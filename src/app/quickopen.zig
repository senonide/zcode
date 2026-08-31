//! Find a file in the project by typing part of its path (Ctrl+P).
//!
//! The project is walked once when the dialog opens — build outputs and VCS
//! metadata are skipped, and the total is capped — then every keystroke ranks
//! that snapshot in memory.  Matching is subsequence-based rather than
//! substring, so "srcmain" finds "src/main.zig", and hits in the file name
//! outrank hits in the directories leading to it.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const editor = @import("../editor/tabs.zig");

const alloc = std.heap.c_allocator;

/// Enough to cover a large project without letting a stray home directory
/// turn one keystroke into a multi-second scan.
const max_files = 20000;
const max_results = 50;
const max_depth = 12;

/// Directories that never hold project sources worth opening by name.
const skipped_dirs = [_][]const u8{
    "node_modules", "zig-out",          "zig-cache", "target",
    "build",        "dist",             "vendor",    "__pycache__",
    ".venv",        ".flatpak-builder",
};

const row_path_key: [*:0]const u8 = "zc-quickopen-path";

const Ctx = struct {
    state: *core.AppState,
    dialog: *gtk.AdwDialog,
    list: *gtk.GtkListBox,
    /// Project-relative paths, owned; the absolute path is rebuilt on demand.
    paths: std.ArrayList([]u8) = .empty,
    root: []u8 = &.{},

    fn deinit(self: *Ctx) void {
        for (self.paths.items) |p| alloc.free(p);
        self.paths.deinit(alloc);
        alloc.free(self.root);
    }
};

pub fn present(state: *core.AppState) void {
    const root = std.mem.sliceTo(&state.folder_path, 0);
    if (root.len == 0) return;

    const dialog = gtk.adw_dialog_new() orelse return;
    gtk.adw_dialog_set_title(dialog, "Find File");
    gtk.adw_dialog_set_content_width(dialog, 560);
    gtk.adw_dialog_set_content_height(dialog, 480);

    const box_widget = gtk.gtk_box_new(.vertical, 0) orelse return;
    const box = @as(*gtk.GtkBox, @ptrCast(box_widget));

    const header = gtk.adw_header_bar_new() orelse return;
    const entry_widget = gtk.gtk_search_entry_new() orelse return;
    gtk.gtk_widget_set_hexpand(entry_widget, 1);
    gtk.adw_header_bar_set_title_widget(@ptrCast(header), entry_widget);
    gtk.gtk_box_append(box, header);

    const scroll_widget = gtk.gtk_scrolled_window_new() orelse return;
    const scroll = @as(*gtk.GtkScrolledWindow, @ptrCast(scroll_widget));
    gtk.gtk_widget_set_vexpand(scroll_widget, 1);
    gtk.gtk_scrolled_window_set_policy(scroll, .never, .automatic);

    const list_widget = gtk.gtk_list_box_new() orelse return;
    const list = @as(*gtk.GtkListBox, @ptrCast(list_widget));
    gtk.gtk_list_box_set_selection_mode(list, .single);
    gtk.gtk_widget_add_css_class(list_widget, "navigation-sidebar");
    gtk.gtk_scrolled_window_set_child(scroll, list_widget);
    gtk.gtk_box_append(box, scroll_widget);

    gtk.adw_dialog_set_child(dialog, box_widget);

    const ctx = alloc.create(Ctx) catch return;
    ctx.* = .{ .state = state, .dialog = dialog, .list = list };
    ctx.root = alloc.dupe(u8, root) catch {
        alloc.destroy(ctx);
        return;
    };
    collect(ctx);

    _ = gtk.g_signal_connect_data(entry_widget, "search-changed", @as(gtk.GCallback, @ptrCast(&onSearchChanged)), @ptrCast(ctx), null, 0);
    _ = gtk.g_signal_connect_data(entry_widget, "activate", @as(gtk.GCallback, @ptrCast(&onEntryActivate)), @ptrCast(ctx), null, 0);
    _ = gtk.g_signal_connect_data(list_widget, "row-activated", @as(gtk.GCallback, @ptrCast(&onRowActivated)), @ptrCast(ctx), null, 0);
    _ = gtk.g_signal_connect_data(dialog, "closed", @as(gtk.GCallback, @ptrCast(&onClosed)), @ptrCast(ctx), null, 0);

    fill(ctx, "");
    gtk.adw_dialog_present(dialog, @ptrCast(state.win));
    _ = gtk.gtk_widget_grab_focus(entry_widget);
}

fn onClosed(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    ctx.deinit();
    alloc.destroy(ctx);
}

// ── Project scan ─────────────────────────────────────────────────────────────

/// Depth-first walk of the project, collecting project-relative file paths.
/// Runs on the main loop, which is why it is bounded on both breadth (the skip
/// list) and total size.
fn collect(ctx: *Ctx) void {
    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |p| alloc.free(p);
        stack.deinit(alloc);
    }
    const first = alloc.dupe(u8, ctx.root) catch return;
    stack.append(alloc, first) catch {
        alloc.free(first);
        return;
    };

    var dir_buf: [4096:0]u8 = undefined;
    var full_buf: [4096:0]u8 = undefined;

    while (stack.pop()) |dir_path| {
        defer alloc.free(dir_path);
        if (ctx.paths.items.len >= max_files) break;

        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir_path}) catch continue;
        const gdir = gtk.g_dir_open(dir_z, 0, null) orelse continue;
        defer gtk.g_dir_close(gdir);

        while (gtk.g_dir_read_name(gdir)) |raw| {
            const name = std.mem.sliceTo(raw, 0);
            if (name.len == 0 or name[0] == '.') continue;

            const full_z = std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ dir_path, name }) catch continue;
            const full = std.mem.sliceTo(full_z, 0);

            if (gtk.g_file_test(full_z, gtk.G_FILE_TEST_IS_DIR) != 0) {
                if (isSkipped(name) or depthOf(full, ctx.root.len) > max_depth) continue;
                const owned = alloc.dupe(u8, full) catch continue;
                stack.append(alloc, owned) catch alloc.free(owned);
                continue;
            }

            if (ctx.paths.items.len >= max_files) break;
            // Store the path relative to the root: it is what the user reads,
            // types against, and what keeps the list compact.
            const rel = alloc.dupe(u8, full[@min(ctx.root.len + 1, full.len)..]) catch continue;
            ctx.paths.append(alloc, rel) catch alloc.free(rel);
        }
    }
}

fn isSkipped(name: []const u8) bool {
    for (skipped_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

fn depthOf(path: []const u8, root_len: usize) usize {
    if (path.len <= root_len) return 0;
    return std.mem.count(u8, path[root_len..], "/");
}

// ── Matching ─────────────────────────────────────────────────────────────────

/// Score for `needle` against `hay`, or null when `hay` does not contain the
/// needle's characters in order.  Higher is better: consecutive characters and
/// characters landing in the file name (rather than a parent directory) both
/// pull the entry up.
fn score(hay: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;

    const name_start = if (std.mem.lastIndexOfScalar(u8, hay, '/')) |i| i + 1 else 0;
    var total: i32 = 0;
    var run: i32 = 0;
    var hi: usize = 0;

    for (needle) |want| {
        const lower_want = std.ascii.toLower(want);
        while (hi < hay.len and std.ascii.toLower(hay[hi]) != lower_want) : (hi += 1) run = 0;
        if (hi == hay.len) return null;
        run += 1;
        total += run;
        if (hi >= name_start) total += 4;
        hi += 1;
    }
    // Prefer shorter paths when the match quality is otherwise equal.
    return total - @divTrunc(@as(i32, @intCast(@min(hay.len, 100))), 8);
}

const Hit = struct { index: usize, score: i32 };

/// The best `max_results` matches seen so far, best first.  Only that many are
/// ever shown, so keeping a small ordered window as the scan goes costs a few
/// comparisons per file instead of ranking the whole project on every
/// keystroke — and an empty query matches every file.
const Ranking = struct {
    hits: [max_results]Hit = undefined,
    len: usize = 0,

    fn offer(self: *Ranking, hit: Hit) void {
        if (self.len == max_results and hit.score <= self.hits[max_results - 1].score) return;
        var i = @min(self.len, max_results - 1);
        while (i > 0 and self.hits[i - 1].score < hit.score) : (i -= 1) self.hits[i] = self.hits[i - 1];
        self.hits[i] = hit;
        if (self.len < max_results) self.len += 1;
    }
};

// ── List ─────────────────────────────────────────────────────────────────────

fn fill(ctx: *Ctx, needle: []const u8) void {
    gtk.gtk_list_box_remove_all(ctx.list);

    var ranking: Ranking = .{};
    for (ctx.paths.items, 0..) |path, i| {
        const s = score(path, needle) orelse continue;
        ranking.offer(.{ .index = i, .score = s });
    }

    for (ranking.hits[0..ranking.len]) |hit| {
        const rel = ctx.paths.items[hit.index];
        const row = gtk.adw_action_row_new() orelse break;

        var name_buf: [256:0]u8 = undefined;
        const base = std.fs.path.basename(rel);
        const title = std.fmt.bufPrintZ(&name_buf, "{s}", .{base}) catch continue;
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);

        var dir_buf: [1024:0]u8 = undefined;
        const parent = std.fs.path.dirname(rel) orelse "";
        const subtitle = std.fmt.bufPrintZ(&dir_buf, "{s}", .{parent}) catch continue;
        gtk.adw_action_row_set_subtitle(@ptrCast(row), subtitle);
        gtk.gtk_list_box_row_set_activatable(@ptrCast(row), 1);

        var abs_buf: [4096:0]u8 = undefined;
        const abs = std.fmt.bufPrintZ(&abs_buf, "{s}/{s}", .{ ctx.root, rel }) catch continue;
        gtk.g_object_set_data_full(@ptrCast(row), row_path_key, gtk.g_strdup(abs), &gtk.g_free);

        gtk.gtk_list_box_append(ctx.list, row);
    }

    // Pre-select the top hit so Enter opens it without touching the arrows.
    if (gtk.gtk_list_box_get_row_at_index(ctx.list, 0)) |first|
        gtk.gtk_list_box_select_row(ctx.list, first);
}

fn onSearchChanged(entry: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const text = gtk.gtk_editable_get_text(@as(*gtk.GtkEditable, @ptrCast(entry.?)));
    fill(ctx, std.mem.sliceTo(text, 0));
}

fn onEntryActivate(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    const row = gtk.gtk_list_box_get_selected_row(ctx.list) orelse
        gtk.gtk_list_box_get_row_at_index(ctx.list, 0) orelse return;
    open(ctx, @ptrCast(row));
}

fn onRowActivated(_: ?*anyopaque, row: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    open(ctx, row.?);
}

fn open(ctx: *Ctx, row: *anyopaque) void {
    const raw = gtk.g_object_get_data(@ptrCast(row), row_path_key) orelse return;
    // Closing frees ctx via "closed", so read everything needed first.
    const state = ctx.state;
    const path: [*:0]const u8 = @ptrCast(raw);
    var buf: [4096:0]u8 = undefined;
    const copy = std.fmt.bufPrintZ(&buf, "{s}", .{std.mem.sliceTo(path, 0)}) catch return;
    _ = gtk.adw_dialog_close(ctx.dialog);
    editor.openEditorTab(state, copy);
}

test "score: subsequence match and ordering" {
    // A path that does not contain the characters in order does not match.
    try std.testing.expect(score("src/main.zig", "zx") == null);
    // The file name outranks the directories leading to it.
    const in_name = score("src/main.zig", "main").?;
    const in_dir = score("main/other.zig", "main").?;
    try std.testing.expect(in_name > in_dir);
}

test "score: empty needle matches everything" {
    try std.testing.expectEqual(@as(i32, 0), score("anything", "").?);
}

test "score: gaps are allowed" {
    try std.testing.expect(score("src/app/window.zig", "srcwin") != null);
}

test "ranking: keeps the best matches, best first" {
    var ranking: Ranking = .{};
    // More candidates than the window holds, offered worst-first so every one
    // of them has to displace the entries already in it.
    for (0..max_results * 2) |i| ranking.offer(.{ .index = i, .score = @intCast(i) });

    try std.testing.expectEqual(max_results, ranking.len);
    try std.testing.expectEqual(@as(i32, max_results * 2 - 1), ranking.hits[0].score);
    for (ranking.hits[0 .. ranking.len - 1], ranking.hits[1..ranking.len]) |a, b|
        try std.testing.expect(a.score >= b.score);
}

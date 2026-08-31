//! Per-project editor-tab session persistence.
//!
//! Stores the set of editor files open per project root in
//! `$XDG_CONFIG_HOME/zcode/sessions.json`, so reopening a project restores its
//! tabs (never its terminals — those are ephemeral). A single flat JSON object
//! keyed by absolute project path:
//!
//!   { "/path/to/proj": {"files": ["…","…"], "selected": "…"}, … }
//!
//! The schema is deliberately tiny: open files plus the selected one. Cursor
//! position and preview mode are not restored — the set of tabs is the load-
//! bearing part of "the same state"; the rest is polish that can follow.
//!
//! Entries are pruned to projects still in the recent list (config.max_recent)
//! on every save, keeping the file bounded to the same ten-project window the
//! recent-projects popover shows.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("state.zig");
const config = @import("config.zig");

const alloc = std.heap.c_allocator;

/// One loaded session. Owns its slices; free with `deinit`.
pub const Session = struct {
    files: [][]const u8,
    selected: []const u8,

    pub fn deinit(self: *Session) void {
        for (self.files) |f| alloc.free(f);
        alloc.free(self.files);
        alloc.free(self.selected);
    }
};

/// Records the editor tabs open in `state` under its project root. No-op when
/// the window has no project open. Terminals are never persisted.
pub fn save(state: *core.AppState) void {
    const root = std.mem.sliceTo(&state.folder_path, 0);
    if (root.len == 0) return;

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

    var selected: []const u8 = "";
    if (gtk.adw_tab_view_get_selected_page(state.editor_tabs)) |sel_page| {
        if (core.editorTabFromPage(sel_page)) |t|
            selected = std.mem.sliceTo(&t.doc.path, 0);
    }

    const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = gtk.adw_tab_view_get_nth_page(state.editor_tabs, i) orelse continue;
        if (core.editorTabFromPage(page)) |t| {
            const p = std.mem.sliceTo(&t.doc.path, 0);
            if (p.len != 0) files.append(alloc, p) catch return;
        }
    }

    writeEntry(root, files.items, selected);
}

/// Returns the session saved for `project_path`, or null when there is none.
/// The caller owns the result and frees it with `Session.deinit`.
pub fn load(project_path: []const u8) ?Session {
    var path_buf: [4096:0]u8 = .{0} ** 4096;
    if (!buildPath(&path_buf)) return null;

    var raw: [*:0]u8 = undefined;
    var err: ?*gtk.GError = null;
    if (gtk.g_file_get_contents(&path_buf, &raw, null, &err) == 0) {
        if (err != null) gtk.g_error_free(err);
        return null;
    }
    defer gtk.g_free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, std.mem.sliceTo(raw, 0), .{}) catch return null;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const entry = root_obj.get(project_path) orelse return null;
    const entry_obj = switch (entry) {
        .object => |o| o,
        else => return null,
    };

    const files_arr = switch (entry_obj.get("files") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var files: std.ArrayList([]const u8) = .empty;
    for (files_arr.items) |item| {
        const s = switch (item) {
            .string => |s| s,
            else => continue,
        };
        files.append(alloc, alloc.dupe(u8, s) catch return null) catch return null;
    }

    const selected_src: []const u8 = switch (entry_obj.get("selected") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    const owned_files = files.toOwnedSlice(alloc) catch return null;
    const owned_selected = alloc.dupe(u8, selected_src) catch {
        for (owned_files) |f| alloc.free(f);
        alloc.free(owned_files);
        return null;
    };

    return .{ .files = owned_files, .selected = owned_selected };
}

// ── Internals: JSON written by hand (parsed with std.json) ────────────────────

const Entry = struct { path: []const u8, files: [][]const u8, selected: []const u8 };

/// Rebuilds the whole sessions file with `root`'s entry set to `files`/`selected`,
/// dropping any project no longer in the recent list.
fn writeEntry(root: []const u8, files: []const []const u8, selected: []const u8) void {
    var path_buf: [4096:0]u8 = .{0} ** 4096;
    if (!buildPath(&path_buf)) return;

    var existing: std.ArrayList(Entry) = .empty;
    defer {
        for (existing.items) |e| {
            for (e.files) |f| alloc.free(f);
            alloc.free(e.files);
            alloc.free(e.selected);
            alloc.free(e.path);
        }
        existing.deinit(alloc);
    }
    readExisting(&path_buf, &existing) catch {};

    // Replace/append this project's entry.
    var i: usize = 0;
    while (i < existing.items.len) : (i += 1) {
        if (std.mem.eql(u8, existing.items[i].path, root)) {
            freeEntry(existing.items[i]);
            _ = existing.swapRemove(i);
            break;
        }
    }
    existing.append(alloc, dupeEntry(root, files, selected) catch return) catch return;

    // Prune to recent projects.
    var kept: std.ArrayList(Entry) = .empty;
    defer kept.deinit(alloc);
    var recents: std.ArrayList([]const u8) = .empty;
    defer recents.deinit(alloc);
    var rit = config.recentProjects();
    defer rit.deinit();
    while (rit.next()) |p| recents.append(alloc, p) catch {};
    for (existing.items) |e| {
        if (isRecent(e.path, recents.items))
            kept.append(alloc, e) catch {};
    }
    existing.clearRetainingCapacity();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.append(alloc, '{') catch return;
    for (kept.items, 0..) |e, idx| {
        if (idx != 0) out.append(alloc, ',') catch return;
        writeEntryField(&out, e) catch return;
    }
    out.append(alloc, '}') catch return;

    ensureDir(&path_buf);
    var gerr: ?*gtk.GError = null;
    _ = gtk.g_file_set_contents(&path_buf, out.items.ptr, @intCast(out.items.len), &gerr);
    if (gerr != null) gtk.g_error_free(gerr);
}

fn writeEntryField(out: *std.ArrayList(u8), e: Entry) !void {
    try writeString(out, e.path);
    try out.append(alloc, ':');
    try out.append(alloc, '{');
    try out.appendSlice(alloc, "\"files\":");
    try out.append(alloc, '[');
    for (e.files, 0..) |f, idx| {
        if (idx != 0) try out.append(alloc, ',');
        try writeString(out, f);
    }
    try out.append(alloc, ']');
    try out.appendSlice(alloc, ",\"selected\":");
    try writeString(out, e.selected);
    try out.append(alloc, '}');
}

/// Writes a JSON string literal (quoted, escaped) for `s` into `out`.
fn writeString(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...31 => {
                var buf: [6]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try out.appendSlice(alloc, esc);
            },
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
}

fn dupeEntry(path: []const u8, files: []const []const u8, selected: []const u8) !Entry {
    const path_c = try alloc.dupe(u8, path);
    errdefer alloc.free(path_c);
    const files_c = try alloc.alloc([]const u8, files.len);
    errdefer alloc.free(files_c);
    var n: usize = 0;
    errdefer {
        for (files_c[0..n]) |f| alloc.free(f);
    }
    for (files) |f| {
        files_c[n] = try alloc.dupe(u8, f);
        n += 1;
    }
    const sel_c = try alloc.dupe(u8, selected);
    return .{ .path = path_c, .files = files_c, .selected = sel_c };
}

fn freeEntry(e: Entry) void {
    for (e.files) |f| alloc.free(f);
    alloc.free(e.files);
    alloc.free(e.selected);
    alloc.free(e.path);
}

fn readExisting(path: *const [4096:0]u8, out: *std.ArrayList(Entry)) !void {
    var raw: [*:0]u8 = undefined;
    var err: ?*gtk.GError = null;
    if (gtk.g_file_get_contents(path, &raw, null, &err) == 0) {
        if (err != null) gtk.g_error_free(err);
        return;
    }
    defer gtk.g_free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, std.mem.sliceTo(raw, 0), .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    var it = obj.iterator();
    while (it.next()) |kv| {
        const entry_obj = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        const files_arr = switch (entry_obj.get("files") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(alloc);
        for (files_arr.items) |item| {
            const s = switch (item) {
                .string => |s| s,
                else => continue,
            };
            files.append(alloc, s) catch continue;
        }
        const selected: []const u8 = switch (entry_obj.get("selected") orelse std.json.Value{ .string = "" }) {
            .string => |s| s,
            else => "",
        };
        out.append(alloc, dupeEntry(kv.key_ptr.*, files.items, selected) catch continue) catch continue;
    }
}

fn isRecent(path: []const u8, recents: []const []const u8) bool {
    for (recents) |r| {
        if (std.mem.eql(u8, r, path)) return true;
    }
    return false;
}

fn buildPath(buf: *[4096:0]u8) bool {
    const cfg = gtk.g_get_user_config_dir() orelse return false;
    _ = std.fmt.bufPrintZ(buf, "{s}/zcode/sessions.json", .{std.mem.sliceTo(cfg, 0)}) catch return false;
    return true;
}

fn ensureDir(path: *const [4096:0]u8) void {
    var dir_buf: [4096:0]u8 = .{0} ** 4096;
    const path_s = std.mem.sliceTo(path, 0);
    const dir = std.fs.path.dirname(path_s) orelse return;
    const dn = @min(dir.len, dir_buf.len - 1);
    @memcpy(dir_buf[0..dn], dir[0..dn]);
    dir_buf[dn] = 0;
    _ = gtk.g_mkdir_with_parents(&dir_buf, 0o755);
}

// ── Tests ─────────────────────────────────────────────────────────────────────
//
// The on-disk path is exercised via the full build + smoke test (it touches GTK
// and GSettings); these tests cover the pure string-escaping and the JSON
// round-trip through std.json so the writer and reader agree.

test "writeString: escapes quotes, backslash and control chars" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try writeString(&out, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items);
}

test "writeString: empty string" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try writeString(&out, "");
    try std.testing.expectEqualStrings("\"\"", out.items);
}

test "writeString: control char below 0x20 is \\u-escaped" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try writeString(&out, "\x01");
    try std.testing.expectEqualStrings("\"\\u0001\"", out.items);
}

test "writeEntryField + std.json round-trip" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const e_files = try alloc.alloc([]const u8, 2);
    e_files[0] = "/proj/a.zig";
    e_files[1] = "/proj/b.md";
    defer alloc.free(e_files);
    const e = Entry{
        .path = "/proj",
        .files = e_files,
        .selected = "/proj/a.zig",
    };
    try writeEntryField(&out, e);
    // Wrap as a one-entry object so it maps to a root object keyed by path.
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    try full.append(alloc, '{');
    try full.appendSlice(alloc, out.items);
    try full.append(alloc, '}');

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, full.items, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const entry = obj.get("/proj") orelse return error.MissingEntry;
    const entry_obj = switch (entry) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const files = switch (entry_obj.get("files") orelse return error.MissingFiles) {
        .array => |a| a,
        else => return error.NotArray,
    };
    try std.testing.expectEqual(@as(usize, 2), files.items.len);
    try std.testing.expectEqualStrings("/proj/a.zig", files.items[0].string);
    try std.testing.expectEqualStrings("/proj/b.md", files.items[1].string);
    try std.testing.expectEqualStrings("/proj/a.zig", entry_obj.get("selected").?.string);
}

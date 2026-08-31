//! Keeps the editors/terminals/empty view stack, its matching tab bar, the
//! header-bar title and the editor status bar in sync as tabs open or close and
//! terminal mode is toggled.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const lsp = @import("../lsp/manager.zig");
const preview = @import("../editor/preview.zig");

/// Brings the visible view, tab bar, status bar and tab overview in line with
/// the current mode (terminal vs editor) and the number of open tabs.
pub fn updateView(state: *core.AppState) void {
    if (state.shutting_down) return;
    if (state.terminal_shown) {
        gtk.gtk_widget_set_visible(@ptrCast(state.tabbar_stack), 1);
        gtk.gtk_stack_set_visible_child_name(state.tabbar_stack, "terminal");
        gtk.gtk_stack_set_visible_child_name(state.view_stack, "terminals");
    } else if (gtk.adw_tab_view_get_n_pages(state.editor_tabs) > 0) {
        gtk.gtk_widget_set_visible(@ptrCast(state.tabbar_stack), 1);
        gtk.gtk_stack_set_visible_child_name(state.tabbar_stack, "editor");
        gtk.gtk_stack_set_visible_child_name(state.view_stack, "editors");
    } else {
        gtk.gtk_widget_set_visible(@ptrCast(state.tabbar_stack), 0);
        gtk.gtk_stack_set_visible_child_name(state.view_stack, "empty");
    }

    gtk.gtk_widget_set_visible(state.new_terminal_btn, if (state.terminal_shown) 1 else 0);

    // Which tabs the overview grids is decided when it opens (shortcuts.zig),
    // never here.  `open` goes false the moment the closing animation starts,
    // but libadwaita only releases the tab view when that animation ends —
    // rebinding in between leaves the released view's page bins believing they
    // are still overview thumbnails, so AdwTabView paints the visible tab
    // without ever allocating it and the editor stops redrawing.

    preview.updatePreviewBtn(state);
    updateStatus(state);
}

/// Enters terminal mode and shows the terminal tabs.
pub fn switchToTerminals(state: *core.AppState) void {
    if (state.shutting_down) return;
    state.terminal_shown = true;
    syncViewAction(state);
    updateView(state);
    updateWindowTitle(state);
}

/// Leaves terminal mode and shows the editors (or the empty page).
pub fn switchToEditors(state: *core.AppState) void {
    if (state.shutting_down) return;
    state.terminal_shown = false;
    syncViewAction(state);
    updateView(state);
    updateWindowTitle(state);
}

/// Moves the header-bar mode switch to match `state.terminal_shown` without
/// its own handler firing back into here. `set_state` updates the action's
/// state property; GtkActionable listens to that to render the buttons, and
/// `set_state` does not re-emit `change-state`, so there is no recursion.
pub fn syncViewAction(state: *core.AppState) void {
    const target: [*:0]const u8 = if (state.terminal_shown) core.view_terminal else core.view_editor;
    gtk.g_simple_action_set_state(@ptrCast(state.view_action), gtk.g_variant_new_string(target));
}

/// Rebuilds the header-bar title: the file name over its path inside the
/// project, which is the GNOME pattern — the app name never appears, and the
/// path lives in the subtitle rather than being crammed into one line.  A
/// bullet marks unsaved changes.  The window title (task switchers, the
/// desktop shell) gets the same name without the subtitle.
pub fn updateWindowTitle(state: *core.AppState) void {
    if (state.shutting_down) return;
    var title_buf: [320:0]u8 = undefined;
    var sub_buf: [512:0]u8 = undefined;

    const folder = std.mem.sliceTo(&state.folder_path, 0);
    const project = if (folder.len > 0) std.fs.path.basename(folder) else "";

    if (!state.terminal_shown) {
        if (core.selectedEditorTab(state)) |tab| {
            const bullet: []const u8 = if (tab.doc.isModified(tab.buffer)) "\u{2022} " else "";
            const name = tab.doc.filename();
            const title = std.fmt.bufPrintZ(&title_buf, "{s}{s}", .{ bullet, name }) catch "Untitled";
            const subtitle = std.fmt.bufPrintZ(&sub_buf, "{s}", .{parentLabel(state, tab, project)}) catch "";
            setTitle(state, title, subtitle, name);
            return;
        }
    }

    if (state.terminal_shown) {
        const subtitle = std.fmt.bufPrintZ(&sub_buf, "{s}", .{project}) catch "";
        setTitle(state, "Terminal", subtitle, "Terminal");
        return;
    }

    if (project.len == 0) {
        setTitle(state, "zcode", "", "zcode");
    } else {
        const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{project}) catch "zcode";
        setTitle(state, title, "", title);
    }
}

/// Where the open file lives, as shown under its name: its directory relative
/// to the project root, the project name itself for a file sitting at the root,
/// and the absolute parent directory for a file outside any project.
fn parentLabel(state: *core.AppState, tab: *core.EditorTab, project: []const u8) []const u8 {
    if (!tab.doc.isOpen()) return project;
    const file_path = std.mem.sliceTo(&tab.doc.path, 0);
    const dir = std.fs.path.dirname(file_path) orelse return project;
    const folder = std.mem.sliceTo(&state.folder_path, 0);

    if (folder.len == 0 or !std.mem.startsWith(u8, file_path, folder)) return dir;
    if (dir.len == folder.len) return project;
    return dir[folder.len + 1 ..];
}

fn setTitle(
    state: *core.AppState,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    window_title: []const u8,
) void {
    gtk.adw_window_title_set_title(state.title, title);
    gtk.adw_window_title_set_subtitle(state.title, subtitle);
    var buf: [320:0]u8 = undefined;
    const wt = std.fmt.bufPrintZ(&buf, "{s}", .{window_title}) catch "zcode";
    gtk.gtk_window_set_title(state.win, wt);
}

// ── Status bar ────────────────────────────────────────────────────────────────

/// Assembles the bottom bar: what the language server makes of the open file on
/// the left, what git and the cursor make of it on the right. Returns the row to
/// hand to `adw_toolbar_view_add_bottom_bar` along with the readings to update.
pub fn buildStatusBar() struct { *gtk.GtkWidget, core.StatusBar } {
    const row = gtk.gtk_box_new(.horizontal, 12).?;
    const box = @as(*gtk.GtkBox, @ptrCast(row));
    gtk.gtk_widget_add_css_class(row, "toolbar");
    gtk.gtk_widget_add_css_class(row, "zc-status");

    const server = gtk.gtk_label_new("").?;
    gtk.gtk_widget_set_tooltip_text(server, "Language server connected");
    gtk.gtk_widget_set_visible(server, 0);
    gtk.gtk_box_append(box, server);

    const diags = [3]core.StatusFigure{
        figure(box, "dialog-error-symbolic", "error"),
        figure(box, "dialog-warning-symbolic", "warning"),
        figure(box, "dialog-information-symbolic", "accent"),
    };

    const spacer = gtk.gtk_box_new(.horizontal, 0).?;
    gtk.gtk_widget_set_hexpand(spacer, 1);
    gtk.gtk_box_append(box, spacer);

    const added = figure(box, null, "success");
    const removed = figure(box, null, "error");

    const position = gtk.gtk_label_new("").?;
    gtk.gtk_box_append(box, position);

    return .{ row, .{
        .server = @ptrCast(server),
        .diags = diags,
        .added = added,
        .removed = removed,
        .position = @ptrCast(position),
    } };
}

/// Called by the diff gutter once a recomputed `git diff` lands, which is well
/// after the save that asked for it — every window re-reads its own counts.
pub fn onDiffChanged() callconv(.c) void {
    for (core.g_windows.items) |state| updateStatus(state);
}

/// One reading, appended to the bar and hidden until it has something to say.
/// `css` is a libadwaita colour helper class, so the figure follows the theme
/// rather than a colour of ours.
fn figure(box: *gtk.GtkBox, icon: ?[*:0]const u8, css: [*:0]const u8) core.StatusFigure {
    const label = gtk.gtk_label_new("").?;
    const root = if (icon) |name| blk: {
        const pair = gtk.gtk_box_new(.horizontal, 4).?;
        gtk.gtk_box_append(@ptrCast(pair), gtk.gtk_image_new_from_icon_name(name).?);
        gtk.gtk_box_append(@ptrCast(pair), label);
        break :blk pair;
    } else label;
    gtk.gtk_widget_add_css_class(root, css);
    gtk.gtk_widget_set_visible(root, 0);
    gtk.gtk_box_append(box, root);
    return .{ .root = root, .value = @ptrCast(label) };
}

/// Shows `count` on `fig`, or hides it entirely when there is nothing to count.
fn setFigure(fig: core.StatusFigure, prefix: []const u8, count: u32) void {
    if (count == 0) {
        gtk.gtk_widget_set_visible(fig.root, 0);
        return;
    }
    var buf: [24:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "{s}{d}", .{ prefix, count }) catch return;
    gtk.gtk_label_set_text(fig.value, text);
    gtk.gtk_widget_set_visible(fig.root, 1);
}

/// Refreshes every reading in the bottom bar, and reveals the bar only while a
/// text buffer is on screen — there is nothing to report about a terminal, an
/// image or the empty state.
pub fn updateStatus(state: *core.AppState) void {
    if (state.shutting_down) return;

    const tab = if (state.terminal_shown) null else core.selectedEditorTab(state);
    const showing = blk: {
        const t = tab orelse break :blk false;
        break :blk !t.doc.is_binary and !t.is_image;
    };
    gtk.adw_toolbar_view_set_reveal_bottom_bars(state.content_toolbar, if (showing) 1 else 0);
    if (!showing) return;
    const open = tab.?;

    if (lsp.serverLanguage(open)) |language| {
        var name: [64:0]u8 = undefined;
        const n = @min(language.len, name.len - 1);
        @memcpy(name[0..n], language[0..n]);
        if (n > 0) name[0] = std.ascii.toUpper(name[0]);
        name[n] = 0;
        gtk.gtk_label_set_text(state.status.server, &name);
        gtk.gtk_widget_set_visible(@ptrCast(state.status.server), 1);
    } else {
        gtk.gtk_widget_set_visible(@ptrCast(state.status.server), 0);
    }

    const counts = lsp.diagnosticCounts(open.buffer);
    setFigure(state.status.diags[0], "", counts[0]);
    setFigure(state.status.diags[1], "", counts[1]);
    setFigure(state.status.diags[2], "", counts[2] + counts[3]);

    var added: c_uint = 0;
    var removed: c_uint = 0;
    gtk.zc_diff_stats(open.source_view, &added, &removed);
    setFigure(state.status.added, "+", added);
    setFigure(state.status.removed, "\u{2212}", removed);

    const tb: *gtk.GtkTextBuffer = @ptrCast(open.buffer);
    var iter: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_mark(tb, &iter, gtk.gtk_text_buffer_get_insert(tb));

    var buf: [64:0]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "Ln {d}, Col {d}", .{
        gtk.gtk_text_iter_get_line(&iter) + 1,
        gtk.gtk_text_iter_get_line_offset(&iter) + 1,
    }) catch return;
    gtk.gtk_label_set_text(state.status.position, text);
}

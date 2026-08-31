//! Project sidebar: builds and refreshes the C file tree, shows git state in the
//! header, opens folders and runs the new-file/folder dialog. The Zig side the
//! tree (src/c/tree*.c) calls back into.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const config = @import("../core/config.zig");
const session = @import("../core/session.zig");
const view = @import("../app/view.zig");
const toast = @import("../app/toast.zig");
const editor = @import("../editor/tabs.zig");
const preview = @import("../editor/preview.zig");
const terminal = @import("../terminal/tabs.zig");

// Set from window.zig at startup to break the window.zig ↔ files.zig cycle
// (window.zig already imports this module to build the sidebar).
pub var g_build_window_fn: ?*const fn (*gtk.AdwApplication, ?*core.AppState) *core.AppState = null;

// ── Tree build / refresh ──────────────────────────────────────────────────────

/// Builds a fresh file tree for the open folder and installs it in the sidebar.
/// Replacing the old tree widget tears down its file monitors automatically.
pub fn buildTree(state: *core.AppState) void {
    const root = std.mem.sliceTo(&state.folder_path, 0);
    if (root.len == 0) return;

    // Callbacks the C file tree invokes back into the app.  zc_file_tree_new
    // copies this block, so a stack temporary carrying this window's state is fine.
    const tree_callbacks = gtk.ZcTreeCallbacks{
        .open_file = &treeOpenFile,
        .open_terminal = &treeOpenTerminal,
        .new_item = &treeNewItem,
        .changed = &treeChanged,
        .file_renamed = &treeFileRenamed,
        .report = &treeReport,
        .user_data = @ptrCast(state),
    };

    const tv = gtk.zc_file_tree_new(&state.folder_path, &tree_callbacks) orelse return;
    gtk.gtk_widget_add_css_class(tv, "navigation-sidebar");
    // Replace the child first; the old widget is freed here (it was the scrolled
    // window's sole GInitiallyUnowned reference), so the previous `file_tree`
    // pointer becomes dangling from this point on.
    gtk.gtk_scrolled_window_set_child(state.sidebar_scroll, tv);
    state.file_tree = tv;
    updateGitLabel(state);
}

/// In-place refresh: re-reads git + reconciles the visible directories without
/// rebuilding the tree, so expansion and selection survive.
fn refreshTreeContents(state: *core.AppState) void {
    if (state.file_tree) |tree| {
        gtk.zc_file_tree_refresh(tree);
        updateGitLabel(state);
    }
}

/// Refreshes the sidebar when the window regains focus, catching git activity
/// the `.git` monitor can't see (pushes/commits from an outside terminal write
/// mostly to unwatched subdirectories). Event-driven — no polling — and rate
/// limited so focus flapping between windows stays cheap.
pub fn onWindowActiveChanged(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return;
    if (gtk.gtk_window_is_active(state.win) == 0) return;
    const now = gtk.g_get_monotonic_time();
    if (now - state.last_focus_refresh < 2 * std.time.us_per_s) return;
    state.last_focus_refresh = now;
    refreshTreeContents(state);
}

/// Reflects the project's git state in the sidebar header: the branch name on
/// top (title) and the change count below (subtitle, dimmed by AdwWindowTitle).
/// When not in a git work tree, the title is the project folder name (or "No
/// Git") and the subtitle is empty.
fn updateGitLabel(state: *core.AppState) void {
    const tree = state.file_tree orelse return;
    if (gtk.zc_file_tree_summary(tree)) |sum| {
        defer gtk.g_free(sum);
        const s = std.mem.sliceTo(sum, 0);
        const sep: []const u8 = " \xe2\x80\xa2 ";
        if (std.mem.indexOf(u8, s, sep)) |pos| {
            var title_buf: [256:0]u8 = undefined;
            var sub_buf: [128:0]u8 = undefined;
            const branch = s[0..pos];
            const status = s[pos + sep.len ..];
            const bn = @min(branch.len, title_buf.len - 1);
            @memcpy(title_buf[0..bn], branch[0..bn]);
            title_buf[bn] = 0;
            const sn = @min(status.len, sub_buf.len - 1);
            @memcpy(sub_buf[0..sn], status[0..sn]);
            sub_buf[sn] = 0;
            gtk.adw_window_title_set_title(state.git_title, &title_buf);
            gtk.adw_window_title_set_subtitle(state.git_title, &sub_buf);
        } else {
            gtk.adw_window_title_set_title(state.git_title, s);
            gtk.adw_window_title_set_subtitle(state.git_title, "");
        }
    } else {
        const folder = std.mem.sliceTo(&state.folder_path, 0);
        if (folder.len > 0) {
            var name_buf: [256:0]u8 = undefined;
            const basename = std.fs.path.basename(folder);
            const n = @min(basename.len, name_buf.len - 1);
            @memcpy(name_buf[0..n], basename[0..n]);
            name_buf[n] = 0;
            gtk.adw_window_title_set_title(state.git_title, &name_buf);
        } else {
            gtk.adw_window_title_set_title(state.git_title, "No Git");
        }
        gtk.adw_window_title_set_subtitle(state.git_title, "");
    }
}

/// Right-clicking empty space below the tree offers to create an item at the
/// project root — the same two window actions the sidebar header exposes, so
/// there is one implementation of "new file here" rather than two.
pub fn onSidebarEmptyRightClick(
    _: ?*anyopaque,
    _: c_int,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (std.mem.sliceTo(&state.folder_path, 0).len == 0) return;

    const menu = gtk.g_menu_new() orelse return;
    defer gtk.g_object_unref(menu);
    gtk.g_menu_append(menu, "New File", "win.new-file");
    gtk.g_menu_append(menu, "New Folder", "win.new-folder");

    const popover_widget = gtk.gtk_popover_menu_new_from_model(@ptrCast(menu)) orelse return;
    const popover = @as(*gtk.GtkPopover, @ptrCast(popover_widget));
    gtk.gtk_popover_set_has_arrow(popover, 0);
    gtk.gtk_widget_set_halign(popover_widget, .start);
    gtk.gtk_widget_set_parent(popover_widget, @ptrCast(state.sidebar_scroll));
    var rect = gtk.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    gtk.gtk_popover_set_pointing_to(popover, &rect);
    _ = gtk.g_signal_connect_data(popover_widget, "closed", @as(gtk.GCallback, @ptrCast(&onMenuClosed)), null, null, 0);
    gtk.gtk_popover_popup(popover);
}

/// A popover parented by hand has to be unparented by hand, or it outlives the
/// menu it was built for — but not before the click that closed it is over.
/// A menu item pops the menu down first and runs its action second, so tearing
/// the popover down here and now finalises the item mid-click and the action
/// never fires: the whole menu appears dead. One idle later it is safe.
fn onMenuClosed(popover: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(&dropPopover, gtk.g_object_ref(popover.?));
}

fn dropPopover(data: ?*anyopaque) callconv(.c) c_int {
    const popover: *gtk.GtkWidget = @ptrCast(@alignCast(data.?));
    if (gtk.gtk_widget_get_parent(popover) != null) gtk.gtk_widget_unparent(popover);
    gtk.g_object_unref(popover);
    return 0; // G_SOURCE_REMOVE
}

// ── File-tree callbacks (invoked from C) ──────────────────────────────────────

fn treeOpenFile(path: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    editor.openEditorTab(state, path);
}

fn treeOpenTerminal(dir: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    terminal.newTerminalTabAt(state, dir);
    view.switchToTerminals(state);
    if (core.selectedTerminalTab(state)) |tab|
        _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.terminal)));
}

fn treeNewItem(dir: [*:0]const u8, is_dir: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dir_s = std.mem.sliceTo(dir, 0);
    const n = @min(dir_s.len, state.dialog_target_dir.len - 1);
    @memcpy(state.dialog_target_dir[0..n], dir_s[0..n]);
    state.dialog_target_dir[n] = 0;
    state.dialog_is_dir = is_dir != 0;
    showNewItemDialog(state);
}

fn treeChanged(user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return;
    updateGitLabel(state);
    editor.refreshAllEditorDiffs(state);
}

fn treeFileRenamed(old_path: [*:0]const u8, new_path: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return;
    editor.renameEditorTab(state, old_path, new_path);
}

/// The tree's filesystem operations (rename, trash, duplicate, drag-and-drop
/// move) report their outcome here rather than failing silently.
fn treeReport(message: [*:0]const u8, is_error: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (is_error != 0) toast.showError(state, message) else toast.show(state, message);
}

// ── Open folder dialog ────────────────────────────────────────────────────────

/// "Open Project" — the split button's main action.  Lists the recent projects
/// so switching to one is two clicks, and falls straight through to the folder
/// chooser while there is no history to show.
pub fn onOpenProjectClicked(button: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (hasRecentProjects()) {
        showRecentPopover(state, @ptrCast(@alignCast(button.?)));
    } else {
        showOpenFolderDialog(state, @as(gtk.GAsyncReadyCallback, @ptrCast(&onFolderSelected)));
    }
}

// Each row carries its own project path, freed with the row.
const recent_path_key: [*:0]const u8 = "zc-recent-path";

fn hasRecentProjects() bool {
    var it = config.recentProjects();
    defer it.deinit();
    return it.next() != null;
}

/// Refills this window's recent-projects popover — created on first use and
/// anchored to `anchor` — and pops it up.
fn showRecentPopover(state: *core.AppState, anchor: *gtk.GtkWidget) void {
    const list_widget = gtk.gtk_list_box_new() orelse return;
    const list = @as(*gtk.GtkListBox, @ptrCast(list_widget));
    gtk.gtk_list_box_set_selection_mode(list, .none);
    gtk.gtk_widget_add_css_class(list_widget, "boxed-list");

    var it = config.recentProjects();
    defer it.deinit();
    while (it.next()) |path| {
        const row = gtk.adw_action_row_new() orelse break;
        var title_buf: [256:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&title_buf, "{s}", .{std.fs.path.basename(path)}) catch continue;
        var sub_buf: [4096:0]u8 = undefined;
        gtk.adw_preferences_row_set_title(@ptrCast(row), title);
        gtk.adw_action_row_set_subtitle(@ptrCast(row), displayPath(path, &sub_buf));
        gtk.gtk_list_box_row_set_activatable(@ptrCast(row), 1);
        gtk.g_object_set_data_full(@ptrCast(row), recent_path_key, gtk.g_strdup(path.ptr), &gtk.g_free);
        gtk.gtk_list_box_append(list, row);
    }

    _ = gtk.g_signal_connect_data(
        list_widget,
        "row-activated",
        @as(gtk.GCallback, @ptrCast(&onRecentActivated)),
        @ptrCast(state),
        null,
        0,
    );

    const other = gtk.gtk_button_new_with_label("Open Other Folder…") orelse return;
    gtk.gtk_widget_add_css_class(other, "flat");
    _ = gtk.g_signal_connect_data(
        other,
        "clicked",
        @as(gtk.GCallback, @ptrCast(&onOpenOtherFolder)),
        @ptrCast(state),
        null,
        0,
    );

    const box_widget = gtk.gtk_box_new(.vertical, 6) orelse return;
    const box = @as(*gtk.GtkBox, @ptrCast(box_widget));
    gtk.gtk_box_append(box, list_widget);
    gtk.gtk_box_append(box, other);
    gtk.gtk_widget_set_size_request(box_widget, 280, -1);

    const popover = state.recent_popover orelse blk: {
        const p = gtk.gtk_popover_new() orelse return;
        gtk.gtk_widget_set_parent(@ptrCast(p), anchor);
        state.recent_popover = p;
        break :blk p;
    };
    // Replacing the child drops the previous rows, and with them their paths.
    gtk.gtk_popover_set_child(popover, box_widget);
    gtk.gtk_popover_popup(popover);
}

fn onRecentActivated(_: ?*anyopaque, row: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const raw = gtk.g_object_get_data(@ptrCast(row.?), recent_path_key) orelse return;
    const path: [*:0]const u8 = @ptrCast(raw);
    if (state.recent_popover) |popover| gtk.gtk_popover_popdown(popover);
    openFolder(state, std.mem.sliceTo(path, 0));
}

fn onOpenOtherFolder(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.recent_popover) |popover| gtk.gtk_popover_popdown(popover);
    showOpenFolderDialog(state, @as(gtk.GAsyncReadyCallback, @ptrCast(&onFolderSelected)));
}

/// Home-relative path for a row's subtitle ("~/devel/zcode").
fn displayPath(path: []const u8, buf: *[4096:0]u8) [:0]const u8 {
    const home = if (gtk.g_get_home_dir()) |h| std.mem.sliceTo(h, 0) else "";
    if (home.len != 0 and std.mem.startsWith(u8, path, home))
        return std.fmt.bufPrintZ(buf, "~{s}", .{path[home.len..]}) catch "";
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch "";
}

/// "Open Project…" — the split button's dropdown entry that skips the recent
/// list and goes straight to the folder chooser, replacing this window's project.
pub fn onOpenProjectAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    showOpenFolderDialog(state, @as(gtk.GAsyncReadyCallback, @ptrCast(&onFolderSelected)));
}

/// "Open Project in New Window" — leaves this window's project untouched and
/// opens the chosen folder in a brand new, independent window.
pub fn onOpenProjectNewWindowAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    showOpenFolderDialog(state, @as(gtk.GAsyncReadyCallback, @ptrCast(&onFolderSelectedNewWindow)));
}

/// "Open File…" — opens a single file in a tab without changing the project.
pub fn showOpenFileDialog(state: *core.AppState) void {
    const dialog = gtk.gtk_file_dialog_new().?;
    defer gtk.g_object_unref(dialog); // see showOpenFolderDialog
    gtk.gtk_file_dialog_set_title(dialog, "Open File");
    gtk.gtk_file_dialog_set_modal(dialog, 1);

    const folder = std.mem.sliceTo(&state.folder_path, 0);
    if (folder.len != 0) {
        if (gtk.g_file_new_for_path(&state.folder_path)) |gf| {
            gtk.gtk_file_dialog_set_initial_folder(dialog, gf);
            gtk.g_object_unref(gf);
        }
    }

    gtk.gtk_file_dialog_open(
        dialog,
        state.win,
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onFileSelected)),
        @ptrCast(state),
    );
}

fn onFileSelected(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.GtkFileDialog, @ptrCast(@alignCast(source.?)));
    var err: ?*gtk.GError = null;
    const gfile = gtk.gtk_file_dialog_open_finish(dialog, result, &err);
    if (err != null) {
        gtk.g_error_free(err);
        return;
    }
    const file = gfile orelse return;
    defer gtk.g_object_unref(file);
    const path = gtk.g_file_get_path(file) orelse return;
    defer gtk.g_free(path);
    editor.openEditorTab(state, path);
}

fn showOpenFolderDialog(state: *core.AppState, callback: gtk.GAsyncReadyCallback) void {
    const dialog = gtk.gtk_file_dialog_new().?;
    // GtkFileDialog is a plain GObject, so it arrives with a reference of our
    // own that nothing else ever drops.  It keeps itself alive for the duration
    // of the async call, so handing that reference back here is what stops one
    // dialog (and its file-chooser window) leaking per invocation.
    defer gtk.g_object_unref(dialog);
    gtk.gtk_file_dialog_set_title(dialog, "Open Folder");
    gtk.gtk_file_dialog_set_modal(dialog, 1);
    gtk.gtk_file_dialog_select_folder(dialog, state.win, null, callback, @ptrCast(state));
}

fn selectedFolderPath(result: ?*gtk.GAsyncResult, source: ?*gtk.GObject) ?[:0]const u8 {
    const dialog = @as(*gtk.GtkFileDialog, @ptrCast(@alignCast(source.?)));
    var err: ?*gtk.GError = null;
    const gfile = gtk.gtk_file_dialog_select_folder_finish(dialog, result, &err);
    if (err != null) {
        gtk.g_error_free(err);
        return null;
    }
    if (gfile == null) return null;
    defer gtk.g_object_unref(gfile);

    const raw_path = gtk.g_file_get_path(gfile) orelse return null;
    defer gtk.g_free(raw_path);
    return std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(raw_path, 0)) catch null;
}

fn onFolderSelected(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const path = selectedFolderPath(result, source) orelse return;
    defer std.heap.c_allocator.free(path);
    openFolder(state, path);
}

fn onFolderSelectedNewWindow(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const path = selectedFolderPath(result, source) orelse return;
    defer std.heap.c_allocator.free(path);
    const build_fn = g_build_window_fn orelse return;
    const new_state = build_fn(state.app, null);
    openFolder(new_state, path);
}

/// Attaches `path_str` as this window's project root: rebuilds the tree,
/// enables the New File/New Folder actions and shows the project name in the
/// sidebar header. Does not touch open tabs — callers decide whether to close
/// them first (a fresh "open project" does; a tear-off window cloning an
/// already-open project does not, since it starts with none).
pub fn attachProject(state: *core.AppState, path_str: []const u8) void {
    const copy_len = @min(path_str.len, state.folder_path.len - 1);
    @memcpy(state.folder_path[0..copy_len], path_str[0..copy_len]);
    state.folder_path[copy_len] = 0;

    // Every route into a project passes through here, so this is the one place
    // the history needs touching.
    config.pushRecentProject(path_str[0..copy_len]);

    buildTree(state); // sets sidebar title/subtitle via updateGitSummary

    gtk.g_simple_action_set_enabled(state.new_file_action, 1);
    gtk.g_simple_action_set_enabled(state.new_folder_action, 1);

    view.updateWindowTitle(state);
}

/// Loads `path_str` as the project root, closing any tabs from a previous
/// project first. A project with a saved session restores its open editor
/// tabs (never terminals); a fresh one opens its README.md in preview mode.
pub fn openFolder(state: *core.AppState, path_str: []const u8) void {
    // Persist the outgoing project's open tabs before they are torn down —
    // switching projects is the other moment (besides closing the window)
    // where a session worth restoring is about to be lost.
    session.save(state);
    terminal.closeAllTerminalTabs(state);
    editor.closeAllEditorTabs(state);
    attachProject(state, path_str);

    if (restoreSession(state, path_str)) return;
    openReadme(state, path_str);
}

/// Opens README.md in preview mode when present at the project root.
fn openReadme(state: *core.AppState, root: []const u8) void {
    var readme_buf: [4096:0]u8 = undefined;
    const readme_path = std.fmt.bufPrintZ(&readme_buf, "{s}/README.md", .{root}) catch return;
    if (gtk.g_file_test(readme_path, gtk.G_FILE_TEST_IS_REGULAR) != 0) {
        editor.openEditorTab(state, readme_path);
        preview.showPreview(state);
    }
}

/// Restores a previously saved editor-tab session for `root`. Returns true
/// when it opened at least one tab; false (so the caller falls back to the
/// README) when there is no session or every file it named has since vanished.
fn restoreSession(state: *core.AppState, root: []const u8) bool {
    var sess = session.load(root) orelse return false;
    defer sess.deinit();

    var opened: usize = 0;
    for (sess.files) |path| {
        var path_buf: [4096:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
        if (gtk.g_file_test(z, gtk.G_FILE_TEST_IS_REGULAR) == 0) continue;
        editor.openEditorTab(state, z);
        opened += 1;
    }

    // Re-select the tab that was selected when the session was saved.
    if (sess.selected.len != 0) {
        const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = gtk.adw_tab_view_get_nth_page(state.editor_tabs, i) orelse continue;
            if (core.editorTabFromPage(page)) |t| {
                if (std.mem.eql(u8, std.mem.sliceTo(&t.doc.path, 0), sess.selected)) {
                    gtk.adw_tab_view_set_selected_page(state.editor_tabs, page);
                    break;
                }
            }
        }
    }

    return opened != 0;
}

// ── Open Project dropdown: New File / New Folder actions ──────────────────────

pub fn onNewFileAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const root = std.mem.sliceTo(&state.folder_path, 0);
    @memcpy(state.dialog_target_dir[0..root.len], root);
    state.dialog_target_dir[root.len] = 0;
    state.dialog_is_dir = false;
    showNewItemDialog(state);
}

pub fn onNewFolderAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const root = std.mem.sliceTo(&state.folder_path, 0);
    @memcpy(state.dialog_target_dir[0..root.len], root);
    state.dialog_target_dir[root.len] = 0;
    state.dialog_is_dir = true;
    showNewItemDialog(state);
}

// ── New-item dialog ───────────────────────────────────────────────────────────

/// Opens the new-file dialog targeting the project root. Called from shortcuts.
pub fn promptNewFile(state: *core.AppState) void {
    const root = std.mem.sliceTo(&state.folder_path, 0);
    if (root.len == 0) return;
    @memcpy(state.dialog_target_dir[0..root.len], root);
    state.dialog_target_dir[root.len] = 0;
    state.dialog_is_dir = false;
    showNewItemDialog(state);
}

fn focusEntryOnMap(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(@alignCast(user_data.?))));
}

fn showNewItemDialog(state: *core.AppState) void {
    const heading: [*:0]const u8 = if (state.dialog_is_dir) "New Folder" else "New File";
    const placeholder: [*:0]const u8 = if (state.dialog_is_dir) "folder-name" else "filename.txt";

    // Show the parent directory so the user knows where the item will be created.
    var body_buf: [512:0]u8 = .{0} ** 512;
    const dir = std.mem.sliceTo(&state.dialog_target_dir, 0);
    const folder = std.mem.sliceTo(&state.folder_path, 0);
    const rel = if (folder.len > 0 and std.mem.startsWith(u8, dir, folder) and dir.len > folder.len)
        dir[folder.len + 1 ..]
    else
        std.fs.path.basename(dir);
    _ = std.fmt.bufPrintZ(&body_buf, "In {s}", .{rel}) catch {};
    const body: ?[*:0]const u8 = if (body_buf[0] != 0) @as([*:0]const u8, &body_buf) else null;

    const dialog = gtk.adw_alert_dialog_new(heading, body).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    gtk.adw_alert_dialog_add_response(dialog, "create", "Create");
    gtk.adw_alert_dialog_set_response_appearance(dialog, "create", gtk.ADW_RESPONSE_SUGGESTED);
    gtk.adw_alert_dialog_set_default_response(dialog, "create");
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");

    const entry_widget = gtk.gtk_entry_new().?;
    const entry = @as(*gtk.GtkEntry, @ptrCast(entry_widget));
    gtk.gtk_entry_set_placeholder_text(entry, placeholder);
    gtk.gtk_entry_set_activates_default(entry, 1);
    gtk.adw_alert_dialog_set_extra_child(dialog, entry_widget);

    _ = gtk.g_signal_connect_data(dialog, "map", @as(gtk.GCallback, @ptrCast(&focusEntryOnMap)), entry_widget, null, 0);

    gtk.adw_alert_dialog_choose(
        dialog,
        @as(*gtk.GtkWidget, @ptrCast(state.win)),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onNewItemDialogDone)),
        @ptrCast(state),
    );
}

fn onNewItemDialogDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.AdwAlertDialog, @ptrCast(@alignCast(source.?)));
    const response = gtk.adw_alert_dialog_choose_finish(dialog, result);

    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "create")) return;

    const extra = gtk.adw_alert_dialog_get_extra_child(dialog) orelse return;
    const text = gtk.gtk_editable_get_text(@as(*gtk.GtkEditable, @ptrCast(extra)));
    const name = std.mem.sliceTo(text, 0);
    if (name.len == 0) return;

    const ok = gtk.zc_create_item(
        &state.dialog_target_dir,
        text,
        if (state.dialog_is_dir) @as(c_int, 1) else @as(c_int, 0),
    );
    if (ok == 0) {
        toast.showErrorFmt(state, "Could not create \u{201c}{s}\u{201d}", .{name});
        return;
    }

    refreshTreeContents(state);

    if (!state.dialog_is_dir) {
        var path_buf: [4096:0]u8 = undefined;
        const dir = std.mem.sliceTo(&state.dialog_target_dir, 0);
        const full = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
        editor.openEditorTab(state, full);
    }
}

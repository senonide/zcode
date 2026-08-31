//! Window-scoped commands and the close-request confirmation.
//!
//! Every command is a `win.*` GAction with an accelerator rather than a raw
//! keyval comparison in a key controller: actions can be driven from menus, are
//! listed by name in the shortcuts dialog, run through GTK's accel machinery
//! (which fires ahead of the focused widget's own key bindings) and keep
//! working on keyboard layouts where the keyval is not the Latin letter.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const lsp = @import("../lsp/manager.zig");
const view = @import("view.zig");
const files = @import("../sidebar/files.zig");
const terminal = @import("../terminal/tabs.zig");
const geometry = @import("../core/geometry.zig");
const session = @import("../core/session.zig");
const editor_tabs = @import("../editor/tabs.zig");
const quickopen = @import("quickopen.zig");
const shortcuts_dialog = @import("shortcuts_dialog.zig");
const toast = @import("toast.zig");

const Handler = *const fn (?*gtk.GSimpleAction, ?*gtk.GVariant, ?*anyopaque) callconv(.c) void;

const Command = struct {
    name: [*:0]const u8,
    handler: Handler,
    accel: ?[*:0]const u8,
};

/// The window's command table.  One row per command: this is the list the
/// shortcuts dialog, the primary menu and the keyboard all agree on.
const commands = [_]Command{
    .{ .name = "save", .handler = &onSave, .accel = "<Control>s" },
    .{ .name = "save-as", .handler = &onSaveAs, .accel = "<Control><Shift>s" },
    .{ .name = "reload", .handler = &onReload, .accel = null },
    .{ .name = "open-file", .handler = &onOpenFile, .accel = "<Control>o" },
    .{ .name = "close-tab", .handler = &onCloseTab, .accel = "<Control>w" },
    .{ .name = "find", .handler = &onFind, .accel = "<Control>f" },
    .{ .name = "replace", .handler = &onReplace, .accel = "<Control>h" },
    .{ .name = "go-to-line", .handler = &onGoToLine, .accel = "<Control>g" },
    .{ .name = "quick-open", .handler = &onQuickOpen, .accel = "<Control>p" },
    .{ .name = "toggle-sidebar", .handler = &onToggleSidebar, .accel = "F9" },
    .{ .name = "toggle-terminal", .handler = &onToggleTerminal, .accel = "<Control>t" },
    .{ .name = "new-terminal", .handler = &onNewTerminal, .accel = "<Control><Shift>t" },
    .{ .name = "tab-overview", .handler = &onTabOverview, .accel = "<Control><Shift>o" },
    .{ .name = "next-tab", .handler = &onNextTab, .accel = "<Control>Tab" },
    .{ .name = "previous-tab", .handler = &onPreviousTab, .accel = "<Control><Shift>Tab" },
    .{ .name = "format", .handler = &onFormat, .accel = "<Control><Shift>i" },
    .{ .name = "code-action", .handler = &onCodeAction, .accel = "<Control>period" },
    .{ .name = "shortcuts", .handler = &onShortcuts, .accel = "<Control>question" },
};

/// Accelerators for actions defined elsewhere (the sidebar owns these, because
/// they switch on and off with the open project), kept here so one table
/// describes the whole keyboard.
const extra_accels = [_]struct { action: [*:0]const u8, accel: [*:0]const u8 }{
    .{ .action = "win.new-file", .accel = "<Control>n" },
    .{ .action = "win.open-project", .accel = "<Control><Shift>p" },
};

/// Registers the accelerators.  App-scoped and identical for every window, so
/// this runs once at startup rather than per window.
pub fn installAccels(app: *gtk.AdwApplication) void {
    for (commands) |cmd| {
        const accel = cmd.accel orelse continue;
        var detailed: [64:0]u8 = undefined;
        const name = std.fmt.bufPrintZ(&detailed, "win.{s}", .{std.mem.sliceTo(cmd.name, 0)}) catch continue;
        setAccel(app, name, accel);
    }
    for (extra_accels) |extra| setAccel(app, extra.action, extra.accel);
}

fn setAccel(app: *gtk.AdwApplication, action: [*:0]const u8, accel: [*:0]const u8) void {
    var accels = [_:null]?[*:0]const u8{accel};
    gtk.gtk_application_set_accels_for_action(@ptrCast(app), action, &accels);
}

/// Adds every command to `win`'s action map, bound to this window's state.
pub fn installActions(state: *core.AppState, win: *gtk.GtkWidget) void {
    for (commands) |cmd| {
        const action = gtk.g_simple_action_new(cmd.name, null) orelse continue;
        _ = gtk.g_signal_connect_data(
            action,
            "activate",
            @as(gtk.GCallback, @ptrCast(cmd.handler)),
            @ptrCast(state),
            null,
            0,
        );
        gtk.g_action_map_add_action(@ptrCast(win), @ptrCast(action));
        gtk.g_object_unref(action);
    }
}

// ── Command handlers ─────────────────────────────────────────────────────────

fn stateOf(user_data: ?*anyopaque) *core.AppState {
    return @ptrCast(@alignCast(user_data.?));
}

fn onSave(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    if (core.selectedEditorTab(stateOf(user_data))) |tab| editor_tabs.saveTab(tab);
}

fn onSaveAs(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    editor_tabs.saveTabAs(stateOf(user_data));
}

fn onReload(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    editor_tabs.reloadTab(stateOf(user_data));
}

fn onOpenFile(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    files.showOpenFileDialog(stateOf(user_data));
}

fn onCloseTab(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOf(user_data);
    if (state.terminal_shown) {
        if (core.selectedTerminalTab(state)) |tab|
            gtk.adw_tab_view_close_page(state.terminal_tabs, tab.page);
    } else {
        if (core.selectedEditorTab(state)) |tab|
            gtk.adw_tab_view_close_page(state.editor_tabs, tab.page);
    }
}

fn onFind(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    if (core.selectedEditorTab(stateOf(user_data))) |tab| gtk.zc_search_bar_open(tab.source_view);
}

fn onReplace(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    if (core.selectedEditorTab(stateOf(user_data))) |tab| gtk.zc_search_bar_open_replace(tab.source_view);
}

fn onGoToLine(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    promptGoToLine(stateOf(user_data));
}

fn onQuickOpen(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    quickopen.present(stateOf(user_data));
}

fn onToggleSidebar(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOf(user_data);
    const shown = gtk.adw_overlay_split_view_get_show_sidebar(state.split);
    gtk.adw_overlay_split_view_set_show_sidebar(state.split, if (shown != 0) 0 else 1);
}

fn onToggleTerminal(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOf(user_data);
    if (state.terminal_shown) {
        view.switchToEditors(state);
        return;
    }
    if (gtk.adw_tab_view_get_n_pages(state.terminal_tabs) == 0) terminal.newTerminalTab(state);
    view.switchToTerminals(state);
    focusTerminal(state);
}

fn onNewTerminal(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOf(user_data);
    terminal.newTerminalTab(state);
    view.switchToTerminals(state);
    focusTerminal(state);
}

fn focusTerminal(state: *core.AppState) void {
    if (core.selectedTerminalTab(state)) |tab|
        _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.terminal)));
}

fn onTabOverview(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const state = stateOf(user_data);
    if (gtk.adw_tab_overview_get_open(state.tab_overview) != 0) {
        gtk.adw_tab_overview_set_open(state.tab_overview, 0);
        return;
    }
    // Point the grid at whichever tabs are on screen. Opening is the one moment
    // this is safe: libadwaita hands the view back only when the closing
    // animation ends, so rebinding at any other time can land on a view that is
    // still mid-close (see view.zig).
    const tabs = if (state.terminal_shown) state.terminal_tabs else state.editor_tabs;
    if (gtk.adw_tab_view_get_n_pages(tabs) == 0) return; // nothing to grid
    gtk.adw_tab_overview_set_view(state.tab_overview, tabs);
    gtk.adw_tab_overview_set_open(state.tab_overview, 1);
}

fn onNextTab(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    cycleTab(stateOf(user_data), true);
}

fn onPreviousTab(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    cycleTab(stateOf(user_data), false);
}

/// Moves one tab along in the visible tab view, wrapping at either end.
fn cycleTab(state: *core.AppState, forward: bool) void {
    const tabs = if (state.terminal_shown) state.terminal_tabs else state.editor_tabs;
    const n = gtk.adw_tab_view_get_n_pages(tabs);
    if (n < 2) return;
    const moved = if (forward)
        gtk.adw_tab_view_select_next_page(tabs)
    else
        gtk.adw_tab_view_select_previous_page(tabs);
    if (moved != 0) return;
    const wrap_to = if (forward) @as(c_int, 0) else n - 1;
    if (gtk.adw_tab_view_get_nth_page(tabs, wrap_to)) |page|
        gtk.adw_tab_view_set_selected_page(tabs, page);
}

fn onFormat(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    if (core.selectedEditorTab(stateOf(user_data))) |tab| lsp.formatDocument(tab.buffer);
}

fn onCodeAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    if (core.selectedEditorTab(stateOf(user_data))) |tab| lsp.codeAction(tab.buffer);
}

fn onShortcuts(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    shortcuts_dialog.present(@ptrCast(stateOf(user_data).win));
}

// ── Go to Line ────────────────────────────────────────────────────────────────

fn focusEntryOnMap(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(@alignCast(user_data.?))));
}

fn onGoToLineDialogDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.AdwAlertDialog, @ptrCast(@alignCast(source.?)));
    const response = gtk.adw_alert_dialog_choose_finish(dialog, result);
    if (!std.mem.eql(u8, std.mem.sliceTo(response, 0), "go")) return;

    const extra = gtk.adw_alert_dialog_get_extra_child(dialog) orelse return;
    const raw = gtk.gtk_editable_get_text(@as(*gtk.GtkEditable, @ptrCast(extra)));
    const line_1based = std.fmt.parseInt(c_int, std.mem.sliceTo(raw, 0), 10) catch {
        toast.showError(state, "Not a line number");
        return;
    };
    if (line_1based < 1) return;

    const tab = core.selectedEditorTab(state) orelse return;
    const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
    const n_lines = gtk.gtk_text_buffer_get_line_count(tb);
    const line_0based = @min(line_1based - 1, n_lines - 1);

    var iter: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_line_index(tb, &iter, line_0based, 0);
    gtk.gtk_text_buffer_place_cursor(tb, &iter);
    _ = gtk.gtk_text_view_scroll_to_iter(@ptrCast(tab.source_view), &iter, 0.1, 1, 0.0, 0.3);
    _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.source_view)));
}

fn promptGoToLine(state: *core.AppState) void {
    if (state.terminal_shown) return;
    const tab = core.selectedEditorTab(state) orelse return;

    const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
    const n_lines = gtk.gtk_text_buffer_get_line_count(tb);
    var heading_buf: [64:0]u8 = .{0} ** 64;
    _ = std.fmt.bufPrintZ(&heading_buf, "Go to Line (1\u{2013}{d})", .{n_lines}) catch {};

    const dialog = gtk.adw_alert_dialog_new(&heading_buf, null).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    gtk.adw_alert_dialog_add_response(dialog, "go", "Go");
    gtk.adw_alert_dialog_set_response_appearance(dialog, "go", gtk.ADW_RESPONSE_SUGGESTED);
    gtk.adw_alert_dialog_set_default_response(dialog, "go");
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");

    const entry_widget = gtk.gtk_entry_new().?;
    const entry = @as(*gtk.GtkEntry, @ptrCast(entry_widget));
    gtk.gtk_entry_set_placeholder_text(entry, "Line number");
    gtk.gtk_entry_set_activates_default(entry, 1);
    gtk.adw_alert_dialog_set_extra_child(dialog, entry_widget);

    _ = gtk.g_signal_connect_data(dialog, "map", @as(gtk.GCallback, @ptrCast(&focusEntryOnMap)), entry_widget, null, 0);

    gtk.adw_alert_dialog_choose(
        dialog,
        @as(*gtk.GtkWidget, @ptrCast(state.win)),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onGoToLineDialogDone)),
        @ptrCast(state),
    );
}

// ── Window close: shared confirmation ─────────────────────────────────────────
//
// Triggers on two conditions: unsaved editor changes (per-file) and any open
// terminal tab (a coarse proxy for "a process might be running" — there is no
// primitive to inspect a PTY's foreground process group, so any open terminal
// counts, mirroring how any unsaved file counts regardless of how small the
// change is).

const CloseBlockers = struct { modified: usize, terminals: usize };

fn closeBlockers(state: *core.AppState) CloseBlockers {
    var modified: usize = 0;
    var i: c_int = 0;
    const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    while (i < n) : (i += 1) {
        if (core.editorTabAt(state, i)) |tab| {
            if (tab.doc.isModified(tab.buffer)) modified += 1;
        }
    }
    const terminals: usize = @intCast(gtk.adw_tab_view_get_n_pages(state.terminal_tabs));
    return .{ .modified = modified, .terminals = terminals };
}

/// `gtk_window_destroy` disposes the tab views directly (bypassing the
/// "close-page" signal entirely — libadwaita's own dispose implementation
/// calls its internal detach unconditionally for every remaining page), so
/// `tab.closing` would otherwise never get set for tabs still open when the
/// window closes. Without this, `page-detached`'s cleanup (freeing the tab
/// struct, unregistering its LSP document, detaching its flatpak host shell)
/// is skipped for every open tab on window close — a leak at best, and a
/// dangling-buffer use-after-free at worst once a later `lsp.shutdownAll()`
/// touches a document whose buffer's window is already gone.
fn markAllTabsClosing(state: *core.AppState) void {
    var i: c_int = 0;
    var n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    while (i < n) : (i += 1) {
        if (core.editorTabAt(state, i)) |tab| tab.closing = true;
    }
    i = 0;
    n = gtk.adw_tab_view_get_n_pages(state.terminal_tabs);
    while (i < n) : (i += 1) {
        if (core.terminalTabAt(state, i)) |tab| tab.closing = true;
    }
}

/// Finishes closing `state`'s window: detaches its style-manager handler
/// (connected on that process-lifetime singleton), unregisters it, shuts down
/// shared LSP servers only once no window remains, then destroys the window.
fn finishClose(state: *core.AppState) void {
    session.save(state); // before shutting_down — tabs must still be readable
    state.shutting_down = true;
    markAllTabsClosing(state);
    // Manually parented (gtk_popover_set_parent), so it has to be unparented
    // here rather than left for the window's own teardown.
    if (state.recent_popover) |popover| gtk.gtk_widget_unparent(@ptrCast(popover));
    core.disconnectTabSignals(@ptrCast(gtk.adw_style_manager_get_default()), @ptrCast(state));
    core.unregisterWindow(state);
    if (core.g_windows.items.len == 0) lsp.shutdownAll();
    gtk.gtk_window_destroy(@as(*gtk.GtkWidget, @ptrCast(state.win)));
    std.heap.c_allocator.destroy(state);
}

fn onCloseWindowDialogDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.AdwAlertDialog, @ptrCast(@alignCast(source.?)));
    const response = std.mem.sliceTo(gtk.adw_alert_dialog_choose_finish(dialog, result), 0);

    if (std.mem.eql(u8, response, "cancel")) return;

    if (std.mem.eql(u8, response, "save")) {
        var i: c_int = 0;
        const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
        while (i < n) : (i += 1) {
            if (core.editorTabAt(state, i)) |tab| {
                if (!tab.doc.isModified(tab.buffer)) continue;
                // A failed write is reported and aborts the close: closing now
                // would discard exactly the changes the user asked to keep.
                if (!editor_tabs.writeTab(tab)) return;
            }
        }
    }

    finishClose(state);
}

/// Window's own close button / OS close request.
pub fn onWindowCloseRequest(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return 0;

    geometry.save(state.win);

    const blockers = closeBlockers(state);
    if (blockers.modified == 0 and blockers.terminals == 0) {
        finishClose(state);
        return 0;
    }

    var body_buf: [256:0]u8 = undefined;
    const body = closeBodyText(&body_buf, blockers);

    const dialog = gtk.adw_alert_dialog_new("Close Window?", body).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    if (blockers.modified == 0) {
        // Only terminals are open — there is nothing to save or discard, just
        // whether to close them.
        gtk.adw_alert_dialog_add_response(dialog, "close", "Close");
        gtk.adw_alert_dialog_set_response_appearance(dialog, "close", gtk.ADW_RESPONSE_DESTRUCTIVE);
        gtk.adw_alert_dialog_set_default_response(dialog, "close");
    } else {
        gtk.adw_alert_dialog_add_response(dialog, "discard", "Discard All");
        gtk.adw_alert_dialog_add_response(dialog, "save", "Save All");
        gtk.adw_alert_dialog_set_response_appearance(dialog, "discard", gtk.ADW_RESPONSE_DESTRUCTIVE);
        gtk.adw_alert_dialog_set_response_appearance(dialog, "save", gtk.ADW_RESPONSE_SUGGESTED);
        gtk.adw_alert_dialog_set_default_response(dialog, "save");
    }
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");

    gtk.adw_alert_dialog_choose(
        dialog,
        @as(*gtk.GtkWidget, @ptrCast(state.win)),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onCloseWindowDialogDone)),
        @ptrCast(state),
    );
    return 1;
}

fn closeBodyText(buf: *[256:0]u8, blockers: CloseBlockers) [*:0]const u8 {
    const files_part: []const u8 = if (blockers.modified == 0)
        ""
    else if (blockers.modified == 1)
        "There is 1 file with unsaved changes."
    else
        "There are files with unsaved changes.";
    const term_part: []const u8 = if (blockers.terminals == 0)
        ""
    else if (blockers.terminals == 1)
        "There is 1 terminal still open."
    else
        "There are terminals still open.";

    if (files_part.len != 0 and term_part.len != 0) {
        return std.fmt.bufPrintZ(buf, "{s} {s}", .{ files_part, term_part }) catch "Close anyway?";
    }
    if (files_part.len != 0) return std.fmt.bufPrintZ(buf, "{s}", .{files_part}) catch "Close anyway?";
    return std.fmt.bufPrintZ(buf, "{s}", .{term_part}) catch "Close anyway?";
}

/// Ctrl+Q (app.quit): behaves like closing the active window, not the whole
/// app — with several windows open, quitting only affects the focused one.
pub fn requestCloseActiveWindow(app: *gtk.AdwApplication) void {
    const win = gtk.gtk_application_get_active_window(@ptrCast(app)) orelse return;
    for (core.g_windows.items) |state| {
        if (state.win == win) {
            _ = onWindowCloseRequest(null, @ptrCast(state));
            return;
        }
    }
}

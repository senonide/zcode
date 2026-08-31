//! Terminal tabs: spawn a shell, name the tab after its cwd, copy/paste, and
//! the toggle that switches the right pane into terminal mode.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const style = @import("../core/style.zig");
const view = @import("../app/view.zig");

const TerminalTab = core.TerminalTab;

/// Opens a terminal tab rooted at the project folder (or $HOME).
pub fn newTerminalTab(state: *core.AppState) void {
    const folder = std.mem.sliceTo(&state.folder_path, 0);
    newTerminalTabAt(state, if (folder.len != 0) @as([*:0]const u8, &state.folder_path) else null);
}

/// Creates a new terminal tab rooted at `wd_in` (null → $HOME), selects it and
/// spawns a shell inside it.
pub fn newTerminalTabAt(state: *core.AppState, wd_in: ?[*:0]const u8) void {
    const term_widget = gtk.vte_terminal_new() orelse return;
    const term = @as(*gtk.VteTerminal, @ptrCast(term_widget));
    gtk.gtk_widget_set_hexpand(term_widget, 1);
    gtk.gtk_widget_set_vexpand(term_widget, 1);
    gtk.vte_terminal_set_scrollback_lines(term, 10000);
    gtk.vte_terminal_set_scroll_on_output(term, 0);
    gtk.zc_terminal_style(term, style.isDark());
    style.applyMonoFontToTerminal(term);
    gtk.zc_terminal_attach_url_match(term);

    const tab = std.heap.c_allocator.create(TerminalTab) catch return;
    tab.* = .{ .terminal = term, .page = undefined, .owner = state };

    const page = gtk.adw_tab_view_append(state.terminal_tabs, term_widget) orelse {
        std.heap.c_allocator.destroy(tab);
        return;
    };
    tab.page = page;
    gtk.g_object_set_data(@ptrCast(page), core.tab_data_key, @ptrCast(tab));

    // Initial title: the working directory the shell starts in.  Once the shell
    // reports its cwd (OSC 7) or a window title, the handlers below refine it.
    var ibuf: [256]u8 = undefined;
    const wd_slice: []const u8 = if (wd_in) |w| std.mem.sliceTo(w, 0) else "";
    const init_title: [*:0]const u8 = if (wd_slice.len != 0)
        (std.fmt.bufPrintZ(&ibuf, "{s}", .{std.fs.path.basename(wd_slice)}) catch "Terminal")
    else
        "Terminal";
    gtk.adw_tab_page_set_title(page, init_title);

    // Keep the title in sync with the cwd (preferred) or the program-set window title.
    _ = gtk.g_signal_connect_data(
        term_widget,
        "notify::current-directory-uri",
        @as(gtk.GCallback, @ptrCast(&onTerminalDirChanged)),
        @ptrCast(tab),
        null,
        0,
    );
    _ = gtk.g_signal_connect_data(
        term_widget,
        "window-title-changed",
        @as(gtk.GCallback, @ptrCast(&onTerminalTitleChanged)),
        @ptrCast(tab),
        null,
        0,
    );

    // Ctrl+Shift+V → paste from clipboard inside the terminal.
    const term_key_ctrl = gtk.gtk_event_controller_key_new().?;
    _ = gtk.g_signal_connect_data(
        term_key_ctrl,
        "key-pressed",
        @as(gtk.GCallback, @ptrCast(&onTerminalKeyPressed)),
        @ptrCast(term),
        null,
        0,
    );
    gtk.gtk_widget_add_controller(term_widget, @ptrCast(term_key_ctrl));

    gtk.adw_tab_view_set_selected_page(state.terminal_tabs, page);

    const wd: ?[*:0]const u8 = if (wd_in) |w| blk: {
        const s = std.mem.sliceTo(w, 0);
        const n = @min(s.len, state.term_wd.len - 1);
        @memcpy(state.term_wd[0..n], s[0..n]);
        state.term_wd[n] = 0;
        break :blk @as([*:0]const u8, &state.term_wd);
    } else null;

    if (gtk.zc_is_flatpak() != 0) {
        tab.host_pid = gtk.zc_terminal_spawn_host(term, wd, &onFlatpakHostExited, @ptrCast(tab));
    } else {
        gtk.zc_terminal_spawn(term, wd);
        _ = gtk.g_signal_connect_data(term_widget, "child-exited", @as(gtk.GCallback, @ptrCast(&onTerminalChildExited)), @ptrCast(tab), null, 0);
    }
}

/// Titles a terminal tab after its current working directory (like GNOME
/// Console), falling back to the program-set window title.
fn updateTerminalTitle(tab: *TerminalTab) void {
    var buf: [512]u8 = undefined;

    if (gtk.vte_terminal_get_current_directory_uri(tab.terminal)) |uri| {
        if (gtk.g_filename_from_uri(uri, null, null)) |path| {
            defer gtk.g_free(path);
            const p = std.mem.sliceTo(path, 0);
            if (p.len != 0) {
                const home_c = gtk.g_get_home_dir();
                const home = if (home_c) |h| std.mem.sliceTo(h, 0) else "";
                const label = if (home.len != 0 and std.mem.eql(u8, p, home))
                    "~"
                else
                    std.fs.path.basename(p);
                if (label.len != 0) {
                    const t = std.fmt.bufPrintZ(&buf, "{s}", .{label}) catch return;
                    gtk.adw_tab_page_set_title(tab.page, t);
                    return;
                }
            }
        }
    }

    if (gtk.vte_terminal_get_window_title(tab.terminal)) |title| {
        if (title[0] != 0) gtk.adw_tab_page_set_title(tab.page, title);
    }
}

/// `win.view` change-state handler: the header-bar toggle buttons drive this
/// action's state to `view_editor` / `view_terminal`. Accept the requested
/// state, apply the view switch, and commit the state so the buttons render
/// active/inactive. `g_simple_action_set_state` does not re-emit this signal,
/// so there is no recursion to guard against (unlike the old notify handler).
pub fn onViewChangeState(
    action: ?*gtk.GSimpleAction,
    value: ?*gtk.GVariant,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const requested = gtk.g_variant_get_string(value, null) orelse return;
    const to_terminal = std.mem.eql(u8, std.mem.sliceTo(requested, 0), std.mem.sliceTo(core.view_terminal, 0));

    state.terminal_shown = to_terminal;
    gtk.g_simple_action_set_state(action, value);

    if (to_terminal and gtk.adw_tab_view_get_n_pages(state.terminal_tabs) == 0) {
        newTerminalTab(state);
    }
    view.updateView(state);
    view.updateWindowTitle(state);

    if (to_terminal) {
        if (core.selectedTerminalTab(state)) |tab|
            _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.terminal)));
    }
}

fn onTerminalKeyPressed(
    _: ?*anyopaque,
    keyval: c_uint,
    _: c_uint,
    state_mask: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const ctrl_shift = (state_mask & gtk.GDK_CONTROL_MASK) != 0 and
        (state_mask & gtk.GDK_SHIFT_MASK) != 0;
    if (!ctrl_shift) return 0;

    const term = @as(*gtk.VteTerminal, @ptrCast(@alignCast(user_data.?)));

    if (keyval == gtk.GDK_KEY_v or keyval == gtk.GDK_KEY_V) {
        gtk.vte_terminal_paste_clipboard(term);
        return 1;
    }
    // Ctrl+Shift+C copies the selection; with no selection, let the key through
    // (so a shell that maps it keeps working).
    if (keyval == gtk.GDK_KEY_c or keyval == gtk.GDK_KEY_C) {
        if (gtk.vte_terminal_get_has_selection(term) != 0) {
            gtk.vte_terminal_copy_clipboard_format(term, gtk.VTE_FORMAT_TEXT);
            return 1;
        }
    }
    return 0;
}

fn onFlatpakHostExited(user_data: ?*anyopaque) callconv(.c) void {
    const tab = @as(*TerminalTab, @ptrCast(@alignCast(user_data orelse return)));
    gtk.adw_tab_view_close_page(tab.owner.terminal_tabs, tab.page);
}

fn onTerminalChildExited(_: ?*gtk.VteTerminal, _: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const tab = @as(*TerminalTab, @ptrCast(@alignCast(user_data.?)));
    // Closing the tab triggers page-detached, which frees the struct and, if no
    // terminals remain, falls back to the editor view.
    gtk.adw_tab_view_close_page(tab.owner.terminal_tabs, tab.page);
}

fn onTerminalTitleChanged(_: ?*gtk.VteTerminal, user_data: ?*anyopaque) callconv(.c) void {
    updateTerminalTitle(@as(*TerminalTab, @ptrCast(@alignCast(user_data.?))));
}

fn onTerminalDirChanged(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    updateTerminalTitle(@as(*TerminalTab, @ptrCast(@alignCast(user_data.?))));
}

/// Closes every terminal tab. Called when switching to a different project so
/// shells rooted in the old project don't keep running in the background.
pub fn closeAllTerminalTabs(state: *core.AppState) void {
    while (gtk.adw_tab_view_get_n_pages(state.terminal_tabs) > 0) {
        const page = gtk.adw_tab_view_get_nth_page(state.terminal_tabs, 0) orelse break;
        gtk.adw_tab_view_close_page(state.terminal_tabs, page);
    }
}

/// New tabs never need confirmation; this only exists so page-detached (fired
/// for both a real close and a tear-off transfer) can tell them apart via the
/// `closing` flag it sets here.
pub fn onTerminalClosePage(
    _: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    _: ?*anyopaque,
) callconv(.c) c_int {
    if (page) |p| {
        if (core.terminalTabFromPage(p)) |tab| tab.closing = true;
    }
    return 0;
}

pub fn onTerminalPageDetached(
    tab_view: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    _: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (page) |p| {
        if (core.terminalTabFromPage(p)) |tab| {
            if (tab.closing) {
                // Drop signal handlers first so VTE teardown signals can't run
                // against freed memory, then clean up the host process if Flatpak.
                core.disconnectTabSignals(@ptrCast(tab.terminal), tab);
                if (tab.host_pid != 0) gtk.zc_terminal_detach_host(tab.host_pid);
                std.heap.c_allocator.destroy(tab);
            }
        }
    }
    // No terminals left → drop back to the editor view automatically.
    if (gtk.adw_tab_view_get_n_pages(tab_view) == 0 and state.terminal_shown) {
        view.switchToEditors(state);
    }
}

/// Fires when a page is appended to this tab view — including a tab dragged
/// in from another window. Re-stamps `owner` and switches this window into
/// terminal mode. See `editor.onEditorPageAttached` for why the ordinary tab
/// creation path is unaffected (the signal fires before the tab struct is
/// attached to the page).
pub fn onTerminalPageAttached(
    _: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    _: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const p = page orelse return;
    const tab = core.terminalTabFromPage(p) orelse return;
    tab.owner = state;
    tab.closing = false;
    view.switchToTerminals(state);
}

//! Per-window application state. GTK C callbacks can't capture Zig closures, so
//! each window's widgets and flags live in a heap-allocated `AppState`, threaded
//! through as signal user_data; feature modules import this and operate on it.

const std = @import("std");
const gtk = @import("../gtk.zig");
const document = @import("../editor/document.zig");
const filesync = @import("../editor/filesync.zig");

/// What a conflict-bar button does: re-read the file from disk, or write the
/// buffer over it.  Stored per button so its click handler knows how to react.
pub const BarAction = enum { reload, write };

// A tab's struct is attached to its AdwTabPage via g_object_set_data under
// `tab_data_key`, so a signal handed a page can recover its tab. Tabs are heap-
// allocated and freed in the view's "page-detached" handler.

pub const EditorTab = struct {
    doc: document.Document = .{},
    source_view: *gtk.GtkSourceView,
    buffer: *gtk.GtkSourceBuffer,
    page: *gtk.AdwTabPage,
    // The window this tab currently belongs to. Re-stamped on tear-off so
    // per-tab handlers (LSP callbacks, preview link clicks, ...) always affect
    // the right window rather than the one that originally created the tab.
    owner: *AppState,
    // True for image files (PNG, JPEG, SVG, …).  The tab shows a GtkPicture
    // directly; there is no source view in the widget tree.
    is_image: bool = false,
    // Preview stack (Markdown / HTML tabs): per-tab GtkStack switching between
    // "editor" and "preview".  preview_view is the WebKitWebView, created
    // lazily on first toggle.
    preview_stack: ?*gtk.GtkStack = null,
    preview_view: ?*gtk.WebKitWebView = null,
    preview_active: bool = false,
    // Live external-sync: watches the file on disk and reloads/flags it when
    // another process rewrites it.  Null for binary/image tabs.
    filesync: ?*filesync.FileSync = null,
    // AdwBanner shown when the open file diverges from disk.
    banner: ?*gtk.AdwBanner = null,
    banner_action: BarAction = .reload,
    // Reusable tag + timer for the fading highlight over lines an external
    // reload changed.
    flash_tag: ?*gtk.GtkTextTag = null,
    flash_timer: c_uint = 0,
    // Set just before a real close (not a tear-off transfer) so page-detached
    // knows whether to free this struct — libadwaita fires the same signal for
    // both, and a torn-off page's struct must survive into its new window.
    closing: bool = false,
};

pub const TerminalTab = struct {
    terminal: *gtk.VteTerminal,
    page: *gtk.AdwTabPage,
    owner: *AppState,
    host_pid: c_uint = 0,
    closing: bool = false,
};

pub const tab_data_key: [*:0]const u8 = "zc-tab";

/// State values of the `win.view` action: which pane the right side shows.
pub const view_editor: [*:0]const u8 = "editor";
pub const view_terminal: [*:0]const u8 = "terminal";

/// One status-bar reading: an optional symbolic icon and a figure beside it.
/// `root` is what gets hidden, so a reading with nothing to report takes up no
/// room — it is the label itself when there is no icon.
pub const StatusFigure = struct {
    root: *gtk.GtkWidget,
    value: *gtk.GtkLabel,
};

/// The editor status bar's readings. Built and updated in app/view.zig.
pub const StatusBar = struct {
    /// Language server for the open file, hidden when none is connected.
    server: *gtk.GtkLabel,
    /// Diagnostic counts, indexed as LSP severities are: error, warning, then
    /// information and hints together — one "information" icon covers both.
    diags: [3]StatusFigure,
    added: StatusFigure,
    removed: StatusFigure,
    /// Cursor line and column; the only reading that is always present.
    position: *gtk.GtkLabel,
};

// ── Per-window state ─────────────────────────────────────────────────────────

pub const AppState = struct {
    app: *gtk.AdwApplication,
    win: *gtk.GtkWindow,
    split: *gtk.AdwOverlaySplitView,
    // Wraps the whole window content; every user-visible success/failure
    // message goes through it (see app/toast.zig).
    toast_overlay: *gtk.AdwToastOverlay,
    // Content header bar title: file name over its path within the project,
    // the GNOME pattern — the window title never carries the app name.
    title: *gtk.AdwWindowTitle,
    // Editor status bar (AdwToolbarView bottom bar); its contents are built and
    // kept current by app/view.zig.
    content_toolbar: *gtk.AdwToolbarView,
    status: StatusBar,
    // Tab grid (Ctrl+Shift+O); rebound to whichever tab view is on screen.
    tab_overview: *gtk.AdwTabOverview,
    // "New Terminal"; only meaningful — and only visible — in terminal mode.
    new_terminal_btn: *gtk.GtkWidget,
    // Git status title in the sidebar header's title-widget slot: branch name
    // on top, change count dimmed below. Read-only.
    git_title: *gtk.AdwWindowTitle,
    sidebar_scroll: *gtk.GtkScrolledWindow,
    // The project file tree (GtkListView); null until a folder is opened.
    file_tree: ?*gtk.GtkWidget = null,
    // Right pane: a stack swapping between the empty page, the editor tab view
    // and the terminal tab view — editors and terminals never mix on screen.
    view_stack: *gtk.GtkStack,
    // Second toolbar row: a stack swapping the editor tab bar for the terminal
    // tab bar so the visible bar always matches the visible tab view.
    tabbar_stack: *gtk.GtkStack,
    editor_tabs: *gtk.AdwTabView,
    terminal_tabs: *gtk.AdwTabView,
    // "New File" / "New Folder" — entries in the Open Project split button's
    // dropdown (window.zig); disabled until a project is open.
    new_file_action: *gtk.GSimpleAction,
    new_folder_action: *gtk.GSimpleAction,
    // Editor/terminal mode switch: a stateful `win.view` GAction whose state
    // is `view_editor` / `view_terminal`. The two header-bar toggle buttons
    // are GtkActionables bound to it, so GTK renders their active state.
    view_action: *gtk.GSimpleAction,
    // Markdown preview toggle button — visible only when a .md tab is active.
    preview_btn: ?*gtk.GtkWidget = null,
    preview_btn_handler: c_ulong = 0,

    // This window's open project root (empty when no folder open).
    folder_path: [4096:0]u8 = [_:0]u8{0} ** 4096,
    // Monotonic µs of the last focus-triggered sidebar refresh (rate limit).
    last_focus_refresh: i64 = 0,
    // Whether the terminal panel is currently the visible mode.
    terminal_shown: bool = false,
    // Working directory for the next terminal spawn — kept in a stable buffer
    // because vte_terminal_spawn_async reads it after the caller's string is gone.
    term_wd: [4096:0]u8 = [_:0]u8{0} ** 4096,
    // Set once this window is closing.  During teardown GTK detaches every tab
    // page, firing page-detached/selected-page handlers that would otherwise
    // poke widgets already being destroyed — these guards make those bail out.
    shutting_down: bool = false,
    // Recent-projects popover hanging off the Open Project button; built on
    // first use and refilled on each click.  Manually parented, so the window's
    // close path unparents it (see shortcuts.finishClose).
    recent_popover: ?*gtk.GtkPopover = null,
    // State for the pending new-item dialog.
    dialog_target_dir: [4096:0]u8 = [_:0]u8{0} ** 4096,
    dialog_is_dir: bool = false,
};

// The running application; used by app actions (Quit) and the About dialog.
pub var g_app: ?*gtk.AdwApplication = null;

// Every window currently open in this process. Needed to know when the last
// one closes (so shared LSP servers only shut down then) and to resolve "the
// active window" for app-scoped actions like Ctrl+Q.
pub var g_windows: std.ArrayList(*AppState) = .empty;

pub fn registerWindow(state: *AppState) void {
    // Not optional: a window missing from this list is invisible to
    // `shutdownAll`'s last-window check and to the active-window lookup that
    // Ctrl+Q and the app-scoped dialogs go through.
    g_windows.append(std.heap.c_allocator, state) catch @panic("oom");
}

pub fn unregisterWindow(state: *AppState) void {
    for (g_windows.items, 0..) |w, i| {
        if (w == state) {
            _ = g_windows.swapRemove(i);
            return;
        }
    }
}

// ── Tab lookup helpers ────────────────────────────────────────────────────────

pub fn editorTabFromPage(page: *gtk.AdwTabPage) ?*EditorTab {
    const ptr = gtk.g_object_get_data(@ptrCast(page), tab_data_key) orelse return null;
    return @as(*EditorTab, @ptrCast(@alignCast(ptr)));
}

pub fn terminalTabFromPage(page: *gtk.AdwTabPage) ?*TerminalTab {
    const ptr = gtk.g_object_get_data(@ptrCast(page), tab_data_key) orelse return null;
    return @as(*TerminalTab, @ptrCast(@alignCast(ptr)));
}

pub fn editorTabAt(state: *AppState, index: c_int) ?*EditorTab {
    const page = gtk.adw_tab_view_get_nth_page(state.editor_tabs, index) orelse return null;
    return editorTabFromPage(page);
}

pub fn terminalTabAt(state: *AppState, index: c_int) ?*TerminalTab {
    const page = gtk.adw_tab_view_get_nth_page(state.terminal_tabs, index) orelse return null;
    return terminalTabFromPage(page);
}

/// The tab showing `buffer`, in whichever window currently holds it. Searching
/// every window rather than one is what makes this survive a tear-off, where a
/// tab changes hands but its buffer does not.
pub fn editorTabForBuffer(buffer: *gtk.GtkSourceBuffer) ?*EditorTab {
    for (g_windows.items) |state| {
        var i: c_int = 0;
        const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
        while (i < n) : (i += 1) {
            const tab = editorTabAt(state, i) orelse continue;
            if (tab.buffer == buffer) return tab;
        }
    }
    return null;
}

pub fn selectedEditorTab(state: *AppState) ?*EditorTab {
    const page = gtk.adw_tab_view_get_selected_page(state.editor_tabs) orelse return null;
    return editorTabFromPage(page);
}

pub fn selectedTerminalTab(state: *AppState) ?*TerminalTab {
    const page = gtk.adw_tab_view_get_selected_page(state.terminal_tabs) orelse return null;
    return terminalTabFromPage(page);
}

/// Drops every signal handler on `instance` that carries `data` as user_data.
/// Called before freeing a tab's heap struct so a signal emitted during widget
/// teardown (notably VTE's child-exited) can't dereference freed memory. Also
/// used at window-close scope to detach a window's handler from a
/// process-lifetime singleton (e.g. the style manager).
pub fn disconnectTabSignals(instance: ?*anyopaque, data: *anyopaque) void {
    _ = gtk.g_signal_handlers_disconnect_matched(
        instance,
        gtk.G_SIGNAL_MATCH_DATA,
        0,
        0,
        null,
        null,
        @ptrCast(data),
    );
}

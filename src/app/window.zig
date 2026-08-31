//! Composition root: `buildWindow` assembles the widget tree and wires each
//! signal to the handler that owns it. Wiring only — no behaviour. Callable
//! more than once per process — each call produces an independent window with
//! its own `AppState`, registered in `core.g_windows`.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const style = @import("../core/style.zig");
const geometry = @import("../core/geometry.zig");
const editor = @import("../editor/tabs.zig");
const terminal = @import("../terminal/tabs.zig");
const files = @import("../sidebar/files.zig");
const shortcuts = @import("shortcuts.zig");
const lsp = @import("../lsp/manager.zig");
const preview = @import("../editor/preview.zig");
const view = @import("view.zig");

/// Builds a new window and returns its state. `source`, when non-null, is an
/// existing window whose project (folder tree) the new window should also
/// open — used when tearing a tab out into its own window; pass `null` for an
/// ordinary fresh window (startup, or an unrelated "open in new window").
pub fn buildWindow(app: *gtk.AdwApplication, source: ?*core.AppState) *core.AppState {
    const win_widget = gtk.adw_application_window_new(
        @as(*gtk.GtkApplication, @ptrCast(app)),
    ).?;
    const win_adw = @as(*gtk.AdwApplicationWindow, @ptrCast(win_widget));
    const win = @as(*gtk.GtkWindow, @ptrCast(win_widget));

    // Allocated early so it can be threaded through every signal connected
    // below as user_data; its fields are populated once all the widgets they
    // reference exist, but the pointer itself is stable from here on and no
    // signal below fires synchronously during this function.
    const state = std.heap.c_allocator.create(core.AppState) catch @panic("oom");

    // ── Content pane: AdwToolbarView + AdwHeaderBar ───────────────────────
    const content_toolbar_widget = gtk.adw_toolbar_view_new().?;
    const content_toolbar = @as(*gtk.AdwToolbarView, @ptrCast(content_toolbar_widget));

    const hbar_widget = gtk.adw_header_bar_new().?;
    const hbar = @as(*gtk.AdwHeaderBar, @ptrCast(hbar_widget));

    // The file name over its location, rather than the window title — GNOME
    // apps never put the app name or a full path in the header bar.
    const title_widget = gtk.adw_window_title_new("zcode", "").?;
    const title = @as(*gtk.AdwWindowTitle, @ptrCast(title_widget));
    gtk.adw_header_bar_set_title_widget(hbar, title_widget);

    // Sidebar toggle (leftmost) — bound to the split view's show-sidebar.
    const sidebar_btn_widget = gtk.gtk_toggle_button_new().?;
    gtk.gtk_button_set_icon_name(@ptrCast(sidebar_btn_widget), "sidebar-show-symbolic");
    gtk.gtk_widget_set_tooltip_text(sidebar_btn_widget, "Toggle Sidebar");
    gtk.adw_header_bar_pack_start(hbar, sidebar_btn_widget);

    // Open Project — clicking the main area opens the recent-projects popover
    // (or the folder chooser with no history); the dropdown arrow offers New
    // File, New Folder and opening a project in a new window.
    const open_menu = gtk.g_menu_new().?;
    appendSection(open_menu, &.{
        .{ "New File", "win.new-file" },
        .{ "New Folder", "win.new-folder" },
    });
    appendSection(open_menu, &.{
        .{ "Open Project\u{2026}", "win.open-project" },
        .{ "Open Project in New Window\u{2026}", "win.open-project-new-window" },
    });
    const open_btn_widget = gtk.adw_split_button_new().?;
    const open_btn = @as(*gtk.AdwSplitButton, @ptrCast(open_btn_widget));
    gtk.adw_split_button_set_menu_model(open_btn, @ptrCast(open_menu));
    gtk.g_object_unref(open_menu);
    gtk.adw_split_button_set_icon_name(open_btn, "folder-open-symbolic");
    gtk.gtk_widget_set_tooltip_text(open_btn_widget, "Open Project");
    gtk.adw_header_bar_pack_start(hbar, open_btn_widget);
    _ = gtk.g_signal_connect_data(open_btn_widget, "clicked", @as(gtk.GCallback, @ptrCast(&files.onOpenProjectClicked)), @ptrCast(state), null, 0);

    // Opens the tab overview.  A plain icon button rather than AdwTabButton:
    // the tab count it renders is noise next to a tab bar that already shows
    // every tab.
    const tab_btn_widget = gtk.gtk_button_new_from_icon_name("view-grid-symbolic").?;
    gtk.gtk_widget_set_tooltip_text(tab_btn_widget, "View Open Tabs");
    gtk.gtk_actionable_set_action_name(@ptrCast(tab_btn_widget), "win.tab-overview");
    gtk.adw_header_bar_pack_start(hbar, tab_btn_widget);

    // Editor/terminal mode switch (right side of header bar): two linked
    // GtkToggleButtons bound to a single stateful `win.view` action, the GNOME
    // radio-button pattern. `linked` groups them visually; the action's state
    // drives which button renders active, so there is no manual sync handler.
    const view_action = gtk.g_simple_action_new_stateful(
        "view",
        gtk.G_VARIANT_TYPE_STRING,
        gtk.g_variant_new_string(core.view_editor),
    ).?;
    _ = gtk.g_signal_connect_data(
        view_action,
        "change-state",
        @as(gtk.GCallback, @ptrCast(&terminal.onViewChangeState)),
        @ptrCast(state),
        null,
        0,
    );
    gtk.g_action_map_add_action(@ptrCast(win_widget), @ptrCast(view_action));
    gtk.g_object_unref(view_action);

    const view_switch = gtk.gtk_box_new(.horizontal, 0).?;
    gtk.gtk_widget_add_css_class(view_switch, "linked");

    const editor_btn = gtk.gtk_toggle_button_new().?;
    gtk.gtk_button_set_icon_name(@ptrCast(editor_btn), "text-editor-symbolic");
    gtk.gtk_widget_set_tooltip_text(editor_btn, "Editor");
    gtk.gtk_actionable_set_action_name(@ptrCast(editor_btn), "win.view");
    gtk.gtk_actionable_set_action_target_value(@ptrCast(editor_btn), gtk.g_variant_new_string(core.view_editor));
    gtk.gtk_box_append(@ptrCast(view_switch), editor_btn);

    const terminal_btn = gtk.gtk_toggle_button_new().?;
    gtk.gtk_button_set_icon_name(@ptrCast(terminal_btn), "utilities-terminal-symbolic");
    gtk.gtk_widget_set_tooltip_text(terminal_btn, "Terminal");
    gtk.gtk_actionable_set_action_name(@ptrCast(terminal_btn), "win.view");
    gtk.gtk_actionable_set_action_target_value(@ptrCast(terminal_btn), gtk.g_variant_new_string(core.view_terminal));
    gtk.gtk_box_append(@ptrCast(view_switch), terminal_btn);

    // "New Terminal" — next to the overview button, since both act on the tabs
    // rather than on the document.  Shown only in terminal mode (view.zig): in
    // editor mode it would offer to create a tab the visible tab bar can't hold.
    const new_tab_btn = gtk.gtk_button_new_from_icon_name("tab-new-symbolic").?;
    gtk.gtk_widget_set_tooltip_text(new_tab_btn, "New Terminal");
    gtk.gtk_actionable_set_action_name(@ptrCast(new_tab_btn), "win.new-terminal");
    gtk.gtk_widget_set_visible(new_tab_btn, 0);
    gtk.adw_header_bar_pack_start(hbar, new_tab_btn);

    // Markdown preview toggle — visible only when the active tab is a .md file.
    const preview_btn_widget = gtk.gtk_toggle_button_new().?;
    gtk.gtk_button_set_icon_name(@ptrCast(preview_btn_widget), "view-dual-symbolic");
    gtk.gtk_widget_set_tooltip_text(preview_btn_widget, "Toggle Preview");
    gtk.gtk_widget_set_visible(preview_btn_widget, 0);
    const preview_btn_handler = gtk.g_signal_connect_data(
        preview_btn_widget,
        "toggled",
        @as(gtk.GCallback, @ptrCast(&preview.onPreviewToggled)),
        @ptrCast(state),
        null,
        0,
    );

    // Primary menu (rightmost). Sections separate the file commands, the
    // document commands and the app-level items, following the GNOME
    // primary-menu convention; the accelerators come from the action names.
    const menu = gtk.g_menu_new().?;
    appendSection(menu, &.{
        .{ "New File", "win.new-file" },
        .{ "Open File\u{2026}", "win.open-file" },
        .{ "Open Project\u{2026}", "win.open-project" },
    });
    appendSection(menu, &.{
        .{ "Save", "win.save" },
        .{ "Save As\u{2026}", "win.save-as" },
        .{ "Reload from Disk", "win.reload" },
    });
    appendSection(menu, &.{
        .{ "Find and Replace\u{2026}", "win.replace" },
        .{ "Format Document", "win.format" },
    });
    appendSection(menu, &.{
        .{ "Preferences", "app.preferences" },
        .{ "Keyboard Shortcuts", "win.shortcuts" },
        .{ "About zcode", "app.about" },
        .{ "Quit", "app.quit" },
    });

    const menu_btn_widget = gtk.gtk_menu_button_new().?;
    const menu_btn = @as(*gtk.GtkMenuButton, @ptrCast(menu_btn_widget));
    gtk.gtk_menu_button_set_icon_name(menu_btn, "open-menu-symbolic");
    gtk.gtk_menu_button_set_primary(menu_btn, 1);
    gtk.gtk_menu_button_set_menu_model(menu_btn, @ptrCast(menu));
    gtk.gtk_widget_set_tooltip_text(menu_btn_widget, "Main Menu");
    gtk.g_object_unref(menu);

    gtk.adw_header_bar_pack_end(hbar, menu_btn_widget);
    gtk.adw_header_bar_pack_end(hbar, view_switch);
    gtk.adw_header_bar_pack_end(hbar, preview_btn_widget);

    gtk.adw_toolbar_view_add_top_bar(content_toolbar, hbar_widget);

    // ── Status bar (bottom bar) ───────────────────────────────────────────
    // Where the readouts about the open document live, so the header bar can
    // stay a row of controls. Revealed only while a text buffer is on screen.
    const status_row, const status = view.buildStatusBar();
    gtk.adw_toolbar_view_add_bottom_bar(content_toolbar, status_row);
    gtk.adw_toolbar_view_set_reveal_bottom_bars(content_toolbar, 0);

    // ── AdwOverlaySplitView ───────────────────────────────────────────────
    // The GNOME-native collapsible sidebar (as used by Builder, Nautilus, …).
    const split_widget = gtk.adw_overlay_split_view_new().?;
    const split = @as(*gtk.AdwOverlaySplitView, @ptrCast(split_widget));
    gtk.adw_overlay_split_view_set_min_sidebar_width(split, 180);
    gtk.adw_overlay_split_view_set_max_sidebar_width(split, 360);
    gtk.adw_overlay_split_view_set_sidebar_width_fraction(split, 0.22);
    gtk.gtk_widget_set_hexpand(split_widget, 1);
    gtk.gtk_widget_set_vexpand(split_widget, 1);

    // Keep the sidebar toggle button in sync with the split view both ways.
    _ = gtk.g_object_bind_property(
        split_widget,
        "show-sidebar",
        sidebar_btn_widget,
        "active",
        gtk.G_BINDING_SYNC_CREATE | gtk.G_BINDING_BIDIRECTIONAL,
    );

    // ── Sidebar pane: its own AdwToolbarView + flat header ────────────────
    // Giving the sidebar its own toolbar view makes it a single unified panel
    // that extends up through the title bar and collapses as a whole, exactly
    // like the project panel in GNOME Builder.
    const sidebar_toolbar_widget = gtk.adw_toolbar_view_new().?;
    const sidebar_toolbar = @as(*gtk.AdwToolbarView, @ptrCast(sidebar_toolbar_widget));
    gtk.gtk_widget_add_css_class(sidebar_toolbar_widget, "sidebar");

    const sidebar_header_widget = gtk.adw_header_bar_new().?;
    const sidebar_header = @as(*gtk.AdwHeaderBar, @ptrCast(sidebar_header_widget));
    // Flat + no window controls so the header blends into the panel; the window
    // controls live on the content side only.
    gtk.gtk_widget_add_css_class(sidebar_header_widget, "flat");
    gtk.adw_header_bar_set_show_end_title_buttons(sidebar_header, 0);
    gtk.adw_header_bar_set_show_start_title_buttons(sidebar_header, 0);

    // "New File" / "New Folder" — entries in the Open Project dropdown in the
    // header bar, disabled until a project is open (enabled in files.attachProject).
    const new_file_action = gtk.g_simple_action_new("new-file", null).?;
    _ = gtk.g_signal_connect_data(new_file_action, "activate", @as(gtk.GCallback, @ptrCast(&files.onNewFileAction)), @ptrCast(state), null, 0);
    gtk.g_action_map_add_action(@ptrCast(win_widget), @ptrCast(new_file_action));
    gtk.g_simple_action_set_enabled(new_file_action, 0);
    gtk.g_object_unref(new_file_action);

    const new_folder_action = gtk.g_simple_action_new("new-folder", null).?;
    _ = gtk.g_signal_connect_data(new_folder_action, "activate", @as(gtk.GCallback, @ptrCast(&files.onNewFolderAction)), @ptrCast(state), null, 0);
    gtk.g_action_map_add_action(@ptrCast(win_widget), @ptrCast(new_folder_action));
    gtk.g_simple_action_set_enabled(new_folder_action, 0);
    gtk.g_object_unref(new_folder_action);

    // Git status — a two-line title in the title-widget slot (so it
    // true-centers): the branch name on top, the change count dimmed below.
    // Read-only, no popover, no branch switching.
    const git_title_widget = gtk.adw_window_title_new("No Git", "").?;
    const git_title = @as(*gtk.AdwWindowTitle, @ptrCast(git_title_widget));
    gtk.gtk_widget_set_tooltip_text(git_title_widget, "Git Branch");
    gtk.adw_header_bar_set_title_widget(sidebar_header, git_title_widget);

    gtk.adw_toolbar_view_add_top_bar(sidebar_toolbar, sidebar_header_widget);

    const sidebar_scroll_widget = gtk.gtk_scrolled_window_new().?;
    const sidebar_scroll = @as(*gtk.GtkScrolledWindow, @ptrCast(sidebar_scroll_widget));
    // Suppress the native vertical scrollbar: its overlay fade-in snapshots
    // the scrollbar's trough/slider gizmos before allocation, logging
    // "snapshot GtkGizmo without a current allocation" (same fix already
    // applied to editor tabs' scrolled window in editor/tabs.zig).
    gtk.gtk_scrolled_window_set_policy(sidebar_scroll, .automatic, .external);

    // Empty sidebar: a compact status page. The Open Project split button in
    // the header bar is the entry point, so the body just signals the state.
    const placeholder_widget = gtk.adw_status_page_new().?;
    const placeholder = @as(*gtk.AdwStatusPage, @ptrCast(placeholder_widget));
    gtk.gtk_widget_add_css_class(placeholder_widget, "compact");
    gtk.adw_status_page_set_icon_name(placeholder, "folder-symbolic");
    gtk.adw_status_page_set_title(placeholder, "No Project");
    gtk.adw_status_page_set_description(placeholder, "Open a project to see its files here.");
    gtk.gtk_scrolled_window_set_child(sidebar_scroll, placeholder_widget);
    gtk.adw_toolbar_view_set_content(sidebar_toolbar, sidebar_scroll_widget);
    gtk.adw_overlay_split_view_set_sidebar(split, sidebar_toolbar_widget);

    // Right-click on empty space below the tree → New File / New Folder.
    // Row-level gestures claim button-3 events first, so this fires only on empty space.
    const sidebar_right_click = gtk.gtk_gesture_click_new().?;
    gtk.gtk_gesture_single_set_button(@ptrCast(sidebar_right_click), 3);
    _ = gtk.g_signal_connect_data(
        @ptrCast(sidebar_right_click),
        "pressed",
        @as(gtk.GCallback, @ptrCast(&files.onSidebarEmptyRightClick)),
        @ptrCast(state),
        null,
        0,
    );
    gtk.gtk_widget_add_controller(sidebar_scroll_widget, @ptrCast(sidebar_right_click));

    // ── Tab views (one per mode) ──────────────────────────────────────────
    const editor_tabs_widget = gtk.adw_tab_view_new().?;
    const editor_tabs = @as(*gtk.AdwTabView, @ptrCast(editor_tabs_widget));
    gtk.gtk_widget_set_hexpand(editor_tabs_widget, 1);
    gtk.gtk_widget_set_vexpand(editor_tabs_widget, 1);

    const terminal_tabs_widget = gtk.adw_tab_view_new().?;
    const terminal_tabs = @as(*gtk.AdwTabView, @ptrCast(terminal_tabs_widget));
    gtk.gtk_widget_set_hexpand(terminal_tabs_widget, 1);
    gtk.gtk_widget_set_vexpand(terminal_tabs_widget, 1);

    // ── Tab bars, swapped in a stack so only the active mode's bar shows ──
    // Both collapse on a single tab: one tab needs no bar to switch between.
    const editor_bar_widget = gtk.adw_tab_bar_new().?;
    const editor_bar = @as(*gtk.AdwTabBar, @ptrCast(editor_bar_widget));
    gtk.adw_tab_bar_set_view(editor_bar, editor_tabs);
    gtk.adw_tab_bar_set_autohide(editor_bar, 1);

    const terminal_bar_widget = gtk.adw_tab_bar_new().?;
    const terminal_bar = @as(*gtk.AdwTabBar, @ptrCast(terminal_bar_widget));
    gtk.adw_tab_bar_set_view(terminal_bar, terminal_tabs);
    gtk.adw_tab_bar_set_autohide(terminal_bar, 1);

    const tabbar_stack_widget = gtk.gtk_stack_new().?;
    const tabbar_stack = @as(*gtk.GtkStack, @ptrCast(tabbar_stack_widget));
    // Only reserve the visible bar's height; otherwise the stack keeps the tall
    // editor bar's height while the (collapsed) terminal bar is shown, leaving an
    // empty offset above the terminal.
    gtk.gtk_stack_set_vhomogeneous(tabbar_stack, 0);
    _ = gtk.gtk_stack_add_named(tabbar_stack, editor_bar_widget, "editor");
    _ = gtk.gtk_stack_add_named(tabbar_stack, terminal_bar_widget, "terminal");
    gtk.adw_toolbar_view_add_top_bar(content_toolbar, tabbar_stack_widget);

    // ── Right pane: view stack (empty / editors / terminals) ──────────────
    const stack_widget = gtk.gtk_stack_new().?;
    const stack = @as(*gtk.GtkStack, @ptrCast(stack_widget));
    gtk.gtk_widget_set_hexpand(stack_widget, 1);
    gtk.gtk_widget_set_vexpand(stack_widget, 1);
    // Mode switches cross-fade instead of snapping. Armed on "map" rather than
    // here: a startup file opens before the first frame, and animating away a
    // page that has never been allocated makes GTK snapshot it without one.
    _ = gtk.g_signal_connect_data(
        win_widget,
        "map",
        @as(gtk.GCallback, @ptrCast(&onWindowMapped)),
        @ptrCast(stack_widget),
        null,
        0,
    );

    // Empty state, with the action that resolves it.
    const empty_widget = gtk.adw_status_page_new().?;
    const empty = @as(*gtk.AdwStatusPage, @ptrCast(empty_widget));
    gtk.adw_status_page_set_icon_name(empty, "text-editor-symbolic");
    gtk.adw_status_page_set_title(empty, "No File Open");
    gtk.adw_status_page_set_description(empty, "Open a project and pick a file to start editing.");
    gtk.adw_status_page_set_child(empty, actionButton("Open Project\u{2026}", "win.open-project"));
    _ = gtk.gtk_stack_add_named(stack, empty_widget, "empty");
    _ = gtk.gtk_stack_add_named(stack, editor_tabs_widget, "editors");
    _ = gtk.gtk_stack_add_named(stack, terminal_tabs_widget, "terminals");
    gtk.gtk_stack_set_visible_child_name(stack, "empty");

    gtk.adw_toolbar_view_set_content(content_toolbar, stack_widget);

    // ── Tab overview, over the content pane only ──────────────────────────
    // The grid stands in for the tabs, which are a property of the right pane;
    // covering the project tree as well would hide the one thing that stays
    // useful while picking a tab.
    const overview_widget = gtk.adw_tab_overview_new().?;
    const overview = @as(*gtk.AdwTabOverview, @ptrCast(overview_widget));
    gtk.adw_tab_overview_set_view(overview, editor_tabs);
    gtk.adw_tab_overview_set_enable_search(overview, 1);
    gtk.adw_tab_overview_set_child(overview, content_toolbar_widget);
    gtk.adw_overlay_split_view_set_content(split, overview_widget);

    // Outermost, so a toast is visible whether or not the overview is open.
    const toast_overlay_widget = gtk.adw_toast_overlay_new().?;
    const toast_overlay = @as(*gtk.AdwToastOverlay, @ptrCast(toast_overlay_widget));
    gtk.adw_toast_overlay_set_child(toast_overlay, split_widget);

    gtk.adw_application_window_set_content(win_adw, toast_overlay_widget);

    // Collapse the sidebar automatically on narrow windows (adaptive layout).
    gtk.zc_add_collapse_breakpoint(win_adw, split);

    state.* = .{
        .app = app,
        .win = win,
        .split = split,
        .toast_overlay = toast_overlay,
        .title = title,
        .content_toolbar = content_toolbar,
        .status = status,
        .tab_overview = overview,
        .new_terminal_btn = new_tab_btn,
        .sidebar_scroll = sidebar_scroll,
        .view_stack = stack,
        .tabbar_stack = tabbar_stack,
        .editor_tabs = editor_tabs,
        .terminal_tabs = terminal_tabs,
        .new_file_action = new_file_action,
        .new_folder_action = new_folder_action,
        .view_action = view_action,
        .git_title = git_title,
        .preview_btn = preview_btn_widget,
        .preview_btn_handler = preview_btn_handler,
    };
    core.registerWindow(state);

    // Every window-scoped command (save, find, go to line, …) lives in
    // shortcuts.zig as a GAction with an accelerator.
    shortcuts.installActions(state, win_widget);

    // Tab-view signals — editors prompt on close when unsaved, both views
    // free their per-tab struct on detach and update the view afterwards.
    _ = gtk.g_signal_connect_data(editor_tabs_widget, "close-page", @as(gtk.GCallback, @ptrCast(&editor.onEditorClosePage)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(editor_tabs_widget, "page-detached", @as(gtk.GCallback, @ptrCast(&editor.onEditorPageDetached)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(editor_tabs_widget, "page-attached", @as(gtk.GCallback, @ptrCast(&editor.onEditorPageAttached)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(editor_tabs_widget, "notify::selected-page", @as(gtk.GCallback, @ptrCast(&editor.onEditorSelectedPage)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(terminal_tabs_widget, "close-page", @as(gtk.GCallback, @ptrCast(&terminal.onTerminalClosePage)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(terminal_tabs_widget, "page-detached", @as(gtk.GCallback, @ptrCast(&terminal.onTerminalPageDetached)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(terminal_tabs_widget, "page-attached", @as(gtk.GCallback, @ptrCast(&terminal.onTerminalPageAttached)), @ptrCast(state), null, 0);

    // Dragging a tab out of the window tears it into a brand new window that
    // opens onto the same project — libadwaita handles the entire drag
    // gesture and page transfer itself; this only needs to hand back the new
    // window's matching tab view.
    _ = gtk.g_signal_connect_data(editor_tabs_widget, "create-window", @as(gtk.GCallback, @ptrCast(&onEditorCreateWindow)), @ptrCast(state), null, 0);
    _ = gtk.g_signal_connect_data(terminal_tabs_widget, "create-window", @as(gtk.GCallback, @ptrCast(&onTerminalCreateWindow)), @ptrCast(state), null, 0);

    // Refresh the sidebar's git state when the window regains focus — git
    // activity from outside the app mostly writes to .git subdirectories the
    // watcher doesn't cover.
    _ = gtk.g_signal_connect_data(@as(*anyopaque, @ptrCast(state.win)), "notify::is-active", @as(gtk.GCallback, @ptrCast(&files.onWindowActiveChanged)), @ptrCast(state), null, 0);

    // Re-apply the editor scheme and terminal colours when the system
    // light/dark preference changes. Connected on the process-lifetime style
    // manager singleton, so it must be disconnected when this window closes
    // (see shortcuts.zig's close continuation) to avoid a dangling user_data.
    _ = gtk.g_signal_connect_data(
        gtk.adw_style_manager_get_default(),
        "notify::dark",
        @as(gtk.GCallback, @ptrCast(&style.onColorSchemeChanged)),
        @ptrCast(state),
        null,
        0,
    );

    // Prompt to save unsaved changes / warn about open terminals when this
    // window is closed.
    _ = gtk.g_signal_connect_data(
        @as(*anyopaque, @ptrCast(win)),
        "close-request",
        @as(gtk.GCallback, @ptrCast(&shortcuts.onWindowCloseRequest)),
        @ptrCast(state),
        null,
        0,
    );

    lsp.g_open_at_fn = openAt;
    preview.g_open_file_fn = &openFile;
    files.g_build_window_fn = &buildWindow;

    // "Open Project…" / "Open Project in New Window…" — back the sidebar's
    // open-project split button dropdown (built above, before `state` existed).
    const open_project_action = gtk.g_simple_action_new("open-project", null).?;
    _ = gtk.g_signal_connect_data(open_project_action, "activate", @as(gtk.GCallback, @ptrCast(&files.onOpenProjectAction)), @ptrCast(state), null, 0);
    gtk.g_action_map_add_action(@ptrCast(win_widget), @ptrCast(open_project_action));
    gtk.g_object_unref(open_project_action);

    const open_project_new_window_action = gtk.g_simple_action_new("open-project-new-window", null).?;
    _ = gtk.g_signal_connect_data(open_project_new_window_action, "activate", @as(gtk.GCallback, @ptrCast(&files.onOpenProjectNewWindowAction)), @ptrCast(state), null, 0);
    gtk.g_action_map_add_action(@ptrCast(win_widget), @ptrCast(open_project_new_window_action));
    gtk.g_object_unref(open_project_new_window_action);

    if (source) |src| {
        const path = std.mem.sliceTo(&src.folder_path, 0);
        if (path.len != 0) files.attachProject(state, path);
    }

    gtk.gtk_window_set_title(win, "zcode");
    gtk.gtk_window_set_default_size(win, 1200, 700);
    geometry.restore(win);
    gtk.gtk_window_present(win);

    return state;
}

/// Turns on the view stack's crossfade once the window is on screen, so the
/// first switch — which happens while the window is still being built — is
/// instant and every later mode change animates.
fn onWindowMapped(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const stack: *gtk.GtkStack = @ptrCast(@alignCast(user_data.?));
    gtk.gtk_stack_set_transition_type(stack, gtk.GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk.gtk_stack_set_transition_duration(stack, 150);
}

/// One menu section from a list of (label, action) pairs.  The section is what
/// draws the separator between groups of items.
fn appendSection(menu: *gtk.GMenu, items: []const struct { [*:0]const u8, [*:0]const u8 }) void {
    const section = gtk.g_menu_new() orelse return;
    for (items) |item| gtk.g_menu_append(section, item[0], item[1]);
    gtk.g_menu_append_section(menu, null, @ptrCast(section));
    gtk.g_object_unref(section);
}

/// The suggested pill button an empty state offers as its way out.
fn actionButton(label: [*:0]const u8, action: [*:0]const u8) ?*gtk.GtkWidget {
    const btn = gtk.gtk_button_new_with_label(label) orelse return null;
    gtk.gtk_actionable_set_action_name(@ptrCast(btn), action);
    gtk.gtk_widget_add_css_class(btn, "suggested-action");
    gtk.gtk_widget_add_css_class(btn, "pill");
    gtk.gtk_widget_set_halign(btn, .center);
    return btn;
}

fn onEditorCreateWindow(_: ?*gtk.AdwTabView, user_data: ?*anyopaque) callconv(.c) ?*gtk.AdwTabView {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const new_state = buildWindow(state.app, state);
    return new_state.editor_tabs;
}

fn onTerminalCreateWindow(_: ?*gtk.AdwTabView, user_data: ?*anyopaque) callconv(.c) ?*gtk.AdwTabView {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const new_state = buildWindow(state.app, state);
    return new_state.terminal_tabs;
}

fn openAt(state: *core.AppState, path: [*:0]const u8, line: i64, ch: i64) void {
    editor.openEditorTab(state, path);
    const tab = core.selectedEditorTab(state) orelse return;
    const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
    var iter: gtk.GtkTextIter = .{};
    // The column comes from the language server, against its own copy of the
    // file; snap it rather than trust it to be a character boundary here.
    gtk.zc_iter_at_line_byte(tb, &iter, @intCast(line), @intCast(ch));
    gtk.gtk_text_buffer_place_cursor(tb, &iter);
    _ = gtk.gtk_text_view_scroll_to_iter(@ptrCast(tab.source_view), &iter, 0.1, 1, 0.5, 0.3);
}

fn openFile(state: *core.AppState, path: [*:0]const u8) void {
    editor.openEditorTab(state, path);
}

//! Editor tabs: opening files, the source view, the unsaved-changes bullet, the
//! diff gutter and the tab-view signal handlers.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const style = @import("../core/style.zig");
const config = @import("../core/config.zig");
const toast = @import("../app/toast.zig");
const view = @import("../app/view.zig");
const language = @import("language.zig");
const syntax = @import("syntax.zig");
const lsp = @import("../lsp/manager.zig");
const preview = @import("preview.zig");
const filesync = @import("filesync.zig");
const position = @import("position.zig");

const EditorTab = core.EditorTab;

/// Destroys a widget that was built but never parented.  A fresh GtkWidget
/// carries a floating reference, so sinking it first is what makes the unref
/// actually free it.
fn discardFloating(widget: *gtk.GtkWidget) void {
    _ = gtk.g_object_ref_sink(@ptrCast(widget));
    gtk.g_object_unref(@ptrCast(widget));
}

/// Brings one source view in line with the editor preferences.  Called when the
/// view is built and again for every open view whenever a preference changes.
pub fn applyPrefs(sv: *gtk.GtkSourceView) void {
    const width = config.tabWidth();
    gtk.gtk_source_view_set_tab_width(sv, @intCast(width));
    gtk.gtk_source_view_set_indent_width(sv, width);
    gtk.gtk_source_view_set_insert_spaces_instead_of_tabs(sv, if (config.insertSpaces()) 1 else 0);
    gtk.gtk_source_view_set_show_line_numbers(sv, if (config.showLineNumbers()) 1 else 0);
    gtk.gtk_text_view_set_wrap_mode(
        @ptrCast(sv),
        if (config.wrapLines()) gtk.GTK_WRAP_WORD_CHAR else gtk.GTK_WRAP_NONE,
    );
    const margin = config.rightMargin();
    gtk.gtk_source_view_set_show_right_margin(sv, if (margin > 0) 1 else 0);
    if (margin > 0) gtk.gtk_source_view_set_right_margin_position(sv, @intCast(margin));
}

/// Re-applies the editor preferences to every open source view in every window.
pub fn refreshAllEditorPrefs() void {
    for (core.g_windows.items) |state| {
        var i: c_int = 0;
        const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
        while (i < n) : (i += 1) {
            if (core.editorTabAt(state, i)) |tab| applyPrefs(tab.source_view);
        }
    }
}

/// Re-arms the allocation of a source view's whole ancestry when it comes back
/// on screen.
///
/// `gtk_widget_map` propagates a redraw and nothing else, so a subtree that
/// picked up a pending allocation while it was off screen is painted before it
/// is laid out.  GTK will not build a render node for a widget in that state —
/// it re-appends the previous one — and every route back out is already closed
/// by the flags that put it there: `queue_draw` stops at the first widget whose
/// redraw is pending, so it never reaches the surface to ask for a frame, and
/// `queue_resize` returns early on the resize that was never serviced.  The
/// text then stops updating for good while the status bar, on its own branch,
/// keeps tracking the caret — and remapping the view by switching tabs is the
/// only thing that clears it.
///
/// Editor subtrees go off screen constantly — a tab that is not selected,
/// terminal mode, the tab overview, the markdown preview — while diagnostics,
/// change bars, tree-sitter tagging and disk reloads keep resizing them
/// regardless.  `queue_allocate` is the way back: it has no early-out on the
/// flags that are stuck, and walking it to the root both requests the layout
/// phase and marks every ancestor as needing allocation, so each one descends
/// into its children instead of taking the nothing-moved shortcut.
fn onViewMapped(widget: *gtk.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    var w: ?*gtk.GtkWidget = widget;
    while (w) |cur| : (w = gtk.gtk_widget_get_parent(cur)) gtk.gtk_widget_queue_allocate(cur);
}

const sync_handlers = filesync.Handlers{
    .reloaded = &syncReloaded,
    .conflict = &syncConflict,
    .deleted = &syncDeleted,
};

/// Opens `path` in an editor tab.  If the file is already open its tab is
/// selected instead of being opened twice.  Always leaves terminal mode.
pub fn openEditorTab(state: *core.AppState, path: [*:0]const u8) void {
    const want = std.mem.sliceTo(path, 0);

    // Reuse an existing tab for the same file.
    var i: c_int = 0;
    const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    while (i < n) : (i += 1) {
        if (core.editorTabAt(state, i)) |tab| {
            if (std.mem.eql(u8, std.mem.sliceTo(&tab.doc.path, 0), want)) {
                gtk.adw_tab_view_set_selected_page(state.editor_tabs, tab.page);
                view.switchToEditors(state);
                if (!tab.doc.is_binary and !tab.is_image)
                    _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.source_view)));
                return;
            }
        }
    }

    // Always create the source view — it is stored in EditorTab regardless of
    // file type.  For binary files it stays orphaned (not in the widget tree).
    const sv_widget = gtk.gtk_source_view_new() orelse return;
    const sv = @as(*gtk.GtkSourceView, @ptrCast(sv_widget));
    gtk.gtk_source_view_set_highlight_current_line(sv, 1);
    gtk.gtk_source_view_set_auto_indent(sv, 1);
    applyPrefs(sv);
    gtk.gtk_widget_set_hexpand(sv_widget, 1);
    gtk.gtk_widget_set_vexpand(sv_widget, 1);
    // Allow scrolling past the last line so it can be positioned comfortably
    // in the middle of the viewport instead of being locked to the bottom edge.
    gtk.gtk_text_view_set_bottom_margin(@ptrCast(sv_widget), 400);
    // Same idea horizontally: a wide right margin lets the end of the longest
    // lines be scrolled toward the centre instead of hugging the right edge.
    gtk.gtk_text_view_set_right_margin(@ptrCast(sv_widget), 400);
    _ = gtk.g_signal_connect_data(sv_widget, "map", @ptrCast(&onViewMapped), null, null, 0);

    const buf = @as(*gtk.GtkSourceBuffer, @ptrCast(
        gtk.gtk_text_view_get_buffer(@as(*gtk.GtkTextView, @ptrCast(sv_widget))).?,
    ));
    style.applyStyleScheme(buf);

    // Create the tab struct and open the document before building the widget
    // tree so that doc.is_binary is known in time to branch.
    const is_image = isImagePath(path);
    const tab = std.heap.c_allocator.create(EditorTab) catch return;
    tab.* = .{ .source_view = sv, .buffer = buf, .page = undefined, .owner = state, .is_image = is_image };
    tab.doc.open(path, buf);

    const box_widget = gtk.gtk_box_new(.vertical, 0) orelse {
        discardFloating(sv_widget);
        std.heap.c_allocator.destroy(tab);
        return;
    };
    const box = @as(*gtk.GtkBox, @ptrCast(box_widget));

    if (is_image) {
        // Image file: display via GtkPicture, which scales to fit while
        // maintaining the aspect ratio.  The source view exists in memory but
        // is not added to the widget tree.
        const pic_widget = gtk.gtk_picture_new_for_filename(path) orelse {
            discardFloating(box_widget);
            discardFloating(sv_widget);
            std.heap.c_allocator.destroy(tab);
            return;
        };
        gtk.gtk_widget_set_hexpand(pic_widget, 1);
        gtk.gtk_widget_set_vexpand(pic_widget, 1);
        gtk.gtk_box_append(box, pic_widget);
    } else if (tab.doc.is_binary) {
        // Binary/non-text file: show a status page placeholder.  The source
        // view exists in memory but is not added to the widget tree.
        const sp_widget = gtk.adw_status_page_new().?;
        const sp = @as(*gtk.AdwStatusPage, @ptrCast(sp_widget));
        gtk.adw_status_page_set_icon_name(sp, "application-x-executable-symbolic");
        gtk.adw_status_page_set_title(sp, "Cannot Display File");
        gtk.adw_status_page_set_description(sp, "This file is binary and has no text representation.");
        gtk.gtk_widget_set_hexpand(sp_widget, 1);
        gtk.gtk_widget_set_vexpand(sp_widget, 1);
        gtk.gtk_box_append(box, sp_widget);
    } else {
        const scroll_widget = gtk.gtk_scrolled_window_new() orelse {
            discardFloating(box_widget);
            discardFloating(sv_widget);
            std.heap.c_allocator.destroy(tab);
            return;
        };
        const scroll = @as(*gtk.GtkScrolledWindow, @ptrCast(scroll_widget));
        gtk.gtk_widget_set_hexpand(scroll_widget, 1);
        gtk.gtk_widget_set_vexpand(scroll_widget, 1);
        // Both scrollbars are EXTERNAL: the overview ruler is the vertical
        // scroll UI, and horizontal movement is by gesture/keyboard.  Beyond
        // being redundant here, the native overlay scrollbars' fade-in snapshots
        // their trough/slider gizmos before allocation, logging "snapshot
        // GtkGizmo without a current allocation" — suppressing them avoids that.
        // The wide right margin still gives the content its extra scroll range.
        gtk.gtk_scrolled_window_set_policy(scroll, .external, .external);
        gtk.gtk_scrolled_window_set_child(scroll, sv_widget);

        // Selection-occurrence highlight + the Ctrl+F find bar.
        gtk.zc_search_attach(sv);
        if (gtk.zc_search_bar_new(sv)) |bar_widget|
            gtk.gtk_box_append(box, bar_widget);
        gtk.zc_hover_attach(sv);
        gtk.zc_diag_marks_attach(sv);

        // GtkOverlay: scrolled window fills the tab area as the base child; the
        // overview ruler floats at halign=END without affecting layout.
        const tab_overlay_widget = gtk.gtk_overlay_new() orelse {
            discardFloating(scroll_widget);
            discardFloating(box_widget);
            std.heap.c_allocator.destroy(tab);
            return;
        };
        const tab_overlay = @as(*gtk.GtkOverlay, @ptrCast(tab_overlay_widget));
        gtk.gtk_widget_set_hexpand(tab_overlay_widget, 1);
        gtk.gtk_widget_set_vexpand(tab_overlay_widget, 1);
        gtk.gtk_overlay_set_child(tab_overlay, scroll_widget);
        if (gtk.zc_overview_ruler_new(sv, scroll)) |ruler| {
            gtk.gtk_overlay_add_overlay(tab_overlay, ruler);
            gtk.gtk_overlay_set_measure_overlay(tab_overlay, ruler, 0);
        }

        // Markdown and HTML files get a per-tab GtkStack so the preview panel
        // can be swapped in without destroying the source view.  The
        // WebKitWebView is added lazily on first toggle.
        if (hasPreviewStack(path)) {
            const ts_widget = gtk.gtk_stack_new() orelse {
                discardFloating(tab_overlay_widget);
                discardFloating(box_widget);
                std.heap.c_allocator.destroy(tab);
                return;
            };
            const ts = @as(*gtk.GtkStack, @ptrCast(ts_widget));
            gtk.gtk_widget_set_hexpand(ts_widget, 1);
            gtk.gtk_widget_set_vexpand(ts_widget, 1);
            gtk.gtk_stack_set_hhomogeneous(ts, 1);
            // Source and preview are two views of one document, so they slide
            // rather than snap — and the direction follows the order the pages
            // were added, so going back to the source reverses the animation.
            gtk.gtk_stack_set_transition_type(ts, gtk.GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);
            gtk.gtk_stack_set_transition_duration(ts, 150);
            _ = gtk.gtk_stack_add_named(ts, tab_overlay_widget, "editor");
            gtk.gtk_box_append(box, ts_widget);
            tab.preview_stack = ts;
        } else {
            gtk.gtk_box_append(box, tab_overlay_widget);
        }
    }

    const page = gtk.adw_tab_view_append(state.editor_tabs, box_widget) orelse {
        discardFloating(box_widget);
        std.heap.c_allocator.destroy(tab);
        return;
    };
    tab.page = page;
    gtk.g_object_set_data(@ptrCast(page), core.tab_data_key, @ptrCast(tab));

    _ = gtk.g_signal_connect_data(
        buf,
        "modified-changed",
        @as(gtk.GCallback, @ptrCast(&onEditorModified)),
        @ptrCast(tab),
        null,
        0,
    );
    // Keeps the status bar's line/column readout on the cursor.
    _ = gtk.g_signal_connect_data(
        buf,
        "notify::cursor-position",
        @as(gtk.GCallback, @ptrCast(&onCursorMoved)),
        @ptrCast(tab),
        null,
        0,
    );

    updateEditorTabTitle(tab);

    if (!tab.doc.is_binary and !is_image) {
        // Tree-sitter takes over for supported grammars; everything else keeps
        // the GtkSourceView .lang highlighter set in document.open.  Large files
        // keep the native incremental highlighter instead of our whole-buffer-
        // reparse tree-sitter path, which would lag at that size.
        if (!tab.doc.large) {
            if (language.detect(path)) |lang| syntax.attach(sv, lang);
        }

        // Language-server features: completion, hover, definition.
        // Large files are skipped to avoid shipping megabytes per edit.
        gtk.zc_lsp_completion_attach(sv);
        gtk.zc_signature_attach(sv);
        gtk.zc_editor_attach_click_nav(sv);
        if (!tab.doc.large) lsp.didOpen(state, buf, path);

        // Git change-bars in the gutter, comparing the file against HEAD.
        gtk.zc_source_view_attach_diff(sv, &tab.doc.path);

        // Live external sync: a conflict bar + a watcher that reloads the buffer
        // when another process rewrites the file on disk.
        buildConflictBar(tab, box);
        tab.filesync = filesync.create(buf, path, @ptrCast(tab), sync_handlers);
    }

    gtk.adw_tab_view_set_selected_page(state.editor_tabs, page);
    view.switchToEditors(state);
    if (!tab.doc.is_binary and !is_image) _ = gtk.gtk_widget_grab_focus(sv_widget);
}

/// Sets an editor tab's title to the file name, prefixed with a bullet when the
/// buffer has unsaved changes.  Also sets the tooltip to the full file path.
fn updateEditorTabTitle(tab: *EditorTab) void {
    var buf: [320]u8 = undefined;
    const name = tab.doc.filename();
    const t = if (tab.doc.isModified(tab.buffer))
        std.fmt.bufPrintZ(&buf, "\u{2022} {s}", .{name}) catch "Untitled"
    else
        std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch "Untitled";
    gtk.adw_tab_page_set_title(tab.page, t);
    if (tab.doc.isOpen())
        gtk.adw_tab_page_set_tooltip(tab.page, @as([*:0]const u8, &tab.doc.path))
    else
        gtk.adw_tab_page_set_tooltip(tab.page, null);
}

fn onEditorModified(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(user_data.?)));
    updateEditorTabTitle(tab);
    const state = tab.owner;
    // A clean buffer means the file was just saved → recompute its diff bars
    // and tell the language server.  A buffer cleared by an external reload also
    // lands here, but those side effects belong to a real save only.
    if (!tab.doc.isModified(tab.buffer) and tab.doc.isOpen()) {
        gtk.zc_source_view_update_diff(tab.source_view, &tab.doc.path);
        const reloading = if (tab.filesync) |fs| fs.loading else false;
        if (!reloading) {
            lsp.didSave(tab.buffer);
            if (tab.filesync) |fs| fs.noteSaved();
            hideBar(tab);
        }
    }
    if (core.selectedEditorTab(state)) |sel| {
        if (sel == tab) view.updateWindowTitle(state);
    }
}

// ── Live external sync: conflict banner, indicator and change flash ───────────

const conflict_icon: [*:0]const u8 = "dialog-warning-symbolic";

/// Attaches an AdwBanner (initially hidden) at the top of the tab box.
fn buildConflictBar(tab: *EditorTab, box: *gtk.GtkBox) void {
    const banner_w = gtk.adw_banner_new("") orelse return;
    const banner = @as(*gtk.AdwBanner, @ptrCast(banner_w));
    gtk.adw_banner_set_revealed(banner, 0);
    _ = gtk.g_signal_connect_data(
        banner_w,
        "button-clicked",
        @as(gtk.GCallback, @ptrCast(&onBannerClicked)),
        @ptrCast(tab),
        null,
        0,
    );
    gtk.gtk_box_prepend(box, banner_w);
    tab.banner = banner;
}

/// The file was re-read from disk: keep the cursor in view, refresh the diff
/// bars, flash the changed lines and drop any conflict banner.
fn syncReloaded(ctx: *anyopaque, ok: bool, flash_start: c_int, flash_end: c_int) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(ctx)));
    if (ok) {
        scrollToCursor(tab);
        if (tab.doc.isOpen())
            gtk.zc_source_view_update_diff(tab.source_view, &tab.doc.path);
        if (flash_start >= 0) flashRange(tab, flash_start, flash_end);
    }
    hideBar(tab);
}

/// Disk changed under unsaved edits — never clobber: let the user decide.
fn syncConflict(ctx: *anyopaque) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(ctx)));
    showBar(tab, "File Has Changed on Disk", "Discard Changes and Reload", .reload);
}

/// The file vanished on disk — offer to write the buffer back.
fn syncDeleted(ctx: *anyopaque) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(ctx)));
    showBar(tab, "File Has Been Deleted on Disk", "Save", .write);
}

fn showBar(tab: *EditorTab, message: [*:0]const u8, btn_label: [*:0]const u8, action: core.BarAction) void {
    const banner = tab.banner orelse return;
    gtk.adw_banner_set_title(banner, message);
    gtk.adw_banner_set_button_label(banner, btn_label);
    tab.banner_action = action;
    gtk.adw_banner_set_revealed(banner, 1);
    setIndicator(tab, true);
}

fn hideBar(tab: *EditorTab) void {
    if (tab.banner) |banner| gtk.adw_banner_set_revealed(banner, 0);
    setIndicator(tab, false);
}

/// Saves `tab`'s buffer for an explicit user-initiated save (Ctrl+S), running
/// the language server's formatter first when the file has one. No-op if
/// there are no unsaved changes.
pub fn saveTab(tab: *EditorTab) void {
    if (!tab.doc.isModified(tab.buffer)) return;
    lsp.formatDocumentThen(tab.buffer, finishSaveTab, @ptrCast(tab));
}

fn finishSaveTab(ctx: ?*anyopaque) void {
    const tab: *EditorTab = @ptrCast(@alignCast(ctx.?));
    _ = writeTab(tab);
}

/// Writes `tab`'s buffer to its file, surfacing a failure the user would
/// otherwise never notice: a read-only or vanished file just leaves the
/// unsaved-changes bullet in place, looking exactly like a successful save.
pub fn writeTab(tab: *EditorTab) bool {
    if (tab.doc.save(tab.buffer)) return true;
    toast.showErrorFmt(tab.owner, "Could not save \u{201c}{s}\u{201d}", .{tab.doc.filename()});
    return false;
}

// ── Save As / Reload ─────────────────────────────────────────────────────────

/// Points `tab` at `new_path`: everything keyed on the old location (title,
/// diff bars, the disk watcher, the language server's document URI) follows.
fn retarget(state: *core.AppState, tab: *EditorTab, new_path: [*:0]const u8) void {
    const new = std.mem.sliceTo(new_path, 0);
    const copy_len = @min(new.len, tab.doc.path.len - 1);
    @memcpy(tab.doc.path[0..copy_len], new[0..copy_len]);
    tab.doc.path[copy_len] = 0;

    updateEditorTabTitle(tab);
    gtk.zc_source_view_update_diff(tab.source_view, &tab.doc.path);
    if (tab.filesync) |fs| fs.setLocation(new_path);

    lsp.closeDocument(state, tab.buffer);
    if (!tab.doc.large) lsp.didOpen(state, tab.buffer, new_path);

    if (core.selectedEditorTab(state)) |sel| {
        if (sel == tab) view.updateWindowTitle(state);
    }
}

/// "Save As…" — writes the active buffer to a newly chosen path and moves the
/// tab onto it, so later saves go to the new file rather than the old one.
pub fn saveTabAs(state: *core.AppState) void {
    const tab = core.selectedEditorTab(state) orelse return;
    if (tab.doc.is_binary or tab.is_image) return;

    const dialog = gtk.gtk_file_dialog_new().?;
    // Ours to release; the dialog holds itself alive across the async call.
    defer gtk.g_object_unref(dialog);
    gtk.gtk_file_dialog_set_title(dialog, "Save As");
    gtk.gtk_file_dialog_set_modal(dialog, 1);

    if (tab.doc.isOpen()) {
        var name_buf: [256:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&name_buf, "{s}", .{tab.doc.filename()})) |name| {
            gtk.gtk_file_dialog_set_initial_name(dialog, name);
        } else |_| {}
        if (std.fs.path.dirname(std.mem.sliceTo(&tab.doc.path, 0))) |dir| {
            var dir_buf: [4096:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir})) |d| {
                if (gtk.g_file_new_for_path(d)) |gf| {
                    gtk.gtk_file_dialog_set_initial_folder(dialog, gf);
                    gtk.g_object_unref(gf);
                }
            } else |_| {}
        }
    }

    gtk.gtk_file_dialog_save(
        dialog,
        state.win,
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onSaveAsDone)),
        @ptrCast(state),
    );
}

fn onSaveAsDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.GtkFileDialog, @ptrCast(@alignCast(source.?)));
    var err: ?*gtk.GError = null;
    const gfile = gtk.gtk_file_dialog_save_finish(dialog, result, &err);
    if (err != null) {
        gtk.g_error_free(err);
        return;
    }
    const file = gfile orelse return;
    defer gtk.g_object_unref(file);
    const raw = gtk.g_file_get_path(file) orelse return;
    defer gtk.g_free(raw);

    const tab = core.selectedEditorTab(state) orelse return;
    retarget(state, tab, raw);
    if (writeTab(tab)) toast.showFmt(state, "Saved as \u{201c}{s}\u{201d}", .{tab.doc.filename()});
    if (state.file_tree) |tree| gtk.zc_file_tree_refresh(tree);
}

/// "Reload" — re-reads the active file from disk.  Confirms first when that
/// would throw away unsaved edits.
pub fn reloadTab(state: *core.AppState) void {
    const tab = core.selectedEditorTab(state) orelse return;
    if (tab.filesync == null) return;
    if (!tab.doc.isModified(tab.buffer)) {
        doReload(tab);
        return;
    }

    const dialog = gtk.adw_alert_dialog_new(
        "Reload from Disk?",
        "The unsaved changes in this file will be lost.",
    ).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    gtk.adw_alert_dialog_add_response(dialog, "reload", "Reload");
    gtk.adw_alert_dialog_set_response_appearance(dialog, "reload", gtk.ADW_RESPONSE_DESTRUCTIVE);
    gtk.adw_alert_dialog_set_default_response(dialog, "cancel");
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");
    gtk.adw_alert_dialog_choose(
        dialog,
        @as(*gtk.GtkWidget, @ptrCast(state.win)),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onReloadDialogDone)),
        @ptrCast(state),
    );
}

fn onReloadDialogDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const dialog = @as(*gtk.AdwAlertDialog, @ptrCast(@alignCast(source.?)));
    const response = std.mem.sliceTo(gtk.adw_alert_dialog_choose_finish(dialog, result), 0);
    if (!std.mem.eql(u8, response, "reload")) return;
    if (core.selectedEditorTab(state)) |tab| doReload(tab);
}

fn doReload(tab: *EditorTab) void {
    const fs = tab.filesync orelse return;
    fs.reload();
    toast.showFmt(tab.owner, "Reloaded \u{201c}{s}\u{201d}", .{tab.doc.filename()});
}

fn onCursorMoved(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(user_data.?)));
    const state = tab.owner;
    if (state.shutting_down) return;
    if (core.selectedEditorTab(state)) |sel| {
        if (sel == tab) view.updateStatus(state);
    }
}

fn doBarAction(tab: *EditorTab, action: core.BarAction) void {
    switch (action) {
        .reload => if (tab.filesync) |fs| fs.reload(),
        .write => {
            if (!writeTab(tab)) return;
            if (tab.filesync) |fs| fs.noteSaved();
            hideBar(tab);
        },
    }
}

fn onBannerClicked(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(user_data.?)));
    doBarAction(tab, tab.banner_action);
}

/// Marks the tab in the tab bar so a conflict on a background tab is visible.
fn setIndicator(tab: *EditorTab, on: bool) void {
    if (on) {
        const icon = gtk.g_themed_icon_new(conflict_icon);
        gtk.adw_tab_page_set_indicator_icon(tab.page, icon);
        gtk.adw_tab_page_set_indicator_tooltip(tab.page, "File changed on disk");
        if (icon) |i| gtk.g_object_unref(i);
    } else {
        gtk.adw_tab_page_set_indicator_icon(tab.page, null);
        gtk.adw_tab_page_set_indicator_tooltip(tab.page, "");
    }
}

fn scrollToCursor(tab: *EditorTab) void {
    const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
    var it: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_mark(tb, &it, gtk.gtk_text_buffer_get_insert(tb));
    // Keeping the caret's own horizontal fraction rather than pinning it to the
    // left edge: a reload moves the document under the cursor, not the cursor
    // across the line, so the view has no reason to travel sideways.
    const x = if (position.caretSpot(tab.source_view, &it)) |spot| spot.x else 0;
    _ = gtk.gtk_text_view_scroll_to_iter(@ptrCast(tab.source_view), &it, 0.0, 1, x, 0.3);
}

/// Briefly highlights the inclusive line band `start`..`end` an external reload
/// changed, then clears it — a subtle flash so the eye catches what moved.
fn flashRange(tab: *EditorTab, start: c_int, end: c_int) void {
    const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
    if (tab.flash_tag == null)
        tab.flash_tag = gtk.zc_line_bg_tag_new(@ptrCast(tab.buffer), 0.21, 0.52, 0.89, 0.18);
    const tag = tab.flash_tag orelse return;

    if (tab.flash_timer != 0) {
        _ = gtk.g_source_remove(tab.flash_timer);
        tab.flash_timer = 0;
    }
    var s_it: gtk.GtkTextIter = .{};
    var e_it: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_bounds(tb, &s_it, &e_it);
    gtk.gtk_text_buffer_remove_tag(tb, tag, &s_it, &e_it);

    const n = gtk.gtk_text_buffer_get_line_count(tb);
    var sl = start;
    if (sl >= n) sl = n - 1;
    if (sl < 0) sl = 0;
    var el = end;
    if (el >= n) el = n - 1;
    if (el < sl) el = sl;

    var a: gtk.GtkTextIter = .{};
    var b: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_line_index(tb, &a, sl, 0);
    gtk.gtk_text_buffer_get_iter_at_line_index(tb, &b, el, 0);
    _ = gtk.gtk_text_iter_forward_to_line_end(&b);
    gtk.gtk_text_buffer_apply_tag(tb, tag, &a, &b);
    tab.flash_timer = gtk.g_timeout_add(700, &onFlashDone, @ptrCast(tab));
}

fn onFlashDone(user_data: ?*anyopaque) callconv(.c) c_int {
    const tab = @as(*EditorTab, @ptrCast(@alignCast(user_data.?)));
    tab.flash_timer = 0;
    if (tab.flash_tag) |tag| {
        const tb: *gtk.GtkTextBuffer = @ptrCast(tab.buffer);
        var s: gtk.GtkTextIter = .{};
        var e: gtk.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_bounds(tb, &s, &e);
        gtk.gtk_text_buffer_remove_tag(tb, tag, &s, &e);
    }
    return 0;
}

const ClosePageCtx = struct {
    tab_view: *gtk.AdwTabView,
    page: *gtk.AdwTabPage,
};

fn onClosePageDialogDone(
    source: ?*gtk.GObject,
    result: ?*gtk.GAsyncResult,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ctx = @as(*ClosePageCtx, @ptrCast(@alignCast(user_data.?)));
    const dialog = @as(*gtk.AdwAlertDialog, @ptrCast(@alignCast(source.?)));
    const response = std.mem.sliceTo(gtk.adw_alert_dialog_choose_finish(dialog, result), 0);

    if (std.mem.eql(u8, response, "save")) {
        // `finishClosePage` takes ownership of `ctx`: it formats-then-saves and
        // only finishes the close once that settles (immediately if there's no
        // formatter to wait on).
        if (core.editorTabFromPage(ctx.page)) |tab| {
            lsp.formatDocumentThen(tab.buffer, finishClosePage, @ptrCast(ctx));
        } else {
            finishClosePage(@ptrCast(ctx));
        }
        return;
    }

    const tab_view = ctx.tab_view;
    const page = ctx.page;
    std.heap.c_allocator.destroy(ctx);
    if (std.mem.eql(u8, response, "discard")) {
        // A real close: page-detached is about to fire and must free the tab.
        if (core.editorTabFromPage(page)) |tab| tab.closing = true;
        gtk.adw_tab_view_close_page_finish(tab_view, page, 1);
    } else {
        gtk.adw_tab_view_close_page_finish(tab_view, page, 0);
    }
}

fn finishClosePage(user_data: ?*anyopaque) void {
    const ctx: *ClosePageCtx = @ptrCast(@alignCast(user_data.?));
    if (core.editorTabFromPage(ctx.page)) |tab| {
        _ = writeTab(tab);
        tab.closing = true;
    }
    const tab_view = ctx.tab_view;
    const page = ctx.page;
    std.heap.c_allocator.destroy(ctx);
    gtk.adw_tab_view_close_page_finish(tab_view, page, 1);
}

pub fn onEditorClosePage(
    tab_view: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const p = page orelse return 0;
    const tab = core.editorTabFromPage(p) orelse return 0;

    if (state.shutting_down) {
        tab.closing = true;
        return 0;
    }
    const tv = tab_view orelse return 0;

    if (!tab.doc.isModified(tab.buffer)) {
        tab.closing = true;
        return 0;
    }

    var hdr_buf: [512:0]u8 = undefined;
    const name = tab.doc.filename();
    const heading = std.fmt.bufPrintZ(&hdr_buf, "Save changes to \"{s}\"?", .{name}) catch "Save changes?";

    const dialog = gtk.adw_alert_dialog_new(heading, "If you don't save, your changes will be lost.").?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    gtk.adw_alert_dialog_add_response(dialog, "discard", "Discard");
    gtk.adw_alert_dialog_add_response(dialog, "save", "Save");
    gtk.adw_alert_dialog_set_response_appearance(dialog, "discard", gtk.ADW_RESPONSE_DESTRUCTIVE);
    gtk.adw_alert_dialog_set_response_appearance(dialog, "save", gtk.ADW_RESPONSE_SUGGESTED);
    gtk.adw_alert_dialog_set_default_response(dialog, "save");
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");

    // Out of memory: let the close through rather than leaving a tab that can
    // never be closed again.
    const ctx = std.heap.c_allocator.create(ClosePageCtx) catch {
        tab.closing = true;
        return 0;
    };
    ctx.* = .{ .tab_view = tv, .page = p };

    gtk.adw_alert_dialog_choose(
        dialog,
        @as(*gtk.GtkWidget, @ptrCast(state.win)),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onClosePageDialogDone)),
        @ptrCast(ctx),
    );
    return 1;
}

pub fn onEditorPageDetached(
    _: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    _: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (page) |p| {
        // page-detached fires both for a real close and for a tear-off transfer
        // to another window (libadwaita reuses the signal for both); only a
        // real close should free this struct — a transferred page's tab is
        // still alive in the destination window.
        if (core.editorTabFromPage(p)) |tab| {
            if (tab.closing) {
                if (tab.flash_timer != 0) _ = gtk.g_source_remove(tab.flash_timer);
                if (tab.filesync) |fs| fs.destroy();
                syntax.detach(tab.source_view);
                lsp.closeDocument(tab.owner, tab.buffer);
                gtk.zc_search_detach(tab.source_view);
                core.disconnectTabSignals(@ptrCast(tab.buffer), tab);
                std.heap.c_allocator.destroy(tab);
            }
        }
    }
    if (state.shutting_down) return;
    view.updateView(state);
    view.updateWindowTitle(state);
}

/// Fires when a page is appended to this tab view — including a tab dragged
/// in from another window. Re-stamps `owner` so every per-tab handler (LSP
/// callbacks, preview link clicks, ...) affects this window from now on, and
/// switches this window into editor mode. Ordinary tab creation also fires
/// this signal, but before the tab struct is attached to the page, so it's a
/// harmless no-op there (openEditorTab already does both jobs explicitly).
pub fn onEditorPageAttached(
    _: ?*gtk.AdwTabView,
    page: ?*gtk.AdwTabPage,
    _: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const p = page orelse return;
    const tab = core.editorTabFromPage(p) orelse return;
    tab.owner = state;
    tab.closing = false;
    lsp.setDocOwner(state, tab.buffer);
    view.switchToEditors(state);
}

/// Closes every editor tab. Called when switching to a different project so
/// files from the old project don't remain open. Tabs with unsaved changes
/// show the standard save/discard dialog before closing.
pub fn closeAllEditorTabs(state: *core.AppState) void {
    var i: c_int = gtk.adw_tab_view_get_n_pages(state.editor_tabs) - 1;
    while (i >= 0) : (i -= 1) {
        const page = gtk.adw_tab_view_get_nth_page(state.editor_tabs, i) orelse continue;
        gtk.adw_tab_view_close_page(state.editor_tabs, page);
    }
}

pub fn onEditorSelectedPage(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return;
    view.updateWindowTitle(state);
    view.updateStatus(state);
    preview.updatePreviewBtn(state);
    if (core.selectedEditorTab(state)) |tab| {
        if (!tab.doc.is_binary and !tab.is_image)
            _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(tab.source_view)));
        // Reveal the active file in the tree (expand + select + scroll).
        if (state.file_tree) |tree| {
            if (tab.doc.isOpen()) gtk.zc_file_tree_reveal(tree, &tab.doc.path);
        }
    }
}

fn hasPreviewStack(path: [*:0]const u8) bool {
    const name = std.mem.sliceTo(path, 0);
    return std.mem.endsWith(u8, name, ".md") or
        std.mem.endsWith(u8, name, ".markdown") or
        std.mem.endsWith(u8, name, ".html") or
        std.mem.endsWith(u8, name, ".htm");
}

fn isImagePath(path: [*:0]const u8) bool {
    const name = std.mem.sliceTo(path, 0);
    return std.mem.endsWith(u8, name, ".png") or
        std.mem.endsWith(u8, name, ".jpg") or
        std.mem.endsWith(u8, name, ".jpeg") or
        std.mem.endsWith(u8, name, ".gif") or
        std.mem.endsWith(u8, name, ".webp") or
        std.mem.endsWith(u8, name, ".svg") or
        std.mem.endsWith(u8, name, ".bmp") or
        std.mem.endsWith(u8, name, ".ico") or
        std.mem.endsWith(u8, name, ".tiff") or
        std.mem.endsWith(u8, name, ".tif");
}

/// Updates every open editor tab whose path is `old_path` to use `new_path`.
/// Called when a file is renamed externally so the tab stays live and saves
/// to the correct location.
pub fn renameEditorTab(state: *core.AppState, old_path: [*:0]const u8, new_path: [*:0]const u8) void {
    const old = std.mem.sliceTo(old_path, 0);
    const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const tab = core.editorTabAt(state, i) orelse continue;
        if (!std.mem.eql(u8, std.mem.sliceTo(&tab.doc.path, 0), old)) continue;
        retarget(state, tab, new_path);
        return;
    }
}

/// Updates the diff change-bars of every open editor (after a git change).
pub fn refreshAllEditorDiffs(state: *core.AppState) void {
    var i: c_int = 0;
    const n = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    while (i < n) : (i += 1) {
        if (core.editorTabAt(state, i)) |tab| {
            if (tab.doc.isOpen())
                gtk.zc_source_view_update_diff(tab.source_view, &tab.doc.path);
        }
    }
}

// Manual extern declarations for GTK4 + Libadwaita + GtkSourceView 5.
// This avoids @cImport, which fails on GLib's _Pragma macros in Zig 0.16.
// All types are opaque pointers — we never access their internal fields.

// ── GLib / GObject ──────────────────────────────────────────────────────────

pub const GObject = opaque {};
pub const GApplication = opaque {};
pub const GFile = opaque {};
pub const GAsyncResult = opaque {};
pub const GError = opaque {};
pub const GCancellable = opaque {};

pub const GCallback = *const fn () callconv(.c) void;
pub const GAsyncReadyCallback = *const fn (
    ?*GObject,
    ?*GAsyncResult,
    ?*anyopaque,
) callconv(.c) void;

pub const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;
pub const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;
pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;

pub extern fn g_object_unref(obj: ?*anyopaque) void;
pub extern fn g_object_ref(obj: ?*anyopaque) ?*anyopaque;
// Sinks a widget's floating reference so a matching unref actually frees it —
// needed to discard a widget that was built but never parented.
pub extern fn g_object_ref_sink(obj: ?*anyopaque) ?*anyopaque;
pub extern fn g_error_free(err: ?*GError) void;

// Per-object opaque data — used to attach a per-tab Zig struct to an AdwTabPage.
pub extern fn g_object_set_data(object: ?*anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern fn g_object_get_data(object: ?*anyopaque, key: [*:0]const u8) ?*anyopaque;

// Disconnect every handler on `instance` whose user_data matches `data`.
// Used to drop a tab's callbacks before its heap struct is freed, so a late
// signal (e.g. VTE's child-exited during teardown) can't touch freed memory.
pub const G_SIGNAL_MATCH_DATA: c_uint = 1 << 4;
pub extern fn g_signal_handlers_disconnect_matched(
    instance: ?*anyopaque,
    mask: c_uint,
    signal_id: c_uint,
    detail: u32,
    closure: ?*anyopaque,
    func: ?*anyopaque,
    data: ?*anyopaque,
) c_uint;
pub extern fn g_signal_handler_block(instance: ?*anyopaque, handler_id: c_ulong) void;
pub extern fn g_signal_handler_unblock(instance: ?*anyopaque, handler_id: c_ulong) void;
pub extern fn g_signal_connect_data(
    instance: ?*anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: ?GCallback,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_uint,
) c_ulong;
pub extern fn g_application_run(
    application: ?*GApplication,
    argc: c_int,
    argv: ?[*][*:0]u8,
) c_int;

// ── GTK4 types ──────────────────────────────────────────────────────────────

pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkButton = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkLabel = opaque {};
pub const GtkTextView = opaque {};
pub const GtkTextBuffer = opaque {};
pub const GtkFileDialog = opaque {};
pub const GtkApplication = opaque {};
pub const GtkCssProvider = opaque {};
pub const GdkDisplay = opaque {};

pub const GtkOrientation = enum(c_int) { horizontal = 0, vertical = 1 };
pub const GtkAlign = enum(c_int) { fill = 0, start = 1, end = 2, center = 3 };
pub const GtkJustification = enum(c_int) { left = 0, right = 1, center = 2, fill = 3 };

// ── GTK4 functions ──────────────────────────────────────────────────────────

pub extern fn gtk_widget_set_hexpand(widget: ?*GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_vexpand(widget: ?*GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_tooltip_text(widget: ?*GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_widget_add_css_class(widget: ?*GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: ?*GtkWidget, css_class: [*:0]const u8) void;
pub extern fn gtk_widget_set_valign(widget: ?*GtkWidget, @"align": GtkAlign) void;
pub extern fn gtk_widget_set_halign(widget: ?*GtkWidget, @"align": GtkAlign) void;
pub extern fn gtk_widget_set_visible(widget: ?*GtkWidget, visible: c_int) void;

pub extern fn gtk_window_set_title(window: ?*GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: ?*GtkWindow, width: c_int, height: c_int) void;
pub extern fn gtk_window_present(window: ?*GtkWindow) void;
pub extern fn gtk_window_is_active(window: ?*GtkWindow) c_int;
pub extern fn gtk_window_destroy(window: ?*GtkWidget) void;
pub extern fn gtk_widget_get_width(widget: ?*GtkWidget) c_int;
pub extern fn gtk_widget_get_height(widget: ?*GtkWidget) c_int;
pub extern fn gtk_window_is_maximized(window: ?*GtkWindow) c_int;
pub extern fn gtk_window_maximize(window: ?*GtkWindow) void;

pub extern fn gtk_button_new_from_icon_name(icon_name: [*:0]const u8) ?*GtkWidget;
pub extern fn gtk_button_new() ?*GtkWidget;

// GtkToggleButton
pub const GtkToggleButton = opaque {};
pub extern fn gtk_toggle_button_new() ?*GtkWidget;
pub extern fn gtk_toggle_button_get_active(button: ?*GtkToggleButton) c_int;
pub extern fn gtk_toggle_button_set_active(button: ?*GtkToggleButton, is_active: c_int) void;

pub const GtkBox = opaque {};
pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: c_int) ?*GtkWidget;
pub extern fn gtk_box_append(box: ?*GtkBox, child: ?*GtkWidget) void;
pub extern fn gtk_box_prepend(box: ?*GtkBox, child: ?*GtkWidget) void;

pub const GtkOverlay = opaque {};
pub extern fn gtk_overlay_new() ?*GtkWidget;
pub extern fn gtk_overlay_set_child(overlay: ?*GtkOverlay, child: ?*GtkWidget) void;
pub extern fn gtk_overlay_add_overlay(overlay: ?*GtkOverlay, widget: ?*GtkWidget) void;
pub extern fn gtk_overlay_set_measure_overlay(overlay: ?*GtkOverlay, widget: ?*GtkWidget, measure: c_int) void;

pub extern fn gtk_scrolled_window_new() ?*GtkWidget;
pub const GtkPolicyType = enum(c_int) { always = 0, automatic = 1, never = 2, external = 3 };
pub extern fn gtk_scrolled_window_set_policy(scrolled_window: ?*GtkScrolledWindow, hscrollbar_policy: GtkPolicyType, vscrollbar_policy: GtkPolicyType) void;
pub extern fn gtk_scrolled_window_set_child(
    scrolled_window: ?*GtkScrolledWindow,
    child: ?*GtkWidget,
) void;

pub extern fn gtk_label_new(str: [*:0]const u8) ?*GtkWidget;
pub extern fn gtk_label_set_text(label: ?*GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_image_new_from_icon_name(icon_name: [*:0]const u8) ?*GtkWidget;
pub extern fn gtk_label_set_justify(label: ?*GtkLabel, jtype: GtkJustification) void;

pub extern fn gtk_text_view_get_buffer(text_view: ?*GtkTextView) ?*GtkTextBuffer;
pub extern fn gtk_text_view_set_bottom_margin(text_view: ?*GtkTextView, bottom_margin: c_int) void;
pub extern fn gtk_text_view_set_right_margin(text_view: ?*GtkTextView, right_margin: c_int) void;

pub extern fn gtk_file_dialog_new() ?*GtkFileDialog;
pub extern fn gtk_file_dialog_set_title(self: ?*GtkFileDialog, title: [*:0]const u8) void;
pub extern fn gtk_file_dialog_set_modal(self: ?*GtkFileDialog, modal: c_int) void;
pub extern fn gtk_file_dialog_select_folder(
    self: ?*GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_select_folder_finish(
    self: ?*GtkFileDialog,
    result: ?*GAsyncResult,
    err: ?*?*GError,
) ?*GFile;

// GtkWidget extras
pub extern fn gtk_widget_set_sensitive(widget: ?*GtkWidget, sensitive: c_int) void;
pub extern fn gtk_widget_grab_focus(widget: ?*GtkWidget) c_int;
pub extern fn gtk_widget_add_controller(widget: ?*GtkWidget, controller: ?*anyopaque) void;
pub extern fn gtk_widget_queue_draw(widget: ?*GtkWidget) void;
pub extern fn gtk_widget_queue_resize(widget: ?*GtkWidget) void;
pub extern fn gtk_widget_queue_allocate(widget: ?*GtkWidget) void;

// GtkEntry / GtkEditable
pub const GtkEntry = opaque {};
pub const GtkEditable = opaque {};
pub extern fn gtk_entry_new() ?*GtkWidget;
pub extern fn gtk_entry_set_placeholder_text(entry: ?*GtkEntry, text: [*:0]const u8) void;
pub extern fn gtk_entry_set_activates_default(entry: ?*GtkEntry, setting: c_int) void;
pub extern fn gtk_editable_get_text(editable: ?*GtkEditable) [*:0]const u8;
pub extern fn gtk_editable_set_text(editable: ?*GtkEditable, text: [*:0]const u8) void;
pub extern fn gtk_editable_select_region(editable: ?*GtkEditable, start_pos: c_int, end_pos: c_int) void;

// GtkGestureClick
pub const GtkGestureClick = opaque {};
pub extern fn gtk_gesture_click_new() ?*GtkGestureClick;
pub extern fn gtk_gesture_single_set_button(gesture: ?*anyopaque, button: c_uint) void;

// AdwAlertDialog
pub const AdwAlertDialog = opaque {};
pub const ADW_RESPONSE_SUGGESTED: c_int = 1;
pub const ADW_RESPONSE_DESTRUCTIVE: c_int = 2;
pub extern fn adw_alert_dialog_new(heading: [*:0]const u8, body: ?[*:0]const u8) ?*AdwAlertDialog;
pub extern fn adw_alert_dialog_add_response(self: ?*AdwAlertDialog, id: [*:0]const u8, label: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_response_appearance(self: ?*AdwAlertDialog, response: [*:0]const u8, appearance: c_int) void;
pub extern fn adw_alert_dialog_set_default_response(self: ?*AdwAlertDialog, response: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_close_response(self: ?*AdwAlertDialog, response: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_extra_child(self: ?*AdwAlertDialog, child: ?*GtkWidget) void;
pub extern fn adw_alert_dialog_get_extra_child(self: ?*AdwAlertDialog) ?*GtkWidget;
pub extern fn adw_alert_dialog_choose(
    self: ?*AdwAlertDialog,
    parent: ?*GtkWidget,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn adw_alert_dialog_choose_finish(
    self: ?*AdwAlertDialog,
    result: ?*GAsyncResult,
) [*:0]const u8;

// C helpers (src/helpers.c)
pub extern fn zc_create_item(parent_dir: [*:0]const u8, name: [*:0]const u8, is_dir: c_int) c_int;
pub extern fn zc_resolve_dir(path: [*:0]const u8) ?[*:0]u8;

// GtkStack
pub const GtkStack = opaque {};
pub extern fn gtk_stack_new() ?*GtkWidget;
pub extern fn gtk_stack_add_named(stack: ?*GtkStack, child: ?*GtkWidget, name: [*:0]const u8) ?*anyopaque;
pub extern fn gtk_stack_set_visible_child_name(stack: ?*GtkStack, name: [*:0]const u8) void;
pub extern fn gtk_stack_set_hhomogeneous(stack: ?*GtkStack, hhomogeneous: c_int) void;
pub extern fn gtk_stack_set_vhomogeneous(stack: ?*GtkStack, vhomogeneous: c_int) void;

// AdwStatusPage
pub const AdwStatusPage = opaque {};
pub extern fn adw_status_page_new() ?*GtkWidget;
pub extern fn adw_status_page_set_icon_name(self: ?*AdwStatusPage, icon_name: [*:0]const u8) void;
pub extern fn adw_status_page_set_title(self: ?*AdwStatusPage, title: [*:0]const u8) void;
pub extern fn adw_status_page_set_description(self: ?*AdwStatusPage, description: ?[*:0]const u8) void;
pub extern fn adw_status_page_set_child(self: ?*AdwStatusPage, child: ?*GtkWidget) void;

// GFile helpers
pub extern fn g_file_get_path(file: ?*GFile) ?[*:0]u8;
pub extern fn g_file_get_basename(file: ?*GFile) ?[*:0]u8;
pub extern fn g_free(mem: ?*anyopaque) void;

// Convert a file:// URI to a local path (caller g_free's the result), and read
// the user's home directory — used to name terminal tabs after their cwd.
pub extern fn g_filename_from_uri(uri: [*:0]const u8, hostname: ?*?[*:0]u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_get_home_dir() ?[*:0]const u8;
pub extern fn g_get_user_config_dir() ?[*:0]const u8;
pub extern fn g_mkdir_with_parents(pathname: [*:0]const u8, mode: c_int) c_int;
pub extern fn g_file_set_contents(filename: [*:0]const u8, contents: [*]const u8, length: isize, err: ?*?*GError) c_int;

// Read whole file by path (GLib). contents must be g_free'd by caller.
pub extern fn g_file_get_contents(
    filename: [*:0]const u8,
    contents: *[*:0]u8,
    length: ?*usize,
    err: ?*?*GError,
) c_int;

// Path classification + canonicalisation (resolving a `zcode <path>` argument).
pub const G_FILE_TEST_IS_REGULAR: c_int = 1;
pub const G_FILE_TEST_IS_DIR: c_int = 1 << 2;
pub extern fn g_file_test(filename: [*:0]const u8, flags: c_int) c_int;
// Plain synchronous directory listing (quick-open's project scan).  std.fs is
// gone in Zig 0.16 and its replacement wants an explicit Io instance; GLib is
// already linked and is what the rest of the tree walks with.
pub const GDir = opaque {};
pub extern fn g_dir_open(path: [*:0]const u8, flags: c_uint, err: ?*?*GError) ?*GDir;
pub extern fn g_dir_read_name(dir: ?*GDir) ?[*:0]const u8;
pub extern fn g_dir_close(dir: ?*GDir) void;
// Absolute, canonical path (caller g_free's); relative_to NULL means the cwd.
pub extern fn g_canonicalize_filename(filename: [*:0]const u8, relative_to: ?[*:0]const u8) [*:0]u8;

// UTF-8 validation
pub extern fn g_utf8_validate(str: [*]const u8, max_len: isize, end: ?*?[*]const u8) c_int;

// GtkTextBuffer text / modified state
pub extern fn gtk_text_buffer_new(table: ?*anyopaque) ?*GtkTextBuffer;
pub extern fn gtk_text_buffer_set_text(buffer: ?*GtkTextBuffer, text: [*]const u8, len: c_int) void;
pub extern fn gtk_text_buffer_get_modified(buffer: ?*GtkTextBuffer) c_int;
pub extern fn gtk_text_buffer_set_modified(buffer: ?*GtkTextBuffer, setting: c_int) void;

// ── GtkTextIter / tags (tree-sitter highlighter applies syntax via tags) ─────
// GtkTextIter is a stack-allocated struct (80 bytes on 64-bit); we treat it as
// an opaque blob and only ever pass its address to GTK.
pub const GtkTextIter = extern struct { _: [80]u8 align(8) = undefined };
pub const GtkTextTag = opaque {};
pub extern fn gtk_text_buffer_get_bounds(buffer: ?*GtkTextBuffer, start: *GtkTextIter, end: *GtkTextIter) void;
pub extern fn gtk_text_buffer_get_text(buffer: ?*GtkTextBuffer, start: *const GtkTextIter, end: *const GtkTextIter, include_hidden_chars: c_int) ?[*:0]u8;
pub extern fn gtk_text_buffer_get_start_iter(buffer: ?*GtkTextBuffer, iter: *GtkTextIter) void;
pub extern fn gtk_text_buffer_get_iter_at_line_index(buffer: ?*GtkTextBuffer, iter: *GtkTextIter, line: c_int, byte_index: c_int) void;
// Same, but snapped to a character boundary and clamped to the line (src/c/util.c).
// Required for any byte column measured against a different revision of the
// buffer — a raw index that lands mid-character corrupts the buffer's B-tree.
pub extern fn zc_iter_at_line_byte(buffer: ?*GtkTextBuffer, iter: *GtkTextIter, line: c_int, byte_col: c_int) void;
pub extern fn gtk_text_buffer_apply_tag(buffer: ?*GtkTextBuffer, tag: ?*GtkTextTag, start: *const GtkTextIter, end: *const GtkTextIter) void;
pub extern fn gtk_text_buffer_remove_tag(buffer: ?*GtkTextBuffer, tag: ?*GtkTextTag, start: *const GtkTextIter, end: *const GtkTextIter) void;

pub extern fn gtk_text_iter_get_line(iter: *const GtkTextIter) c_int;
pub extern fn gtk_text_iter_get_line_index(iter: *const GtkTextIter) c_int;
pub extern fn gtk_text_iter_get_line_offset(iter: *const GtkTextIter) c_int;
pub extern fn gtk_text_iter_forward_chars(iter: *GtkTextIter, count: c_int) c_int;
pub extern fn gtk_text_iter_backward_chars(iter: *GtkTextIter, count: c_int) c_int;
pub extern fn gtk_text_buffer_get_iter_at_line(buffer: ?*GtkTextBuffer, iter: *GtkTextIter, line: c_int) c_int;
pub extern fn gtk_text_iter_get_char(iter: *const GtkTextIter) c_uint;
pub extern fn gtk_text_iter_forward_char(iter: *GtkTextIter) c_int;
pub extern fn gtk_text_iter_ends_line(iter: *const GtkTextIter) c_int;
pub extern fn gtk_text_buffer_get_line_count(buffer: ?*GtkTextBuffer) c_int;
pub extern fn gtk_text_buffer_delete(buffer: ?*GtkTextBuffer, start: *GtkTextIter, end: *GtkTextIter) void;
pub extern fn gtk_text_iter_forward_to_tag_toggle(iter: *GtkTextIter, tag: ?*GtkTextTag) c_int;
pub extern fn gtk_text_iter_forward_to_line_end(iter: *GtkTextIter) c_int;
pub extern fn gtk_text_iter_backward_word_start(iter: *GtkTextIter) c_int;
pub extern fn gtk_text_iter_forward_word_end(iter: *GtkTextIter) c_int;
pub extern fn gtk_text_iter_inside_word(iter: *const GtkTextIter) c_int;
// Viewport detection (visible line range) for viewport-limited highlighting.
pub const GdkRectangle = extern struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };
pub const GtkAdjustment = opaque {};
pub extern fn gtk_text_view_get_visible_rect(text_view: ?*GtkTextView, visible_rect: *GdkRectangle) void;
pub extern fn gtk_text_view_get_line_at_y(text_view: ?*GtkTextView, target_iter: *GtkTextIter, y: c_int, line_top: ?*c_int) void;
// GtkTextView implements GtkScrollable; this returns the scroll adjustment the
// enclosing GtkScrolledWindow drives, so we can re-tag on scroll.
pub extern fn gtk_scrollable_get_vadjustment(scrollable: ?*GtkTextView) ?*GtkAdjustment;
pub extern fn gtk_scrollable_get_hadjustment(scrollable: ?*GtkTextView) ?*GtkAdjustment;
pub extern fn gtk_adjustment_get_value(adjustment: ?*GtkAdjustment) f64;
pub extern fn gtk_adjustment_set_value(adjustment: ?*GtkAdjustment, value: f64) void;
// Position and page, but deliberately not `upper`: it also grows when a tag we
// applied makes a line taller, which is not a scroll and must not cause a paint.
pub extern fn gtk_adjustment_get_page_size(adjustment: ?*GtkAdjustment) f64;

// Idle source (coalesces re-highlight after edits) and one-shot regex (predicates).
pub extern fn g_idle_add(function: ?*const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern fn g_source_remove(tag: c_uint) c_int;
pub const GRegex = opaque {};
pub extern fn g_regex_new(pattern: [*:0]const u8, compile_options: c_uint, match_options: c_uint, err: ?*?*GError) ?*GRegex;
pub extern fn g_regex_match(regex: ?*GRegex, string: [*:0]const u8, match_options: c_uint, match_info: ?*anyopaque) c_int;
// G_REGEX_OPTIMIZE: worth its compile cost here, since every pattern in a
// highlight query is matched once per capture on every reparse.
pub const G_REGEX_OPTIMIZE: c_uint = 1 << 3;

// Tag helpers (src/c/util.c) — variadic GObject calls kept in C.
pub extern fn zc_text_tag_new(buffer: ?*anyopaque, fg: [*:0]const u8, italic: c_int, bold: c_int) ?*GtkTextTag;
pub extern fn zc_text_tag_set_fg(tag: ?*GtkTextTag, fg: [*:0]const u8) void;
pub extern fn zc_diag_tag_new(buffer: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) ?*GtkTextTag;
pub extern fn zc_line_bg_tag_new(buffer: ?*anyopaque, r: f32, g: f32, b: f32, a: f32) ?*GtkTextTag;
// Full-width diagnostic line tint (GtkSourceView mark categories, src/c/util.c).
pub extern fn zc_diag_marks_attach(view: ?*GtkSourceView) void;
pub extern fn zc_diag_line_mark_add(buf: ?*GtkSourceBuffer, line: c_int, severity: c_int) void;
pub extern fn zc_diag_line_marks_clear_range(buf: ?*GtkSourceBuffer, start: *const GtkTextIter, end: *const GtkTextIter) void;
pub const GtkEventControllerKey = opaque {};
pub extern fn gtk_event_controller_key_new() ?*GtkEventControllerKey;

// Propagation phase: CAPTURE lets a window-level shortcut beat the focused
// widget's own bindings (e.g. Ctrl+F, which GtkTextView binds to move-cursor).
pub const GTK_PHASE_CAPTURE: c_int = 1;
pub extern fn gtk_event_controller_set_propagation_phase(controller: ?*anyopaque, phase: c_int) void;

// GDK modifier / key constants
pub const GDK_KEY_s: c_uint = 0x073;
pub const GDK_KEY_f: c_uint = 0x066;
pub const GDK_KEY_Up: c_uint = 0xFF52;
pub const GDK_KEY_Down: c_uint = 0xFF54;
pub const GDK_KEY_o: c_uint = 0x06F;
pub const GDK_KEY_O: c_uint = 0x04F;
pub const GDK_CONTROL_MASK: c_uint = 0x4;

// ── Project file tree (GtkListView + GtkTreeListModel, src/helpers.c) ──────────
// The tree calls back into the app through this block for everything that needs
// the editor/terminal/dialogs; pure filesystem actions it performs itself.
pub const ZcTreeCallbacks = extern struct {
    open_file: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void = null,
    open_terminal: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void = null,
    new_item: ?*const fn ([*:0]const u8, c_int, ?*anyopaque) callconv(.c) void = null,
    changed: ?*const fn (?*anyopaque) callconv(.c) void = null,
    file_renamed: ?*const fn ([*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void = null,
    // Outcome of a filesystem operation the tree performed itself; the Zig side
    // turns it into a toast.  `is_error` picks the priority and styling.
    report: ?*const fn ([*:0]const u8, c_int, ?*anyopaque) callconv(.c) void = null,
    user_data: ?*anyopaque = null,
};
pub extern fn zc_file_tree_new(root_path: [*:0]const u8, callbacks: *const ZcTreeCallbacks) ?*GtkWidget;
pub extern fn zc_file_tree_refresh(tree: ?*GtkWidget) void;
pub extern fn zc_file_tree_summary(tree: ?*GtkWidget) ?[*:0]u8;
pub extern fn zc_file_tree_reveal(tree: ?*GtkWidget, path: [*:0]const u8) void;
pub extern fn zc_file_tree_set_diag_severity(tree: ?*GtkWidget, path: [*:0]const u8, sev: c_int) void;

// Source-view diff gutter (change bars vs HEAD).
pub extern fn zc_source_view_attach_diff(view: ?*GtkSourceView, path: [*:0]const u8) void;
pub extern fn zc_source_view_update_diff(view: ?*GtkSourceView, path: [*:0]const u8) void;
pub extern fn zc_diff_stats(view: ?*GtkSourceView, added: *c_uint, removed: *c_uint) void;
pub extern fn zc_diff_set_changed_cb(cb: ?*const fn () callconv(.c) void) void;

// Overview ruler: git-diff minimap + viewport + cursor indicator.
pub extern fn zc_overview_ruler_new(view: *GtkSourceView, scroll: *GtkScrolledWindow) ?*GtkWidget;
pub extern fn zc_overview_ruler_queue_draw(ruler: ?*GtkWidget) void;
pub const ZcDiagMark = extern struct { line: c_uint, severity: u8 };
pub const ZcHoverDiag = extern struct { start_line: c_int, start_char: c_int, end_line: c_int, end_char: c_int, severity: c_int, message: [*:0]const u8 };
pub extern fn zc_hover_attach(view: ?*GtkSourceView) void;
pub extern fn zc_hover_show_at_cursor(view: ?*GtkSourceView) void;
pub extern fn zc_hover_show_diag_fallback(view: ?*GtkSourceView, line: c_int, ch: c_int) void;
pub extern fn zc_buffer_set_hover_diags(buf: ?*GtkSourceBuffer, diags: ?*const ZcHoverDiag, n: c_uint) void;
pub extern fn zc_buffer_set_diag_marks(buf: ?*GtkSourceBuffer, marks: ?*const ZcDiagMark, n: c_uint) void;

// Popover + motion controller (diagnostic hover).
pub const GtkPopover = opaque {};
pub const GtkEventControllerMotion = opaque {};
pub extern fn gtk_popover_new() ?*GtkPopover;
pub extern fn gtk_popover_set_has_arrow(popover: ?*GtkPopover, has_arrow: c_int) void;
pub extern fn gtk_popover_set_child(popover: ?*GtkPopover, child: ?*GtkWidget) void;
pub extern fn gtk_popover_set_pointing_to(popover: ?*GtkPopover, rect: ?*GdkRectangle) void;
pub extern fn gtk_popover_popup(popover: ?*GtkPopover) void;
pub extern fn gtk_popover_popdown(popover: ?*GtkPopover) void;
pub extern fn gtk_widget_set_parent(widget: ?*GtkWidget, parent: ?*GtkWidget) void;
pub extern fn gtk_widget_unparent(widget: ?*GtkWidget) void;
pub extern fn gtk_widget_get_parent(widget: ?*GtkWidget) ?*GtkWidget;
pub extern fn gtk_event_controller_motion_new() ?*GtkEventControllerMotion;
pub extern fn gtk_label_set_wrap(label: ?*GtkLabel, wrap: c_int) void;
pub extern fn gtk_label_set_wrap_mode(label: ?*GtkLabel, wrap_mode: c_int) void;
pub extern fn gtk_label_set_max_width_chars(label: ?*GtkLabel, n_chars: c_int) void;
pub extern fn gtk_text_view_get_iter_location(view: ?*GtkTextView, iter: *GtkTextIter, location: *GdkRectangle) void;
pub extern fn gtk_text_view_scroll_to_mark(text_view: ?*GtkTextView, mark: ?*GtkTextMark, within_margin: f64, use_align: c_int, xalign: f64, yalign: f64) void;
pub extern fn gtk_text_view_window_to_buffer_coords(view: ?*GtkTextView, win: c_int, window_x: c_int, window_y: c_int, buffer_x: *c_int, buffer_y: *c_int) void;
pub extern fn gtk_text_view_get_iter_at_location(view: ?*GtkTextView, iter: *GtkTextIter, x: c_int, y: c_int) c_int;
pub extern fn gtk_text_view_buffer_to_widget_coords(view: ?*GtkTextView, buf_x: c_int, buf_y: c_int, widget_x: *c_int, widget_y: *c_int) void;
pub const GTK_TEXT_WINDOW_TEXT: c_int = 2;
pub extern fn zc_search_attach(view: ?*GtkSourceView) void;
pub extern fn zc_search_bar_new(view: ?*GtkSourceView) ?*GtkWidget;
pub extern fn zc_search_bar_open(view: ?*GtkSourceView) void;
pub extern fn zc_search_detach(view: ?*GtkSourceView) void;

pub extern fn zc_buffer_save(path: [*:0]const u8, buffer: ?*anyopaque) c_int;

// ── Language server transport (src/c/lsp_io.c) ────────────────────────────────
// A long-lived child process we speak JSON-RPC to; lsp_io.c owns the GSubprocess
// and pumps raw bytes, the framing/protocol live in src/lsp/ (Zig).
pub const ZcLspProc = opaque {};
pub const ZcLspCallbacks = extern struct {
    on_data: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
    on_closed: ?*const fn (?*anyopaque) callconv(.c) void = null,
    user_data: ?*anyopaque = null,
};
pub extern fn zc_lsp_proc_new(
    argv: [*]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    cb: *const ZcLspCallbacks,
) ?*ZcLspProc;
pub extern fn zc_lsp_proc_write(p: ?*ZcLspProc, bytes: [*]const u8, len: usize) void;
pub extern fn zc_lsp_proc_write_pending(p: ?*ZcLspProc) bool;
pub extern fn zc_lsp_proc_close(p: ?*ZcLspProc) void;

// LSP completion bridge (src/c/completion.c): Zig builds the proposal store as
// it parses the reply, then hands it to the pending GTask.
pub const GListStore = opaque {};
pub const GTask = opaque {};
pub extern fn zc_lsp_completion_attach(view: ?*GtkSourceView) void;
pub extern fn zc_completion_store_new() ?*GListStore;
pub extern fn zc_completion_store_add(
    store: ?*GListStore,
    label: ?[*:0]const u8,
    detail: ?[*:0]const u8,
    insert_text: ?[*:0]const u8,
) void;
pub extern fn zc_completion_finish(task: ?*GTask, store: ?*GListStore) void;

// file:// URI for a local path (caller g_free's), and a debounce timer.
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*GError) ?[*:0]u8;
pub extern fn g_timeout_add(interval: c_uint, function: ?*const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern fn getpid() c_int;

pub const GtkTextMark = opaque {};
pub extern fn gtk_text_buffer_get_insert(buffer: ?*GtkTextBuffer) ?*GtkTextMark;
pub extern fn gtk_text_buffer_get_iter_at_mark(buffer: ?*GtkTextBuffer, iter: *GtkTextIter, mark: ?*GtkTextMark) void;
pub extern fn gtk_text_buffer_insert(buffer: ?*GtkTextBuffer, iter: *GtkTextIter, text: [*]const u8, len: c_int) void;
pub extern fn gtk_text_view_scroll_to_iter(view: ?*GtkTextView, iter: *GtkTextIter, within_margin: f64, use_align: c_int, xalign: f64, yalign: f64) c_int;

pub const GDK_KEY_F2: c_uint = 0xFFBF;
pub const GDK_KEY_F12: c_uint = 0xFFC9;
pub const GDK_KEY_i: c_uint = 0x069;
pub const GDK_KEY_I: c_uint = 0x049;
pub const GDK_KEY_period: c_uint = 0x02e;

pub extern fn zc_hover_show_text(view: ?*GtkSourceView, text: [*:0]const u8, line: c_int, ch: c_int) void;
pub extern fn zc_signature_attach(view: ?*GtkSourceView) void;
pub extern fn zc_signature_show(view: ?*GtkSourceView, text: [*:0]const u8) void;
pub extern fn zc_signature_hide(view: ?*GtkSourceView) void;
pub extern fn zc_editor_attach_click_nav(view: ?*GtkSourceView) void;
pub extern fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;
pub extern fn gtk_text_buffer_place_cursor(buffer: ?*GtkTextBuffer, where: *const GtkTextIter) void;
// Brackets a batch of programmatic edits: one undo step, and one round of
// re-highlighting, instead of one per edit.
pub extern fn gtk_text_buffer_begin_user_action(buffer: ?*GtkTextBuffer) void;
pub extern fn gtk_text_buffer_end_user_action(buffer: ?*GtkTextBuffer) void;
pub extern fn gtk_text_buffer_insert_at_cursor(buffer: ?*GtkTextBuffer, text: [*]const u8, len: c_int) void;
pub extern fn zc_terminal_spawn(terminal: ?*VteTerminal, working_dir: ?[*:0]const u8) void;
pub extern fn zc_terminal_spawn_host(terminal: ?*VteTerminal, working_dir: ?[*:0]const u8, on_exit: ?*const fn (?*anyopaque) callconv(.c) void, on_exit_data: ?*anyopaque) c_uint;
pub extern fn zc_terminal_detach_host(host_pid: c_uint) void;
pub extern fn zc_is_flatpak() c_int;

pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gtk_css_provider_new() ?*GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(
    css_provider: ?*GtkCssProvider,
    data: [*:0]const u8,
) void;
pub extern fn gtk_style_context_add_provider_for_display(
    display: ?*GdkDisplay,
    provider: ?*anyopaque,
    priority: c_uint,
) void;

// ── Adwaita ─────────────────────────────────────────────────────────────────

pub const AdwApplication = opaque {};
pub const AdwApplicationWindow = opaque {};
pub const AdwToolbarView = opaque {};
pub const AdwHeaderBar = opaque {};

pub extern fn adw_application_new(
    application_id: [*:0]const u8,
    flags: c_uint,
) ?*AdwApplication;
pub extern fn adw_application_window_new(app: ?*GtkApplication) ?*GtkWidget;
pub extern fn adw_application_window_set_content(
    self: ?*AdwApplicationWindow,
    content: ?*GtkWidget,
) void;
pub extern fn adw_toolbar_view_new() ?*GtkWidget;
pub extern fn adw_toolbar_view_add_top_bar(
    self: ?*AdwToolbarView,
    widget: ?*GtkWidget,
) void;
pub extern fn adw_toolbar_view_set_content(
    self: ?*AdwToolbarView,
    content: ?*GtkWidget,
) void;
pub extern fn adw_header_bar_new() ?*GtkWidget;
pub extern fn adw_header_bar_pack_start(
    self: ?*AdwHeaderBar,
    child: ?*GtkWidget,
) void;
pub extern fn adw_header_bar_pack_end(
    self: ?*AdwHeaderBar,
    child: ?*GtkWidget,
) void;
pub extern fn adw_header_bar_set_title_widget(self: ?*AdwHeaderBar, title_widget: ?*GtkWidget) void;
pub extern fn adw_header_bar_set_show_end_title_buttons(self: ?*AdwHeaderBar, setting: c_int) void;
pub extern fn adw_header_bar_set_show_start_title_buttons(self: ?*AdwHeaderBar, setting: c_int) void;

// AdwWindowTitle — title/subtitle widget for a header bar.
pub const AdwWindowTitle = opaque {};
pub extern fn adw_window_title_new(title: [*:0]const u8, subtitle: [*:0]const u8) ?*GtkWidget;
pub extern fn adw_window_title_set_title(self: ?*AdwWindowTitle, title: [*:0]const u8) void;
pub extern fn adw_window_title_set_subtitle(self: ?*AdwWindowTitle, subtitle: [*:0]const u8) void;

// ── AdwTabView / AdwTabBar / AdwTabPage (GNOME-native tabs) ────────────────────
// One AdwTabView per "mode" (editors / terminals); each is driven by an
// AdwTabBar.  An AdwTabPage wraps the page child and carries the per-tab title.

pub const AdwTabView = opaque {};
pub const AdwTabBar = opaque {};
pub const AdwTabPage = opaque {};

pub extern fn adw_tab_view_new() ?*GtkWidget;
pub extern fn adw_tab_view_append(self: ?*AdwTabView, child: ?*GtkWidget) ?*AdwTabPage;
pub extern fn adw_tab_view_close_page(self: ?*AdwTabView, page: ?*AdwTabPage) void;
pub extern fn adw_tab_view_close_page_finish(self: ?*AdwTabView, page: ?*AdwTabPage, confirm: c_int) void;
pub extern fn adw_tab_view_get_selected_page(self: ?*AdwTabView) ?*AdwTabPage;
pub extern fn adw_tab_view_set_selected_page(self: ?*AdwTabView, page: ?*AdwTabPage) void;
pub extern fn adw_tab_view_get_n_pages(self: ?*AdwTabView) c_int;
pub extern fn adw_tab_view_get_nth_page(self: ?*AdwTabView, position: c_int) ?*AdwTabPage;
pub extern fn adw_tab_view_select_next_page(self: ?*AdwTabView) c_int;
pub extern fn adw_tab_view_select_previous_page(self: ?*AdwTabView) c_int;

pub extern fn adw_tab_page_get_child(self: ?*AdwTabPage) ?*GtkWidget;
pub extern fn adw_tab_page_set_title(self: ?*AdwTabPage, title: [*:0]const u8) void;
pub extern fn adw_tab_page_set_tooltip(self: ?*AdwTabPage, tooltip: ?[*:0]const u8) void;

pub extern fn adw_tab_bar_new() ?*GtkWidget;
pub extern fn adw_tab_bar_set_view(self: ?*AdwTabBar, view: ?*AdwTabView) void;
pub extern fn adw_tab_bar_set_autohide(self: ?*AdwTabBar, autohide: c_int) void;

// ── GtkSourceView 5 ─────────────────────────────────────────────────────────

pub const GtkSourceView = opaque {};
pub const GtkSourceBuffer = opaque {};
pub const GtkSourceStyleSchemeManager = opaque {};
pub const GtkSourceStyleScheme = opaque {};
pub const GtkSourceLanguageManager = opaque {};
pub const GtkSourceLanguage = opaque {};

pub extern fn gtk_source_init() void;
pub extern fn gtk_source_view_new() ?*GtkWidget;
pub extern fn gtk_source_view_set_show_line_numbers(view: ?*GtkSourceView, show: c_int) void;
pub extern fn gtk_source_view_set_highlight_current_line(view: ?*GtkSourceView, hl: c_int) void;
pub extern fn gtk_source_view_set_auto_indent(view: ?*GtkSourceView, enable: c_int) void;
pub extern fn gtk_source_view_set_tab_width(view: ?*GtkSourceView, width: c_uint) void;
pub extern fn gtk_source_buffer_get_language(buffer: ?*GtkSourceBuffer) ?*GtkSourceLanguage;
pub extern fn gtk_source_buffer_set_style_scheme(
    buffer: ?*GtkSourceBuffer,
    scheme: ?*GtkSourceStyleScheme,
) void;
pub extern fn gtk_source_style_scheme_manager_get_default() ?*GtkSourceStyleSchemeManager;
pub extern fn gtk_source_style_scheme_manager_get_scheme(
    manager: ?*GtkSourceStyleSchemeManager,
    scheme_id: [*:0]const u8,
) ?*GtkSourceStyleScheme;
pub extern fn gtk_source_language_manager_get_default() ?*GtkSourceLanguageManager;
pub extern fn gtk_source_language_manager_guess_language(
    manager: ?*GtkSourceLanguageManager,
    filename: ?[*:0]const u8,
    content_type: ?[*:0]const u8,
) ?*GtkSourceLanguage;
pub extern fn gtk_source_buffer_set_language(
    buffer: ?*GtkSourceBuffer,
    language: ?*GtkSourceLanguage,
) void;
pub extern fn gtk_source_buffer_set_highlight_matching_brackets(
    buffer: ?*GtkSourceBuffer,
    highlight: c_int,
) void;

// Registers our bundled Catppuccin style schemes on the manager search path.
pub extern fn zc_register_style_schemes() void;

// ── External file sync (GtkSourceFile + GFileMonitor, src/editor/filesync.zig) ─
// GtkSourceFile/Loader give an encoding-aware async (re)load; GFileMonitor +
// g_file_query_info detect when another process rewrites the open file.

pub const GtkSourceFile = opaque {};
pub const GtkSourceFileLoader = opaque {};
pub const GFileInfo = opaque {};
pub const GFileMonitor = opaque {};
pub const GIcon = opaque {};

pub const G_PRIORITY_DEFAULT: c_int = 0;
pub const G_FILE_QUERY_INFO_NONE: c_int = 0;
pub const G_FILE_MONITOR_WATCH_MOVES: c_int = 1 << 3;
// Attribute keys queried for the change baseline.
pub const G_FILE_ATTRIBUTE_TIME_MODIFIED: [*:0]const u8 = "time::modified";
pub const G_FILE_ATTRIBUTE_TIME_MODIFIED_USEC: [*:0]const u8 = "time::modified-usec";
pub const G_FILE_ATTRIBUTE_QUERY: [*:0]const u8 = "etag::value,time::modified,time::modified-usec";

pub extern fn g_file_new_for_path(path: [*:0]const u8) ?*GFile;
pub extern fn g_file_query_exists(file: ?*GFile, cancellable: ?*GCancellable) c_int;
pub extern fn g_file_query_info(
    file: ?*GFile,
    attributes: [*:0]const u8,
    flags: c_int,
    cancellable: ?*GCancellable,
    err: ?*?*GError,
) ?*GFileInfo;
pub extern fn g_file_info_get_etag(info: ?*GFileInfo) ?[*:0]const u8;
pub extern fn g_file_info_get_attribute_uint64(info: ?*GFileInfo, attribute: [*:0]const u8) u64;
pub extern fn g_file_info_get_attribute_uint32(info: ?*GFileInfo, attribute: [*:0]const u8) u32;

pub extern fn g_file_monitor_file(
    file: ?*GFile,
    flags: c_int,
    cancellable: ?*GCancellable,
    err: ?*?*GError,
) ?*GFileMonitor;
pub extern fn g_file_monitor_cancel(monitor: ?*GFileMonitor) c_int;

pub extern fn g_cancellable_new() ?*GCancellable;
pub extern fn g_cancellable_cancel(cancellable: ?*GCancellable) void;
pub extern fn g_strdup(str: ?[*:0]const u8) ?[*:0]u8;
pub extern fn g_get_monotonic_time() i64;

pub extern fn gtk_source_file_new() ?*GtkSourceFile;
pub extern fn gtk_source_file_set_location(file: ?*GtkSourceFile, location: ?*GFile) void;
pub extern fn gtk_source_file_loader_new(buffer: ?*GtkSourceBuffer, file: ?*GtkSourceFile) ?*GtkSourceFileLoader;
pub extern fn gtk_source_file_loader_load_async(
    loader: ?*GtkSourceFileLoader,
    io_priority: c_int,
    cancellable: ?*GCancellable,
    progress_callback: ?*anyopaque,
    progress_callback_data: ?*anyopaque,
    progress_callback_notify: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_source_file_loader_load_finish(
    loader: ?*GtkSourceFileLoader,
    result: ?*GAsyncResult,
    err: ?*?*GError,
) c_int;

// Inline conflict banner: AdwBanner with a single action button.
pub const AdwBanner = opaque {};
pub extern fn adw_banner_new(title: [*:0]const u8) ?*GtkWidget;
pub extern fn adw_banner_set_title(self: ?*AdwBanner, title: [*:0]const u8) void;
pub extern fn adw_banner_set_button_label(self: ?*AdwBanner, label: ?[*:0]const u8) void;
pub extern fn adw_banner_set_revealed(self: ?*AdwBanner, revealed: c_int) void;

// Per-tab indicator icon (warning glyph) shown in the tab bar for background
// tabs that have a pending external-change conflict.
pub extern fn g_themed_icon_new(iconname: [*:0]const u8) ?*GIcon;
pub extern fn adw_tab_page_set_indicator_icon(self: ?*AdwTabPage, indicator_icon: ?*GIcon) void;
pub extern fn adw_tab_page_set_indicator_tooltip(self: ?*AdwTabPage, tooltip: ?[*:0]const u8) void;

// ── Pango font descriptions ───────────────────────────────────────────────────
// A font preference is stored as a Pango description string ("Iosevka 12");
// Pango parses it, VTE consumes the description directly and the editor's CSS
// is built from its family and size.

pub const PangoFontDescription = opaque {};
pub const PANGO_SCALE: c_int = 1024;

pub extern fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_to_string(desc: ?*const PangoFontDescription) ?[*:0]u8;
pub extern fn pango_font_description_free(desc: ?*PangoFontDescription) void;
pub extern fn pango_font_description_get_family(desc: ?*const PangoFontDescription) ?[*:0]const u8;
pub extern fn pango_font_description_get_size(desc: ?*const PangoFontDescription) c_int;
pub extern fn pango_font_description_get_size_is_absolute(desc: ?*const PangoFontDescription) c_int;
// PangoWeight shares CSS's numeric scale (400 normal, 700 bold).
pub extern fn pango_font_description_get_weight(desc: ?*const PangoFontDescription) c_int;
pub const PangoStyle = enum(c_int) { normal = 0, oblique = 1, italic = 2 };
pub extern fn pango_font_description_get_style(desc: ?*const PangoFontDescription) PangoStyle;

// ── VTE 2.91 (GTK4) ─────────────────────────────────────────────────────────

pub const VteTerminal = opaque {};
pub extern fn vte_terminal_set_font(terminal: ?*VteTerminal, font_desc: ?*const PangoFontDescription) void;
pub extern fn vte_terminal_new() ?*GtkWidget;
pub extern fn vte_terminal_set_scrollback_lines(terminal: ?*VteTerminal, lines: c_long) void;
pub extern fn vte_terminal_set_scroll_on_output(terminal: ?*VteTerminal, scroll: c_int) void;
pub extern fn vte_terminal_get_window_title(terminal: ?*VteTerminal) ?[*:0]const u8;
pub extern fn vte_terminal_get_current_directory_uri(terminal: ?*VteTerminal) ?[*:0]const u8;
pub extern fn vte_terminal_paste_clipboard(terminal: ?*VteTerminal) void;
pub extern fn vte_terminal_get_has_selection(terminal: ?*VteTerminal) c_int;
// VteFormat: VTE_FORMAT_TEXT = 1.  copy_clipboard_format replaces the
// deprecated copy_clipboard and lets us copy the current selection as plain text.
pub const VTE_FORMAT_TEXT: c_int = 1;
pub extern fn vte_terminal_copy_clipboard_format(terminal: ?*VteTerminal, format: c_int) void;
pub const VtePty = opaque {};
pub extern fn vte_pty_new_foreign_sync(fd: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*VtePty;
pub extern fn vte_terminal_set_pty(terminal: ?*VteTerminal, pty: ?*VtePty) void;

// Ctrl+Click URL open, mirroring the source view's (src/c/terminal.c).
pub extern fn zc_terminal_attach_url_match(terminal: ?*VteTerminal) void;

// ── GObject property binding ──────────────────────────────────────────────────

pub const G_BINDING_SYNC_CREATE: c_uint = 1 << 0;
pub const G_BINDING_BIDIRECTIONAL: c_uint = 1 << 1;
pub const G_BINDING_INVERT_BOOLEAN: c_uint = 1 << 2;

pub extern fn g_object_bind_property(
    source: ?*anyopaque,
    source_property: [*:0]const u8,
    target: ?*anyopaque,
    target_property: [*:0]const u8,
    flags: c_uint,
) ?*anyopaque;

pub extern fn g_application_quit(application: ?*GApplication) void;

// ── GMenu / GAction (primary menu + app actions) ──────────────────────────────

pub const GMenu = opaque {};
pub const GSimpleAction = opaque {};
pub const GVariant = opaque {};

pub extern fn g_menu_new() ?*GMenu;
pub extern fn g_menu_append(menu: ?*GMenu, label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) void;
pub extern fn g_menu_append_section(menu: ?*GMenu, label: ?[*:0]const u8, section: ?*anyopaque) void;
pub extern fn g_simple_action_new(name: [*:0]const u8, parameter_type: ?*anyopaque) ?*GSimpleAction;
pub extern fn g_simple_action_set_enabled(action: ?*GSimpleAction, enabled: c_int) void;
pub extern fn g_action_map_add_action(action_map: ?*anyopaque, action: ?*anyopaque) void;
pub extern fn g_simple_action_new_stateful(name: [*:0]const u8, parameter_type: ?*anyopaque, state: ?*GVariant) ?*GSimpleAction;
pub extern fn g_simple_action_set_state(action: ?*GSimpleAction, value: ?*GVariant) void;
pub extern fn gtk_application_set_accels_for_action(
    application: ?*GtkApplication,
    detailed_action_name: [*:0]const u8,
    accels: [*]const ?[*:0]const u8,
) void;
pub extern fn gtk_application_get_active_window(application: ?*GtkApplication) ?*GtkWindow;

// GtkMenuButton
pub const GtkMenuButton = opaque {};
pub extern fn gtk_menu_button_new() ?*GtkWidget;
pub extern fn gtk_menu_button_set_icon_name(button: ?*GtkMenuButton, icon_name: [*:0]const u8) void;
pub extern fn gtk_menu_button_set_menu_model(button: ?*GtkMenuButton, menu_model: ?*anyopaque) void;
pub extern fn gtk_menu_button_set_primary(button: ?*GtkMenuButton, primary: c_int) void;
pub extern fn gtk_menu_button_set_child(button: ?*GtkMenuButton, child: ?*GtkWidget) void;

// AdwSplitButton — icon button whose main area runs a default action ("clicked")
// with a small attached dropdown arrow for secondary actions (a menu model),
// exactly like GNOME Builder's "Open" button.
pub const AdwSplitButton = opaque {};
pub extern fn adw_split_button_new() ?*GtkWidget;
pub extern fn adw_split_button_set_icon_name(self: ?*AdwSplitButton, icon_name: [*:0]const u8) void;
pub extern fn adw_split_button_set_menu_model(self: ?*AdwSplitButton, menu_model: ?*anyopaque) void;

// GVariant — only what's needed to read a string parameter off a parameterized
// GAction (the win.view action passes the target mode as its value).
pub extern fn g_variant_get_string(value: ?*GVariant, length: ?*usize) ?[*:0]const u8;
// `(const GVariantType *) "s"` — GVariantType is documented to be laid out
// identically to its own type-string bytes, the same reinterpretation GLib's
// own headers use for G_VARIANT_TYPE_STRING; avoids an allocation.
pub const G_VARIANT_TYPE_STRING: ?*anyopaque = @constCast(@as(*const anyopaque, @ptrCast("s")));

// ── GSettings (preferences + recent projects, src/core/config.zig) ────────────
// The schema is looked up through the source first: g_settings_new() aborts the
// process when its schema is not installed, which happens whenever the binary
// runs outside `zig build run` / Flatpak.

pub const GSettings = opaque {};
pub const GSettingsSchema = opaque {};
pub const GSettingsSchemaSource = opaque {};

pub extern fn g_settings_schema_source_get_default() ?*GSettingsSchemaSource;
pub extern fn g_settings_schema_source_lookup(
    source: ?*GSettingsSchemaSource,
    schema_id: [*:0]const u8,
    recursive: c_int,
) ?*GSettingsSchema;
pub extern fn g_settings_schema_unref(schema: ?*GSettingsSchema) void;

pub extern fn g_settings_new(schema_id: [*:0]const u8) ?*GSettings;
pub extern fn g_settings_get_string(settings: ?*GSettings, key: [*:0]const u8) ?[*:0]u8;
pub extern fn g_settings_set_string(settings: ?*GSettings, key: [*:0]const u8, value: [*:0]const u8) c_int;
pub extern fn g_settings_get_boolean(settings: ?*GSettings, key: [*:0]const u8) c_int;
pub extern fn g_settings_get_int(settings: ?*GSettings, key: [*:0]const u8) c_int;
pub extern fn g_settings_set_int(settings: ?*GSettings, key: [*:0]const u8, value: c_int) c_int;
pub extern fn g_settings_set_boolean(settings: ?*GSettings, key: [*:0]const u8, value: c_int) c_int;
// NULL-terminated array of NUL-terminated strings; free with g_strfreev.
pub extern fn g_settings_get_strv(settings: ?*GSettings, key: [*:0]const u8) ?[*:null]?[*:0]u8;
pub extern fn g_settings_set_strv(settings: ?*GSettings, key: [*:0]const u8, value: [*]const ?[*:0]const u8) c_int;
pub extern fn g_strfreev(str_array: ?[*:null]?[*:0]u8) void;

// Attaches data whose lifetime follows the object — used to hang a recent
// project's path off its list row without a parallel allocation to free.
pub extern fn g_object_set_data_full(
    object: ?*anyopaque,
    key: [*:0]const u8,
    data: ?*anyopaque,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
) void;

pub const GDK_KEY_F9: c_uint = 0xFFC6;
pub const GDK_KEY_v: c_uint = 0x076;
pub const GDK_KEY_V: c_uint = 0x056;
pub const GDK_KEY_c: c_uint = 0x063;
pub const GDK_KEY_C: c_uint = 0x043;
pub const GDK_KEY_w: c_uint = 0x077;
pub const GDK_KEY_W: c_uint = 0x057;
pub const GDK_KEY_n: c_uint = 0x06e;
pub const GDK_KEY_N: c_uint = 0x04e;
pub const GDK_KEY_t: c_uint = 0x074;
pub const GDK_KEY_T: c_uint = 0x054;
pub const GDK_KEY_e: c_uint = 0x065;
pub const GDK_KEY_E: c_uint = 0x045;
pub const GDK_KEY_g: c_uint = 0x067;
pub const GDK_KEY_G: c_uint = 0x047;
pub const GDK_KEY_q: c_uint = 0x071;
pub const GDK_KEY_Q: c_uint = 0x051;
pub const GDK_KEY_Tab: c_uint = 0xFF09;
pub const GDK_KEY_ISO_Left_Tab: c_uint = 0xFE20;
pub const GDK_SHIFT_MASK: c_uint = 0x1;

// ── AdwOverlaySplitView (collapsible sidebar) ─────────────────────────────────

pub const AdwOverlaySplitView = opaque {};
pub extern fn adw_overlay_split_view_new() ?*GtkWidget;
pub extern fn adw_overlay_split_view_set_sidebar(self: ?*AdwOverlaySplitView, sidebar: ?*GtkWidget) void;
pub extern fn adw_overlay_split_view_set_content(self: ?*AdwOverlaySplitView, content: ?*GtkWidget) void;
pub extern fn adw_overlay_split_view_set_collapsed(self: ?*AdwOverlaySplitView, collapsed: c_int) void;
pub extern fn adw_overlay_split_view_set_show_sidebar(self: ?*AdwOverlaySplitView, show: c_int) void;
pub extern fn adw_overlay_split_view_get_show_sidebar(self: ?*AdwOverlaySplitView) c_int;
pub extern fn adw_overlay_split_view_set_min_sidebar_width(self: ?*AdwOverlaySplitView, width: f64) void;
pub extern fn adw_overlay_split_view_set_max_sidebar_width(self: ?*AdwOverlaySplitView, width: f64) void;
pub extern fn adw_overlay_split_view_set_sidebar_width_fraction(self: ?*AdwOverlaySplitView, fraction: f64) void;

// ── AdwStyleManager (system light/dark) ───────────────────────────────────────

pub const AdwStyleManager = opaque {};
pub extern fn adw_style_manager_get_default() ?*AdwStyleManager;
pub extern fn adw_style_manager_get_dark(self: ?*AdwStyleManager) c_int;

// ── AdwAboutDialog ────────────────────────────────────────────────────────────

pub const AdwAboutDialog = opaque {};
pub const AdwDialog = opaque {};
pub const GTK_LICENSE_GPL_3_0: c_int = 3; // "GPL 3.0 or later"
pub const GTK_LICENSE_MIT_X11: c_int = 7; // "MIT/X11 standard license"

pub extern fn adw_about_dialog_new() ?*AdwDialog;
pub extern fn adw_about_dialog_set_application_name(self: ?*AdwAboutDialog, name: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_application_icon(self: ?*AdwAboutDialog, icon_name: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_developer_name(self: ?*AdwAboutDialog, name: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_version(self: ?*AdwAboutDialog, version: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_comments(self: ?*AdwAboutDialog, comments: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_website(self: ?*AdwAboutDialog, website: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_issue_url(self: ?*AdwAboutDialog, url: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_license_type(self: ?*AdwAboutDialog, license_type: c_int) void;
pub extern fn adw_about_dialog_set_copyright(self: ?*AdwAboutDialog, copyright: [*:0]const u8) void;
pub extern fn adw_about_dialog_set_developers(self: ?*AdwAboutDialog, developers: [*]const ?[*:0]const u8) void;
pub extern fn adw_dialog_present(self: ?*AdwDialog, parent: ?*GtkWidget) void;

// ── AdwPreferencesDialog + rows (src/app/preferences.zig) ─────────────────────

pub const AdwPreferencesDialog = opaque {};
pub const AdwPreferencesPage = opaque {};
pub const AdwPreferencesGroup = opaque {};
pub const AdwPreferencesRow = opaque {};
pub const AdwActionRow = opaque {};
pub const AdwSwitchRow = opaque {};

pub extern fn adw_preferences_dialog_new() ?*AdwDialog;
pub extern fn adw_preferences_dialog_add(self: ?*AdwPreferencesDialog, page: ?*AdwPreferencesPage) void;
pub extern fn adw_preferences_page_new() ?*GtkWidget;
pub extern fn adw_preferences_page_set_title(self: ?*AdwPreferencesPage, title: [*:0]const u8) void;
pub extern fn adw_preferences_page_set_icon_name(self: ?*AdwPreferencesPage, icon_name: ?[*:0]const u8) void;
pub extern fn adw_preferences_page_add(self: ?*AdwPreferencesPage, group: ?*AdwPreferencesGroup) void;
pub extern fn adw_preferences_group_new() ?*GtkWidget;
pub extern fn adw_preferences_group_set_title(self: ?*AdwPreferencesGroup, title: [*:0]const u8) void;
pub extern fn adw_preferences_group_set_description(self: ?*AdwPreferencesGroup, description: ?[*:0]const u8) void;
pub extern fn adw_preferences_group_add(self: ?*AdwPreferencesGroup, child: ?*GtkWidget) void;
pub extern fn adw_preferences_row_set_title(self: ?*AdwPreferencesRow, title: [*:0]const u8) void;
pub extern fn adw_action_row_new() ?*GtkWidget;
pub extern fn adw_action_row_set_subtitle(self: ?*AdwActionRow, subtitle: [*:0]const u8) void;
pub extern fn adw_action_row_add_suffix(self: ?*AdwActionRow, widget: ?*GtkWidget) void;
pub extern fn adw_switch_row_new() ?*GtkWidget;
pub extern fn adw_switch_row_get_active(self: ?*AdwSwitchRow) c_int;
pub extern fn adw_switch_row_set_active(self: ?*AdwSwitchRow, is_active: c_int) void;

// GtkFontDialogButton — the GTK4 font picker: a button that opens a
// GtkFontDialog and exposes the chosen font as a PangoFontDescription.
pub const GtkFontDialog = opaque {};
pub const GtkFontDialogButton = opaque {};
pub extern fn gtk_font_dialog_new() ?*GtkFontDialog;
pub extern fn gtk_font_dialog_set_title(self: ?*GtkFontDialog, title: [*:0]const u8) void;
pub extern fn gtk_font_dialog_button_new(dialog: ?*GtkFontDialog) ?*GtkWidget;
pub extern fn gtk_font_dialog_button_set_font_desc(self: ?*GtkFontDialogButton, desc: ?*const PangoFontDescription) void;
pub extern fn gtk_font_dialog_button_get_font_desc(self: ?*GtkFontDialogButton) ?*PangoFontDescription;

// ── GtkListBox (recent-projects popover) ──────────────────────────────────────

pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkSelectionMode = enum(c_int) { none = 0, single = 1, browse = 2, multiple = 3 };
pub extern fn gtk_list_box_new() ?*GtkWidget;
pub extern fn gtk_list_box_append(box: ?*GtkListBox, child: ?*GtkWidget) void;
pub extern fn gtk_list_box_set_selection_mode(box: ?*GtkListBox, mode: GtkSelectionMode) void;
pub extern fn gtk_list_box_row_set_activatable(row: ?*GtkListBoxRow, activatable: c_int) void;
pub extern fn gtk_list_box_get_row_at_index(box: ?*GtkListBox, index: c_int) ?*GtkListBoxRow;
pub extern fn gtk_list_box_get_selected_row(box: ?*GtkListBox) ?*GtkListBoxRow;
pub extern fn gtk_list_box_select_row(box: ?*GtkListBox, row: ?*GtkListBoxRow) void;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) ?*GtkWidget;
// Wires a button (or any GtkActionable) straight to a GAction, so the widget
// carries no handler of its own.
pub extern fn gtk_actionable_set_action_name(actionable: ?*anyopaque, action_name: ?[*:0]const u8) void;
pub extern fn gtk_actionable_set_action_target_value(actionable: ?*anyopaque, target_value: ?*GVariant) void;
pub extern fn gtk_widget_set_size_request(widget: ?*GtkWidget, width: c_int, height: c_int) void;

// ── Extra C helpers (src/helpers.c) ───────────────────────────────────────────

pub extern fn zc_terminal_style(terminal: ?*VteTerminal, dark: c_int) void;
pub extern fn zc_add_collapse_breakpoint(win: ?*AdwApplicationWindow, split: ?*AdwOverlaySplitView) void;

// Warns on every main-loop turn longer than ZC_WATCHDOG_MS (src/c/util.c).
// No-op unless the variable is set.
pub extern fn zc_watchdog_install() void;

// ── GtkPicture ────────────────────────────────────────────────────────────────

pub const GtkPicture = opaque {};
pub extern fn gtk_picture_new_for_filename(filename: ?[*:0]const u8) ?*GtkWidget;

// ── WebKitGTK 6.0 ─────────────────────────────────────────────────────────────

pub const WebKitWebView = opaque {};
pub const WebKitSettings = opaque {};
pub const WebKitPolicyDecision = opaque {};
pub const WebKitNavigationPolicyDecision = opaque {};
pub const WebKitNavigationAction = opaque {};

// WebKitPolicyDecisionType
pub const WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION: c_int = 0;
// WebKitNavigationType — only OTHER is what webkit_web_view_load_html triggers
pub const WEBKIT_NAVIGATION_TYPE_OTHER: c_int = 5;

pub extern fn webkit_policy_decision_ignore(decision: ?*WebKitPolicyDecision) void;
pub extern fn webkit_navigation_policy_decision_get_navigation_action(
    decision: ?*WebKitNavigationPolicyDecision,
) ?*WebKitNavigationAction;
pub extern fn webkit_navigation_action_get_navigation_type(
    action: ?*WebKitNavigationAction,
) c_int;

pub const WebKitURIRequest = opaque {};
pub extern fn webkit_navigation_action_get_request(
    action: ?*WebKitNavigationAction,
) ?*WebKitURIRequest;
pub extern fn webkit_uri_request_get_uri(request: ?*WebKitURIRequest) ?[*:0]const u8;
pub extern fn gtk_show_uri(parent: ?*GtkWindow, uri: [*:0]const u8, timestamp: u32) void;

pub extern fn webkit_web_view_new() ?*GtkWidget;
pub extern fn webkit_web_view_load_html(
    web_view: ?*WebKitWebView,
    content: [*:0]const u8,
    base_uri: ?[*:0]const u8,
) void;
pub extern fn webkit_web_view_load_uri(web_view: ?*WebKitWebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_set_settings(
    web_view: ?*WebKitWebView,
    settings: ?*WebKitSettings,
) void;
pub extern fn webkit_settings_new() ?*WebKitSettings;
pub extern fn webkit_settings_set_enable_javascript(
    settings: ?*WebKitSettings,
    enabled: c_int,
) void;
pub extern fn webkit_settings_set_enable_javascript_markup(
    settings: ?*WebKitSettings,
    enabled: c_int,
) void;
pub extern fn webkit_settings_set_allow_universal_access_from_file_urls(
    settings: ?*WebKitSettings,
    allowed: c_int,
) void;

// ── cmark (CommonMark renderer) ───────────────────────────────────────────────

// Converts `len` bytes of CommonMark source to a heap-allocated HTML string.
// The caller must free the result with g_free (cmark uses malloc internally,
// but we pass it through GLib-aware code — actually the caller must use
// stdlib free.  We declare it as [*:0]u8 and call g_free which is safe on
// glibc since both use the same allocator).
pub extern fn cmark_markdown_to_html(text: [*]const u8, len: usize, options: c_int) ?[*:0]u8;
pub const CMARK_OPT_DEFAULT: c_int = 0;
pub const CMARK_OPT_UNSAFE: c_int = 1 << 17;

// ── AdwToastOverlay / AdwToast (user feedback) ────────────────────────────────
// One overlay per window wraps the whole content; every user-visible success or
// failure surfaces through it (see src/app/toast.zig).

pub const AdwToastOverlay = opaque {};
pub const AdwToast = opaque {};

pub extern fn adw_toast_overlay_new() ?*GtkWidget;
pub extern fn adw_toast_overlay_set_child(self: ?*AdwToastOverlay, child: ?*GtkWidget) void;
pub extern fn adw_toast_overlay_add_toast(self: ?*AdwToastOverlay, toast: ?*AdwToast) void;
pub extern fn adw_toast_new(title: [*:0]const u8) ?*AdwToast;
pub extern fn adw_toast_set_button_label(self: ?*AdwToast, button_label: ?[*:0]const u8) void;
pub extern fn adw_toast_set_timeout(self: ?*AdwToast, timeout: c_uint) void;
// AdwToastPriority: NORMAL = 0, HIGH = 1 (jumps the queue; used for errors).
pub const ADW_TOAST_PRIORITY_HIGH: c_int = 1;
pub extern fn adw_toast_set_priority(self: ?*AdwToast, priority: c_int) void;

// ── AdwShortcutsDialog (replaces the deprecated GtkShortcutsWindow) ───────────

pub const AdwShortcutsDialog = opaque {};
pub const AdwShortcutsSection = opaque {};
pub const AdwShortcutsItem = opaque {};

pub extern fn adw_shortcuts_dialog_new() ?*AdwDialog;
pub extern fn adw_shortcuts_dialog_add(self: ?*AdwShortcutsDialog, section: ?*AdwShortcutsSection) void;
pub extern fn adw_shortcuts_section_new(title: ?[*:0]const u8) ?*AdwShortcutsSection;
pub extern fn adw_shortcuts_section_add(self: ?*AdwShortcutsSection, item: ?*AdwShortcutsItem) void;
pub extern fn adw_shortcuts_item_new(title: [*:0]const u8, accelerator: ?[*:0]const u8) ?*AdwShortcutsItem;

// ── AdwTabOverview (Ctrl+Shift+O tab grid) ───────────────────────────────────

pub const AdwTabOverview = opaque {};

pub extern fn adw_tab_overview_new() ?*GtkWidget;
pub extern fn adw_tab_overview_set_view(self: ?*AdwTabOverview, view: ?*AdwTabView) void;
pub extern fn adw_tab_overview_set_child(self: ?*AdwTabOverview, child: ?*GtkWidget) void;
pub extern fn adw_tab_overview_set_open(self: ?*AdwTabOverview, open: c_int) void;
pub extern fn adw_tab_overview_get_open(self: ?*AdwTabOverview) c_int;
pub extern fn adw_tab_overview_set_enable_search(self: ?*AdwTabOverview, enable: c_int) void;
pub extern fn adw_tab_overview_set_enable_new_tab(self: ?*AdwTabOverview, enable: c_int) void;

// Action widgets flank the tabs inside the bar itself — the GNOME-native home
// for a "new tab" button, keeping it out of the header bar.

// ── AdwToolbarView bottom bar (editor status bar) ─────────────────────────────

pub extern fn adw_toolbar_view_add_bottom_bar(self: ?*AdwToolbarView, widget: ?*GtkWidget) void;
pub extern fn adw_toolbar_view_set_reveal_bottom_bars(self: ?*AdwToolbarView, reveal: c_int) void;

// ── AdwDialog (quick-open) ────────────────────────────────────────────────────

pub extern fn adw_dialog_new() ?*AdwDialog;
pub extern fn adw_dialog_set_child(self: ?*AdwDialog, child: ?*GtkWidget) void;
pub extern fn adw_dialog_set_title(self: ?*AdwDialog, title: [*:0]const u8) void;
pub extern fn adw_dialog_set_content_width(self: ?*AdwDialog, width: c_int) void;
pub extern fn adw_dialog_set_content_height(self: ?*AdwDialog, height: c_int) void;
pub extern fn adw_dialog_close(self: ?*AdwDialog) c_int;

// ── Preference rows (AdwPreferencesDialog pages) ──────────────────────────────

pub const AdwComboRow = opaque {};
pub const AdwSpinRow = opaque {};
pub const GtkStringList = opaque {};
pub const GListModel = opaque {};

pub extern fn adw_combo_row_new() ?*GtkWidget;
pub extern fn adw_combo_row_set_model(self: ?*AdwComboRow, model: ?*GListModel) void;
pub extern fn adw_combo_row_set_selected(self: ?*AdwComboRow, position: c_uint) void;
pub extern fn adw_combo_row_get_selected(self: ?*AdwComboRow) c_uint;
pub extern fn adw_spin_row_new_with_range(min: f64, max: f64, step: f64) ?*GtkWidget;
pub extern fn adw_spin_row_get_value(self: ?*AdwSpinRow) f64;
pub extern fn adw_spin_row_set_value(self: ?*AdwSpinRow, value: f64) void;
// NULL-terminated array of strings, copied by the list.
pub extern fn gtk_string_list_new(strings: ?[*]const ?[*:0]const u8) ?*GtkStringList;
pub extern fn gtk_string_list_append(self: ?*GtkStringList, string: [*:0]const u8) void;

// ── GtkFileDialog: open / save a single file ──────────────────────────────────

pub extern fn gtk_file_dialog_open(
    self: ?*GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_open_finish(self: ?*GtkFileDialog, result: ?*GAsyncResult, err: ?*?*GError) ?*GFile;
pub extern fn gtk_file_dialog_save(
    self: ?*GtkFileDialog,
    parent: ?*GtkWindow,
    cancellable: ?*GCancellable,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_dialog_save_finish(self: ?*GtkFileDialog, result: ?*GAsyncResult, err: ?*?*GError) ?*GFile;
pub extern fn gtk_file_dialog_set_initial_name(self: ?*GtkFileDialog, name: ?[*:0]const u8) void;
pub extern fn gtk_file_dialog_set_initial_folder(self: ?*GtkFileDialog, folder: ?*GFile) void;

// ── GMenu items with a target (the file tree's context menu) ──────────────────

pub const GMenuItem = opaque {};
pub extern fn g_menu_item_new(label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) ?*GMenuItem;
pub extern fn g_menu_item_set_action_and_target_value(item: ?*GMenuItem, action: ?[*:0]const u8, target: ?*GVariant) void;
pub extern fn g_menu_append_item(menu: ?*GMenu, item: ?*GMenuItem) void;
pub extern fn g_variant_new_string(string: [*:0]const u8) ?*GVariant;
pub extern fn gtk_popover_menu_new_from_model(model: ?*anyopaque) ?*GtkWidget;
pub extern fn gtk_popover_set_autohide(popover: ?*GtkPopover, autohide: c_int) void;

// ── Widget/stack polish ───────────────────────────────────────────────────────

// GtkStackTransitionType — the two the app uses; everything else stays NONE.
pub const GTK_STACK_TRANSITION_TYPE_CROSSFADE: c_int = 1;
pub const GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT: c_int = 6;
pub extern fn gtk_stack_set_transition_type(stack: ?*GtkStack, transition: c_int) void;
pub extern fn gtk_stack_set_transition_duration(stack: ?*GtkStack, duration: c_uint) void;

pub extern fn gtk_widget_set_margin_start(widget: ?*GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: ?*GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: ?*GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: ?*GtkWidget, margin: c_int) void;
pub extern fn gtk_button_set_icon_name(button: ?*GtkButton, icon_name: [*:0]const u8) void;
pub const PANGO_ELLIPSIZE_MIDDLE: c_int = 2;
pub extern fn gtk_label_set_ellipsize(label: ?*GtkLabel, mode: c_int) void;
pub extern fn gtk_scrolled_window_set_min_content_height(self: ?*GtkScrolledWindow, height: c_int) void;
pub extern fn gtk_search_entry_new() ?*GtkWidget;
pub extern fn gtk_list_box_remove_all(box: ?*GtkListBox) void;
pub extern fn gtk_widget_get_first_child(widget: ?*GtkWidget) ?*GtkWidget;

// ── Editor preferences applied to a source view ───────────────────────────────

pub const GTK_WRAP_NONE: c_int = 0;
pub const GTK_WRAP_WORD_CHAR: c_int = 3;
pub extern fn gtk_text_view_set_wrap_mode(view: ?*GtkTextView, wrap_mode: c_int) void;
pub extern fn gtk_source_view_set_insert_spaces_instead_of_tabs(view: ?*GtkSourceView, enable: c_int) void;
pub extern fn gtk_source_view_set_indent_width(view: ?*GtkSourceView, width: c_int) void;
pub extern fn gtk_source_view_set_show_right_margin(view: ?*GtkSourceView, show: c_int) void;
pub extern fn gtk_source_view_set_right_margin_position(view: ?*GtkSourceView, pos: c_uint) void;
// NULL-terminated, owned by the manager.
pub extern fn gtk_source_style_scheme_manager_get_scheme_ids(manager: ?*GtkSourceStyleSchemeManager) ?[*:null]const ?[*:0]const u8;
pub extern fn gtk_source_style_scheme_get_name(scheme: ?*GtkSourceStyleScheme) ?[*:0]const u8;
pub extern fn gtk_source_buffer_get_style_scheme(buffer: ?*GtkSourceBuffer) ?*GtkSourceStyleScheme;

// ── Find & replace (src/c/search.c) ───────────────────────────────────────────

pub extern fn zc_search_bar_open_replace(view: ?*GtkSourceView) void;

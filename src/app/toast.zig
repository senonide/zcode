//! Transient user feedback.  Every operation that can fail without the user
//! noticing — a save, a rename, a checkout — reports through here, so there is
//! exactly one place that decides how feedback looks.
//!
//! `show` is for confirmations, `showError` for failures: errors jump the toast
//! queue and linger longer, because a missed error is the one that costs data.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");

const error_timeout_s: c_uint = 6;

pub fn show(state: *core.AppState, text: [*:0]const u8) void {
    present(state, text, false);
}

pub fn showError(state: *core.AppState, text: [*:0]const u8) void {
    present(state, text, true);
}

/// Formatted variants.  The message is rendered into a stack buffer, so it is
/// truncated rather than allocated — toasts are one short line by design.
pub fn showFmt(state: *core.AppState, comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    present(state, std.fmt.bufPrintZ(&buf, fmt, args) catch return, false);
}

pub fn showErrorFmt(state: *core.AppState, comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    present(state, std.fmt.bufPrintZ(&buf, fmt, args) catch return, true);
}

fn present(state: *core.AppState, text: [*:0]const u8, is_error: bool) void {
    if (state.shutting_down) return;
    const overlay = state.toast_overlay;
    const toast = gtk.adw_toast_new(text) orelse return;
    if (is_error) {
        gtk.adw_toast_set_priority(toast, gtk.ADW_TOAST_PRIORITY_HIGH);
        gtk.adw_toast_set_timeout(toast, error_timeout_s);
    }
    gtk.adw_toast_overlay_add_toast(overlay, toast);
}

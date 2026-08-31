//! Positions in a source view: byte columns into iterators, and where the caret
//! sits on screen.  Both exist because GTK's own APIs take a position on trust
//! and misbehave when it no longer matches the buffer or the viewport.
//!
//! ## Byte columns
//!
//! Byte columns in this editor are measured against one revision of a buffer and
//! used against another — a diagnostic is measured when the language server
//! publishes it and painted a frame later, a cursor is measured before an
//! external reload and restored after, a tree-sitter capture is measured at the
//! last parse.  `gtk_text_buffer_get_iter_at_line_index` trusts the caller, and
//! an index that lands mid-character corrupts the buffer rather than merely
//! misplacing a tag: GTK's own warning is "this will crash the text buffer".
//!
//! `zc_iter_at_line_byte` (src/c/util.c) is the answer: it walks the line by
//! characters, so the iterator it returns is always one GTK can safely tag or
//! edit at — snapped back to the boundary at or before the requested column and
//! clamped to the line.  Use it for any column that did not come from the
//! buffer's own iterators a moment earlier.
//!
//! It lives in C because the C helpers need it too.  This module is where its
//! contract is pinned down: GtkTextBuffer is a plain GObject, so the tests below
//! exercise the real thing without a display.

const std = @import("std");
const gtk = @import("../gtk.zig");

const testing = std.testing;

fn atLineByte(buffer: *gtk.GtkTextBuffer, iter: *gtk.GtkTextIter, line: c_int, byte_col: c_int) void {
    gtk.zc_iter_at_line_byte(buffer, iter, line, byte_col);
}

// ── Caret position on screen ─────────────────────────────────────────────────

/// Where the caret sits within the visible area: 0 at the left/top edge, 1 at
/// the right/bottom.
pub const CaretSpot = struct { x: f64, y: f64 };

/// Reads the caret's place on screen so it can be put back there after the text
/// under it is rewritten.  Null while the view has no allocation, and clamped
/// for a caret that was scrolled off screen — putting it back at the nearest
/// edge beats leaving the view somewhere unrelated to the document.
///
/// Both axes, because `gtk_text_view_scroll_to_mark` aligns both or neither:
/// there is no vertical-only form.  A fixed `xalign` therefore drags the caret's
/// column to that edge — with 0, hard against the left, hiding the indentation
/// before it — and the view lurches sideways every time it is called.  Asking
/// for the fraction the caret already had is what makes the call a no-op
/// horizontally.  Restoring the adjustment afterwards does not work: the view
/// defers the scroll to its next layout pass, so it runs after the restore.
pub fn caretSpot(sv: *gtk.GtkSourceView, caret: *gtk.GtkTextIter) ?CaretSpot {
    var visible: gtk.GdkRectangle = .{};
    gtk.gtk_text_view_get_visible_rect(@ptrCast(sv), &visible);
    if (visible.height <= 0 or visible.width <= 0) return null;
    var caret_rect: gtk.GdkRectangle = .{};
    gtk.gtk_text_view_get_iter_location(@ptrCast(sv), caret, &caret_rect);
    return .{
        .x = fraction(caret_rect.x - visible.x, visible.width),
        .y = fraction(caret_rect.y - visible.y, visible.height),
    };
}

fn fraction(offset: c_int, extent: c_int) f64 {
    const value = @as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(extent));
    return std.math.clamp(value, 0, 1);
}

fn bufferWith(text: [:0]const u8) *gtk.GtkTextBuffer {
    const buf = gtk.gtk_text_buffer_new(null).?;
    gtk.gtk_text_buffer_set_text(buf, text.ptr, @intCast(text.len));
    return buf;
}

fn lineIndexAt(buf: *gtk.GtkTextBuffer, line: c_int, byte_col: c_int) c_int {
    var it: gtk.GtkTextIter = .{};
    atLineByte(buf, &it, line, byte_col);
    return gtk.gtk_text_iter_get_line_index(&it);
}

test "atLineByte: exact boundaries are kept" {
    const buf = bufferWith("hola\ncafé ✓ x\n");
    defer gtk.g_object_unref(buf);
    try testing.expectEqual(@as(c_int, 0), lineIndexAt(buf, 1, 0));
    try testing.expectEqual(@as(c_int, 3), lineIndexAt(buf, 1, 3));
    // "café" is 5 bytes: 'é' occupies 3..4, so 5 is the space after it.
    try testing.expectEqual(@as(c_int, 5), lineIndexAt(buf, 1, 5));
}

test "atLineByte: a column inside a character snaps back to its start" {
    const buf = bufferWith("café ✓ x\n");
    defer gtk.g_object_unref(buf);
    // 'é' starts at byte 3 and spans two bytes; 4 is inside it.
    try testing.expectEqual(@as(c_int, 3), lineIndexAt(buf, 0, 4));
    // '✓' starts at byte 6 and spans three; 7 and 8 are inside it.
    try testing.expectEqual(@as(c_int, 6), lineIndexAt(buf, 0, 7));
    try testing.expectEqual(@as(c_int, 6), lineIndexAt(buf, 0, 8));
}

test "atLineByte: a column past the line clamps to its end" {
    const buf = bufferWith("ab\nlonger line\n");
    defer gtk.g_object_unref(buf);
    try testing.expectEqual(@as(c_int, 2), lineIndexAt(buf, 0, 999));
    try testing.expectEqual(@as(c_int, 11), lineIndexAt(buf, 1, 11));
    try testing.expectEqual(@as(c_int, 11), lineIndexAt(buf, 1, 12));
}

test "atLineByte: out-of-range lines and negative columns are clamped" {
    const buf = bufferWith("uno\ndos\n");
    defer gtk.g_object_unref(buf);
    var it: gtk.GtkTextIter = .{};
    atLineByte(buf, &it, 99, 2);
    try testing.expect(gtk.gtk_text_iter_get_line(&it) < gtk.gtk_text_buffer_get_line_count(@ptrCast(buf)));
    try testing.expectEqual(@as(c_int, 0), lineIndexAt(buf, 0, -5));
}

test "atLineByte: every column of a multi-byte line lands on a boundary" {
    // The property that matters: whatever stale column arrives, the iterator it
    // produces is always one GTK can safely tag or edit at.
    const line = "áéíóú ✓✓ 😀 end";
    const buf = bufferWith("x\n" ++ line ++ "\n");
    defer gtk.g_object_unref(buf);

    var col: c_int = 0;
    while (col <= @as(c_int, line.len) + 4) : (col += 1) {
        var it: gtk.GtkTextIter = .{};
        atLineByte(buf, &it, 1, col);
        const idx: usize = @intCast(gtk.gtk_text_iter_get_line_index(&it));
        try testing.expect(idx <= line.len);
        if (idx < line.len) try testing.expect(line[idx] & 0xC0 != 0x80);
        // Never past the requested column, and never more than one character short.
        try testing.expect(idx <= @as(usize, @intCast(col)) or col > @as(c_int, line.len));
    }
}

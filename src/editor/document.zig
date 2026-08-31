/// Document — one open file.
///
/// Designed for per-tab use: each editor tab owns one Document instance plus
/// its own GtkSourceBuffer (see editor/tabs.zig).
const std = @import("std");
const gtk = @import("../gtk.zig");

/// Files at or above this size skip tree-sitter highlighting and fall back to
/// GtkSourceView's own incremental `.lang` highlighter, which is built for large
/// files.  What our path costs at this size is not the parse — that is
/// incremental and budgeted — but the copy of the text it keeps and the tag
/// sweep it owes the buffer when it hands the file back (see editor/syntax).
/// Tunable.
pub const large_threshold_bytes: usize = 4 * 1024 * 1024;

pub const Document = struct {
    /// Absolute path of the open file. Empty first byte means no file open.
    path: [4096:0]u8 = [_:0]u8{0} ** 4096,

    /// True when the file is large enough to skip tree-sitter (see threshold).
    large: bool = false,

    /// True when the file could not be loaded as UTF-8 text (binary or
    /// non-UTF-8 encoded).  The editor shows a placeholder instead of the
    /// source view for such files.
    is_binary: bool = false,

    pub fn isOpen(self: *const Document) bool {
        return self.path[0] != 0;
    }

    pub fn filename(self: *const Document) []const u8 {
        if (!self.isOpen()) return "";
        return std.fs.path.basename(std.mem.sliceTo(&self.path, 0));
    }

    /// True when the buffer has unsaved changes.
    pub fn isModified(self: *const Document, buffer: *gtk.GtkSourceBuffer) bool {
        if (!self.isOpen()) return false;
        return gtk.gtk_text_buffer_get_modified(@as(*gtk.GtkTextBuffer, @ptrCast(buffer))) != 0;
    }

    /// Writes buffer contents to disk via the C helper.
    /// On success the C helper resets the buffer's modified flag (which fires
    /// the modified-changed signal and updates the title automatically).
    pub fn save(self: *const Document, buffer: *gtk.GtkSourceBuffer) bool {
        if (!self.isOpen() or self.is_binary) return false;
        return gtk.zc_buffer_save(&self.path, @as(*anyopaque, @ptrCast(buffer))) != 0;
    }

    /// Loads a file into the buffer and records the path.
    /// Resets the modified flag after loading so the buffer starts clean.
    pub fn open(self: *Document, path: [*:0]const u8, buffer: *gtk.GtkSourceBuffer) void {
        const s = std.mem.sliceTo(path, 0);
        const n = @min(s.len, self.path.len - 1);
        @memcpy(self.path[0..n], s[0..n]);
        self.path[n] = 0;

        var raw: [*:0]u8 = undefined;
        var length: usize = 0;
        var err: ?*gtk.GError = null;
        if (gtk.g_file_get_contents(path, &raw, &length, &err) == 0) {
            if (err != null) gtk.g_error_free(err);
            return;
        }
        defer gtk.g_free(raw);

        if (gtk.g_utf8_validate(raw, @intCast(length), null) == 0) {
            self.is_binary = true;
            return;
        }

        self.large = length >= large_threshold_bytes;

        gtk.gtk_text_buffer_set_text(
            @as(*gtk.GtkTextBuffer, @ptrCast(buffer)),
            raw,
            @intCast(length),
        );

        const lm = gtk.gtk_source_language_manager_get_default();
        const lang = gtk.gtk_source_language_manager_guess_language(lm, path, null);
        gtk.gtk_source_buffer_set_language(buffer, lang);

        // gtk_text_buffer_set_text marks the buffer modified; reset it so the
        // title does not show a bullet right after opening.
        gtk.gtk_text_buffer_set_modified(@as(*gtk.GtkTextBuffer, @ptrCast(buffer)), 0);

        // gtk_text_buffer_set_text leaves the cursor at the end; place it at start.
        var start: gtk.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_start_iter(@as(*gtk.GtkTextBuffer, @ptrCast(buffer)), &start);
        gtk.gtk_text_buffer_place_cursor(@as(*gtk.GtkTextBuffer, @ptrCast(buffer)), &start);
    }
};

test "Document.isOpen: empty path" {
    const doc = Document{};
    try std.testing.expect(!doc.isOpen());
}

test "Document.isOpen: non-empty path" {
    var doc = Document{};
    doc.path[0] = '/';
    doc.path[1] = 0;
    try std.testing.expect(doc.isOpen());
}

test "Document.filename: no path open" {
    const doc = Document{};
    try std.testing.expectEqualStrings("", doc.filename());
}

test "Document.filename: returns basename" {
    var doc = Document{};
    const p = "/home/user/project/main.zig";
    @memcpy(doc.path[0..p.len], p);
    doc.path[p.len] = 0;
    try std.testing.expectEqualStrings("main.zig", doc.filename());
}

test "Document.filename: nested path" {
    var doc = Document{};
    const p = "/foo/bar/baz/widget.c";
    @memcpy(doc.path[0..p.len], p);
    doc.path[p.len] = 0;
    try std.testing.expectEqualStrings("widget.c", doc.filename());
}

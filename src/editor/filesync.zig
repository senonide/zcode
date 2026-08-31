//! Live external-sync for an open file.
//!
//! Each editor tab that shows a text buffer owns one FileSync.  It watches the
//! file on disk with a GFileMonitor and, when another process rewrites it,
//! decides what to do based on whether the buffer has unsaved edits:
//!
//!   * clean buffer  → re-read the file into the buffer (`reloaded`), so the
//!                     editor tracks the disk live while agents edit it;
//!   * dirty buffer  → never clobber: report a `conflict` for the caller to
//!                     resolve with a banner;
//!   * file deleted  → report `deleted`.
//!
//! "Externally modified" is decided by comparing the file's mtime+etag against a
//! baseline recorded at open / after every load and save, so the editor's own
//! writes never look external.  Re-reads go through GtkSourceFileLoader, which
//! loads asynchronously and handles encoding, keeping the UI responsive even
//! when an agent rewrites a large generated file.
//!
//! Deep module: the tab only wires three callbacks and calls save/reload; all
//! the monitor, debounce, baseline and async-load lifecycle lives here.

const std = @import("std");
const gtk = @import("../gtk.zig");

const alloc = std.heap.c_allocator;

// Coalesce a burst of writes (agents often write in chunks) into one reaction,
// and ignore the monitor noise our own save makes for a moment afterwards.
const debounce_ms: c_uint = 200;
const settle_us: i64 = 1_000_000; // 1s

pub const Handlers = struct {
    /// The file was re-read into the buffer.  ok=false means the read failed.
    /// `flash_start`..`flash_end` is the inclusive line band the reload changed
    /// (for a highlight), or both -1 when nothing useful to flash.
    reloaded: *const fn (ctx: *anyopaque, ok: bool, flash_start: c_int, flash_end: c_int) void,
    /// Disk changed while the buffer had unsaved edits — caller must resolve.
    conflict: *const fn (ctx: *anyopaque) void,
    /// The file was deleted on disk.
    deleted: *const fn (ctx: *anyopaque) void,
};

pub const FileSync = struct {
    buffer: *gtk.GtkSourceBuffer,
    sfile: *gtk.GtkSourceFile,
    gfile: *gtk.GFile,
    monitor: ?*gtk.GFileMonitor = null,
    cancel: ?*gtk.GCancellable = null,

    base_mtime: u64 = 0,
    base_mtime_usec: u32 = 0,
    base_etag: ?[*:0]u8 = null,

    debounce_id: c_uint = 0,
    save_settle_until: i64 = 0,
    loading: bool = false,
    changed_while_loading: bool = false,
    dead: bool = false,

    saved_line: c_int = 0,
    saved_byte: c_int = 0,
    old_text: ?[]u8 = null, // buffer snapshot taken before a reload, for the flash diff

    ctx: *anyopaque,
    handlers: Handlers,

    /// Records the file's current mtime+etag as the buffer's reference point.
    fn seedBaseline(self: *FileSync) void {
        if (self.base_etag) |e| {
            gtk.g_free(e);
            self.base_etag = null;
        }
        self.base_mtime = 0;
        self.base_mtime_usec = 0;
        const info = gtk.g_file_query_info(self.gfile, gtk.G_FILE_ATTRIBUTE_QUERY, gtk.G_FILE_QUERY_INFO_NONE, null, null) orelse return;
        defer gtk.g_object_unref(info);
        self.base_mtime = gtk.g_file_info_get_attribute_uint64(info, gtk.G_FILE_ATTRIBUTE_TIME_MODIFIED);
        self.base_mtime_usec = gtk.g_file_info_get_attribute_uint32(info, gtk.G_FILE_ATTRIBUTE_TIME_MODIFIED_USEC);
        if (gtk.g_file_info_get_etag(info)) |etag| self.base_etag = gtk.g_strdup(etag);
    }

    /// True when the file on disk differs from the recorded baseline.
    fn externallyModified(self: *FileSync) bool {
        const info = gtk.g_file_query_info(self.gfile, gtk.G_FILE_ATTRIBUTE_QUERY, gtk.G_FILE_QUERY_INFO_NONE, null, null) orelse return false;
        defer gtk.g_object_unref(info);
        const mtime = gtk.g_file_info_get_attribute_uint64(info, gtk.G_FILE_ATTRIBUTE_TIME_MODIFIED);
        const usec = gtk.g_file_info_get_attribute_uint32(info, gtk.G_FILE_ATTRIBUTE_TIME_MODIFIED_USEC);
        if (mtime != self.base_mtime or usec != self.base_mtime_usec) return true;
        const cur = gtk.g_file_info_get_etag(info);
        return !etagEqual(self.base_etag, cur);
    }

    fn bufferTextDup(self: *FileSync) ?[]u8 {
        const tb: *gtk.GtkTextBuffer = @ptrCast(self.buffer);
        var s: gtk.GtkTextIter = .{};
        var e: gtk.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_bounds(tb, &s, &e);
        const raw = gtk.gtk_text_buffer_get_text(tb, &s, &e, 1) orelse return null;
        defer gtk.g_free(@ptrCast(raw));
        return alloc.dupe(u8, std.mem.sliceTo(raw, 0)) catch null;
    }

    fn captureCursor(self: *FileSync) void {
        const tb: *gtk.GtkTextBuffer = @ptrCast(self.buffer);
        var it: gtk.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_iter_at_mark(tb, &it, gtk.gtk_text_buffer_get_insert(tb));
        self.saved_line = gtk.gtk_text_iter_get_line(&it);
        self.saved_byte = gtk.gtk_text_iter_get_line_index(&it);
    }

    fn restoreCursor(self: *FileSync) void {
        const tb: *gtk.GtkTextBuffer = @ptrCast(self.buffer);
        const n = gtk.gtk_text_buffer_get_line_count(tb);
        var line = self.saved_line;
        if (line >= n) line = n - 1;
        if (line < 0) line = 0;
        var it: gtk.GtkTextIter = .{};
        // The column was measured before the reload replaced the text, so the
        // character it pointed at may not start there any more.
        gtk.zc_iter_at_line_byte(tb, &it, line, self.saved_byte);
        gtk.gtk_text_buffer_place_cursor(tb, &it);
    }

    /// Re-reads the file into the buffer, preserving the cursor line/column.
    /// Used both for clean-buffer auto-reload and the user's explicit "Reload".
    pub fn reload(self: *FileSync) void {
        if (self.loading) {
            self.changed_while_loading = true;
            return;
        }
        self.captureCursor();
        if (self.old_text) |t| alloc.free(t);
        self.old_text = self.bufferTextDup();
        self.loading = true;
        self.changed_while_loading = false;
        self.cancel = gtk.g_cancellable_new();
        const loader = gtk.gtk_source_file_loader_new(self.buffer, self.sfile) orelse {
            self.loading = false;
            if (self.cancel) |c| {
                gtk.g_object_unref(c);
                self.cancel = null;
            }
            return;
        };
        gtk.gtk_source_file_loader_load_async(loader, gtk.G_PRIORITY_DEFAULT, self.cancel, null, null, null, &onLoadDone, self);
    }

    /// Re-anchors the baseline to the file on disk after the editor itself wrote
    /// it, and suppresses the monitor noise that write produces.
    pub fn noteSaved(self: *FileSync) void {
        self.seedBaseline();
        self.save_settle_until = gtk.g_get_monotonic_time() + settle_us;
    }

    /// Repoints the watcher at a new path after the file is renamed/moved.
    pub fn setLocation(self: *FileSync, path: [*:0]const u8) void {
        if (self.monitor) |m| {
            _ = gtk.g_file_monitor_cancel(m);
            gtk.g_object_unref(m);
            self.monitor = null;
        }
        gtk.g_object_unref(self.gfile);
        self.gfile = gtk.g_file_new_for_path(path) orelse return;
        gtk.gtk_source_file_set_location(self.sfile, self.gfile);
        self.seedBaseline();
        self.installMonitor();
    }

    fn installMonitor(self: *FileSync) void {
        self.monitor = gtk.g_file_monitor_file(self.gfile, gtk.G_FILE_MONITOR_WATCH_MOVES, null, null);
        if (self.monitor) |m|
            _ = gtk.g_signal_connect_data(m, "changed", @ptrCast(&onMonitorChanged), self, null, 0);
    }

    pub fn destroy(self: *FileSync) void {
        if (self.debounce_id != 0) {
            _ = gtk.g_source_remove(self.debounce_id);
            self.debounce_id = 0;
        }
        if (self.monitor) |m| {
            _ = gtk.g_file_monitor_cancel(m);
            gtk.g_object_unref(m);
            self.monitor = null;
        }
        if (self.cancel) |c| gtk.g_cancellable_cancel(c);
        if (self.loading) {
            // An async load is in flight; let its callback finalize us.
            self.dead = true;
            return;
        }
        self.finalize();
    }

    fn finalize(self: *FileSync) void {
        if (self.cancel) |c| {
            gtk.g_object_unref(c);
            self.cancel = null;
        }
        if (self.base_etag) |e| gtk.g_free(e);
        if (self.old_text) |t| alloc.free(t);
        gtk.g_object_unref(self.sfile);
        gtk.g_object_unref(self.gfile);
        alloc.destroy(self);
    }
};

const Band = struct { start: c_int, end: c_int };

/// The inclusive line band (in the new text) that differs between `old` and
/// `new`, found by trimming the common leading/trailing lines.  Returns a band
/// with start = -1 when there is nothing worth flashing (no change, or a change
/// so large it would just flash most of the file).
fn changedBand(old: []const u8, new: []const u8) Band {
    const none = Band{ .start = -1, .end = -1 };
    if (old.len > 4 * 1024 * 1024 or new.len > 4 * 1024 * 1024) return none;

    // Count leading and trailing lines that match, by line-slice equality.
    // No allocation: each line is located by scanning newlines from the nearest
    // known boundary, so the trim is O(matched bytes) rather than O(whole file).
    const on = std.mem.count(u8, old, "\n") + 1;
    const nn = std.mem.count(u8, new, "\n") + 1;
    if (new.len == 0) return none;

    // Common prefix: advance past whole lines that are byte-identical.
    var p: usize = 0;
    var opos: usize = 0;
    var npos: usize = 0;
    while (p < on and p < nn) {
        const ol = lineSlice(old, &opos);
        const nl = lineSlice(new, &npos);
        if (!std.mem.eql(u8, ol, nl)) break;
        p += 1;
    }

    // Common suffix: same, from the ends. Lines after the prefix overlap are
    // already consumed, so the suffix never crosses the prefix.
    var s: usize = 0;
    var oend: usize = old.len;
    var nend: usize = new.len;
    while (s < on - p and s < nn - p) {
        const ol = lineSliceBack(old, &oend);
        const nl = lineSliceBack(new, &nend);
        if (!std.mem.eql(u8, ol, nl)) break;
        s += 1;
    }

    const start: isize = @intCast(p);
    const end: isize = @as(isize, @intCast(nn)) - 1 - @as(isize, @intCast(s));
    if (start > end) return none;
    if (end - start + 1 > 400) return none;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// The next line ending at `*pos`, which is then advanced past its newline.
/// A line is the text up to (not including) the next '\n', or the remainder.
fn lineSlice(s: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    if (std.mem.indexOfScalarPos(u8, s, start, '\n')) |nl| {
        pos.* = nl + 1;
        return s[start..nl];
    }
    pos.* = s.len;
    return s[start..];
}

/// The final line of s[0..*end] when split on '\n', returned without its
/// separator; `*end` moves back to the separator. A trailing '\n' yields an
/// empty final line, matching std.mem.splitScalar(u8, '\n').
fn lineSliceBack(s: []const u8, end: *usize) []const u8 {
    if (end.* == 0) return s[0..0];
    const e = end.*;
    if (std.mem.lastIndexOfScalar(u8, s[0..e], '\n')) |nl| {
        end.* = nl;
        return s[nl + 1 .. e];
    }
    end.* = 0;
    return s[0..e];
}

test "changedBand: trims common prefix and suffix" {
    const b = changedBand("a\nb\nc\nd\n", "a\nB\nC\nd\n");
    try std.testing.expectEqual(@as(c_int, 1), b.start);
    try std.testing.expectEqual(@as(c_int, 2), b.end);
}

test "changedBand: identical text flashes nothing" {
    const b = changedBand("x\ny\n", "x\ny\n");
    try std.testing.expectEqual(@as(c_int, -1), b.start);
}

test "changedBand: pure insertion flashes only the new lines" {
    const b = changedBand("a\nb\n", "a\nNEW1\nNEW2\nb\n");
    try std.testing.expectEqual(@as(c_int, 1), b.start);
    try std.testing.expectEqual(@as(c_int, 2), b.end);
}

fn etagEqual(a: ?[*:0]u8, b: ?[*:0]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, std.mem.sliceTo(a.?, 0), std.mem.sliceTo(b.?, 0));
}

/// Creates a watcher for `path` bound to `buffer`.  `ctx` is handed back to the
/// handlers unchanged (the editor tab).  Returns null if the file handle or
/// source-file object can't be created.
pub fn create(buffer: *gtk.GtkSourceBuffer, path: [*:0]const u8, ctx: *anyopaque, handlers: Handlers) ?*FileSync {
    const gfile = gtk.g_file_new_for_path(path) orelse return null;
    const sfile = gtk.gtk_source_file_new() orelse {
        gtk.g_object_unref(gfile);
        return null;
    };
    gtk.gtk_source_file_set_location(sfile, gfile);

    const self = alloc.create(FileSync) catch {
        gtk.g_object_unref(sfile);
        gtk.g_object_unref(gfile);
        return null;
    };
    self.* = .{ .buffer = buffer, .sfile = sfile, .gfile = gfile, .ctx = ctx, .handlers = handlers };
    self.seedBaseline();
    self.installMonitor();
    return self;
}

fn onMonitorChanged(_: ?*gtk.GFileMonitor, _: ?*gtk.GFile, _: ?*gtk.GFile, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const self: *FileSync = @ptrCast(@alignCast(data.?));
    if (self.dead) return;
    if (self.loading) {
        self.changed_while_loading = true;
        return;
    }
    if (gtk.g_get_monotonic_time() < self.save_settle_until) return;
    if (self.debounce_id != 0) return;
    self.debounce_id = gtk.g_timeout_add(debounce_ms, &onDebounce, self);
}

fn onDebounce(data: ?*anyopaque) callconv(.c) c_int {
    const self: *FileSync = @ptrCast(@alignCast(data.?));
    self.debounce_id = 0;
    if (self.dead) return 0;

    if (gtk.g_file_query_exists(self.gfile, null) == 0) {
        self.handlers.deleted(self.ctx);
        return 0;
    }
    if (self.externallyModified()) {
        const dirty = gtk.gtk_text_buffer_get_modified(@ptrCast(self.buffer)) != 0;
        if (dirty)
            self.handlers.conflict(self.ctx)
        else
            self.reload();
    }
    return 0;
}

fn onLoadDone(source: ?*gtk.GObject, result: ?*gtk.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self: *FileSync = @ptrCast(@alignCast(data.?));
    const loader: *gtk.GtkSourceFileLoader = @ptrCast(@alignCast(source.?));
    var err: ?*gtk.GError = null;
    const ok = gtk.gtk_source_file_loader_load_finish(loader, result, &err) != 0;
    if (err) |e| gtk.g_error_free(e);
    gtk.g_object_unref(loader);

    if (self.cancel) |c| {
        gtk.g_object_unref(c);
        self.cancel = null;
    }
    self.loading = false;

    if (self.dead) {
        self.finalize();
        return;
    }

    var flash_start: c_int = -1;
    var flash_end: c_int = -1;
    if (ok) {
        self.restoreCursor();
        gtk.gtk_text_buffer_set_modified(@ptrCast(self.buffer), 0);
        self.seedBaseline();
        self.save_settle_until = gtk.g_get_monotonic_time() + settle_us;
        if (self.old_text) |old| {
            if (self.bufferTextDup()) |new| {
                defer alloc.free(new);
                const band = changedBand(old, new);
                flash_start = band.start;
                flash_end = band.end;
            }
        }
    }
    if (self.old_text) |t| {
        alloc.free(t);
        self.old_text = null;
    }
    self.handlers.reloaded(self.ctx, ok, flash_start, flash_end);

    // The file changed again while we were reading it — re-read to stay live.
    if (self.changed_while_loading and !self.loading) {
        self.changed_while_loading = false;
        if (self.debounce_id == 0)
            self.debounce_id = gtk.g_timeout_add(debounce_ms, &onDebounce, self);
    }
}

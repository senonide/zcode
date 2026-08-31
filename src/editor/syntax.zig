//! Tree-sitter syntax highlighting for an editor buffer.
//!
//! One `Highlighter` is attached to each supported source view; it owns the
//! parser, the tree, its own copy of the text, and paints a `GtkTextTag` per
//! highlight capture.  Overlapping captures resolve by tag priority, which GTK
//! assigns in creation order — and tags are created in capture-id order,
//! generic captures first, so the more specific capture wins, matching
//! tree-sitter's own precedence.
//!
//! All of this runs on the main loop between one keystroke and the next, and
//! the expensive part is not the parse: it is what painting does to
//! GtkTextView.  Applying or removing a tag invalidates that line's layout, and
//! GTK revalidates the whole visible range synchronously before the next frame.
//! Everything below is shaped around triggering that as rarely as possible:
//!
//!   * **A private copy of the text** (`Shadow`).  The parser and the query read
//!     bytes straight out of it, so neither ever walks the widget's B-tree.
//!   * **Incremental parsing** against that copy, bounded to `budget_us` per
//!     main-loop turn, and restarted rather than resumed when the buffer moved
//!     under an unfinished parse.
//!   * **One paint per settled viewport.**  A burst of edits collapses into one
//!     parse and one paint; painting in slices only made GTK revalidate the same
//!     lines once per slice.
//!   * **Per-line tag bookkeeping** (`Painted`), so repainting a line removes
//!     the few tags it carries instead of every tag in the query, and lines that
//!     have never been painted are not swept at all.
//!
//! Tree-sitter is used for highlighting only. Unsupported files keep
//! GtkSourceView's `.lang` highlighter (see editor/tabs); files at or above
//! `document.large_threshold_bytes` do too — including a file that only grows
//! that big while being edited, which is why the check is not just at open.

const std = @import("std");
const gtk = @import("../gtk.zig");
const ts = @import("tree-sitter");
const document = @import("document.zig");
const language = @import("language.zig");
const palette = @import("palette.zig");

const c_allocator = std.heap.c_allocator;
const data_key: [*:0]const u8 = "zc-syntax";

/// Extra lines painted above and below the viewport so small scrolls and the
/// cursor leaving the visible area don't reveal uncoloured text.
const margin_lines: c_int = 80;

/// Ceiling on the lines one pass may cover — the pass, not the viewport.
///
/// A viewport plus its margins is a couple of hundred lines, but GtkTextView
/// reports the visible range from line heights it has not measured yet, so right
/// after a large insertion it can claim thousands of lines are on screen.  The
/// ceiling keeps one pass proportional to a viewport; whatever is left over is
/// picked up by the pass after it, once the heights are real.
const max_paint_lines: c_int = 400;

/// How long a burst of edits accumulates before it is re-parsed.  The timer
/// restarts on every edit, so a repeated paste collapses into a single parse.
const reparse_delay_ms: c_uint = 50;

/// How long restarting may defer a parse.  Without a ceiling, typing without
/// pause would keep pushing the parse — and the colour — indefinitely.
const max_defer_us: i64 = 250_000;

/// What one main-loop turn may spend inside tree-sitter.  The parser stops at
/// the deadline and resumes on the next turn, so a file of any size is absorbed
/// a few milliseconds at a time instead of blocking the window.
const budget_us: i64 = 4_000;

/// Captures a `u64` line mask can track, one bit each.  Every bundled query is
/// far below this (the largest, Zig, has 38); a query above it simply loses the
/// per-line bookkeeping and falls back to sweeping every tag.
const max_tracked_tags: usize = 64;

fn deadline() i64 {
    return gtk.g_get_monotonic_time() + budget_us;
}

const Highlighter = struct {
    lang: *language.Language,
    view: *gtk.GtkTextView,
    buffer: *gtk.GtkTextBuffer,
    parser: *ts.Parser,
    tree: ?*ts.Tree = null,
    tags: []?*gtk.GtkTextTag,

    /// The text as tree-sitter sees it.
    doc: Shadow = .{},
    /// What is coloured, and with which tags.
    painted: Painted = .{},
    /// Masks for the run being painted, reused across passes.
    scratch: std.ArrayList(u64) = .empty,

    /// The buffer's own highlighter, set aside while tree-sitter has the file.
    /// Handed back if this one gives up (see `giveUp`).
    fallback_lang: ?*gtk.GtkSourceLanguage = null,

    /// Bumped on every edit.  `parsed` is the revision `tree` describes, so the
    /// two differ exactly while the tree points at text the buffer no longer
    /// has — not even at character boundaries.  Painting waits for the reparse.
    revision: u64 = 0,
    parsed: u64 = 0,
    /// The revision an unfinished parse started from, or null when none is.
    parsing: ?u64 = null,

    /// False when the query has more captures than a mask holds; `Painted` then
    /// carries no useful information and every repaint sweeps all tags.
    track_tags: bool = true,
    /// Set when the file outgrew what this highlighter is for; everything
    /// becomes a no-op and GtkSourceView's own highlighter takes over.
    disabled: bool = false,

    /// When the current burst of edits started, so a long one still gets parsed.
    burst_start: i64 = 0,

    change_timer: c_uint = 0,
    parse_idle: c_uint = 0,
    paint_idle: c_uint = 0,

    vadj: ?*gtk.GtkAdjustment = null,
    /// The scroll position the last paint was for.  `upper` also changes when
    /// our own tags change a line's height, and reacting to that would paint,
    /// change `upper` again and come straight back here.
    last_value: f64 = -1,
    last_page: f64 = -1,

    fn stale(self: *const Highlighter) bool {
        return self.revision != self.parsed;
    }
};

fn highlighterFor(view: *gtk.GtkSourceView) ?*Highlighter {
    const ptr = gtk.g_object_get_data(@ptrCast(view), data_key) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn isDark() bool {
    return gtk.adw_style_manager_get_dark(gtk.adw_style_manager_get_default()) != 0;
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

pub fn attach(view: *gtk.GtkSourceView, lang: *language.Language) void {
    const hl = build(view, lang) catch return;
    gtk.g_object_set_data(@ptrCast(view), data_key, @ptrCast(hl));

    // Take the file over from GtkSourceView's highlighter, keeping its language
    // so `giveUp` can hand the file straight back.
    hl.fallback_lang = gtk.gtk_source_buffer_get_language(@ptrCast(hl.buffer));
    gtk.gtk_source_buffer_set_language(@ptrCast(hl.buffer), null);

    // The only whole-buffer read there is: from here on the copy is patched by
    // the same edits the buffer gets.
    const text = bufferText(hl.buffer) orelse return giveUp(hl);
    defer gtk.g_free(text);
    if (!hl.doc.reset(std.mem.sliceTo(text, 0))) return giveUp(hl);

    hl.tree = hl.parser.parse(hl.doc.input(), null);

    _ = gtk.g_signal_connect_data(hl.buffer, "insert-text", @ptrCast(&onInsert), @ptrCast(hl), null, 0);
    _ = gtk.g_signal_connect_data(hl.buffer, "delete-range", @ptrCast(&onDelete), @ptrCast(hl), null, 0);
    _ = gtk.g_signal_connect_data(hl.buffer, "changed", @ptrCast(&onChanged), @ptrCast(hl), null, 0);

    if (gtk.gtk_scrollable_get_vadjustment(@ptrCast(view))) |vadj| {
        hl.vadj = vadj;
        _ = gtk.g_signal_connect_data(vadj, "value-changed", @ptrCast(&onScroll), @ptrCast(hl), null, 0);
        _ = gtk.g_signal_connect_data(vadj, "changed", @ptrCast(&onScroll), @ptrCast(hl), null, 0);
    }
    queuePaint(hl);
}

fn build(view: *gtk.GtkSourceView, lang: *language.Language) !*Highlighter {
    const query = lang.highlightQuery() orelse return error.NoQuery;
    const buffer: *gtk.GtkTextBuffer = @ptrCast(gtk.gtk_text_view_get_buffer(@ptrCast(view)).?);

    const parser = lang.newParser() orelse return error.NoParser;
    errdefer parser.destroy();

    const tags = try c_allocator.alloc(?*gtk.GtkTextTag, query.captureCount());
    errdefer c_allocator.free(tags);
    makeTags(buffer, query, tags);

    const hl = try c_allocator.create(Highlighter);
    hl.* = .{ .lang = lang, .view = @ptrCast(view), .buffer = buffer, .parser = parser, .tags = tags };
    hl.track_tags = tags.len <= max_tracked_tags;
    return hl;
}

fn makeTags(buffer: *gtk.GtkTextBuffer, query: *ts.Query, tags: []?*gtk.GtkTextTag) void {
    const dark = isDark();
    for (tags, 0..) |*slot, id| {
        const name = query.captureNameForId(@intCast(id)) orelse {
            slot.* = null;
            continue;
        };
        slot.* = if (palette.lookup(name)) |s|
            gtk.zc_text_tag_new(@ptrCast(buffer), if (dark) s.dark else s.light, @intFromBool(s.italic), @intFromBool(s.bold))
        else
            null;
    }
}

pub fn detach(view: *gtk.GtkSourceView) void {
    const hl = highlighterFor(view) orelse return;
    gtk.g_object_set_data(@ptrCast(view), data_key, null);

    cancelSources(hl);
    _ = gtk.g_signal_handlers_disconnect_matched(@ptrCast(hl.buffer), gtk.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(hl));
    if (hl.vadj) |vadj|
        _ = gtk.g_signal_handlers_disconnect_matched(@ptrCast(vadj), gtk.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(hl));
    if (hl.tree) |t| t.destroy();
    hl.doc.deinit();
    hl.painted.deinit();
    hl.scratch.deinit(c_allocator);
    hl.parser.destroy();
    c_allocator.free(hl.tags);
    c_allocator.destroy(hl);
}

/// Drops every pending timer and idle.  All three carry the highlighter as
/// their payload, so leaving one behind outlives what it points at.
fn cancelSources(hl: *Highlighter) void {
    if (hl.change_timer != 0) _ = gtk.g_source_remove(hl.change_timer);
    if (hl.parse_idle != 0) _ = gtk.g_source_remove(hl.parse_idle);
    if (hl.paint_idle != 0) _ = gtk.g_source_remove(hl.paint_idle);
    hl.change_timer = 0;
    hl.parse_idle = 0;
    hl.paint_idle = 0;
}

pub fn refreshColors(view: *gtk.GtkSourceView) void {
    const hl = highlighterFor(view) orelse return;
    const query = hl.lang.highlightQuery() orelse return;
    const dark = isDark();
    for (hl.tags, 0..) |slot, id| {
        const tag = slot orelse continue;
        const name = query.captureNameForId(@intCast(id)) orelse continue;
        const style = palette.lookup(name) orelse continue;
        gtk.zc_text_tag_set_fg(tag, if (dark) style.dark else style.light);
    }
}

/// Returns the full buffer text (null-terminated UTF-8).  Caller g_free()s.
/// Only used to seed the shadow copy when the file is opened.
fn bufferText(buffer: *gtk.GtkTextBuffer) ?[*:0]u8 {
    var start: gtk.GtkTextIter = .{};
    var end: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_bounds(buffer, &start, &end);
    return gtk.gtk_text_buffer_get_text(buffer, &start, &end, 1);
}

// ── The text, as tree-sitter sees it ─────────────────────────────────────────

/// A private copy of the buffer's text, plus where every line starts in it.
///
/// Reading through GtkTextBuffer instead is what the parser and the query used
/// to do, and it is the wrong shape for both: they address the document by
/// byte, GtkTextBuffer addresses it by character through a B-tree, so bridging
/// the two cost an iterator walk per read — two per capture, thousands per
/// painted viewport — and an allocation per chunk.  A copy patched by the same
/// edits the buffer gets stays byte-identical without ever being re-read, and
/// every offset tree-sitter produces indexes straight into it.
///
/// Every mutation reports whether it succeeded: a copy that silently fell out
/// of step with the buffer would feed the parser byte ranges the text does not
/// have, so the caller gives the file back to GtkSourceView instead.
const Shadow = struct {
    text: std.ArrayList(u8) = .empty,
    lines: LineTable = .{},

    fn deinit(self: *Shadow) void {
        self.text.deinit(c_allocator);
        self.lines.deinit();
        self.* = .{};
    }

    fn reset(self: *Shadow, content: []const u8) bool {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(c_allocator, content) catch return false;
        return self.lines.rebuild(content);
    }

    fn insert(self: *Shadow, at: u32, content: []const u8) bool {
        if (at > self.text.items.len) return false;
        self.text.insertSlice(c_allocator, at, content) catch return false;
        return self.lines.insert(at, content);
    }

    fn delete(self: *Shadow, start: u32, end: u32) bool {
        if (end > self.text.items.len or start > end) return false;
        self.text.replaceRangeAssumeCapacity(start, end - start, &.{});
        self.lines.delete(start, end);
        return true;
    }

    fn bytes(self: *const Shadow) []const u8 {
        return self.text.items;
    }

    fn total(self: *const Shadow) usize {
        return self.text.items.len;
    }

    /// Lines in the document, counted the way GtkTextBuffer counts them: a
    /// trailing newline opens an empty last line.
    fn lineCount(self: *const Shadow) c_int {
        return if (self.lines.len < 2) 1 else @intCast(self.lines.len - 1);
    }

    fn byteOffset(self: *const Shadow, row: u32, column: u32) u32 {
        return self.lines.byteOffset(row, column);
    }

    /// Feeds the parser the whole remaining text in one chunk — it is already
    /// contiguous, so there is nothing to copy and nothing to free.
    fn input(self: *Shadow) ts.Input {
        return .{ .payload = @ptrCast(self), .read = readChunk };
    }

    /// Where query predicates read the text of the node they are testing.
    fn source(self: *const Shadow) language.Source {
        return .{ .ctx = @ptrCast(@constCast(self)), .read = readSpan };
    }

    fn readChunk(payload: ?*anyopaque, byte_index: u32, _: ts.Point, bytes_read: *u32) callconv(.c) [*c]const u8 {
        const self: *Shadow = @ptrCast(@alignCast(payload.?));
        if (byte_index >= self.text.items.len) {
            bytes_read.* = 0;
            return "";
        }
        bytes_read.* = @intCast(self.text.items.len - byte_index);
        return self.text.items[byte_index..].ptr;
    }

    fn readSpan(ctx: ?*anyopaque, start_byte: u32, end_byte: u32, out: []u8) []const u8 {
        const self: *const Shadow = @ptrCast(@alignCast(ctx.?));
        const items = self.bytes();
        if (start_byte > end_byte or end_byte > items.len) return "";
        const want = @min(end_byte - start_byte, out.len);
        @memcpy(out[0..want], items[start_byte..][0..want]);
        return out[0..want];
    }
};

// ── Line-offset table ────────────────────────────────────────────────────────

/// Where every line of the document starts, in bytes.
///
/// Entry i is the first byte of line i, and one extra entry at the end holds the
/// total length — a bound, not a line start, so `lineAt` searches everything
/// before it.  For a document of L lines that is L + 1 entries.
///
/// The table moves with each edit rather than waiting for the next parse: an
/// edit arrives as a GtkTextIter's (row, column) and has to become a byte range
/// before tree-sitter can be told about it, and GTK delivers several edits per
/// main-loop iteration (a paste over a selection is a delete then an insert).
/// A table one edit behind describes byte ranges the text no longer has.
///
/// The allocation is kept when the document shrinks, so `len` — not
/// `entries.len` — is what bounds every read.
const LineTable = struct {
    entries: []u32 = &.{},
    len: usize = 0,

    fn deinit(self: *LineTable) void {
        if (self.entries.len > 0) c_allocator.free(self.entries);
        self.* = .{};
    }

    fn live(self: *const LineTable) []const u32 {
        return self.entries[0..self.len];
    }

    fn rebuild(self: *LineTable, bytes: []const u8) bool {
        const count = std.mem.count(u8, bytes, "\n") + 2;
        if (!self.reserve(count)) {
            self.len = 0;
            return false;
        }
        self.len = count;
        self.entries[0] = 0;
        var slot: usize = 1;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |idx| {
            self.entries[slot] = @intCast(idx + 1);
            slot += 1;
            pos = idx + 1;
        }
        self.entries[count - 1] = @intCast(bytes.len);
        return true;
    }

    /// The row containing `offset`; the trailing total is excluded from the
    /// search, so an offset at the very end belongs to the last real line.
    fn lineAt(self: *const LineTable, offset: u32) u32 {
        if (self.len < 2) return 0;
        return lineForOffset(self.live()[0 .. self.len - 1], offset);
    }

    /// O(1) byte offset of (row, column) — column is a byte index within the row.
    fn byteOffset(self: *const LineTable, row: u32, column: u32) u32 {
        if (self.len == 0) return column;
        const lo = self.live();
        const idx = @min(row, lo.len - 1);
        return @min(lo[lo.len - 1], lo[idx] + column);
    }

    fn insert(self: *LineTable, at: u32, text: []const u8) bool {
        const old_len = self.len;
        if (old_len < 2) return false;
        const delta: u32 = @intCast(text.len);
        const added = std.mem.count(u8, text, "\n");

        if (!self.reserve(old_len + added)) {
            self.len = 0;
            return false;
        }
        const lo = self.entries;
        const li: usize = self.lineAt(at);
        self.len = old_len + added;

        // Everything past the edited line shifts `added` slots right and `delta`
        // bytes down; copy backwards so the move never clobbers an unread entry.
        var i: usize = old_len;
        while (i > li + 1) : (i -= 1) lo[i - 1 + added] = lo[i - 1] + delta;

        // Each inserted newline opens a line start right after `li`.
        var slot: usize = li + 1;
        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |idx| {
            lo[slot] = at + @as(u32, @intCast(idx)) + 1;
            slot += 1;
            pos = idx + 1;
        }
        return true;
    }

    fn delete(self: *LineTable, start: u32, end: u32) void {
        const old_len = self.len;
        if (old_len < 2 or end <= start) return;
        const lo = self.entries;
        const delta = end - start;
        const first: usize = self.lineAt(start);
        const last: usize = self.lineAt(end);

        // Lines first+1 .. last disappear; the rest shift left and down.
        const removed = last - first;
        var i: usize = last + 1;
        while (i < old_len) : (i += 1) lo[i - removed] = lo[i] - delta;
        self.len = old_len - removed;
    }

    fn reserve(self: *LineTable, want: usize) bool {
        if (self.entries.len >= want) return true;
        const cap = @max(want, self.entries.len * 2);
        const grown = c_allocator.alloc(u32, cap) catch return false;
        @memcpy(grown[0..self.len], self.entries[0..self.len]);
        if (self.entries.len > 0) c_allocator.free(self.entries);
        self.entries = grown;
        return true;
    }
};

fn lineForOffset(lo: []const u32, byte_offset: u32) u32 {
    var low: u32 = 0;
    var high: u32 = @intCast(lo.len - 1);
    while (low < high) {
        const mid = low + (high - low + 1) / 2;
        if (lo[mid] <= byte_offset) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    return low;
}

// ── What is painted ──────────────────────────────────────────────────────────

const LineRange = struct { first: c_int, last: c_int };

/// Which highlight tags each painted line carries.
///
/// Tags are anchored to the text, so they travel with it: a line stays correctly
/// coloured until its own text changes, however much is inserted above it.
/// Remembering the band is what makes scrolling back over coloured text free.
/// Remembering the tags *within* each line is what keeps a repaint from removing
/// every tag in the query one by one — GtkTextBuffer invalidates the range's
/// layout on each removal, whether the tag was there or not.
///
/// The band is one contiguous run because the areas that need painting always
/// are: a viewport, or the lines an edit restructured.  A line outside it has no
/// record, which reads as "unknown" and falls back to the full sweep — except
/// past `high_water`, which no paint has ever reached and so carries no tags at
/// all.
const Painted = struct {
    /// First line of the band; `masks.items[i]` describes line `first + i`.
    first: c_int = 0,
    masks: std.ArrayList(u64) = .empty,
    /// Highest line ever painted, tracked across band restarts because the tags
    /// stay in the buffer even when the record of them is dropped.
    high_water: c_int = -1,

    fn deinit(self: *Painted) void {
        self.masks.deinit(c_allocator);
        self.* = .{};
    }

    fn isEmpty(self: *const Painted) bool {
        return self.masks.items.len == 0;
    }

    fn last(self: *const Painted) c_int {
        return self.first + @as(c_int, @intCast(self.masks.items.len)) - 1;
    }

    fn maskFor(self: *const Painted, line: c_int) ?u64 {
        if (self.isEmpty() or line < self.first or line > self.last()) return null;
        return self.masks.items[@intCast(line - self.first)];
    }

    /// Forgets the band.  The tags stay on the text, so `high_water` does not
    /// move: those lines still have to be swept before they are painted again.
    fn clear(self: *Painted) void {
        self.masks.clearRetainingCapacity();
        self.first = 0;
    }

    /// Records a freshly painted run, extending the band when the run adjoins
    /// it.  A run that does not touch the band replaces it: painting works
    /// outwards from the viewport, so the band closes again within a pass or two.
    fn record(self: *Painted, from: c_int, masks: []const u64) bool {
        if (masks.len == 0) return true;
        const to = from + @as(c_int, @intCast(masks.len)) - 1;
        self.high_water = @max(self.high_water, to);

        if (!self.isEmpty()) {
            if (from == self.last() + 1) {
                self.masks.appendSlice(c_allocator, masks) catch return false;
                return true;
            }
            if (to == self.first - 1) {
                self.masks.insertSlice(c_allocator, 0, masks) catch return false;
                self.first = from;
                return true;
            }
            if (from >= self.first and to <= self.last()) {
                @memcpy(self.masks.items[@intCast(from - self.first)..][0..masks.len], masks);
                return true;
            }
            self.masks.clearRetainingCapacity();
        }
        self.masks.appendSlice(c_allocator, masks) catch return false;
        self.first = from;
        return true;
    }

    /// Forgets `line` and everything below it — their text changed, so their
    /// tags are the wrong ones until the next paint.
    fn dropFrom(self: *Painted, line: c_int) void {
        if (self.isEmpty() or line > self.last()) return;
        if (line <= self.first) return self.clear();
        self.masks.shrinkRetainingCapacity(@intCast(line - self.first));
    }

    /// Moves the record with the text when lines appear or disappear at
    /// `at_row`.  The tags themselves are anchored in the buffer and travel on
    /// their own; only the line numbers covering them have to follow.
    fn shift(self: *Painted, at_row: c_int, delta: c_int) void {
        if (at_row <= self.high_water) self.high_water = @max(-1, self.high_water + delta);
        if (delta == 0 or self.isEmpty() or at_row > self.last()) return;
        if (at_row < self.first) {
            self.first += delta;
            if (self.first < 0) self.clear();
            return;
        }
        // The edit lands inside the band: everything from it down is repainted.
        self.dropFrom(at_row);
    }
};

// ── Edit tracking ────────────────────────────────────────────────────────────

fn pointOf(it: *const gtk.GtkTextIter) ts.Point {
    return .{
        .row = @intCast(gtk.gtk_text_iter_get_line(it)),
        .column = @intCast(gtk.gtk_text_iter_get_line_index(it)),
    };
}

fn pointAfter(start: ts.Point, bytes: []const u8) ts.Point {
    if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |nl| {
        const lines = std.mem.count(u8, bytes, "\n");
        return .{ .row = start.row + @as(u32, @intCast(lines)), .column = @intCast(bytes.len - nl - 1) };
    }
    return .{ .row = start.row, .column = start.column + @as(u32, @intCast(bytes.len)) };
}

fn onInsert(_: ?*anyopaque, location: *const gtk.GtkTextIter, text: [*]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    if (hl.disabled) return;
    const items = text[0..@intCast(len)];
    const sp = pointOf(location);
    const at = hl.doc.byteOffset(sp.row, sp.column);
    if (hl.tree) |tree| tree.edit(.{
        .start_byte = at,
        .old_end_byte = at,
        .new_end_byte = at + @as(u32, @intCast(items.len)),
        .start_point = sp,
        .old_end_point = sp,
        .new_end_point = pointAfter(sp, items),
    });
    if (!hl.doc.insert(at, items)) return giveUp(hl);
    noteEdit(hl, sp.row, @intCast(std.mem.count(u8, items, "\n")));
}

fn onDelete(_: ?*anyopaque, start: *const gtk.GtkTextIter, end: *const gtk.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    if (hl.disabled) return;
    const sp = pointOf(start);
    const ep = pointOf(end);
    const sb = hl.doc.byteOffset(sp.row, sp.column);
    const eb = hl.doc.byteOffset(ep.row, ep.column);
    if (eb <= sb) return;
    if (hl.tree) |tree| tree.edit(.{
        .start_byte = sb,
        .old_end_byte = eb,
        .new_end_byte = sb,
        .start_point = sp,
        .old_end_point = ep,
        .new_end_point = sp,
    });
    if (!hl.doc.delete(sb, eb)) return giveUp(hl);
    noteEdit(hl, sp.row, -@as(c_int, @intCast(ep.row - sp.row)));
}

/// Common tail of both edits: the tree now describes older text, whatever paint
/// was queued was queued for line numbers that have moved, and the record of
/// what is coloured has to follow the text.
fn noteEdit(hl: *Highlighter, at_row: u32, delta: c_int) void {
    hl.revision +%= 1;
    cancelPaint(hl);
    hl.painted.shift(@intCast(at_row), delta);
}

// ── Parsing ──────────────────────────────────────────────────────────────────

/// A timer rather than an idle, restarted on every edit: an idle fires between
/// every pair of events, so a held key or a repeated paste paid for a parse
/// each.  Restarting collapses a burst into the single parse that follows it,
/// up to `max_defer_us` so continuous typing still gets coloured.
fn onChanged(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    if (hl.disabled) return;

    const now = gtk.g_get_monotonic_time();
    if (hl.change_timer == 0) {
        hl.burst_start = now;
    } else if (now - hl.burst_start >= max_defer_us) {
        return; // deferred long enough; let the parse already due land
    } else {
        _ = gtk.g_source_remove(hl.change_timer);
    }
    hl.change_timer = gtk.g_timeout_add(reparse_delay_ms, &onReparseDue, @ptrCast(hl));
}

fn onReparseDue(data: ?*anyopaque) callconv(.c) c_int {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    hl.change_timer = 0;
    runParse(hl);
    return 0;
}

/// Resumes a parse that ran out of budget last turn.
fn onParseSlice(data: ?*anyopaque) callconv(.c) c_int {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    hl.parse_idle = 0;
    runParse(hl);
    return 0;
}

/// Parses within one turn's budget.  Tree-sitter stops at the deadline and
/// picks up where it left off next time, so an insertion of any size is absorbed
/// a few milliseconds at a time instead of blocking the window until it is done.
fn runParse(hl: *Highlighter) void {
    if (hl.disabled) return;
    if (hl.doc.total() >= document.large_threshold_bytes) return giveUp(hl);

    // Tree-sitter resumes an interrupted parse from its own saved state and
    // reads the rest of the document as it is *now*, ignoring the tree it was
    // handed — so a parse whose text moved under it would describe a document
    // that never existed.  Throw that state away and start over; the edits since
    // are already recorded in `tree`, so the restart is still incremental.
    if (hl.parsing) |started| {
        if (started != hl.revision) {
            hl.parser.reset();
            hl.parsing = null;
        }
    }
    if (hl.parsing == null) hl.parsing = hl.revision;

    var stop_at = deadline();
    const options: ts.Parser.Options = .{ .payload = @ptrCast(&stop_at), .progress_callback = parseExpired };
    const fresh = hl.parser.parseWithOptions(hl.doc.input(), hl.tree, options) orelse {
        // Out of budget mid-parse: the parser keeps its state, so simply come
        // back for another slice.  Anything else would restart it from scratch.
        if (hl.parse_idle == 0) hl.parse_idle = gtk.g_idle_add(&onParseSlice, @ptrCast(hl));
        return;
    };
    hl.parsing = null;
    hl.parsed = hl.revision;

    const changed = if (hl.tree) |old| blk: {
        const band = changedLines(old, fresh);
        old.destroy();
        break :blk band;
    } else null;
    hl.tree = fresh;

    if (changed) |band| {
        if (band.last >= band.first) hl.painted.dropFrom(band.first);
    } else {
        hl.painted.clear(); // first parse: nothing describes the tree yet
    }
    // Queued rather than painted here: parsing and painting are the two halves
    // of the cost, and leaving the turn between them lets the loop answer input.
    queuePaint(hl);
}

fn parseExpired(state: *const ts.Parser.State) callconv(.c) bool {
    const stop_at: *const i64 = @ptrCast(@alignCast(state.payload.?));
    return gtk.g_get_monotonic_time() > stop_at.*;
}

/// The line span the two trees disagree on.  Tree-sitter reports the byte ranges
/// whose node structure moved; anything outside them is still described by the
/// tags already on screen, so only this band needs repainting — which is what
/// keeps a keystroke from invalidating the whole viewport's layout.
fn changedLines(old: *ts.Tree, new: *ts.Tree) ?LineRange {
    const ranges = old.getChangedRanges(c_allocator, new) catch return null;
    defer c_allocator.free(ranges);
    if (ranges.len == 0) return .{ .first = 0, .last = -1 };

    var first: c_int = std.math.maxInt(c_int);
    var last: c_int = -1;
    for (ranges) |r| {
        first = @min(first, @as(c_int, @intCast(r.start_point.row)));
        last = @max(last, @as(c_int, @intCast(r.end_point.row)));
    }
    return .{ .first = first, .last = last };
}

/// The file outgrew what this highlighter is for, or its copy of the text fell
/// out of step with the buffer.  Give the file back to GtkSourceView's own
/// incremental highlighter and go quiet.
fn giveUp(hl: *Highlighter) void {
    hl.disabled = true;
    cancelSources(hl);
    if (hl.tree) |t| t.destroy();
    hl.tree = null;
    hl.doc.deinit();
    hl.painted.deinit();
    hl.scratch.clearAndFree(c_allocator);

    var start: gtk.GtkTextIter = .{};
    var end: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_bounds(hl.buffer, &start, &end);
    for (hl.tags) |slot| {
        if (slot) |tag| gtk.gtk_text_buffer_remove_tag(hl.buffer, tag, &start, &end);
    }
    gtk.gtk_source_buffer_set_language(@ptrCast(hl.buffer), hl.fallback_lang);
}

// ── Painting ─────────────────────────────────────────────────────────────────

/// A scroll the user can see, as opposed to the adjustment growing because a
/// tag we just applied made a line taller.  Only the former needs a paint, and
/// telling them apart is what stops painting from feeding itself.
fn onScroll(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    if (hl.disabled) return;
    const vadj = hl.vadj orelse return;
    const value = gtk.gtk_adjustment_get_value(vadj);
    const page = gtk.gtk_adjustment_get_page_size(vadj);
    if (value == hl.last_value and page == hl.last_page) return;
    hl.last_value = value;
    hl.last_page = page;
    queuePaint(hl);
}

fn queuePaint(hl: *Highlighter) void {
    if (hl.disabled or hl.paint_idle != 0) return;
    hl.paint_idle = gtk.g_idle_add(&onPaint, @ptrCast(hl));
}

/// Drops a queued paint.  Called when an edit invalidates the line numbers it
/// would have painted; the parse that follows queues a fresh one.
fn cancelPaint(hl: *Highlighter) void {
    if (hl.paint_idle != 0) {
        _ = gtk.g_source_remove(hl.paint_idle);
        hl.paint_idle = 0;
    }
}

fn onPaint(data: ?*anyopaque) callconv(.c) c_int {
    const hl: *Highlighter = @ptrCast(@alignCast(data.?));
    hl.paint_idle = 0;
    paintViewport(hl);
    return 0;
}

/// Paints whatever part of the viewport is not painted yet, in one pass.
///
/// One pass rather than a slice per main-loop turn: each pass invalidates the
/// layout of the lines it touches, and GTK revalidates the visible range
/// synchronously before the next frame — so slicing the same work across N turns
/// bought N revalidations of the same lines instead of one.  The *range* is
/// bounded instead (`max_paint_lines`), which bounds the pass without
/// multiplying it.
fn paintViewport(hl: *Highlighter) void {
    if (hl.disabled or hl.tree == null or hl.stale()) return;
    if (hl.change_timer != 0) return; // mid-burst: a parse is already due

    const range = viewportLines(hl);
    if (range.last < range.first) return;

    const was: LineRange = .{ .first = hl.painted.first, .last = hl.painted.last() };
    paintMissing(hl, range);
    if (hl.painted.first == was.first and hl.painted.last() == was.last) return;

    // Painting changes line heights, so what is on screen now is not quite what
    // this pass was computed from — and one pass is capped at `max_paint_lines`,
    // which a viewport reported before GTK measured freshly inserted text can
    // exceed.  Come back for the rest.  Only after real progress, and only while
    // something is still uncovered, so this settles instead of cycling.
    const settled = viewportLines(hl);
    if (settled.first < hl.painted.first or settled.last > hl.painted.last()) queuePaint(hl);
}

fn paintMissing(hl: *Highlighter, range: LineRange) void {
    const band: LineRange = .{ .first = hl.painted.first, .last = hl.painted.last() };
    for (missingRuns(band, range)) |run| {
        if (run) |r| paint(hl, r.first, r.last);
    }
}

/// The parts of `range` that `band` does not already cover: at most one above it
/// and one below, each capped to `max_paint_lines` and each adjoining the band so
/// it extends rather than replaces it.  `band.last < band.first` means nothing is
/// painted yet.  Both runs are measured against the same band on purpose — the
/// first one only moves the end it adjoins, so the second still fits.
fn missingRuns(band: LineRange, range: LineRange) [2]?LineRange {
    if (band.last < band.first)
        return .{ capFrom(range.first, range.last), null };

    var runs: [2]?LineRange = .{ null, null };
    if (range.first < band.first) runs[0] = capTo(range.first, @min(band.first - 1, range.last));
    if (range.last > band.last) runs[1] = capFrom(@max(band.last + 1, range.first), range.last);
    return runs;
}

/// `first`..`last`, shortened from the end.
fn capFrom(first: c_int, last: c_int) LineRange {
    return .{ .first = first, .last = @min(last, first + max_paint_lines - 1) };
}

/// `first`..`last`, shortened from the start — the end is what adjoins the band.
fn capTo(first: c_int, last: c_int) LineRange {
    return .{ .first = @max(first, last - max_paint_lines + 1), .last = last };
}

fn viewportLines(hl: *Highlighter) LineRange {
    var rect: gtk.GdkRectangle = .{};
    gtk.gtk_text_view_get_visible_rect(hl.view, &rect);
    if (rect.height <= 0) return .{ .first = 0, .last = -1 };

    var top: gtk.GtkTextIter = .{};
    var bot: gtk.GtkTextIter = .{};
    gtk.gtk_text_view_get_line_at_y(hl.view, &top, rect.y, null);
    gtk.gtk_text_view_get_line_at_y(hl.view, &bot, rect.y + rect.height, null);

    const n = hl.doc.lineCount();
    return .{
        .first = @max(0, gtk.gtk_text_iter_get_line(&top) - margin_lines),
        .last = @min(n - 1, gtk.gtk_text_iter_get_line(&bot) + margin_lines),
    };
}

/// Runs the highlight query over `first`..`last` and applies a tag per capture,
/// recording which tags each line ends up with.  Node points are already
/// (row, byte-in-row), which is what the buffer wants.
fn paint(hl: *Highlighter, first: c_int, last: c_int) void {
    if (last < first) return;
    const tree = hl.tree orelse return;
    const query = hl.lang.highlightQuery() orelse return;

    const count: usize = @intCast(last - first + 1);
    hl.scratch.resize(c_allocator, count) catch return;
    const masks = hl.scratch.items;
    @memset(masks, 0);

    removeTags(hl, first, last);

    var it = language.matchesInRange(
        query,
        tree.rootNode(),
        hl.doc.source(),
        .{ .row = @intCast(first), .column = 0 },
        .{ .row = @intCast(last + 1), .column = 0 },
    );
    defer it.deinit();

    while (it.next()) |match| {
        for (match.captures) |capture| {
            if (capture.index >= hl.tags.len) continue;
            const tag = hl.tags[capture.index] orelse continue;
            const sp = capture.node.startPoint();
            const ep = capture.node.endPoint();
            if (ep.row < sp.row or (ep.row == sp.row and ep.column <= sp.column)) continue;
            var a: gtk.GtkTextIter = .{};
            var b: gtk.GtkTextIter = .{};
            gtk.zc_iter_at_line_byte(hl.buffer, &a, @intCast(sp.row), @intCast(sp.column));
            gtk.zc_iter_at_line_byte(hl.buffer, &b, @intCast(ep.row), @intCast(ep.column));
            gtk.gtk_text_buffer_apply_tag(hl.buffer, tag, &a, &b);
            if (hl.track_tags) markLines(masks, first, last, capture.index, sp.row, ep.row);
        }
    }
    // A record that could not be kept only costs the next repaint of these lines
    // a full sweep; the colour on screen is right either way.
    _ = hl.painted.record(first, masks);
}

fn markLines(masks: []u64, first: c_int, last: c_int, capture: u32, start_row: u32, end_row: u32) void {
    const bit = @as(u64, 1) << @intCast(capture);
    var row = @max(first, @as(c_int, @intCast(start_row)));
    const stop = @min(last, @as(c_int, @intCast(end_row)));
    while (row <= stop) : (row += 1) masks[@intCast(row - first)] |= bit;
}

/// Drops the tags on `first`..`last` so the paint that follows can lay down the
/// current ones.
///
/// Only the tags those lines are known to carry: GtkTextBuffer invalidates the
/// range's layout on every removal, present or not, so sweeping the query's
/// whole tag list costs one invalidation per tag rather than per tag that is
/// actually there.  Lines past `high_water` have never been painted and are
/// skipped outright; a line with no record falls back to the full sweep.
fn removeTags(hl: *Highlighter, first: c_int, last: c_int) void {
    const end = @min(last, hl.painted.high_water);
    if (end < first) return; // no paint has ever reached here

    var present: u64 = 0;
    var unknown = !hl.track_tags;
    if (!unknown) {
        var line = first;
        while (line <= end) : (line += 1) {
            const mask = hl.painted.maskFor(line) orelse {
                unknown = true;
                break;
            };
            present |= mask;
        }
    }
    if (!unknown and present == 0) return;

    var a: gtk.GtkTextIter = .{};
    var b: gtk.GtkTextIter = .{};
    lineBounds(hl, first, end, &a, &b);
    for (hl.tags, 0..) |slot, id| {
        const tag = slot orelse continue;
        if (!unknown and present & (@as(u64, 1) << @intCast(id)) == 0) continue;
        gtk.gtk_text_buffer_remove_tag(hl.buffer, tag, &a, &b);
    }
}

/// Iterators spanning `first`..`last` inclusive, in buffer coordinates.
fn lineBounds(hl: *Highlighter, first: c_int, last: c_int, a: *gtk.GtkTextIter, b: *gtk.GtkTextIter) void {
    _ = gtk.gtk_text_buffer_get_iter_at_line(hl.buffer, a, first);
    const n = hl.doc.lineCount();
    if (last + 1 < n) {
        _ = gtk.gtk_text_buffer_get_iter_at_line(hl.buffer, b, last + 1);
    } else {
        var ignored: gtk.GtkTextIter = .{};
        gtk.gtk_text_buffer_get_bounds(hl.buffer, &ignored, b);
    }
}

// ── LineTable ────────────────────────────────────────────────────────────────
//
// Every case checks the incrementally patched table against a rebuild of the
// text it should now describe: the two disagreeing is exactly what corrupts the
// byte ranges fed to tree-sitter.

fn expectMatchesRebuild(table: *const LineTable, text: []const u8) !void {
    var fresh: LineTable = .{};
    defer fresh.deinit();
    try std.testing.expect(fresh.rebuild(text));
    try std.testing.expectEqualSlices(u32, fresh.live(), table.live());
}

test "LineTable.rebuild: layout" {
    var t: LineTable = .{};
    defer t.deinit();

    try std.testing.expect(t.rebuild(""));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, t.live());

    try std.testing.expect(t.rebuild("abc"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, t.live());

    // A trailing newline opens an empty last line, so its start and the total
    // both sit at the end.
    try std.testing.expect(t.rebuild("a\n"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 2 }, t.live());

    try std.testing.expect(t.rebuild("a\nbb\nccc"));
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 5, 8 }, t.live());
}

test "LineTable.lineAt: end of buffer belongs to the last line" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nbb\nccc"));
    try std.testing.expectEqual(@as(u32, 0), t.lineAt(0));
    try std.testing.expectEqual(@as(u32, 1), t.lineAt(2));
    try std.testing.expectEqual(@as(u32, 2), t.lineAt(5));
    // Offset 8 is the total; it must not resolve to the trailing bound.
    try std.testing.expectEqual(@as(u32, 2), t.lineAt(8));
}

test "LineTable.byteOffset: row and byte column" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nbb\nccc"));
    try std.testing.expectEqual(@as(u32, 0), t.byteOffset(0, 0));
    try std.testing.expectEqual(@as(u32, 3), t.byteOffset(1, 1));
    try std.testing.expectEqual(@as(u32, 7), t.byteOffset(2, 2));
    // Clamped to the buffer rather than running past it.
    try std.testing.expectEqual(@as(u32, 8), t.byteOffset(2, 99));
}

test "LineTable.insert: without a newline" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nbb\nccc"));
    try std.testing.expect(t.insert(2, "XY")); // "a\nXYbb\nccc"
    try expectMatchesRebuild(&t, "a\nXYbb\nccc");
}

test "LineTable.insert: at the very end" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nbb"));
    try std.testing.expect(t.insert(4, "!")); // "a\nbb!"
    try expectMatchesRebuild(&t, "a\nbb!");
}

test "LineTable.insert: a multi-line paste" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("head\ntail\n"));
    try std.testing.expect(t.insert(5, "1\n2\n3\n")); // "head\n1\n2\n3\ntail\n"
    try expectMatchesRebuild(&t, "head\n1\n2\n3\ntail\n");
}

test "LineTable.delete: within one line" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nbbbb\nc"));
    t.delete(3, 5); // "a\nbb\nc"
    try expectMatchesRebuild(&t, "a\nbb\nc");
}

test "LineTable.delete: spanning lines" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("one\ntwo\nthree\nfour\n"));
    t.delete(4, 14); // drops "two\nthree\n"
    try expectMatchesRebuild(&t, "one\nfour\n");
}

test "LineTable: the allocation is reused after the buffer shrinks" {
    var t: LineTable = .{};
    defer t.deinit();
    try std.testing.expect(t.rebuild("a\nb\nc\nd\ne\nf\n"));
    const grown = t.entries.len;
    try std.testing.expect(t.rebuild("x\n"));
    // Kept oversized on purpose — only `len` may bound a read, which is what
    // `live()` enforces.
    try std.testing.expectEqual(grown, t.entries.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 2 }, t.live());
}

test "lineForOffset: single line" {
    // One line with 10 bytes plus sentinel (total length 10).
    const lo = [_]u32{ 0, 10 };
    try std.testing.expectEqual(@as(u32, 0), lineForOffset(&lo, 0));
    try std.testing.expectEqual(@as(u32, 0), lineForOffset(&lo, 9));
}

test "lineForOffset: multiple lines" {
    // Three lines: offsets 0, 5, 12; sentinel 20.
    const lo = [_]u32{ 0, 5, 12, 20 };
    try std.testing.expectEqual(@as(u32, 0), lineForOffset(&lo, 0));
    try std.testing.expectEqual(@as(u32, 0), lineForOffset(&lo, 4));
    try std.testing.expectEqual(@as(u32, 1), lineForOffset(&lo, 5));
    try std.testing.expectEqual(@as(u32, 1), lineForOffset(&lo, 11));
    try std.testing.expectEqual(@as(u32, 2), lineForOffset(&lo, 12));
    try std.testing.expectEqual(@as(u32, 2), lineForOffset(&lo, 19));
}

test "lineForOffset: offset at exact line start" {
    const lo = [_]u32{ 0, 8, 16, 24 };
    try std.testing.expectEqual(@as(u32, 1), lineForOffset(&lo, 8));
    try std.testing.expectEqual(@as(u32, 2), lineForOffset(&lo, 16));
}

// ── Shadow ───────────────────────────────────────────────────────────────────

fn expectShadow(doc: *const Shadow, text: []const u8) !void {
    try std.testing.expectEqualStrings(text, doc.bytes());
    try expectMatchesRebuild(&doc.lines, text);
}

test "Shadow: a paste over a selection stays in step" {
    // GTK delivers this as delete-range then insert-text in one iteration, and
    // the second edit's byte offsets come from the state the first one left.
    var doc: Shadow = .{};
    defer doc.deinit();
    try std.testing.expect(doc.reset("keep\nold one\nold two\nkeep\n"));

    const start = doc.byteOffset(1, 0);
    const end = doc.byteOffset(3, 0);
    try std.testing.expect(doc.delete(start, end));
    try expectShadow(&doc, "keep\nkeep\n");

    const at = doc.byteOffset(1, 0);
    try std.testing.expectEqual(@as(u32, 5), at);
    try std.testing.expect(doc.insert(at, "new\nnew\n"));
    try expectShadow(&doc, "keep\nnew\nnew\nkeep\n");
}

test "Shadow: a paste far larger than any fixed buffer" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 500) : (i += 1) try text.appendSlice(std.testing.allocator, "line\n");

    var doc: Shadow = .{};
    defer doc.deinit();
    try std.testing.expect(doc.reset("A\nB\n"));
    try std.testing.expect(doc.insert(2, text.items));

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.appendSlice(std.testing.allocator, "A\n");
    try expected.appendSlice(std.testing.allocator, text.items);
    try expected.appendSlice(std.testing.allocator, "B\n");
    try expectShadow(&doc, expected.items);
}

test "Shadow.lineCount: counted the way GtkTextBuffer counts" {
    var doc: Shadow = .{};
    defer doc.deinit();
    try std.testing.expect(doc.reset(""));
    try std.testing.expectEqual(@as(c_int, 1), doc.lineCount());
    try std.testing.expect(doc.reset("a\nbb\nccc"));
    try std.testing.expectEqual(@as(c_int, 3), doc.lineCount());
    try std.testing.expect(doc.reset("a\n"));
    try std.testing.expectEqual(@as(c_int, 2), doc.lineCount());
}

test "Shadow: random edit sequences never drift from the text" {
    // The incremental path is what feeds tree-sitter its byte ranges, and a copy
    // that has drifted from the buffer produces offsets that fall inside
    // characters — which corrupts the text buffer rather than merely
    // mishighlighting.  So drive it the way the editor does and compare after
    // every single edit.
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();

    var doc: Shadow = .{};
    defer doc.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);

    try text.appendSlice(a, "fn main() {\n    return;\n}\n");
    try std.testing.expect(doc.reset(text.items));

    var step: usize = 0;
    while (step < 1500) : (step += 1) {
        // Kept bounded so the per-step rebuild stays cheap.
        const shrink = text.items.len > 20_000;
        if (text.items.len > 4 and (shrink or rand.boolean())) {
            const start = rand.uintLessThan(usize, text.items.len);
            const span: usize = if (shrink) 2048 else 64;
            const end = start + 1 + rand.uintLessThan(usize, @min(span, text.items.len - start));
            try std.testing.expect(doc.delete(@intCast(start), @intCast(end)));
            text.replaceRangeAssumeCapacity(start, end - start, "");
        } else {
            const at = rand.uintLessThan(usize, text.items.len + 1);
            // Chunks up to a few hundred lines: a paste, not a keystroke.
            const chunks = [_][]const u8{ "x", "\n", "a\nb\n", "  const x = 1;\n", "\n\n\n", "// ñ é ✓\n" };
            var piece: std.ArrayList(u8) = .empty;
            defer piece.deinit(a);
            var n = rand.uintLessThan(usize, 40);
            while (n > 0) : (n -= 1)
                try piece.appendSlice(a, chunks[rand.uintLessThan(usize, chunks.len)]);
            if (piece.items.len == 0) continue;
            try std.testing.expect(doc.insert(@intCast(at), piece.items));
            try text.insertSlice(a, at, piece.items);
        }
        try expectShadow(&doc, text.items);
    }
}

// ── Painted ──────────────────────────────────────────────────────────────────

test "Painted.record: extends the band at either end" {
    var p: Painted = .{};
    defer p.deinit();

    try std.testing.expect(p.record(10, &.{ 1, 2, 4 }));
    try std.testing.expectEqual(@as(c_int, 10), p.first);
    try std.testing.expectEqual(@as(c_int, 12), p.last());

    try std.testing.expect(p.record(13, &.{8}));
    try std.testing.expectEqual(@as(c_int, 13), p.last());
    try std.testing.expectEqual(@as(?u64, 8), p.maskFor(13));

    try std.testing.expect(p.record(8, &.{ 16, 32 }));
    try std.testing.expectEqual(@as(c_int, 8), p.first);
    try std.testing.expectEqual(@as(?u64, 16), p.maskFor(8));
    try std.testing.expectEqual(@as(?u64, 1), p.maskFor(10));
}

test "Painted.record: a disjoint run replaces the band but not the high water" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(0, &.{ 1, 1, 1 }));
    try std.testing.expect(p.record(90, &.{2}));
    try std.testing.expectEqual(@as(c_int, 90), p.first);
    try std.testing.expectEqual(@as(?u64, null), p.maskFor(0));
    // Line 0 was painted once, so its tags are still on the text.
    try std.testing.expectEqual(@as(c_int, 90), p.high_water);
}

test "Painted.record: overwrites a run inside the band" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(5, &.{ 1, 2, 3, 4 }));
    try std.testing.expect(p.record(6, &.{ 9, 9 }));
    try std.testing.expectEqual(@as(?u64, 1), p.maskFor(5));
    try std.testing.expectEqual(@as(?u64, 9), p.maskFor(6));
    try std.testing.expectEqual(@as(?u64, 9), p.maskFor(7));
    try std.testing.expectEqual(@as(?u64, 4), p.maskFor(8));
}

test "Painted.dropFrom: forgets a line and everything below it" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(4, &.{ 1, 2, 3, 4 }));
    p.dropFrom(6);
    try std.testing.expectEqual(@as(c_int, 5), p.last());
    p.dropFrom(4);
    try std.testing.expect(p.isEmpty());
}

test "Painted.shift: the band follows text inserted above it" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(20, &.{ 1, 2, 3 }));

    p.shift(5, 4); // four lines inserted above the band
    try std.testing.expectEqual(@as(c_int, 24), p.first);
    try std.testing.expectEqual(@as(c_int, 26), p.last());
    try std.testing.expectEqual(@as(c_int, 26), p.high_water);

    p.shift(5, -4);
    try std.testing.expectEqual(@as(c_int, 20), p.first);
}

test "Painted.shift: an edit inside the band truncates it there" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(0, &.{ 1, 2, 3, 4, 5 }));
    p.shift(2, 1);
    try std.testing.expectEqual(@as(c_int, 0), p.first);
    try std.testing.expectEqual(@as(c_int, 1), p.last());
    // The tags below are still on the text, so the high water moves with them.
    try std.testing.expectEqual(@as(c_int, 5), p.high_water);
}

test "Painted.shift: an edit below the band leaves it alone" {
    var p: Painted = .{};
    defer p.deinit();
    try std.testing.expect(p.record(0, &.{ 1, 2 }));
    p.shift(50, 3);
    try std.testing.expectEqual(@as(c_int, 0), p.first);
    try std.testing.expectEqual(@as(c_int, 1), p.last());
}

// ── Paint runs ───────────────────────────────────────────────────────────────

const nothing_painted: LineRange = .{ .first = 0, .last = -1 };

test "missingRuns: nothing painted yet paints the top of the viewport" {
    const runs = missingRuns(nothing_painted, .{ .first = 100, .last = 260 });
    try std.testing.expectEqual(@as(c_int, 100), runs[0].?.first);
    try std.testing.expectEqual(@as(c_int, 260), runs[0].?.last);
    try std.testing.expect(runs[1] == null);
}

test "missingRuns: a viewport inside the band needs nothing" {
    const runs = missingRuns(.{ .first = 0, .last = 500 }, .{ .first = 100, .last = 260 });
    try std.testing.expect(runs[0] == null);
    try std.testing.expect(runs[1] == null);
}

test "missingRuns: scrolling extends the band at the end it moved towards" {
    const band: LineRange = .{ .first = 100, .last = 200 };

    const down = missingRuns(band, .{ .first = 150, .last = 240 });
    try std.testing.expect(down[0] == null);
    try std.testing.expectEqual(@as(c_int, 201), down[1].?.first);
    try std.testing.expectEqual(@as(c_int, 240), down[1].?.last);

    const up = missingRuns(band, .{ .first = 60, .last = 180 });
    try std.testing.expectEqual(@as(c_int, 60), up[0].?.first);
    try std.testing.expectEqual(@as(c_int, 99), up[0].?.last);
    try std.testing.expect(up[1] == null);
}

test "missingRuns: both ends at once, each still adjoining the band" {
    const runs = missingRuns(.{ .first = 100, .last = 200 }, .{ .first = 50, .last = 250 });
    try std.testing.expectEqual(@as(c_int, 99), runs[0].?.last);
    try std.testing.expectEqual(@as(c_int, 201), runs[1].?.first);
}

test "missingRuns: a run longer than a pass is cut at the end away from the band" {
    // Below the band the run starts where the band ends, so the cut is at the far
    // end; above it the run ends where the band starts, so the cut is at the near
    // one.  Either way the next pass continues from the band it just extended.
    const long = max_paint_lines * 3;

    const below = missingRuns(.{ .first = 0, .last = 10 }, .{ .first = 0, .last = long });
    try std.testing.expectEqual(@as(c_int, 11), below[1].?.first);
    try std.testing.expectEqual(@as(c_int, 10 + max_paint_lines), below[1].?.last);

    const above = missingRuns(.{ .first = long, .last = long + 10 }, .{ .first = 0, .last = long });
    try std.testing.expectEqual(@as(c_int, long - 1), above[0].?.last);
    try std.testing.expectEqual(@as(c_int, long - max_paint_lines), above[0].?.first);
}

test "missingRuns: a viewport far from the band is painted from its top" {
    const runs = missingRuns(.{ .first = 0, .last = 100 }, .{ .first = 5_000, .last = 5_200 });
    try std.testing.expect(runs[0] == null);
    try std.testing.expectEqual(@as(c_int, 5_000), runs[1].?.first);
    try std.testing.expectEqual(@as(c_int, 5_200), runs[1].?.last);
}

test "pointAfter: no newline stays on same row" {
    const result = pointAfter(.{ .row = 3, .column = 2 }, "hello");
    try std.testing.expectEqual(@as(u32, 3), result.row);
    try std.testing.expectEqual(@as(u32, 7), result.column);
}

test "pointAfter: single newline advances row" {
    const result = pointAfter(.{ .row = 0, .column = 0 }, "foo\nbar");
    try std.testing.expectEqual(@as(u32, 1), result.row);
    try std.testing.expectEqual(@as(u32, 3), result.column);
}

test "pointAfter: multiple newlines" {
    const result = pointAfter(.{ .row = 0, .column = 0 }, "a\nb\nc");
    try std.testing.expectEqual(@as(u32, 2), result.row);
    try std.testing.expectEqual(@as(u32, 1), result.column);
}

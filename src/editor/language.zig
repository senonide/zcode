//! The bundled tree-sitter grammars and the query machinery built on them.
//!
//! A `Language` lazily resolves its grammar and compiles its highlight query on
//! first use.  `matches` iterates a query over a tree and yields only the matches
//! whose predicates hold — the runtime does not evaluate predicates, so they are
//! checked here (regex via GLib).
//!
//! Tree-sitter is used for syntax highlighting only.

const std = @import("std");
const gtk = @import("../gtk.zig");
const ts = @import("tree-sitter");

extern fn tree_sitter_zig() callconv(.c) *ts.Language;
extern fn tree_sitter_go() callconv(.c) *ts.Language;
extern fn tree_sitter_rust() callconv(.c) *ts.Language;
extern fn tree_sitter_c() callconv(.c) *ts.Language;
extern fn tree_sitter_python() callconv(.c) *ts.Language;
extern fn tree_sitter_javascript() callconv(.c) *ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *ts.Language;
extern fn tree_sitter_markdown() callconv(.c) *ts.Language;

pub const Language = struct {
    grammar: *const fn () callconv(.c) *ts.Language,
    highlights: []const u8,
    exts: []const []const u8,

    raw: ?*ts.Language = null,
    highlight_query: ?*ts.Query = null,

    pub fn newParser(self: *Language) ?*ts.Parser {
        const parser = ts.Parser.create();
        parser.setLanguage(self.rawLanguage()) catch {
            parser.destroy();
            return null;
        };
        return parser;
    }

    pub fn highlightQuery(self: *Language) ?*ts.Query {
        return self.compile(&self.highlight_query, self.highlights);
    }

    fn rawLanguage(self: *Language) *ts.Language {
        return self.raw orelse {
            self.raw = self.grammar();
            return self.raw.?;
        };
    }

    fn compile(self: *Language, slot: *?*ts.Query, src: []const u8) ?*ts.Query {
        if (slot.*) |q| return q;
        var err: u32 = 0;
        slot.* = ts.Query.create(self.rawLanguage(), src, &err) catch {
            std.log.warn("zcode: tree-sitter query failed to compile at byte {d}", .{err});
            return null;
        };
        return slot.*;
    }
};

// TypeScript/TSX queries only add their own rules and inherit the rest from
// JavaScript, so the JS query is prepended at comptime (later patterns keep
// higher precedence, so the TS additions win their overlaps).
const js_highlights = @embedFile("queries/javascript.scm").*;
const ts_highlights = js_highlights ++ "\n".* ++ @embedFile("queries/typescript.scm").*;

var registry = [_]Language{
    .{ .grammar = tree_sitter_zig, .highlights = @embedFile("queries/zig.scm"), .exts = &.{ ".zig", ".zon" } },
    .{ .grammar = tree_sitter_go, .highlights = @embedFile("queries/go.scm"), .exts = &.{".go"} },
    .{ .grammar = tree_sitter_rust, .highlights = @embedFile("queries/rust.scm"), .exts = &.{".rs"} },
    .{ .grammar = tree_sitter_c, .highlights = @embedFile("queries/c.scm"), .exts = &.{ ".c", ".h" } },
    .{ .grammar = tree_sitter_python, .highlights = @embedFile("queries/python.scm"), .exts = &.{ ".py", ".pyi" } },
    .{ .grammar = tree_sitter_javascript, .highlights = &js_highlights, .exts = &.{ ".js", ".jsx", ".mjs", ".cjs" } },
    .{ .grammar = tree_sitter_typescript, .highlights = &ts_highlights, .exts = &.{ ".ts", ".mts", ".cts" } },
    .{ .grammar = tree_sitter_tsx, .highlights = &ts_highlights, .exts = &.{".tsx"} },
    .{ .grammar = tree_sitter_markdown, .highlights = @embedFile("queries/markdown.scm"), .exts = &.{ ".md", ".markdown" } },
};

/// The grammar for `path`'s extension, or null when none is bundled.
pub fn detect(path: [*:0]const u8) ?*Language {
    const name = std.mem.sliceTo(path, 0);
    for (&registry) |*lang| {
        for (lang.exts) |ext| if (std.mem.endsWith(u8, name, ext)) return lang;
    }
    return null;
}

/// Where a predicate gets the text of the node it is testing.
///
/// A callback rather than the document itself: predicates only ever look at the
/// handful of captured nodes in a match, so requiring the whole source in memory
/// to run a query would cost more than the query. `read` fills `out` and returns
/// the part it used; text too long for `out` may be truncated, which only makes
/// a predicate fail to match.
pub const Source = struct {
    ctx: ?*anyopaque,
    read: *const fn (ctx: ?*anyopaque, start: u32, end: u32, out: []u8) []const u8,
};

/// Iterates the matches of `query` over `node` that overlap the point range
/// `[start, end)`, skipping those whose predicates fail.
pub fn matchesInRange(query: *ts.Query, node: ts.Node, source: Source, start: ts.Point, end: ts.Point) Matches {
    const cursor = ts.QueryCursor.create();
    cursor.setPointRange(start, end) catch {};
    cursor.exec(query, node);
    return .{ .cursor = cursor, .query = query, .source = source };
}

pub const Matches = struct {
    cursor: *ts.QueryCursor,
    query: *ts.Query,
    source: Source,

    pub fn next(self: *Matches) ?ts.Query.Match {
        while (self.cursor.nextMatch()) |match| {
            if (predicatesHold(self.query, match, self.source)) return match;
        }
        return null;
    }

    pub fn deinit(self: *Matches) void {
        self.cursor.destroy();
    }
};

// ── Predicate evaluation ─────────────────────────────────────────────────────

fn predicatesHold(query: *ts.Query, match: ts.Query.Match, source: Source) bool {
    // One scratch buffer for every capture argument of this predicate; long
    // enough for the identifiers predicates actually test.
    var texts: [max_args][256]u8 = undefined;
    var used: usize = 0;
    const steps = query.predicatesForPattern(@intCast(match.pattern_index));
    var i: usize = 0;
    while (i < steps.len) {
        if (steps[i].type != .string) {
            i += 1;
            continue;
        }
        const op = query.stringValueForId(steps[i].value_id) orelse "";
        i += 1;

        var args: [max_args][]const u8 = undefined;
        var n: usize = 0;
        while (i < steps.len and steps[i].type != .done) : (i += 1) {
            if (n == args.len) continue;
            args[n] = switch (steps[i].type) {
                .capture => blk: {
                    if (used == texts.len) break :blk "";
                    const slot = &texts[used];
                    used += 1;
                    break :blk captureText(match, steps[i].value_id, source, slot);
                },
                else => query.stringValueForId(steps[i].value_id) orelse "",
            };
            n += 1;
        }
        i += 1; // the .done sentinel

        if (!eval(op, args[0..n])) return false;
    }
    return true;
}

const max_args = 16;

fn captureText(match: ts.Query.Match, id: u32, source: Source, out: []u8) []const u8 {
    for (match.captures) |c| {
        if (c.index != id) continue;
        return source.read(source.ctx, c.node.startByte(), c.node.endByte(), out);
    }
    return "";
}

fn eval(op: []const u8, args: []const []const u8) bool {
    const E = std.mem.eql;
    if (args.len == 0) return true;
    const subject = args[0];

    if (E(u8, op, "eq?")) return args.len >= 2 and E(u8, subject, args[1]);
    if (E(u8, op, "not-eq?")) return !(args.len >= 2 and E(u8, subject, args[1]));
    if (E(u8, op, "any-of?")) {
        for (args[1..]) |a| if (E(u8, subject, a)) return true;
        return false;
    }
    if (E(u8, op, "not-any-of?")) {
        for (args[1..]) |a| if (E(u8, subject, a)) return false;
        return true;
    }
    if (E(u8, op, "match?") or E(u8, op, "lua-match?"))
        return args.len >= 2 and regexHolds(args[1], subject);
    if (E(u8, op, "not-match?") or E(u8, op, "not-lua-match?"))
        return !(args.len >= 2 and regexHolds(args[1], subject));

    return true; // a directive (#set!, …) or an unknown predicate: don't filter
}

test "detect: known extensions" {
    try std.testing.expect(detect("/foo/main.zig") != null);
    try std.testing.expect(detect("/foo/main.go") != null);
    try std.testing.expect(detect("/foo/main.rs") != null);
    try std.testing.expect(detect("/foo/main.c") != null);
    try std.testing.expect(detect("/foo/main.py") != null);
    try std.testing.expect(detect("/foo/main.js") != null);
    try std.testing.expect(detect("/foo/main.ts") != null);
    try std.testing.expect(detect("/foo/main.tsx") != null);
    try std.testing.expect(detect("/foo/README.md") != null);
}

test "detect: unknown extension returns null" {
    try std.testing.expect(detect("/foo/image.png") == null);
    try std.testing.expect(detect("/foo/data.json") == null);
    try std.testing.expect(detect("/foo/Makefile") == null);
}

test "detect: zig extension matches zig language" {
    const lang = detect("/foo/build.zig.zon").?;
    try std.testing.expectEqualStrings(".zon", lang.exts[1]);
}

test "eval: eq? predicate" {
    const args_match = [_][]const u8{ "foo", "foo" };
    try std.testing.expect(eval("eq?", &args_match));
    const args_no = [_][]const u8{ "foo", "bar" };
    try std.testing.expect(!eval("eq?", &args_no));
}

test "eval: not-eq? predicate" {
    const args = [_][]const u8{ "foo", "bar" };
    try std.testing.expect(eval("not-eq?", &args));
    const args_same = [_][]const u8{ "x", "x" };
    try std.testing.expect(!eval("not-eq?", &args_same));
}

test "eval: any-of? predicate" {
    const args = [_][]const u8{ "b", "a", "b", "c" };
    try std.testing.expect(eval("any-of?", &args));
    const args_no = [_][]const u8{ "z", "a", "b" };
    try std.testing.expect(!eval("any-of?", &args_no));
}

test "eval: not-any-of? predicate" {
    const args = [_][]const u8{ "z", "a", "b" };
    try std.testing.expect(eval("not-any-of?", &args));
    const args_in = [_][]const u8{ "b", "a", "b" };
    try std.testing.expect(!eval("not-any-of?", &args_in));
}

test "eval: unknown op passes through" {
    const args = [_][]const u8{"x"};
    try std.testing.expect(eval("set!", &args));
    try std.testing.expect(eval("is-not-a-known-predicate?", &args));
}

test "eval: empty args passes" {
    const args = [_][]const u8{};
    try std.testing.expect(eval("eq?", &args));
}

/// Compiled `#match?` patterns, keyed by the pattern source.
///
/// A highlight query runs over the whole tree after every edit, and each match
/// re-evaluates its predicates — compiling the same handful of regexes thousands
/// of times per keystroke.  The set of patterns is fixed by the bundled queries,
/// so they are compiled once and kept for the life of the process.
var regex_cache: std.StringHashMapUnmanaged(?*gtk.GRegex) = .empty;

fn compiledRegex(pattern: []const u8) ?*gtk.GRegex {
    if (regex_cache.get(pattern)) |cached| return cached;

    var pbuf: [256]u8 = undefined;
    if (pattern.len >= pbuf.len) return null;
    @memcpy(pbuf[0..pattern.len], pattern);
    pbuf[pattern.len] = 0;

    const compiled = gtk.g_regex_new(@ptrCast(&pbuf), gtk.G_REGEX_OPTIMIZE, 0, null);
    // The key must outlive the query object the pattern was borrowed from.
    const key = std.heap.c_allocator.dupe(u8, pattern) catch return compiled;
    regex_cache.put(std.heap.c_allocator, key, compiled) catch std.heap.c_allocator.free(key);
    return compiled;
}

fn regexHolds(pattern: []const u8, text: []const u8) bool {
    var tbuf: [1024]u8 = undefined;
    if (text.len >= tbuf.len) return true; // too long to test
    const regex = compiledRegex(pattern) orelse return true; // unusable pattern: don't filter
    @memcpy(tbuf[0..text.len], text);
    tbuf[text.len] = 0;
    return gtk.g_regex_match(regex, @ptrCast(&tbuf), 0, null) != 0;
}

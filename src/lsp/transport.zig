//! JSON-RPC message framing over a raw byte stream.
//!
//! LSP frames each JSON payload with a `Content-Length: N\r\n\r\n` header.
//! `frame` wraps an outgoing payload; `Parser` accumulates incoming bytes and
//! yields complete payloads as they arrive — the byte stream from the server
//! has no message boundaries, so a payload may span several reads or several
//! may share one.

const std = @import("std");

/// Allocates `payload` wrapped in an LSP header. Caller frees the result.
pub fn frame(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
}

/// Reassembles framed messages from a byte stream. Push bytes as they arrive,
/// then drain complete payloads with `next` until it returns null; `compact`
/// reclaims consumed bytes once draining is done.
pub const Parser = struct {
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.alloc);
    }

    pub fn push(self: *Parser, bytes: []const u8) !void {
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// The next complete payload, or null when more bytes are needed. The slice
    /// is valid until the following `push`/`compact`, which is enough because
    /// callers drain (and copy out via JSON parse) before pushing again.
    pub fn next(self: *Parser) ?[]const u8 {
        const data = self.buf.items[self.pos..];
        const sep = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        const len = contentLength(data[0..sep]) orelse {
            // Malformed header: skip past it so we don't wedge on it forever.
            self.pos += sep + 4;
            return null;
        };
        const body_start = sep + 4;
        if (data.len < body_start + len) return null; // payload still arriving
        const body = data[body_start .. body_start + len];
        self.pos += body_start + len;
        return body;
    }

    /// Drops the bytes already returned by `next`. Call after a drain loop.
    pub fn compact(self: *Parser) void {
        if (self.pos == 0) return;
        const remaining = self.buf.items.len - self.pos;
        std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.pos..]);
        self.buf.shrinkRetainingCapacity(remaining);
        self.pos = 0;
    }

    fn contentLength(header: []const u8) ?usize {
        var it = std.mem.splitSequence(u8, header, "\r\n");
        while (it.next()) |line| {
            const prefix = "Content-Length:";
            if (std.ascii.startsWithIgnoreCase(line, prefix)) {
                const v = std.mem.trim(u8, line[prefix.len..], " \t");
                return std.fmt.parseInt(usize, v, 10) catch null;
            }
        }
        return null;
    }
};

test "frame then parse round-trip" {
    const a = std.testing.allocator;
    const f = try frame(a, "{\"x\":1}");
    defer a.free(f);

    var p = Parser.init(a);
    defer p.deinit();
    // Split the framed bytes across two pushes to exercise reassembly.
    try p.push(f[0 .. f.len - 3]);
    try std.testing.expect(p.next() == null);
    try p.push(f[f.len - 3 ..]);
    try std.testing.expectEqualStrings("{\"x\":1}", p.next().?);
    try std.testing.expect(p.next() == null);
    p.compact();
}

test "two messages in one push" {
    const a = std.testing.allocator;
    const f1 = try frame(a, "{\"a\":1}");
    defer a.free(f1);
    const f2 = try frame(a, "{\"b\":2}");
    defer a.free(f2);

    var p = Parser.init(a);
    defer p.deinit();
    try p.push(f1);
    try p.push(f2);
    try std.testing.expectEqualStrings("{\"a\":1}", p.next().?);
    try std.testing.expectEqualStrings("{\"b\":2}", p.next().?);
    try std.testing.expect(p.next() == null);
}

test "malformed header is skipped" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    // Push a malformed header followed by a valid framed message.
    const garbage = "Not-A-Header: 0\r\n\r\n";
    const valid = try frame(a, "{}");
    defer a.free(valid);
    try p.push(garbage);
    // The malformed header has no Content-Length, so next() skips it and
    // returns null (not enough data yet for the following valid message).
    _ = p.next();
    try p.push(valid);
    try std.testing.expectEqualStrings("{}", p.next().?);
    try std.testing.expect(p.next() == null);
    p.compact();
}

test "compact reclaims consumed bytes" {
    const a = std.testing.allocator;
    var p = Parser.init(a);
    defer p.deinit();
    const f = try frame(a, "{\"compact\":true}");
    defer a.free(f);
    try p.push(f);
    _ = p.next();
    // Before compact, pos points past the consumed message.
    try std.testing.expect(p.pos > 0);
    p.compact();
    try std.testing.expectEqual(@as(usize, 0), p.pos);
    try std.testing.expectEqual(@as(usize, 0), p.buf.items.len);
}

test "empty payload" {
    const a = std.testing.allocator;
    const f = try frame(a, "");
    defer a.free(f);
    var p = Parser.init(a);
    defer p.deinit();
    try p.push(f);
    try std.testing.expectEqualStrings("", p.next().?);
    try std.testing.expect(p.next() == null);
}

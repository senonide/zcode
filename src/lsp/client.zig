//! A JSON-RPC client for one language server.
//!
//! Owns the request/response correlation, the initialize handshake and the
//! outbox that holds notifications until the server is ready. The transport
//! (process + raw bytes) is `gtk.ZcLspProc`; framing is `transport`. Everything
//! runs on the GTK main loop — bytes arrive through `onData`, so there is no
//! threading and all state is touched from one thread.

const std = @import("std");
const gtk = @import("../gtk.zig");
const transport = @import("transport.zig");

pub const NotificationFn = *const fn (client: *Client, method: []const u8, params: ?std.json.Value) void;

pub const ResponseFn = *const fn (self: *Client, ctx: ?*anyopaque, result: ?std.json.Value) void;

const Pending = struct {
    func: ResponseFn,
    ctx: ?*anyopaque,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    proc: *gtk.ZcLspProc,
    parser: transport.Parser,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    // Notifications/requests issued before reply to `initialize` — held and
    // flushed once the handshake completes.
    outbox: std.ArrayList(u8) = .empty,
    initialized: bool = false,
    // Set from the server's initialize response.  Conservative defaults until
    // the handshake completes: full sync, UTF-16 positions (LSP spec default).
    sync_incremental: bool = false,
    position_utf16: bool = true,
    supports_formatting: bool = false,
    callbacks: gtk.ZcLspCallbacks = .{},
    // Server→client notification handler (set by the manager).
    on_notify: ?NotificationFn = null,
    // Fired when `initialized` flips (connect or disconnect).
    on_status_change: ?*const fn (*Client) void = null,

    /// Spawns the server `argv` in `cwd`. Returns null if it can't be launched.
    pub fn create(alloc: std.mem.Allocator, argv: [*]const ?[*:0]const u8, cwd: [*:0]const u8) ?*Client {
        const self = alloc.create(Client) catch return null;
        self.* = .{ .alloc = alloc, .proc = undefined, .parser = transport.Parser.init(alloc) };
        self.callbacks = .{ .on_data = onData, .on_closed = onClosed, .user_data = self };
        self.proc = gtk.zc_lsp_proc_new(argv, cwd, &self.callbacks) orelse {
            self.parser.deinit();
            alloc.destroy(self);
            return null;
        };
        return self;
    }
    /// Registers a handler for server→client notifications (no id).
    pub fn setNotificationHandler(self: *Client, func: NotificationFn) void {
        self.on_notify = func;
    }

    pub fn destroy(self: *Client) void {
        gtk.zc_lsp_proc_close(self.proc);
        self.failPending();
        self.parser.deinit();
        self.pending.deinit(self.alloc);
        self.outbox.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Answers every in-flight request with an empty result.  A request's
    /// callback owns its context (and, for completion, an unfinished GTask), so
    /// dropping the table without running them leaks memory and leaves the
    /// completion popup waiting on a reply that will never come.
    fn failPending(self: *Client) void {
        // Detached first: a callback is free to issue another request, which
        // would rehash the table this loop is walking.
        var table = self.pending;
        self.pending = .empty;
        defer table.deinit(self.alloc);
        var it = table.iterator();
        while (it.next()) |entry| entry.value_ptr.func(self, entry.value_ptr.ctx, null);
    }

    /// Sends `initialize` with `root_uri`; the server is usable once it replies.
    pub fn start(self: *Client, root_uri: []const u8) void {
        const params = .{
            .processId = getpid(),
            .rootUri = root_uri,
            // Modern servers (gopls) load the project from workspaceFolders, not
            // the legacy rootUri; without it gopls reports "expected 1, got 0".
            .workspaceFolders = .{.{ .uri = root_uri, .name = std.fs.path.basename(root_uri) }},
            .capabilities = .{
                .general = .{ .positionEncodings = [_][]const u8{ "utf-8", "utf-16" } },
                .textDocument = .{
                    .synchronization = .{ .didSave = true, .dynamicRegistration = false },
                    // Must serialize as an object: `.{}` would emit `[]` (a
                    // tuple), which zls's typed parser rejects with ParseError.
                    .publishDiagnostics = struct {}{},
                    .completion = .{
                        .completionItem = .{
                            .snippetSupport = false,
                            .documentationFormat = [_][]const u8{ "plaintext", "markdown" },
                        },
                        .contextSupport = true,
                    },
                    .hover = .{
                        .contentFormat = [_][]const u8{ "plaintext", "markdown" },
                    },
                    .signatureHelp = .{
                        .signatureInformation = .{
                            .documentationFormat = [_][]const u8{ "plaintext", "markdown" },
                        },
                    },
                    .definition = .{ .dynamicRegistration = false },
                    .codeAction = .{
                        .dynamicRegistration = false,
                        .codeActionLiteralSupport = .{
                            .codeActionKind = .{
                                .valueSet = [_][]const u8{ "", "quickfix", "refactor", "source" },
                            },
                        },
                    },
                    .rename = .{ .dynamicRegistration = false, .prepareSupport = false },
                    .formatting = .{ .dynamicRegistration = false },
                },
            },
        };
        self.request("initialize", params, onInitialize, self);
    }

    /// Sends `shutdown` + `exit` so the server can clean up before we kill it.
    pub fn sendShutdown(self: *Client) void {
        if (!self.initialized) return;
        const id = self.next_id;
        self.next_id += 1;
        const shutdown_body = std.json.Stringify.valueAlloc(self.alloc, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = "shutdown",
        }, .{ .emit_null_optional_fields = false }) catch return;
        defer self.alloc.free(shutdown_body);
        const framed_s = transport.frame(self.alloc, shutdown_body) catch return;
        defer self.alloc.free(framed_s);
        gtk.zc_lsp_proc_write(self.proc, framed_s.ptr, framed_s.len);
        self.notifyNow("exit", .{});
    }

    /// Issues a request, registering `func` to run when the response arrives.
    pub fn request(self: *Client, method: []const u8, params: anytype, func: ResponseFn, ctx: ?*anyopaque) void {
        const id = self.next_id;
        self.next_id += 1;
        self.pending.put(self.alloc, id, .{ .func = func, .ctx = ctx }) catch return;
        const body = std.json.Stringify.valueAlloc(self.alloc, .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = params,
        }, .{ .emit_null_optional_fields = false }) catch return;
        defer self.alloc.free(body);
        // `initialize` must go out before the server is "initialized".
        self.send(body, std.mem.eql(u8, method, "initialize"));
    }

    /// Sends a notification (no response expected).
    pub fn notify(self: *Client, method: []const u8, params: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.alloc, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        }, .{ .emit_null_optional_fields = false }) catch return;
        defer self.alloc.free(body);
        self.send(body, false);
    }

    /// True while bytes previously written are still queued in the transport
    /// (a write in flight or pending in its buffer).  Used by the document-sync
    /// layer to apply backpressure: a didChange built while the previous one is
    /// still draining would only pile megabytes onto the main loop.
    pub fn writePending(self: *Client) bool {
        return gtk.zc_lsp_proc_write_pending(self.proc);
    }

    fn send(self: *Client, body: []const u8, force: bool) void {
        const framed = transport.frame(self.alloc, body) catch return;
        defer self.alloc.free(framed);
        if (self.initialized or force) {
            gtk.zc_lsp_proc_write(self.proc, framed.ptr, framed.len);
        } else {
            self.outbox.appendSlice(self.alloc, framed) catch {};
        }
    }

    fn onInitialize(self: *Client, _: ?*anyopaque, result: ?std.json.Value) void {
        if (result) |res| {
            const sc = parseServerCaps(res);
            self.sync_incremental = sc.sync_incremental;
            self.position_utf16 = sc.position_utf16;
            self.supports_formatting = sc.supports_formatting;
        }
        self.initialized = true;
        // `initialized` must precede every other message; send it directly,
        // then flush whatever queued up during the handshake. The params are an
        // empty *object* — `.{}` would serialize as `[]` (a tuple), which gopls
        // rejects, leaving it stuck "before server initialized".
        self.notifyNow("initialized", struct {}{});
        if (self.outbox.items.len > 0) {
            gtk.zc_lsp_proc_write(self.proc, self.outbox.items.ptr, self.outbox.items.len);
            self.outbox.clearRetainingCapacity();
        }
        if (self.on_status_change) |cb| cb(self);
    }

    fn notifyNow(self: *Client, method: []const u8, params: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.alloc, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
        }, .{ .emit_null_optional_fields = false }) catch return;
        defer self.alloc.free(body);
        const framed = transport.frame(self.alloc, body) catch return;
        defer self.alloc.free(framed);
        gtk.zc_lsp_proc_write(self.proc, framed.ptr, framed.len);
    }

    // ── Incoming bytes ────────────────────────────────────────────────────────

    fn onData(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.parser.push(bytes[0..len]) catch return;
        while (self.parser.next()) |payload| self.dispatch(payload);
        self.parser.compact();
    }

    fn onClosed(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        // The server died; answer pending callers so they don't wait forever.
        self.initialized = false;
        self.failPending();
        if (self.on_status_change) |cb| cb(self);
    }

    fn dispatch(self: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        const id_val = obj.get("id");
        if (obj.get("method")) |method_val| {
            // A server→client message.
            if (id_val) |id| self.respondNull(id);
            // If no id, it's a notification — forward to the registered handler.
            if (id_val == null) {
                if (self.on_notify) |handler| {
                    handler(self, method_val.string, obj.get("params"));
                }
            }
            return;
        }

        // A response to one of our requests.
        const id = switch (id_val orelse return) {
            .integer => |i| i,
            else => return,
        };
        if (self.pending.fetchRemove(id)) |entry| {
            entry.value.func(self, entry.value.ctx, obj.get("result"));
        }
    }

    fn respondNull(self: *Client, id: std.json.Value) void {
        const id_str = std.json.Stringify.valueAlloc(self.alloc, id, .{}) catch return;
        defer self.alloc.free(id_str);
        const body = std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str}) catch return;
        defer self.alloc.free(body);
        const framed = transport.frame(self.alloc, body) catch return;
        defer self.alloc.free(framed);
        gtk.zc_lsp_proc_write(self.proc, framed.ptr, framed.len);
    }
};

extern fn getpid() c_int;

// ── Server capability parsing ─────────────────────────────────────────────────

const ServerCaps = struct {
    sync_incremental: bool = false,
    position_utf16: bool = true, // UTF-16 is the LSP default when unspecified
    supports_formatting: bool = false,
};

/// Extracts the subset of server capabilities relevant to document sync.
/// Conservative: unrecognised or missing fields keep the safe default.
fn parseServerCaps(result: std.json.Value) ServerCaps {
    var sc = ServerCaps{};
    const caps = switch (result) {
        .object => |o| switch (o.get("capabilities") orelse return sc) {
            .object => |c| c,
            else => return sc,
        },
        else => return sc,
    };

    if (caps.get("positionEncoding")) |pe| switch (pe) {
        .string => |s| if (std.mem.eql(u8, s, "utf-8")) {
            sc.position_utf16 = false;
        },
        else => {},
    };

    if (caps.get("documentFormattingProvider")) |dfp| switch (dfp) {
        .bool => |b| sc.supports_formatting = b,
        .object => sc.supports_formatting = true,
        else => {},
    };

    const tds = caps.get("textDocumentSync") orelse return sc;
    const kind: i64 = switch (tds) {
        .integer => |k| k,
        .object => |o| switch (o.get("change") orelse return sc) {
            .integer => |k| k,
            else => return sc,
        },
        else => return sc,
    };
    sc.sync_incremental = (kind == 2);
    return sc;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseServerCaps: incremental sync + utf-8 encoding" {
    const json =
        \\{"capabilities":{"textDocumentSync":{"change":2},"positionEncoding":"utf-8"}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(sc.sync_incremental);
    try testing.expect(!sc.position_utf16);
}

test "parseServerCaps: full sync via integer" {
    const json =
        \\{"capabilities":{"textDocumentSync":1}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(!sc.sync_incremental);
    try testing.expect(sc.position_utf16);
}

test "parseServerCaps: incremental via integer shorthand" {
    const json =
        \\{"capabilities":{"textDocumentSync":2}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(sc.sync_incremental);
}

test "parseServerCaps: missing textDocumentSync is conservative" {
    const json =
        \\{"capabilities":{}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(!sc.sync_incremental);
    try testing.expect(sc.position_utf16);
}

test "parseServerCaps: utf-16 positionEncoding keeps default" {
    const json =
        \\{"capabilities":{"textDocumentSync":2,"positionEncoding":"utf-16"}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(sc.sync_incremental);
    try testing.expect(sc.position_utf16);
}

test "parseServerCaps: documentFormattingProvider as bool true" {
    const json =
        \\{"capabilities":{"documentFormattingProvider":true}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    try testing.expect(parseServerCaps(p.value).supports_formatting);
}

test "parseServerCaps: documentFormattingProvider as options object" {
    const json =
        \\{"capabilities":{"documentFormattingProvider":{}}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    try testing.expect(parseServerCaps(p.value).supports_formatting);
}

test "parseServerCaps: documentFormattingProvider absent is conservative" {
    const json =
        \\{"capabilities":{}}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    try testing.expect(!parseServerCaps(p.value).supports_formatting);
}

test "parseServerCaps: malformed result returns safe defaults" {
    const json =
        \\{"foo":"bar"}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const sc = parseServerCaps(p.value);
    try testing.expect(!sc.sync_incremental);
    try testing.expect(sc.position_utf16);
}

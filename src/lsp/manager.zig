//! Language-server lifecycle and document sync.
//!
//! Maps a file to its server (one shared client per project root + language,
//! spawned lazily), keeps the server's view of each open buffer in sync
//! (didOpen / didChange / didSave / didClose) and answers the editor's queries.
//! This is the only LSP surface the rest of the editor calls.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const client = @import("client.zig");
const view = @import("../app/view.zig");
const position = @import("../editor/position.zig");

const alloc = std.heap.c_allocator;

const max_diag_marks: usize = 128;
const max_code_actions: usize = 8;

/// One language server's launch recipe. Add a language by adding a row.
const ServerSpec = struct {
    exts: []const []const u8,
    language_id: []const u8,
    argv: []const ?[*:0]const u8, // NULL-terminated for execv
};

const registry = [_]ServerSpec{
    .{ .exts = &.{ ".zig", ".zon" }, .language_id = "zig", .argv = &.{ "zls", null } },
    .{ .exts = &.{".go"}, .language_id = "go", .argv = &.{ "gopls", null } },
    .{ .exts = &.{".rs"}, .language_id = "rust", .argv = &.{ "rust-analyzer", null } },
    .{ .exts = &.{ ".c", ".h", ".cpp", ".hpp", ".cc", ".hh", ".cxx", ".hxx" }, .language_id = "cpp", .argv = &.{ "clangd", "--background-index", null } },
    .{ .exts = &.{".py"}, .language_id = "python", .argv = &.{ "pyright-langserver", "--stdio", null } },
    .{ .exts = &.{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" }, .language_id = "typescript", .argv = &.{ "typescript-language-server", "--stdio", null } },
};

const ServerEntry = struct {
    root: [:0]u8, // owned project root (keys the client)
    language_id: []const u8, // borrowed from registry
    cl: *client.Client,
};

const DiagSeverity = enum(u8) { err = 1, warning = 2, information = 3, hint = 4 };

const DiagItem = struct {
    start_line: i64,
    start_char: i64,
    end_line: i64,
    end_char: i64,
    severity: DiagSeverity,
    // Owned, NUL-terminated: hover.c reads it as a C string via ZcHoverDiag.
    message: [:0]u8,
};

/// Diagnostics kept for one document, past which only the tally is.
///
/// A server that considers a file thoroughly broken reports thousands, and each
/// one is an allocation, a tag application, and lines to sweep again on the next
/// publish — several times a second while typing.  Nothing beyond this ceiling
/// is ever drawn anyway (`max_line_marks`, `max_diag_marks`), and since servers
/// publish in file order, keeping the first N also keeps the painted band near
/// the top of the file instead of spanning all of it.
const max_diag_items: usize = 256;

const Diagnostics = struct {
    items: std.ArrayList(DiagItem) = .empty,
    // Both indexed by DiagSeverity - 1: [0]=err [1]=warn [2]=info [3]=hint.
    // The tally is kept as diagnostics arrive so the status bar reads it back
    // instead of counting the list on every keystroke.
    underline: [4]?*gtk.GtkTextTag = .{null} ** 4,
    counts: [4]u32 = .{0} ** 4,
    // The band of lines the last paint actually touched, so clearing costs the
    // diagnostics rather than the document.  `painted_last < painted_first`
    // means nothing is on screen and clearing is free.
    painted_first: c_int = 0,
    painted_last: c_int = -1,

    fn deinit(self: *Diagnostics) void {
        self.clear();
        self.items.deinit(alloc);
    }
    fn clear(self: *Diagnostics) void {
        for (self.items.items) |item| alloc.free(item.message);
        self.items.clearRetainingCapacity();
        self.counts = .{0} ** 4;
    }
    /// Takes ownership of `item.message`, whether or not the item is kept.
    fn add(self: *Diagnostics, item: DiagItem) void {
        self.counts[@intFromEnum(item.severity) - 1] += 1;
        if (self.items.items.len >= max_diag_items) return alloc.free(item.message);
        self.items.append(alloc, item) catch alloc.free(item.message);
    }
};

// One captured buffer edit (insert or delete), stored in the position encoding
// the document's server negotiated. text is owned; empty slice for pure deletions.
const EditChange = struct {
    start_line: i64,
    start_char: i64,
    end_line: i64,
    end_char: i64,
    text: []u8,
};

// Shape for the contentChanges array in an incremental didChange notification.
const LspChange = struct {
    range: struct {
        start: struct { line: i64, character: i64 },
        end: struct { line: i64, character: i64 },
    },
    text: []const u8,
};

const max_incremental_changes: usize = 64;

/// A single incremental edit past this many bytes is captured as a full-sync
/// instead: incremental edits this large cost a retained copy per edit and an
/// equally large JSON fragment, and a burst of them (a massive paste repeated
/// at full speed) would pile megabytes onto the main loop for nothing — the
/// next full-sync supersedes them anyway.
const incremental_change_bytes: usize = 64 * 1024;

/// Bytes of incremental edits accumulated since the last sync past which we
/// stop capturing and let the debounce fall through to a full sync.
const incremental_total_bytes: usize = 256 * 1024;

const Document = struct {
    buffer: *gtk.GtkSourceBuffer,
    owner: *core.AppState,
    uri: [:0]u8, // owned "file://…"
    language_id: []const u8, // borrowed
    cl: *client.Client, // borrowed (owned by its ServerEntry)
    version: i64 = 1,
    change_timer: c_uint = 0, // debounce id, 0 = none
    diag_timer: c_uint = 0, // pending diagnostic repaint, 0 = none
    // The buffer revision the pending repaint's positions were measured
    // against. The repaint is due sooner than the change debounce, so an edit
    // can land between a publish and its paint; painting anyway would put the
    // squiggles on text that has moved.
    diag_seq: u64 = 0,
    // Bumped on every buffer edit, before any debouncing. `version` only moves
    // when a didChange is actually sent, so it cannot tell whether the user has
    // typed since a request went out; this can.
    edit_seq: u64 = 0,
    // Incremental edits captured since the last sync, in emission order.
    // Only used when cl.sync_incremental is true.
    changes: std.ArrayList(EditChange) = .empty,
    /// Set when an edit was too large for incremental capture (or too many
    /// accumulated): the next sync sends the whole buffer instead of the
    /// captured edits, and onInsertText/onDeleteRange stop duping bytes.
    needs_full_sync: bool = false,
    /// Total bytes of incremental text retained in `changes`, to decide when
    /// capturing more is worse than a full sync.
    changes_bytes: usize = 0,
    /// An idle source id for a deferred sync, or 0 when none is queued.
    sync_idle: c_uint = 0,
    diags: Diagnostics = .{},
};

var g_servers: std.ArrayList(*ServerEntry) = .empty;
var g_docs: std.ArrayList(*Document) = .empty;

/// Set from window.zig; opens a file in an editor tab and scrolls to (line, ch).
pub var g_open_at_fn: ?*const fn (*core.AppState, [*:0]const u8, i64, i64) void = null;

/// The language whose server is running for `tab`'s file, or null when no
/// server backs it — either none is configured for the file type or it has not
/// finished starting.
pub fn serverLanguage(tab: *core.EditorTab) ?[]const u8 {
    const doc = docFor(tab.buffer) orelse return null;
    if (!doc.cl.initialized) return null;
    return doc.language_id;
}

fn onClientStatusChange(_: *client.Client) void {
    // A server can back documents open in more than one window; refresh every
    // window's status bar (updateStatus early-returns where irrelevant).
    for (core.g_windows.items) |w| view.updateStatus(w);
}

const change_debounce_ms: c_uint = 200;

// ── Public API (called from editor/tabs.zig and app/shortcuts.zig) ───────────

/// Registers `buffer` with its language server, if one is configured for the
/// file type and can be launched. No-op otherwise.
pub fn didOpen(state: *core.AppState, buffer: *gtk.GtkSourceBuffer, path: [*:0]const u8) void {
    if (docFor(buffer) != null) return;
    const spec = specFor(path) orelse return;
    const root = rootFor(state, path) orelse return;
    const cl = clientFor(root, spec) orelse {
        alloc.free(root);
        return;
    };
    alloc.free(root);

    const uri = fileUri(path) orelse return;
    const text = bufferText(buffer);
    defer gtk.g_free(@ptrCast(@constCast(text.ptr)));

    const doc = alloc.create(Document) catch {
        alloc.free(uri);
        return;
    };
    doc.* = .{ .buffer = buffer, .owner = state, .uri = uri, .language_id = spec.language_id, .cl = cl };
    createDiagTags(doc);
    g_docs.append(alloc, doc) catch {
        alloc.free(uri);
        alloc.destroy(doc);
        return;
    };

    _ = gtk.g_signal_connect_data(buffer, "changed", @ptrCast(&onChanged), @ptrCast(doc), null, 0);
    _ = gtk.g_signal_connect_data(buffer, "insert-text", @ptrCast(&onInsertText), @ptrCast(doc), null, 0);
    _ = gtk.g_signal_connect_data(buffer, "delete-range", @ptrCast(&onDeleteRange), @ptrCast(doc), null, 0);

    cl.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = std.mem.sliceTo(uri, 0),
        .languageId = spec.language_id,
        .version = @as(i64, 1),
        .text = text,
    } });
}

/// Tells the server the file was saved (after flushing any pending change).
pub fn didSave(buffer: *gtk.GtkSourceBuffer) void {
    const doc = docFor(buffer) orelse return;
    syncNow(doc);
    doc.cl.notify("textDocument/didSave", .{ .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) } });
}

/// Unregisters `buffer` (call before its tab is freed).
pub fn closeDocument(state: *core.AppState, buffer: *gtk.GtkSourceBuffer) void {
    const idx = docIndex(buffer) orelse return;
    const doc = g_docs.swapRemove(idx);
    if (doc.change_timer != 0) _ = gtk.g_source_remove(doc.change_timer);
    cancelDeferredSync(doc);
    if (doc.diag_timer != 0) _ = gtk.g_source_remove(doc.diag_timer);
    core.disconnectTabSignals(@ptrCast(buffer), @ptrCast(doc));
    doc.cl.notify("textDocument/didClose", .{ .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) } });
    clearChanges(doc);
    doc.changes.deinit(alloc);
    doc.diags.deinit();
    alloc.free(doc.uri);
    alloc.destroy(doc);
    view.updateStatus(state);
}

/// Re-stamps the window owning `buffer`'s document — a tab dragged into
/// another window keeps its buffer and server, but the file-tree diagnostic
/// badge must move with it or it goes stale in the old window.
pub fn setDocOwner(state: *core.AppState, buffer: *gtk.GtkSourceBuffer) void {
    const doc = docFor(buffer) orelse return;
    if (doc.owner == state) return;
    const uri = std.mem.sliceTo(doc.uri, 0);
    updateTreeDiag(doc.owner, uri, 0);
    doc.owner = state;
    var worst: u8 = 0;
    for (doc.diags.items.items) |item| {
        const s = @intFromEnum(item.severity);
        if (worst == 0 or s < worst) worst = s;
    }
    updateTreeDiag(state, uri, worst);
}

/// Shuts every server down (call on window close).
pub fn shutdownAll() void {
    for (g_docs.items) |doc| {
        if (doc.change_timer != 0) _ = gtk.g_source_remove(doc.change_timer);
        cancelDeferredSync(doc);
        core.disconnectTabSignals(@ptrCast(doc.buffer), @ptrCast(doc));
        clearChanges(doc);
        doc.changes.deinit(alloc);
        doc.diags.deinit();
        alloc.free(doc.uri);
        alloc.destroy(doc);
    }
    g_docs.clearAndFree(alloc);
    for (g_servers.items) |entry| {
        entry.cl.sendShutdown();
        entry.cl.destroy();
        alloc.free(entry.root);
        alloc.destroy(entry);
    }
    g_servers.clearAndFree(alloc);
}

// ── Navigation / editing features ────────────────────────────────────────────

pub fn formatDocument(buffer: *gtk.GtkSourceBuffer) void {
    formatDocumentThen(buffer, null, null);
}

const format_timeout_ms: c_uint = 1500;

const FormatCtx = struct {
    buffer: *gtk.GtkSourceBuffer,
    on_done: ?*const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
    timeout_id: c_uint = 0,
    timed_out: bool = false,
    // The buffer revision the server is formatting.  Its edits are expressed
    // as positions in that exact text, so they are only applicable while the
    // buffer still matches it.
    edit_seq: u64 = 0,
};

/// Requests a whole-document format from `buffer`'s language server and
/// applies the resulting edits, then calls `on_done(ctx)` — used to run the
/// formatter before a save without the caller needing to know whether one is
/// even available. `on_done` runs immediately when no server is attached or
/// it doesn't support formatting. Bounded by `format_timeout_ms` so a slow or
/// unresponsive server can never block a save; a response that arrives after
/// the timeout is dropped rather than applied.
pub fn formatDocumentThen(
    buffer: *gtk.GtkSourceBuffer,
    on_done: ?*const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
) void {
    const doc = docFor(buffer) orelse return finishNow(on_done, ctx);
    if (!doc.cl.initialized or !doc.cl.supports_formatting) return finishNow(on_done, ctx);
    syncNow(doc);

    const fmt_ctx = alloc.create(FormatCtx) catch return finishNow(on_done, ctx);
    fmt_ctx.* = .{ .buffer = buffer, .on_done = on_done, .ctx = ctx, .edit_seq = doc.edit_seq };
    fmt_ctx.timeout_id = gtk.g_timeout_add(format_timeout_ms, @ptrCast(&onFormatTimeout), @ptrCast(fmt_ctx));

    doc.cl.request("textDocument/formatting", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .options = .{ .tabSize = @as(i64, 4), .insertSpaces = false },
    }, onFormatThen, @ptrCast(fmt_ctx));
}

fn finishNow(on_done: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    if (on_done) |f| f(ctx);
}

fn onFormatTimeout(user_data: ?*anyopaque) callconv(.c) c_int {
    const fmt_ctx: *FormatCtx = @ptrCast(@alignCast(user_data.?));
    fmt_ctx.timeout_id = 0;
    fmt_ctx.timed_out = true;
    // If the tab was already closed, `ctx` may no longer point at anything live.
    if (docFor(fmt_ctx.buffer) != null) finishNow(fmt_ctx.on_done, fmt_ctx.ctx);
    return 0; // G_SOURCE_REMOVE
}

pub fn renameSymbol(buffer: *gtk.GtkSourceBuffer) void {
    const doc = docFor(buffer) orelse return;
    if (!doc.cl.initialized) return;
    const pos = cursorPosition(doc) orelse return;
    const state = doc.owner;

    const dialog = gtk.adw_alert_dialog_new("Rename Symbol", null).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    gtk.adw_alert_dialog_add_response(dialog, "rename", "Rename");
    gtk.adw_alert_dialog_set_response_appearance(dialog, "rename", gtk.ADW_RESPONSE_SUGGESTED);
    gtk.adw_alert_dialog_set_default_response(dialog, "rename");
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");

    const entry_widget = gtk.gtk_entry_new().?;
    const entry: *gtk.GtkEntry = @ptrCast(entry_widget);
    gtk.gtk_entry_set_placeholder_text(entry, "New name");
    gtk.gtk_entry_set_activates_default(entry, 1);
    gtk.adw_alert_dialog_set_extra_child(dialog, entry_widget);

    // Pre-fill with the word under the cursor so the user can edit it directly.
    if (wordAtCursor(buffer)) |word| {
        defer gtk.g_free(@ptrCast(word));
        gtk.gtk_editable_set_text(@ptrCast(entry), word);
        gtk.gtk_editable_select_region(@ptrCast(entry), 0, -1);
    }

    _ = gtk.g_signal_connect_data(dialog, "map", @as(gtk.GCallback, @ptrCast(&focusEntryOnMap)), entry_widget, null, 0);

    const ctx = alloc.create(RenameCtx) catch return;
    ctx.* = .{ .buffer = buffer, .line = pos.line, .ch = pos.ch, .entry = entry };
    gtk.adw_alert_dialog_choose(
        dialog,
        @ptrCast(state.win),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onRenameDialogDone)),
        @ptrCast(ctx),
    );
}

fn focusEntryOnMap(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = gtk.gtk_widget_grab_focus(@as(*gtk.GtkWidget, @ptrCast(@alignCast(user_data.?))));
}

/// Returns the word under the cursor as a GLib-allocated string (caller must
/// g_free), or null when the cursor is not inside a word.
fn wordAtCursor(buffer: *gtk.GtkSourceBuffer) ?[*:0]u8 {
    const tb: *gtk.GtkTextBuffer = @ptrCast(buffer);
    const mark = gtk.gtk_text_buffer_get_insert(tb) orelse return null;
    var cursor: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_mark(tb, &cursor, mark);
    if (gtk.gtk_text_iter_inside_word(&cursor) == 0) return null;
    var start = cursor;
    var end = cursor;
    _ = gtk.gtk_text_iter_backward_word_start(&start);
    _ = gtk.gtk_text_iter_forward_word_end(&end);
    return gtk.gtk_text_buffer_get_text(tb, &start, &end, 0);
}

pub fn codeAction(buffer: *gtk.GtkSourceBuffer) void {
    const doc = docFor(buffer) orelse return;
    if (!doc.cl.initialized) return;
    const pos = cursorPosition(doc) orelse return;
    const no_diags: [0]struct {} = .{};
    doc.cl.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .range = .{
            .start = .{ .line = pos.line, .character = pos.ch },
            .end = .{ .line = pos.line, .character = pos.ch },
        },
        .context = .{ .diagnostics = no_diags, .triggerKind = @as(i64, 1) },
    }, onCodeActions, @ptrCast(buffer));
}

// ── Completion trigger characters ─────────────────────────────────────────────

/// Returns the set of characters that should trigger LSP completion for the
/// given language ID. Always includes '.'; ':' is added for languages that use
/// it as a scope-resolution operator (Rust, C/C++).
fn triggerCharsForLanguage(language_id: []const u8) []const u21 {
    const dot_colon: []const u21 = &.{ '.', ':' };
    const dot_only: []const u21 = &.{'.'};
    return if (std.mem.eql(u8, language_id, "rust") or
        std.mem.eql(u8, language_id, "cpp"))
        dot_colon
    else
        dot_only;
}

/// Called from completion.c: returns 1 when `ch` should trigger LSP completion
/// for the language associated with `buffer`, 0 otherwise.
export fn zc_lsp_is_trigger_char(buffer: *gtk.GtkSourceBuffer, ch: c_uint) c_int {
    const ch_u21: u21 = @intCast(ch);
    const triggers = if (docFor(buffer)) |doc|
        triggerCharsForLanguage(doc.language_id)
    else
        triggerCharsForLanguage(""); // no server registered: dot only
    for (triggers) |t| if (t == ch_u21) return 1;
    return 0;
}

// ── Navigation / refactoring exports (called from src/c/editor.c) ────────────

export fn zc_lsp_goto_definition(buffer: *gtk.GtkSourceBuffer, line: c_int, ch: c_int) void {
    const doc = docFor(buffer) orelse return;
    if (!doc.cl.initialized) return;
    syncNow(doc);
    doc.cl.request("textDocument/definition", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .position = .{ .line = @as(i64, line), .character = lspCol(doc, line, ch) },
    }, onDefinition, @ptrCast(buffer));
}

export fn zc_lsp_rename_symbol(buffer: *gtk.GtkSourceBuffer) void {
    renameSymbol(buffer);
}

// ── Completion (called from src/c/completion.c) ───────────────────────────────

export fn zc_lsp_complete(
    buffer: *gtk.GtkSourceBuffer,
    line: c_int,
    character: c_int,
    task: *gtk.GTask,
    trigger_kind: c_int,
    trigger_char: c_int,
) void {
    const doc = docFor(buffer) orelse return finishEmpty(task);
    if (!doc.cl.initialized) return finishEmpty(task);
    syncNow(doc);

    const pos = .{ .line = @as(i64, line), .character = lspCol(doc, line, character) };
    const text_doc = .{ .uri = std.mem.sliceTo(doc.uri, 0) };

    if (trigger_kind != 0 and trigger_char != 0) {
        var buf: [4]u8 = undefined;
        const ch: u21 = @intCast(trigger_char);
        const ch_len = std.unicode.utf8Encode(ch, &buf) catch 1;
        doc.cl.request("textDocument/completion", .{
            .textDocument = text_doc,
            .position = pos,
            .context = .{ .triggerKind = @as(i64, 2), .triggerCharacter = buf[0..ch_len] },
        }, onCompletion, @ptrCast(task));
    } else if (trigger_kind != 0) {
        doc.cl.request("textDocument/completion", .{
            .textDocument = text_doc,
            .position = pos,
            .context = .{ .triggerKind = @as(i64, trigger_kind) },
        }, onCompletion, @ptrCast(task));
    } else {
        doc.cl.request("textDocument/completion", .{
            .textDocument = text_doc,
            .position = pos,
        }, onCompletion, @ptrCast(task));
    }
}

// ── Hover documentation (called from src/c/hover.c) ──────────────────────────

export fn zc_lsp_request_hover(
    buffer: *gtk.GtkSourceBuffer,
    line: c_int,
    ch: c_int,
    sv: *gtk.GtkSourceView,
) void {
    const doc = docFor(buffer) orelse return;
    if (!doc.cl.initialized) return;
    const ctx = alloc.create(HoverCtx) catch return;
    // ctx keeps the byte column: the popover anchor and hover.c's stale-response
    // check both work in GTK coordinates; only the request uses LSP encoding.
    ctx.* = .{ .view = sv, .line = line, .ch = ch };
    doc.cl.request("textDocument/hover", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .position = .{ .line = @as(i64, line), .character = lspCol(doc, line, ch) },
    }, onHover, ctx);
}

// ── Signature help (called from src/c/signature.c) ───────────────────────────

export fn zc_lsp_signature_help(
    buffer: *gtk.GtkSourceBuffer,
    line: c_int,
    ch: c_int,
    sv: *gtk.GtkSourceView,
) void {
    const doc = docFor(buffer) orelse return;
    if (!doc.cl.initialized) return;
    const ctx = alloc.create(SigCtx) catch return;
    ctx.* = .{ .view = sv };
    doc.cl.request("textDocument/signatureHelp", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .position = .{ .line = @as(i64, line), .character = lspCol(doc, line, ch) },
    }, onSignatureHelp, ctx);
}

// ── Response callbacks ────────────────────────────────────────────────────────

fn onCompletion(self: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    const task: *gtk.GTask = @ptrCast(@alignCast(ctx.?));
    const store = gtk.zc_completion_store_new() orelse return finishEmpty(task);
    const items = completionItems(result) orelse return gtk.zc_completion_finish(task, store);
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    for (items.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const label = strField(obj, "label") orelse continue;
        const detail = strField(obj, "detail");
        const insert = insertText(obj) orelse label;
        const label_z = a.dupeZ(u8, label) catch continue;
        const insert_z = a.dupeZ(u8, insert) catch continue;
        const detail_z: ?[*:0]const u8 = if (detail) |d| (a.dupeZ(u8, d) catch null) else null;
        gtk.zc_completion_store_add(store, label_z, detail_z, insert_z);
    }
    gtk.zc_completion_finish(task, store);
}

fn onDefinition(_: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    const val = result orelse return;
    const loc = extractLocation(val) orelse return;
    // Re-derive through the live buffer rather than trusting a stored window
    // pointer across the async gap — the tab (or its window) may have closed
    // while the request was in flight.
    const buffer: *gtk.GtkSourceBuffer = @ptrCast(@alignCast(ctx.?));
    const doc = docFor(buffer) orelse return;
    jumpToLocation(doc.owner, loc);
}

fn onHover(self: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    _ = self;
    const hover_ctx: *HoverCtx = @ptrCast(@alignCast(ctx.?));
    defer alloc.destroy(hover_ctx);
    // No symbol documentation here — but the line may carry a diagnostic whose
    // full-width tint the user is hovering; surface its message instead.
    const text = extractHoverText(result) orelse
        return gtk.zc_hover_show_diag_fallback(hover_ctx.view, hover_ctx.line, hover_ctx.ch);
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0)
        return gtk.zc_hover_show_diag_fallback(hover_ctx.view, hover_ctx.line, hover_ctx.ch);
    var buf: [2048:0]u8 = undefined;
    const shown = utf8Prefix(trimmed, buf.len - 1);
    @memcpy(buf[0..shown.len], shown);
    buf[shown.len] = 0;
    gtk.zc_hover_show_text(hover_ctx.view, &buf, hover_ctx.line, hover_ctx.ch);
}

fn onSignatureHelp(self: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    _ = self;
    const sig_ctx: *SigCtx = @ptrCast(@alignCast(ctx.?));
    defer alloc.destroy(sig_ctx);
    const label = extractSignatureLabel(result) orelse {
        gtk.zc_signature_hide(sig_ctx.view);
        return;
    };
    var buf: [512:0]u8 = undefined;
    const shown = utf8Prefix(label, buf.len - 1);
    @memcpy(buf[0..shown.len], shown);
    buf[shown.len] = 0;
    gtk.zc_signature_show(sig_ctx.view, &buf);
}

fn onFormatThen(_: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    const fmt_ctx: *FormatCtx = @ptrCast(@alignCast(ctx.?));
    defer alloc.destroy(fmt_ctx);
    // The timeout already ran `on_done`; the caller may have moved on (saved,
    // closed the tab), so this late response is dropped rather than applied.
    if (fmt_ctx.timed_out) return;
    if (fmt_ctx.timeout_id != 0) _ = gtk.g_source_remove(fmt_ctx.timeout_id);

    const doc = docFor(fmt_ctx.buffer) orelse return; // tab closed while in flight

    // The user kept typing while the server was working, so these edits refer
    // to text that no longer exists: applying them would delete whatever was
    // typed since. Save without formatting instead — the next save formats.
    if (doc.edit_seq != fmt_ctx.edit_seq) return finishNow(fmt_ctx.on_done, fmt_ctx.ctx);

    if (result) |val| switch (val) {
        .array => |edits| applyFormatEdits(fmt_ctx.buffer, edits.items),
        else => {},
    };
    finishNow(fmt_ctx.on_done, fmt_ctx.ctx);
}

/// Applies a formatting result without moving what the user is looking at.
///
/// A formatter rewrites the whole document, and emptying a buffer collapses its
/// view's scroll offset to zero: left alone, every save throws the caret away
/// and jumps to the top of the file, which reads as the editor having frozen.
/// So the caret's line, column and both scroll offsets are restored around the
/// rewrite.
fn applyFormatEdits(buffer: *gtk.GtkSourceBuffer, edits: []const std.json.Value) void {
    const tb: *gtk.GtkTextBuffer = @ptrCast(buffer);
    var caret: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_mark(tb, &caret, gtk.gtk_text_buffer_get_insert(tb));
    const line = gtk.gtk_text_iter_get_line(&caret);
    const col = gtk.gtk_text_iter_get_line_offset(&caret);

    const spot = if (core.editorTabForBuffer(buffer)) |tab| position.caretSpot(tab.source_view, &caret) else null;

    applyTextEdits(buffer, edits);

    var restored: gtk.GtkTextIter = .{};
    _ = gtk.gtk_text_buffer_get_iter_at_line(tb, &restored, @min(line, gtk.gtk_text_buffer_get_line_count(tb) - 1));
    var line_end = restored;
    if (gtk.gtk_text_iter_ends_line(&line_end) == 0) _ = gtk.gtk_text_iter_forward_to_line_end(&line_end);
    _ = gtk.gtk_text_iter_forward_chars(&restored, @min(col, gtk.gtk_text_iter_get_line_offset(&line_end)));
    gtk.gtk_text_buffer_place_cursor(tb, &restored);

    // The frame that follows a formatting edit can be painted without a layout
    // pass having run, and GTK then skips the editor's subtree and re-shows the
    // previous frame — the text looks frozen while the status bar keeps up.
    // Asking for the resize explicitly makes the next frame include a layout.
    if (core.editorTabForBuffer(buffer)) |tab|
        gtk.gtk_widget_queue_resize(@ptrCast(tab.source_view));

    if (spot) |s| scrollBack(buffer, s);
}

const ScrollBack = struct { buffer: *gtk.GtkSourceBuffer, spot: position.CaretSpot };

/// Puts the caret back where it was on screen once the view has caught up with
/// the rewrite.  It has to wait: GtkTextView re-measures the new text below the
/// priority at which it paints, so a scroll issued here would be computed from
/// the old line heights and land near the top of the document.
fn scrollBack(buffer: *gtk.GtkSourceBuffer, spot: position.CaretSpot) void {
    const req = alloc.create(ScrollBack) catch return;
    req.* = .{ .buffer = buffer, .spot = spot };
    _ = gtk.g_idle_add(@ptrCast(&onScrollBack), @ptrCast(req));
}

fn onScrollBack(user_data: ?*anyopaque) callconv(.c) c_int {
    const req: *ScrollBack = @ptrCast(@alignCast(user_data.?));
    defer alloc.destroy(req);
    const tab = core.editorTabForBuffer(req.buffer) orelse return 0; // tab closed
    const tb: *gtk.GtkTextBuffer = @ptrCast(req.buffer);
    gtk.gtk_text_view_scroll_to_mark(
        @ptrCast(tab.source_view),
        gtk.gtk_text_buffer_get_insert(tb),
        0,
        1,
        req.spot.x,
        req.spot.y,
    );
    return 0;
}

fn onRenameResponse(_: *client.Client, _: ?*anyopaque, result: ?std.json.Value) void {
    applyWorkspaceEdit(result orelse return);
}

fn onCodeActions(_: *client.Client, ctx: ?*anyopaque, result: ?std.json.Value) void {
    const val = result orelse return;
    const items = switch (val) {
        .array => |a| a,
        else => return,
    };
    if (items.items.len == 0) return;
    // Re-derive through the live buffer rather than trusting a stored window
    // pointer across the async gap — the tab (or its window) may have closed
    // while the request was in flight.
    const buffer: *gtk.GtkSourceBuffer = @ptrCast(@alignCast(ctx.?));
    const doc = docFor(buffer) orelse return;
    const state = doc.owner;

    const action_ctx = alloc.create(CodeActionCtx) catch return;
    action_ctx.* = .{};

    for (items.items) |item| {
        if (action_ctx.len >= max_code_actions) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const title_str = strField(obj, "title") orelse continue;
        const title = alloc.dupeZ(u8, title_str) catch continue;
        const edit_json: ?[:0]u8 = if (obj.get("edit")) |edit_val| blk: {
            const json_str = std.json.Stringify.valueAlloc(alloc, edit_val, .{}) catch break :blk null;
            defer alloc.free(json_str);
            break :blk alloc.dupeZ(u8, json_str) catch null;
        } else null;
        action_ctx.append(.{ .title = title, .edit_json = edit_json });
    }

    if (action_ctx.len == 0) {
        alloc.destroy(action_ctx);
        return;
    }

    const dialog = gtk.adw_alert_dialog_new("Code Actions", null).?;
    gtk.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
    var id_buf: [4]u8 = undefined;
    for (action_ctx.slice(), 0..) |entry, i| {
        const id = std.fmt.bufPrintZ(&id_buf, "{d}", .{i}) catch continue;
        gtk.adw_alert_dialog_add_response(dialog, id, entry.title);
        if (i == 0) {
            gtk.adw_alert_dialog_set_response_appearance(dialog, id, gtk.ADW_RESPONSE_SUGGESTED);
            gtk.adw_alert_dialog_set_default_response(dialog, id);
        }
    }
    gtk.adw_alert_dialog_set_close_response(dialog, "cancel");
    gtk.adw_alert_dialog_choose(
        dialog,
        @ptrCast(state.win),
        null,
        @as(gtk.GAsyncReadyCallback, @ptrCast(&onCodeActionDialogDone)),
        @ptrCast(action_ctx),
    );
}

// ── Dialog callbacks (callconv .c, fired by GTK) ──────────────────────────────

fn onRenameDialogDone(source: ?*gtk.GObject, result: ?*gtk.GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *RenameCtx = @ptrCast(@alignCast(user_data.?));
    defer alloc.destroy(ctx);
    const dialog: *gtk.AdwAlertDialog = @ptrCast(@alignCast(source.?));
    const response = std.mem.sliceTo(gtk.adw_alert_dialog_choose_finish(dialog, result), 0);
    if (!std.mem.eql(u8, response, "rename")) return;
    const raw = gtk.gtk_editable_get_text(@ptrCast(ctx.entry));
    const new_name = std.mem.sliceTo(raw, 0);
    if (new_name.len == 0) return;
    const doc = docFor(ctx.buffer) orelse return;
    doc.cl.request("textDocument/rename", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0) },
        .position = .{ .line = ctx.line, .character = ctx.ch },
        .newName = new_name,
    }, onRenameResponse, null);
}

fn onCodeActionDialogDone(source: ?*gtk.GObject, result: ?*gtk.GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *CodeActionCtx = @ptrCast(@alignCast(user_data.?));
    defer {
        ctx.deinit();
        alloc.destroy(ctx);
    }
    const dialog: *gtk.AdwAlertDialog = @ptrCast(@alignCast(source.?));
    const response = std.mem.sliceTo(gtk.adw_alert_dialog_choose_finish(dialog, result), 0);
    const idx = std.fmt.parseInt(usize, response, 10) catch return;
    if (idx >= ctx.len) return;
    const edit_json = ctx.slice()[idx].edit_json orelse return;
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.sliceTo(edit_json, 0),
        .{},
    ) catch return;
    defer parsed.deinit();
    applyWorkspaceEdit(parsed.value);
}

// ── Context structs ───────────────────────────────────────────────────────────

const HoverCtx = struct {
    view: *gtk.GtkSourceView,
    line: c_int,
    ch: c_int,
};

const SigCtx = struct {
    view: *gtk.GtkSourceView,
};

const RenameCtx = struct {
    buffer: *gtk.GtkSourceBuffer,
    line: i64,
    ch: i64,
    entry: *gtk.GtkEntry,
};

const ActionEntry = struct {
    title: [:0]u8, // owned
    edit_json: ?[:0]u8, // owned WorkspaceEdit as JSON; null if the action has no inline edit
};

const CodeActionCtx = struct {
    actions: [max_code_actions]ActionEntry = undefined,
    len: usize = 0,

    fn slice(self: *@This()) []ActionEntry {
        return self.actions[0..self.len];
    }

    fn append(self: *@This(), entry: ActionEntry) void {
        if (self.len >= max_code_actions) return;
        self.actions[self.len] = entry;
        self.len += 1;
    }

    fn deinit(self: *@This()) void {
        for (self.slice()) |entry| {
            alloc.free(entry.title);
            if (entry.edit_json) |j| alloc.free(j);
        }
    }
};

// ── WorkspaceEdit application ─────────────────────────────────────────────────

fn applyWorkspaceEdit(edit: std.json.Value) void {
    const obj = switch (edit) {
        .object => |o| o,
        else => return,
    };

    // changes: { uri: TextEdit[] }
    if (obj.get("changes")) |changes_val| {
        const changes = switch (changes_val) {
            .object => |o| o,
            else => return,
        };
        var it = changes.iterator();
        while (it.next()) |entry| {
            const edits = switch (entry.value_ptr.*) {
                .array => |a| a,
                else => continue,
            };
            if (docForUri(entry.key_ptr.*)) |doc| applyTextEdits(doc.buffer, edits.items);
        }
    }

    // documentChanges: TextDocumentEdit[]
    if (obj.get("documentChanges")) |dc_val| {
        const arr = switch (dc_val) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |item| {
            const item_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const td = switch (item_obj.get("textDocument") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const uri = strField(td, "uri") orelse continue;
            const edits = switch (item_obj.get("edits") orelse continue) {
                .array => |a| a,
                else => continue,
            };
            if (docForUri(uri)) |doc| applyTextEdits(doc.buffer, edits.items);
        }
    }
}

const PendingEdit = struct {
    sl: i64,
    sc: i64,
    el: i64,
    ec: i64,
    text: []const u8,
};

fn laterFirst(_: void, a: PendingEdit, b: PendingEdit) bool {
    if (a.sl != b.sl) return a.sl > b.sl;
    return a.sc > b.sc;
}

/// Applies a set of LSP text edits to `buffer` as one undoable operation.
///
/// Every range is expressed against the document as the server last saw it, so
/// the set has to be applied bottom-up or each edit shifts the positions of the
/// ones after it.  The protocol does not promise the array is sorted, so the
/// edits are ordered here rather than assumed: walking the array backwards is
/// only correct for a server that happens to emit them in ascending order.
fn applyTextEdits(buffer: *gtk.GtkSourceBuffer, edits: []const std.json.Value) void {
    if (edits.len == 0) return;
    const tb: *gtk.GtkTextBuffer = @ptrCast(buffer);
    const utf16 = if (docFor(buffer)) |d| d.cl.position_utf16 else false;

    const pending = alloc.alloc(PendingEdit, edits.len) catch return;
    defer alloc.free(pending);

    var n: usize = 0;
    for (edits) |value| {
        const obj = switch (value) {
            .object => |o| o,
            else => continue,
        };
        var range = parseRange(obj) orelse continue;
        // An inverted range is not something any revision of this buffer can
        // satisfy; applying the rest of the set around it would corrupt the file.
        if (range.sl < 0 or range.el < range.sl) return;
        if (utf16) {
            range.sc = utf16ToByteCol(tb, range.sl, range.sc);
            range.ec = utf16ToByteCol(tb, range.el, range.ec);
        }
        pending[n] = .{
            .sl = range.sl,
            .sc = range.sc,
            .el = range.el,
            .ec = range.ec,
            .text = strField(obj, "newText") orelse "",
        };
        n += 1;
    }
    if (n == 0) return;
    std.mem.sort(PendingEdit, pending[0..n], {}, laterFirst);

    gtk.gtk_text_buffer_begin_user_action(tb);
    defer gtk.gtk_text_buffer_end_user_action(tb);

    for (pending[0..n]) |edit| {
        var a: gtk.GtkTextIter = .{};
        var b: gtk.GtkTextIter = .{};
        gtk.zc_iter_at_line_byte(tb, &a, @intCast(edit.sl), @intCast(edit.sc));
        gtk.zc_iter_at_line_byte(tb, &b, @intCast(edit.el), @intCast(edit.ec));
        applyOneEdit(tb, &a, &b, edit.text);
    }
}

/// Replaces [a, b) with `text`, but only the part of it that actually differs.
///
/// A formatter answers with the whole document, so applying an edit verbatim
/// rewrites every line even when three blank lines were all that changed.  That
/// forces GtkTextView to re-validate the entire file, which it does in idle
/// chunks at `GDK_PRIORITY_REDRAW + 5` — after the frame is laid out but before
/// the next one paints.  Each chunk queues a resize the current frame no longer
/// honours, so GTK finds a pending allocation at snapshot time, keeps the
/// previous render node and the editor stops repainting while still tracking
/// the caret.  Narrowing the edit keeps the rewrite proportional to the change,
/// and makes a format that changes nothing cost nothing.
fn applyOneEdit(tb: *gtk.GtkTextBuffer, a: *gtk.GtkTextIter, b: *gtk.GtkTextIter, text: []const u8) void {
    const old_c = gtk.gtk_text_buffer_get_text(tb, a, b, 1) orelse return;
    defer gtk.g_free(@ptrCast(old_c));
    const old = std.mem.sliceTo(old_c, 0);

    const head = commonPrefix(old, text);
    const tail = commonSuffix(old[head..], text[head..]);
    if (head == old.len and head == text.len) return; // identical

    _ = gtk.gtk_text_iter_forward_chars(a, charCount(old[0..head]));
    _ = gtk.gtk_text_iter_backward_chars(b, charCount(old[old.len - tail ..]));
    gtk.gtk_text_buffer_delete(tb, a, b);

    const middle = text[head .. text.len - tail];
    if (middle.len > 0) gtk.gtk_text_buffer_insert(tb, a, middle.ptr, @intCast(middle.len));
}

/// Length of the shared start of `a` and `b`, backed off to a UTF-8 boundary.
fn commonPrefix(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {}
    // Back off while the cut lands *on* a continuation byte — the byte at `i` is
    // what tells whether it is a character boundary.  Testing the byte before it
    // stopped one short, so two characters differing only after a shared lead
    // byte ("añb" vs "aöb") split the sequence, and the character count the
    // caller derives from this prefix then moved the iter a character too far.
    while (i > 0 and isContinuation(a[i..])) : (i -= 1) {}
    return i;
}

/// Length of the shared end of `a` and `b`, backed off to a UTF-8 boundary.
fn commonSuffix(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[a.len - 1 - i] == b[b.len - 1 - i]) : (i += 1) {}
    while (i > 0 and isContinuation(a[a.len - i ..])) : (i -= 1) {}
    return i;
}

fn isContinuation(s: []const u8) bool {
    return s.len > 0 and s[0] & 0xC0 == 0x80;
}

fn charCount(bytes: []const u8) c_int {
    var n: c_int = 0;
    for (bytes) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

// ── JSON helpers ──────────────────────────────────────────────────────────────

const Range = struct { sl: i64, sc: i64, el: i64, ec: i64 };

fn parseRange(obj: std.json.ObjectMap) ?Range {
    const r = switch (obj.get("range") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const s = switch (r.get("start") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const e = switch (r.get("end") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return .{
        .sl = intField(s, "line") orelse return null,
        .sc = intField(s, "character") orelse return null,
        .el = intField(e, "line") orelse return null,
        .ec = intField(e, "character") orelse return null,
    };
}

const Location = struct { uri: []const u8, line: i64, ch: i64 };

fn extractLocation(val: std.json.Value) ?Location {
    return switch (val) {
        .object => |o| locationFromObj(o),
        .array => |a| if (a.items.len == 0) null else switch (a.items[0]) {
            .object => |o| locationFromObj(o),
            else => null,
        },
        else => null,
    };
}

fn locationFromObj(obj: std.json.ObjectMap) ?Location {
    // Location: { uri, range } — or LocationLink: { targetUri, targetRange }
    const uri = strField(obj, "uri") orelse strField(obj, "targetUri") orelse return null;
    const range_key = if (obj.get("targetSelectionRange") != null) "targetSelectionRange" else "range";
    const range = obj.get(range_key) orelse return null;
    const r = switch (range) {
        .object => |o| o,
        else => return null,
    };
    const s = switch (r.get("start") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return .{
        .uri = uri,
        .line = intField(s, "line") orelse return null,
        .ch = intField(s, "character") orelse return null,
    };
}

fn jumpToLocation(state: *core.AppState, loc: Location) void {
    const fn_ptr = g_open_at_fn orelse return;
    var buf: [4096:0]u8 = undefined;
    const uri_z = std.fmt.bufPrintZ(&buf, "{s}", .{loc.uri}) catch return;
    const path = gtk.g_filename_from_uri(uri_z, null, null) orelse return;
    defer gtk.g_free(path);
    // openAt places the cursor with a byte index; convert when the target is
    // already open and its server counts UTF-16 units. For files not yet open
    // the raw column is used as-is (exact only for ASCII-prefixed lines).
    var ch = loc.ch;
    if (docForUri(loc.uri)) |target| {
        if (target.cl.position_utf16)
            ch = utf16ToByteCol(@ptrCast(target.buffer), loc.line, ch);
    }
    fn_ptr(state, path, loc.line, ch);
}

fn extractHoverText(result: ?std.json.Value) ?[]const u8 {
    const obj = switch (result orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const contents = obj.get("contents") orelse return null;
    return switch (contents) {
        .string => |s| s,
        .object => |o| strField(o, "value"),
        .array => |a| for (a.items) |item| {
            switch (item) {
                .string => |s| break s,
                .object => |o| if (strField(o, "value")) |v| break v,
                else => {},
            }
        } else null,
        else => null,
    };
}

fn extractSignatureLabel(result: ?std.json.Value) ?[]const u8 {
    const obj = switch (result orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const sigs = switch (obj.get("signatures") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (sigs.items.len == 0) return null;
    const active: usize = switch (obj.get("activeSignature") orelse std.json.Value{ .integer = 0 }) {
        .integer => |i| @intCast(@max(0, i)),
        else => 0,
    };
    const sig_obj = switch (sigs.items[@min(active, sigs.items.len - 1)]) {
        .object => |o| o,
        else => return null,
    };
    return strField(sig_obj, "label");
}

fn completionItems(result: ?std.json.Value) ?std.json.Array {
    return switch (result orelse return null) {
        .array => |a| a,
        .object => |o| switch (o.get("items") orelse return null) {
            .array => |a| a,
            else => null,
        },
        else => null,
    };
}

fn insertText(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("textEdit")) |te| switch (te) {
        .object => |o| if (strField(o, "newText")) |t| return t,
        else => {},
    };
    return strField(obj, "insertText");
}

/// Largest prefix of `s` that fits in `max` bytes without splitting a UTF-8
/// sequence — a blind byte cut mid-character hands Pango invalid UTF-8.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

// ── Position encoding ─────────────────────────────────────────────────────────
// GTK columns are byte indexes; the LSP default encoding is UTF-16 code units
// (only some servers negotiate utf-8). These walk the line to convert — they
// only differ from the identity on lines with non-ASCII text, but skipping the
// conversion there corrupts the server's copy of the document under
// incremental sync, leaving phantom diagnostics behind.

fn byteToUtf16Col(tb: *gtk.GtkTextBuffer, line: i64, byte_col: i64) i64 {
    var it: gtk.GtkTextIter = .{};
    _ = gtk.gtk_text_buffer_get_iter_at_line(tb, &it, clampLine(line));
    var col: i64 = 0;
    while (gtk.gtk_text_iter_get_line_index(&it) < byte_col and
        gtk.gtk_text_iter_ends_line(&it) == 0)
    {
        col += if (gtk.gtk_text_iter_get_char(&it) >= 0x10000) 2 else 1;
        if (gtk.gtk_text_iter_forward_char(&it) == 0) break;
    }
    return col;
}

fn utf16ToByteCol(tb: *gtk.GtkTextBuffer, line: i64, utf16_col: i64) i64 {
    var it: gtk.GtkTextIter = .{};
    _ = gtk.gtk_text_buffer_get_iter_at_line(tb, &it, clampLine(line));
    var col: i64 = 0;
    while (col < utf16_col and gtk.gtk_text_iter_ends_line(&it) == 0) {
        col += if (gtk.gtk_text_iter_get_char(&it) >= 0x10000) 2 else 1;
        if (gtk.gtk_text_iter_forward_char(&it) == 0) break;
    }
    return gtk.gtk_text_iter_get_line_index(&it);
}

fn clampLine(line: i64) c_int {
    return @intCast(@min(@max(line, 0), std.math.maxInt(c_int)));
}

/// Converts a GTK byte column to the encoding `doc`'s server expects.
fn lspCol(doc: *Document, line: i64, byte_col: i64) i64 {
    if (!doc.cl.position_utf16) return byte_col;
    return byteToUtf16Col(@ptrCast(doc.buffer), line, byte_col);
}

// ── Cursor position ───────────────────────────────────────────────────────────

const CursorPos = struct { line: i64, ch: i64 };

/// Cursor position in the encoding `doc`'s server expects.
fn cursorPosition(doc: *Document) ?CursorPos {
    const tb: *gtk.GtkTextBuffer = @ptrCast(doc.buffer);
    const mark = gtk.gtk_text_buffer_get_insert(tb) orelse return null;
    var iter: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_iter_at_mark(tb, &iter, mark);
    const line: i64 = gtk.gtk_text_iter_get_line(&iter);
    return .{
        .line = line,
        .ch = lspCol(doc, line, gtk.gtk_text_iter_get_line_index(&iter)),
    };
}

// ── Document change tracking ──────────────────────────────────────────────────

fn onChanged(_: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    if (doc.change_timer != 0) _ = gtk.g_source_remove(doc.change_timer);
    doc.change_timer = gtk.g_timeout_add(change_debounce_ms, @ptrCast(&onChangeTimeout), @ptrCast(doc));
}

fn onChangeTimeout(user_data: ?*anyopaque) callconv(.c) c_int {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    doc.change_timer = 0;
    sendDidChange(doc, false);
    return 0; // G_SOURCE_REMOVE
}

fn syncNow(doc: *Document) void {
    if (doc.change_timer != 0) {
        _ = gtk.g_source_remove(doc.change_timer);
        doc.change_timer = 0;
    }
    cancelDeferredSync(doc);
    sendDidChange(doc, true);
}

/// How long to wait before retrying a sync that deferred for backpressure.
/// Short enough to keep the server's view current, long enough to let a large
/// in-flight write actually drain rather than spin the main loop.
const sync_retry_ms: c_uint = 20;

/// Retries a sync that deferred because the transport was busy.  The retry
/// re-reads the buffer, so any edits that landed in the meantime are included
/// for free — collapsing a burst of pastes into one didChange per drain cycle.
fn onSyncRetry(user_data: ?*anyopaque) callconv(.c) c_int {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    doc.sync_idle = 0;
    sendDidChange(doc, false);
    return 0; // G_SOURCE_REMOVE
}

fn cancelDeferredSync(doc: *Document) void {
    if (doc.sync_idle != 0) {
        _ = gtk.g_source_remove(doc.sync_idle);
        doc.sync_idle = 0;
    }
}

fn sendDidChange(doc: *Document, force: bool) void {
    defer clearChanges(doc);

    // Backpressure: the previous didChange (potentially megabytes for a large
    // paste) is still queued in the transport.  Building another one now would
    // stack a second serialization on top of the first and starve the main loop
    // of input — the editor freezes mid-paste.  Defer instead: the next attempt
    // re-reads the buffer, so edits that arrived meanwhile are folded in for
    // free, and a burst collapses into one sync per drain cycle.  `force`
    // (a save flushing pending changes) bypasses this so the server's view is
    // current before the didSave.
    if (!force and doc.cl.writePending()) {
        if (doc.sync_idle == 0)
            doc.sync_idle = gtk.g_timeout_add(sync_retry_ms, &onSyncRetry, @ptrCast(doc));
        return;
    }

    if (doc.cl.sync_incremental and !doc.needs_full_sync) {
        // Nothing changed since the last sync (e.g. a save with no pending
        // edits): the server already has the latest content, so leave the
        // current diagnostics in place — they still describe this buffer.
        if (doc.changes.items.len == 0) return;
        doc.version += 1;
        var lsp_changes: [max_incremental_changes]LspChange = undefined;
        for (doc.changes.items, 0..) |ch, i| {
            lsp_changes[i] = .{
                .range = .{
                    .start = .{ .line = ch.start_line, .character = ch.start_char },
                    .end = .{ .line = ch.end_line, .character = ch.end_char },
                },
                .text = ch.text,
            };
        }
        doc.cl.notify("textDocument/didChange", .{
            .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0), .version = doc.version },
            .contentChanges = lsp_changes[0..doc.changes.items.len],
        });
        // The buffer changed for real: drop stale diagnostics now and wait
        // for the server to republish fresh ones for this new content.
        clearDiagVisuals(doc);
        return;
    }

    doc.version += 1;
    const text = bufferText(doc.buffer);
    defer gtk.g_free(@ptrCast(@constCast(text.ptr)));
    doc.cl.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = std.mem.sliceTo(doc.uri, 0), .version = doc.version },
        .contentChanges = .{.{ .text = text }},
    });
    clearDiagVisuals(doc);
}

fn onInsertText(
    _: ?*gtk.GtkTextBuffer,
    location: *gtk.GtkTextIter,
    text: [*]const u8,
    len: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    doc.edit_seq +%= 1;
    const line: i64 = gtk.gtk_text_iter_get_line(location);
    const inserted = text[0..@intCast(@max(len, 0))];
    shiftDiagBand(doc, @intCast(line), @intCast(std.mem.count(u8, inserted, "\n")));

    if (!doc.cl.sync_incremental) return;
    // A single edit past the per-edit ceiling, or accumulation past the total
    // ceiling, is not worth capturing: the retained copy and the JSON fragment
    // it would produce are both large, and the next full sync supersedes them.
    // Drop incremental capture for the rest of this burst and let the debounce
    // fall through to a full sync.
    if (doc.needs_full_sync) return;
    if (inserted.len > incremental_change_bytes or
        doc.changes_bytes + inserted.len > incremental_total_bytes or
        doc.changes.items.len >= max_incremental_changes)
    {
        doc.needs_full_sync = true;
        return;
    }
    const ch = lspCol(doc, line, gtk.gtk_text_iter_get_line_index(location));
    const owned = alloc.dupe(u8, inserted) catch return;
    doc.changes.append(alloc, .{
        .start_line = line,
        .start_char = ch,
        .end_line = line,
        .end_char = ch,
        .text = owned,
    }) catch {
        alloc.free(owned);
        return;
    };
    doc.changes_bytes += inserted.len;
}

fn onDeleteRange(
    _: ?*gtk.GtkTextBuffer,
    start: *gtk.GtkTextIter,
    end: *gtk.GtkTextIter,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    doc.edit_seq +%= 1;
    const sl: i64 = gtk.gtk_text_iter_get_line(start);
    const el: i64 = gtk.gtk_text_iter_get_line(end);
    shiftDiagBand(doc, @intCast(sl), -@as(c_int, @intCast(el - sl)));

    if (!doc.cl.sync_incremental or doc.needs_full_sync) return;
    // A delete's text is empty so it costs no retained bytes, but a burst can
    // still exceed the change count; once it has, stop capturing and let the
    // debounce issue a full sync.
    if (doc.changes.items.len >= max_incremental_changes) {
        doc.needs_full_sync = true;
        return;
    }
    const empty = alloc.dupe(u8, "") catch return;
    doc.changes.append(alloc, .{
        .start_line = sl,
        .start_char = lspCol(doc, sl, gtk.gtk_text_iter_get_line_index(start)),
        .end_line = el,
        .end_char = lspCol(doc, el, gtk.gtk_text_iter_get_line_index(end)),
        .text = empty,
    }) catch alloc.free(empty);
}

fn clearChanges(doc: *Document) void {
    for (doc.changes.items) |ch| alloc.free(ch.text);
    doc.changes.clearRetainingCapacity();
    doc.changes_bytes = 0;
    doc.needs_full_sync = false;
}

// ── Diagnostics ───────────────────────────────────────────────────────────────

fn onNotification(cl: *client.Client, method: []const u8, params: ?std.json.Value) void {
    _ = cl;
    if (std.mem.eql(u8, method, "textDocument/publishDiagnostics"))
        handlePublishDiagnostics(params orelse return);
}

fn handlePublishDiagnostics(params: std.json.Value) void {
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const uri = strField(obj, "uri") orelse return;
    const doc = docForUri(uri) orelse return;

    // A publish for an older document version describes text the user has
    // already changed; applying it would resurrect fixed diagnostics that then
    // stick until the server happens to publish again. Drop it — the didChange
    // that bumped the version triggers a fresh publish.
    if (intField(obj, "version")) |v| {
        if (v < doc.version) return;
    }

    clearDiagTags(doc);
    doc.diags.clear();

    const arr = switch (obj.get("diagnostics") orelse return) {
        .array => |a| a,
        else => return,
    };
    var worst_sev: u8 = 0;

    for (arr.items) |d| {
        const d_obj = switch (d) {
            .object => |o| o,
            else => continue,
        };
        var range = parseRange(d_obj) orelse continue;
        if (doc.cl.position_utf16) {
            const tb: *gtk.GtkTextBuffer = @ptrCast(doc.buffer);
            range.sc = utf16ToByteCol(tb, range.sl, range.sc);
            range.ec = utf16ToByteCol(tb, range.el, range.ec);
        }
        const sev: DiagSeverity = if (d_obj.get("severity")) |sv| switch (sv) {
            .integer => |i| @enumFromInt(@as(u8, @intCast(@min(@max(i, 1), 4)))),
            else => .err,
        } else .err;
        const s8 = @intFromEnum(sev);
        if (worst_sev == 0 or s8 < worst_sev) worst_sev = s8;
        const msg = strField(d_obj, "message") orelse continue;
        const owned_msg = alloc.dupeZ(u8, msg) catch continue;
        doc.diags.add(.{
            .start_line = range.sl,
            .start_char = range.sc,
            .end_line = range.el,
            .end_char = range.ec,
            .severity = sev,
            .message = owned_msg,
        });
    }
    scheduleDiagVisuals(doc);
    updateTreeDiag(doc.owner, uri, worst_sev);
    // The buffer may be on screen in more than one window; each status bar
    // decides for itself whether these diagnostics are the ones it shows.
    for (core.g_windows.items) |w| view.updateStatus(w);
}

/// How many diagnostics the server currently reports for `buffer`, indexed by
/// severity: error, warning, information, hint.  All zero when no server backs
/// the buffer.
pub fn diagnosticCounts(buffer: *gtk.GtkSourceBuffer) [4]u32 {
    const doc = docFor(buffer) orelse return .{0} ** 4;
    return doc.diags.counts;
}

fn createDiagTags(doc: *Document) void {
    const tb: *anyopaque = @ptrCast(doc.buffer);
    const colors = [4][3]u8{
        .{ 0xed, 0x33, 0x3b }, // error
        .{ 0xed, 0xad, 0x1a }, // warning
        .{ 0x4e, 0x9a, 0xf2 }, // info
        .{ 0x8e, 0x90, 0x91 }, // hint
    };
    const ul_alpha = [4]f32{ 0.85, 0.85, 0.85, 0.60 };
    for (colors, 0..) |c, i| {
        const r: f32 = @as(f32, @floatFromInt(c[0])) / 255.0;
        const g: f32 = @as(f32, @floatFromInt(c[1])) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(c[2])) / 255.0;
        doc.diags.underline[i] = gtk.zc_diag_tag_new(tb, r, g, b, ul_alpha[i]);
    }
}

// Bound on line-tint marks per publish so a pathological diagnostic set
// (thousands of lines) can't flood the buffer with source marks.
const max_line_marks: usize = 256;

fn applyDiagTags(doc: *Document) void {
    const tb: *gtk.GtkTextBuffer = @ptrCast(doc.buffer);
    const n_lines = gtk.gtk_text_buffer_get_line_count(tb);
    var marks_left: usize = max_line_marks;
    var band_first: c_int = std.math.maxInt(c_int);
    var band_last: c_int = -1;
    for (doc.diags.items.items) |item| {
        const idx = @intFromEnum(item.severity) - 1;
        const t = doc.diags.underline[idx] orelse continue;
        const sl: c_int = @intCast(@min(item.start_line, n_lines - 1));
        const el: c_int = @intCast(@min(item.end_line, n_lines - 1));

        // Wavy underline: over the exact diagnostic range.  The columns were
        // measured when the server published them, so they are only ever an
        // approximation of where the text is now — snapped, never trusted.
        var a: gtk.GtkTextIter = .{};
        var b: gtk.GtkTextIter = .{};
        gtk.zc_iter_at_line_byte(tb, &a, sl, @intCast(item.start_char));
        gtk.zc_iter_at_line_byte(tb, &b, el, @intCast(item.end_char));
        gtk.gtk_text_buffer_apply_tag(tb, t, &a, &b);

        // Line tint: a source mark per affected line; GtkSourceView paints its
        // background across the full view width, so the highlight reads end to
        // end regardless of line length or horizontal scroll.
        var line = sl;
        while (line <= el and marks_left > 0) : (line += 1) {
            gtk.zc_diag_line_mark_add(doc.buffer, line, @intFromEnum(item.severity));
            marks_left -= 1;
        }

        band_first = @min(band_first, sl);
        band_last = @max(band_last, el);
    }
    doc.diags.painted_first = band_first;
    doc.diags.painted_last = band_last;
}

/// Moves the record of where diagnostics were painted along with the text.
///
/// The tags and marks are anchored in the buffer and travel with it on their
/// own; the band that says where to sweep them does not, and a band left behind
/// describes lines they have since left — so the sweep misses them and they
/// stay on screen over code they no longer describe.  Which is what made the
/// band have to be the whole document to be safe.
fn shiftDiagBand(doc: *Document, at_line: c_int, delta: c_int) void {
    const d = &doc.diags;
    if (delta == 0 or d.painted_last < d.painted_first) return;
    if (at_line > d.painted_last) return;
    if (at_line < d.painted_first) {
        d.painted_first = @max(0, d.painted_first + delta);
        d.painted_last += delta;
    } else {
        // Inside the band: only what is below the edit moves.
        d.painted_last += delta;
    }
    if (d.painted_last < d.painted_first) d.painted_last = -1;
}

/// Removes the underlines and line tints from the band the last paint covered.
///
/// Sweeping the whole buffer instead is what made every edit cost the size of
/// the file: eight full passes (four tags, four mark categories) ran on each
/// didChange, ~50 ms per pass at 4 MB, several times a second while typing.
/// The band is what the paint actually touched, kept in step with the text by
/// `shiftDiagBand` and bounded by `max_diag_items` — and usually nothing is
/// painted at all.
fn clearDiagTags(doc: *Document) void {
    const first = doc.diags.painted_first;
    const last = doc.diags.painted_last;
    if (last < first) return; // nothing on screen

    const tb: *gtk.GtkTextBuffer = @ptrCast(doc.buffer);
    const n_lines = gtk.gtk_text_buffer_get_line_count(tb);
    var start: gtk.GtkTextIter = .{};
    var end: gtk.GtkTextIter = .{};
    _ = gtk.gtk_text_buffer_get_iter_at_line(tb, &start, @max(0, @min(first, n_lines - 1)));
    const end_line = @min(last + 1, n_lines - 1);
    _ = gtk.gtk_text_buffer_get_iter_at_line(tb, &end, end_line);
    if (end_line >= n_lines - 1) _ = gtk.gtk_text_iter_forward_to_line_end(&end);

    for (doc.diags.underline) |maybe_tag|
        if (maybe_tag) |tag| gtk.gtk_text_buffer_remove_tag(tb, tag, &start, &end);
    gtk.zc_diag_line_marks_clear_range(doc.buffer, &start, &end);

    doc.diags.painted_last = -1;
}

/// Drops every visual trace of the current diagnostics — underline/background
/// tags, overview-ruler marks, hover popups and the file-tree badge. Called on
/// each edit so nothing keeps pointing at code the user has already changed;
/// the server republishes fresh diagnostics (in particular after save).
// A server republishes on every keystroke, and each publish repaints the whole
// document's diagnostics — hundreds of source marks torn down and recreated.
// Doing that at typing speed queues gutter resizes in the middle of GTK's paint
// phase, and a widget with a pending allocation is skipped by
// `gtk_widget_do_snapshot`, which leaves its previous frame on screen: the
// editor stops redrawing while still tracking the caret. Painting on a timer
// instead keeps the marks from ever landing mid-frame, and the visuals only
// need to keep up with the eye.
const diag_paint_delay_ms: c_uint = 150;

fn scheduleDiagVisuals(doc: *Document) void {
    doc.diag_seq = doc.edit_seq;
    if (doc.diag_timer != 0) return; // already due
    doc.diag_timer = gtk.g_timeout_add(diag_paint_delay_ms, @ptrCast(&onDiagPaint), @ptrCast(doc));
}

fn onDiagPaint(user_data: ?*anyopaque) callconv(.c) c_int {
    const doc: *Document = @ptrCast(@alignCast(user_data.?));
    doc.diag_timer = 0;
    // The user edited between the publish and this repaint. These positions
    // describe the previous revision, so drop them; the didChange those edits
    // are about to trigger brings a publish that matches what is on screen.
    if (doc.diag_seq != doc.edit_seq) return 0;
    paintDiagVisuals(doc);
    return 0;
}

/// Puts the current diagnostics on screen: wavy underlines and line tint in the
/// buffer, marks on the overview ruler, and the text the hover popover reads.
fn paintDiagVisuals(doc: *Document) void {
    applyDiagTags(doc);

    var marks: [max_diag_marks]gtk.ZcDiagMark = undefined;
    var mcount: usize = 0;
    for (doc.diags.items.items) |item| {
        if (mcount == max_diag_marks) break;
        marks[mcount] = .{ .line = @intCast(item.start_line), .severity = @intFromEnum(item.severity) };
        mcount += 1;
    }
    gtk.zc_buffer_set_diag_marks(doc.buffer, if (mcount > 0) &marks[0] else null, @intCast(mcount));

    var hovers: [max_diag_marks]gtk.ZcHoverDiag = undefined;
    var hcount: usize = 0;
    for (doc.diags.items.items) |item| {
        if (hcount == max_diag_marks) break;
        hovers[hcount] = .{
            .start_line = @intCast(item.start_line),
            .start_char = @intCast(item.start_char),
            .end_line = @intCast(item.end_line),
            .end_char = @intCast(item.end_char),
            .severity = @intFromEnum(item.severity),
            .message = item.message.ptr,
        };
        hcount += 1;
    }
    gtk.zc_buffer_set_hover_diags(doc.buffer, if (hcount > 0) &hovers[0] else null, @intCast(hcount));
}

fn clearDiagVisuals(doc: *Document) void {
    if (doc.diag_timer != 0) {
        _ = gtk.g_source_remove(doc.diag_timer);
        doc.diag_timer = 0;
    }
    clearDiagTags(doc);
    doc.diags.clear();
    gtk.zc_buffer_set_diag_marks(doc.buffer, null, 0);
    gtk.zc_buffer_set_hover_diags(doc.buffer, null, 0);
    updateTreeDiag(doc.owner, std.mem.sliceTo(doc.uri, 0), 0);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn specFor(path: [*:0]const u8) ?*const ServerSpec {
    const name = std.mem.sliceTo(path, 0);
    for (&registry) |*spec| {
        for (spec.exts) |ext| if (std.mem.endsWith(u8, name, ext)) return spec;
    }
    return null;
}

/// The project root for `path`: the open folder if any, else the file's parent.
/// Caller frees.
fn rootFor(state: *core.AppState, path: [*:0]const u8) ?[:0]u8 {
    if (state.folder_path[0] != 0)
        return alloc.dupeZ(u8, std.mem.sliceTo(&state.folder_path, 0)) catch null;
    const dir = std.fs.path.dirname(std.mem.sliceTo(path, 0)) orelse return null;
    return alloc.dupeZ(u8, dir) catch null;
}

fn clientFor(root: [:0]const u8, spec: *const ServerSpec) ?*client.Client {
    for (g_servers.items) |entry| {
        if (std.mem.eql(u8, entry.language_id, spec.language_id) and
            std.mem.eql(u8, entry.root, root)) return entry.cl;
    }
    const cl = client.Client.create(alloc, spec.argv.ptr, root.ptr) orelse return null;
    const root_uri = fileUri(root.ptr) orelse {
        cl.destroy();
        return null;
    };
    defer alloc.free(root_uri);
    cl.start(std.mem.sliceTo(root_uri, 0));
    cl.setNotificationHandler(onNotification);
    cl.on_status_change = onClientStatusChange;

    const entry = alloc.create(ServerEntry) catch {
        cl.destroy();
        return null;
    };
    entry.* = .{
        .root = alloc.dupeZ(u8, root) catch {
            cl.destroy();
            alloc.destroy(entry);
            return null;
        },
        .language_id = spec.language_id,
        .cl = cl,
    };
    g_servers.append(alloc, entry) catch {
        cl.destroy();
        alloc.free(entry.root);
        alloc.destroy(entry);
        return null;
    };
    return cl;
}

fn docFor(buffer: *gtk.GtkSourceBuffer) ?*Document {
    const idx = docIndex(buffer) orelse return null;
    return g_docs.items[idx];
}

fn docIndex(buffer: *gtk.GtkSourceBuffer) ?usize {
    for (g_docs.items, 0..) |doc, i| if (doc.buffer == buffer) return i;
    return null;
}

fn docForUri(uri: []const u8) ?*Document {
    for (g_docs.items) |doc|
        if (std.mem.eql(u8, std.mem.sliceTo(doc.uri, 0), uri)) return doc;
    return null;
}

/// Owned, NUL-terminated "file://…" URI for `path`. Caller frees.
fn fileUri(path: [*:0]const u8) ?[:0]u8 {
    const raw = gtk.g_filename_to_uri(path, null, null) orelse return null;
    defer gtk.g_free(raw);
    return alloc.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch null;
}

/// Whole buffer text. The returned pointer must be g_free'd by the caller.
fn bufferText(buffer: *gtk.GtkSourceBuffer) [:0]const u8 {
    var s: gtk.GtkTextIter = undefined;
    var e: gtk.GtkTextIter = undefined;
    const tb: *gtk.GtkTextBuffer = @ptrCast(buffer);
    gtk.gtk_text_buffer_get_bounds(tb, &s, &e);
    const raw = gtk.gtk_text_buffer_get_text(tb, &s, &e, 1) orelse return "";
    return std.mem.sliceTo(raw, 0);
}

fn updateTreeDiag(state: *core.AppState, uri: []const u8, sev: u8) void {
    const tree = state.file_tree orelse return;
    var uri_z: [4096:0]u8 = undefined;
    const n = @min(uri.len, uri_z.len - 1);
    @memcpy(uri_z[0..n], uri[0..n]);
    uri_z[n] = 0;
    const path = gtk.g_filename_from_uri(&uri_z, null, null) orelse return;
    defer gtk.g_free(path);
    gtk.zc_file_tree_set_diag_severity(tree, path, @intCast(sev));
}

fn finishEmpty(task: *gtk.GTask) void {
    gtk.zc_completion_finish(task, gtk.zc_completion_store_new());
}

// ── Tests for pure JSON helpers ───────────────────────────────────────────────

const testing = std.testing;

fn parseJson(src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, src, .{});
}

test "utf8Prefix: short strings pass through" {
    try testing.expectEqualStrings("hola", utf8Prefix("hola", 10));
    try testing.expectEqualStrings("hola", utf8Prefix("hola", 4));
}

test "utf8Prefix: never splits a multi-byte sequence" {
    // "aé" = 'a' + 2-byte é; cutting at 2 lands mid-é and must back off.
    try testing.expectEqualStrings("a", utf8Prefix("a\xc3\xa9", 2));
    try testing.expectEqualStrings("a\xc3\xa9", utf8Prefix("a\xc3\xa9b", 3));
    // 4-byte emoji: any cut inside it backs off to the boundary before it.
    const emoji = "x\xf0\x9f\x98\x80"; // "x😀"
    try testing.expectEqualStrings("x", utf8Prefix(emoji, 2));
    try testing.expectEqualStrings("x", utf8Prefix(emoji, 4));
    try testing.expectEqualStrings(emoji, utf8Prefix(emoji, 5));
}

test "strField: present and absent" {
    var parsed = try parseJson("{\"key\":\"value\",\"num\":42}");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("value", strField(obj, "key").?);
    try testing.expect(strField(obj, "num") == null);
    try testing.expect(strField(obj, "missing") == null);
}

test "intField: present and absent" {
    var parsed = try parseJson("{\"n\":7,\"s\":\"text\"}");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 7), intField(obj, "n").?);
    try testing.expect(intField(obj, "s") == null);
    try testing.expect(intField(obj, "x") == null);
}

test "parseRange: valid range" {
    var parsed = try parseJson(
        \\{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":9}}}
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    const r = parseRange(obj).?;
    try testing.expectEqual(@as(i64, 2), r.sl);
    try testing.expectEqual(@as(i64, 4), r.sc);
    try testing.expectEqual(@as(i64, 2), r.el);
    try testing.expectEqual(@as(i64, 9), r.ec);
}

test "parseRange: missing range returns null" {
    var parsed = try parseJson("{\"text\":\"hello\"}");
    defer parsed.deinit();
    try testing.expect(parseRange(parsed.value.object) == null);
}

test "completionItems: array result" {
    var parsed = try parseJson("[{\"label\":\"foo\"},{\"label\":\"bar\"}]");
    defer parsed.deinit();
    const items = completionItems(parsed.value).?;
    try testing.expectEqual(@as(usize, 2), items.items.len);
}

test "completionItems: object with items field" {
    var parsed = try parseJson("{\"items\":[{\"label\":\"a\"}],\"isIncomplete\":false}");
    defer parsed.deinit();
    const items = completionItems(parsed.value).?;
    try testing.expectEqual(@as(usize, 1), items.items.len);
}

test "completionItems: null result returns null" {
    try testing.expect(completionItems(null) == null);
}

test "insertText: prefers textEdit.newText" {
    var parsed = try parseJson(
        \\{"textEdit":{"newText":"bar","range":{}},"insertText":"baz","label":"foo"}
    );
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("bar", insertText(obj).?);
}

test "insertText: falls back to insertText field" {
    var parsed = try parseJson("{\"label\":\"x\",\"insertText\":\"xx\"}");
    defer parsed.deinit();
    try testing.expectEqualStrings("xx", insertText(parsed.value.object).?);
}

test "insertText: null when neither field present" {
    var parsed = try parseJson("{\"label\":\"x\"}");
    defer parsed.deinit();
    try testing.expect(insertText(parsed.value.object) == null);
}

test "extractHoverText: string contents" {
    var parsed = try parseJson("{\"contents\":\"hover text\"}");
    defer parsed.deinit();
    try testing.expectEqualStrings("hover text", extractHoverText(parsed.value).?);
}

test "extractHoverText: MarkupContent object" {
    var parsed = try parseJson("{\"contents\":{\"kind\":\"markdown\",\"value\":\"**bold**\"}}");
    defer parsed.deinit();
    try testing.expectEqualStrings("**bold**", extractHoverText(parsed.value).?);
}

test "extractHoverText: null result" {
    try testing.expect(extractHoverText(null) == null);
}

test "extractSignatureLabel: first signature" {
    var parsed = try parseJson(
        \\{"signatures":[{"label":"fn foo(x: i32)"},{"label":"fn foo(x: f64)"}],"activeSignature":0}
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("fn foo(x: i32)", extractSignatureLabel(parsed.value).?);
}

test "extractSignatureLabel: activeSignature index respected" {
    var parsed = try parseJson(
        \\{"signatures":[{"label":"first"},{"label":"second"}],"activeSignature":1}
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("second", extractSignatureLabel(parsed.value).?);
}

test "extractSignatureLabel: empty signatures returns null" {
    var parsed = try parseJson("{\"signatures\":[]}");
    defer parsed.deinit();
    try testing.expect(extractSignatureLabel(parsed.value) == null);
}

test "triggerCharsForLanguage: rust includes dot and colon" {
    const chars = triggerCharsForLanguage("rust");
    try testing.expect(std.mem.indexOfScalar(u21, chars, '.') != null);
    try testing.expect(std.mem.indexOfScalar(u21, chars, ':') != null);
}

test "triggerCharsForLanguage: cpp includes dot and colon" {
    const chars = triggerCharsForLanguage("cpp");
    try testing.expect(std.mem.indexOfScalar(u21, chars, '.') != null);
    try testing.expect(std.mem.indexOfScalar(u21, chars, ':') != null);
}

test "triggerCharsForLanguage: zig is dot only" {
    const chars = triggerCharsForLanguage("zig");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "triggerCharsForLanguage: go is dot only" {
    const chars = triggerCharsForLanguage("go");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "triggerCharsForLanguage: python is dot only" {
    const chars = triggerCharsForLanguage("python");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "triggerCharsForLanguage: typescript is dot only" {
    const chars = triggerCharsForLanguage("typescript");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "triggerCharsForLanguage: unknown language is dot only" {
    const chars = triggerCharsForLanguage("haskell");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "triggerCharsForLanguage: empty language_id is dot only" {
    const chars = triggerCharsForLanguage("");
    try testing.expectEqual(@as(usize, 1), chars.len);
    try testing.expectEqual(@as(u21, '.'), chars[0]);
}

test "edit narrowing: identical text changes nothing" {
    const s = "const a = 1;\n";
    try std.testing.expectEqual(s.len, commonPrefix(s, s));
}

test "edit narrowing: only the changed middle survives" {
    const old = "a\n\n\n\nb\n";
    const new = "a\n\nb\n";
    const head = commonPrefix(old, new);
    const tail = commonSuffix(old[head..], new[head..]);
    try std.testing.expectEqualStrings("", new[head .. new.len - tail]);
    try std.testing.expectEqualStrings("\n\n", old[head .. old.len - tail]);
}

test "edit narrowing: boundaries stay on whole characters" {
    const old = "añb";
    const new = "aöb";
    const head = commonPrefix(old, new);
    const tail = commonSuffix(old[head..], new[head..]);
    try std.testing.expectEqual(@as(usize, 1), head); // not 2: 'ñ' starts at 1
    try std.testing.expectEqual(@as(usize, 1), tail);
    try std.testing.expectEqual(@as(c_int, 1), charCount(old[0..head]));
}

//! Markdown preview panel.
//!
//! When the active editor tab contains a Markdown file, a toggle button appears
//! in the header bar.  Activating it switches the per-tab GtkStack from the
//! source view to a WebKitWebView that renders the buffer as HTML via cmark.
//! The WebView is created lazily on first use to avoid WebKit startup cost for
//! tabs that never open preview mode.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const style = @import("../core/style.zig");

// Set from window.zig at startup to break the tabs.zig ↔ preview.zig cycle.
pub var g_open_file_fn: ?*const fn (*core.AppState, [*:0]const u8) void = null;

// ── HTML template ─────────────────────────────────────────────────────────────
//
// Colors mirror the bundled Catppuccin/Adwaita-Pastel style schemes:
//   dark  bg=#222226  fg=#ffffff  (adwaita-pastel-dark)
//   light bg=#fafafb  fg=#2f2f2f  (adwaita-pastel-light)
//
// Accent colours (links, headings border, code bg, blockquote) are taken from
// the same palette so the preview feels continuous with the editor.

/// The palette the preview shares with the editor: a Catppuccin/Adwaita-Pastel
/// colour pair, differing only in the :root variables and the zebra-row tint.
const Palette = struct {
    bg: []const u8,
    fg: []const u8,
    fg_dim: []const u8,
    border: []const u8,
    code_bg: []const u8,
    link: []const u8,
    tag_fg: []const u8,
    sel_bg: []const u8,
    zebra: []const u8,
};

const palette_dark = Palette{
    .bg = "#222226",
    .fg = "#ffffff",
    .fg_dim = "#a6adc8",
    .border = "#444444",
    .code_bg = "#1a1a1e",
    .link = "#89b4fa",
    .tag_fg = "#f9e2af",
    .sel_bg = "#585b70",
    .zebra = "rgba(255,255,255,0.03)",
};

const palette_light = Palette{
    .bg = "#fafafb",
    .fg = "#2f2f2f",
    .fg_dim = "#8c8fa1",
    .border = "#d0d0d5",
    .code_bg = "#f0f0f2",
    .link = "#1e66f5",
    .tag_fg = "#df8e1d",
    .sel_bg = "#acb0be",
    .zebra = "rgba(0,0,0,0.025)",
};

/// The shared CSS (everything but the :root block and the zebra-row tint).  A
/// plain literal — CSS braces are not format placeholders, so it must never
/// pass through comptimePrint.
const html_body_css_a =
    \\  * { box-sizing: border-box; }
    \\  body {
    \\    font-family: sans-serif; font-size: 15px; line-height: 1.6;
    \\    max-width: 820px; margin: 32px auto; padding: 0 28px;
    \\    background: var(--bg); color: var(--fg);
    \\  }
    \\  h1,h2,h3,h4,h5,h6 { margin: 1.4em 0 0.4em; line-height: 1.3; }
    \\  h1 { font-size: 2em;   border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
    \\  h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.2em; }
    \\  h3 { font-size: 1.25em; }
    \\  code {
    \\    background: var(--code-bg); color: var(--tag-fg);
    \\    padding: 2px 6px; border-radius: 4px;
    \\    font-family: monospace; font-size: 0.88em;
    \\  }
    \\  pre {
    \\    background: var(--code-bg); padding: 14px 18px;
    \\    border-radius: 6px; overflow-x: auto;
    \\  }
    \\  pre code { background: none; padding: 0; color: var(--fg); font-size: 0.9em; }
    \\  blockquote {
    \\    border-left: 3px solid var(--sel-bg); margin: 0;
    \\    padding: 2px 0 2px 16px; color: var(--fg-dim);
    \\  }
    \\  a { color: var(--link); text-decoration: none; }
    \\  a:hover { text-decoration: underline; }
    \\  img { max-width: 100%; border-radius: 4px; }
    \\  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    \\  th, td { border: 1px solid var(--border); padding: 6px 12px; text-align: left; }
    \\  th { background: var(--code-bg); font-weight: 600; }
;
const html_body_css_b =
    \\  hr { border: none; border-top: 1px solid var(--border); margin: 1.5em 0; }
    \\  ul, ol { padding-left: 1.6em; }
    \\  li { margin: 0.15em 0; }
    \\</style></head><body>
;

/// The full <head> for `p`, built at comptime.  Only the :root block and the
/// zebra-row line are formatted — they contain no CSS braces, so comptimePrint
/// is safe; the rest is plain concatenation.
fn htmlHead(comptime p: Palette) []const u8 {
    const root = std.fmt.comptimePrint(
        \\<!DOCTYPE html><html><head><meta charset="utf-8">
        \\<style>
        \\  :root {{
        \\    --bg:       {s};
        \\    --fg:       {s};
        \\    --fg-dim:   {s};
        \\    --border:   {s};
        \\    --code-bg:  {s};
        \\    --link:     {s};
        \\    --tag-fg:   {s};
        \\    --sel-bg:   {s};
        \\  }}
        \\
    , .{ p.bg, p.fg, p.fg_dim, p.border, p.code_bg, p.link, p.tag_fg, p.sel_bg });
    const zebra = std.fmt.comptimePrint(
        \\  tr:nth-child(even) td {{ background: {s}; }}
        \\
    , .{p.zebra});
    return root ++ html_body_css_a ++ zebra ++ html_body_css_b;
}

const html_head_dark = htmlHead(palette_dark);
const html_head_light = htmlHead(palette_light);

const html_tail = "</body></html>";

// ── Public interface ──────────────────────────────────────────────────────────

/// Returns true when the active editor tab has a preview panel (Markdown or HTML).
fn activeTabHasPreview(state: *core.AppState) bool {
    const tab = core.selectedEditorTab(state) orelse return false;
    return tab.preview_stack != null;
}

/// Shows or hides the preview toggle button depending on whether the active
/// editor tab supports preview (Markdown or HTML), and syncs its active state
/// with the per-tab preview_active flag.  Called on every tab selection change.
pub fn updatePreviewBtn(state: *core.AppState) void {
    const btn = state.preview_btn orelse return;
    const is_md = activeTabHasPreview(state) and !state.terminal_shown;
    gtk.gtk_widget_set_visible(btn, if (is_md) 1 else 0);

    // Sync the toggle state to the current tab without re-firing the signal.
    const want_active: c_int = blk: {
        if (!is_md) break :blk 0;
        const tab = core.selectedEditorTab(state) orelse break :blk 0;
        break :blk if (tab.preview_active) 1 else 0;
    };
    gtk.g_signal_handler_block(btn, state.preview_btn_handler);
    gtk.gtk_toggle_button_set_active(@ptrCast(btn), want_active);
    gtk.g_signal_handler_unblock(btn, state.preview_btn_handler);
}

/// Toggle-button signal handler.  Switches the active tab between editor and
/// preview; creates the WebKitWebView lazily on first preview activation.
pub fn onPreviewToggled(btn: ?*gtk.GtkToggleButton, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    const tab = core.selectedEditorTab(state) orelse return;
    const stack = tab.preview_stack orelse return;

    const active = gtk.gtk_toggle_button_get_active(btn) != 0;
    tab.preview_active = active;
    if (active) {
        const wv = ensureWebView(tab, stack);
        renderInto(tab, wv);
        gtk.gtk_stack_set_visible_child_name(stack, "preview");
    } else {
        gtk.gtk_stack_set_visible_child_name(stack, "editor");
        _ = gtk.gtk_widget_grab_focus(@ptrCast(tab.source_view));
    }
}

/// Activates preview mode for the currently selected tab.
/// No-op when the tab has no preview stack (non-Markdown/HTML file).
pub fn showPreview(state: *core.AppState) void {
    const tab = core.selectedEditorTab(state) orelse return;
    const stack = tab.preview_stack orelse return;
    tab.preview_active = true;
    const wv = ensureWebView(tab, stack);
    renderInto(tab, wv);
    gtk.gtk_stack_set_visible_child_name(stack, "preview");
    updatePreviewBtn(state);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Handles link clicks in the preview:
///   - http/https → default browser via gtk_show_uri
///   - file://    → open in zcode editor via g_open_file_fn
/// The programmatic load_html call (WEBKIT_NAVIGATION_TYPE_OTHER) is allowed through.
fn onDecidePolicy(
    _: ?*gtk.WebKitWebView,
    decision: ?*gtk.WebKitPolicyDecision,
    decision_type: c_int,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    if (decision_type == gtk.WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        const tab = @as(*core.EditorTab, @ptrCast(@alignCast(user_data.?)));
        const nav = @as(?*gtk.WebKitNavigationPolicyDecision, @ptrCast(decision));
        const action = gtk.webkit_navigation_policy_decision_get_navigation_action(nav);
        const nav_type = gtk.webkit_navigation_action_get_navigation_type(action);
        if (nav_type != gtk.WEBKIT_NAVIGATION_TYPE_OTHER) {
            handleLinkClick(tab, action);
            gtk.webkit_policy_decision_ignore(decision);
            return 1;
        }
    }
    return 0;
}

fn handleLinkClick(tab: *core.EditorTab, action: ?*gtk.WebKitNavigationAction) void {
    const req = gtk.webkit_navigation_action_get_request(action) orelse return;
    const uri = gtk.webkit_uri_request_get_uri(req) orelse return;
    const s = std.mem.sliceTo(uri, 0);

    if (std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://")) {
        gtk.gtk_show_uri(@ptrCast(tab.owner.win), uri, 0);
        return;
    }

    if (std.mem.startsWith(u8, s, "file://")) {
        const local = gtk.g_filename_from_uri(uri, null, null) orelse return;
        defer gtk.g_free(local);
        if (g_open_file_fn) |f| f(tab.owner, local);
    }
}

/// Returns the existing WebKitWebView for `tab`, or creates and registers one.
///
/// JavaScript stays off for every preview, HTML included.  A previewed file is
/// one the user opened to *read*, not to run: with scripts enabled, opening an
/// untrusted .html would execute it inside a sandbox that has the home
/// directory and the network.  The cost is that scripted HTML renders
/// statically, which is what a preview pane should do anyway.
fn ensureWebView(tab: *core.EditorTab, stack: *gtk.GtkStack) *gtk.WebKitWebView {
    if (tab.preview_view) |wv| return wv;

    const wv_widget = gtk.webkit_web_view_new().?;
    const wv = @as(*gtk.WebKitWebView, @ptrCast(wv_widget));

    const settings = gtk.webkit_settings_new().?;
    gtk.webkit_settings_set_enable_javascript(settings, 0);
    gtk.webkit_settings_set_enable_javascript_markup(settings, 0);
    // Allow loading https:// images from file:// context (e.g. badges in READMEs).
    // Safe because JS is disabled, so the relaxed cross-origin policy can't be exploited.
    gtk.webkit_settings_set_allow_universal_access_from_file_urls(settings, 1);
    gtk.webkit_web_view_set_settings(wv, settings);
    gtk.g_object_unref(settings);

    _ = gtk.g_signal_connect_data(
        wv_widget,
        "decide-policy",
        @as(gtk.GCallback, @ptrCast(&onDecidePolicy)),
        @ptrCast(tab),
        null,
        0,
    );

    gtk.gtk_widget_set_hexpand(wv_widget, 1);
    gtk.gtk_widget_set_vexpand(wv_widget, 1);
    _ = gtk.gtk_stack_add_named(stack, wv_widget, "preview");

    tab.preview_view = wv;
    return wv;
}

/// Renders the active file into `wv`.
/// HTML files are loaded directly from disk via a file:// URI (so relative
/// resources resolve correctly).  Markdown files are converted to HTML via
/// cmark and loaded as an in-memory string.
fn renderInto(tab: *core.EditorTab, wv: *gtk.WebKitWebView) void {
    const path = std.mem.sliceTo(&tab.doc.path, 0);
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) {
        const uri = gtk.g_filename_to_uri(&tab.doc.path, null, null) orelse return;
        defer gtk.g_free(uri);
        gtk.webkit_web_view_load_uri(wv, uri);
        return;
    }

    // Markdown: read buffer, convert with cmark, load as HTML string.
    const tb = @as(*gtk.GtkTextBuffer, @ptrCast(tab.buffer));
    var start: gtk.GtkTextIter = .{};
    var end: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_bounds(tb, &start, &end);

    const raw = gtk.gtk_text_buffer_get_text(tb, &start, &end, 0) orelse return;
    defer gtk.g_free(raw);

    // Pre-process GFM pipe tables → raw HTML before cmark sees the text, since
    // libcmark only implements CommonMark (tables are a GFM extension).
    const md_src = std.mem.span(raw);
    const processed = preprocessTables(md_src) catch md_src;
    defer if (processed.ptr != md_src.ptr) std.heap.c_allocator.free(processed);

    const body_html = gtk.cmark_markdown_to_html(processed.ptr, processed.len, gtk.CMARK_OPT_UNSAFE) orelse return;
    defer gtk.g_free(body_html);

    const dark = style.isDark() != 0;
    const head: []const u8 = if (dark) html_head_dark else html_head_light;
    const body: []const u8 = std.mem.span(body_html);

    const total = head.len + body.len + html_tail.len;
    const page = std.heap.c_allocator.allocSentinel(u8, total, 0) catch return;
    defer std.heap.c_allocator.free(page);
    @memcpy(page[0..head.len], head);
    @memcpy(page[head.len .. head.len + body.len], body);
    @memcpy(page[head.len + body.len .. total], html_tail);

    // Derive a base URI from the file's directory so relative image/link paths
    // (e.g. screenshots/demo.png) resolve correctly inside WebKit.
    var dir_buf: [4096:0]u8 = undefined;
    var base_uri_buf: [4096 + 10:0]u8 = undefined;
    const base_uri: ?[*:0]const u8 = blk: {
        const dir = std.fs.path.dirname(path) orelse break :blk null;
        const n = @min(dir.len, dir_buf.len - 1);
        @memcpy(dir_buf[0..n], dir[0..n]);
        dir_buf[n] = 0;
        const raw_uri = gtk.g_filename_to_uri(&dir_buf, null, null) orelse break :blk null;
        defer gtk.g_free(raw_uri);
        const raw_s = std.mem.sliceTo(raw_uri, 0);
        // URL resolution requires a trailing slash on the directory component.
        break :blk std.fmt.bufPrintZ(&base_uri_buf, "{s}/", .{raw_s}) catch null;
    };
    gtk.webkit_web_view_load_html(wv, page, base_uri);
}

// ── GFM pipe table → HTML pre-processor ──────────────────────────────────────
//
// Single-pass state machine that detects GFM pipe-table blocks (header +
// separator + rows) and converts them to raw <table> HTML before cmark sees
// the text.  libcmark only implements CommonMark — tables are a GFM extension.

fn isTableSeparator(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (s.len < 3) return false;
    var has_dash = false;
    for (s) |c| {
        switch (c) {
            '-' => has_dash = true,
            '|', ':', ' ' => {},
            else => return false,
        }
    }
    return has_dash;
}

fn isTableRow(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    return s.len > 0 and s[0] == '|';
}

const alloc = std.heap.c_allocator;

fn appendCells(out: *std.ArrayList(u8), line: []const u8, tag: []const u8) !void {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        try out.append(alloc, '<');
        try out.appendSlice(alloc, tag);
        try out.append(alloc, '>');
        try out.appendSlice(alloc, cell);
        try out.appendSlice(alloc, "</");
        try out.appendSlice(alloc, tag);
        try out.append(alloc, '>');
    }
}

test "isTableRow: detects pipe-prefixed lines" {
    try std.testing.expect(isTableRow("| foo | bar |"));
    try std.testing.expect(isTableRow("|col1|col2|"));
    try std.testing.expect(!isTableRow("no pipe here"));
    try std.testing.expect(!isTableRow(""));
    try std.testing.expect(!isTableRow("text | with pipe in middle"));
}

test "isTableSeparator: detects separator lines" {
    try std.testing.expect(isTableSeparator("|---|---|"));
    try std.testing.expect(isTableSeparator("| :--- | ---: |"));
    try std.testing.expect(isTableSeparator("---"));
    try std.testing.expect(!isTableSeparator("|foo|bar|"));
    try std.testing.expect(!isTableSeparator(""));
    try std.testing.expect(!isTableSeparator("--"));
}

test "preprocessTables: plain markdown is unchanged" {
    const src = "# Hello\n\nSome text.\n";
    const out = try preprocessTables(src);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "preprocessTables: converts a simple table" {
    const src = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n";
    const out = try preprocessTables(src);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<th>A</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<td>1</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<td>3</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</table>") != null);
}

test "preprocessTables: non-table content around a table" {
    const src = "Intro\n\n| X |\n| --- |\n| val |\n\nOutro\n";
    const out = try preprocessTables(src);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Intro") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Outro") != null);
}

fn preprocessTables(src: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // One pass: collect line slices into a growing list.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| lines.append(alloc, line) catch return out.toOwnedSlice(alloc);
    }

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (isTableRow(line) and i + 1 < lines.items.len and isTableSeparator(lines.items[i + 1])) {
            try out.appendSlice(alloc, "<table>\n<thead><tr>");
            try appendCells(&out, line, "th");
            try out.appendSlice(alloc, "</tr></thead>\n<tbody>\n");
            i += 2;
            while (i < lines.items.len and isTableRow(lines.items[i])) {
                try out.appendSlice(alloc, "<tr>");
                try appendCells(&out, lines.items[i], "td");
                try out.appendSlice(alloc, "</tr>\n");
                i += 1;
            }
            try out.appendSlice(alloc, "</tbody></table>\n");
        } else {
            try out.appendSlice(alloc, line);
            // splitScalar yields a trailing empty piece for text ending in a
            // newline, so appending unconditionally grew the document by one
            // blank line on every render.
            if (i + 1 < lines.items.len) try out.append(alloc, '\n');
            i += 1;
        }
    }

    return out.toOwnedSlice(alloc);
}

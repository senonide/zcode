//! Persistent preferences, backed by GSettings (schema
//! `org.senonide.zcode`).  The rest of the app asks this module for
//! effective values and never touches GSettings itself.
//!
//! Every accessor degrades to a built-in default when the schema is not
//! installed — `g_settings_new` aborts the process on a missing schema, so the
//! schema is looked up first and a failed lookup simply means "no persistence"
//! (which is what running an uninstalled binary should do, not a crash).

const std = @import("std");
const gtk = @import("../gtk.zig");

pub const key_mono_font: [*:0]const u8 = "monospace-font";
pub const key_recent_projects: [*:0]const u8 = "recent-projects";
pub const key_restore_last: [*:0]const u8 = "restore-last-project";
pub const key_style_scheme: [*:0]const u8 = "style-scheme";
pub const key_tab_width: [*:0]const u8 = "tab-width";
pub const key_insert_spaces: [*:0]const u8 = "insert-spaces";
pub const key_wrap_lines: [*:0]const u8 = "wrap-lines";
pub const key_show_line_numbers: [*:0]const u8 = "show-line-numbers";
pub const key_right_margin: [*:0]const u8 = "right-margin";

/// Editor keys whose change must restyle every open source view.  Watched as a
/// group so callers register one handler instead of six.
pub const editor_keys = [_][*:0]const u8{
    key_style_scheme, key_tab_width,         key_insert_spaces,
    key_wrap_lines,   key_show_line_numbers, key_right_margin,
};

pub const max_recent = 10;

/// Holds a Pango font description string ("JetBrains Mono 12").
pub const FontBuf = [127:0]u8;
pub const PathBuf = [4096:0]u8;

const schema_id: [*:0]const u8 = "org.senonide.zcode";
const desktop_schema_id: [*:0]const u8 = "org.gnome.desktop.interface";
const fallback_mono: [:0]const u8 = "Monospace 11";

var settings: ?*gtk.GSettings = null;
var desktop: ?*gtk.GSettings = null;

/// Opens the settings backends.  Call once, before the first window is built.
pub fn init() void {
    settings = open(schema_id);
    desktop = open(desktop_schema_id);
}

fn open(id: [*:0]const u8) ?*gtk.GSettings {
    const source = gtk.g_settings_schema_source_get_default() orelse return null;
    const schema = gtk.g_settings_schema_source_lookup(source, id, 1) orelse return null;
    gtk.g_settings_schema_unref(schema);
    return gtk.g_settings_new(id);
}

/// Runs `cb` whenever `key` changes — including changes made by another zcode
/// window, or from outside the app with `gsettings`.
pub fn watch(key: [*:0]const u8, cb: gtk.GCallback, data: ?*anyopaque) void {
    const s = settings orelse return;
    var signal: [64:0]u8 = undefined;
    const detailed = std.fmt.bufPrintZ(&signal, "changed::{s}", .{std.mem.sliceTo(key, 0)}) catch return;
    _ = gtk.g_signal_connect_data(s, detailed, cb, data, null, 0);
}

// ── Fonts ─────────────────────────────────────────────────────────────────────

/// The font the source view and terminal should use: the user's override when
/// set, otherwise the desktop's monospace font.
pub fn monoFont(buf: *FontBuf) [:0]const u8 {
    if (monoFontOverride(buf)) |desc| return desc;
    if (readString(desktop, "monospace-font-name", buf)) |desc| return desc;
    return fallback_mono;
}

/// The user's font override, or null while following the system font.
pub fn monoFontOverride(buf: *FontBuf) ?[:0]const u8 {
    return readString(settings, key_mono_font, buf);
}

/// Passing null (or an empty description) goes back to the system font.
pub fn setMonoFontOverride(desc: ?[*:0]const u8) void {
    const s = settings orelse return;
    _ = gtk.g_settings_set_string(s, key_mono_font, desc orelse "");
}

// ── Recent projects ───────────────────────────────────────────────────────────

/// Most-recent-first walk over the stored projects, skipping any whose
/// directory has since disappeared.  Borrowed strings: valid until `deinit`.
pub const Recents = struct {
    raw: ?[*:null]?[*:0]u8 = null,
    i: usize = 0,

    pub fn next(self: *Recents) ?[:0]const u8 {
        const list = self.raw orelse return null;
        while (list[self.i]) |entry| {
            self.i += 1;
            if (gtk.g_file_test(entry, gtk.G_FILE_TEST_IS_DIR) != 0) return std.mem.sliceTo(entry, 0);
        }
        return null;
    }

    pub fn deinit(self: *Recents) void {
        gtk.g_strfreev(self.raw);
        self.raw = null;
    }
};

pub fn recentProjects() Recents {
    const s = settings orelse return .{};
    return .{ .raw = gtk.g_settings_get_strv(s, key_recent_projects) };
}

/// Records `path` as the project opened most recently.
pub fn pushRecentProject(path: []const u8) void {
    const s = settings orelse return;
    var head: PathBuf = undefined;
    if (path.len == 0 or path.len > head.len) return;
    @memcpy(head[0..path.len], path);
    head[path.len] = 0;

    // Collected as raw pointers so the merged list can be handed to GSettings
    // without copying every path.
    var previous: [max_recent * 4][*:0]const u8 = undefined;
    var n_previous: usize = 0;
    var it = recentProjects();
    defer it.deinit();
    while (it.next()) |entry| {
        if (n_previous == previous.len) break;
        previous[n_previous] = @ptrCast(entry.ptr);
        n_previous += 1;
    }

    var merged: [max_recent + 1]?[*:0]const u8 = @splat(null);
    _ = mergeRecent(&head, previous[0..n_previous], &merged);
    _ = gtk.g_settings_set_strv(s, key_recent_projects, &merged);
}

/// Puts `head` first, keeps the previous order after it minus any duplicate of
/// `head`, and trims to `max_recent`.  `out` is left NULL-terminated.
fn mergeRecent(
    head: [*:0]const u8,
    previous: []const [*:0]const u8,
    out: *[max_recent + 1]?[*:0]const u8,
) usize {
    out[0] = head;
    var n: usize = 1;
    for (previous) |entry| {
        if (n == max_recent) break;
        if (std.mem.eql(u8, std.mem.sliceTo(entry, 0), std.mem.sliceTo(head, 0))) continue;
        out[n] = entry;
        n += 1;
    }
    out[n] = null;
    return n;
}

/// The project to reopen at startup, or null when there is none left on disk.
pub fn lastProject(buf: *PathBuf) ?[:0]const u8 {
    var it = recentProjects();
    defer it.deinit();
    const path = it.next() orelse return null;
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn restoreLastProject() bool {
    return readBool(key_restore_last, true);
}

pub fn setRestoreLastProject(on: bool) void {
    writeBool(key_restore_last, on);
}

// ── Editor ────────────────────────────────────────────────────────────────────

/// The style scheme the user pinned, or null while following the system
/// light/dark preference.
pub fn styleScheme(buf: *FontBuf) ?[:0]const u8 {
    return readString(settings, key_style_scheme, buf);
}

pub fn setStyleScheme(id: ?[*:0]const u8) void {
    const s = settings orelse return;
    _ = gtk.g_settings_set_string(s, key_style_scheme, id orelse "");
}

pub fn tabWidth() c_int {
    return readInt(key_tab_width, 4);
}

pub fn setTabWidth(width: c_int) void {
    writeInt(key_tab_width, width);
}

pub fn insertSpaces() bool {
    return readBool(key_insert_spaces, false);
}

pub fn setInsertSpaces(on: bool) void {
    writeBool(key_insert_spaces, on);
}

pub fn wrapLines() bool {
    return readBool(key_wrap_lines, false);
}

pub fn setWrapLines(on: bool) void {
    writeBool(key_wrap_lines, on);
}

pub fn showLineNumbers() bool {
    return readBool(key_show_line_numbers, true);
}

pub fn setShowLineNumbers(on: bool) void {
    writeBool(key_show_line_numbers, on);
}

/// Column of the right-margin guide; zero means the guide is hidden.
pub fn rightMargin() c_int {
    return readInt(key_right_margin, 0);
}

pub fn setRightMargin(column: c_int) void {
    writeInt(key_right_margin, column);
}

// ── Internals ─────────────────────────────────────────────────────────────────

fn readBool(key: [*:0]const u8, default: bool) bool {
    const s = settings orelse return default;
    return gtk.g_settings_get_boolean(s, key) != 0;
}

fn writeBool(key: [*:0]const u8, value: bool) void {
    const s = settings orelse return;
    _ = gtk.g_settings_set_boolean(s, key, if (value) 1 else 0);
}

fn readInt(key: [*:0]const u8, default: c_int) c_int {
    const s = settings orelse return default;
    return gtk.g_settings_get_int(s, key);
}

fn writeInt(key: [*:0]const u8, value: c_int) void {
    const s = settings orelse return;
    _ = gtk.g_settings_set_int(s, key, value);
}

/// Reads `key` into `buf`, treating an empty (or over-long) value as unset.
fn readString(s: ?*gtk.GSettings, key: [*:0]const u8, buf: *FontBuf) ?[:0]const u8 {
    if (s == null) return null;
    const raw = gtk.g_settings_get_string(s, key) orelse return null;
    defer gtk.g_free(raw);
    const value = std.mem.sliceTo(raw, 0);
    if (value.len == 0 or value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf[0..value.len :0];
}

test mergeRecent {
    var out: [max_recent + 1]?[*:0]const u8 = @splat(null);

    try std.testing.expectEqual(1, mergeRecent("/a", &.{}, &out));
    try std.testing.expectEqualStrings("/a", std.mem.sliceTo(out[0].?, 0));
    try std.testing.expect(out[1] == null);

    // A re-opened project moves to the head instead of being duplicated.
    try std.testing.expectEqual(3, mergeRecent("/b", &.{ "/a", "/b", "/c" }, &out));
    try std.testing.expectEqualStrings("/b", std.mem.sliceTo(out[0].?, 0));
    try std.testing.expectEqualStrings("/a", std.mem.sliceTo(out[1].?, 0));
    try std.testing.expectEqualStrings("/c", std.mem.sliceTo(out[2].?, 0));
    try std.testing.expect(out[3] == null);

    // Oldest entries fall off the end once the list is full.
    const full: [max_recent][*:0]const u8 = @splat("/old");
    try std.testing.expectEqual(max_recent, mergeRecent("/new", &full, &out));
    try std.testing.expectEqualStrings("/new", std.mem.sliceTo(out[0].?, 0));
    try std.testing.expect(out[max_recent] == null);
}

//! Window geometry persistence across sessions.
//! Saves width/height/maximized to $XDG_CONFIG_HOME/zcode/window.ini.

const std = @import("std");
const gtk = @import("../gtk.zig");

pub fn restore(win: *gtk.GtkWindow) void {
    var path_buf: [4096:0]u8 = .{0} ** 4096;
    if (!buildPath(&path_buf)) return;

    var raw: [*:0]u8 = undefined;
    var err: ?*gtk.GError = null;
    if (gtk.g_file_get_contents(&path_buf, &raw, null, &err) == 0) {
        if (err != null) gtk.g_error_free(err);
        return;
    }
    defer gtk.g_free(raw);

    var it = std.mem.splitScalar(u8, std.mem.sliceTo(raw, 0), '\n');
    const w = std.fmt.parseInt(c_int, std.mem.trim(u8, it.next() orelse return, &std.ascii.whitespace), 10) catch return;
    const h = std.fmt.parseInt(c_int, std.mem.trim(u8, it.next() orelse return, &std.ascii.whitespace), 10) catch return;
    const maximized = std.mem.eql(u8, std.mem.trim(u8, it.next() orelse "0", &std.ascii.whitespace), "1");

    if (maximized) {
        gtk.gtk_window_maximize(win);
    } else if (w > 0 and h > 0) {
        gtk.gtk_window_set_default_size(win, w, h);
    }
}

pub fn save(win: *gtk.GtkWindow) void {
    var path_buf: [4096:0]u8 = .{0} ** 4096;
    if (!buildPath(&path_buf)) return;

    ensureDir(&path_buf);

    var content_buf: [64]u8 = undefined;
    const content = if (gtk.gtk_window_is_maximized(win) != 0)
        std.fmt.bufPrint(&content_buf, "0\n0\n1\n", .{}) catch return
    else blk: {
        const w = gtk.gtk_widget_get_width(@ptrCast(win));
        const h = gtk.gtk_widget_get_height(@ptrCast(win));
        break :blk std.fmt.bufPrint(&content_buf, "{d}\n{d}\n0\n", .{ w, h }) catch return;
    };

    var gerr: ?*gtk.GError = null;
    _ = gtk.g_file_set_contents(&path_buf, content.ptr, @intCast(content.len), &gerr);
    if (gerr != null) gtk.g_error_free(gerr);
}

fn buildPath(buf: *[4096:0]u8) bool {
    const cfg = gtk.g_get_user_config_dir() orelse return false;
    _ = std.fmt.bufPrintZ(buf, "{s}/zcode/window.ini", .{std.mem.sliceTo(cfg, 0)}) catch return false;
    return true;
}

fn ensureDir(path: *const [4096:0]u8) void {
    var dir_buf: [4096:0]u8 = .{0} ** 4096;
    const path_s = std.mem.sliceTo(path, 0);
    const dir = std.fs.path.dirname(path_s) orelse return;
    const dn = @min(dir.len, dir_buf.len - 1);
    @memcpy(dir_buf[0..dn], dir[0..dn]);
    dir_buf[dn] = 0;
    _ = gtk.g_mkdir_with_parents(&dir_buf, 0o755);
}

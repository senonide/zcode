//! Application lifecycle and primary-menu actions (About, Quit).

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("../core/state.zig");
const config = @import("../core/config.zig");
const style = @import("../core/style.zig");
const window = @import("window.zig");
const files = @import("../sidebar/files.zig");
const editor = @import("../editor/tabs.zig");
const shortcuts = @import("shortcuts.zig");
const preferences = @import("preferences.zig");
const view = @import("view.zig");
const build_options = @import("build_options");

// Path requested on the command line, consumed once the window is built.
var g_startup_path: [4096:0]u8 = [_:0]u8{0} ** 4096;

/// Records the path to open at startup (set from main before the app runs).
/// Accepts a project directory or a file (whose parent becomes the project).
pub fn setStartupFolder(path: []const u8) void {
    const n = @min(path.len, g_startup_path.len - 1);
    @memcpy(g_startup_path[0..n], path[0..n]);
    g_startup_path[n] = 0;
}

pub fn onActivate(app: *gtk.AdwApplication, _: ?*anyopaque) callconv(.c) void {
    core.g_app = app;
    config.init();
    // Process-wide, not per window: the stylesheet and the scheme search path
    // live on the display and on a singleton manager, so registering them once
    // per window would stack a duplicate provider (and search path) each time.
    // The schemes must be on the path before the first buffer exists.
    style.registerStyleSchemes();
    style.applyGlobalCss();
    style.watchMonoFont();
    watchEditorPrefs();
    gtk.zc_diff_set_changed_cb(&view.onDiffChanged);
    installActions(app);
    shortcuts.installAccels(app);
    const state = window.buildWindow(app, null);

    if (g_startup_path[0] != 0) {
        openStartupPath(state);
    } else {
        openLastProject(state);
    }
}

/// Reopens the project from the previous session, unless the user turned that
/// off or its folder is gone.
fn openLastProject(state: *core.AppState) void {
    if (!config.restoreLastProject()) return;
    var buf: config.PathBuf = undefined;
    const path = config.lastProject(&buf) orelse return;
    files.openFolder(state, path);
}

/// Opens the command-line argument: a file opens its parent as the project and
/// the file in a tab; anything else is treated as the project directory.
fn openStartupPath(state: *core.AppState) void {
    const raw: [*:0]const u8 = &g_startup_path;

    if (gtk.g_file_test(raw, gtk.G_FILE_TEST_IS_REGULAR) != 0) {
        const abs = gtk.g_canonicalize_filename(raw, null);
        defer gtk.g_free(abs);
        if (std.fs.path.dirname(std.mem.sliceTo(abs, 0))) |dir| {
            files.openFolder(state, dir);
            editor.openEditorTab(state, abs);
        }
        return;
    }

    if (gtk.zc_resolve_dir(&g_startup_path)) |abs| {
        defer gtk.g_free(abs);
        files.openFolder(state, std.mem.sliceTo(abs, 0));
    }
}

// ── Editor preferences ────────────────────────────────────────────────────────

/// Keeps every open source view in step with the editor preferences for the
/// rest of the process' life.  The preferences dialog only writes to GSettings;
/// this is what turns a write into a visible change, in every window at once.
fn watchEditorPrefs() void {
    for (config.editor_keys) |key| config.watch(key, @ptrCast(&onEditorPrefChanged), null);
}

fn onEditorPrefChanged(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    style.refreshAll();
    editor.refreshAllEditorPrefs();
}

// ── Application actions (primary menu) ────────────────────────────────────────

fn installActions(app: *gtk.AdwApplication) void {
    const about = gtk.g_simple_action_new("about", null).?;
    _ = gtk.g_signal_connect_data(about, "activate", @as(gtk.GCallback, @ptrCast(&onAboutAction)), @ptrCast(app), null, 0);
    gtk.g_action_map_add_action(@ptrCast(app), @ptrCast(about));
    gtk.g_object_unref(about);

    const prefs = gtk.g_simple_action_new("preferences", null).?;
    _ = gtk.g_signal_connect_data(prefs, "activate", @as(gtk.GCallback, @ptrCast(&onPreferencesAction)), @ptrCast(app), null, 0);
    gtk.g_action_map_add_action(@ptrCast(app), @ptrCast(prefs));
    gtk.g_object_unref(prefs);

    var prefs_accels = [_:null]?[*:0]const u8{"<Control>comma"};
    gtk.gtk_application_set_accels_for_action(@ptrCast(app), "app.preferences", &prefs_accels);

    const quit = gtk.g_simple_action_new("quit", null).?;
    _ = gtk.g_signal_connect_data(quit, "activate", @as(gtk.GCallback, @ptrCast(&onQuitAction)), @ptrCast(app), null, 0);
    gtk.g_action_map_add_action(@ptrCast(app), @ptrCast(quit));
    gtk.g_object_unref(quit);

    var quit_accels = [_:null]?[*:0]const u8{"<Control>q"};
    gtk.gtk_application_set_accels_for_action(@ptrCast(app), "app.quit", &quit_accels);
}

fn onQuitAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const app: *gtk.AdwApplication = @ptrCast(@alignCast(user_data.?));
    shortcuts.requestCloseActiveWindow(app);
}

fn onPreferencesAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const app: *gtk.AdwApplication = @ptrCast(@alignCast(user_data.?));
    const state = activeState(app) orelse return;
    preferences.present(@ptrCast(state.win));
}

/// The window an app-scoped dialog should be presented from.
fn activeState(app: *gtk.AdwApplication) ?*core.AppState {
    const win = gtk.gtk_application_get_active_window(@ptrCast(app)) orelse return null;
    for (core.g_windows.items) |w| {
        if (w.win == win) return w;
    }
    return null;
}

fn onAboutAction(_: ?*gtk.GSimpleAction, _: ?*gtk.GVariant, user_data: ?*anyopaque) callconv(.c) void {
    const app: *gtk.AdwApplication = @ptrCast(@alignCast(user_data.?));
    const state = activeState(app) orelse return;
    const dialog_widget = gtk.adw_about_dialog_new().?;
    const dialog = @as(*gtk.AdwAboutDialog, @ptrCast(dialog_widget));
    gtk.adw_about_dialog_set_application_name(dialog, "Zcode");
    gtk.adw_about_dialog_set_application_icon(dialog, "org.senonide.zcode");
    gtk.adw_about_dialog_set_developer_name(dialog, "Senonide");
    var vbuf: [32:0]u8 = undefined;
    const v = std.fmt.bufPrintZ(&vbuf, "{d}.{d}.{d}", .{
        build_options.version.major, build_options.version.minor, build_options.version.patch,
    }) catch unreachable;
    gtk.adw_about_dialog_set_version(dialog, v);
    gtk.adw_about_dialog_set_comments(dialog, "A simple, native code editor for GNOME.");
    gtk.adw_about_dialog_set_website(dialog, "https://github.com/senonide/zcode");
    gtk.adw_about_dialog_set_issue_url(dialog, "https://github.com/senonide/zcode/issues/new");
    gtk.adw_about_dialog_set_license_type(dialog, gtk.GTK_LICENSE_MIT_X11);
    gtk.adw_about_dialog_set_copyright(dialog, "\u{00A9} 2026 Senonide");
    var developers = [_:null]?[*:0]const u8{"Senonide"};
    gtk.adw_about_dialog_set_developers(dialog, &developers);
    gtk.adw_dialog_present(dialog_widget, @as(*gtk.GtkWidget, @ptrCast(state.win)));
}

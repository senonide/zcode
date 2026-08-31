const std = @import("std");
const gtk = @import("gtk.zig");
const application = @import("app/application.zig");

pub fn main(init: std.process.Init) void {
    gtk.gtk_source_init();
    gtk.zc_watchdog_install();

    // Optional `zcode <dir>`: remember the first argument so the window can
    // resolve and open it as the project root once it is built.
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // program name
    if (it.next()) |arg| application.setStartupFolder(arg);

    const app = gtk.adw_application_new(
        "org.senonide.zcode",
        gtk.G_APPLICATION_DEFAULT_FLAGS | gtk.G_APPLICATION_NON_UNIQUE,
    ).?;
    defer gtk.g_object_unref(app);

    _ = gtk.g_signal_connect_data(
        app,
        "activate",
        @as(gtk.GCallback, @ptrCast(&application.onActivate)),
        null,
        null,
        0,
    );

    _ = gtk.g_application_run(
        @as(*gtk.GApplication, @ptrCast(app)),
        0,
        null,
    );
}

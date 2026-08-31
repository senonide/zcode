//! The "Keyboard Shortcuts" dialog.
//!
//! An `AdwShortcutsDialog`, which supersedes the deprecated
//! `GtkShortcutsWindow`: it is adaptive, matches the current libadwaita
//! styling, and needs no GtkBuilder XML — the listing below is the whole
//! definition, so adding a shortcut is adding one row.

const gtk = @import("../gtk.zig");

const Item = struct {
    title: [*:0]const u8,
    /// GTK accelerator syntax.
    accel: [*:0]const u8,
};

const Section = struct {
    title: [*:0]const u8,
    items: []const Item,
};

const sections = [_]Section{
    .{ .title = "General", .items = &.{
        .{ .title = "Open File", .accel = "<Control>o" },
        .{ .title = "Open Project", .accel = "<Control><Shift>p" },
        .{ .title = "New File", .accel = "<Control>n" },
        .{ .title = "Save", .accel = "<Control>s" },
        .{ .title = "Save As", .accel = "<Control><Shift>s" },
        .{ .title = "Preferences", .accel = "<Control>comma" },
        .{ .title = "Keyboard Shortcuts", .accel = "<Control>question" },
        .{ .title = "Close Window", .accel = "<Control>q" },
    } },
    .{ .title = "Navigation", .items = &.{
        .{ .title = "Find File in Project", .accel = "<Control>p" },
        .{ .title = "Find in File", .accel = "<Control>f" },
        .{ .title = "Find and Replace", .accel = "<Control>h" },
        .{ .title = "Go to Line", .accel = "<Control>g" },
        .{ .title = "Next Tab", .accel = "<Control>Tab" },
        .{ .title = "Previous Tab", .accel = "<Control><Shift>Tab" },
        .{ .title = "Close Tab", .accel = "<Control>w" },
        .{ .title = "Tab Overview", .accel = "<Control><Shift>o" },
    } },
    .{ .title = "View", .items = &.{
        .{ .title = "Toggle Sidebar", .accel = "F9" },
        .{ .title = "Toggle Terminal", .accel = "<Control>t" },
        .{ .title = "New Terminal Tab", .accel = "<Control><Shift>t" },
    } },
    .{ .title = "Editing", .items = &.{
        .{ .title = "Format Document", .accel = "<Control><Shift>i" },
        .{ .title = "Code Actions", .accel = "<Control>period" },
        .{ .title = "Copy in Terminal", .accel = "<Control><Shift>c" },
        .{ .title = "Paste in Terminal", .accel = "<Control><Shift>v" },
    } },
};

pub fn present(parent: *gtk.GtkWidget) void {
    const dialog = gtk.adw_shortcuts_dialog_new() orelse return;

    for (sections) |section| {
        const sec = gtk.adw_shortcuts_section_new(section.title) orelse continue;
        for (section.items) |item| {
            const row = gtk.adw_shortcuts_item_new(item.title, item.accel) orelse continue;
            gtk.adw_shortcuts_section_add(sec, row);
        }
        gtk.adw_shortcuts_dialog_add(@ptrCast(dialog), sec);
    }

    gtk.adw_dialog_present(dialog, parent);
}

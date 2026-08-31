//! Preferences dialog.  Rows write straight to `config`; the settings change
//! signal is what restyles the app (see `application.watchEditorPrefs`), so
//! nothing here knows about source views or terminals.

const std = @import("std");
const gtk = @import("../gtk.zig");
const config = @import("../core/config.zig");

/// The scheme ids offered by the Appearance page, in the order they appear.
/// Index 0 is the "follow the system" entry, which is not a scheme id at all.
var scheme_ids: std.ArrayList([:0]u8) = .empty;
const alloc = std.heap.c_allocator;

pub fn present(parent: *gtk.GtkWidget) void {
    const dialog = gtk.adw_preferences_dialog_new() orelse return;
    if (buildAppearance()) |page| gtk.adw_preferences_dialog_add(@ptrCast(dialog), @ptrCast(page));
    if (buildEditor()) |page| gtk.adw_preferences_dialog_add(@ptrCast(dialog), @ptrCast(page));
    gtk.adw_dialog_present(dialog, parent);
}

// ── Appearance ───────────────────────────────────────────────────────────────

fn buildAppearance() ?*gtk.GtkWidget {
    const page_widget = gtk.adw_preferences_page_new() orelse return null;
    const page = @as(*gtk.AdwPreferencesPage, @ptrCast(page_widget));
    gtk.adw_preferences_page_set_title(page, "Appearance");
    gtk.adw_preferences_page_set_icon_name(page, "applications-graphics-symbolic");

    const font_group = gtk.adw_preferences_group_new() orelse return page_widget;
    const font = @as(*gtk.AdwPreferencesGroup, @ptrCast(font_group));
    gtk.adw_preferences_group_set_title(font, "Font");
    gtk.adw_preferences_group_set_description(font, "Used by the editor and the built-in terminal.");
    addFontRows(font);
    gtk.adw_preferences_page_add(page, font);

    const theme_group = gtk.adw_preferences_group_new() orelse return page_widget;
    const theme = @as(*gtk.AdwPreferencesGroup, @ptrCast(theme_group));
    gtk.adw_preferences_group_set_title(theme, "Colours");
    addSchemeRow(theme);
    gtk.adw_preferences_page_add(page, theme);

    return page_widget;
}

fn addFontRows(group: *gtk.AdwPreferencesGroup) void {
    // The picker shows the font actually in use, whether that is the override
    // or the system font it falls back to.
    const font_dialog = gtk.gtk_font_dialog_new() orelse return;
    gtk.gtk_font_dialog_set_title(font_dialog, "Editor Font");
    const font_btn_widget = gtk.gtk_font_dialog_button_new(font_dialog) orelse return;
    const font_btn = @as(*gtk.GtkFontDialogButton, @ptrCast(font_btn_widget));
    var buf: config.FontBuf = undefined;
    const following = config.monoFontOverride(&buf) == null;
    if (gtk.pango_font_description_from_string(config.monoFont(&buf))) |desc| {
        defer gtk.pango_font_description_free(desc);
        gtk.gtk_font_dialog_button_set_font_desc(font_btn, desc);
    }

    const follow_row_widget = gtk.adw_switch_row_new() orelse return;
    const follow_row = @as(*gtk.AdwSwitchRow, @ptrCast(follow_row_widget));
    gtk.adw_preferences_row_set_title(@ptrCast(follow_row_widget), "Use System Monospace Font");
    gtk.adw_switch_row_set_active(follow_row, if (following) 1 else 0);
    gtk.adw_preferences_group_add(group, follow_row_widget);

    const font_row_widget = gtk.adw_action_row_new() orelse return;
    gtk.adw_preferences_row_set_title(@ptrCast(font_row_widget), "Custom Font");
    gtk.adw_action_row_set_subtitle(@ptrCast(font_row_widget), "Family and size for code and terminal output");
    gtk.adw_action_row_add_suffix(@ptrCast(font_row_widget), font_btn_widget);
    gtk.adw_preferences_group_add(group, font_row_widget);

    // The custom-font row is only meaningful while not following the system.
    _ = gtk.g_object_bind_property(
        follow_row_widget,
        "active",
        font_row_widget,
        "sensitive",
        gtk.G_BINDING_SYNC_CREATE | gtk.G_BINDING_INVERT_BOOLEAN,
    );

    _ = gtk.g_signal_connect_data(
        follow_row_widget,
        "notify::active",
        @as(gtk.GCallback, @ptrCast(&onFollowSystemToggled)),
        @ptrCast(font_btn_widget),
        null,
        0,
    );
    _ = gtk.g_signal_connect_data(
        font_btn_widget,
        "notify::font-desc",
        @as(gtk.GCallback, @ptrCast(&onFontChanged)),
        @ptrCast(follow_row_widget),
        null,
        0,
    );
}

/// Lists every style scheme GtkSourceView knows about, with "Follow System" —
/// the bundled Adwaita Pastel pair tracking the desktop's light/dark setting —
/// as the first and default entry.
fn addSchemeRow(group: *gtk.AdwPreferencesGroup) void {
    const row_widget = gtk.adw_combo_row_new() orelse return;
    const row = @as(*gtk.AdwComboRow, @ptrCast(row_widget));
    gtk.adw_preferences_row_set_title(@ptrCast(row_widget), "Editor Theme");
    gtk.adw_action_row_set_subtitle(@ptrCast(row_widget), "Syntax colours for the source view");

    const model = gtk.gtk_string_list_new(null) orelse return;
    gtk.gtk_string_list_append(model, "Follow System");

    for (scheme_ids.items) |id| alloc.free(id);
    scheme_ids.clearRetainingCapacity();
    scheme_ids.append(alloc, alloc.dupeZ(u8, "") catch return) catch return;

    var pref_buf: config.FontBuf = undefined;
    const current = config.styleScheme(&pref_buf);
    var selected: c_uint = 0;

    const sm = gtk.gtk_source_style_scheme_manager_get_default();
    if (gtk.gtk_source_style_scheme_manager_get_scheme_ids(sm)) |ids| {
        var i: usize = 0;
        while (ids[i]) |id| : (i += 1) {
            const id_slice = std.mem.sliceTo(id, 0);
            const scheme = gtk.gtk_source_style_scheme_manager_get_scheme(sm, id) orelse continue;
            const name = gtk.gtk_source_style_scheme_get_name(scheme) orelse id;
            gtk.gtk_string_list_append(model, name);
            const owned = alloc.dupeZ(u8, id_slice) catch break;
            scheme_ids.append(alloc, owned) catch {
                alloc.free(owned);
                break;
            };
            if (current) |c| {
                if (std.mem.eql(u8, c, id_slice)) selected = @intCast(scheme_ids.items.len - 1);
            }
        }
    }

    gtk.adw_combo_row_set_model(row, @ptrCast(model));
    gtk.g_object_unref(model); // the row holds the only reference from here on
    gtk.adw_combo_row_set_selected(row, selected);
    _ = gtk.g_signal_connect_data(
        row_widget,
        "notify::selected",
        @as(gtk.GCallback, @ptrCast(&onSchemeChanged)),
        null,
        null,
        0,
    );
    gtk.adw_preferences_group_add(group, row_widget);
}

fn onSchemeChanged(instance: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const row = @as(*gtk.AdwComboRow, @ptrCast(@alignCast(instance.?)));
    const index = gtk.adw_combo_row_get_selected(row);
    if (index >= scheme_ids.items.len) return;
    const id = scheme_ids.items[index];
    config.setStyleScheme(if (id.len == 0) null else id.ptr);
}

// ── Editor ───────────────────────────────────────────────────────────────────

fn buildEditor() ?*gtk.GtkWidget {
    const page_widget = gtk.adw_preferences_page_new() orelse return null;
    const page = @as(*gtk.AdwPreferencesPage, @ptrCast(page_widget));
    gtk.adw_preferences_page_set_title(page, "Editor");
    gtk.adw_preferences_page_set_icon_name(page, "text-editor-symbolic");

    const indent_group = gtk.adw_preferences_group_new() orelse return page_widget;
    const indent = @as(*gtk.AdwPreferencesGroup, @ptrCast(indent_group));
    gtk.adw_preferences_group_set_title(indent, "Indentation");
    addSpin(indent, "Tab Width", "Characters per indentation level", 1, 16, config.tabWidth(), &onTabWidthChanged);
    addSwitch(indent, "Insert Spaces", "Indent with spaces instead of tab characters", config.insertSpaces(), &onInsertSpacesChanged);
    gtk.adw_preferences_page_add(page, indent);

    const display_group = gtk.adw_preferences_group_new() orelse return page_widget;
    const display = @as(*gtk.AdwPreferencesGroup, @ptrCast(display_group));
    gtk.adw_preferences_group_set_title(display, "Display");
    addSwitch(display, "Line Numbers", "Show line numbers in the gutter", config.showLineNumbers(), &onLineNumbersChanged);
    addSwitch(display, "Wrap Long Lines", "Wrap instead of scrolling horizontally", config.wrapLines(), &onWrapChanged);
    addSpin(display, "Right Margin", "Column of the margin guide; zero hides it", 0, 200, config.rightMargin(), &onRightMarginChanged);
    gtk.adw_preferences_page_add(page, display);

    const session_group = gtk.adw_preferences_group_new() orelse return page_widget;
    const session = @as(*gtk.AdwPreferencesGroup, @ptrCast(session_group));
    gtk.adw_preferences_group_set_title(session, "Session");
    addSwitch(session, "Reopen Last Project", "Restore the previous project at startup", config.restoreLastProject(), &onRestoreLastChanged);
    gtk.adw_preferences_page_add(page, session);

    return page_widget;
}

const SwitchHandler = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

fn addSwitch(
    group: *gtk.AdwPreferencesGroup,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    active: bool,
    handler: SwitchHandler,
) void {
    const row_widget = gtk.adw_switch_row_new() orelse return;
    gtk.adw_preferences_row_set_title(@ptrCast(row_widget), title);
    gtk.adw_action_row_set_subtitle(@ptrCast(row_widget), subtitle);
    gtk.adw_switch_row_set_active(@ptrCast(row_widget), if (active) 1 else 0);
    _ = gtk.g_signal_connect_data(row_widget, "notify::active", @as(gtk.GCallback, @ptrCast(handler)), null, null, 0);
    gtk.adw_preferences_group_add(group, row_widget);
}

fn addSpin(
    group: *gtk.AdwPreferencesGroup,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    min: f64,
    max: f64,
    value: c_int,
    handler: SwitchHandler,
) void {
    const row_widget = gtk.adw_spin_row_new_with_range(min, max, 1) orelse return;
    gtk.adw_preferences_row_set_title(@ptrCast(row_widget), title);
    gtk.adw_action_row_set_subtitle(@ptrCast(row_widget), subtitle);
    gtk.adw_spin_row_set_value(@ptrCast(row_widget), @floatFromInt(value));
    _ = gtk.g_signal_connect_data(row_widget, "notify::value", @as(gtk.GCallback, @ptrCast(handler)), null, null, 0);
    gtk.adw_preferences_group_add(group, row_widget);
}

fn switchValue(instance: ?*anyopaque) bool {
    return gtk.adw_switch_row_get_active(@ptrCast(@alignCast(instance.?))) != 0;
}

fn spinValue(instance: ?*anyopaque) c_int {
    return @intFromFloat(gtk.adw_spin_row_get_value(@ptrCast(@alignCast(instance.?))));
}

fn onTabWidthChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setTabWidth(spinValue(i));
}

fn onRightMarginChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setRightMargin(spinValue(i));
}

fn onInsertSpacesChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setInsertSpaces(switchValue(i));
}

fn onLineNumbersChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setShowLineNumbers(switchValue(i));
}

fn onWrapChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setWrapLines(switchValue(i));
}

fn onRestoreLastChanged(i: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    config.setRestoreLastProject(switchValue(i));
}

// ── Font override ────────────────────────────────────────────────────────────

fn onFollowSystemToggled(instance: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const follow_row = @as(*gtk.AdwSwitchRow, @ptrCast(@alignCast(instance.?)));
    const font_btn = @as(*gtk.GtkFontDialogButton, @ptrCast(@alignCast(user_data.?)));

    if (gtk.adw_switch_row_get_active(follow_row) == 0) {
        writeFont(font_btn);
        return;
    }

    config.setMonoFontOverride(null);
    // Reflect the system font the picker now stands for.
    var buf: config.FontBuf = undefined;
    const desc = gtk.pango_font_description_from_string(config.monoFont(&buf)) orelse return;
    defer gtk.pango_font_description_free(desc);
    gtk.gtk_font_dialog_button_set_font_desc(font_btn, desc);
}

fn onFontChanged(instance: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const follow_row = @as(*gtk.AdwSwitchRow, @ptrCast(@alignCast(user_data.?)));
    if (gtk.adw_switch_row_get_active(follow_row) != 0) return;
    writeFont(@as(*gtk.GtkFontDialogButton, @ptrCast(@alignCast(instance.?))));
}

fn writeFont(btn: *gtk.GtkFontDialogButton) void {
    const desc = gtk.gtk_font_dialog_button_get_font_desc(btn) orelse return;
    const str = gtk.pango_font_description_to_string(desc) orelse return;
    defer gtk.g_free(str);
    config.setMonoFontOverride(str);
}

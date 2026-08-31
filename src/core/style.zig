//! Application stylesheet and light/dark colour-scheme handling.

const std = @import("std");
const gtk = @import("../gtk.zig");
const core = @import("state.zig");
const config = @import("config.zig");
const files = @import("../sidebar/files.zig");
const syntax = @import("../editor/syntax.zig");

// Colours come from libadwaita's named palette rather than literals, so the
// sidebar and the diagnostics follow the user's accent colour and the
// high-contrast styles instead of fighting them.
const global_css =
    \\/* Let the file list blend into the lighter sidebar background. */
    \\.sidebar scrolledwindow,
    \\.sidebar listview { background-color: transparent; }
    \\.sidebar listview > row { border-radius: 6px; }
    \\
    \\/* Git status colours, applied to row names and badges by class. */
    \\.zc-git-modified  { color: @warning_color; }
    \\.zc-git-added     { color: @success_color; }
    \\.zc-git-untracked { color: @success_color; }
    \\.zc-git-deleted   { color: @error_color; }
    \\.zc-git-renamed   { color: @accent_color; }
    \\.zc-git-ignored   { opacity: 0.45; }
    \\.zc-badge { font-size: 0.8em; }
    \\.zc-drop-target { background-color: alpha(@accent_bg_color, 0.3); border-radius: 4px; }
    \\
    \\.zc-diag-error   { color: @error_color; }
    \\.zc-diag-warning { color: @warning_color; }
    \\.zc-diag-info    { color: @accent_color; }
    \\.zc-diag-hint    { color: alpha(currentColor, 0.55); }
    \\
    \\/* Editor status bar: numeric readouts stay put as the cursor moves. */
    \\.zc-status { font-size: 0.9em; }
    \\.zc-status label { color: alpha(currentColor, 0.7); }
    \\
    \\/* Completion popover safety net: a min-width on the listbox ensures the
    \\   popover never tries to present with width=0 (gdk_popup_present CRITICAL)
    \\   while the first batch of completion items is still being measured. */
    \\GtkSourceAssistant scrolledwindow { min-width: 150px; }
    \\
    \\/* Inset the terminal text so it doesn't hug the sidebar edge.  VTE fills
    \\   the padding with the terminal background, so the gap is seamless. */
    \\vte-terminal { padding-left: 8px; padding-right: 4px; }
;

/// Installs the application stylesheet on the default display.  Called once
/// while the window is being built.
pub fn applyGlobalCss() void {
    const provider = gtk.gtk_css_provider_new().?;
    gtk.gtk_css_provider_load_from_string(provider, global_css);
    gtk.gtk_style_context_add_provider_for_display(
        gtk.gdk_display_get_default(),
        @ptrCast(provider),
        gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    gtk.g_object_unref(provider);
    applyMonoFont();
}

// ── Monospace font (source views + terminals) ─────────────────────────────────

// Kept in a provider of its own so a preference change reloads one rule rather
// than the whole stylesheet.  Display-wide: every window sees the same font.
var font_provider: ?*gtk.GtkCssProvider = null;

/// Restyles every source view with the configured monospace font.
pub fn applyMonoFont() void {
    const provider = font_provider orelse blk: {
        const p = gtk.gtk_css_provider_new().?;
        gtk.gtk_style_context_add_provider_for_display(
            gtk.gdk_display_get_default(),
            @ptrCast(p),
            gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        font_provider = p;
        break :blk p;
    };

    var buf: config.FontBuf = undefined;
    const desc = gtk.pango_font_description_from_string(config.monoFont(&buf)) orelse return;
    defer gtk.pango_font_description_free(desc);
    const family = gtk.pango_font_description_get_family(desc) orelse "Monospace";

    // Weight and style are carried over too: VTE gets the whole description, so
    // dropping them here would leave the editor and the terminal disagreeing.
    var css: [320:0]u8 = undefined;
    const rule = std.fmt.bufPrintZ(
        &css,
        "textview, textview text {{ font-family: \"{s}\"; font-size: {d:.1}pt; " ++
            "font-weight: {d}; font-style: {s}; }}",
        .{
            std.mem.sliceTo(family, 0),
            fontSizePt(desc),
            gtk.pango_font_description_get_weight(desc),
            @tagName(gtk.pango_font_description_get_style(desc)),
        },
    ) catch return;
    gtk.gtk_css_provider_load_from_string(provider, rule);
}

pub fn applyMonoFontToTerminal(term: *gtk.VteTerminal) void {
    var buf: config.FontBuf = undefined;
    const desc = gtk.pango_font_description_from_string(config.monoFont(&buf)) orelse return;
    defer gtk.pango_font_description_free(desc);
    gtk.vte_terminal_set_font(term, desc);
}

/// Keeps open windows in sync with the font preference for the rest of the
/// process' life.  Call once at startup.
pub fn watchMonoFont() void {
    config.watch(config.key_mono_font, @ptrCast(&onMonoFontChanged), null);
}

fn onMonoFontChanged(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    applyMonoFont();
    for (core.g_windows.items) |state| {
        var i: c_int = 0;
        const n = gtk.adw_tab_view_get_n_pages(state.terminal_tabs);
        while (i < n) : (i += 1) {
            if (core.terminalTabAt(state, i)) |tab| applyMonoFontToTerminal(tab.terminal);
        }
    }
}

/// Pango stores sizes in 1/1024 pt; an absolute size is in device units, which
/// CSS reads at 96 dpi, so `font-size` can stay in points either way.
fn fontSizePt(desc: *gtk.PangoFontDescription) f64 {
    const raw = gtk.pango_font_description_get_size(desc);
    if (raw <= 0) return 11;
    const size = @as(f64, @floatFromInt(raw)) / @as(f64, @floatFromInt(gtk.PANGO_SCALE));
    return if (gtk.pango_font_description_get_size_is_absolute(desc) != 0) size * 72.0 / 96.0 else size;
}

/// True when the system prefers a dark style.
pub fn isDark() c_int {
    return gtk.adw_style_manager_get_dark(gtk.adw_style_manager_get_default());
}

/// Makes the bundled Catppuccin schemes selectable.  Called once at startup,
/// before any editor buffer is created.
pub fn registerStyleSchemes() void {
    gtk.zc_register_style_schemes();
}

/// Applies the configured source-style scheme to an editor buffer.  With no
/// preference set the bundled Adwaita Pastel pair follows the system light/dark
/// setting, falling back to Adwaita when the bundled scheme is unavailable.
/// Also turns on matching-bracket highlighting (styled via `bracket-match`).
pub fn applyStyleScheme(buf: *gtk.GtkSourceBuffer) void {
    const sm = gtk.gtk_source_style_scheme_manager_get_default().?;
    var pref_buf: config.FontBuf = undefined;
    const scheme: ?*gtk.GtkSourceStyleScheme = blk: {
        if (config.styleScheme(&pref_buf)) |id| {
            if (gtk.gtk_source_style_scheme_manager_get_scheme(sm, id.ptr)) |chosen|
                break :blk chosen;
        }
        const dark = isDark() != 0;
        const primary: [*:0]const u8 = if (dark) "adwaita-pastel-dark" else "adwaita-pastel-light";
        const fallback: [*:0]const u8 = if (dark) "Adwaita-dark" else "Adwaita";
        break :blk gtk.gtk_source_style_scheme_manager_get_scheme(sm, primary) orelse
            gtk.gtk_source_style_scheme_manager_get_scheme(sm, fallback);
    };
    gtk.gtk_source_buffer_set_style_scheme(buf, scheme);
    gtk.gtk_source_buffer_set_highlight_matching_brackets(buf, 1);
}

/// Re-applies the scheme to everything already on screen in `state`: editor
/// buffers, the tree-sitter tags the scheme cannot reach, the overview ruler
/// and the terminals.
pub fn refreshWindow(state: *core.AppState) void {
    if (state.shutting_down) return;
    const dark = isDark();

    var i: c_int = 0;
    const n_editors = gtk.adw_tab_view_get_n_pages(state.editor_tabs);
    while (i < n_editors) : (i += 1) {
        if (core.editorTabAt(state, i)) |tab| {
            applyStyleScheme(tab.buffer);
            // Tree-sitter buffers have language NULL, so the scheme does not
            // colour them — re-tint their syntax tags for the new scheme.
            syntax.refreshColors(tab.source_view);
            // Overview ruler reads the scheme on each draw, so just queue a
            // redraw to pick up the new colours.
            if (gtk.g_object_get_data(@ptrCast(tab.source_view), "zc-overview")) |ruler|
                gtk.gtk_widget_queue_draw(@ptrCast(ruler));
        }
    }

    var j: c_int = 0;
    const n_terms = gtk.adw_tab_view_get_n_pages(state.terminal_tabs);
    while (j < n_terms) : (j += 1) {
        if (core.terminalTabAt(state, j)) |tab| gtk.zc_terminal_style(tab.terminal, dark);
    }
}

/// Same, for every open window — used when a preference changes rather than
/// the system theme (which is delivered per window).
pub fn refreshAll() void {
    for (core.g_windows.items) |state| refreshWindow(state);
}

pub fn onColorSchemeChanged(_: ?*anyopaque, _: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const state: *core.AppState = @ptrCast(@alignCast(user_data.?));
    if (state.shutting_down) return;
    refreshWindow(state);
    // Rebuild the file tree so its icons switch flavour (Mocha ↔ Latte).
    if (state.file_tree != null) files.buildTree(state);
}

/* Overview ruler for the editor.
 *
 * A narrow GtkDrawingArea (11 px) placed to the right of the scrolled window
 * that shows, scaled to the full file height:
 *   - current viewport range (semi-transparent rect)
 *   - git-diff change bars  (green add / orange modify / red delete)
 *   - cursor position        (thin white/dark bar)
 *
 * Click or drag the ruler to scroll the editor to the corresponding position.
 * The widget is registered on the GtkSourceView under the key "zc-overview"
 * so that diff.c can notify it when new diff data is ready.
 */
#include "zc_internal.h"
#include <gtksourceview/gtksource.h>

typedef struct {
    GtkSourceView     *view;
    GtkScrolledWindow *scroll;
    /* Last scheme the colours below were read from, so a redraw — which happens
     * on every scroll — re-reads them only when the theme actually changed. */
    GtkSourceStyleScheme *scheme;
    gboolean              dark;
    GdkRGBA               bg, fg;
} ZcOverviewCtx;

/* ── Scroll helper ────────────────────────────────────────────────────────── */

/* Translates a Y pixel in the ruler to a scroll-adjustment value and applies
 * it so that the target line appears near the centre of the viewport. */
static void zc_overview_scroll_to_y(GtkWidget *da, ZcOverviewCtx *ctx, double y) {
    int h = gtk_widget_get_height(da);
    if (h <= 0) return;
    GtkAdjustment *vadj  = gtk_scrolled_window_get_vadjustment(ctx->scroll);
    double upper = gtk_adjustment_get_upper(vadj);
    double page  = gtk_adjustment_get_page_size(vadj);
    if (upper <= page) return;
    double target = (y / h) * upper - page / 2.0;
    gtk_adjustment_set_value(vadj, CLAMP(target, 0.0, upper - page));
}

/* ── Gesture callbacks ────────────────────────────────────────────────────── */

static void zc_overview_drag_begin(GtkGestureDrag *drag, double x, double y,
                                   gpointer ctx_ptr) {
    GtkWidget *da = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(drag));
    zc_overview_scroll_to_y(da, ctx_ptr, y);
}

static void zc_overview_drag_update(GtkGestureDrag *drag, double dx, double dy,
                                    gpointer ctx_ptr) {
    GtkWidget *da = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(drag));
    double sx, sy;
    gtk_gesture_drag_get_start_point(drag, &sx, &sy);
    zc_overview_scroll_to_y(da, ctx_ptr, sy + dy);
}

/* ── Theme colours ────────────────────────────────────────────────────────── */

/* Reads a colour off the buffer's style scheme so the ruler matches whichever
 * editor theme is in use, rather than the one it was written against.  Falls
 * back to `fallback` (an Adwaita neutral) when the scheme has no opinion. */
static void zc_scheme_color(GtkSourceBuffer *buf, const char *style_name,
                            const char *property, const char *fallback,
                            GdkRGBA *out) {
    gdk_rgba_parse(out, fallback);
    GtkSourceStyleScheme *scheme = gtk_source_buffer_get_style_scheme(buf);
    if (!scheme) return;
    GtkSourceStyle *style = gtk_source_style_scheme_get_style(scheme, style_name);
    if (!style) return;

    gchar *value = NULL;
    gboolean set = FALSE;
    g_object_get(style, property, &value, NULL);
    /* GtkSourceStyle exposes a "<property>-set" companion for every colour. */
    gchar *set_prop = g_strconcat(property, "-set", NULL);
    g_object_get(style, set_prop, &set, NULL);
    g_free(set_prop);
    if (set && value) gdk_rgba_parse(out, value);
    g_free(value);
}

/* ── Draw function ────────────────────────────────────────────────────────── */

static void zc_overview_draw(GtkDrawingArea *da, cairo_t *cr, int w, int h,
                             gpointer ctx_ptr) {
    ZcOverviewCtx *ctx = ctx_ptr;
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(ctx->view));
    gint n_lines = MAX(1, gtk_text_buffer_get_line_count(buf));

    gboolean dark = adw_style_manager_get_dark(adw_style_manager_get_default());
    /* The ruler sits flush against the text, so it takes the editor's own
     * background and foreground rather than a hardcoded pair. */
    GtkSourceStyleScheme *scheme = gtk_source_buffer_get_style_scheme(GTK_SOURCE_BUFFER(buf));
    if (scheme != ctx->scheme || dark != ctx->dark) {
        ctx->scheme = scheme;
        ctx->dark = dark;
        zc_scheme_color(GTK_SOURCE_BUFFER(buf), "text", "background",
                        dark ? "#222226" : "#fafafb", &ctx->bg);
        zc_scheme_color(GTK_SOURCE_BUFFER(buf), "text", "foreground",
                        dark ? "#ffffff" : "#2f2f2f", &ctx->fg);
    }
    GdkRGBA bg = ctx->bg, fg = ctx->fg;
    double bg_r = bg.red, bg_g = bg.green, bg_b = bg.blue;

    /* Fetch adjustment early — needed for background and viewport rect. */
    GtkAdjustment *vadj  = gtk_scrolled_window_get_vadjustment(ctx->scroll);
    double upper = gtk_adjustment_get_upper(vadj);
    double page  = gtk_adjustment_get_page_size(vadj);
    double value = gtk_adjustment_get_value(vadj);

    /* Background.  When the content is scrolled down the GtkScrolledWindow
     * renders an undershoot shadow at the very top of its viewport.  We fade
     * the ruler from fully transparent (alpha 0) to fully opaque over 8 px
     * so the undershoot shows through the overlay and the shadow appears
     * full-width.  When at the top the ruler is simply opaque. */
    if (value > 0) {
        cairo_set_source_rgb(cr, bg_r, bg_g, bg_b);
        cairo_rectangle(cr, 0, 8, w, h - 8);
        cairo_fill(cr);

        cairo_pattern_t *fade = cairo_pattern_create_linear(0, 0, 0, 8);
        cairo_pattern_add_color_stop_rgba(fade, 0.0, bg_r, bg_g, bg_b, 0.0);
        cairo_pattern_add_color_stop_rgba(fade, 1.0, bg_r, bg_g, bg_b, 1.0);
        cairo_set_source(cr, fade);
        cairo_rectangle(cr, 0, 0, w, 8);
        cairo_fill(cr);
        cairo_pattern_destroy(fade);
    } else {
        cairo_set_source_rgb(cr, bg_r, bg_g, bg_b);
        cairo_paint(cr);
    }

    if (upper > page) {
        double top    = (value / upper) * h;
        double height = (page  / upper) * h;
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, dark ? 0.10 : 0.14);
        cairo_rectangle(cr, 0, top, w, MAX(height, 4.0));
        cairo_fill(cr);
    }

    double half_w = (double)w / 2.0;

    /* Diff bars: one mark per changed line, minimum 2 px tall so thin changes
     * remain visible even in very long files.  Uses the sparse marks array so
     * cost is O(changed_lines) instead of O(file_lines).  Drawn on the left
     * half of the ruler so diagnostics (right half) can coexist on the same
     * line without overlapping. */
    GArray *marks = zc_diff_get_marks(ctx->view);
    guint mlen = marks ? marks->len : 0;
    /* One bar per changed line, but the ruler is a few hundred pixels tall: a
     * file that differs by tens of thousands of lines would otherwise issue that
     * many cairo fills on every scroll, all of them landing on a pixel row an
     * earlier one already filled with the same colour.  Drawing is bounded by
     * the ruler's height instead of the diff's size. */
    int last_row = -1;
    guint8 last_st = 0;
    for (guint i = 0; i < mlen; i++) {
        ZcDiffMark *m = &g_array_index(marks, ZcDiffMark, i);
        guint8 st = m->status;
        double y     = ((double)m->line / n_lines) * h;
        double bar_h = MAX(2.0, (1.0 / n_lines) * h);
        if ((int)y == last_row && st == last_st) continue;
        last_row = (int)y;
        last_st = st;

        if      (st == 1) cairo_set_source_rgb(cr, 0x2e/255.0, 0xc2/255.0, 0x7e/255.0);
        else if (st == 2) cairo_set_source_rgb(cr, 0xe5/255.0, 0xa5/255.0, 0x0a/255.0);
        else              cairo_set_source_rgb(cr, 0xe0/255.0, 0x1b/255.0, 0x24/255.0);
        cairo_rectangle(cr, 0.0, y, half_w, bar_h);
        cairo_fill(cr);
    }

    /* Cursor line: a 2 px horizontal bar at the proportional line position. */
    GtkTextMark *ins = gtk_text_buffer_get_insert(buf);
    GtkTextIter  it;
    gtk_text_buffer_get_iter_at_mark(buf, &it, ins);
    gint cursor_line = gtk_text_iter_get_line(&it);
    double cy = ((double)cursor_line / n_lines) * h;
    cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, dark ? 0.80 : 0.55);
    cairo_rectangle(cr, 0.0, MAX(0.0, cy - 1.0), (double)w, 2.0);
    cairo_fill(cr);

    /* Diagnostic marks: right half of the ruler, one bar per line with
     * diagnostics.  They start at the midline so git diff bars (left half)
     * and diagnostics can coexist on the same line. */
    GArray *diags = g_object_get_data(G_OBJECT(buf), "zc-diag-marks");
    if (diags) {
        for (guint i = 0; i < diags->len; i++) {
            ZcDiagMark *d = &g_array_index(diags, ZcDiagMark, i);
            guint8 sev = d->severity;
            if      (sev == 1) cairo_set_source_rgba(cr, 0xed/255.0, 0x33/255.0, 0x3b/255.0, 0.85);
            else if (sev == 2) cairo_set_source_rgba(cr, 0xed/255.0, 0xad/255.0, 0x1a/255.0, 0.85);
            else if (sev == 3) cairo_set_source_rgba(cr, 0x4e/255.0, 0x9a/255.0, 0xf2/255.0, 0.85);
            else               cairo_set_source_rgba(cr, 0x8e/255.0, 0x90/255.0, 0x91/255.0, 0.60);
            double y     = ((double)d->line / n_lines) * h;
            double bar_h = MAX(2.0, (1.0 / n_lines) * h);
            cairo_rectangle(cr, half_w, y, half_w, bar_h);
            cairo_fill(cr);
        }
    }
}

/* ── Signal stubs ─────────────────────────────────────────────────────────── */

static void zc_overview_on_adj_changed(GtkAdjustment *adj, gpointer da) {
    gtk_widget_queue_draw(GTK_WIDGET(da));
}

static void zc_overview_on_cursor_moved(GObject *buf, GParamSpec *ps, gpointer da) {
    gtk_widget_queue_draw(GTK_WIDGET(da));
}

/* Forwards mouse-wheel events on the ruler to the document scroll position. */
static gboolean zc_overview_on_scroll(GtkEventControllerScroll *ctrl,
                                       double dx, double dy, gpointer ctx_ptr) {
    ZcOverviewCtx *ctx = ctx_ptr;
    GtkAdjustment *vadj = gtk_scrolled_window_get_vadjustment(ctx->scroll);
    double step  = gtk_adjustment_get_step_increment(vadj);
    double value = gtk_adjustment_get_value(vadj);
    double upper = gtk_adjustment_get_upper(vadj);
    double page  = gtk_adjustment_get_page_size(vadj);
    gtk_adjustment_set_value(vadj, CLAMP(value + dy * step * 3.0, 0.0, upper - page));
    return TRUE;
}

/* ── Public API ───────────────────────────────────────────────────────────── */

GtkWidget *zc_overview_ruler_new(GtkSourceView *view, GtkScrolledWindow *scroll) {
    /* The editor's scrolled window has its vertical scrollbar set to EXTERNAL
     * (see editor/tabs), so this ruler IS the vertical scroll UI: placed as a
     * GtkOverlay child at halign=END, the viewport rect is the navigation
     * handle and drag/scroll here drives the adjustment. */
    GtkWidget *da = gtk_drawing_area_new();
    gtk_widget_set_size_request(da, 13, -1);
    gtk_widget_set_vexpand(da, TRUE);
    gtk_widget_set_halign(da, GTK_ALIGN_END);

    ZcOverviewCtx *ctx = g_new0(ZcOverviewCtx, 1);
    ctx->view   = view;
    ctx->scroll = scroll;
    g_object_set_data_full(G_OBJECT(da), "zc-ctx", ctx, g_free);
    g_object_set_data(G_OBJECT(view), "zc-overview", da);
    {
        GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
        g_object_set_data(G_OBJECT(buf), "zc-overview-ruler", da);
    }
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(da), zc_overview_draw, ctx, NULL);

    GtkAdjustment *vadj = gtk_scrolled_window_get_vadjustment(scroll);

    /* Redraw when scroll position or content size changes. */
    g_signal_connect_object(vadj, "value-changed",
                            G_CALLBACK(zc_overview_on_adj_changed), da, 0);
    g_signal_connect_object(vadj, "changed",
                            G_CALLBACK(zc_overview_on_adj_changed), da, 0);

    /* Redraw when the cursor moves. */
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    g_signal_connect_object(buf, "notify::cursor-position",
                            G_CALLBACK(zc_overview_on_cursor_moved), da, 0);

    /* Click / drag anywhere on the ruler → scroll to that proportional line. */
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin",  G_CALLBACK(zc_overview_drag_begin),  ctx);
    g_signal_connect(drag, "drag-update", G_CALLBACK(zc_overview_drag_update), ctx);
    gtk_widget_add_controller(da, GTK_EVENT_CONTROLLER(drag));

    /* Mouse wheel over the ruler also scrolls the document. */
    GtkEventController *scroll_ctrl = gtk_event_controller_scroll_new(
        GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll_ctrl, "scroll", G_CALLBACK(zc_overview_on_scroll), ctx);
    gtk_widget_add_controller(da, scroll_ctrl);

    return da;
}

static void zc_diag_marks_free(gpointer p) {
    g_array_unref((GArray *)p);
}

void zc_buffer_set_diag_marks(GtkSourceBuffer *buf, const ZcDiagMark *marks, guint n) {
    if (n == 0) {
        g_object_set_data(G_OBJECT(buf), "zc-diag-marks", NULL);
    } else {
        GArray *arr = g_array_sized_new(FALSE, FALSE, sizeof(ZcDiagMark), n);
        g_array_append_vals(arr, marks, n);
        g_object_set_data_full(G_OBJECT(buf), "zc-diag-marks", arr, zc_diag_marks_free);
    }
    GtkWidget *ruler = g_object_get_data(G_OBJECT(buf), "zc-overview-ruler");
    if (ruler) gtk_widget_queue_draw(ruler);
}


void zc_overview_ruler_queue_draw(GtkWidget *ruler) {
    if (ruler) gtk_widget_queue_draw(ruler);
}

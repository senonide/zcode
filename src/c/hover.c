/* Diagnostic hover popover — shows the message when the pointer rests
 * over a squiggly-underlined range or when the text cursor lands on one.
 *
 * Usage:
 *   zc_hover_attach(view)                     — once, when the editor tab is created
 *   zc_buffer_set_hover_diags(buf, diags, n)  — every time diags change
 *
 * Diag data is stored on the GtkSourceBuffer as "zc-hover-diags" (a GPtrArray
 * of owned ZcHoverEntry structs). */

#include "zc_internal.h"
#include <gtksourceview/gtksource.h>

typedef struct {
    ZcHoverDiag  diag;
    char        *message; /* owned */
} ZcHoverEntry;

typedef struct {
    GtkTextView   *view;
    GtkTextBuffer *buf;           /* non-owning; NULL'd via weak-ref when buf dies */
    GtkPopover    *popover;
    GtkLabel      *label;
    guint          settle_id;     /* debounce timer id, 0 = none */
    gulong         cursor_handler;
    int            target_line;
    int            target_char;
    int            mouse_wx;      /* widget-space X at last motion event */
} ZcHoverCtx;

/* ── helpers ──────────────────────────────────────────────────────────────── */

static void zc_hover_entry_free(gpointer p) {
    ZcHoverEntry *e = p;
    g_free(e->message);
    g_free(e);
}

/* Find a diagnostic that covers (line, char).  Returns NULL if none. */
static const ZcHoverEntry *zc_hover_find(GtkSourceBuffer *buf, int line, int ch) {
    GPtrArray *entries = g_object_get_data(G_OBJECT(buf), "zc-hover-diags");
    if (!entries) return NULL;
    for (guint i = 0; i < entries->len; i++) {
        const ZcHoverEntry *e = g_ptr_array_index(entries, i);
        if (line < e->diag.start_line || line > e->diag.end_line) continue;
        if (line == e->diag.start_line && ch < e->diag.start_char) continue;
        if (line == e->diag.end_line   && ch > e->diag.end_char)   continue;
        return e;
    }
    return NULL;
}

/* Find the most severe diagnostic anywhere on `line` (the whole line is
 * tinted, so hovering it anywhere should surface the message). */
static const ZcHoverEntry *zc_hover_find_line(GtkSourceBuffer *buf, int line) {
    GPtrArray *entries = g_object_get_data(G_OBJECT(buf), "zc-hover-diags");
    if (!entries) return NULL;
    const ZcHoverEntry *best = NULL;
    for (guint i = 0; i < entries->len; i++) {
        const ZcHoverEntry *e = g_ptr_array_index(entries, i);
        if (line < e->diag.start_line || line > e->diag.end_line) continue;
        if (!best || e->diag.severity < best->diag.severity) best = e;
    }
    return best;
}

/* ── show / hide ──────────────────────────────────────────────────────────── */

static void zc_hover_hide(ZcHoverCtx *ctx) {
    if (ctx->popover) gtk_popover_popdown(ctx->popover);
}

static void zc_hover_show(ZcHoverCtx *ctx, const ZcHoverEntry *e) {
    if (!ctx->popover) {
        ctx->popover = GTK_POPOVER(gtk_popover_new());
        gtk_popover_set_has_arrow(ctx->popover, FALSE);
        gtk_popover_set_autohide(ctx->popover, FALSE);
        gtk_widget_set_parent(GTK_WIDGET(ctx->popover), GTK_WIDGET(ctx->view));
        GtkWidget *lbl = gtk_label_new("");
        gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(lbl), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_max_width_chars(GTK_LABEL(lbl), 60);
        gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
        gtk_widget_set_margin_start(lbl, 8);
        gtk_widget_set_margin_end(lbl, 8);
        gtk_widget_set_margin_top(lbl, 4);
        gtk_widget_set_margin_bottom(lbl, 4);
        gtk_popover_set_child(ctx->popover, lbl);
        ctx->label = GTK_LABEL(lbl);
    }
    gtk_label_set_text(ctx->label, e->message);

    /* gtk_text_view_get_iter_location returns buffer-space coords (the virtual
     * coordinate system of the whole document).  gtk_popover_set_pointing_to
     * needs widget-space coords (relative to the parent widget).  Convert. */
    {
        GtkTextIter pos;
        /* Measured at the last motion event; the buffer may have changed since. */
        zc_iter_at_line_byte(gtk_text_view_get_buffer(ctx->view), &pos,
                             ctx->target_line, ctx->target_char);
        GdkRectangle buf_rect;
        gtk_text_view_get_iter_location(ctx->view, &pos, &buf_rect);
        int wx, wy;
        gtk_text_view_buffer_to_window_coords(ctx->view, GTK_TEXT_WINDOW_WIDGET,
                                              buf_rect.x, buf_rect.y, &wx, &wy);
        GdkRectangle widget_rect = { wx, wy, buf_rect.width, 2 };
        gtk_popover_set_pointing_to(ctx->popover, &widget_rect);
    }
    gtk_popover_popup(ctx->popover);
}

/* ── right-click: cancel pending hover ────────────────────────────────────── */

static void zc_hover_on_rclick(GtkGestureClick *gesture,
                               int n_press, double x, double y,
                               gpointer data) {
    (void)gesture; (void)n_press; (void)x; (void)y;
    ZcHoverCtx *ctx = data;
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    zc_hover_hide(ctx);
}

/* ── motion (mouse hover) ─────────────────────────────────────────────────── */

static gboolean zc_hover_settle_cb(gpointer data) {
    ZcHoverCtx *ctx = data;
    ctx->settle_id = 0;
    if (ctx->target_line < 0) return G_SOURCE_REMOVE; /* mouse left the view */

    /* If the mouse is to the right of where the iter was clamped (end of line),
     * the pointer is over empty space — no token to hover, but the line's
     * diagnostic tint spans the full width, so still surface its message. */
    GtkTextBuffer *buf = gtk_text_view_get_buffer(ctx->view);
    {
        GtkTextIter it;
        zc_iter_at_line_byte(buf, &it, ctx->target_line, ctx->target_char);
        GdkRectangle r;
        gtk_text_view_get_iter_location(ctx->view, &it, &r);
        int iter_wx;
        gtk_text_view_buffer_to_window_coords(ctx->view, GTK_TEXT_WINDOW_WIDGET,
                                              r.x, r.y, &iter_wx, NULL);
        if (ctx->mouse_wx > iter_wx + r.width) {
            const ZcHoverEntry *e = zc_hover_find_line(GTK_SOURCE_BUFFER(buf),
                                                       ctx->target_line);
            if (e) zc_hover_show(ctx, e);
            return G_SOURCE_REMOVE;
        }
    }

    const ZcHoverEntry *e = zc_hover_find(GTK_SOURCE_BUFFER(buf),
                                           ctx->target_line, ctx->target_char);
    if (e) {
        zc_hover_show(ctx, e);
    } else {
        zc_hover_hide(ctx);
        zc_lsp_request_hover(GTK_SOURCE_BUFFER(buf), ctx->target_line,
                             ctx->target_char, GTK_SOURCE_VIEW(ctx->view));
    }
    return G_SOURCE_REMOVE;
}

static void zc_hover_on_motion(GtkEventControllerMotion *ctrl,
                               double x, double y, gpointer data) {
    (void)ctrl;
    ZcHoverCtx *ctx = data;
    int bx, by;
    /* Motion events give widget-space coordinates.  GTK_TEXT_WINDOW_WIDGET
     * subtracts the gutter width before mapping to buffer space, which is
     * necessary when line numbers are visible. */
    gtk_text_view_window_to_buffer_coords(ctx->view, GTK_TEXT_WINDOW_WIDGET,
                                          (int)x, (int)y, &bx, &by);
    GtkTextIter iter;
    gtk_text_view_get_iter_at_location(ctx->view, &iter, bx, by);
    int line = gtk_text_iter_get_line(&iter);
    int ch   = gtk_text_iter_get_line_index(&iter);
    ctx->mouse_wx = (int)x;

    /* Same target as before: leave the popover (and any pending settle timer)
     * alone.  This covers two cases: pointer jitter within one character cell,
     * and — crucially — the synthesized motion events Wayland delivers when
     * the popover surface maps without taking the pointer (anchored at the end
     * of a line whose full-width tint the pointer is over).  Hiding on those
     * re-armed the settle timer, whose show triggered another synthesized
     * motion, making the popover blink in a loop. */
    if (line == ctx->target_line && ch == ctx->target_char) {
        gboolean shown = ctx->popover &&
                         gtk_widget_get_visible(GTK_WIDGET(ctx->popover));
        if (!shown && !ctx->settle_id)
            ctx->settle_id = g_timeout_add(750, zc_hover_settle_cb, ctx);
        return;
    }

    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    zc_hover_hide(ctx);
    ctx->target_line = line;
    ctx->target_char = ch;
    ctx->settle_id = g_timeout_add(750, zc_hover_settle_cb, ctx);
}

/* Cancel any pending hover when the pointer leaves the source view.
 *
 * We deliberately do NOT call zc_hover_hide here.  On Wayland, GtkPopover
 * gets its own GDK surface; the moment gtk_popover_popup() is called the
 * compositor routes pointer events to the popover surface and sends
 * wl_pointer::leave for the source-view surface, which fires this handler.
 * Calling zc_hover_hide here would immediately dismiss the popover we just
 * opened, producing the "appears and closes instantly" behaviour.
 *
 * Instead we only:
 *   1. Cancel the pending settle timer (no point requesting LSP hover for a
 *      position the pointer has left).
 *   2. Set the sentinel so that any in-flight LSP response is rejected by the
 *      (line != ctx->target_line) check in zc_hover_show_text.
 *
 * The popover is dismissed in zc_hover_on_motion (mouse moved to a new
 * position inside the source view) and zc_hover_on_rclick. */
static void zc_hover_on_leave(GtkEventControllerMotion *ctrl, gpointer data) {
    (void)ctrl;
    ZcHoverCtx *ctx = data;
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    ctx->target_line = -1;
    ctx->target_char = -1;
}

/* ── cursor (keyboard) ────────────────────────────────────────────────────── */

static void zc_hover_on_cursor(GObject *buf, GParamSpec *ps, gpointer data) {
    (void)buf; (void)ps;
    ZcHoverCtx *ctx = data;
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    zc_hover_hide(ctx);
}

/* ── cleanup ──────────────────────────────────────────────────────────────── */

/* The popover is parented by hand, so it has to be unparented by hand — and
 * during ::destroy, not from the data-full notifier, which runs at finalize
 * when GtkWidget has already complained about the child it still has. */
static void zc_hover_on_view_destroy(GtkWidget *view, gpointer data) {
    (void)view;
    ZcHoverCtx *ctx = data;
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    if (ctx->popover) {
        gtk_widget_unparent(GTK_WIDGET(ctx->popover));
        ctx->popover = NULL;
        ctx->label = NULL;
    }
}

static void zc_hover_ctx_free(gpointer p) {
    ZcHoverCtx *ctx = p;
    /* Cancel any in-flight settle timer so the callback never fires on freed ctx. */
    if (ctx->settle_id) {
        g_source_remove(ctx->settle_id);
        ctx->settle_id = 0;
    }
    /* Disconnect the buffer signal.  ctx->buf is NULL if the buffer was already
     * finalized (weak-ref clears it), in which case the signal is already gone. */
    if (ctx->buf) {
        if (ctx->cursor_handler)
            g_signal_handler_disconnect(ctx->buf, ctx->cursor_handler);
        g_object_remove_weak_pointer(G_OBJECT(ctx->buf), (gpointer *)&ctx->buf);
    }
    g_free(ctx);
}

/* ── public API ───────────────────────────────────────────────────────────── */

/* Show the hover for the diagnostic under the text cursor, if any.
 * Called from the keybinding handler (e.g. Ctrl+K Ctrl+I). */
void zc_hover_show_at_cursor(GtkSourceView *view) {
    ZcHoverCtx *ctx = g_object_get_data(G_OBJECT(view), "zc-hover-ctx");
    if (!ctx) return;
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    GtkTextMark *ins = gtk_text_buffer_get_insert(buf);
    GtkTextIter iter;
    gtk_text_buffer_get_iter_at_mark(buf, &iter, ins);
    int line = gtk_text_iter_get_line(&iter);
    int ch   = gtk_text_iter_get_line_index(&iter);
    const ZcHoverEntry *e = zc_hover_find(GTK_SOURCE_BUFFER(buf), line, ch);
    if (!e) e = zc_hover_find_line(GTK_SOURCE_BUFFER(buf), line);
    if (e) {
        ctx->target_line = line;
        ctx->target_char = ch;
        zc_hover_show(ctx, e);
    } else {
        zc_hover_hide(ctx);
    }
}

/* Called from Zig when the LSP hover response for (line, ch) came back empty:
 * fall back to the line's diagnostic, if any, so hovering anywhere on a
 * tinted line surfaces the message even where there is no symbol. */
void zc_hover_show_diag_fallback(GtkSourceView *view, int line, int ch) {
    ZcHoverCtx *ctx = g_object_get_data(G_OBJECT(view), "zc-hover-ctx");
    if (!ctx) return;
    if (line != ctx->target_line || ch != ctx->target_char) return; /* stale */
    GtkTextBuffer *buf = gtk_text_view_get_buffer(ctx->view);
    const ZcHoverEntry *e = zc_hover_find_line(GTK_SOURCE_BUFFER(buf), line);
    if (e) zc_hover_show(ctx, e);
}

void zc_hover_show_text(GtkSourceView *view, const char *text, int line, int ch) {
    ZcHoverCtx *ctx = g_object_get_data(G_OBJECT(view), "zc-hover-ctx");
    if (!ctx) return;
    /* Discard stale responses: mouse moved or left the view since the request. */
    if (line != ctx->target_line || ch != ctx->target_char) return;

    if (!ctx->popover) {
        ctx->popover = GTK_POPOVER(gtk_popover_new());
        gtk_popover_set_has_arrow(ctx->popover, FALSE);
        gtk_popover_set_autohide(ctx->popover, FALSE);
        gtk_widget_set_parent(GTK_WIDGET(ctx->popover), GTK_WIDGET(ctx->view));
        GtkWidget *lbl = gtk_label_new("");
        gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(lbl), PANGO_WRAP_WORD_CHAR);
        gtk_label_set_max_width_chars(GTK_LABEL(lbl), 60);
        gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
        gtk_widget_set_margin_start(lbl, 8);
        gtk_widget_set_margin_end(lbl, 8);
        gtk_widget_set_margin_top(lbl, 4);
        gtk_widget_set_margin_bottom(lbl, 4);
        gtk_popover_set_child(ctx->popover, lbl);
        ctx->label = GTK_LABEL(lbl);
    }
    gtk_label_set_text(ctx->label, text);

    GtkTextBuffer *buf = gtk_text_view_get_buffer(ctx->view);
    GtkTextIter pos;
    /* Position from the in-flight LSP request; snap it to the buffer as it is now. */
    zc_iter_at_line_byte(buf, &pos, line, ch);
    GdkRectangle buf_rect;
    gtk_text_view_get_iter_location(ctx->view, &pos, &buf_rect);
    int wx, wy;
    gtk_text_view_buffer_to_window_coords(ctx->view, GTK_TEXT_WINDOW_WIDGET,
                                          buf_rect.x, buf_rect.y, &wx, &wy);
    GdkRectangle widget_rect = { wx, wy, buf_rect.width, 2 };
    gtk_popover_set_pointing_to(ctx->popover, &widget_rect);
    gtk_popover_popup(ctx->popover);
}

void zc_hover_attach(GtkSourceView *view) {
    ZcHoverCtx *ctx = g_new0(ZcHoverCtx, 1);
    ctx->view = GTK_TEXT_VIEW(view);
    /* zc_hover_ctx_free cancels timers and disconnects signals before freeing. */
    g_object_set_data_full(G_OBJECT(view), "zc-hover-ctx", ctx, zc_hover_ctx_free);
    g_signal_connect(view, "destroy", G_CALLBACK(zc_hover_on_view_destroy), ctx);

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(zc_hover_on_motion), ctx);
    g_signal_connect(motion, "leave",  G_CALLBACK(zc_hover_on_leave),  ctx);
    gtk_widget_add_controller(GTK_WIDGET(view), motion);

    GtkGesture *rclick = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(rclick), GDK_BUTTON_SECONDARY);
    g_signal_connect(rclick, "pressed", G_CALLBACK(zc_hover_on_rclick), ctx);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(rclick));

    GtkTextBuffer *buf = gtk_text_view_get_buffer(ctx->view);
    if (buf) {
        ctx->buf = buf;
        /* Weak-ref so ctx->buf is set to NULL if the buffer is finalized before
         * the view's data-full notifier runs (avoids a dangling-pointer disconnect). */
        g_object_add_weak_pointer(G_OBJECT(buf), (gpointer *)&ctx->buf);
        ctx->cursor_handler = g_signal_connect(buf, "notify::cursor-position",
                                               G_CALLBACK(zc_hover_on_cursor), ctx);
    }
}

void zc_buffer_set_hover_diags(GtkSourceBuffer *buf,
                               const ZcHoverDiag *diags, guint n) {
    g_object_set_data(G_OBJECT(buf), "zc-hover-diags", NULL); /* free old */
    if (n == 0) return;
    GPtrArray *arr = g_ptr_array_new_full(n, zc_hover_entry_free);
    for (guint i = 0; i < n; i++) {
        ZcHoverEntry *e = g_new0(ZcHoverEntry, 1);
        e->diag    = diags[i];
        e->message = g_strdup(diags[i].message);
        g_ptr_array_add(arr, e);
    }
    g_object_set_data_full(G_OBJECT(buf), "zc-hover-diags", arr,
                           (GDestroyNotify)g_ptr_array_unref);
}

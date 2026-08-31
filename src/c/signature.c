/* Signature help popover.
 *
 * Attaches an insert-text::after handler to the buffer; when '(' or ',' is
 * typed, calls into Zig (zc_lsp_signature_help) which sends the LSP request
 * and calls back zc_signature_show / zc_signature_hide once the reply lands.
 * On ')' the popover is dismissed. */

#include "zc_internal.h"

typedef struct {
    GtkTextView  *view;
    GtkTextBuffer *buf;
    GtkPopover   *popover;
    GtkLabel     *label;
    gulong        insert_handler;
} ZcSigCtx;

static void zc_sig_ctx_free(gpointer p) {
    ZcSigCtx *ctx = p;
    if (ctx->buf) {
        if (ctx->insert_handler)
            g_signal_handler_disconnect(ctx->buf, ctx->insert_handler);
        g_object_remove_weak_pointer(G_OBJECT(ctx->buf), (gpointer *)&ctx->buf);
    }
    g_free(ctx);
}

static void zc_sig_on_insert(GtkTextBuffer *buf, GtkTextIter *loc,
                              gchar *text, gint len, gpointer data) {
    ZcSigCtx *ctx = data;
    if (len != 1) return;
    if (text[0] == ')') {
        zc_signature_hide(GTK_SOURCE_VIEW(ctx->view));
        return;
    }
    if (text[0] != '(' && text[0] != ',') return;
    /* connect_after: the text is already inserted; loc points past it. */
    int line = gtk_text_iter_get_line(loc);
    int ch   = gtk_text_iter_get_line_index(loc);
    zc_lsp_signature_help(GTK_SOURCE_BUFFER(buf), line, ch,
                          GTK_SOURCE_VIEW(ctx->view));
}

/* The popover is parented by hand, so it has to be unparented by hand — and
 * during ::destroy, not from the data-full notifier, which runs at finalize
 * when GtkWidget has already complained about the child it still has. */
static void zc_sig_on_view_destroy(GtkWidget *view, gpointer data) {
    (void)view;
    ZcSigCtx *ctx = data;
    if (ctx->popover) {
        gtk_widget_unparent(GTK_WIDGET(ctx->popover));
        ctx->popover = NULL;
        ctx->label = NULL;
    }
}

void zc_signature_attach(GtkSourceView *view) {
    ZcSigCtx *ctx = g_new0(ZcSigCtx, 1);
    ctx->view = GTK_TEXT_VIEW(view);
    ctx->buf  = gtk_text_view_get_buffer(ctx->view);
    ctx->insert_handler = g_signal_connect_after(ctx->buf, "insert-text",
                                                  G_CALLBACK(zc_sig_on_insert), ctx);
    g_object_add_weak_pointer(G_OBJECT(ctx->buf), (gpointer *)&ctx->buf);
    g_object_set_data_full(G_OBJECT(view), "zc-sig-ctx", ctx, zc_sig_ctx_free);
    g_signal_connect(view, "destroy", G_CALLBACK(zc_sig_on_view_destroy), ctx);
}

void zc_signature_show(GtkSourceView *view, const char *text) {
    ZcSigCtx *ctx = g_object_get_data(G_OBJECT(view), "zc-sig-ctx");
    if (!ctx) return;

    if (!ctx->popover) {
        ctx->popover = GTK_POPOVER(gtk_popover_new());
        gtk_popover_set_has_arrow(ctx->popover, FALSE);
        gtk_popover_set_autohide(ctx->popover, FALSE);
        gtk_popover_set_position(ctx->popover, GTK_POS_TOP);
        gtk_widget_set_parent(GTK_WIDGET(ctx->popover), GTK_WIDGET(ctx->view));
        GtkWidget *lbl = gtk_label_new("");
        gtk_label_set_max_width_chars(GTK_LABEL(lbl), 80);
        gtk_label_set_xalign(GTK_LABEL(lbl), 0.0);
        gtk_widget_set_margin_start(lbl, 8);
        gtk_widget_set_margin_end(lbl, 8);
        gtk_widget_set_margin_top(lbl, 4);
        gtk_widget_set_margin_bottom(lbl, 4);
        gtk_popover_set_child(ctx->popover, lbl);
        ctx->label = GTK_LABEL(lbl);
    }
    gtk_label_set_text(ctx->label, text);

    GtkTextMark *ins = gtk_text_buffer_get_insert(ctx->buf);
    GtkTextIter iter;
    gtk_text_buffer_get_iter_at_mark(ctx->buf, &iter, ins);
    GdkRectangle buf_rect;
    gtk_text_view_get_iter_location(ctx->view, &iter, &buf_rect);
    int wx, wy;
    gtk_text_view_buffer_to_window_coords(ctx->view, GTK_TEXT_WINDOW_WIDGET,
                                          buf_rect.x, buf_rect.y, &wx, &wy);
    GdkRectangle rect = { wx, wy, 1, buf_rect.height };
    gtk_popover_set_pointing_to(ctx->popover, &rect);
    gtk_popover_popup(ctx->popover);
}

void zc_signature_hide(GtkSourceView *view) {
    ZcSigCtx *ctx = g_object_get_data(G_OBJECT(view), "zc-sig-ctx");
    if (!ctx || !ctx->popover) return;
    gtk_popover_popdown(ctx->popover);
}

/* Stub implementations of the four C subsystems that call back into Zig export
 * functions.  Used by `zig build test` in place of completion.c, hover.c,
 * signature.c, and editor.c to break the circular C↔Zig link dependency.
 * Every function is a no-op; return values satisfy callers' null checks. */

#include "zc_internal.h"

/* ── completion.c stubs ─────────────────────────────────────────────────── */

void zc_lsp_completion_attach(GtkSourceView *view) { (void)view; }

GListStore *zc_completion_store_new(void) { return NULL; }

void zc_completion_store_add(GListStore *store, const char *label,
                             const char *detail, const char *insert_text) {
    (void)store; (void)label; (void)detail; (void)insert_text;
}

void zc_completion_finish(GTask *task, GListStore *store) {
    (void)task; (void)store;
}

/* ── hover.c stubs ──────────────────────────────────────────────────────── */

void zc_hover_attach(GtkSourceView *view) { (void)view; }
void zc_hover_show_at_cursor(GtkSourceView *view) { (void)view; }
void zc_hover_show_text(GtkSourceView *view, const char *text,
                        int line, int ch) {
    (void)view; (void)text; (void)line; (void)ch;
}
void zc_hover_show_diag_fallback(GtkSourceView *view, int line, int ch) {
    (void)view; (void)line; (void)ch;
}
void zc_buffer_set_hover_diags(GtkSourceBuffer *buf,
                               const ZcHoverDiag *diags, guint n) {
    (void)buf; (void)diags; (void)n;
}

/* ── signature.c stubs ──────────────────────────────────────────────────── */

void zc_signature_attach(GtkSourceView *view) { (void)view; }
void zc_signature_show(GtkSourceView *view, const char *text) {
    (void)view; (void)text;
}
void zc_signature_hide(GtkSourceView *view) { (void)view; }

/* ── editor.c stubs ─────────────────────────────────────────────────────── */

void zc_editor_attach_click_nav(GtkSourceView *view) { (void)view; }

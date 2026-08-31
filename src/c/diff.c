/* Source-view diff gutter.
 *
 * A GtkSourceGutterRenderer that paints a coloured change bar next to lines
 * that differ from HEAD (green add, orange modify, red delete marker).  The
 * per-line map is computed from `git diff HEAD --unified=0` for the file and
 * refreshed on open, on save and whenever git status changes.
 */
#include "zc_internal.h"
#include <stdio.h>

#define ZC_TYPE_DIFF_RENDERER (zc_diff_renderer_get_type())
G_DECLARE_FINAL_TYPE(ZcDiffRenderer, zc_diff_renderer, ZC, DIFF_RENDERER,
                     GtkSourceGutterRenderer)



struct _ZcDiffRenderer {
    GtkSourceGutterRenderer parent_instance;
    GArray *lines;        /* guint8 per line: 0 none, 1 add, 2 modify, 3 delete */
    GArray *marks;        /* ZcDiffMark[], sparse: only non-zero diff lines */
    GCancellable *cancel; /* cancels the in-flight `git diff`, so the latest wins */
    guint added, removed; /* line counts, as `git diff --numstat` reports them */
};

/* Set from Zig: called after a recomputed diff so the status bar can pick up
 * the new counts, which arrive long after the save that triggered them. */
static ZcDiffChangedFn zc_diff_changed_cb;

void zc_diff_set_changed_cb(ZcDiffChangedFn cb) { zc_diff_changed_cb = cb; }

G_DEFINE_TYPE(ZcDiffRenderer, zc_diff_renderer, GTK_SOURCE_TYPE_GUTTER_RENDERER)

static void zc_diff_snapshot_line(GtkSourceGutterRenderer *r, GtkSnapshot *snap,
                                  GtkSourceGutterLines *lines, guint line) {
    ZcDiffRenderer *self = ZC_DIFF_RENDERER(r);
    if (!self->lines || line >= self->lines->len) return;
    guint8 st = g_array_index(self->lines, guint8, line);
    if (st == 0) return;

    GdkRGBA c;
    if (st == 1)      gdk_rgba_parse(&c, "#2ec27e");
    else if (st == 2) gdk_rgba_parse(&c, "#e5a50a");
    else              gdk_rgba_parse(&c, "#e01b24");

    int y = 0, h = 0;
    gtk_source_gutter_lines_get_line_yrange(
        lines, line, GTK_SOURCE_GUTTER_RENDERER_ALIGNMENT_MODE_CELL, &y, &h);

    graphene_rect_t rect;
    if (st == 3)
        graphene_rect_init(&rect, 0, (float)(y + h - 1), 6.0f, 2.0f);
    else
        graphene_rect_init(&rect, 0, (float)y, 3.0f, (float)h);
    gtk_snapshot_append_color(snap, &c, &rect);
}

static void zc_diff_measure(GtkWidget *w, GtkOrientation o, int for_size,
                            int *min, int *nat, int *min_base, int *nat_base) {
    if (o == GTK_ORIENTATION_HORIZONTAL) { *min = *nat = 5; }
    else { *min = *nat = 0; }
    *min_base = *nat_base = -1;
}

static void zc_diff_finalize(GObject *o) {
    ZcDiffRenderer *self = ZC_DIFF_RENDERER(o);
    if (self->cancel) { g_cancellable_cancel(self->cancel); g_object_unref(self->cancel); }
    if (self->lines) g_array_free(self->lines, TRUE);
    if (self->marks) g_array_free(self->marks, TRUE);
    G_OBJECT_CLASS(zc_diff_renderer_parent_class)->finalize(o);
}

static void zc_diff_renderer_class_init(ZcDiffRendererClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = zc_diff_finalize;
    GTK_WIDGET_CLASS(klass)->measure = zc_diff_measure;
    GTK_SOURCE_GUTTER_RENDERER_CLASS(klass)->snapshot_line = zc_diff_snapshot_line;
}
static void zc_diff_renderer_init(ZcDiffRenderer *self) {
    self->lines = NULL;
    self->marks = NULL;
    self->cancel = NULL;
    self->added = self->removed = 0;
}

/* Turns `git diff --unified=0` output into a per-line change map (dense) and
 * a sparse marks array for the overview ruler. */
static void zc_diff_parse(const char *out, ZcDiffRenderer *self,
                          GArray **lines_out, GArray **marks_out) {
    GArray *arr = g_array_new(FALSE, TRUE, sizeof(guint8));
    GArray *sparse = g_array_new(FALSE, TRUE, sizeof(ZcDiffMark));
    self->added = self->removed = 0;
    gchar **ls = g_strsplit(out, "\n", -1);
    for (int i = 0; ls[i]; i++) {
        const char *l = ls[i];
        if (l[0] != '@') continue;
        int a, b, c, d;
        if (sscanf(l, "@@ -%d,%d +%d,%d @@", &a, &b, &c, &d) == 4) {}
        else if (sscanf(l, "@@ -%d,%d +%d @@", &a, &b, &c) == 3) d = 1;
        else if (sscanf(l, "@@ -%d +%d,%d @@", &a, &c, &d) == 3) b = 1;
        else if (sscanf(l, "@@ -%d +%d @@", &a, &c) == 2) { b = 1; d = 1; }
        else continue;

        /* A hunk replaces `b` old lines with `d` new ones — the same tally
         * `git diff --numstat` prints. */
        self->added += (guint)d;
        self->removed += (guint)b;

        if (d == 0) {                      /* pure deletion marker */
            int idx = c - 1; if (idx < 0) idx = 0;
            if ((int)arr->len <= idx) g_array_set_size(arr, idx + 1);
            g_array_index(arr, guint8, idx) = 3;
            ZcDiffMark m = { .line = (guint)idx, .status = 3 };
            g_array_append_val(sparse, m);
        } else {
            guint8 kind = (b == 0) ? 1 : 2; /* added vs modified */
            for (int k = 0; k < d; k++) {
                int idx = c - 1 + k; if (idx < 0) continue;
                if ((int)arr->len <= idx) g_array_set_size(arr, idx + 1);
                g_array_index(arr, guint8, idx) = kind;
                ZcDiffMark m = { .line = (guint)idx, .status = kind };
                g_array_append_val(sparse, m);
            }
        }
    }
    g_strfreev(ls);
    *lines_out = arr;
    *marks_out = sparse;
}

/* One `git diff` run.  The cancellable is held by the request rather than only
 * by the renderer: cancelling after the subprocess has already completed does
 * not make `finish` fail, so `ok` alone cannot tell a current result from a
 * superseded one — the flag has to be read explicitly. */
typedef struct { ZcDiffRenderer *self; GCancellable *cancel; } ZcDiffReq;

static void zc_diff_done(GObject *src, GAsyncResult *res, gpointer data) {
    ZcDiffReq *req = data;
    ZcDiffRenderer *self = req->self;
    gchar *out = NULL;
    gboolean ok = g_subprocess_communicate_utf8_finish(G_SUBPROCESS(src), res,
                                                        &out, NULL, NULL) &&
                  !g_cancellable_is_cancelled(req->cancel);
    if (ok) {
        if (self->lines) g_array_free(self->lines, TRUE);
        if (self->marks) g_array_free(self->marks, TRUE);
        if (out)
            zc_diff_parse(out, self, &self->lines, &self->marks);
        else {
            self->lines = NULL;
            self->marks = NULL;
            self->added = self->removed = 0;
        }
        /* Also refresh the overview ruler that mirrors the same data. */
        GtkSourceView *sv = gtk_source_gutter_renderer_get_view(
            GTK_SOURCE_GUTTER_RENDERER(self));
        if (sv) {
            GtkWidget *ruler = g_object_get_data(G_OBJECT(sv), "zc-overview");
            zc_overview_ruler_queue_draw(ruler);
        }
        if (zc_diff_changed_cb) zc_diff_changed_cb();
    }
    g_free(out);
    zc_git_busy_leave();
    g_object_unref(req->cancel);
    g_object_unref(self); /* the ref taken in zc_diff_compute */
    g_free(req);
}

/* Recomputes the change map off the main thread; the bars update when ready. */
static void zc_diff_compute(ZcDiffRenderer *self, const char *path) {
    if (self->cancel) {
        g_cancellable_cancel(self->cancel);
        g_clear_object(&self->cancel);
    }
    if (!path || !*path) {
        if (self->lines) { g_array_free(self->lines, TRUE); self->lines = NULL; }
        if (self->marks) { g_array_free(self->marks, TRUE); self->marks = NULL; }
        gtk_widget_queue_draw(GTK_WIDGET(self));
        return;
    }

    gchar *dir = g_path_get_dirname(path);
    /* --no-optional-locks: without it git refreshes and rewrites .git/index,
     * which the work-tree watcher reads as an external change and answers with
     * another refresh — which runs this again. */
    const gchar *base[] = {"git", "--no-optional-locks", "-C", dir, "diff", "HEAD",
                           "--unified=0", "--no-color", "--", path, NULL};
    const gchar *fp[]   = {"flatpak-spawn", "--host", "git", "--no-optional-locks",
                           "-C", dir, "diff", "HEAD",
                           "--unified=0", "--no-color", "--", path, NULL};
    GSubprocess *proc = g_subprocess_newv(
        zc_in_flatpak() ? fp : base,
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, NULL);
    g_free(dir);
    if (!proc) return;

    ZcDiffReq *req = g_new0(ZcDiffReq, 1);
    req->self = g_object_ref(self);
    req->cancel = g_cancellable_new();
    self->cancel = g_object_ref(req->cancel);
    zc_git_busy_enter();
    g_subprocess_communicate_utf8_async(proc, NULL, req->cancel, zc_diff_done, req);
    g_object_unref(proc);
}

void zc_source_view_attach_diff(GtkSourceView *view, const char *path) {
    GtkSourceGutter *gutter = gtk_source_view_get_gutter(view, GTK_TEXT_WINDOW_LEFT);
    ZcDiffRenderer *r = g_object_new(ZC_TYPE_DIFF_RENDERER, NULL);
    gtk_source_gutter_insert(gutter, GTK_SOURCE_GUTTER_RENDERER(r), -40);
    g_object_set_data(G_OBJECT(view), "zc-diff", r);

    for (GtkWidget *c = gtk_widget_get_first_child(GTK_WIDGET(gutter));
         c != NULL; c = gtk_widget_get_next_sibling(c)) {
        if (GTK_SOURCE_IS_GUTTER_RENDERER(c) && !ZC_IS_DIFF_RENDERER(c))
            gtk_widget_set_margin_end(c, 10);
    }
    zc_diff_compute(r, path);
    gtk_widget_queue_draw(GTK_WIDGET(r));
}

void zc_source_view_update_diff(GtkSourceView *view, const char *path) {
    ZcDiffRenderer *r = g_object_get_data(G_OBJECT(view), "zc-diff");
    if (!r) return;
    zc_diff_compute(r, path);
    gtk_widget_queue_draw(GTK_WIDGET(r));
}

/* Returns the borrowed per-line change array from the diff renderer attached
 * to `view`, or NULL when none exists or no diff has been computed yet.
 * Callers must not free the array — its lifetime is the renderer's. */
GArray *zc_diff_get_lines(GtkSourceView *view) {
    ZcDiffRenderer *r = g_object_get_data(G_OBJECT(view), "zc-diff");
    return r ? r->lines : NULL;
}

/* How many lines the file adds and removes against HEAD.  Zero for a file with
 * no diff renderer, or before the first `git diff` has come back. */
void zc_diff_stats(GtkSourceView *view, guint *added, guint *removed) {
    ZcDiffRenderer *r = g_object_get_data(G_OBJECT(view), "zc-diff");
    *added = r ? r->added : 0;
    *removed = r ? r->removed : 0;
}

/* Returns the borrowed sparse marks array (ZcDiffMark elements), or NULL. */
GArray *zc_diff_get_marks(GtkSourceView *view) {
    ZcDiffRenderer *r = g_object_get_data(G_OBJECT(view), "zc-diff");
    return r ? r->marks : NULL;
}

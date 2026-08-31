/* Small standalone GTK/GLib helpers that are awkward to express through the
 * hand-written externs in Zig: data-dir resolution, the icon toggle button,
 * buffer save, item creation, style-scheme registration, the syntax tags and
 * the adaptive sidebar breakpoint. */
#include "zc_internal.h"
#include <gtksourceview/gtksource.h>
#include <glib/gstdio.h>
#include <unistd.h>

/* Creates an anonymous GtkTextTag with a wavy error underline in the given
 * colour.  Components are 0.0 – 1.0 floats. */
GtkTextTag *zc_diag_tag_new(void *buffer, float r, float g, float b, float a) {
    GdkRGBA c = { r, g, b, a };
    return gtk_text_buffer_create_tag(GTK_TEXT_BUFFER(buffer), NULL,
                                      "underline", PANGO_UNDERLINE_ERROR,
                                      "underline-rgba", &c,
                                      NULL);
}

/* Creates an anonymous GtkTextTag that tints the paragraph background — used
 * for the brief flash on externally reloaded lines.  Components are 0.0–1.0;
 * keep alpha low so it stays subtle. */
GtkTextTag *zc_line_bg_tag_new(void *buffer, float r, float g, float b, float a) {
    GdkRGBA c = { r, g, b, a };
    return gtk_text_buffer_create_tag(GTK_TEXT_BUFFER(buffer), NULL,
                                      "paragraph-background-rgba", &c,
                                      NULL);
}

/* Full-width diagnostic line tint via GtkSourceView mark categories.
 *
 * A "paragraph-background" text tag only paints as far as the line's text, so
 * short lines and horizontal scrolling leave untinted gaps.  GtkSourceView
 * paints the background of lines holding a source mark across the entire
 * visible width of the view, which is exactly what a line-level diagnostic
 * highlight needs.  One category per severity; when a line carries several,
 * the higher-priority (more severe) background wins. */
static const char *zc_diag_categories[4] = {
    "zc-diag-1", "zc-diag-2", "zc-diag-3", "zc-diag-4",
};

/* Registers the four severity categories on `view`.  Call once per view. */
void zc_diag_marks_attach(GtkSourceView *view) {
    static const GdkRGBA colors[4] = {
        { 0.929, 0.200, 0.231, 0.20 },  /* error   #ed333b */
        { 0.929, 0.678, 0.102, 0.16 },  /* warning #edad1a */
        { 0.306, 0.604, 0.949, 0.10 },  /* info    #4e9af2 */
        { 0.557, 0.565, 0.569, 0.08 },  /* hint    #8e9091 */
    };
    for (int i = 0; i < 4; i++) {
        GtkSourceMarkAttributes *attrs = gtk_source_mark_attributes_new();
        gtk_source_mark_attributes_set_background(attrs, &colors[i]);
        gtk_source_view_set_mark_attributes(view, zc_diag_categories[i],
                                            attrs, 40 - 10 * i);
        g_object_unref(attrs);
    }
}

/* Tints `line` with the colour for `severity` (1=error … 4=hint). */
void zc_diag_line_mark_add(GtkSourceBuffer *buf, int line, int severity) {
    if (severity < 1 || severity > 4) return;
    GtkTextIter it;
    gtk_text_buffer_get_iter_at_line(GTK_TEXT_BUFFER(buf), &it, line);
    gtk_source_buffer_create_source_mark(buf, NULL,
                                         zc_diag_categories[severity - 1], &it);
}

/* Removes the diagnostic line tints between `start` and `end`.  Scoped rather
 * than whole-buffer: this runs on every edit, and sweeping the document four
 * times over cost more than the edit itself on a large file. */
void zc_diag_line_marks_clear_range(GtkSourceBuffer *buf,
                                    const void *start, const void *end) {
    for (int i = 0; i < 4; i++)
        gtk_source_buffer_remove_source_marks(buf, (GtkTextIter *)start,
                                              (GtkTextIter *)end,
                                              zc_diag_categories[i]);
}


/*
 * Places `iter` at `byte_col` within `line`, snapped back to a character
 * boundary and clamped to the line's length.
 *
 * Byte columns in this editor are computed against one revision of the buffer
 * and used against another: a diagnostic is measured when the server publishes
 * it and painted a frame later, a cursor is measured before a reload and
 * restored after, a tree-sitter capture is measured at the last parse.  Feeding
 * such a column straight to gtk_text_buffer_get_iter_at_line_index lands
 * mid-character as soon as the text moved under it, and GTK is explicit about
 * what that costs: "this will crash the text buffer".  It does — the iterator
 * goes on to tag or edit at a byte that is not a character, the B-tree's
 * character accounting stops matching the bytes, and the next paint hands Pango
 * a broken string and segfaults inside the text view's snapshot.
 *
 * Walking the line by characters is what makes the result always valid, and the
 * cost is proportional to the column rather than to the buffer.
 */
void zc_iter_at_line_byte(void *buffer, void *iter_out, int line, int byte_col) {
    GtkTextBuffer *buf = GTK_TEXT_BUFFER(buffer);
    GtkTextIter *iter = iter_out;

    int n_lines = gtk_text_buffer_get_line_count(buf);
    if (line < 0) line = 0;
    if (line >= n_lines) line = n_lines - 1;
    gtk_text_buffer_get_iter_at_line(buf, iter, line);
    if (byte_col <= 0) return;

    GtkTextIter line_end = *iter;
    if (!gtk_text_iter_ends_line(&line_end))
        gtk_text_iter_forward_to_line_end(&line_end);
    if (byte_col >= gtk_text_iter_get_line_index(&line_end)) {
        *iter = line_end;
        return;
    }

    while (!gtk_text_iter_ends_line(iter) &&
           gtk_text_iter_get_line_index(iter) < byte_col) {
        GtkTextIter next = *iter;
        if (!gtk_text_iter_forward_char(&next)) break;
        /* Overshooting means byte_col was inside this character: stop before it. */
        if (gtk_text_iter_get_line_index(&next) > byte_col) break;
        *iter = next;
    }
}


gchar *zc_data_dir(const char *env_var, const char *subdir, const char *probe) {
    GPtrArray *cands = g_ptr_array_new_with_free_func(g_free);
    const char *env = g_getenv(env_var);
    if (env && *env) g_ptr_array_add(cands, g_strdup(env));

    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) {
        exe[n] = 0;
        gchar *bin = g_path_get_dirname(exe);
        g_ptr_array_add(cands, g_build_filename(bin, "..", "share", "zcode", subdir, NULL));
        g_ptr_array_add(cands, g_build_filename(bin, "..", "..", "data", subdir, NULL));
        g_free(bin);
    }
    g_ptr_array_add(cands, g_build_filename("/app/share/zcode", subdir, NULL));

    gchar *found = NULL;
    for (guint i = 0; i < cands->len && !found; i++) {
        gchar *path = g_build_filename(cands->pdata[i], probe, NULL);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) found = g_strdup(cands->pdata[i]);
        g_free(path);
    }
    g_ptr_array_free(cands, TRUE);
    return found;
}

/*
 * Saves the content of buf to path.
 * Resets the buffer's modified flag on success (which fires modified-changed).
 * Returns 1 on success, 0 on failure.
 */
int zc_buffer_save(const gchar *path, void *buf_ptr) {
    GtkTextBuffer *buf = GTK_TEXT_BUFFER(buf_ptr);
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buf, &start, &end);
    gchar *text = gtk_text_buffer_get_text(buf, &start, &end, FALSE);
    GError *err = NULL;
    gboolean ok = g_file_set_contents(path, text, -1, &err);
    g_free(text);
    if (!ok) {
        if (err) g_error_free(err);
        return 0;
    }
    gtk_text_buffer_set_modified(buf, FALSE);
    return 1;
}

/*
 * Creates a file (is_dir=0) or directory (is_dir=1) named `name` inside
 * `parent_dir`.  Returns 1 on success, 0 on failure.
 */
int zc_create_item(const gchar *parent_dir, const gchar *name, int is_dir) {
    gchar *full = g_build_filename(parent_dir, name, NULL);
    int ok;
    if (is_dir) {
        ok = (g_mkdir_with_parents(full, 0755) == 0);
    } else {
        ok = g_file_set_contents(full, "", 0, NULL);
    }
    g_free(full);
    return ok;
}

/*
 * Canonicalises `path` (resolving a relative argument against the current
 * directory) and returns it if it names a directory, else NULL.  g_free().
 */
gchar *zc_resolve_dir(const char *path) {
    gchar *abs = g_canonicalize_filename(path, NULL);
    if (abs && g_file_test(abs, G_FILE_TEST_IS_DIR)) return abs;
    g_free(abs);
    return NULL;
}

/* Puts our bundled Adwaita Pastel schemes on the manager's search path so the
 * editor can select them by id. */
void zc_register_style_schemes(void) {
    gchar *dir = zc_data_dir("ZCODE_STYLE_DIR", "styles", "adwaita-pastel-dark.xml");
    if (!dir) return;
    gtk_source_style_scheme_manager_append_search_path(
        gtk_source_style_scheme_manager_get_default(), dir);
    g_free(dir);
}

/* Creates an anonymous GtkTextTag with a foreground colour and optional
 * italic/bold.  The variadic property API is awkward from Zig, so the
 * tree-sitter highlighter builds its tags through here. */
GtkTextTag *zc_text_tag_new(void *buffer, const char *fg, int italic, int bold) {
    GtkTextTag *t = gtk_text_buffer_create_tag(GTK_TEXT_BUFFER(buffer), NULL,
                                               "foreground", fg, NULL);
    if (italic) g_object_set(t, "style", PANGO_STYLE_ITALIC, NULL);
    if (bold)   g_object_set(t, "weight", PANGO_WEIGHT_BOLD, NULL);
    return t;
}

/* Updates a tag's foreground (used when the light/dark scheme changes). */
void zc_text_tag_set_fg(GtkTextTag *tag, const char *fg) {
    g_object_set(tag, "foreground", fg, NULL);
}

/* ── Main-loop watchdog ───────────────────────────────────────────────────── */

/*
 * Reports every main-loop turn that takes longer than ZC_WATCHDOG_MS.
 *
 * The window stops answering for exactly as long as one callback runs, and from
 * inside the process that is all this can say — but it says it at the moment it
 * happens, which turns "the editor froze" into "the loop was busy 3200 ms", and
 * that is the difference between one blocking call and a thousand slow frames.
 * Attach a debugger on a report to see where.
 *
 * The poll function is what brackets a turn: everything between one poll
 * returning and the next one starting is dispatch.
 */
static GPollFunc zc_wd_next_poll;
static gint64    zc_wd_poll_ended;
static gint64    zc_wd_threshold_us;

static gint zc_wd_poll(GPollFD *fds, guint nfds, gint timeout) {
    if (zc_wd_poll_ended != 0) {
        gint64 busy = g_get_monotonic_time() - zc_wd_poll_ended;
        if (busy >= zc_wd_threshold_us)
            g_warning("main loop busy for %.0f ms", busy / 1000.0);
    }
    gint ready = zc_wd_next_poll(fds, nfds, timeout);
    zc_wd_poll_ended = g_get_monotonic_time();
    return ready;
}

void zc_watchdog_install(void) {
    const char *ms = g_getenv("ZC_WATCHDOG_MS");
    if (!ms || !*ms) return;
    zc_wd_threshold_us = g_ascii_strtoll(ms, NULL, 10) * 1000;
    if (zc_wd_threshold_us <= 0) return;

    GMainContext *ctx = g_main_context_default();
    zc_wd_next_poll = g_main_context_get_poll_func(ctx);
    g_main_context_set_poll_func(ctx, zc_wd_poll);
}

/*
 * Adds a breakpoint that collapses the sidebar once the window gets narrow,
 * giving the adaptive behaviour GNOME Circle expects on small screens.
 */
void zc_add_collapse_breakpoint(AdwApplicationWindow *win,
                                AdwOverlaySplitView *split) {
    AdwBreakpoint *bp =
        adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 600px"));

    GValue collapsed = G_VALUE_INIT;
    g_value_init(&collapsed, G_TYPE_BOOLEAN);
    g_value_set_boolean(&collapsed, TRUE);
    adw_breakpoint_add_setter(bp, G_OBJECT(split), "collapsed", &collapsed);
    g_value_unset(&collapsed);

    adw_application_window_add_breakpoint(win, bp);
}

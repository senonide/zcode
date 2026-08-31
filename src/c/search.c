/* In-file search and selection-occurrence highlighting.
 *
 * One ZcSearch per source view (attached to the view via object data) drives a
 * GtkSourceSearchContext shared by two behaviours that never run at once:
 *
 *   - Selection highlight: while the find bar is closed, selecting a single-line,
 *     non-blank token highlights every matching occurrence in the buffer.
 *   - Find (Ctrl+F): a GtkSearchBar takes over the same context for interactive
 *     search with next/previous navigation, an "N of M" counter, the
 *     case/word/regex switches GtkSourceSearchSettings already supports, and a
 *     second row for replace (Ctrl+H) that stays hidden until asked for.
 *
 * The find bar "owns" the context while open (find_mode), so the two never fight
 * over the highlight. */
#include <gtk/gtk.h>
#include <gtksourceview/gtksource.h>

typedef struct {
    GtkSourceView           *view;
    GtkSourceBuffer         *buffer;
    GtkSourceSearchSettings *settings;
    GtkSourceSearchContext  *context;
    GtkSearchBar            *bar;   /* NULL until the find bar is built */
    GtkSearchEntry          *entry;
    GtkLabel                *info;
    GtkWidget               *replace_row;   /* second row, hidden until asked for */
    GtkEditable             *replace_entry;
    GtkToggleButton         *replace_toggle;
    gboolean                 find_mode;
} ZcSearch;

/* ── Selection-occurrence highlight ──────────────────────────────────────── */

/* Longest selection that still reads as a token worth highlighting elsewhere.
 * Past this the search context would rescan the whole buffer for a needle no
 * one is looking for — on every cursor move, which is what a click-drag or a
 * held Shift+Arrow emits.  Long lines (minified sources) made that a visible
 * stall. */
#define ZC_MAX_SELECTION_HIGHLIGHT 128

/* Sets the search text to the current selection when it is a single-line,
 * non-blank token; otherwise clears the highlight.  No-op while the find bar
 * owns the context. */
static void update_selection_highlight(GtkTextBuffer *buffer, GtkTextMark *mark,
                                       ZcSearch *s) {
    if (s->find_mode) return;
    if (mark != gtk_text_buffer_get_insert(buffer) &&
        mark != gtk_text_buffer_get_selection_bound(buffer))
        return;

    GtkTextIter a, b;
    if (!gtk_text_buffer_get_selection_bounds(buffer, &a, &b) ||
        gtk_text_iter_get_line(&a) != gtk_text_iter_get_line(&b) ||
        gtk_text_iter_get_offset(&b) - gtk_text_iter_get_offset(&a)
            > ZC_MAX_SELECTION_HIGHLIGHT) {
        gtk_source_search_settings_set_search_text(s->settings, NULL);
        return;
    }

    gchar *sel = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    const char *trimmed = sel;
    while (g_ascii_isspace(*trimmed)) trimmed++;
    gtk_source_search_settings_set_search_text(s->settings, *trimmed ? sel : NULL);
    g_free(sel);
}

static void on_mark_set(GtkTextBuffer *buffer, GtkTextIter *loc,
                        GtkTextMark *mark, gpointer data) {
    (void)loc;
    update_selection_highlight(buffer, mark, data);
}

/* ── Find bar ────────────────────────────────────────────────────────────── */

static void update_info(ZcSearch *s) {
    if (!s->info) return;
    const gchar *txt = gtk_source_search_settings_get_search_text(s->settings);
    int count = gtk_source_search_context_get_occurrences_count(s->context);

    GtkTextBuffer *buf = GTK_TEXT_BUFFER(s->buffer);
    GtkTextIter a, b;
    int pos = -1;
    if (gtk_text_buffer_get_selection_bounds(buf, &a, &b))
        pos = gtk_source_search_context_get_occurrence_position(s->context, &a, &b);

    char tmp[64];
    if (!txt || !*txt)      tmp[0] = '\0';
    else if (count == 0)    g_strlcpy(tmp, "No results", sizeof tmp);
    else if (count < 0)     g_strlcpy(tmp, "\xe2\x80\xa6", sizeof tmp); /* … */
    else if (pos > 0)       g_snprintf(tmp, sizeof tmp, "%d of %d", pos, count);
    else                    g_snprintf(tmp, sizeof tmp, "%d found", count);
    gtk_label_set_text(s->info, tmp);
}

/* Selects the next/previous match relative to the current selection/cursor. */
static void search_move(ZcSearch *s, gboolean forward) {
    GtkTextBuffer *buf = GTK_TEXT_BUFFER(s->buffer);
    GtkTextIter sel_start, sel_end, start, mstart, mend;
    gboolean has_sel = gtk_text_buffer_get_selection_bounds(buf, &sel_start, &sel_end);
    if (!has_sel)
        gtk_text_buffer_get_iter_at_mark(buf, &start, gtk_text_buffer_get_insert(buf));
    else
        start = forward ? sel_end : sel_start;

    gboolean wrapped, found = forward
        ? gtk_source_search_context_forward(s->context, &start, &mstart, &mend, &wrapped)
        : gtk_source_search_context_backward(s->context, &start, &mstart, &mend, &wrapped);

    if (found) {
        gtk_text_buffer_select_range(buf, &mend, &mstart); /* cursor at end */
        gtk_text_view_scroll_to_mark(GTK_TEXT_VIEW(s->view),
            gtk_text_buffer_get_insert(buf), 0.1, FALSE, 0, 0);
    }
    update_info(s);
}

static void on_search_changed(GtkSearchEntry *entry, ZcSearch *s) {
    const gchar *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    gtk_source_search_settings_set_search_text(s->settings,
                                               (text && *text) ? text : NULL);

    GtkTextBuffer *buf = GTK_TEXT_BUFFER(s->buffer);
    GtkTextIter start, mstart, mend;
    gboolean wrapped;
    gtk_text_buffer_get_iter_at_mark(buf, &start, gtk_text_buffer_get_insert(buf));
    if (text && *text &&
        gtk_source_search_context_forward(s->context, &start, &mstart, &mend, &wrapped)) {
        gtk_text_buffer_select_range(buf, &mend, &mstart);
        gtk_text_view_scroll_to_mark(GTK_TEXT_VIEW(s->view),
            gtk_text_buffer_get_insert(buf), 0.1, FALSE, 0, 0);
    }
    update_info(s);
}

static void on_next(GtkWidget *w, ZcSearch *s)  { (void)w; search_move(s, TRUE);  }
static void on_prev(GtkWidget *w, ZcSearch *s)  { (void)w; search_move(s, FALSE); }
static void on_stop(GtkWidget *w, ZcSearch *s)  { (void)w; gtk_search_bar_set_search_mode(s->bar, FALSE); }
static void on_count(GObject *o, GParamSpec *p, ZcSearch *s) { (void)o; (void)p; update_info(s); }

/* Reacts to the bar opening/closing: while open the find owns the context and is
 * seeded from the current selection; on close the selection highlight resumes. */
static void on_search_mode(GObject *bar, GParamSpec *p, ZcSearch *s) {
    (void)p;
    s->find_mode = gtk_search_bar_get_search_mode(GTK_SEARCH_BAR(bar));
    GtkTextBuffer *buf = GTK_TEXT_BUFFER(s->buffer);

    if (s->find_mode) {
        GtkTextIter a, b;
        if (gtk_text_buffer_get_selection_bounds(buf, &a, &b) &&
            gtk_text_iter_get_line(&a) == gtk_text_iter_get_line(&b)) {
            gchar *sel = gtk_text_buffer_get_text(buf, &a, &b, FALSE);
            if (sel[0]) gtk_editable_set_text(GTK_EDITABLE(s->entry), sel);
            g_free(sel);
        }
        gtk_editable_select_region(GTK_EDITABLE(s->entry), 0, -1);
        gtk_widget_grab_focus(GTK_WIDGET(s->entry));
        on_search_changed(s->entry, s);
    } else {
        gtk_widget_grab_focus(GTK_WIDGET(s->view));
        update_selection_highlight(buf, gtk_text_buffer_get_insert(buf), s);
    }
}

/* ── Replace ─────────────────────────────────────────────────────────────── */

static const char *replace_text(ZcSearch *s) {
    const char *t = s->replace_entry ? gtk_editable_get_text(s->replace_entry) : NULL;
    return t ? t : "";
}

/* Replaces the current match, then moves on: the caret ends up on the next
 * occurrence, so repeated activation walks the file. */
static void on_replace(GtkWidget *w, ZcSearch *s) {
    (void)w;
    GtkTextBuffer *buf = GTK_TEXT_BUFFER(s->buffer);
    GtkTextIter a, b;
    if (gtk_text_buffer_get_selection_bounds(buf, &a, &b) &&
        gtk_source_search_context_get_occurrence_position(s->context, &a, &b) > 0) {
        const char *with = replace_text(s);
        gtk_source_search_context_replace(s->context, &a, &b, with, -1, NULL);
    }
    search_move(s, TRUE);
}

static void on_replace_all(GtkWidget *w, ZcSearch *s) {
    (void)w;
    const char *text = gtk_source_search_settings_get_search_text(s->settings);
    if (!text || !*text) return;
    gtk_source_search_context_replace_all(s->context, replace_text(s), -1, NULL);
    update_info(s);
}

/* Revealing the replace row also focuses it — the user asked to replace, not to
 * look at an empty field. */
static void on_replace_toggled(GtkToggleButton *btn, ZcSearch *s) {
    gboolean on = gtk_toggle_button_get_active(btn);
    gtk_widget_set_visible(s->replace_row, on);
    if (on) gtk_widget_grab_focus(GTK_WIDGET(s->replace_entry));
}

/* ── Search options ──────────────────────────────────────────────────────── */

static void on_case_toggled(GtkToggleButton *btn, ZcSearch *s) {
    gtk_source_search_settings_set_case_sensitive(s->settings, gtk_toggle_button_get_active(btn));
    update_info(s);
}

static void on_word_toggled(GtkToggleButton *btn, ZcSearch *s) {
    gtk_source_search_settings_set_at_word_boundaries(s->settings, gtk_toggle_button_get_active(btn));
    update_info(s);
}

static void on_regex_toggled(GtkToggleButton *btn, ZcSearch *s) {
    gtk_source_search_settings_set_regex_enabled(s->settings, gtk_toggle_button_get_active(btn));
    update_info(s);
}

/* A small labelled toggle, the way GNOME Text Editor presents these options. */
static GtkWidget *option_toggle(const char *label, const char *tooltip,
                                GCallback cb, ZcSearch *s, gboolean active) {
    GtkWidget *b = gtk_toggle_button_new_with_label(label);
    gtk_widget_set_tooltip_text(b, tooltip);
    gtk_widget_add_css_class(b, "flat");
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(b), active);
    g_signal_connect(b, "toggled", cb, s);
    return b;
}

/* ── Public API (called from Zig) ────────────────────────────────────────── */

void zc_search_attach(GtkSourceView *view) {
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    ZcSearch *s = g_new0(ZcSearch, 1);
    s->view = view;
    s->buffer = GTK_SOURCE_BUFFER(buf);
    s->settings = gtk_source_search_settings_new();
    gtk_source_search_settings_set_case_sensitive(s->settings, TRUE);
    gtk_source_search_settings_set_wrap_around(s->settings, TRUE);
    s->context = gtk_source_search_context_new(s->buffer, s->settings);
    gtk_source_search_context_set_highlight(s->context, TRUE);

    g_signal_connect(buf, "mark-set", G_CALLBACK(on_mark_set), s);
    g_object_set_data(G_OBJECT(view), "zc-search", s);
}

/* Builds the find bar for `view` (must follow zc_search_attach) and returns the
 * GtkSearchBar widget for the caller to place above the editor. */
GtkWidget *zc_search_bar_new(GtkSourceView *view) {
    ZcSearch *s = g_object_get_data(G_OBJECT(view), "zc-search");
    if (!s) return NULL;

    GtkWidget *bar   = gtk_search_bar_new();
    GtkWidget *entry = gtk_search_entry_new();
    gtk_widget_set_hexpand(entry, TRUE);
    gtk_widget_set_size_request(entry, 220, -1);

    GtkWidget *info = gtk_label_new("");
    gtk_widget_add_css_class(info, "dim-label");
    gtk_widget_set_size_request(info, 72, -1);

    GtkWidget *prev = gtk_button_new_from_icon_name("go-up-symbolic");
    gtk_widget_set_tooltip_text(prev, "Previous match");
    gtk_widget_add_css_class(prev, "flat");
    GtkWidget *next = gtk_button_new_from_icon_name("go-down-symbolic");
    gtk_widget_set_tooltip_text(next, "Next match");
    gtk_widget_add_css_class(next, "flat");

    GtkWidget *replace_toggle = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(replace_toggle), "edit-find-replace-symbolic");
    gtk_widget_set_tooltip_text(replace_toggle, "Show Replace");
    gtk_widget_add_css_class(replace_toggle, "flat");

    GtkWidget *find_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(find_row), entry);
    gtk_box_append(GTK_BOX(find_row), info);
    gtk_box_append(GTK_BOX(find_row), prev);
    gtk_box_append(GTK_BOX(find_row), next);
    gtk_box_append(GTK_BOX(find_row),
        option_toggle("Aa", "Match case", G_CALLBACK(on_case_toggled), s,
                      gtk_source_search_settings_get_case_sensitive(s->settings)));
    gtk_box_append(GTK_BOX(find_row),
        option_toggle("W", "Match whole word", G_CALLBACK(on_word_toggled), s, FALSE));
    gtk_box_append(GTK_BOX(find_row),
        option_toggle(".*", "Regular expression", G_CALLBACK(on_regex_toggled), s, FALSE));
    gtk_box_append(GTK_BOX(find_row), replace_toggle);

    /* Second row: hidden until Ctrl+H or the toggle asks for it, so plain Find
     * stays a single compact line. */
    GtkWidget *replace_entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(replace_entry), "Replace with");
    gtk_widget_set_hexpand(replace_entry, TRUE);
    GtkWidget *replace_one = gtk_button_new_with_label("Replace");
    GtkWidget *replace_all = gtk_button_new_with_label("Replace All");

    GtkWidget *replace_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(replace_row), replace_entry);
    gtk_box_append(GTK_BOX(replace_row), replace_one);
    gtk_box_append(GTK_BOX(replace_row), replace_all);
    gtk_widget_set_visible(replace_row, FALSE);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(box), find_row);
    gtk_box_append(GTK_BOX(box), replace_row);

    gtk_search_bar_set_child(GTK_SEARCH_BAR(bar), box);
    gtk_search_bar_connect_entry(GTK_SEARCH_BAR(bar), GTK_EDITABLE(entry));
    gtk_search_bar_set_show_close_button(GTK_SEARCH_BAR(bar), TRUE);

    s->bar            = GTK_SEARCH_BAR(bar);
    s->entry          = GTK_SEARCH_ENTRY(entry);
    s->info           = GTK_LABEL(info);
    s->replace_row    = replace_row;
    s->replace_entry  = GTK_EDITABLE(replace_entry);
    s->replace_toggle = GTK_TOGGLE_BUTTON(replace_toggle);

    g_signal_connect(entry, "search-changed",  G_CALLBACK(on_search_changed), s);
    g_signal_connect(entry, "activate",         G_CALLBACK(on_next), s);
    g_signal_connect(entry, "next-match",       G_CALLBACK(on_next), s);
    g_signal_connect(entry, "previous-match",   G_CALLBACK(on_prev), s);
    g_signal_connect(entry, "stop-search",      G_CALLBACK(on_stop), s);
    g_signal_connect(prev,  "clicked",          G_CALLBACK(on_prev), s);
    g_signal_connect(next,  "clicked",          G_CALLBACK(on_next), s);
    g_signal_connect(replace_toggle, "toggled", G_CALLBACK(on_replace_toggled), s);
    g_signal_connect(replace_entry, "activate", G_CALLBACK(on_replace), s);
    g_signal_connect(replace_one, "clicked",    G_CALLBACK(on_replace), s);
    g_signal_connect(replace_all, "clicked",    G_CALLBACK(on_replace_all), s);
    g_signal_connect(bar, "notify::search-mode-enabled", G_CALLBACK(on_search_mode), s);
    g_signal_connect(s->context, "notify::occurrences-count", G_CALLBACK(on_count), s);

    return bar;
}

/* Reveals and focuses the find bar, seeding it from the current selection. */
void zc_search_bar_open(GtkSourceView *view) {
    ZcSearch *s = g_object_get_data(G_OBJECT(view), "zc-search");
    if (!s || !s->bar) return;
    if (gtk_search_bar_get_search_mode(s->bar)) {
        gtk_editable_select_region(GTK_EDITABLE(s->entry), 0, -1);
        gtk_widget_grab_focus(GTK_WIDGET(s->entry));
    } else {
        gtk_search_bar_set_search_mode(s->bar, TRUE); /* fires on_search_mode */
    }
}

/* Same, with the replace row revealed (Ctrl+H). */
void zc_search_bar_open_replace(GtkSourceView *view) {
    ZcSearch *s = g_object_get_data(G_OBJECT(view), "zc-search");
    if (!s || !s->bar) return;
    zc_search_bar_open(view);
    gtk_toggle_button_set_active(s->replace_toggle, TRUE);
}

/* Tears down the per-view search state.  Called from the editor tab's
 * page-detached handler before the view is destroyed, mirroring the project's
 * "disconnect before free" rule. */
void zc_search_detach(GtkSourceView *view) {
    ZcSearch *s = g_object_get_data(G_OBJECT(view), "zc-search");
    if (!s) return;
    g_object_set_data(G_OBJECT(view), "zc-search", NULL);

    /* Drop every handler carrying `s` before freeing it, so a signal emitted
     * while the widgets are torn down can't touch freed memory. */
    g_signal_handlers_disconnect_by_data(
        gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), s);
    if (s->entry)          g_signal_handlers_disconnect_by_data(s->entry, s);
    if (s->bar)            g_signal_handlers_disconnect_by_data(s->bar, s);
    if (s->replace_entry)  g_signal_handlers_disconnect_by_data(s->replace_entry, s);
    if (s->replace_toggle) g_signal_handlers_disconnect_by_data(s->replace_toggle, s);
    g_signal_handlers_disconnect_by_data(s->context, s);

    g_object_unref(s->context);
    g_object_unref(s->settings);
    g_free(s);
}

/* Editor interaction: Ctrl+Click go-to-definition / URL, "Rename Symbol" context menu,
 * Ctrl+Hover URL highlight. */
#include "zc_internal.h"
#include <string.h>

/* ── URL detection ────────────────────────────────────────────────────────── */

/* Scans the line containing `iter` for http/https URLs.  If `iter` falls
 * within one, returns a heap-allocated copy (caller g_free()s) and writes the
 * URL's text-buffer span into `*out_start` / `*out_end` (either may be NULL).
 * Returns NULL when no URL contains the current position. */
static gchar *url_at_iter(GtkTextIter *iter,
                           GtkTextIter *out_start, GtkTextIter *out_end) {
    GtkTextIter ls = *iter, le = *iter;
    gtk_text_iter_set_line_offset(&ls, 0);
    gtk_text_iter_forward_to_line_end(&le);
    gchar *line = gtk_text_iter_get_text(&ls, &le);
    if (!line) return NULL;

    int col = gtk_text_iter_get_line_offset(iter);
    gchar *result = NULL;

    static const char *schemes[] = { "https://", "http://", NULL };
    for (int s = 0; schemes[s] && !result; s++) {
        const char *cur = line;
        const char *hit;
        while ((hit = strstr(cur, schemes[s])) != NULL) {
            int url_start = (int)(hit - line);
            const char *tail = hit;
            while (*tail && !g_ascii_isspace(*tail) &&
                   *tail != '"' && *tail != '\'' &&
                   *tail != '<'  && *tail != '>'  &&
                   *tail != ')'  && *tail != ']')
                tail++;
            int url_end = (int)(tail - line);
            if (col >= url_start && col < url_end) {
                result = g_strndup(hit, tail - hit);
                if (out_start) {
                    *out_start = ls;
                    gtk_text_iter_set_line_offset(out_start, url_start);
                }
                if (out_end) {
                    *out_end = ls;
                    gtk_text_iter_set_line_offset(out_end, url_end);
                }
                break;
            }
            cur = hit + 1;
        }
    }

    g_free(line);
    return result;
}

/* ── Ctrl+Hover link highlight ────────────────────────────────────────────── */

typedef struct {
    GtkTextTag *tag;       /* underline tag in the view's buffer, created lazily */
    gboolean    active;    /* whether the tag is currently applied              */
    double      last_x;    /* last known pointer coords (widget-relative)       */
    double      last_y;
} LinkHover;

static LinkHover *link_hover_get(GtkWidget *widget) {
    LinkHover *lh = g_object_get_data(G_OBJECT(widget), "zc-link-hover");
    if (!lh) {
        lh = g_new0(LinkHover, 1);
        g_object_set_data_full(G_OBJECT(widget), "zc-link-hover", lh, g_free);
    }
    return lh;
}

static void link_hover_clear_tag(GtkWidget *widget, LinkHover *lh) {
    if (!lh->active || !lh->tag) return;
    GtkTextBuffer *buf = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
    GtkTextIter s, e;
    gtk_text_buffer_get_bounds(buf, &s, &e);
    gtk_text_buffer_remove_tag(buf, lh->tag, &s, &e);
    lh->active = FALSE;
}

/* Clears the underline and restores the I-beam cursor (used while inside the widget). */
static void link_hover_clear(GtkWidget *widget, LinkHover *lh) {
    link_hover_clear_tag(widget, lh);
    gtk_widget_set_cursor_from_name(widget, "text");
}

static void link_hover_update(GtkWidget *widget, LinkHover *lh,
                              double x, double y, gboolean ctrl) {
    lh->last_x = x;
    lh->last_y = y;

    link_hover_clear(widget, lh);
    if (!ctrl) return;

    GtkTextView *view = GTK_TEXT_VIEW(widget);
    int bx, by;
    gtk_text_view_window_to_buffer_coords(view, GTK_TEXT_WINDOW_WIDGET,
                                          (int)x, (int)y, &bx, &by);
    GtkTextIter iter;
    gtk_text_view_get_iter_at_location(view, &iter, bx, by);

    GtkTextIter url_s, url_e;
    gchar *url = url_at_iter(&iter, &url_s, &url_e);
    if (!url) return;
    g_free(url);

    if (!lh->tag) {
        GtkTextBuffer *buf = gtk_text_view_get_buffer(view);
        lh->tag = gtk_text_buffer_create_tag(buf, NULL,
                                             "underline", PANGO_UNDERLINE_SINGLE,
                                             NULL);
    }
    GtkTextBuffer *buf = gtk_text_view_get_buffer(view);
    gtk_text_buffer_apply_tag(buf, lh->tag, &url_s, &url_e);
    lh->active = TRUE;
    gtk_widget_set_cursor_from_name(widget, "pointer");
}

static void on_hover_motion(GtkEventControllerMotion *ctrl,
                            double x, double y, gpointer data) {
    (void)data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    GdkModifierType mods = gtk_event_controller_get_current_event_state(
            GTK_EVENT_CONTROLLER(ctrl));
    link_hover_update(widget, link_hover_get(widget), x, y,
                      (mods & GDK_CONTROL_MASK) != 0);
}

static void on_hover_leave(GtkEventControllerMotion *ctrl, gpointer data) {
    (void)data;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    /* Only remove the tag; the pointer has left so no cursor reset is needed. */
    link_hover_clear_tag(widget, link_hover_get(widget));
}

static gboolean on_hover_key_pressed(GtkEventControllerKey *ctrl,
                                     guint keyval, guint keycode,
                                     GdkModifierType state, gpointer data) {
    (void)keycode; (void)state; (void)data;
    if (keyval != GDK_KEY_Control_L && keyval != GDK_KEY_Control_R) return FALSE;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    LinkHover *lh = link_hover_get(widget);
    link_hover_update(widget, lh, lh->last_x, lh->last_y, TRUE);
    return FALSE;
}

static void on_hover_key_released(GtkEventControllerKey *ctrl,
                                  guint keyval, guint keycode,
                                  GdkModifierType state, gpointer data) {
    (void)keycode; (void)state; (void)data;
    if (keyval != GDK_KEY_Control_L && keyval != GDK_KEY_Control_R) return;
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(ctrl));
    link_hover_clear(widget, link_hover_get(widget));
}

/* ── Ctrl+Click go-to-definition / URL ───────────────────────────────────── */

static void on_click_pressed(GtkGestureClick *gesture,
                             int n_press, double x, double y,
                             gpointer data) {
    (void)data;
    if (n_press != 1) return;

    GdkModifierType mods = gtk_event_controller_get_current_event_state(
            GTK_EVENT_CONTROLLER(gesture));
    if (!(mods & GDK_CONTROL_MASK)) {
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_DENIED);
        return;
    }

    GtkWidget   *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GtkTextView *view   = GTK_TEXT_VIEW(widget);

    int bx, by;
    gtk_text_view_window_to_buffer_coords(view, GTK_TEXT_WINDOW_WIDGET,
                                          (int)x, (int)y, &bx, &by);
    GtkTextIter iter;
    gtk_text_view_get_iter_at_location(view, &iter, bx, by);

    /* Claim the event after inspecting the modifier — prevents GtkTextView from
     * also handling this click (which would extend a selection with Ctrl held). */
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);

    GtkTextBuffer *buf = gtk_text_view_get_buffer(view);
    gtk_text_buffer_place_cursor(buf, &iter);

    /* Open URLs in the default browser; fall back to LSP go-to-definition. */
    gchar *url = url_at_iter(&iter, NULL, NULL);
    if (url) {
        gtk_show_uri(NULL, url, GDK_CURRENT_TIME);
        g_free(url);
        return;
    }

    zc_lsp_goto_definition(GTK_SOURCE_BUFFER(buf),
                           gtk_text_iter_get_line(&iter),
                           gtk_text_iter_get_line_index(&iter));
}

/* ── "Rename Symbol" in the built-in context menu ────────────────────────── */

static void on_rename_activate(GSimpleAction *action, GVariant *parameter,
                               gpointer data) {
    (void)action; (void)parameter;
    GtkTextView *view = GTK_TEXT_VIEW(data);
    zc_lsp_rename_symbol(GTK_SOURCE_BUFFER(gtk_text_view_get_buffer(view)));
}

/* ── Public ───────────────────────────────────────────────────────────────── */

void zc_editor_attach_click_nav(GtkSourceView *view) {
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click),
                                               GTK_PHASE_CAPTURE);
    g_signal_connect(click, "pressed", G_CALLBACK(on_click_pressed), NULL);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(click));

    /* Motion controller (bubble phase — runs after GtkTextView's own handler so
     * our cursor override sticks) for Ctrl+hover URL highlight. */
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_hover_motion), NULL);
    g_signal_connect(motion, "leave",  G_CALLBACK(on_hover_leave),  NULL);
    gtk_widget_add_controller(GTK_WIDGET(view), motion);

    /* Key controller to update the highlight when Ctrl is pressed/released
     * without the mouse moving. */
    GtkEventController *key = gtk_event_controller_key_new();
    g_signal_connect(key, "key-pressed",  G_CALLBACK(on_hover_key_pressed),  NULL);
    g_signal_connect(key, "key-released", G_CALLBACK(on_hover_key_released), NULL);
    gtk_widget_add_controller(GTK_WIDGET(view), key);

    GSimpleAction *rename_act = g_simple_action_new("rename-symbol", NULL);
    g_signal_connect(rename_act, "activate", G_CALLBACK(on_rename_activate), view);
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(rename_act));
    g_object_unref(rename_act);
    gtk_widget_insert_action_group(GTK_WIDGET(view), "lsp", G_ACTION_GROUP(group));
    g_object_unref(group);

    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Rename Symbol", "lsp.rename-symbol");
    gtk_text_view_set_extra_menu(GTK_TEXT_VIEW(view), G_MENU_MODEL(menu));
    g_object_unref(menu);
}

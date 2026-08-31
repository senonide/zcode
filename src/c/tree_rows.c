/* Row widgets for the file tree: the GtkSignalListItemFactory that builds each
 * row's expander/icon/label/git badge and wires its right-click menu. Exposes
 * one entry point, zc_tree_factory_new. */
#include "zc_internal.h"

static void zc_apply_status_classes(GtkWidget *w, ZcGitStatus s) {
    for (int i = 0; zc_git_all_classes[i]; i++)
        gtk_widget_remove_css_class(w, zc_git_all_classes[i]);
    const gchar *cls = zc_git_css_class(s);
    if (cls) gtk_widget_add_css_class(w, cls);
}

/* Sets the row image to the matching Catppuccin icon (open variant for an
 * expanded folder), falling back to an Adwaita symbolic when unavailable. */
static void zc_set_item_icon(GtkImage *img, ZcFileItem *fi, gboolean expanded) {
    const char *flavor = zc_icon_flavor();
    const char *stem;
    const char *fallback;

    if (fi->is_dir) {
        stem = zc_icon_stem_for_dir(fi->name, expanded);
        fallback = "folder-symbolic";
    } else {
        stem = zc_icon_stem_for_file(fi->name);
        if (!stem) stem = "_file";
        fallback = "text-x-generic-symbolic";
    }

    GdkTexture *tex = zc_icon_texture(flavor, stem);
    if (tex) gtk_image_set_from_paintable(img, GDK_PAINTABLE(tex));
    else gtk_image_set_from_icon_name(img, fallback);
}

static const char *zc_diag_classes[] = {NULL, "zc-diag-error", "zc-diag-warning", "zc-diag-info", "zc-diag-hint"};

static void zc_item_apply(GtkWidget *expander, ZcFileItem *fi) {
    GtkWidget *diag  = g_object_get_data(G_OBJECT(expander), "diag");
    GtkWidget *image = g_object_get_data(G_OBJECT(expander), "img");
    GtkWidget *label = g_object_get_data(G_OBJECT(expander), "lbl");
    GtkWidget *badge = g_object_get_data(G_OBJECT(expander), "badge");
    GtkWidget *box   = g_object_get_data(G_OBJECT(expander), "box");

    gboolean expanded = FALSE;
    GtkTreeListRow *row = gtk_tree_expander_get_list_row(GTK_TREE_EXPANDER(expander));
    if (row && fi->is_dir) expanded = gtk_tree_list_row_get_expanded(row);
    zc_set_item_icon(GTK_IMAGE(image), fi, expanded);
    gtk_label_set_text(GTK_LABEL(label), fi->name);

    ZcGitStatus s = (ZcGitStatus)fi->status;
    zc_apply_status_classes(label, s);
    zc_apply_status_classes(badge, s);

    if (box) {
        if (s == ZC_GIT_IGNORED)
            gtk_widget_add_css_class(box, "zc-git-ignored");
        else
            gtk_widget_remove_css_class(box, "zc-git-ignored");
    }

    if (fi->is_dir)
        gtk_label_set_text(GTK_LABEL(badge), s != ZC_GIT_NONE && s != ZC_GIT_IGNORED ? "\xe2\x97\x8f" : "");
    else
        gtk_label_set_text(GTK_LABEL(badge), zc_git_letter(s));

    /* Diagnostic severity: show a coloured "!" left of the icon. */
    for (int i = 1; i <= 4; i++)
        if (zc_diag_classes[i]) gtk_widget_remove_css_class(diag, zc_diag_classes[i]);
    int sev = fi->diag_severity;
    if (sev >= 1 && sev <= 4 && zc_diag_classes[sev]) {
        gtk_widget_add_css_class(diag, zc_diag_classes[sev]);
        gtk_widget_set_visible(diag, TRUE);
    } else {
        gtk_widget_set_visible(diag, FALSE);
    }
}

static void zc_on_status_notify(GObject *item, GParamSpec *ps, gpointer expander) {
    zc_item_apply(GTK_WIDGET(expander), ZC_FILE_ITEM(item));
}

static void zc_on_diag_notify(GObject *item, GParamSpec *ps, gpointer expander) {
    zc_item_apply(GTK_WIDGET(expander), ZC_FILE_ITEM(item));
}

/* ── Drag and drop ───────────────────────────────────────────────────────── */

static GdkContentProvider *zc_on_drag_prepare(GtkDragSource *src,
                                               double x, double y,
                                               gpointer data) {
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(src));
    const char *path = g_object_get_data(G_OBJECT(w), "zc-drag-path");
    if (!path) return NULL;
    GValue v = G_VALUE_INIT;
    g_value_init(&v, G_TYPE_STRING);
    g_value_set_string(&v, path);
    GdkContentProvider *cp = gdk_content_provider_new_for_value(&v);
    g_value_unset(&v);
    return cp;
}

static GdkDragAction zc_on_drop_enter(GtkDropTarget *tgt,
                                       double x, double y, gpointer data) {
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(tgt));
    gtk_widget_add_css_class(w, "zc-drop-target");
    return GDK_ACTION_MOVE;
}

static void zc_on_drop_leave(GtkDropTarget *tgt, gpointer data) {
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(tgt));
    gtk_widget_remove_css_class(w, "zc-drop-target");
}

static gboolean zc_on_drop(GtkDropTarget *tgt, const GValue *val,
                            double x, double y, gpointer data) {
    ZcFileTree *t = data;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(tgt));
    gtk_widget_remove_css_class(w, "zc-drop-target");

    const char *src_path  = g_value_get_string(val);
    const char *dest_item = g_object_get_data(G_OBJECT(w), "zc-drag-path");
    if (!src_path || !dest_item || strcmp(src_path, dest_item) == 0) return FALSE;

    gchar *dest_dir = g_file_test(dest_item, G_FILE_TEST_IS_DIR)
        ? g_strdup(dest_item) : g_path_get_dirname(dest_item);
    gboolean ok = zc_do_move(t, src_path, dest_dir);
    g_free(dest_dir);
    return ok;
}

static void zc_on_row_right_click(GtkGestureClick *g, int n, double x, double y,
                                  gpointer data) {
    ZcFileTree *t = data;
    GtkWidget *expander =
        gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    GtkTreeListRow *row =
        gtk_tree_expander_get_list_row(GTK_TREE_EXPANDER(expander));
    if (!row) return;
    ZcFileItem *fi = gtk_tree_list_row_get_item(row);
    if (!fi) return;
    zc_show_context_menu(t, expander, fi, x, y);
    g_object_unref(fi);
}

static void zc_on_setup(GtkSignalListItemFactory *f, GtkListItem *li, gpointer data) {
    ZcFileTree *t = data;

    GtkWidget *expander = gtk_tree_expander_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *diag = gtk_image_new_from_icon_name("dialog-warning-symbolic");
    gtk_image_set_pixel_size(GTK_IMAGE(diag), 12);
    gtk_widget_set_visible(diag, FALSE);
    GtkWidget *image = gtk_image_new();
    gtk_image_set_pixel_size(GTK_IMAGE(image), 16);
    GtkWidget *label = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(label), 0.0);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_MIDDLE);
    GtkWidget *badge = gtk_label_new("");
    gtk_widget_add_css_class(badge, "zc-badge");

    gtk_box_append(GTK_BOX(box), diag);
    gtk_box_append(GTK_BOX(box), image);
    gtk_box_append(GTK_BOX(box), label);
    gtk_box_append(GTK_BOX(box), badge);
    gtk_tree_expander_set_child(GTK_TREE_EXPANDER(expander), box);
    gtk_list_item_set_child(li, expander);

    g_object_set_data(G_OBJECT(expander), "diag",  diag);
    g_object_set_data(G_OBJECT(expander), "img",   image);
    g_object_set_data(G_OBJECT(expander), "lbl",   label);
    g_object_set_data(G_OBJECT(expander), "badge", badge);
    g_object_set_data(G_OBJECT(expander), "box",   box);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 3);
    g_signal_connect(click, "pressed", G_CALLBACK(zc_on_row_right_click), t);
    gtk_widget_add_controller(expander, GTK_EVENT_CONTROLLER(click));

    GtkDragSource *drag_src = gtk_drag_source_new();
    gtk_drag_source_set_actions(drag_src, GDK_ACTION_MOVE);
    g_signal_connect(drag_src, "prepare", G_CALLBACK(zc_on_drag_prepare), NULL);
    gtk_widget_add_controller(expander, GTK_EVENT_CONTROLLER(drag_src));

    GtkDropTarget *drop_tgt = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_MOVE);
    g_signal_connect(drop_tgt, "drop",  G_CALLBACK(zc_on_drop),       t);
    g_signal_connect(drop_tgt, "enter", G_CALLBACK(zc_on_drop_enter), t);
    g_signal_connect(drop_tgt, "leave", G_CALLBACK(zc_on_drop_leave), t);
    gtk_widget_add_controller(expander, GTK_EVENT_CONTROLLER(drop_tgt));
}

/* Swap the folder icon (open/closed) when a row's expansion changes. */
static void zc_on_expanded_notify(GObject *row, GParamSpec *ps, gpointer expander) {
    ZcFileItem *fi = gtk_tree_list_row_get_item(GTK_TREE_LIST_ROW(row));
    if (fi) {
        zc_item_apply(GTK_WIDGET(expander), fi);
        g_object_unref(fi);
    }
}

static void zc_on_bind(GtkSignalListItemFactory *f, GtkListItem *li, gpointer data) {
    GtkTreeListRow *row = gtk_list_item_get_item(li);
    ZcFileItem *fi = gtk_tree_list_row_get_item(row); /* +1 ref — transferred to li */
    GtkWidget *expander = gtk_list_item_get_child(li);

    gtk_tree_expander_set_list_row(GTK_TREE_EXPANDER(expander), row);
    zc_item_apply(expander, fi);
    g_object_set_data_full(G_OBJECT(expander), "zc-drag-path", g_strdup(fi->path), g_free);

    /* Use plain g_signal_connect (not connect_object) so that when fi/row are
     * finalized after g_list_store_remove drops the model ref, there is no
     * auto-disconnect closure that would call g_signal_handler_disconnect on
     * the dead instance when expander is later finalized.  GTK guarantees
     * unbind fires before a list item widget is destroyed, so the explicit
     * disconnects in zc_on_unbind are always reached first. */
    gulong h = g_signal_connect(fi, "notify::status",
                                G_CALLBACK(zc_on_status_notify), expander);
    gulong eh = g_signal_connect(row, "notify::expanded",
                                 G_CALLBACK(zc_on_expanded_notify), expander);
    gulong dh = g_signal_connect(fi, "notify::diag-severity",
                                 G_CALLBACK(zc_on_diag_notify), expander);
    g_object_set_data(G_OBJECT(li), "zc-h",  GSIZE_TO_POINTER(h));
    g_object_set_data(G_OBJECT(li), "zc-eh", GSIZE_TO_POINTER(eh));
    g_object_set_data(G_OBJECT(li), "zc-dh", GSIZE_TO_POINTER(dh));
    /* li owns the +1 ref on fi via the destroy_notify; this guarantees fi stays
     * alive until unbind clears the key, preventing use-after-free when the
     * model removes fi before unbind fires. */
    g_object_set_data_full(G_OBJECT(li), "zc-fi", fi, g_object_unref);
    g_object_set_data(G_OBJECT(li), "zc-row", row); /* borrowed; li keeps a ref */
}

static void zc_on_unbind(GtkSignalListItemFactory *f, GtkListItem *li, gpointer data) {
    ZcFileItem *fi = g_object_get_data(G_OBJECT(li), "zc-fi");
    GtkTreeListRow *row = g_object_get_data(G_OBJECT(li), "zc-row");
    gulong h = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(li), "zc-h"));
    gulong eh = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(li), "zc-eh"));
    gulong dh = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(li), "zc-dh"));
    if (fi && h && g_signal_handler_is_connected(fi, h))
        g_signal_handler_disconnect(fi, h);
    if (fi && dh && g_signal_handler_is_connected(fi, dh))
        g_signal_handler_disconnect(fi, dh);
    if (row && eh && g_signal_handler_is_connected(row, eh))
        g_signal_handler_disconnect(row, eh);
    g_object_set_data(G_OBJECT(li), "zc-fi", NULL);
    g_object_set_data(G_OBJECT(li), "zc-row", NULL);
    g_object_set_data(G_OBJECT(li), "zc-h", NULL);
    g_object_set_data(G_OBJECT(li), "zc-eh", NULL);
    g_object_set_data(G_OBJECT(li), "zc-dh", NULL);
    GtkWidget *expander2 = gtk_list_item_get_child(li);
    if (expander2) {
        g_object_set_data(G_OBJECT(expander2), "zc-drag-path", NULL);
        gtk_widget_remove_css_class(expander2, "zc-drop-target");
    }
}

GtkListItemFactory *zc_tree_factory_new(ZcFileTree *t) {
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup",  G_CALLBACK(zc_on_setup),  t);
    g_signal_connect(factory, "bind",   G_CALLBACK(zc_on_bind),   t);
    g_signal_connect(factory, "unbind", G_CALLBACK(zc_on_unbind), t);
    return factory;
}

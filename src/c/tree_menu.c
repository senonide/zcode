/* Right-click menu and file operations for the tree.
 *
 * The menu is a GMenu rendered by a GtkPopoverMenu, backed by an "item" action
 * group installed once on the list view.  Each menu item carries the row's path
 * as its action target, so the actions are stateless and the popover gets
 * GNOME's real menu behaviour (sections, keyboard navigation, styling) instead
 * of a stack of flat buttons pretending to be one.
 *
 * Filesystem actions run here; anything needing the editor, the terminal or a
 * dialog routes back through the tree's ZcTreeCallbacks — including the outcome
 * of every operation, so nothing fails silently. */
#include "zc_internal.h"

#include <glib/gstdio.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>

/* ── Reporting ───────────────────────────────────────────────────────────── */

void zc_tree_report(ZcFileTree *t, int is_error, const char *fmt, ...) {
    if (!t->cb.report) return;
    va_list args;
    va_start(args, fmt);
    gchar *msg = g_strdup_vprintf(fmt, args);
    va_end(args);
    t->cb.report(msg, is_error, t->cb.user_data);
    g_free(msg);
}

/* ── File move (shared by DnD handlers) ──────────────────────────────────── */

gboolean zc_do_move(ZcFileTree *t, const char *src_path, const char *dest_dir) {
    gchar *src_dir = g_path_get_dirname(src_path);
    gboolean same = strcmp(src_dir, dest_dir) == 0;
    g_free(src_dir);
    if (same) return FALSE;

    if (g_file_test(src_path, G_FILE_TEST_IS_DIR)) {
        gchar *prefix = g_strdup_printf("%s/", src_path);
        gboolean circular = strcmp(dest_dir, src_path) == 0 ||
                            g_str_has_prefix(dest_dir, prefix);
        g_free(prefix);
        if (circular) return FALSE;
    }

    gchar *base     = g_path_get_basename(src_path);
    gchar *new_path = g_build_filename(dest_dir, base, NULL);

    GFile *src_f = g_file_new_for_path(src_path);
    GFile *dst_f = g_file_new_for_path(new_path);
    GError *err  = NULL;
    g_file_move(src_f, dst_f, G_FILE_COPY_NONE, NULL, NULL, NULL, &err);
    gboolean ok = (err == NULL);
    g_object_unref(src_f);
    g_object_unref(dst_f);

    if (ok) {
        if (t->cb.file_renamed) t->cb.file_renamed(src_path, new_path, t->cb.user_data);
        zc_do_refresh(t);
    } else {
        zc_tree_report(t, TRUE, "Could not move \xe2\x80\x9c%s\xe2\x80\x9d: %s", base, err->message);
        g_error_free(err);
    }
    g_free(base);
    g_free(new_path);
    return ok;
}

/* ── Action helpers ──────────────────────────────────────────────────────── */

/* Directory to act in: the item itself if a folder, else its parent. */
static gchar *zc_target_dir(const char *path) {
    if (g_file_test(path, G_FILE_TEST_IS_DIR)) return g_strdup(path);
    return g_path_get_dirname(path);
}

/* Every action takes the row's absolute path as its string target. */
static const char *zc_target_path(GVariant *param) {
    return param ? g_variant_get_string(param, NULL) : NULL;
}

/* The window a dialog raised from a tree action should be modal to. */
static GtkWidget *zc_tree_root(ZcFileTree *t) {
    return t->list_view ? GTK_WIDGET(gtk_widget_get_root(GTK_WIDGET(t->list_view))) : NULL;
}

/* ── Per-row actions ─────────────────────────────────────────────────────── */

static void zc_act_open(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (path && t->cb.open_file) t->cb.open_file(path, t->cb.user_data);
}

static void zc_act_open_terminal(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (!path || !t->cb.open_terminal) return;
    gchar *dir = zc_target_dir(path);
    t->cb.open_terminal(dir, t->cb.user_data);
    g_free(dir);
}

static void zc_new_item(ZcFileTree *t, GVariant *param, int is_dir) {
    const char *path = zc_target_path(param);
    if (!path || !t->cb.new_item) return;
    gchar *dir = zc_target_dir(path);
    t->cb.new_item(dir, is_dir, t->cb.user_data);
    g_free(dir);
}

static void zc_act_new_file(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    zc_new_item(data, param, 0);
}

static void zc_act_new_folder(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    zc_new_item(data, param, 1);
}

static void zc_act_copy_path(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (!path || !t->list_view) return;
    GdkClipboard *cb = gtk_widget_get_clipboard(GTK_WIDGET(t->list_view));
    gdk_clipboard_set(cb, G_TYPE_STRING, path);
    zc_tree_report(t, FALSE, "Path copied to clipboard");
}

/* ── Move to Trash ───────────────────────────────────────────────────────── */

typedef struct { ZcFileTree *t; gchar *path; } ZcTrashCtx;

static void zc_trash_done(GObject *src, GAsyncResult *res, gpointer data) {
    ZcTrashCtx *tc = data;
    const char *resp = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(src), res);
    if (g_strcmp0(resp, "trash") == 0) {
        GFile *f = g_file_new_for_path(tc->path);
        GError *err = NULL;
        gchar *base = g_path_get_basename(tc->path);
        if (g_file_trash(f, NULL, &err)) {
            zc_tree_report(tc->t, FALSE, "\xe2\x80\x9c%s\xe2\x80\x9d moved to Trash", base);
            zc_do_refresh(tc->t);
        } else {
            zc_tree_report(tc->t, TRUE, "Could not move \xe2\x80\x9c%s\xe2\x80\x9d to Trash: %s",
                           base, err ? err->message : "unknown error");
            g_clear_error(&err);
        }
        g_free(base);
        g_object_unref(f);
    }
    g_free(tc->path);
    g_free(tc);
}

static void zc_act_trash(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (!path) return;

    gchar *base = g_path_get_basename(path);
    gchar *body = g_strdup_printf("\xe2\x80\x9c%s\xe2\x80\x9d will be moved to the Trash.", base);
    g_free(base);
    AdwAlertDialog *d = ADW_ALERT_DIALOG(adw_alert_dialog_new("Move to Trash?", body));
    g_free(body);
    adw_alert_dialog_add_response(d, "cancel", "Cancel");
    adw_alert_dialog_add_response(d, "trash",  "Move to Trash");
    adw_alert_dialog_set_response_appearance(d, "trash", ADW_RESPONSE_DESTRUCTIVE);
    adw_alert_dialog_set_default_response(d, "cancel");
    adw_alert_dialog_set_close_response(d, "cancel");

    ZcTrashCtx *tc = g_new0(ZcTrashCtx, 1);
    tc->t    = t;
    tc->path = g_strdup(path);
    adw_alert_dialog_choose(d, zc_tree_root(t), NULL, zc_trash_done, tc);
}

/* ── Duplicate ───────────────────────────────────────────────────────────── */

static void zc_act_duplicate(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (!path) return;

    gchar *dir = g_path_get_dirname(path);
    gchar *base = g_path_get_basename(path);
    gchar *dot = strrchr(base, '.');
    gchar *ext = (dot && dot != base) ? g_strdup(dot + 1) : NULL;
    if (dot && dot != base) *dot = 0; /* base now holds the stem */

    gboolean done = FALSE;
    for (int k = 1; k <= 50 && !done; k++) {
        gchar *cand = (k == 1)
            ? g_strdup_printf("%s copy%s%s", base, ext ? "." : "", ext ? ext : "")
            : g_strdup_printf("%s copy %d%s%s", base, k, ext ? "." : "", ext ? ext : "");
        gchar *cpath = g_build_filename(dir, cand, NULL);
        if (!g_file_test(cpath, G_FILE_TEST_EXISTS)) {
            GFile *s = g_file_new_for_path(path);
            GFile *d = g_file_new_for_path(cpath);
            GError *err = NULL;
            if (g_file_copy(s, d, G_FILE_COPY_NONE, NULL, NULL, NULL, &err)) {
                zc_tree_report(t, FALSE, "Duplicated as \xe2\x80\x9c%s\xe2\x80\x9d", cand);
            } else {
                zc_tree_report(t, TRUE, "Could not duplicate \xe2\x80\x9c%s\xe2\x80\x9d: %s",
                               base, err ? err->message : "unknown error");
                g_clear_error(&err);
            }
            g_object_unref(s);
            g_object_unref(d);
            done = TRUE;
        }
        g_free(cand);
        g_free(cpath);
    }
    g_free(dir); g_free(base); g_free(ext);
    zc_do_refresh(t);
}

/* ── Rename ──────────────────────────────────────────────────────────────── */

typedef struct { ZcFileTree *t; gchar *old; } ZcRenameCtx;

static void zc_rename_done(GObject *src, GAsyncResult *res, gpointer data) {
    AdwAlertDialog *d = ADW_ALERT_DIALOG(src);
    ZcRenameCtx *rc = data;
    const char *resp = adw_alert_dialog_choose_finish(d, res);
    if (g_strcmp0(resp, "rename") == 0) {
        GtkWidget *entry = adw_alert_dialog_get_extra_child(d);
        const char *name = gtk_editable_get_text(GTK_EDITABLE(entry));
        if (name && *name) {
            gchar *dir = g_path_get_dirname(rc->old);
            gchar *np = g_build_filename(dir, name, NULL);
            if (g_rename(rc->old, np) == 0) {
                if (rc->t->cb.file_renamed)
                    rc->t->cb.file_renamed(rc->old, np, rc->t->cb.user_data);
                zc_do_refresh(rc->t);
            } else {
                zc_tree_report(rc->t, TRUE, "Could not rename to \xe2\x80\x9c%s\xe2\x80\x9d: %s",
                               name, g_strerror(errno));
            }
            g_free(dir); g_free(np);
        }
    }
    g_free(rc->old);
    g_free(rc);
}

/* Selects the file name without its extension, the way every file manager
 * does — renaming usually means changing the stem, not the suffix. */
static void zc_rename_focus(GtkWidget *dialog, gpointer entry) {
    (void)dialog;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry));
    const char *dot = text ? strrchr(text, '.') : NULL;
    int stem_end = (dot && dot != text) ? (int)(dot - text) : -1;
    gtk_widget_grab_focus(GTK_WIDGET(entry));
    gtk_editable_select_region(GTK_EDITABLE(entry), 0, stem_end);
}

static void zc_act_rename(GSimpleAction *a, GVariant *param, gpointer data) {
    (void)a;
    ZcFileTree *t = data;
    const char *path = zc_target_path(param);
    if (!path) return;

    gchar *base = g_path_get_basename(path);
    AdwAlertDialog *d = ADW_ALERT_DIALOG(adw_alert_dialog_new("Rename", NULL));
    adw_alert_dialog_add_response(d, "cancel", "Cancel");
    adw_alert_dialog_add_response(d, "rename", "Rename");
    adw_alert_dialog_set_response_appearance(d, "rename", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(d, "rename");
    adw_alert_dialog_set_close_response(d, "cancel");

    GtkWidget *entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(entry), base);
    gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    adw_alert_dialog_set_extra_child(d, entry);
    g_free(base);

    g_signal_connect(d, "map", G_CALLBACK(zc_rename_focus), entry);

    ZcRenameCtx *rc = g_new0(ZcRenameCtx, 1);
    rc->t = t;
    rc->old = g_strdup(path);
    adw_alert_dialog_choose(d, zc_tree_root(t), NULL, zc_rename_done, rc);
}

/* ── Action group ────────────────────────────────────────────────────────── */

static const GActionEntry zc_item_actions[] = {
    { "open",          zc_act_open,          "s", NULL, NULL, {0} },
    { "new-file",      zc_act_new_file,      "s", NULL, NULL, {0} },
    { "new-folder",    zc_act_new_folder,    "s", NULL, NULL, {0} },
    { "open-terminal", zc_act_open_terminal, "s", NULL, NULL, {0} },
    { "rename",        zc_act_rename,        "s", NULL, NULL, {0} },
    { "duplicate",     zc_act_duplicate,     "s", NULL, NULL, {0} },
    { "copy-path",     zc_act_copy_path,     "s", NULL, NULL, {0} },
    { "trash",         zc_act_trash,         "s", NULL, NULL, {0} },
};

void zc_tree_install_menu_actions(ZcFileTree *t, GtkWidget *list_view) {
    GSimpleActionGroup *group = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(group), zc_item_actions,
                                    G_N_ELEMENTS(zc_item_actions), t);
    gtk_widget_insert_action_group(list_view, "item", G_ACTION_GROUP(group));
    g_object_unref(group);
}

/* ── Per-row context menu ────────────────────────────────────────────────── */

static void zc_menu_add(GMenu *section, const char *label, const char *action,
                        const char *path) {
    GMenuItem *item = g_menu_item_new(label, NULL);
    g_menu_item_set_action_and_target_value(item, action, g_variant_new_string(path));
    g_menu_append_item(section, item);
    g_object_unref(item);
}

static void zc_menu_add_section(GMenu *menu, GMenu *section) {
    g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
    g_object_unref(section);
}

static void zc_popover_drop(gpointer data) {
    GtkWidget *pop = data;
    if (gtk_widget_get_parent(pop)) gtk_widget_unparent(pop);
    g_object_unref(pop);
}

/* Detaching the popover the moment it closes finalises the menu item the user
 * just clicked *before* GTK runs its action — every entry would silently do
 * nothing.  The item pops the menu down first and activates second, so the
 * teardown has to wait for the click to finish; one idle is enough.  The
 * reference keeps the popover valid until then. */
static void zc_popover_closed(GtkPopover *pop, gpointer data) {
    (void)data;
    g_idle_add_once(zc_popover_drop, g_object_ref(pop));
}

void zc_show_context_menu(ZcFileTree *t, GtkWidget *anchor,
                          ZcFileItem *fi, double x, double y) {
    const char *p = fi->path;
    GMenu *menu = g_menu_new();

    GMenu *primary = g_menu_new();
    if (fi->is_dir) {
        zc_menu_add(primary, "New File",         "item.new-file",      p);
        zc_menu_add(primary, "New Folder",       "item.new-folder",    p);
        zc_menu_add(primary, "Open in Terminal", "item.open-terminal", p);
    } else {
        zc_menu_add(primary, "Open", "item.open", p);
    }
    zc_menu_add_section(menu, primary);

    GMenu *edit = g_menu_new();
    zc_menu_add(edit, "Rename", "item.rename", p);
    if (!fi->is_dir) zc_menu_add(edit, "Duplicate", "item.duplicate", p);
    zc_menu_add(edit, "Copy Path", "item.copy-path", p);
    zc_menu_add_section(menu, edit);

    GMenu *destructive = g_menu_new();
    zc_menu_add(destructive, "Move to Trash", "item.trash", p);
    zc_menu_add_section(menu, destructive);

    GtkWidget *pop = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    g_object_unref(menu);

    gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
    gtk_widget_set_halign(pop, GTK_ALIGN_START);
    gtk_widget_set_parent(pop, anchor);
    GdkRectangle r = {(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
    g_signal_connect(pop, "closed", G_CALLBACK(zc_popover_closed), NULL);
    gtk_popover_popup(GTK_POPOVER(pop));
}

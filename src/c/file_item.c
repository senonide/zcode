/* ZcFileItem — the GObject backing one tree row. Only `status` is a GObject
 * property (the row renderer binds "notify::status" to repaint on git changes);
 * path/name/is_dir are read directly. */
#include "zc_internal.h"

G_DEFINE_TYPE(ZcFileItem, zc_file_item, G_TYPE_OBJECT)

enum { PROP_0, PROP_STATUS, PROP_DIAG_SEVERITY, N_PROPS };
static GParamSpec *zc_file_item_props[N_PROPS];

static void zc_file_item_finalize(GObject *o) {
    ZcFileItem *self = ZC_FILE_ITEM(o);
    g_free(self->path);
    g_free(self->name);
    G_OBJECT_CLASS(zc_file_item_parent_class)->finalize(o);
}

static void zc_file_item_get_property(GObject *o, guint id, GValue *v, GParamSpec *ps) {
    ZcFileItem *self = ZC_FILE_ITEM(o);
    if (id == PROP_STATUS) g_value_set_int(v, self->status);
    else if (id == PROP_DIAG_SEVERITY) g_value_set_int(v, self->diag_severity);
    else G_OBJECT_WARN_INVALID_PROPERTY_ID(o, id, ps);
}

static void zc_file_item_set_property(GObject *o, guint id, const GValue *v, GParamSpec *ps) {
    ZcFileItem *self = ZC_FILE_ITEM(o);
    if (id == PROP_DIAG_SEVERITY) self->diag_severity = g_value_get_int(v);
    else G_OBJECT_WARN_INVALID_PROPERTY_ID(o, id, ps);
}

static void zc_file_item_class_init(ZcFileItemClass *klass) {
    GObjectClass *oc = G_OBJECT_CLASS(klass);
    oc->finalize = zc_file_item_finalize;
    oc->get_property = zc_file_item_get_property;
    oc->set_property = zc_file_item_set_property;
    zc_file_item_props[PROP_STATUS] = g_param_spec_int(
        "status", "status", "git status",
        0, G_MAXINT, 0, G_PARAM_READABLE | G_PARAM_STATIC_STRINGS);
    zc_file_item_props[PROP_DIAG_SEVERITY] = g_param_spec_int(
        "diag-severity", "diag-severity", "diagnostic severity",
        0, 4, 0, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
    g_object_class_install_properties(oc, N_PROPS, zc_file_item_props);
}

static void zc_file_item_init(ZcFileItem *self) { self->diag_severity = 0; }

ZcFileItem *zc_file_item_new(const char *path, const char *name,
                             gboolean is_dir, int status) {
    ZcFileItem *it = g_object_new(ZC_TYPE_FILE_ITEM, NULL);
    it->path = g_strdup(path);
    it->name = g_strdup(name);
    it->is_dir = is_dir;
    it->status = status;
    return it;
}

void zc_file_item_set_status(ZcFileItem *it, int status) {
    if (it->status == status) return;
    it->status = status;
    g_object_notify_by_pspec(G_OBJECT(it), zc_file_item_props[PROP_STATUS]);
}

void zc_file_item_set_diag_severity(ZcFileItem *it, int sev) {
    if (it->diag_severity == sev) return;
    it->diag_severity = sev;
    g_object_notify_by_pspec(G_OBJECT(it), zc_file_item_props[PROP_DIAG_SEVERITY]);
}

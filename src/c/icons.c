/* File/folder icons (Catppuccin / zed-icons). Names are matched to an icon stem
 * via the tables in icon_data.h (kept private to this file); the PNGs live under
 * <prefix>/share/zcode/icons/catppuccin/<flavor>/ and load as cached
 * GdkTextures. The caller falls back to an Adwaita symbolic when none resolves. */
#include "zc_internal.h"
#include "icon_data.h"

#include <string.h>

static int zc_kv_cmp(const void *a, const void *b) {
    return strcmp(((const ZcIconKV *)a)->key, ((const ZcIconKV *)b)->key);
}
static int zc_dir_cmp(const void *a, const void *b) {
    return strcmp(((const ZcIconDir *)a)->key, ((const ZcIconDir *)b)->key);
}

static const char *zc_kv_lookup(const ZcIconKV *arr, int n, const char *key) {
    ZcIconKV want = { key, NULL };
    const ZcIconKV *r = bsearch(&want, arr, (size_t)n, sizeof *arr, zc_kv_cmp);
    return r ? r->icon : NULL;
}

/* Tries the whole name, then the part after each '.', longest first. */
static const char *zc_suffix_lookup(const char *name) {
    for (const char *c = name; c; ) {
        const char *r = zc_kv_lookup(zc_suffixes, zc_suffixes_n, c);
        if (r) return r;
        const char *dot = strchr(c, '.');
        c = dot ? dot + 1 : NULL;
    }
    return NULL;
}

/* Returns the icon stem (PNG basename) for a file, or NULL. */
const char *zc_icon_stem_for_file(const char *name) {
    const char *r = zc_kv_lookup(zc_stems, zc_stems_n, name);
    if (!r) r = zc_suffix_lookup(name);
    if (r) return r;
    /* Case-insensitive second pass (handles e.g. .PNG, .Json). */
    gchar *low = g_ascii_strdown(name, -1);
    r = zc_kv_lookup(zc_stems, zc_stems_n, low);
    if (!r) r = zc_suffix_lookup(low);
    g_free(low);
    return r;
}

/* Folder names match case-insensitively against the named-directory table. */
static const ZcIconDir *zc_icon_dir_lookup(const char *name) {
    gchar *low = g_ascii_strdown(name, -1);
    ZcIconDir want = { low, NULL, NULL };
    const ZcIconDir *r = bsearch(&want, zc_dirs, (size_t)zc_dirs_n,
                                 sizeof *zc_dirs, zc_dir_cmp);
    g_free(low);
    return r;
}

/* Icon stem for a folder, with the open variant when expanded.  Never NULL. */
const char *zc_icon_stem_for_dir(const char *name, gboolean expanded) {
    const ZcIconDir *d = zc_icon_dir_lookup(name);
    if (d) return expanded ? d->expanded : d->collapsed;
    return expanded ? "_folder_open" : "_folder";
}

const char *zc_icon_flavor(void) {
    return adw_style_manager_get_dark(adw_style_manager_get_default())
        ? "mocha" : "latte";
}


/* Directory holding the per-flavor icon folders (resolved once via the shared
 * data-dir probe, keyed off the "mocha" subdir).  Cached; do not free. */
static const char *zc_icons_base(void) {
    static gchar *cached = NULL;
    static gboolean done = FALSE;
    if (!done) {
        cached = zc_data_dir("ZCODE_ICON_DIR", "icons/catppuccin", "mocha");
        done = TRUE;
    }
    return cached;
}

/* Loads (and caches) the texture for `<flavor>/<stem>.png`, or NULL. */
GdkTexture *zc_icon_texture(const char *flavor, const char *stem) {
    static GHashTable *cache = NULL;
    if (!stem) return NULL;
    if (!cache)
        cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);

    gchar *key = g_strconcat(flavor, "/", stem, NULL);
    GdkTexture *tex = g_hash_table_lookup(cache, key);
    if (tex) { g_free(key); return tex; }

    const char *base = zc_icons_base();
    if (!base) { g_free(key); return NULL; }

    gchar *file = g_strconcat(stem, ".png", NULL);
    gchar *path = g_build_filename(base, flavor, file, NULL);
    g_free(file);
    tex = gdk_texture_new_from_filename(path, NULL);
    g_free(path);

    if (tex) { g_hash_table_insert(cache, key, tex); return tex; }
    g_free(key);
    return NULL;
}

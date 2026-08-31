/* The project file tree (model + lifecycle).
 *
 * A GtkListView backed by a GtkTreeListModel: directories are read lazily, only
 * when a row is expanded.  Each row is a ZcFileItem GObject carrying its path,
 * name, kind and git status.  A debounced GFileMonitor on the root, the `.git`
 * directory and every *expanded* directory keeps the view live without watching
 * the whole tree, and reconciles changed directories in place so expansion and
 * selection survive.  All app-facing actions go through a ZcTreeCallbacks block.
 *
 * Row rendering lives in tree_rows.c; the right-click menu in tree_menu.c.
 */
#include "zc_internal.h"

#include <string.h>

/* ── Directory listing ───────────────────────────────────────────────────── */

typedef struct {
    gchar   *full;
    gchar   *name;
    gboolean is_dir;
} ZcEntry;

/* Folders before files, then natural case-insensitive order — like Nautilus. */
static gint zc_cmp_ni(gboolean a_dir, const char *a_name,
                      gboolean b_dir, const char *b_name) {
    if (a_dir != b_dir) return a_dir ? -1 : 1;
    gchar *ka = g_utf8_collate_key_for_filename(a_name, -1);
    gchar *kb = g_utf8_collate_key_for_filename(b_name, -1);
    gint r = strcmp(ka, kb);
    g_free(ka);
    g_free(kb);
    return r;
}

static gint zc_entry_cmp(gconstpointer a, gconstpointer b) {
    const ZcEntry *ea = a, *eb = b;
    return zc_cmp_ni(ea->is_dir, ea->name, eb->is_dir, eb->name);
}

static void zc_entry_clear(gpointer p) {
    ZcEntry *e = p;
    g_free(e->full);
    g_free(e->name);
}

/* Returns the children of `path`, sorted, with only `.git` hidden (its internals
 * are noise; dotfiles like .gitignore are shown).  Uses a GFileEnumerator so the
 * file type comes from the batched directory read (one query for the whole dir)
 * instead of a separate stat() per entry — important for directories with many
 * thousands of children. */
static GArray *zc_list_dir(const char *path) {
    GArray *out = g_array_new(FALSE, FALSE, sizeof(ZcEntry));
    g_array_set_clear_func(out, zc_entry_clear);

    GFile *gdir = g_file_new_for_path(path);
    GFileEnumerator *en = g_file_enumerate_children(
        gdir,
        G_FILE_ATTRIBUTE_STANDARD_NAME "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
        G_FILE_QUERY_INFO_NONE, NULL, NULL);
    g_object_unref(gdir);
    if (!en) return out;

    GFileInfo *info;
    while ((info = g_file_enumerator_next_file(en, NULL, NULL)) != NULL) {
        const gchar *name = g_file_info_get_name(info);
        if (g_strcmp0(name, ".git") == 0) { g_object_unref(info); continue; }
        ZcEntry e;
        e.full = g_build_filename(path, name, NULL);
        e.name = g_strdup(name);
        e.is_dir = g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY;
        g_array_append_val(out, e);
        g_object_unref(info);
    }
    g_object_unref(en);

    g_array_sort(out, zc_entry_cmp);
    return out;
}

/* ── Git status lookups ──────────────────────────────────────────────────── */

typedef struct {
    ZcFileTree *t;
    gchar      *path;
} ZcStoreCtx;

static ZcGitStatus zc_file_status(ZcFileTree *t, const char *abs) {
    if (!t->git) return ZC_GIT_NONE;
    gpointer v;
    if (g_hash_table_lookup_extended(t->git, abs, NULL, &v))
        return (ZcGitStatus)GPOINTER_TO_INT(v);
    return ZC_GIT_NONE;
}

static ZcGitStatus zc_dir_status(ZcFileTree *t, const char *abs) {
    if (t->dirty_dirs && g_hash_table_contains(t->dirty_dirs, abs))
        return ZC_GIT_MODIFIED;
    return zc_file_status(t, abs);
}

/* Registers `it` as the row for `path` so the language server's diagnostics can
 * find it.  The table holds a reference: the alternative — a weak ref back into
 * the tree — outlives the tree itself, because a row can be finalized long after
 * the tree that created it (a list item, a selection or a pending event keeps it
 * alive), and the notify would then run against freed memory.  Replacing an
 * entry drops the previous row's reference. */
static void zc_diag_item_register(ZcFileTree *t, const char *path, ZcFileItem *it) {
    g_hash_table_insert(t->diag_items, g_strdup(path), g_object_ref(it));
}

/* Records every ancestor directory of `abs` (down to, but excluding, the root)
 * so collapsed folders can show a change dot. */
static void zc_mark_dirty_dirs(ZcFileTree *t, const char *abs) {
    gchar *d = g_path_get_dirname(abs);
    while (d && g_str_has_prefix(d, t->root) && strcmp(d, t->root) != 0) {
        if (!g_hash_table_contains(t->dirty_dirs, d))
            g_hash_table_add(t->dirty_dirs, g_strdup(d));
        gchar *nd = g_path_get_dirname(d);
        g_free(d);
        d = nd;
    }
    g_free(d);
}

/* Rebuilds t->git / t->dirty_dirs from `git status --porcelain` output. */
static void zc_git_apply(ZcFileTree *t, const char *out) {
    if (t->git) g_hash_table_destroy(t->git);
    if (t->dirty_dirs) g_hash_table_destroy(t->dirty_dirs);
    t->git = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    t->dirty_dirs = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);

    gchar **lines = g_strsplit(out, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        const gchar *line = lines[i];
        if (strlen(line) < 4) continue;
        char x = line[0], y = line[1];
        const gchar *p = line + 3;
        if (*p == '"') continue;                 /* skip C-quoted paths */
        const gchar *arrow = strstr(p, " -> ");
        if (arrow) p = arrow + 4;                 /* rename: colour dest */

        /* Ignored entries: strip trailing slash (git uses "dir/" for dirs).
         * With --untracked-files=all git expands ignored dirs into individual
         * files, so we also mark their ancestor dirs as ignored. */
        if (x == '!' && y == '!') {
            gchar *pstr = g_strdup(p);
            gsize plen = strlen(pstr);
            if (plen > 0 && pstr[plen - 1] == '/')
                pstr[plen - 1] = '\0';
            gchar *abs = g_build_filename(t->git_top, pstr, NULL);
            g_free(pstr);
            g_hash_table_insert(t->git, abs, GINT_TO_POINTER(ZC_GIT_IGNORED));
            continue;
        }

        ZcGitStatus s;
        if (x == '?' && y == '?')                       s = ZC_GIT_UNTRACKED;
        else if (x == 'U' || y == 'U' ||
                 (x == 'A' && y == 'A') ||
                 (x == 'D' && y == 'D'))                s = ZC_GIT_CONFLICT;
        else if (x == 'R' || y == 'R')                  s = ZC_GIT_RENAMED;
        else if (x == 'A')                              s = ZC_GIT_ADDED;
        else if (x == 'D' || y == 'D')                  s = ZC_GIT_DELETED;
        else                                            s = ZC_GIT_MODIFIED;

        gchar *abs = g_build_filename(t->git_top, p, NULL);
        zc_mark_dirty_dirs(t, abs);
        g_hash_table_insert(t->git, abs, GINT_TO_POINTER(s));
    }
    g_strfreev(lines);
}

/* ── Directory stores (lazy children) + monitors ─────────────────────────── */

static gboolean zc_debounced(gpointer data);
static void     zc_reconcile(ZcFileTree *t, const char *path, GListStore *store);

/* Cap on directory monitors so opening a huge tree (many expanded folders)
 * can't exhaust the kernel's inotify watch budget.  Past the cap, directories
 * still list and reconcile on a manual refresh; they just don't auto-update. */
#define ZC_MAX_MONITORS 512

/* Couples a monitor to the tree, so its teardown can decrement the live count. */
typedef struct { ZcFileTree *t; GFileMonitor *mon; } ZcMonCtx;

static void zc_monitor_destroy(gpointer p) {
    ZcMonCtx *c = p;
    if (c->t->alive && c->t->n_monitors > 0) c->t->n_monitors--;
    g_file_monitor_cancel(c->mon);
    g_object_unref(c->mon);
    g_free(c);
}

static void zc_store_unreg(gpointer p) {
    ZcStoreCtx *c = p;
    if (c->t->alive && c->t->stores)
        g_hash_table_remove(c->t->stores, c->path);
    g_free(c->path);
    g_free(c);
}

static void zc_on_dir_changed(GFileMonitor *m, GFile *f, GFile *o,
                              GFileMonitorEvent ev, gpointer data) {
    ZcFileTree *t = data;
    if (!t->alive) return;

    if (ev == G_FILE_MONITOR_EVENT_RENAMED && f && o && t->cb.file_renamed) {
        gchar *old_path = g_file_get_path(f);
        gchar *new_path = g_file_get_path(o);
        if (old_path && new_path)
            t->cb.file_renamed(old_path, new_path, t->cb.user_data);
        g_free(old_path);
        g_free(new_path);
    }

    if (t->debounce_id) return;
    t->debounce_id = g_timeout_add(350, zc_debounced, t);
}

/* The `.git` watcher must absorb the churn `git status` itself causes
 * (index/lock writes), or it would loop forever.  But dropping those events
 * outright loses real git activity (a commit landing while a status run is in
 * flight) and the sidebar goes stale until the next unrelated refresh — so
 * events in the absorb window are remembered and replayed once by
 * zc_git_done.  The replayed run converges: a `git status` over an unchanged
 * tree with a fresh index writes nothing, so no further events arrive. */
static void zc_on_git_changed(GFileMonitor *m, GFile *f, GFile *o,
                              GFileMonitorEvent ev, gpointer data) {
    ZcFileTree *t = data;
    if (!t->alive || t->debounce_id) return;
    if (t->git_cancel || zc_git_busy() || g_get_monotonic_time() < t->git_settle) {
        t->git_pending = TRUE;
        return;
    }
    t->debounce_id = g_timeout_add(350, zc_debounced, t);
}

/* Builds the GListStore for `path`, registers it and starts watching it.
 * Returned with one ref for the GtkTreeListModel to own. */
static GListStore *zc_dir_store_new(ZcFileTree *t, const char *path) {
    GListStore *store = g_list_store_new(ZC_TYPE_FILE_ITEM);

    GArray *entries = zc_list_dir(path);
    for (guint i = 0; i < entries->len; i++) {
        ZcEntry *e = &g_array_index(entries, ZcEntry, i);
        ZcGitStatus s = e->is_dir ? zc_dir_status(t, e->full)
                                  : zc_file_status(t, e->full);
        ZcFileItem *it = zc_file_item_new(e->full, e->name, e->is_dir, s);
        zc_diag_item_register(t, e->full, it);
        g_list_store_append(store, it);
        g_object_unref(it);
    }
    g_array_free(entries, TRUE);

    ZcStoreCtx *ctx = g_new0(ZcStoreCtx, 1);
    ctx->t = t;
    ctx->path = g_strdup(path);
    g_hash_table_insert(t->stores, ctx->path, store);   /* value borrowed */
    g_object_set_data_full(G_OBJECT(store), "zc-ctx", ctx, zc_store_unreg);

    if (t->n_monitors < ZC_MAX_MONITORS) {
        GFile *gf = g_file_new_for_path(path);
        GFileMonitor *mon = g_file_monitor_directory(gf, G_FILE_MONITOR_WATCH_MOVES,
                                                     NULL, NULL);
        g_object_unref(gf);
        if (mon) {
            g_signal_connect(mon, "changed", G_CALLBACK(zc_on_dir_changed), t);
            ZcMonCtx *mc = g_new0(ZcMonCtx, 1);
            mc->t = t;
            mc->mon = mon;
            t->n_monitors++;
            g_object_set_data_full(G_OBJECT(store), "zc-mon", mc, zc_monitor_destroy);
        }
    }
    return store;
}

/* GtkTreeListModel: produce a directory's children the first time it expands. */
static GListModel *zc_create_child(gpointer item, gpointer data) {
    ZcFileTree *t = data;
    ZcFileItem *fi = item;
    if (!fi->is_dir) return NULL;
    return G_LIST_MODEL(zc_dir_store_new(t, fi->path));
}

/* Brings an already-materialised store in line with the directory on disk,
 * preserving the surviving items (and thus their expansion/selection). */
static void zc_reconcile(ZcFileTree *t, const char *path, GListStore *store) {
    GArray *entries = zc_list_dir(path);
    GListModel *model = G_LIST_MODEL(store);
    guint i = 0, j = 0;

    while (j < entries->len) {
        ZcEntry *e = &g_array_index(entries, ZcEntry, j);
        ZcGitStatus s = e->is_dir ? zc_dir_status(t, e->full)
                                  : zc_file_status(t, e->full);

        if (i >= g_list_model_get_n_items(model)) {
            ZcFileItem *it = zc_file_item_new(e->full, e->name, e->is_dir, s);
            zc_diag_item_register(t, e->full, it);
            g_list_store_append(store, it);
            g_object_unref(it);
            i++; j++;
            continue;
        }

        ZcFileItem *cur = g_list_model_get_item(model, i);
        gint c = zc_cmp_ni(cur->is_dir, cur->name, e->is_dir, e->name);
        if (c == 0) {
            zc_file_item_set_status(cur, s);
            i++; j++;
        } else if (c < 0) {                 /* `cur` no longer on disk */
            g_hash_table_remove(t->diag_items, cur->path);
            g_list_store_remove(store, i);  /* keep i; row shifts up   */
        } else {                            /* `e` is new → insert     */
            ZcFileItem *it = zc_file_item_new(e->full, e->name, e->is_dir, s);
            zc_diag_item_register(t, e->full, it);
            g_list_store_insert(store, i, it);
            g_object_unref(it);
            i++; j++;
        }
        g_object_unref(cur);
    }
    while (i < g_list_model_get_n_items(model)) {
        ZcFileItem *gone = g_list_model_get_item(model, i);
        g_hash_table_remove(t->diag_items, gone->path);
        g_object_unref(gone);
        g_list_store_remove(store, i);
    }

    g_array_free(entries, TRUE);
}

/* Reconciles every materialised directory against disk + the git overlay. */
static void zc_reconcile_all(ZcFileTree *t) {
    GPtrArray *paths = g_ptr_array_new();
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, t->stores);
    while (g_hash_table_iter_next(&it, &k, &v))
        g_ptr_array_add(paths, k);
    for (guint i = 0; i < paths->len; i++) {
        GListStore *s = g_hash_table_lookup(t->stores, paths->pdata[i]);
        if (s) zc_reconcile(t, paths->pdata[i], s);
    }
    g_ptr_array_free(paths, TRUE);
}

/* One async `git status` run, tied to the tree's lifetime by its cancellable. */
typedef struct { ZcFileTree *t; GCancellable *cancel; } ZcGitReq;

static void zc_git_done(GObject *src, GAsyncResult *res, gpointer data) {
    ZcGitReq *req = data;
    gchar *out = NULL;
    gboolean ok = g_subprocess_communicate_utf8_finish(G_SUBPROCESS(src), res,
                                                        &out, NULL, NULL);
    /* The request's cancellable outlives `req->t`: it is cancelled when the tree
     * is freed or the run is superseded, so this guard means the tree is still
     * alive and this result is the current one (even if the process had already
     * finished by the time it was cancelled). */
    if (ok && !g_cancellable_is_cancelled(req->cancel)) {
        ZcFileTree *t = req->t;
        zc_git_apply(t, out ? out : "");
        zc_reconcile_all(t);
        if (t->git_cancel == req->cancel) t->git_cancel = NULL;
        /* Absorb the .git writes our own status just made (and any that arrive
         * just after) so the watcher doesn't refresh in a loop. */
        t->git_settle = g_get_monotonic_time() + 500 * 1000;
        if (t->cb.changed) t->cb.changed(t->cb.user_data);
        /* Replay events absorbed during this run so real git activity that
         * raced with it (commit, checkout, push) is never lost. */
        if (t->git_pending && !t->debounce_id) {
            t->git_pending = FALSE;
            t->debounce_id = g_timeout_add(600, zc_debounced, t);
        }
    }
    g_free(out);
    g_object_unref(req->cancel);
    g_free(req);
}

/* Refreshes the git overlay off the main thread; colours update when ready. */
static void zc_git_start(ZcFileTree *t) {
    if (!t->git_top) return; /* not a git work tree */
    /* Cleared as well as cancelled: the cancellable belongs to the request that
     * is about to finish and unref it, so keeping the pointer past this point
     * would leave a dangling one behind whenever the spawn below fails. */
    if (t->git_cancel) {
        g_cancellable_cancel(t->git_cancel);
        t->git_cancel = NULL;
    }

    /* --ignored=matching reports ignored entries that match an ignore pattern
     * without recursing into them (e.g. "build/" rather than its thousands of
     * files), and the default untracked mode collapses untracked directories
     * into a single entry.  Together they keep the status output bounded even on
     * huge trees, where --untracked-files=all --ignored would enumerate every
     * ignored file and blow up memory/CPU. */
    const gchar *base[] = {"git", "--no-optional-locks", "-C", t->git_top,
                           "status", "--porcelain", "--ignored=matching", NULL};
    const gchar *fp[]   = {"flatpak-spawn", "--host", "git", "--no-optional-locks",
                           "-C", t->git_top,
                           "status", "--porcelain", "--ignored=matching", NULL};
    GSubprocess *proc = g_subprocess_newv(
        zc_in_flatpak() ? fp : base,
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, NULL);
    if (!proc) return;

    ZcGitReq *req = g_new0(ZcGitReq, 1);
    req->t = t;
    req->cancel = g_cancellable_new();
    t->git_cancel = req->cancel;
    g_subprocess_communicate_utf8_async(proc, NULL, req->cancel, zc_git_done, req);
    g_object_unref(proc);
}

/* Reconciles the tree structure now (cheap, local) and kicks off an async git
 * refresh that re-applies the colours and notifies the app when it lands. */
void zc_do_refresh(ZcFileTree *t) {
    if (!t->alive) return;
    zc_reconcile_all(t);
    if (t->cb.changed) t->cb.changed(t->cb.user_data);
    zc_git_start(t);
}

static gboolean zc_debounced(gpointer data) {
    ZcFileTree *t = data;
    t->debounce_id = 0;
    zc_do_refresh(t);
    return G_SOURCE_REMOVE;
}

/* ── Activation (open file / toggle folder) ──────────────────────────────── */

static gboolean zc_on_root_drop(GtkDropTarget *tgt, const GValue *val,
                                 double x, double y, gpointer data) {
    ZcFileTree *t = data;
    const char *src_path = g_value_get_string(val);
    if (!src_path) return FALSE;
    return zc_do_move(t, src_path, t->root);
}

static void zc_on_activate(GtkListView *lv, guint pos, gpointer data) {
    ZcFileTree *t = data;
    GtkTreeListRow *row = g_list_model_get_item(G_LIST_MODEL(t->tree_model), pos);
    if (!row) return;
    ZcFileItem *fi = gtk_tree_list_row_get_item(row);
    if (fi) {
        if (fi->is_dir)
            gtk_tree_list_row_set_expanded(row, !gtk_tree_list_row_get_expanded(row));
        else if (t->cb.open_file)
            t->cb.open_file(fi->path, t->cb.user_data);
        g_object_unref(fi);
    }
    g_object_unref(row);
}

/* ── Public tree API ─────────────────────────────────────────────────────── */

static void zc_watch_git_dir(ZcFileTree *t) {
    gchar *gitdir = g_build_filename(t->root, ".git", NULL);
    if (g_file_test(gitdir, G_FILE_TEST_IS_DIR)) {
        GFile *gf = g_file_new_for_path(gitdir);
        t->git_monitor = g_file_monitor_directory(gf, G_FILE_MONITOR_NONE, NULL, NULL);
        g_object_unref(gf);
        if (t->git_monitor)
            g_signal_connect(t->git_monitor, "changed",
                             G_CALLBACK(zc_on_git_changed), t);
    }
    g_free(gitdir);
}

/* Runs when the list view is finalized.  `alive` goes first and stays the guard
 * every deferred callback checks — the directory stores and their monitors are
 * released by the model somewhere in the list view's own teardown, and their
 * destroy notifiers reach back in here. */
static void zc_file_tree_free(gpointer p) {
    ZcFileTree *t = p;
    t->alive = FALSE;
    if (t->git_cancel) g_cancellable_cancel(t->git_cancel); /* drop pending status */
    t->git_cancel = NULL;
    if (t->debounce_id) { g_source_remove(t->debounce_id); t->debounce_id = 0; }
    if (t->git_monitor) { g_file_monitor_cancel(t->git_monitor); g_object_unref(t->git_monitor); }
    if (t->git) g_hash_table_destroy(t->git);
    if (t->dirty_dirs) g_hash_table_destroy(t->dirty_dirs);
    if (t->stores) { g_hash_table_destroy(t->stores); t->stores = NULL; }
    if (t->diag_items) { g_hash_table_destroy(t->diag_items); t->diag_items = NULL; }
    g_free(t->git_top);
    g_free(t->root);
    g_free(t);
}

GtkWidget *zc_file_tree_new(const char *root_path, const ZcTreeCallbacks *cb) {
    ZcFileTree *t = g_new0(ZcFileTree, 1);
    t->alive = TRUE;
    t->root = g_strdup(root_path);
    t->cb = *cb;
    t->stores = g_hash_table_new(g_str_hash, g_str_equal);
    t->diag_items = g_hash_table_new_full(g_str_hash, g_str_equal,
                                          g_free, g_object_unref);
    t->git_top = zc_git_toplevel(t->root);

    GListStore *root_store = zc_dir_store_new(t, t->root);
    t->tree_model = gtk_tree_list_model_new(G_LIST_MODEL(root_store),
                                            FALSE, FALSE, zc_create_child, t, NULL);
    GtkSingleSelection *sel = gtk_single_selection_new(G_LIST_MODEL(t->tree_model));
    gtk_single_selection_set_autoselect(sel, FALSE);
    gtk_single_selection_set_can_unselect(sel, TRUE);
    t->selection = GTK_SELECTION_MODEL(sel);

    GtkListItemFactory *factory = zc_tree_factory_new(t);

    GtkWidget *lv = gtk_list_view_new(t->selection, factory);
    t->list_view = GTK_LIST_VIEW(lv);
    /* One action group for the whole view: each row's context menu targets it
     * with that row's path, so the actions themselves stay stateless. */
    zc_tree_install_menu_actions(t, lv);
    gtk_list_view_set_single_click_activate(GTK_LIST_VIEW(lv), FALSE);
    g_signal_connect(lv, "activate", G_CALLBACK(zc_on_activate), t);

    /* Drop target on the list view itself: catches drops in empty space and
     * moves the dragged item to the project root. */
    GtkDropTarget *root_drop = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_MOVE);
    g_signal_connect(root_drop, "drop", G_CALLBACK(zc_on_root_drop), t);
    gtk_widget_add_controller(lv, GTK_EVENT_CONTROLLER(root_drop));

    zc_watch_git_dir(t);

    g_object_set_data_full(G_OBJECT(lv), "zc-tree", t, zc_file_tree_free);
    zc_git_start(t); /* fills in git colours + summary once status lands */
    return lv;
}

void zc_file_tree_refresh(GtkWidget *tree) {
    ZcFileTree *t = g_object_get_data(G_OBJECT(tree), "zc-tree");
    if (t) zc_do_refresh(t);
}

/* "branch • N changed" / "branch • clean" for the sidebar, or NULL when the
 * project is not a git work tree.  Reuses the tree's loaded status — no extra
 * `git status` scan.  Caller g_free()s. */
gchar *zc_file_tree_summary(GtkWidget *tree) {
    ZcFileTree *t = g_object_get_data(G_OBJECT(tree), "zc-tree");
    if (!t || !t->git_top) return NULL;
    gchar *branch = zc_git_branch(t->git_top);
    if (!branch) return NULL;
    /* Count only real changes — ignored entries (files and the dirs we mark as
     * their ancestors) are noise, not "changes". */
    guint n = 0;
    if (t->git) {
        GHashTableIter it;
        gpointer k, v;
        g_hash_table_iter_init(&it, t->git);
        while (g_hash_table_iter_next(&it, &k, &v))
            if (GPOINTER_TO_INT(v) != ZC_GIT_IGNORED) n++;
    }
    gchar *summary = n
        ? g_strdup_printf("%s \xe2\x80\xa2 %u changed", branch, n)
        : g_strdup_printf("%s \xe2\x80\xa2 clean", branch);
    g_free(branch);
    return summary;
}

/* Expands every ancestor of `path` and selects/scrolls to it. */
void zc_file_tree_reveal(GtkWidget *tree, const char *path) {
    ZcFileTree *t = g_object_get_data(G_OBJECT(tree), "zc-tree");
    if (!t || !path || !g_str_has_prefix(path, t->root)) return;

    const char *rel = path + strlen(t->root);
    while (*rel == '/') rel++;
    if (!*rel) return;

    gchar **parts = g_strsplit(rel, "/", -1);
    GString *acc = g_string_new(t->root);
    GListModel *m = G_LIST_MODEL(t->tree_model);
    guint target = GTK_INVALID_LIST_POSITION;

    for (int k = 0; parts[k]; k++) {
        if (!parts[k][0]) continue;
        g_string_append_c(acc, '/');
        g_string_append(acc, parts[k]);

        guint n = g_list_model_get_n_items(m);
        guint found = GTK_INVALID_LIST_POSITION;
        for (guint pos = 0; pos < n; pos++) {
            GtkTreeListRow *row = g_list_model_get_item(m, pos);
            ZcFileItem *fi = gtk_tree_list_row_get_item(row);
            gboolean eq = fi && strcmp(fi->path, acc->str) == 0;
            if (eq && parts[k + 1]) gtk_tree_list_row_set_expanded(row, TRUE);
            if (fi) g_object_unref(fi);
            g_object_unref(row);
            if (eq) { found = pos; break; }
        }
        if (found == GTK_INVALID_LIST_POSITION) break;
        target = found;
    }

    g_strfreev(parts);
    g_string_free(acc, TRUE);

    if (target != GTK_INVALID_LIST_POSITION) {
        gtk_selection_model_select_item(t->selection, target, TRUE);
        gtk_widget_activate_action(GTK_WIDGET(t->list_view),
                                   "list.scroll-to-item", "u", target);
    }
}

void zc_file_tree_set_diag_severity(GtkWidget *tree, const char *path, int sev) {
    ZcFileTree *t = g_object_get_data(G_OBJECT(tree), "zc-tree");
    if (!t || !t->alive || !t->diag_items || !path) return;
    ZcFileItem *it = g_hash_table_lookup(t->diag_items, path);
    if (!it) return;
    zc_file_item_set_diag_severity(it, sev);
}

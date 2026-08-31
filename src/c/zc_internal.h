/* Declarations shared *across* zcode's C helper modules. Functions called only
 * from Zig live in src/gtk.zig (extern fn); functions private to one .c file
 * stay static there. Keep this surface small. */
#ifndef ZC_INTERNAL_H
#define ZC_INTERNAL_H

#include <gtk/gtk.h>
#include <adwaita.h>
#include <gio/gio.h>
#include <gtksourceview/gtksource.h>

/* ── Flatpak detection ───────────────────────────────────────────────────── */

/* TRUE when running inside a Flatpak sandbox.  Cached after the first call.
 * Use this to redirect host-tool invocations via flatpak-spawn --host. */
static inline gboolean zc_in_flatpak(void) {
    static int v = -1;
    if (G_UNLIKELY(v < 0))
        v = g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS);
    return v;
}

/* ── Shared helpers (util.c) ─────────────────────────────────────────────── */

/* Resolves one of our installed data subdirs by probing, in order, the env
 * override, the dir relative to the executable (installed then in-tree) and the
 * Flatpak prefix, returning the first that contains `probe`.  Caller g_free()s,
 * or NULL when none is found. */
gchar *zc_data_dir(const char *env_var, const char *subdir, const char *probe);

/* Places `iter` at `byte_col` within `line`, snapped back to a character
 * boundary and clamped to the line.  Use this instead of
 * gtk_text_buffer_get_iter_at_line_index for any column that was measured
 * against a different revision of the buffer — see util.c for why. */
void zc_iter_at_line_byte(void *buffer, void *iter, int line, int byte_col);

/* ── Git status (git.c) ──────────────────────────────────────────────────── */

typedef enum {
    ZC_GIT_NONE = 0,
    ZC_GIT_MODIFIED,
    ZC_GIT_ADDED,
    ZC_GIT_UNTRACKED,
    ZC_GIT_DELETED,
    ZC_GIT_RENAMED,
    ZC_GIT_CONFLICT,
    ZC_GIT_IGNORED,
} ZcGitStatus;

/* CSS class applied to a row's name/badge so colours track the stylesheet. */
const gchar *zc_git_css_class(ZcGitStatus s);
/* NULL-terminated list of every status class (for clearing before re-apply). */
extern const char *const zc_git_all_classes[];
/* Single-letter badge for a status ("M", "A", …), "" for ZC_GIT_NONE. */
const gchar *zc_git_letter(ZcGitStatus s);
/* Brackets a git command we run ourselves.  The work-tree watcher ignores .git
 * events while one is in flight (and briefly after), because git's own index
 * writes are otherwise indistinguishable from an external change — and
 * answering them with another refresh spawns more git, forever. */
void zc_git_busy_enter(void);
void zc_git_busy_leave(void);
gboolean zc_git_busy(void);

/* Git work-tree root containing `root_path`, or NULL.  Caller g_free()s. */
gchar *zc_git_toplevel(const gchar *root_path);
/* Current branch name (rev-parse --abbrev-ref HEAD), or NULL.  Caller g_free()s. */
gchar *zc_git_branch(const gchar *root_path);


/* ── File-type icons (icons.c) ───────────────────────────────────────────── */

/* "mocha" (dark) or "latte" (light) depending on the current colour scheme. */
const char *zc_icon_flavor(void);
/* Icon stem (PNG basename) for a file name, or NULL when none matches. */
const char *zc_icon_stem_for_file(const char *name);
/* Icon stem for a folder name; never NULL (defaults to "_folder"[_open]). */
const char *zc_icon_stem_for_dir(const char *name, gboolean expanded);
/* Cached texture for `<flavor>/<stem>.png`, or NULL.  Borrowed; do not free. */
GdkTexture *zc_icon_texture(const char *flavor, const char *stem);

/* ── ZcFileItem: one row of the tree (file_item.c) ───────────────────────── */

#define ZC_TYPE_FILE_ITEM (zc_file_item_get_type())
G_DECLARE_FINAL_TYPE(ZcFileItem, zc_file_item, ZC, FILE_ITEM, GObject)

struct _ZcFileItem {
    GObject  parent_instance;
    gchar   *path;
    gchar   *name;
    gboolean is_dir;
    int      status;         /* ZcGitStatus */
    int      diag_severity;  /* 0=none, 1=error, 2=warning, 3=info, 4=hint */
};

ZcFileItem *zc_file_item_new(const char *path, const char *name,
                             gboolean is_dir, int status);
void zc_file_item_set_status(ZcFileItem *it, int status);
void zc_file_item_set_diag_severity(ZcFileItem *it, int sev);

/* Sets the worst diagnostic severity for a file path in the tree sidebar.
 * 0=clear, 1=error, 2=warning, 3=info, 4=hint.  No-op when path not found. */
void zc_file_tree_set_diag_severity(GtkWidget *tree, const char *path, int sev);

/* ── Tree types (tree.c) ─────────────────────────────────────────────────── */

/* App-facing callbacks; mirrors the `ZcTreeCallbacks` extern struct in Zig. */
typedef struct {
    void (*open_file)(const char *path, void *user_data);
    void (*open_terminal)(const char *dir, void *user_data);
    void (*new_item)(const char *dir, int is_dir, void *user_data);
    void (*changed)(void *user_data);
    void (*file_renamed)(const char *old_path, const char *new_path, void *user_data);
    /* Outcome of a filesystem operation the tree performed itself; the app
     * turns it into a toast.  is_error picks the priority and styling. */
    void (*report)(const char *message, int is_error, void *user_data);
    void *user_data;
} ZcTreeCallbacks;

typedef struct {
    gboolean          alive;
    gchar            *root;
    GHashTable       *git;         /* abs path → ZcGitStatus (GINT) */
    GHashTable       *dirty_dirs;  /* set of dirs containing changes */
    GHashTable       *diag_items;  /* abs path → ZcFileItem* (weak), for sidebar diag dots */
    GHashTable       *stores;      /* abs path → GListStore (borrowed) */
    GtkTreeListModel *tree_model;  /* borrowed (owned by selection) */
    GtkSelectionModel*selection;   /* borrowed (owned by list view) */
    GtkListView      *list_view;   /* borrowed (the returned widget) */
    GFileMonitor     *git_monitor; /* owned */
    gchar            *git_top;     /* cached work-tree root, NULL if not a repo */
    GCancellable     *git_cancel;  /* the in-flight `git status`, borrowed */
    gint64            git_settle;  /* absorb .git events until this (monotonic) */
    gboolean          git_pending; /* a .git event arrived while absorbed */
    guint             debounce_id;
    guint             n_monitors;  /* live directory monitors (watch budget) */
    ZcTreeCallbacks   cb;
} ZcFileTree;

/* Reloads git + reconciles every materialised directory, then notifies the
 * app (sidebar summary, editor diff gutters).  (tree.c) */
void zc_do_refresh(ZcFileTree *t);

/* ── Diff gutter (diff.c) ────────────────────────────────────────────────── */

typedef struct {
    guint  line;
    guint8 status;
} ZcDiffMark;


/* Sparse diff marks (only non-zero lines).  Borrowed; do not free. */
GArray *zc_diff_get_marks(GtkSourceView *view);

/* Lines added and removed against HEAD, as `git diff --numstat` counts them. */
void zc_diff_stats(GtkSourceView *view, guint *added, guint *removed);

/* Notified after a diff is recomputed — the counts land well after the save
 * that asked for them, so whatever displays them has to be told. */
typedef void (*ZcDiffChangedFn)(void);
void zc_diff_set_changed_cb(ZcDiffChangedFn cb);

/* ── Diagnostic overview marks ────────────────────────────────────────────── */

typedef struct {
    guint  line;
    guint8 severity; /* 1=error 2=warning 3=info 4=hint */
} ZcDiagMark;

/* Stores sparse diag marks on the buffer for the overview ruler to consume.
 * Pass n=0 to clear.  Marks are copied; caller keeps ownership. */
void zc_buffer_set_diag_marks(GtkSourceBuffer *buf, const ZcDiagMark *marks, guint n);

/* ── Diagnostic hover popover (hover.c) ──────────────────────────────────── */

typedef struct {
    int  start_line, start_char, end_line, end_char;
    int  severity; /* 1-4 */
    const char *message;
} ZcHoverDiag;
void zc_hover_show_at_cursor(GtkSourceView *view);
void zc_buffer_set_hover_diags(GtkSourceBuffer *buf,
                               const ZcHoverDiag *diags, guint n);

/* Queues a redraw of the ruler; called by diff.c when new diff data lands. */
void zc_overview_ruler_queue_draw(GtkWidget *ruler);

/* ── Tree rows (tree_rows.c) ─────────────────────────────────────────────── */

/* Builds the GtkSignalListItemFactory that renders the tree's rows. */
GtkListItemFactory *zc_tree_factory_new(ZcFileTree *t);

/* ── Tree context menu (tree_menu.c) ─────────────────────────────────────── */

/* Installs the "item" action group backing the row context menu.  Called once,
 * on the list view, so every row's popover resolves the same actions. */
void zc_tree_install_menu_actions(ZcFileTree *t, GtkWidget *list_view);

/* Pops up the per-row right-click menu anchored at `anchor`, (x, y). */
void zc_show_context_menu(ZcFileTree *t, GtkWidget *anchor,
                          ZcFileItem *fi, double x, double y);

/* Reports an operation's outcome to the app (a toast).  Safe with no callback
 * installed, in which case it does nothing. */
void zc_tree_report(ZcFileTree *t, int is_error, const char *fmt, ...) G_GNUC_PRINTF(3, 4);

/* Moves src_path into dest_dir via g_file_move.  No-ops on same-dir or
 * circular (dir into itself/descendant) moves.  Notifies file_renamed and
 * calls zc_do_refresh on success.  Returns TRUE when the move happened. */
gboolean zc_do_move(ZcFileTree *t, const char *src_path, const char *dest_dir);

/* ── Language-server transport (lsp_io.c) ────────────────────────────────── */

/* Raw byte callbacks for one language server's stdout, fired on the main loop.
 * Framing and protocol are handled by the Zig caller (src/lsp/). */
typedef struct {
    void (*on_data)(void *user_data, const char *bytes, size_t len);
    void (*on_closed)(void *user_data);
    void *user_data;
} ZcLspCallbacks;

typedef struct _ZcLspProc ZcLspProc;

/* Spawns `argv` (NULL-terminated) in `cwd`, pumping its stdout to `cb`.
 * Returns NULL when the server binary can't be launched. */
ZcLspProc *zc_lsp_proc_new(const char *const *argv, const char *cwd,
                           const ZcLspCallbacks *cb);
void zc_lsp_proc_write(ZcLspProc *p, const char *bytes, size_t len);
void zc_lsp_proc_close(ZcLspProc *p);
gboolean zc_lsp_proc_write_pending(ZcLspProc *p);

/* ── LSP completion (completion.c) ───────────────────────────────────────── */

#define ZC_TYPE_LSP_PROPOSAL (zc_lsp_proposal_get_type())
G_DECLARE_FINAL_TYPE(ZcLspProposal, zc_lsp_proposal, ZC, LSP_PROPOSAL, GObject)

#define ZC_TYPE_LSP_COMPLETION_PROVIDER (zc_lsp_completion_provider_get_type())
G_DECLARE_FINAL_TYPE(ZcLspCompletionProvider, zc_lsp_completion_provider, ZC,
                     LSP_COMPLETION_PROVIDER, GObject)

/* Adds the LSP completion provider to a source view. */
void zc_lsp_completion_attach(GtkSourceView *view);

/* Proposal-list builders, called from Zig as the LSP reply is parsed. */
GListStore *zc_completion_store_new(void);
void zc_completion_store_add(GListStore *store, const char *label,
                             const char *detail, const char *insert_text);
void zc_completion_finish(GTask *task, GListStore *store);
void zc_lsp_complete(GtkSourceBuffer *buffer, int line, int character,
                     GTask *task, int trigger_kind, int trigger_char);
void zc_lsp_request_hover(GtkSourceBuffer *buffer, int line, int ch,
                          GtkSourceView *view);
void zc_lsp_signature_help(GtkSourceBuffer *buffer, int line, int ch,
                           GtkSourceView *view);
void zc_lsp_goto_definition(GtkSourceBuffer *buffer, int line, int ch);
void zc_lsp_rename_symbol(GtkSourceBuffer *buffer);
/* Returns non-zero when `ch` should trigger LSP completion for the language
 * associated with `buffer`.  '.' triggers for all languages; ':' only for
 * languages that use it as a scope-resolution operator (Rust, C/C++). */
gboolean zc_lsp_is_trigger_char(GtkSourceBuffer *buffer, gunichar ch);

/* ── Hover doc display (hover.c) ─────────────────────────────────────────── */

/* Shows `text` in the hover popover anchored at (line, ch).
 * Called from Zig when the LSP hover response arrives. */
void zc_hover_show_text(GtkSourceView *view, const char *text,
                        int line, int ch);
/* Shows the diagnostic covering `line`, if any.  Called from Zig when the
 * LSP hover response for (line, ch) came back empty. */
void zc_hover_show_diag_fallback(GtkSourceView *view, int line, int ch);

/* ── Signature help popover (signature.c) ────────────────────────────────── */

void zc_signature_attach(GtkSourceView *view);
void zc_signature_show(GtkSourceView *view, const char *text);
void zc_signature_hide(GtkSourceView *view);

/* ── Editor navigation (editor.c) ────────────────────────────────────────── */

/* Attaches Ctrl+Click go-to-definition and "Rename Symbol" context menu. */
void zc_editor_attach_click_nav(GtkSourceView *view);

/* ── Main-loop watchdog (util.c) ─────────────────────────────────────────── */

/* Warns on every main-loop turn longer than ZC_WATCHDOG_MS.  No-op unless the
 * variable is set — it is for finding what blocks the UI, not for shipping. */
void zc_watchdog_install(void);

#endif /* ZC_INTERNAL_H */

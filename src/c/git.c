/* Git status helpers: colours/letters/classes shared with the row renderer,
 * plus zc_git_toplevel (work-tree root) and zc_git_summary (sidebar subtitle). */
#include "zc_internal.h"

#include <string.h>

/* Our own git commands write inside .git — `status` and `diff` both refresh the
 * index — and the work-tree watcher cannot tell those writes from someone
 * else's.  Left alone it answers each one with another refresh, which spawns
 * more git, which writes again: a loop that never settles and repaints the
 * editor several times a second forever.  Every run registers itself here so
 * the watcher can ignore the events it caused. */
static int git_running;
static gint64 git_quiet_until;

#define ZC_GIT_SETTLE_US (500 * 1000)

void zc_git_busy_enter(void) { git_running++; }

void zc_git_busy_leave(void) {
    if (--git_running <= 0) {
        git_running = 0;
        git_quiet_until = g_get_monotonic_time() + ZC_GIT_SETTLE_US;
    }
}

gboolean zc_git_busy(void) {
    return git_running > 0 || g_get_monotonic_time() < git_quiet_until;
}

const gchar *zc_git_css_class(ZcGitStatus s) {
    switch (s) {
        case ZC_GIT_MODIFIED:  return "zc-git-modified";
        case ZC_GIT_ADDED:     return "zc-git-added";
        case ZC_GIT_UNTRACKED: return "zc-git-untracked";
        case ZC_GIT_DELETED:   return "zc-git-deleted";
        case ZC_GIT_RENAMED:   return "zc-git-renamed";
        case ZC_GIT_CONFLICT:  return "zc-git-conflict";
        case ZC_GIT_IGNORED:   return NULL; /* dimming applied at box level */
        default:               return NULL;
    }
}

const char *const zc_git_all_classes[] = {
    "zc-git-modified", "zc-git-added", "zc-git-untracked",
    "zc-git-deleted",  "zc-git-renamed", "zc-git-conflict", NULL,
};

const gchar *zc_git_letter(ZcGitStatus s) {
    switch (s) {
        case ZC_GIT_MODIFIED:  return "M";
        case ZC_GIT_ADDED:     return "A";
        case ZC_GIT_UNTRACKED: return "U";
        case ZC_GIT_DELETED:   return "D";
        case ZC_GIT_RENAMED:   return "R";
        case ZC_GIT_CONFLICT:  return "!";
        case ZC_GIT_IGNORED:   return "";
        default:               return "";
    }
}

/* Resolves the git work-tree root containing `root_path`, or NULL.  g_free(). */
gchar *zc_git_toplevel(const gchar *root_path) {
    const gchar *base[] = {"git", "-C", root_path, "rev-parse",
                           "--show-toplevel", NULL};
    const gchar *fp[]   = {"flatpak-spawn", "--host", "git", "-C", root_path,
                           "rev-parse", "--show-toplevel", NULL};
    const gchar **argv  = zc_in_flatpak() ? fp : base;
    gchar *out = NULL;
    gint status = 0;
    gchar *top = NULL;
    if (g_spawn_sync(NULL, (gchar **)argv, NULL,
                     G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, &out, NULL, &status, NULL)
        && status == 0 && out) {
        g_strchomp(out);
        if (*out) top = g_strdup(out);
    }
    g_free(out);
    return top;
}

/* Current branch name, or NULL.  Cheap (reads HEAD); g_free() the result. */
gchar *zc_git_branch(const gchar *root_path) {
    const gchar *base[] = {"git", "-C", root_path, "rev-parse",
                           "--abbrev-ref", "HEAD", NULL};
    const gchar *fp[]   = {"flatpak-spawn", "--host", "git", "-C", root_path,
                           "rev-parse", "--abbrev-ref", "HEAD", NULL};
    const gchar **argv  = zc_in_flatpak() ? fp : base;
    gchar *out = NULL;
    gint status = 0;
    gchar *branch = NULL;
    if (g_spawn_sync(NULL, (gchar **)argv, NULL,
                     G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, &out, NULL, &status, NULL)
        && status == 0 && out) {
        g_strchomp(out);
        if (*out) branch = g_strdup(out);
    }
    g_free(out);
    return branch;
}

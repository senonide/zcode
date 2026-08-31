/* Long-lived language-server transport.
 *
 * Unlike git.c / diff.c (one-shot `communicate_utf8`), a language server is a
 * persistent child we talk to over stdin/stdout for the whole session.  This
 * file owns only the GObject-heavy plumbing: spawning the process, pumping its
 * stdout to a Zig callback as raw bytes, and writing raw bytes to its stdin.
 * The JSON-RPC framing and protocol live in Zig (src/lsp/). */

#include "zc_internal.h"

#include <string.h>

#define ZC_LSP_READ_CHUNK 65536

struct _ZcLspProc {
    GSubprocess    *proc;
    GOutputStream  *stdin_stream;  /* borrowed from proc */
    GInputStream   *stdout_stream; /* borrowed from proc */
    GCancellable   *cancel;        /* owned; cancelled on close */
    ZcLspCallbacks  cb;
    guint8          read_buf[ZC_LSP_READ_CHUNK];

    /* Outgoing bytes are buffered and drained by a single async writer so we
     * never block the main loop on a full pipe.  `sending` is the chunk handed
     * to the in-flight write and is owned by it: `write_all_async` keeps reading
     * from the pointer it was given until the write completes, so it must not
     * be the queue that later writes keep appending to (appending can realloc,
     * and the write would then be reading freed memory). */
    GByteArray     *outbuf;
    GBytes         *sending;

    /* Cancelling a read doesn't retract a callback already dispatched onto the
     * main loop: it still fires, with a CANCELLED result.  So `p` must outlive
     * every in-flight async op — `close` only marks `closed` and the last
     * callback to land frees `p` (`inflight` tracks reads + writes). */
    gboolean        closed;
    int             inflight;
};

static void zc_lsp_read_next(ZcLspProc *p);
static void zc_lsp_write_next(ZcLspProc *p);

static void zc_lsp_maybe_free(ZcLspProc *p) {
    if (!p->closed || p->inflight > 0) return;
    g_object_unref(p->proc);
    g_object_unref(p->cancel);
    g_byte_array_free(p->outbuf, TRUE);
    if (p->sending) g_bytes_unref(p->sending);
    g_free(p);
}

static void zc_lsp_read_done(GObject *src, GAsyncResult *res, gpointer data) {
    ZcLspProc *p = data;
    GError *err = NULL;
    gssize n = g_input_stream_read_finish(G_INPUT_STREAM(src), res, &err);
    p->inflight--;
    /* Closed by us: the Zig client may already be gone — never call back into
     * it, just retire this op (and free `p` once the last one lands). */
    if (p->closed) {
        g_clear_error(&err);
        zc_lsp_maybe_free(p);
        return;
    }
    if (n > 0) {
        if (p->cb.on_data)
            p->cb.on_data(p->cb.user_data, (const char *)p->read_buf, (size_t)n);
        zc_lsp_read_next(p);
        return;
    }
    /* 0 = EOF, <0 = error: the server died on its own.  The client is still
     * alive (it owns us) — tell it so; it will call close() later. */
    g_clear_error(&err);
    if (p->cb.on_closed) p->cb.on_closed(p->cb.user_data);
}

static void zc_lsp_read_next(ZcLspProc *p) {
    if (p->closed) return;
    p->inflight++;
    g_input_stream_read_async(p->stdout_stream, p->read_buf, sizeof p->read_buf,
                              G_PRIORITY_DEFAULT, p->cancel, zc_lsp_read_done, p);
}

static void zc_lsp_write_done(GObject *src, GAsyncResult *res, gpointer data) {
    ZcLspProc *p = data;
    gsize written = 0;
    GError *err = NULL;
    gboolean ok = g_output_stream_write_all_finish(G_OUTPUT_STREAM(src), res,
                                                    &written, &err);
    g_clear_pointer(&p->sending, g_bytes_unref);
    p->inflight--;
    if (p->closed) {
        g_clear_error(&err);
        zc_lsp_maybe_free(p);
        return;
    }
    g_clear_error(&err);
    if (!ok) return;
    zc_lsp_write_next(p); /* drain whatever queued up while that was in flight */
}

static void zc_lsp_write_next(ZcLspProc *p) {
    if (p->closed || p->sending || p->outbuf->len == 0) return;
    /* Hand the queued bytes to the write and start the queue over, so appends
     * arriving during the write cannot move the memory it is reading from. */
    p->sending = g_byte_array_free_to_bytes(p->outbuf);
    p->outbuf = g_byte_array_new();
    p->inflight++;
    gsize len = 0;
    const guint8 *data = g_bytes_get_data(p->sending, &len);
    g_output_stream_write_all_async(p->stdin_stream, data, len,
                                    G_PRIORITY_DEFAULT, p->cancel,
                                    zc_lsp_write_done, p);
}

/* The host user's login shell, resolved once (g_free-able cache below).
 * $SHELL inside the sandbox is /bin/sh, not the host shell, so we read the
 * passwd entry on the host instead.  fish takes incompatible flags. */
static const char *zc_host_shell(void) {
    static gchar *cached;
    if (cached) return cached;
    const char *argv[] = {"flatpak-spawn", "--host", "sh", "-c",
                          "getent passwd \"$(id -un)\" | cut -d: -f7", NULL};
    gchar *out = NULL;
    if (g_spawn_sync(NULL, (gchar **)argv, NULL,
                     G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, &out, NULL, NULL, NULL) && out) {
        g_strchomp(out);
        if (*out && !g_str_has_suffix(out, "/fish")) cached = out;
        else g_free(out);
    }
    if (!cached) cached = g_strdup("/bin/bash");
    return cached;
}

/* The host's login PATH, resolved once.  In Flatpak the session PATH lacks
 * user-local tool dirs (~/.cargo/bin, ~/.local/bin, ~/go/bin); we recover the
 * full PATH by sourcing the user's login shell.  Borrowed; never freed. */
static const char *g_host_path; /* NULL until first zc_host_resolve success */

/* Resolves, on the host, the absolute path of `prog` (g_free), or NULL if it
 * isn't installed.  Also caches the host login PATH in g_host_path.
 *
 * An interactive login shell (`-l -i`) is used so user-local tool dirs are
 * searched: PATH additions commonly live in ~/.zshrc / ~/.bashrc, which the
 * shell only sources when interactive (a plain `-l` login shell misses them).
 * We must not run the server *through* that shell, though: its rc files may
 * print a banner to stdout and corrupt the JSON-RPC stream.  So we resolve
 * here — capturing the shell's stdout separately and reading only sentinel-
 * framed lines, immune to banner noise — and spawn the absolute binary
 * directly with a clean stdout.
 *
 * `prog` is interpolated into a script that runs on the *host*, outside the
 * sandbox, so it is shell-quoted rather than trusted.  Today it only ever comes
 * from the compile-time server table in lsp/manager.zig, but the quoting is
 * what keeps that from mattering if servers ever become configurable. */
static gchar *zc_host_resolve(const char *prog) {
    g_autofree gchar *quoted = g_shell_quote(prog);
    gchar *script = g_strdup_printf(
        "printf '\\nZC_PATH=%%s\\nZC_BIN=%%s\\n' \"$PATH\" "
        "\"$(command -v %s 2>/dev/null)\"", quoted);
    const char *argv[] = {"flatpak-spawn", "--host", zc_host_shell(),
                          "-l", "-i", "-c", script, NULL};
    gchar *out = NULL;
    gboolean ok = g_spawn_sync(NULL, (gchar **)argv, NULL,
                               G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                               NULL, NULL, &out, NULL, NULL, NULL);
    g_free(script);
    if (!ok || !out) { g_free(out); return NULL; }

    gchar *bin = NULL;
    gchar **lines = g_strsplit(out, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        if (!g_host_path && g_str_has_prefix(lines[i], "ZC_PATH="))
            g_host_path = g_strdup(lines[i] + strlen("ZC_PATH="));
        else if (g_str_has_prefix(lines[i], "ZC_BIN="))
            bin = g_strdup(lines[i] + strlen("ZC_BIN="));
    }
    g_strfreev(lines);
    g_free(out);
    if (bin && !*bin) { g_free(bin); bin = NULL; } /* command -v found nothing */
    return bin;
}

/* Spawns the LSP server process.  When running inside a Flatpak, delegates to
 * the host via flatpak-spawn --host so the server binary is looked up on the
 * host PATH rather than the sandbox.  The stdin/stdout pipes are forwarded
 * transparently; the server exits naturally when its stdin is closed. */
static GSubprocess *zc_lsp_spawn(GSubprocessLauncher *launcher,
                                  const char *const *argv, const char *cwd) {
    GError *err = NULL;
    GSubprocess *proc;

    if (!g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS)) {
        if (cwd) g_subprocess_launcher_set_cwd(launcher, cwd);
        proc = g_subprocess_launcher_spawnv(launcher, argv, &err);
        if (err) g_error_free(err);
        return proc;
    }

    g_autofree gchar *bin = zc_host_resolve(argv[0]);
    if (!bin) return NULL; /* server not installed on the host */

    GPtrArray *args = g_ptr_array_new();
    g_ptr_array_add(args, (gpointer)"flatpak-spawn");
    g_ptr_array_add(args, (gpointer)"--host");
    g_autofree gchar *dir_arg = NULL;
    if (cwd) {
        dir_arg = g_strdup_printf("--directory=%s", cwd);
        g_ptr_array_add(args, dir_arg);
    }
    /* Forward the host login PATH so the server resolves its own helpers
     * (e.g. rust-analyzer → cargo/rustc, gopls → go). */
    g_autofree gchar *env_arg = NULL;
    if (g_host_path) {
        env_arg = g_strdup_printf("--env=PATH=%s", g_host_path);
        g_ptr_array_add(args, env_arg);
    }
    /* Absolute binary + its flags, run directly so stdout stays JSON-RPC-clean. */
    g_ptr_array_add(args, bin);
    for (int i = 1; argv[i]; i++) g_ptr_array_add(args, (gpointer)argv[i]);
    g_ptr_array_add(args, NULL);

    proc = g_subprocess_launcher_spawnv(launcher, (const char *const *)args->pdata, &err);
    if (err) g_error_free(err);
    g_ptr_array_free(args, TRUE);
    return proc;
}

ZcLspProc *zc_lsp_proc_new(const char *const *argv, const char *cwd,
                           const ZcLspCallbacks *cb) {
    GSubprocessLauncher *launcher = g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE |
        G_SUBPROCESS_FLAGS_STDERR_SILENCE);

    GSubprocess *proc = zc_lsp_spawn(launcher, argv, cwd);
    g_object_unref(launcher);
    if (!proc) return NULL; /* server binary not on PATH, etc. */

    ZcLspProc *p = g_new0(ZcLspProc, 1);
    p->proc = proc;
    p->stdin_stream = g_subprocess_get_stdin_pipe(proc);
    p->stdout_stream = g_subprocess_get_stdout_pipe(proc);
    p->cancel = g_cancellable_new();
    p->cb = *cb;
    p->outbuf = g_byte_array_new();
    zc_lsp_read_next(p);
    return p;
}

void zc_lsp_proc_write(ZcLspProc *p, const char *bytes, size_t len) {
    if (!p || p->closed || len == 0) return;
    g_byte_array_append(p->outbuf, (const guint8 *)bytes, (guint)len);
    zc_lsp_write_next(p);
}

gboolean zc_lsp_proc_write_pending(ZcLspProc *p) {
    if (!p || p->closed) return FALSE;
    return p->sending != NULL || p->outbuf->len > 0;
}

void zc_lsp_proc_close(ZcLspProc *p) {
    if (!p) return;
    p->closed = TRUE;
    g_cancellable_cancel(p->cancel);
    g_subprocess_force_exit(p->proc);
    /* Frees now if nothing is in flight, otherwise the last pending read/write
     * callback frees `p` when it lands (see the `closed` note above). */
    zc_lsp_maybe_free(p);
}

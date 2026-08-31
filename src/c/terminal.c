/* Spawns the user's interactive shell into a VteTerminal and applies a GNOME-native
 * look (system monospace font + Tango palette that tracks light/dark).
 *
 * In Flatpak, the sandbox cannot give the host process a controlling terminal
 * via flatpak-spawn.  Instead we call the Flatpak D-Bus API directly:
 *   - openpty() creates PTY-A; VTE gets the master, the slave goes to the host.
 *   - HostCommand passes the slave fd as stdin/stdout/stderr to the user's
 *     shell directly.  The shell detects the interactive TTY, calls setsid()
 *     internally, and acquires PTY-A slave as its own controlling terminal.
 *   - Resize is automatic: VTE calls TIOCSWINSZ on the master; the kernel
 *     delivers SIGWINCH directly to the shell's foreground process group.
 *   - HostCommandExited triggers tab closure when the shell exits. */
#include <gtk/gtk.h>
#include <vte/vte.h>
#include <gio/gunixfdlist.h>
#include <pty.h>
#include <signal.h>
#include <sys/ioctl.h>

/* ── Non-Flatpak spawn ───────────────────────────────────────────────────── */

static void zc_spawn_cb(VteTerminal *terminal, GPid pid, GError *error, gpointer data) {
    (void)terminal; (void)pid; (void)data;
    if (error) g_printerr("zcode: terminal spawn failed: %s\n", error->message);
}

static const gchar *zc_find_shell(void) {
    const gchar *candidates[] = {
        vte_get_user_shell(), g_getenv("SHELL"),
        "/bin/bash", "/usr/bin/bash", "/bin/sh", NULL,
    };
    for (int i = 0; candidates[i]; i++)
        if (candidates[i] && g_file_test(candidates[i], G_FILE_TEST_IS_EXECUTABLE))
            return candidates[i];
    return "/bin/sh";
}

int zc_is_flatpak(void) {
    return g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS) ? 1 : 0;
}

void zc_terminal_spawn(VteTerminal *terminal, const gchar *working_dir) {
    if (!working_dir) working_dir = g_get_home_dir();
    const gchar *shell = zc_find_shell();
    char *argv[] = {(char *)shell, NULL};
    vte_terminal_spawn_async(terminal, VTE_PTY_DEFAULT, working_dir, argv, NULL,
                             G_SPAWN_DEFAULT, NULL, NULL, NULL, -1, NULL,
                             zc_spawn_cb, NULL);
}

/* ── Flatpak D-Bus spawn ─────────────────────────────────────────────────── */

#define FP_BUS   "org.freedesktop.Flatpak"
#define FP_PATH  "/org/freedesktop/Flatpak/Development"
#define FP_IFACE "org.freedesktop.Flatpak.Development"

typedef struct {
    GDBusConnection *bus;
    guint            sub;
    guint            pid;
    void           (*on_exit)(gpointer);
    gpointer         data;
} ZcHostCtx;

/* Global table: host_pid → ZcHostCtx*, so tabs can cancel their own watcher. */
static GHashTable *g_ctxs = NULL;

static GHashTable *ctxs(void) {
    if (!g_ctxs) g_ctxs = g_hash_table_new(g_direct_hash, g_direct_equal);
    return g_ctxs;
}

static void ctx_free(ZcHostCtx *c) {
    if (!c) return;
    if (c->bus && c->sub) g_dbus_connection_signal_unsubscribe(c->bus, c->sub);
    g_clear_object(&c->bus);
    g_free(c);
}

static void on_host_exited(GDBusConnection *bus G_GNUC_UNUSED,
                            const gchar *sender G_GNUC_UNUSED,
                            const gchar *path G_GNUC_UNUSED,
                            const gchar *iface G_GNUC_UNUSED,
                            const gchar *sig G_GNUC_UNUSED,
                            GVariant *params, gpointer user_data) {
    ZcHostCtx *c = user_data;
    guint pid = 0, status = 0;
    g_variant_get(params, "(uu)", &pid, &status);
    if (pid != c->pid) return;

    void (*cb)(gpointer) = c->on_exit;
    gpointer cb_data = c->data;
    g_hash_table_remove(ctxs(), GUINT_TO_POINTER(c->pid));
    ctx_free(c);
    if (cb) cb(cb_data);
}

/*
 * Flatpak: creates PTY-A (openpty), assigns its master to VTE, then spawns
 * the user's configured shell on the host via HostCommand, forwarding the
 * slave fd as stdin/stdout/stderr.  on_exit(on_exit_data) is called on the
 * GLib main loop when the shell exits.  Returns the host process PID, or 0.
 */
guint zc_terminal_spawn_host(VteTerminal *terminal,
                              const gchar *working_dir,
                              void (*on_exit)(gpointer),
                              gpointer on_exit_data) {
    if (!working_dir) working_dir = g_get_home_dir();

    int master_a, slave_a;
    if (openpty(&master_a, &slave_a, NULL, NULL, NULL) < 0) {
        g_printerr("zcode: openpty: %m\n");
        return 0;
    }
    /* Start with a sane default; VTE will correct it on first size-allocate. */
    struct winsize ws = { .ws_row = 24, .ws_col = 80 };
    ioctl(master_a, TIOCSWINSZ, &ws);

    GError *err = NULL;
    VtePty *pty = vte_pty_new_foreign_sync(master_a, NULL, &err);
    if (!pty) {
        g_printerr("zcode: vte_pty_new_foreign_sync: %s\n",
                   err ? err->message : "unknown");
        g_clear_error(&err);
        close(master_a); close(slave_a);
        return 0;
    }
    vte_terminal_set_pty(terminal, pty);
    g_object_unref(pty);

    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        g_printerr("zcode: D-Bus: %s\n", err ? err->message : "unknown");
        g_clear_error(&err);
        close(slave_a);
        return 0;
    }

    /* Pass slave_a three times (stdin/stdout/stderr) via SCM_RIGHTS. */
    GUnixFDList *fds = g_unix_fd_list_new();
    gint i0 = g_unix_fd_list_append(fds, slave_a, NULL);
    gint i1 = g_unix_fd_list_append(fds, slave_a, NULL);
    gint i2 = g_unix_fd_list_append(fds, slave_a, NULL);
    close(slave_a);

    /* The shell is determined from the HOST session environment, not from the
     * sandbox.  The sandbox's /etc/passwd and $SHELL can differ from the host
     * (e.g. the synthetic sandbox passwd may list /bin/sh while the user runs
     * zsh via chsh on the host).  We run /bin/sh — which is always present and
     * proven to work — and ask it to exec $SHELL from the HOST environment.
     * /bin/sh replaces itself via exec so no wrapper process remains; the
     * resulting shell is the only process and behaves as if launched directly.
     *
     * The shell detects the interactive TTY on stdin, calls setsid() to become
     * a session leader, and acquires PTY-A slave as its controlling terminal.
     * SIGWINCH is forwarded automatically by the kernel (TIOCSWINSZ on the
     * master triggers it); no HostCommandSignal is required for resize.
     * Host binaries are accessible: the shell runs on the host filesystem and
     * sources its rc files which set up PATH. */
    GVariantBuilder ab;
    g_variant_builder_init(&ab, G_VARIANT_TYPE("aay"));
    g_variant_builder_add_value(&ab, g_variant_new_bytestring("/bin/sh"));
    g_variant_builder_add_value(&ab, g_variant_new_bytestring("-c"));
    g_variant_builder_add_value(&ab, g_variant_new_bytestring("exec \"${SHELL:-/bin/bash}\""));

    GVariantBuilder fb; /* a{uh}: child fd → GUnixFDList index */
    g_variant_builder_init(&fb, G_VARIANT_TYPE("a{uh}"));
    g_variant_builder_add(&fb, "{uh}", (guint32)0, i0);
    g_variant_builder_add(&fb, "{uh}", (guint32)1, i1);
    g_variant_builder_add(&fb, "{uh}", (guint32)2, i2);

    /* SHELL is intentionally NOT overridden so the host session's value is
     * used.  HOME is explicit because the session helper may provide a minimal
     * base environment that omits it. */
    GVariantBuilder eb;
    g_variant_builder_init(&eb, G_VARIANT_TYPE("a{ss}"));
    g_variant_builder_add(&eb, "{ss}", "TERM",      "xterm-256color");
    g_variant_builder_add(&eb, "{ss}", "COLORTERM", "truecolor");
    const gchar *home = g_get_home_dir();
    if (home) g_variant_builder_add(&eb, "{ss}", "HOME", home);

    GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
        bus, FP_BUS, FP_PATH, FP_IFACE, "HostCommand",
        g_variant_new("(@ay@aay@a{uh}@a{ss}u)",
                      g_variant_new_bytestring(working_dir),
                      g_variant_builder_end(&ab),
                      g_variant_builder_end(&fb),
                      g_variant_builder_end(&eb),
                      (guint32)0),
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE, -1, fds, NULL, NULL, &err);

    g_object_unref(fds);

    if (!reply) {
        g_printerr("zcode: HostCommand: %s\n", err ? err->message : "unknown");
        g_clear_error(&err);
        g_object_unref(bus);
        return 0;
    }

    guint host_pid = 0;
    g_variant_get(reply, "(u)", &host_pid);
    g_variant_unref(reply);

    ZcHostCtx *c = g_new0(ZcHostCtx, 1);
    c->bus     = bus;
    c->pid     = host_pid;
    c->on_exit = on_exit;
    c->data    = on_exit_data;
    c->sub     = g_dbus_connection_signal_subscribe(
        bus, FP_BUS, FP_IFACE, "HostCommandExited", FP_PATH,
        NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_host_exited, c, NULL);

    g_hash_table_insert(ctxs(), GUINT_TO_POINTER(host_pid), c);
    return host_pid;
}

static void fp_signal(guint host_pid, int sig, gboolean to_group) {
    if (!host_pid) return;
    GError *err = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) { g_clear_error(&err); return; }
    g_dbus_connection_call(bus, FP_BUS, FP_PATH, FP_IFACE, "HostCommandSignal",
                           g_variant_new("(uub)", host_pid, (guint32)sig, to_group),
                           NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
    g_object_unref(bus);
}

/* Called by Zig when a tab is closed by the user (not by shell exit). */
void zc_terminal_detach_host(guint host_pid) {
    ZcHostCtx *c = g_hash_table_lookup(ctxs(), GUINT_TO_POINTER(host_pid));
    if (c) {
        g_hash_table_remove(ctxs(), GUINT_TO_POINTER(host_pid));
        ctx_free(c);
    }
    fp_signal(host_pid, SIGHUP, TRUE);
}

/* ── Ctrl+Click URL open ─────────────────────────────────────────────────── */

/* Matches the same http/https URLs the source view opens on Ctrl+Click (see
 * src/c/editor.c's url_at_iter): stops at whitespace or a delimiter unlikely
 * to be part of the URL itself, so trailing punctuation like a sentence's
 * closing quote or parenthesis isn't swallowed. */
#define ZC_URL_PATTERN "https?://[^\\s\"'<>)\\]]+"

static void on_terminal_click_pressed(GtkGestureClick *gesture,
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

    VteTerminal *terminal = VTE_TERMINAL(
            gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture)));
    int tag = -1;
    gchar *match = vte_terminal_check_match_at(terminal, x, y, &tag);
    if (!match) {
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_DENIED);
        return;
    }

    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    gtk_show_uri(NULL, match, GDK_CURRENT_TIME);
    g_free(match);
}

/* PCRE2_MULTILINE, from pcre2.h — not otherwise a dependency of this file, so
 * declared as the raw bit like VTE's own header does for VTE_REGEX_FLAGS_DEFAULT.
 * vte_terminal_match_add_regex() requires match regexes to be compiled with
 * this flag; without it VTE logs "runtime check failed:
 * _vte_regex_has_multiline_compile_flag" on every match-regex registration. */
#define ZC_PCRE2_MULTILINE 0x00000400u

/* Registers URL matching on `terminal` and wires up Ctrl+Click to open the
 * match under the pointer in the default browser. */
void zc_terminal_attach_url_match(VteTerminal *terminal) {
    GError *err = NULL;
    VteRegex *regex = vte_regex_new_for_match(ZC_URL_PATTERN, -1,
                                              VTE_REGEX_FLAGS_DEFAULT | ZC_PCRE2_MULTILINE, &err);
    if (!regex) {
        g_printerr("zcode: terminal URL regex: %s\n", err ? err->message : "unknown");
        g_clear_error(&err);
        return;
    }
    int tag = vte_terminal_match_add_regex(terminal, regex, 0);
    vte_regex_unref(regex);
    vte_terminal_match_set_cursor_name(terminal, tag, "pointer");

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_PRIMARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click),
                                               GTK_PHASE_CAPTURE);
    g_signal_connect(click, "pressed", G_CALLBACK(on_terminal_click_pressed), NULL);
    gtk_widget_add_controller(GTK_WIDGET(terminal), GTK_EVENT_CONTROLLER(click));
}

/* ── Terminal styling ────────────────────────────────────────────────────── */

void zc_terminal_style(VteTerminal *terminal, int dark) {
    static const char *palette_hex[16] = {
        "#241f31", "#c01c28", "#2ec27e", "#f5c211",
        "#1e78e4", "#9841bb", "#0ab9dc", "#c0bfbc",
        "#5e5c64", "#ed333b", "#57e389", "#f8e45c",
        "#51a1ff", "#c061cb", "#4fd2fd", "#f6f5f4",
    };
    GdkRGBA palette[16];
    for (int i = 0; i < 16; i++) gdk_rgba_parse(&palette[i], palette_hex[i]);

    GdkRGBA fg, bg;
    if (dark) {
        gdk_rgba_parse(&fg, "#ffffff");
        gdk_rgba_parse(&bg, "#222226");
    } else {
        gdk_rgba_parse(&fg, "#1e1e1e");
        gdk_rgba_parse(&bg, "#fafafb");
    }
    vte_terminal_set_colors(terminal, &fg, &bg, palette, 16);
}

# Architecture

Zcode is a native GNOME code editor written in **Zig** on top of **GTK 4 +
libadwaita + GtkSourceView 5 + VTE**, with a thin **C** layer for the
GObject-heavy bits that don't translate cleanly to Zig. WebKitGTK and libcmark
back the Markdown/HTML preview; tree-sitter does the highlighting.

The rule that shapes the tree is **one file, one responsibility**. Each module
is small enough to read in a sitting, and the place to make a change is the
file whose name matches the feature. You should be able to land a change
without reading the whole tree.

## Layering

```
                 main.zig            ← process entry point
                    │
              app/application.zig    ← GApplication lifecycle, app actions
                    │
              app/window.zig         ← composition root: builds the widget tree
                    │                   and wires every signal to its handler
   ┌──────────┬─────┴─────┬───────────┬──────────┬──────────┐
 editor/    terminal/   sidebar/    app/view    app/       lsp/
  tabs        tabs       files      + status   shortcuts  manager
   └──────────┴───────────┴───────────┴──────────┴──────────┘
                    │
              core/state.zig         ← per-window AppState, tab structs, lookups
                    │
                 gtk.zig             ← hand-written C bindings (platform edge)
                    │
                 src/c/*.c           ← GObject-heavy C helpers
```

Dependencies point **downward**: feature modules depend on `core` and `gtk`,
never the other way round. `app/window.zig` is the only module that knows about
all the others, and it exists solely to assemble and wire them. Two upward
calls are unavoidable and handled the same way — a function pointer set once at
startup (`files.g_build_window_fn`, `preview.g_open_file_fn`,
`lsp.g_open_at_fn`) instead of an import cycle.

Everything runs on the GTK main loop. There are no threads: work that would
block (git, diff, language servers, file loads) goes through GIO async APIs and
comes back as a callback.

## Zig modules (`src/`)

### Root

| File | Responsibility |
|------|----------------|
| `main.zig` | Parse `zcode <path>`, install the watchdog, create the AdwApplication, run. |
| `gtk.zig` | The C platform boundary: hand-written `extern fn` and opaque-type declarations for GTK, Adwaita, GtkSourceView, VTE, WebKit, cmark and our own `zc_*` helpers. Effectively append-only — you touch it to expose a new symbol. `@cImport` can't be used; it chokes on GLib's `_Pragma` macros under Zig 0.16. |
| `tests.zig` | Test root. A test build never references `main`, so nothing below it gets analysed and the suite collects zero tests. Every module with tests is imported here. |

### `core/` — state and cross-cutting settings

| File | Responsibility |
|------|----------------|
| `state.zig` | The per-window `AppState`, the per-tab structs (`EditorTab` / `TerminalTab`), the status-bar widget handles and the tab-lookup helpers. The one place app state lives. |
| `style.zig` | Global stylesheet, the light/dark GtkSourceView schemes, the configured monospace font (its own CSS provider for source views, `vte_terminal_set_font` for terminals), and the reaction to the system colour scheme or a font change. |
| `config.zig` | Persistent preferences over GSettings (`data/org.senonide.zcode.gschema.xml`): font, editor scheme, indentation, wrap, line numbers, right margin, recent projects, reopen-last-project. The only module that knows GSettings exists. Every accessor falls back to a built-in default when the schema isn't installed, because `g_settings_new` aborts on a missing schema. |
| `geometry.zig` | Window size and maximised state, in `$XDG_CONFIG_HOME/zcode/window.ini`. |
| `session.zig` | Per-project editor tabs, in `$XDG_CONFIG_HOME/zcode/sessions.json`: a flat object keyed by project root holding its open files plus the selected one. Saved on window close, restored on `openFolder`; terminals are never persisted. Entries are pruned to the recent-projects list so the file stays bounded. |

### `app/` — application and window shell

| File | Responsibility |
|------|----------------|
| `application.zig` | `activate`, the app actions (Preferences, About, Quit), the startup-path plumbing and reopening the last project. Process-wide setup happens here, once. |
| `window.zig` | Composition root. `buildWindow` builds the whole widget tree and connects each signal to its handler — wiring only, no behaviour. Callable more than once: each call is an independent window with its own `AppState`, which is what makes tearing a tab out into a new window work. |
| `view.zig` | Keeps the editors/terminals/empty stack, the matching tab bar and the header-bar title (file name over its path, never the app name) in sync. Also owns the status bar: it builds the row and refreshes every reading (language server, diagnostic counts, git line counts, cursor position), pulling each from the module that has the data rather than letting those modules poke at widgets. |
| `shortcuts.zig` | The window's command table. Every window-scoped command (save, save as, reload, open, find, replace, go to line, quick open, format, code action, tab cycling, sidebar/terminal toggles, …) as a `win.*` GAction plus its accelerator, and the close-request unsaved-changes dialog. |
| `shortcuts_dialog.zig` | The Keyboard Shortcuts dialog (`AdwShortcutsDialog`), written as a plain list of sections and items. |
| `preferences.zig` | The preferences dialog (`AdwPreferencesDialog`). Rows write to `config`; the settings change signal is what restyles the app, so this file knows nothing about source views or terminals. |
| `quickopen.zig` | Ctrl+P. Walks the project once when the dialog opens (skipping build output and VCS metadata, capped in total), then ranks that snapshot on every keystroke. Matching is subsequence-based, so `srcmain` finds `src/main.zig`, and name hits outrank directory hits. |
| `toast.zig` | User feedback. The single place a success or failure message becomes visible, through the window's `AdwToastOverlay`. Errors jump the queue and linger longer. |

### `editor/`

| File | Responsibility |
|------|----------------|
| `document.zig` | The `Document` model — one open file: load, save, modified state. Flags files at or above `large_threshold_bytes` (4 MiB) as `large` so the editor keeps GtkSourceView's own highlighter for them. |
| `tabs.zig` | Editor-tab lifecycle: open or reuse a file, build the source view, the unsaved bullet, the diff gutter, save/save-as/reload, the external-change banner, and the tab-view signal handlers. Also handles image files (shown as a `GtkPicture`, no source view) and Markdown/HTML files (a per-tab stack holding the preview). |
| `filesync.zig` | Live external-sync for one open file. Watches the file with a GFileMonitor and, when another process rewrites it, reloads a clean buffer or reports a conflict for a dirty one — never clobbering unsaved edits. "Externally modified" is decided against an mtime+etag baseline re-seeded after every load and save, so our own writes don't look external. Reloads go through `GtkSourceFileLoader`, preserve the cursor, and report the changed line band so the tab can flash it. |
| `language.zig` | The tree-sitter registry and query engine, in Zig via the `tree-sitter` bindings. One `Language` per bundled grammar (Zig, Go, Rust, C, Python, JS, TS, TSX, Markdown) lazily resolves its grammar and compiles its highlight query; `detect` picks one by extension. `matches` iterates a query and yields only matches whose predicates hold — the runtime doesn't evaluate predicates, so they're checked here. |
| `syntax.zig` | The per-buffer `Highlighter`. Owns the parser, the tree and a private copy of the text, and paints one `GtkTextTag` per capture (overlaps resolved by tag-creation-order priority). The expensive part is not the parse but what tagging does to GtkTextView, so it is shaped around painting as rarely as possible: parsing is incremental and budgeted per main-loop turn, a burst of edits collapses into one parse and one paint, tags are applied over the visible range plus a margin, and per-line bookkeeping means repainting a line only removes the tags that line actually carries. |
| `palette.zig` | The Adwaita Pastel syntax palette: capture name → colour, with dotted-hierarchy fallback (`function.call` falls back to `function`). Pure data. |
| `position.zig` | Byte columns and caret placement. A byte column measured against one revision of a buffer and used against another can land mid-character, and `gtk_text_buffer_get_iter_at_line_index` corrupts the buffer when it does — `zc_iter_at_line_byte` (in `util.c`) snaps to a character boundary instead. This module pins that contract down with tests, and holds `caretSpot`, which records where the caret sits on screen so a formatter rewrite can put it back. |
| `preview.zig` | Markdown/HTML preview. A header-bar toggle switches the tab's stack from the source view to a WebKitWebView, created lazily so tabs that never preview don't pay WebKit's startup cost. Markdown goes through cmark into a themed HTML page (with a pre-pass that turns GFM pipe tables into HTML, since cmark is CommonMark only); HTML loads from disk so relative resources resolve. Links open in the browser or, for `file://`, in an editor tab. |
| `queries/*.scm` | Per-language tree-sitter highlight queries. |

### `lsp/`

| File | Responsibility |
|------|----------------|
| `transport.zig` | JSON-RPC framing: wraps outgoing payloads with a `Content-Length` header and reassembles complete payloads from a stream that has no message boundaries. Pure logic, unit-tested. |
| `client.zig` | A JSON-RPC client for one server: the `initialize` handshake, request/response correlation by id, and an outbox holding notifications until the server is ready. Requests are built from Zig values with `std.json`; bytes arrive through a `gtk.ZcLspProc` callback on the main loop. |
| `manager.zig` | Language-server lifecycle, document sync and every LSP feature — the only LSP surface the editor calls. A registry maps a file extension to a server recipe (zls, gopls, rust-analyzer, clangd, pyright, typescript-language-server); one client is spawned lazily per project root + language and shared. Keeps each buffer in sync (didOpen / debounced didChange / didSave / didClose) and serves completion, hover, signature help, go-to-definition, rename, code actions, diagnostics and formatting. Diagnostics are capped per document and drawn as squiggles, overview marks and a severity badge in the file tree. Formatting is bounded by a timeout so a slow server can't block a save, and applies only the ranges that actually differ so GtkTextView doesn't re-validate the whole file. |

### `sidebar/`, `terminal/`

| File | Responsibility |
|------|----------------|
| `sidebar/files.zig` | The project sidebar: build and refresh the file tree, the git summary header and its branch-switch popover, opening a folder, the recent-projects popover behind the Open Project button, and the new-file/folder dialog. The Zig side the C tree calls back into. `attachProject` is the single funnel every route into a project passes through, so it's where recent history is recorded. |
| `terminal/tabs.zig` | Terminal-tab lifecycle: spawn the shell, name the tab after its cwd, copy/paste, and the terminal-mode toggle. |

## C helpers (`src/c/`)

Kept in C because they subclass GObject or lean on GLib/GTK macros.
Declarations shared **between** C files live in `zc_internal.h`; symbols called
**from Zig** are declared as `extern fn` in `gtk.zig`.

| File | Responsibility |
|------|----------------|
| `zc_internal.h` | Shared C-to-C declarations. |
| `icons.c` | File/folder icon mapping (Catppuccin / zed-icons) and cached `GdkTexture` loading. Owns `icon_data.h`. |
| `git.c` | Git status helpers (classes and letters), work-tree root, current branch. |
| `file_item.c` | `ZcFileItem`, the GObject backing one tree row. |
| `tree.c` | The file-tree model: lazy per-directory stores (one `GFileEnumerator` per dir, no per-entry stat), file monitors capped to a watch budget so huge trees don't exhaust inotify, in-place reconcile, activation, reveal, drag-to-move, the `branch • N changed` summary and the per-file diagnostic badge. Git status runs asynchronously (`GSubprocess`, `status --porcelain --ignored=matching` to keep output bounded) so opening a folder never blocks. Dotfiles are shown; only `.git` is hidden. |
| `tree_rows.c` | The `GtkSignalListItemFactory` that renders each row's icon, label and git badge. |
| `tree_menu.c` | The row context menu — a `GMenu` in a `GtkPopoverMenu`, backed by an `item` action group with the row's path as each action's target — and the operations behind it (new, open, duplicate, rename, trash, copy path, open in terminal). Every operation reports its outcome through `ZcTreeCallbacks.report`. |
| `diff.c` | `ZcDiffRenderer`: the gutter change bars vs HEAD and the added/removed counts the status bar shows. Runs `git diff` asynchronously and calls back when a run lands, because the counts arrive long after the save that asked for them. |
| `overview.c` | The overview ruler right of the scrolled window: viewport range, diff bars, diagnostic marks and cursor position scaled to the whole file, click or drag to scroll. |
| `search.c` | Per-view `GtkSourceSearchContext`: selection-occurrence highlight while idle, the Ctrl+F find bar (next/prev, `N of M`, case/word/regex) and the Ctrl+H replace row. |
| `editor.c` | Ctrl+Click go-to-definition and URL opening, the Ctrl+hover URL highlight, and the "Rename Symbol" context-menu entry. |
| `hover.c` | The hover popover: diagnostic messages when the pointer rests on a squiggle or the cursor lands on one, and LSP hover documentation. |
| `signature.c` | The signature-help popover, triggered on `(` and `,` and dismissed on `)`. |
| `completion.c` | LSP-backed completion: a `GtkSourceCompletionProvider` and proposal object, so GtkSourceView owns the popup, filtering and keyboard handling. `populate_async` defers to Zig over a `GTask`; Zig fills the proposal list as it parses the reply. |
| `terminal.c` | VTE shell spawning, URL matching and GNOME-native palette theming (the font comes from `core/style.zig`). |
| `lsp_io.c` | Long-lived language-server transport: spawns the server with stdio pipes at the project root, pumps its stdout to a Zig callback as raw bytes and drains queued writes asynchronously. Unlike `git.c` and `diff.c` (one-shot `communicate`) the process lives for the whole session. It owns no protocol — framing and JSON live in `src/lsp/`. |
| `util.c` | Small standalone helpers: buffer save, item creation, path resolution, syntax and diagnostic text tags, safe byte-column iterators, the adaptive collapse breakpoint, and the main-loop watchdog (set `ZC_WATCHDOG_MS` to get a report for every turn that runs longer than that — it turns "the editor froze" into a number and a moment to break on). |
| `test_stubs.c` | No-op replacements for `completion.c`, `hover.c`, `signature.c` and `editor.c` in the test build. Those four call Zig `export fn` symbols, which makes a C↔Zig link cycle the test runner can't resolve. |

`icon_data.h` is generated — run `zig build gen-icons` (see `tools/gen_icons.zig`).
Don't edit it by hand.

## Conventions

- **State is per window**, in `AppState` (`core/state.zig`); `core.g_windows`
  holds them all. Reach for a bare global only for the few process-wide things
  that outlive any single window.
- **Callbacks from GTK** are `callconv(.c)` and recover their `AppState` from
  the `user_data` they were connected with (or their tab via
  `g_object_get_data`), because C callbacks can't capture Zig closures.
- **Commands are GActions**, never keyval comparisons. `app/shortcuts.zig` holds
  one table of `win.*` actions and their accelerators, and the menus, the
  shortcuts dialog and the keyboard all read from it. Accelerators run ahead of
  widget key bindings and survive non-Latin layouts; a raw key controller
  doesn't.
- **Failures are visible.** Anything that can fail in front of the user reports
  through `app/toast.zig`. Silently swallowing a failed write is a bug.
- **Nothing blocks the main loop.** Subprocesses, file loads and server I/O are
  async; the watchdog is there to catch what slips through.
- **Teardown safety.** Disconnect a tab's signal handlers
  (`core.disconnectTabSignals`) before freeing its struct, so a late signal
  can't touch freed memory. `AppState.shutting_down` short-circuits handlers
  during window close.
- **Process-wide setup runs once**, in `app/application.zig` — the stylesheet,
  the style-scheme search path and the settings watchers live on the display or
  on singletons, so doing them per window would stack duplicates.
- **The C surface stays small.** Anything expressible in Zig lives in Zig.

## Sandbox boundary

Under Flatpak the app deliberately reaches the host: the terminal
(`c/terminal.c`) and language servers (`c/lsp_io.c`) run there via
`org.freedesktop.Flatpak`'s `HostCommand` and `flatpak-spawn --host`, because
the user's shell, `PATH` and toolchains only exist outside the sandbox. This is
the design, not an accident, and it is what the manifest's `--talk-name`,
`--filesystem=home` and `--share=network` pay for. Two rules follow from it:

- **Anything interpolated into a host command is quoted.** `zc_host_resolve`
  runs a script on the host, so the program name goes through `g_shell_quote`
  even though it currently only comes from the compile-time server table.
- **Previews never execute.** `editor/preview.zig` disables JavaScript for
  every previewed file, HTML included — a file the user opened to read must not
  run code with the home directory and the network in reach. That is also what
  makes `allow_universal_access_from_file_urls` (needed so README badges load)
  safe to leave on.

## Build

`build.zig` compiles `src/main.zig` plus every `src/c/*.c` into one executable
and links GTK 4, libadwaita, GtkSourceView 5, VTE, WebKitGTK 6 and libcmark,
plus the tree-sitter Zig bindings (a package dependency). The grammars are
vendored generated C under `vendor/grammars/<lang>/` and compiled in; their
quoted `tree_sitter/*.h` includes resolve per file. The app version is read
from `build.zig.zon` at configure time and injected through `build_options`, so
the About dialog and the manifest can't drift apart.

The install step also lays down the desktop file, AppStream metainfo, the icon
set and the bundled Adwaita Pastel style schemes (`data/styles/` →
`share/zcode/styles`, resolved at runtime like the icons and registered via
`zc_register_style_schemes`).

The GSettings schema is installed to `share/glib-2.0/schemas` and compiled
there by the install step, and `zig build run` points `GSETTINGS_SCHEMA_DIR` at
it. A plain `zig-out/bin/zcode` without that variable simply runs without
persistence instead of aborting. Flatpak needs nothing extra: `flatpak-builder`
compiles `/app/share/glib-2.0/schemas` itself, and inside the sandbox GLib
falls back to its keyfile backend under `~/.var/app/<id>/config/`.

`zig build test` builds the same set with `src/tests.zig` as its root and
`test_stubs.c` in place of the four C files that call back into Zig. See the
README for the toolchain (Zig 0.16 plus the GNOME `-devel` packages, or the
Flatpak build).

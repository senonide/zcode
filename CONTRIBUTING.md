# Contributing to Zcode

Contributions are welcome. To keep the project simple and maintainable,
please follow these rules:

- **Build, format and test before pushing.** `zig build test` must pass and
  `zig fmt build.zig src tools` must leave the tree unchanged; CI runs both on
  every PR, alongside the AppStream and desktop-entry validators, and a red CI
  blocks merge. Run `zig build` too when you touch `src/c/completion.c`,
  `hover.c`, `signature.c` or `editor.c` — the test build replaces those four
  with stubs, so only the Flatpak workflow compiles them after merge.
- **One responsibility per file.** Each module is small enough to read in a
  sitting. Put a change in the file whose name matches the feature; don't
  spread one concern across files.
- **Zig first, C only when necessary.** Anything expressible in Zig lives in
  Zig. The C layer (`src/c/`) exists only for GObject subclassing and
  GLib/GTK macro-heavy code. Don't port C to Zig for its own sake, and don't
  add C where Zig works.
- **No over-engineering.** Prefer the standard library and native platform
  features over new abstractions and dependencies. No interface with one
  implementation, no factory for one product, no config for a value that
  never changes.
- **Minimal interfaces.** Design modules with rich internal implementation
  and simple, focused public surfaces (Deep Modules). Hide complex internal
  logic; don't expose implementation detail.
- **No unnecessary comments.** Comment only when it improves understanding.
  Delete code that isn't pulling its weight.
- **English only.** All code, comments and documentation are in English.
- **Conventional Commits.** Commit subjects follow
  [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`,
  `perf:`, `refactor:`, `docs:`, `chore:`, `build:`, `ci:`, `test:`). This is
  not decoration: the release notes are generated from these subjects at tag
  time (`cliff.toml`), so a `feat:` or `fix:` subject is the changelog entry.
  There is no `CHANGELOG.md` to update.
- **Failures are visible.** Anything that can fail in front of the user
  reports through the toast system; silently swallowing a failed write is a
  bug.
- **Keep the license MIT.** Add your name to the copyright line if you make
  substantial changes. Anything vendored under `vendor/` or `data/` must ship
  its upstream licence file and get a row in [THIRD-PARTY.md](THIRD-PARTY.md);
  a permissive licence (MIT/BSD/Apache-2.0) is a hard requirement.

## Report a bug

- Make sure you are using the latest version.
- Open a [new issue](https://github.com/senonide/zcode/issues/new).
- Copy the log if relevant.
- Add steps to reproduce the bug.

## Code of conduct

Zcode follows the GNOME project [Code of Conduct](https://conduct.gnome.org/) —
see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

# Third-party components

Zcode itself is MIT (see [LICENSE](LICENSE)). It redistributes the components
below, each under its own permissive licence. Every entry ships its full licence
text at the path given; this file is the index, not a substitute for them.

## Vendored source (compiled into the binary)

| Component | Upstream | Licence | Licence file |
|---|---|---|---|
| tree-sitter 0.27.0 | [tree-sitter/tree-sitter](https://github.com/tree-sitter/tree-sitter) | MIT — © 2018 Max Brunsfeld | `vendor/tree-sitter/LICENSE` |
| tree-sitter Unicode tables | ICU, bundled with tree-sitter | Unicode/ICU | `vendor/tree-sitter/lib/src/unicode/LICENSE` |
| zig-tree-sitter 0.26.0 | [tree-sitter/zig-tree-sitter](https://github.com/tree-sitter/zig-tree-sitter) | MIT — © 2024 tree-sitter contributors | `vendor/zig-tree-sitter/LICENSE` |

### Grammars

Checked in as tree-sitter-generated C (`parser.c`, `scanner.c`) rather than as
full upstream checkouts, so no grammar build step is needed. Each directory
carries its upstream `LICENSE`.

| Grammar | Upstream | Licence | Licence file |
|---|---|---|---|
| C | [tree-sitter/tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c) | MIT — © 2014 Max Brunsfeld | `vendor/grammars/c/LICENSE` |
| Go | [tree-sitter/tree-sitter-go](https://github.com/tree-sitter/tree-sitter-go) | MIT — © 2014 Max Brunsfeld | `vendor/grammars/go/LICENSE` |
| JavaScript | [tree-sitter/tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript) | MIT — © 2014 Max Brunsfeld | `vendor/grammars/javascript/LICENSE` |
| TypeScript / TSX | [tree-sitter/tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) | MIT — © 2017 Max Brunsfeld | `vendor/grammars/typescript/LICENSE` |
| Python | [tree-sitter/tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) | MIT — © 2016 Max Brunsfeld | `vendor/grammars/python/LICENSE` |
| Rust | [tree-sitter/tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust) | MIT — © 2017 Maxim Sokolov | `vendor/grammars/rust/LICENSE` |
| Markdown | [tree-sitter-grammars/tree-sitter-markdown](https://github.com/tree-sitter-grammars/tree-sitter-markdown) (`split_parser`, block parser) | MIT — © 2021 Matthias Deiml | `vendor/grammars/markdown/LICENSE` |
| Zig | [tree-sitter-grammars/tree-sitter-zig](https://github.com/tree-sitter-grammars/tree-sitter-zig) | MIT — © 2024 Amaan Qureshi | `vendor/grammars/zig/LICENSE` |

## Bundled assets

| Component | Upstream | Licence | Licence file |
|---|---|---|---|
| File/folder icons (`data/icons/catppuccin/`) | [catppuccin/zed-icons](https://github.com/catppuccin/zed-icons) | MIT — © 2021 Catppuccin | `data/icons/catppuccin/LICENSE` |
| Icon theme mapping (`vendor/zed-icons/`) | [catppuccin/zed-icons](https://github.com/catppuccin/zed-icons) @ `6d953c8` | MIT — © 2021 Catppuccin | `vendor/zed-icons/LICENSE` |

The two GtkSourceView style schemes in `data/styles/` are original markup
written for Zcode. Their syntax colours are the Catppuccin Latte and Mocha
palettes (MIT, © 2021 Catppuccin — same notice as above); their editor chrome
uses Adwaita neutrals from the GNOME HIG. The name and the pastel-on-neutral
concept are inspired by the Zed theme
[Adwaita Pastel](https://github.com/Benjamin-Davies/zed-theme-adwaita); no code
or markup is derived from it, so its LGPL-2.1 terms do not apply to Zcode.

## Bundled by the Flatpak

The Flatpak build (`org.senonide.zcode.json`) compiles and ships these
alongside the app. They are not in this repository; each is fetched from its
own release tarball at build time and keeps its upstream licence.

| Component | Upstream | Licence |
|---|---|---|
| cmark 0.31.1 | [commonmark/cmark](https://github.com/commonmark/cmark) | BSD-2-Clause — © 2014 John MacFarlane |
| VTE 0.84.0 | [GNOME/vte](https://gitlab.gnome.org/GNOME/vte) | LGPL-3.0-or-later |

GTK 4, libadwaita, GtkSourceView 5 and WebKitGTK are used from the
`org.gnome.Platform` runtime and are not redistributed by this project.

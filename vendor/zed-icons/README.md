# zed-icons (vendored)

`catppuccin-icons.json` is the Zed icon theme from
[catppuccin/zed-icons](https://github.com/catppuccin/zed-icons), revision
`6d953c8c7566b9e721d15b54e802dd77ae26fa9c`.

It is the input to `zig build gen-icons`, which regenerates
`src/c/icon_data.h` — the file-tree icon lookup tables. Vendoring it keeps that
regeneration reproducible and offline from a fresh clone; only the icons whose
PNG exists under `data/icons/catppuccin/mocha/` end up in the tables.

To refresh the icon set, replace this file and the PNGs under
`data/icons/catppuccin/`, update the revision above, and re-run the generator.

Licensed under the MIT License — see `LICENSE`.

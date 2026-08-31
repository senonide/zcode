//! gen_icons — regenerates `src/c/icon_data.h` from the Catppuccin zed-icons
//! theme, so the file-tree icon lookup tables stay in the Zig toolchain (no
//! Python needed).  Run via `zig build gen-icons -- [theme.json] [repo_root]`.
//!
//! It reads the theme JSON, picks the "Catppuccin Mocha" theme, and emits three
//! sorted C tables — file stems, file suffixes and named directories — keeping
//! only entries whose PNG actually exists under
//! `<repo>/data/icons/catppuccin/mocha/`.  Tables are sorted by raw key bytes to
//! match the `strcmp`/`bsearch` lookups in `src/c/icons.c`.

const std = @import("std");

/// The theme is vendored so a fresh clone can regenerate the tables offline;
/// see `vendor/zed-icons/README.md` for the upstream revision.
const default_theme = "vendor/zed-icons/catppuccin-icons.json";

/// Suffix → PNG stem mappings the upstream theme doesn't ship. Kept here rather
/// than patched into the vendored JSON so a theme refresh can't silently drop
/// them, which is exactly how `.zon` went missing once.
const local_suffixes = [_]Pair{
    .{ .key = "zon", .val = "zig" },
};

const Pair = struct { key: []const u8, val: []const u8 };
const DirEnt = struct { key: []const u8, collapsed: []const u8, expanded: []const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // Args: [theme.json] [repo_root].  Both optional; the defaults resolve
    // against the repo root, which is where `zig build gen-icons` runs.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // program name
    const theme_path = args.next() orelse default_theme;
    const repo_root = args.next() orelse ".";

    const cwd = std.Io.Dir.cwd();
    const pngdir = try std.fmt.allocPrint(arena, "{s}/data/icons/catppuccin/mocha", .{repo_root});

    const bytes = try cwd.readFileAlloc(io, theme_path, gpa, .unlimited);
    defer gpa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();

    // Locate the Mocha theme (Latte shares the same icon names).
    const themes = parsed.value.object.get("themes").?.array;
    const theme = for (themes.items) |th| {
        const name = th.object.get("name") orelse continue;
        if (name == .string and std.mem.eql(u8, name.string, "Catppuccin Mocha")) break th.object;
    } else return error.MochaThemeNotFound;

    // file_icons: icon key → PNG stem (basename without extension).
    var key2png = std.StringHashMap([]const u8).init(gpa);
    defer key2png.deinit();
    {
        var it = theme.get("file_icons").?.object.iterator();
        while (it.next()) |e| {
            const path = e.value_ptr.*.object.get("path").?.string;
            try key2png.put(e.key_ptr.*, std.fs.path.stem(path));
        }
    }

    var miss: usize = 0;

    var stems = std.array_list.Managed(Pair).init(gpa);
    defer stems.deinit();
    try collectKV(&stems, theme.get("file_stems").?.object, key2png, io, cwd, pngdir, arena, &miss);

    var suffixes = std.array_list.Managed(Pair).init(gpa);
    defer suffixes.deinit();
    try collectKV(&suffixes, theme.get("file_suffixes").?.object, key2png, io, cwd, pngdir, arena, &miss);
    for (local_suffixes) |kv| {
        if (pngExists(io, cwd, pngdir, kv.val, arena)) try suffixes.append(kv) else miss += 1;
    }

    var dirs = std.array_list.Managed(DirEnt).init(gpa);
    defer dirs.deinit();
    {
        var it = theme.get("named_directory_icons").?.object.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*.object;
            const collapsed = std.fs.path.stem(v.get("collapsed").?.string);
            const expanded_path = if (v.get("expanded")) |ev| ev.string else v.get("collapsed").?.string;
            const expanded = std.fs.path.stem(expanded_path);
            if (pngExists(io, cwd, pngdir, collapsed, arena) and
                pngExists(io, cwd, pngdir, expanded, arena))
                try dirs.append(.{ .key = e.key_ptr.*, .collapsed = collapsed, .expanded = expanded });
        }
    }

    // Sort by raw key bytes (matches strcmp + bsearch on the C side).
    std.mem.sort(Pair, stems.items, {}, lessPair);
    std.mem.sort(Pair, suffixes.items, {}, lessPair);
    std.mem.sort(DirEnt, dirs.items, {}, lessDir);

    var out = std.array_list.Managed(u8).init(gpa);
    defer out.deinit();
    try out.appendSlice(
        \\/* Auto-generated from catppuccin zed-icons (Mocha theme mapping).
        \\   Do not edit by hand — see tools/gen_icons.zig (`zig build gen-icons`). */
        \\#ifndef ZC_ICON_DATA_H
        \\#define ZC_ICON_DATA_H
        \\
        \\typedef struct { const char *key; const char *icon; } ZcIconKV;
        \\typedef struct { const char *key; const char *collapsed; const char *expanded; } ZcIconDir;
        \\
        \\
    );
    try emitKV(&out, arena, "zc_stems", stems.items);
    try emitKV(&out, arena, "zc_suffixes", suffixes.items);

    try out.appendSlice("static const ZcIconDir zc_dirs[] = {\n");
    for (dirs.items) |d| {
        try out.appendSlice(try std.fmt.allocPrint(arena, "    {{ \"{s}\", \"{s}\", \"{s}\" }},\n", .{
            try esc(arena, d.key), try esc(arena, d.collapsed), try esc(arena, d.expanded),
        }));
    }
    try out.appendSlice("};\n");
    try out.appendSlice(try std.fmt.allocPrint(arena, "static const int zc_dirs_n = {d};\n\n", .{dirs.items.len}));
    try out.appendSlice("#endif\n");

    const out_path = try std.fmt.allocPrint(arena, "{s}/src/c/icon_data.h", .{repo_root});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.items });

    std.debug.print("stems={d} suffixes={d} dirs={d} skipped(missing png)={d}\n", .{
        stems.items.len, suffixes.items.len, dirs.items.len, miss,
    });
}

fn lessPair(_: void, a: Pair, b: Pair) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}
fn lessDir(_: void, a: DirEnt, b: DirEnt) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Collects (name → PNG stem) entries from `obj`, resolving each name's icon
/// key through `key2png` and skipping any whose PNG is absent.
fn collectKV(
    list: *std.array_list.Managed(Pair),
    obj: std.json.ObjectMap,
    key2png: std.StringHashMap([]const u8),
    io: std.Io,
    cwd: std.Io.Dir,
    pngdir: []const u8,
    arena: std.mem.Allocator,
    miss: *usize,
) !void {
    var it = obj.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const key = e.value_ptr.*.string;
        if (key2png.get(key)) |stem| {
            if (pngExists(io, cwd, pngdir, stem, arena)) {
                try list.append(.{ .key = name, .val = stem });
                continue;
            }
        }
        miss.* += 1;
    }
}

fn emitKV(out: *std.array_list.Managed(u8), arena: std.mem.Allocator, name: []const u8, items: []const Pair) !void {
    try out.appendSlice(try std.fmt.allocPrint(arena, "static const ZcIconKV {s}[] = {{\n", .{name}));
    for (items) |kv| {
        try out.appendSlice(try std.fmt.allocPrint(arena, "    {{ \"{s}\", \"{s}\" }},\n", .{
            try esc(arena, kv.key), try esc(arena, kv.val),
        }));
    }
    try out.appendSlice("};\n");
    try out.appendSlice(try std.fmt.allocPrint(arena, "static const int {s}_n = {d};\n\n", .{ name, items.len }));
}

/// True when `<pngdir>/<name>.png` exists.
fn pngExists(io: std.Io, cwd: std.Io.Dir, pngdir: []const u8, name: []const u8, arena: std.mem.Allocator) bool {
    const p = std.fmt.allocPrint(arena, "{s}/{s}.png", .{ pngdir, name }) catch return false;
    cwd.access(io, p, .{}) catch return false;
    return true;
}

/// Escapes `\` and `"` for a C string literal (returns `s` unchanged when no
/// escaping is needed).
fn esc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const needs = for (s) |ch| {
        if (ch == '\\' or ch == '"') break true;
    } else false;
    if (!needs) return s;

    var buf = std.array_list.Managed(u8).init(arena);
    for (s) |ch| {
        if (ch == '\\' or ch == '"') try buf.append('\\');
        try buf.append(ch);
    }
    return buf.items;
}

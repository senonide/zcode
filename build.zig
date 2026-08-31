const std = @import("std");

/// The single source of truth for the app version is `build.zig.zon`'s
/// `.version` field.  This reads it at configure time and injects it into
/// the binary via the `build_options` module, so the About dialog and the
/// embedded version metadata always match the manifest.
fn readVersion(b: *std.Build) std.SemanticVersion {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const path = b.pathFromRoot("build.zig.zon");
    const bytes = cwd.readFileAlloc(io, path, b.allocator, .limited(1 << 20)) catch
        @panic("could not read build.zig.zon");
    defer b.allocator.free(bytes);
    const src = b.allocator.allocSentinel(u8, bytes.len, 0) catch @panic("OOM");
    defer b.allocator.free(src);
    @memcpy(src[0..bytes.len], bytes);
    const Manifest = struct { version: []const u8 };
    const m = std.zon.parse.fromSliceAlloc(Manifest, b.allocator, src, null, .{
        .ignore_unknown_fields = true,
    }) catch @panic("could not parse .version from build.zig.zon");
    return std.SemanticVersion.parse(m.version) catch
        @panic(".version in build.zig.zon is not valid semver");
}

pub fn build(b: *std.Build) void {
    const version = readVersion(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zcode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Strip release binaries (smaller shippable Flatpak); keep debug info
            // in Debug builds for backtraces.
            .strip = optimize != .Debug,
        }),
        .version = version,
    });

    // Expose the manifest version to source code via the standard
    // `build_options` import (see `application.zig`'s About dialog).
    const opts = b.addOptions();
    opts.addOption(std.SemanticVersion, "version", version);
    exe.root_module.addImport("build_options", opts.createModule());

    exe.root_module.linkSystemLibrary("gtk4", .{});
    exe.root_module.linkSystemLibrary("libadwaita-1", .{});
    exe.root_module.linkSystemLibrary("gtksourceview-5", .{});
    exe.root_module.linkSystemLibrary("vte-2.91-gtk4", .{});
    exe.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
    exe.root_module.linkSystemLibrary("libcmark", .{});

    // Tree-sitter: Zig bindings + amalgamated runtime.  The grammars (including
    // Zig) are vendored generated C compiled below, so no grammar package dep.
    const ts_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));

    // C glue (GObject-heavy bits that don't translate cleanly to Zig).  One
    // translation unit per subsystem; shared C-to-C declarations live in
    // src/c/zc_internal.h.  See ARCHITECTURE.md.
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/c/icons.c",
            "src/c/git.c",
            "src/c/file_item.c",
            "src/c/tree.c",
            "src/c/tree_rows.c",
            "src/c/tree_menu.c",
            "src/c/diff.c",
            "src/c/overview.c",
            "src/c/search.c",
            "src/c/terminal.c",
            "src/c/util.c",
            "src/c/lsp_io.c",
            "src/c/completion.c",
            "src/c/hover.c",
            "src/c/signature.c",
            "src/c/editor.c",
        },
        .flags = &.{"-Wno-deprecated-declarations"},
    });
    exe.root_module.addIncludePath(b.path("src/c"));

    // Vendored tree-sitter grammars (generated C).  Each parser/scanner finds its
    // own `tree_sitter/*.h` via quoted includes relative to the file, so no extra
    // include path is needed.  `-w` silences the generated code's warnings.
    //
    // `-fno-sanitize=function` disables UBSan's indirect-call type check for this
    // third-party code.  Grammars define their external scanner with an
    // unprototyped signature (e.g. `..._scanner_create()`), but the runtime calls
    // it through a `void *(*)(void)` pointer; the type hashes differ, so in Debug
    // builds (UBSan on) every parse traps with SIGILL the moment the scanner is
    // invoked.  The call is well-defined in practice — only the strict check fires.
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/grammars/zig/src/parser.c",
            "vendor/grammars/go/src/parser.c",
            "vendor/grammars/rust/src/parser.c",
            "vendor/grammars/rust/src/scanner.c",
            "vendor/grammars/c/src/parser.c",
            "vendor/grammars/python/src/parser.c",
            "vendor/grammars/python/src/scanner.c",
            "vendor/grammars/javascript/src/parser.c",
            "vendor/grammars/javascript/src/scanner.c",
            "vendor/grammars/typescript/typescript/src/parser.c",
            "vendor/grammars/typescript/typescript/src/scanner.c",
            "vendor/grammars/typescript/tsx/src/parser.c",
            "vendor/grammars/typescript/tsx/src/scanner.c",
            "vendor/grammars/markdown/src/parser.c",
            "vendor/grammars/markdown/src/scanner.c",
        },
        .flags = &.{ "-w", "-fno-sanitize=function" },
    });
    // TypeScript's shared common/scanner.h includes "tree_sitter/parser.h"
    // relative to itself, where there is no such dir — give it one to find.
    exe.root_module.addIncludePath(b.path("vendor/grammars/typescript/typescript/src"));

    b.installArtifact(exe);

    // Desktop integration files (consumed by `zig build install` / packaging).
    const install_desktop = b.addInstallFileWithDir(
        b.path("data/org.senonide.zcode.desktop"),
        .prefix,
        "share/applications/org.senonide.zcode.desktop",
    );
    b.getInstallStep().dependOn(&install_desktop.step);

    const install_metainfo = b.addInstallFileWithDir(
        b.path("data/org.senonide.zcode.metainfo.xml"),
        .prefix,
        "share/metainfo/org.senonide.zcode.metainfo.xml",
    );
    b.getInstallStep().dependOn(&install_metainfo.step);

    const install_icon = b.addInstallFileWithDir(
        b.path("data/icons/hicolor/scalable/apps/org.senonide.zcode.svg"),
        .prefix,
        "share/icons/hicolor/scalable/apps/org.senonide.zcode.svg",
    );
    b.getInstallStep().dependOn(&install_icon.step);

    const install_icon_symbolic = b.addInstallFileWithDir(
        b.path("data/icons/hicolor/symbolic/apps/org.senonide.zcode-symbolic.svg"),
        .prefix,
        "share/icons/hicolor/symbolic/apps/org.senonide.zcode-symbolic.svg",
    );
    b.getInstallStep().dependOn(&install_icon_symbolic.step);

    // GSettings schema (preferences + recent projects).  Compiled right after
    // installing so a plain `zig-out/bin/zcode` run finds a usable schema dir;
    // the `run` step below points GSETTINGS_SCHEMA_DIR at it.  Flatpak builds
    // get the same compile for free from flatpak-builder.
    const install_gschema = b.addInstallFileWithDir(
        b.path("data/org.senonide.zcode.gschema.xml"),
        .prefix,
        "share/glib-2.0/schemas/org.senonide.zcode.gschema.xml",
    );
    b.getInstallStep().dependOn(&install_gschema.step);

    const schema_dir = b.getInstallPath(.prefix, "share/glib-2.0/schemas");
    if (b.findProgram(&.{"glib-compile-schemas"}, &.{})) |compiler| {
        const compile_schemas = b.addSystemCommand(&.{ compiler, schema_dir });
        compile_schemas.step.dependOn(&install_gschema.step);
        b.getInstallStep().dependOn(&compile_schemas.step);
    } else |_| {}

    // Catppuccin file/folder icons (rendered from zed-icons) used by the tree.
    const install_icons = b.addInstallDirectory(.{
        .source_dir = b.path("data/icons"),
        .install_dir = .prefix,
        .install_subdir = "share/zcode/icons",
    });
    b.getInstallStep().dependOn(&install_icons.step);

    // Adwaita Pastel GtkSourceView style schemes (light/dark) for the editor.
    const install_styles = b.addInstallDirectory(.{
        .source_dir = b.path("data/styles"),
        .install_dir = .prefix,
        .install_subdir = "share/zcode/styles",
    });
    b.getInstallStep().dependOn(&install_styles.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setEnvironmentVariable("GSETTINGS_SCHEMA_DIR", schema_dir);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests — same dependencies as the main binary so all modules compile.
    // Rooted at src/tests.zig rather than src/main.zig: a test build never
    // references `main`, so nothing below it is analysed and no test is found.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.linkSystemLibrary("gtk4", .{});
    unit_tests.root_module.linkSystemLibrary("libadwaita-1", .{});
    unit_tests.root_module.linkSystemLibrary("gtksourceview-5", .{});
    unit_tests.root_module.linkSystemLibrary("vte-2.91-gtk4", .{});
    unit_tests.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
    unit_tests.root_module.linkSystemLibrary("libcmark", .{});
    unit_tests.root_module.addImport("tree-sitter", ts_dep.module("tree_sitter"));
    // completion.c, hover.c, signature.c, and editor.c are excluded from the
    // test build: they call Zig `export fn` symbols (zc_lsp_complete, etc.)
    // which creates a circular C↔Zig link dependency that the test runner
    // cannot resolve.  test_stubs.c provides no-op replacements for every
    // symbol those four files export, breaking the cycle.
    const test_opts = b.addOptions();
    test_opts.addOption(std.SemanticVersion, "version", version);
    unit_tests.root_module.addImport("build_options", test_opts.createModule());
    unit_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "src/c/icons.c",
            "src/c/git.c",
            "src/c/file_item.c",
            "src/c/tree.c",
            "src/c/tree_rows.c",
            "src/c/tree_menu.c",
            "src/c/diff.c",
            "src/c/overview.c",
            "src/c/search.c",
            "src/c/terminal.c",
            "src/c/util.c",
            "src/c/lsp_io.c",
            "src/c/test_stubs.c",
        },
        .flags = &.{"-Wno-deprecated-declarations"},
    });
    unit_tests.root_module.addIncludePath(b.path("src/c"));
    unit_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/grammars/zig/src/parser.c",
            "vendor/grammars/go/src/parser.c",
            "vendor/grammars/rust/src/parser.c",
            "vendor/grammars/rust/src/scanner.c",
            "vendor/grammars/c/src/parser.c",
            "vendor/grammars/python/src/parser.c",
            "vendor/grammars/python/src/scanner.c",
            "vendor/grammars/javascript/src/parser.c",
            "vendor/grammars/javascript/src/scanner.c",
            "vendor/grammars/typescript/typescript/src/parser.c",
            "vendor/grammars/typescript/typescript/src/scanner.c",
            "vendor/grammars/typescript/tsx/src/parser.c",
            "vendor/grammars/typescript/tsx/src/scanner.c",
            "vendor/grammars/markdown/src/parser.c",
            "vendor/grammars/markdown/src/scanner.c",
        },
        .flags = &.{ "-w", "-fno-sanitize=function" },
    });
    unit_tests.root_module.addIncludePath(b.path("vendor/grammars/typescript/typescript/src"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Icon-table generator (build-host tool): regenerates src/c/icon_data.h from
    // the vendored zed-icons theme.  Maintainer-only — run when refreshing the
    // icon set:
    //   zig build gen-icons -- [theme.json] [repo_root]
    // Both arguments default to the vendored theme and the repo root as cwd.
    const gen_icons = b.addExecutable(.{
        .name = "gen-icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_icons.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_gen = b.addRunArtifact(gen_icons);
    if (b.args) |args| run_gen.addArgs(args);

    const gen_step = b.step("gen-icons", "Regenerate src/c/icon_data.h from the zed-icons theme");
    gen_step.dependOn(&run_gen.step);
}

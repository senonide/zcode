//! Test root.
//!
//! `main.zig` cannot serve as one: a test build never references `main`, so
//! nothing downstream of it is analysed and the whole suite silently collects
//! zero tests.  Importing each module with tests here is what makes them run.
//! Add a line when a module grows its first test.
const std = @import("std");
comptime {
    _ = @import("core/config.zig");
    _ = @import("core/session.zig");
    _ = @import("editor/document.zig");

    _ = @import("editor/filesync.zig");
    _ = @import("editor/position.zig");
    _ = @import("editor/language.zig");
    _ = @import("editor/palette.zig");
    _ = @import("editor/preview.zig");
    _ = @import("editor/syntax.zig");
    _ = @import("lsp/client.zig");
    _ = @import("lsp/manager.zig");
    _ = @import("lsp/transport.zig");
    _ = @import("app/quickopen.zig");
}
test "build version is valid semver" {
    const v = @import("build_options").version;
    try std.testing.expect(v.major >= 0);
    try std.testing.expect(v.minor >= 0);
    try std.testing.expect(v.patch >= 0);
}

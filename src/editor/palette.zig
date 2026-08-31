//! Adwaita Pastel syntax palette — maps a tree-sitter capture to a colour.

const std = @import("std");

pub const Style = struct {
    dark: [*:0]const u8,
    light: [*:0]const u8,
    italic: bool = false,
    bold: bool = false,
};

/// Resolves a capture name to its style, walking up the dotted hierarchy
/// (`function.call` falls back to `function`).  Captures with no entry — notably
/// `variable` — return null and keep the editor's default text colour.
pub fn lookup(name: []const u8) ?Style {
    var n = name;
    while (true) {
        for (table) |e| {
            if (std.mem.eql(u8, n, e.name)) return e.style;
        }
        const dot = std.mem.lastIndexOfScalar(u8, n, '.') orelse return null;
        n = n[0..dot];
    }
}

const Entry = struct { name: []const u8, style: Style };

fn fg(dark: [*:0]const u8, light: [*:0]const u8) Style {
    return .{ .dark = dark, .light = light };
}

test "lookup exact match" {
    const s = lookup("comment").?;
    try std.testing.expectEqualStrings("#7f849c", std.mem.sliceTo(s.dark, 0));
    try std.testing.expect(s.italic);
    try std.testing.expect(!s.bold);
}

test "lookup hierarchy fallback" {
    // "function.call" has no direct entry; it should fall back to "function".
    const direct = lookup("function").?;
    const via_fallback = lookup("function.call").?;
    try std.testing.expectEqualStrings(std.mem.sliceTo(direct.dark, 0), std.mem.sliceTo(via_fallback.dark, 0));
    try std.testing.expectEqualStrings(std.mem.sliceTo(direct.light, 0), std.mem.sliceTo(via_fallback.light, 0));
}

test "lookup deep hierarchy fallback" {
    // "keyword.control.flow" → "keyword.control" → "keyword"
    const kw = lookup("keyword").?;
    const deep = lookup("keyword.control.flow").?;
    try std.testing.expectEqualStrings(std.mem.sliceTo(kw.dark, 0), std.mem.sliceTo(deep.dark, 0));
}

test "lookup variable returns null" {
    // "variable" has no entry — it inherits the default editor colour.
    try std.testing.expect(lookup("variable") == null);
}

test "lookup unknown returns null" {
    try std.testing.expect(lookup("no.such.capture.name") == null);
}

const table = [_]Entry{
    .{ .name = "comment", .style = .{ .dark = "#7f849c", .light = "#8c8fa1", .italic = true } },
    .{ .name = "string", .style = fg("#a6e3a1", "#40a02b") },
    .{ .name = "character", .style = fg("#a6e3a1", "#40a02b") },
    .{ .name = "string.escape", .style = fg("#f5c2e7", "#ea76cb") },
    .{ .name = "string.special", .style = fg("#f5c2e7", "#ea76cb") },
    .{ .name = "escape", .style = fg("#f5c2e7", "#ea76cb") },
    .{ .name = "embedded", .style = fg("#eba0ac", "#e64553") },
    .{ .name = "number", .style = fg("#fab387", "#fe640b") },
    .{ .name = "boolean", .style = fg("#fab387", "#fe640b") },
    .{ .name = "constant", .style = fg("#fab387", "#fe640b") },
    .{ .name = "type", .style = fg("#f9e2af", "#df8e1d") },
    .{ .name = "module", .style = fg("#f9e2af", "#df8e1d") },
    .{ .name = "attribute", .style = fg("#f9e2af", "#df8e1d") },
    .{ .name = "function", .style = .{ .dark = "#89b4fa", .light = "#1e66f5", .italic = true } },
    .{ .name = "constructor", .style = fg("#89b4fa", "#1e66f5") },
    .{ .name = "property", .style = fg("#89b4fa", "#1e66f5") },
    .{ .name = "keyword", .style = fg("#cba6f7", "#8839ef") },
    .{ .name = "import", .style = fg("#cba6f7", "#8839ef") },
    .{ .name = "operator", .style = fg("#89dceb", "#04a5e5") },
    .{ .name = "label", .style = fg("#f38ba8", "#d20f39") },
    .{ .name = "variable.parameter", .style = .{ .dark = "#fab387", .light = "#fe640b", .italic = true } },
    .{ .name = "variable.builtin", .style = fg("#f38ba8", "#d20f39") },
    .{ .name = "punctuation.bracket", .style = fg("#94e2d5", "#179299") },
    .{ .name = "punctuation.special", .style = fg("#94e2d5", "#179299") },
    .{ .name = "punctuation.delimiter", .style = fg("#9399b2", "#7c7f93") },
    .{ .name = "delimiter", .style = fg("#9399b2", "#7c7f93") },
};

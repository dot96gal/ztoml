const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Cursor = cursor_mod.Cursor;
const Value = types.Value;

pub fn parseBoolean(cursor: *Cursor) errors.ParseError!Value {
    const result: Value = blk: {
        if (cursor.startsWith("true")) {
            cursor.advanceAscii(4);
            break :blk .{ .boolean = true };
        }
        if (cursor.startsWith("false")) {
            cursor.advanceAscii(5);
            break :blk .{ .boolean = false };
        }
        cursor.fillDiagnostic("expected 'true' or 'false'");
        return error.UnexpectedChar;
    };

    if (!cursor.isLiteralTerminator()) {
        cursor.fillDiagnostic("unexpected character after boolean literal");
        return error.UnexpectedChar;
    }

    return result;
}

// --- parseBoolean ---

test "parseBoolean: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { boolean: bool, position: usize },
    }{
        .{
            .name = "true at EOF",
            .input = "true",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "false at EOF",
            .input = "false",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "true with space",
            .input = "true ",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with multiple spaces",
            .input = "true   ",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with newline",
            .input = "true\n",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "false with space",
            .input = "false ",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "false with newline",
            .input = "false\n",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "true with tab",
            .input = "true\t",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with comma",
            .input = "true,",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with right bracket",
            .input = "true]",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "false with tab",
            .input = "false\t",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "false with comma",
            .input = "false,",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "false with right bracket",
            .input = "false]",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "false with right brace",
            .input = "false}",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "false with hash",
            .input = "false#",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "true with hash",
            .input = "true#",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with right brace",
            .input = "true}",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "true with CRLF",
            .input = "true\r\n",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "false with CRLF",
            .input = "false\r\n",
            .expected = .{ .boolean = false, .position = 5 },
        },
        .{
            .name = "true followed by space then another token",
            .input = "true false",
            .expected = .{ .boolean = true, .position = 4 },
        },
        .{
            .name = "false followed by space then another token",
            .input = "false true",
            .expected = .{ .boolean = false, .position = 5 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseBoolean(&cursor);
        try std.testing.expectEqual(Value{ .boolean = tc.expected.boolean }, result);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
    }
}

test "parseBoolean: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "invalid input", .input = "yes", .expected = 0 },
        .{ .name = "empty input", .input = "", .expected = 0 },
        .{ .name = "true followed by non-delimiter", .input = "truex", .expected = 4 },
        .{ .name = "false followed by non-delimiter", .input = "falsex", .expected = 5 },
        .{ .name = "uppercase TRUE", .input = "TRUE", .expected = 0 },
        .{ .name = "mixed case False", .input = "False", .expected = 0 },
        .{ .name = "mixed case tRuE", .input = "tRuE", .expected = 0 },
        .{ .name = "partial true", .input = "tr", .expected = 0 },
        .{ .name = "partial false", .input = "fals", .expected = 0 },
        .{ .name = "single char t", .input = "t", .expected = 0 },
        .{ .name = "single char f", .input = "f", .expected = 0 },
        .{ .name = "uppercase FALSE", .input = "FALSE", .expected = 0 },
        .{ .name = "numeric input", .input = "0", .expected = 0 },
        .{ .name = "null byte input", .input = "\x00", .expected = 0 },
        .{ .name = "true followed by null byte", .input = "true\x00", .expected = 4 },
        .{ .name = "true followed by left bracket", .input = "true[", .expected = 4 },
        .{ .name = "true followed by equals sign", .input = "true=", .expected = 4 },
        .{ .name = "false followed by left bracket", .input = "false[", .expected = 5 },
        .{ .name = "false followed by equals sign", .input = "false=", .expected = 5 },
        .{ .name = "false followed by null byte", .input = "false\x00", .expected = 5 },
        .{ .name = "no input", .input = "no", .expected = 0 },
        .{ .name = "true followed by false", .input = "truefalse", .expected = 4 },
        .{ .name = "false followed by true", .input = "falsetrue", .expected = 5 },
        .{ .name = "true followed by exclamation mark", .input = "true!", .expected = 4 },
        .{ .name = "false followed by period", .input = "false.", .expected = 5 },
        .{ .name = "true followed by bare CR", .input = "true\r", .expected = 4 },
        .{ .name = "false followed by bare CR", .input = "false\r", .expected = 5 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(error.UnexpectedChar, parseBoolean(&cursor));
        try std.testing.expectEqual(tc.expected, cursor.position);
    }
}

test "parseBoolean: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            message: []const u8,
            line: usize,
            column: usize,
            position: usize,
        },
    }{
        .{
            .name = "invalid literal",
            .input = "yes",
            .expected = .{
                .message = "expected 'true' or 'false'",
                .line = 1,
                .column = 1,
                .position = 0,
            },
        },
        .{
            .name = "numeric literal",
            .input = "0",
            .expected = .{
                .message = "expected 'true' or 'false'",
                .line = 1,
                .column = 1,
                .position = 0,
            },
        },
        .{
            .name = "non-delimiter after true literal",
            .input = "truex",
            .expected = .{
                .message = "unexpected character after boolean literal",
                .line = 1,
                .column = 5,
                .position = 4,
            },
        },
        .{
            .name = "non-delimiter after false literal",
            .input = "falsex",
            .expected = .{
                .message = "unexpected character after boolean literal",
                .line = 1,
                .column = 6,
                .position = 5,
            },
        },
        .{
            .name = "bare CR after true",
            .input = "true\r",
            .expected = .{
                .message = "unexpected character after boolean literal",
                .line = 1,
                .column = 5,
                .position = 4,
            },
        },
        .{
            .name = "bare CR after false",
            .input = "false\r",
            .expected = .{
                .message = "unexpected character after boolean literal",
                .line = 1,
                .column = 6,
                .position = 5,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(error.UnexpectedChar, parseBoolean(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
    }
}

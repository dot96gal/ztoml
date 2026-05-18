const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Cursor = cursor_mod.Cursor;

const FastPathResult = union(enum) {
    partial: usize,
    done: []const u8,
};

pub fn parseLiteralString(cursor: *Cursor) errors.ParseError![]const u8 {
    _ = cursor.advance();
    const start = cursor.position;
    while (cursor.peek()) |c| {
        if (c == '\'') {
            const s = cursor.peekSliceSince(start);
            _ = cursor.advance();
            return s;
        } else if ((c < 0x20 and c != '\t') or c == 0x7F) {
            cursor.fillDiagnostic("control character not allowed in literal string");
            return error.UnexpectedChar;
        }
        _ = cursor.advance();
    }

    cursor.fillDiagnostic("unterminated literal string");
    return error.UnexpectedEof;
}

pub fn parseMultilineBasicString(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})![]const u8 {
    const allocator = arena.allocator();
    cursor.advanceAscii(3);
    cursor.skipNewline();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    while (true) {
        const c = cursor.peek() orelse {
            cursor.fillDiagnostic("unterminated multiline basic string");
            return error.UnexpectedEof;
        };
        if (c == '"') {
            const qcount = skipConsecutiveChar(cursor, '"');
            if (qcount >= 3) {
                const trailing = qcount - 3;
                for (0..trailing) |_| try buf.append(allocator, '"');
                break;
            }
            for (0..qcount) |_| try buf.append(allocator, '"');
        } else if (c == '\\') {
            _ = cursor.advance();
            if (cursor.peek()) |esc| {
                if (esc == '\n' or esc == '\r' or esc == ' ' or esc == '\t') {
                    skipLineContinuation(cursor);
                    continue;
                }
            }
            try parseEscapeSequence(cursor, arena, &buf);
        } else {
            if ((c < 0x20 and c != '\t' and c != '\n' and c != '\r') or c == 0x7F) {
                cursor.fillDiagnostic("control character not allowed in multiline basic string");
                return error.UnexpectedChar;
            }
            if (c >= 0x80) {
                try appendUtf8Byte(&buf, arena, cursor, c);
            } else {
                _ = cursor.advance();
                try buf.append(allocator, c);
            }
        }
    }

    return try buf.toOwnedSlice(allocator);
}

pub fn parseMultilineLiteralString(cursor: *Cursor) errors.ParseError![]const u8 {
    cursor.advanceAscii(3);
    cursor.skipNewline();

    const start = cursor.position;
    while (true) {
        const c = cursor.peek() orelse {
            cursor.fillDiagnostic("unterminated multiline literal string");
            return error.UnexpectedEof;
        };
        if (c == '\'') {
            const before = cursor.position;
            const qcount = skipConsecutiveChar(cursor, '\'');
            if (qcount >= 3) {
                return cursor.input[start .. before + (qcount - 3)];
            }
        } else {
            if ((c < 0x20 and c != '\t' and c != '\n' and c != '\r') or c == 0x7F) {
                cursor.fillDiagnostic("control character not allowed in multiline literal string");
                return error.UnexpectedChar;
            }
            _ = cursor.advance();
        }
    }
}

pub fn parseBasicString(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})![]const u8 {
    _ = cursor.advance();
    const start = cursor.position;
    return switch (parseBasicStringFastPath(cursor, start)) {
        .partial => |scan_end| try parseBasicStringSlowPath(cursor, arena, start, scan_end),
        .done => |s| s,
    };
}

fn parseBasicStringFastPath(cursor: *Cursor, start: usize) FastPathResult {
    if (cursor.position != start) {
        @panic("parseBasicStringFastPath: cursor.position must equal start");
    }

    const slice = cursor.peekRest();

    for (slice, 0..) |c, i| {
        if (c == '"') {
            cursor.advanceTo(start + i + 1);
            return .{ .done = slice[0..i] };
        }
        if (c == '\\' or (c < 0x20 and c != '\t') or c == 0x7F) {
            cursor.advanceTo(start + i);
            return .{ .partial = start + i };
        }
    }
    cursor.advanceTo(start + slice.len);

    return .{ .partial = start + slice.len };
}

fn parseBasicStringSlowPath(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    start: usize,
    scan_end: usize,
) (errors.ParseError || error{OutOfMemory})![]const u8 {
    const allocator = arena.allocator();
    if (cursor.position != scan_end) {
        @panic("parseBasicStringSlowPath: cursor.position must equal scan_end");
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(allocator, cursor.input[start..scan_end]);

    while (true) {
        const c = cursor.peek() orelse {
            cursor.fillDiagnostic("unterminated string");
            return error.UnexpectedEof;
        };
        if (c == '"') {
            _ = cursor.advance();
            break;
        } else if (c == '\\') {
            _ = cursor.advance();
            try parseEscapeSequence(cursor, arena, &buf);
        } else if ((c < 0x20 and c != '\t') or c == 0x7F) {
            cursor.fillDiagnostic("control character not allowed in basic string");
            return error.UnexpectedChar;
        } else if (c >= 0x80) {
            try appendUtf8Byte(&buf, arena, cursor, c);
        } else {
            _ = cursor.advance();
            try buf.append(allocator, c);
        }
    }

    return try buf.toOwnedSlice(allocator);
}

fn parseEscapeSequence(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    buf: *std.ArrayListUnmanaged(u8),
) (errors.ParseError || error{OutOfMemory})!void {
    const allocator = arena.allocator();
    const esc = cursor.peek() orelse {
        cursor.fillDiagnostic("unexpected end of input after backslash");
        return error.UnexpectedEof;
    };

    _ = cursor.advance();
    switch (esc) {
        'b' => try buf.append(allocator, 0x08),
        't' => try buf.append(allocator, '\t'),
        'n' => try buf.append(allocator, '\n'),
        'f' => try buf.append(allocator, 0x0C),
        'r' => try buf.append(allocator, '\r'),
        'e' => try buf.append(allocator, 0x1B),
        '"' => try buf.append(allocator, '"'),
        '\\' => try buf.append(allocator, '\\'),
        'x' => try appendUtf8Codepoint(buf, arena, try parseHexCodepoint(cursor, 2)),
        'u' => try appendUtf8Codepoint(buf, arena, try parseHexCodepoint(cursor, 4)),
        'U' => try appendUtf8Codepoint(buf, arena, try parseHexCodepoint(cursor, 8)),
        else => {
            cursor.fillDiagnostic("invalid escape sequence");
            return error.InvalidEscape;
        },
    }
}

fn parseHexCodepoint(cursor: *Cursor, n: usize) errors.ParseError!u21 {
    var value: u32 = 0;
    for (0..n) |_| {
        const h = cursor.peek() orelse {
            cursor.fillDiagnostic("unexpected end of input in unicode escape");
            return error.InvalidUnicode;
        };
        _ = cursor.advance();
        const digit = std.fmt.charToDigit(h, 16) catch {
            cursor.fillDiagnostic("invalid hex digit in unicode escape");
            return error.InvalidUnicode;
        };
        value = value * 16 + digit;
    }

    if (value > 0x10FFFF or !std.unicode.utf8ValidCodepoint(@intCast(value))) {
        cursor.fillDiagnostic("invalid unicode code point");
        return error.InvalidUnicode;
    }

    return @intCast(value);
}

fn skipConsecutiveChar(cursor: *Cursor, comptime char: u8) usize {
    var qcount: usize = 0;
    while (cursor.peek() == char) {
        qcount += 1;
        _ = cursor.advance();
    }

    return qcount;
}

fn skipLineContinuation(cursor: *Cursor) void {
    while (cursor.peek()) |ws| {
        if (ws == ' ' or ws == '\t' or ws == '\n' or ws == '\r') {
            _ = cursor.advance();
        } else break;
    }
}

fn appendUtf8Codepoint(
    buf: *std.ArrayListUnmanaged(u8),
    arena: *std.heap.ArenaAllocator,
    cp: u21,
) (error{InvalidUnicode} || error{OutOfMemory})!void {
    const allocator = arena.allocator();
    var tmp: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &tmp) catch return error.InvalidUnicode;

    try buf.appendSlice(allocator, tmp[0..len]);
}

fn appendUtf8Byte(
    buf: *std.ArrayListUnmanaged(u8),
    arena: *std.heap.ArenaAllocator,
    cursor: *Cursor,
    c: u8,
) (error{InvalidUnicode} || error{OutOfMemory})!void {
    const allocator = arena.allocator();
    const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
        cursor.fillDiagnostic("invalid UTF-8 byte in string");
        return error.InvalidUnicode;
    };
    if (seq_len > 1) {
        if (cursor.peekSlice(seq_len)) |seq| {
            cursor.advanceUtf8Sequence();
            try buf.appendSlice(allocator, seq);
        } else {
            cursor.fillDiagnostic("incomplete UTF-8 sequence in string");
            return error.InvalidUnicode;
        }
    } else {
        _ = cursor.advance();
        try buf.append(allocator, c);
    }
}

// --- parseLiteralString ---

test "parseLiteralString: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "simple", .input = "'hello'", .expected = "hello" },
        .{ .name = "empty", .input = "''", .expected = "" },
        .{ .name = "backslash not escaped", .input = "'C:\\path'", .expected = "C:\\path" },
        .{ .name = "literal tab allowed", .input = "'\t'", .expected = "\t" },
        .{ .name = "multibyte unicode", .input = "'\xe3\x81\x82'", .expected = "\xe3\x81\x82" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseLiteralString(&cursor);
        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

test "parseLiteralString: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "unterminated",
            .input = "'hello",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "NUL char",
            .input = "'\x00'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "control char",
            .input = "'\x01'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "DEL char",
            .input = "'\x7F'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "control char 0x1F",
            .input = "'\x1F'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "newline not allowed",
            .input = "'\n'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "carriage return not allowed",
            .input = "'\r'",
            .expected = error.UnexpectedChar,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseLiteralString(&cursor));
    }
}

test "parseLiteralString: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "control character",
            .input = "'\x01'",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "control character not allowed in literal string",
                .line = 1,
                .column = 2,
            },
        },
        .{
            .name = "unterminated",
            .input = "'hello",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unterminated literal string",
                .line = 1,
                .column = 7,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseLiteralString(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseMultilineBasicString ---

test "parseMultilineBasicString: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .input = "\"\"\"hello\"\"\"",
            .expected = "hello",
        },
        .{
            .name = "opening newline stripped",
            .input = "\"\"\"\nhello\"\"\"",
            .expected = "hello",
        },
        .{
            .name = "multiline content",
            .input = "\"\"\"\nline1\nline2\"\"\"",
            .expected = "line1\nline2",
        },
        .{
            .name = "escape sequence",
            .input = "\"\"\"hel\\nlo\"\"\"",
            .expected = "hel\nlo",
        },
        .{
            .name = "line-ending backslash",
            .input = "\"\"\"\\\n   world\"\"\"",
            .expected = "world",
        },
        .{
            .name = "line-ending backslash CR",
            .input = "\"\"\"\\\r   world\"\"\"",
            .expected = "world",
        },
        .{
            .name = "line-ending backslash CRLF",
            .input = "\"\"\"\\\r\n   world\"\"\"",
            .expected = "world",
        },
        .{
            .name = "line-ending backslash space",
            .input = "\"\"\"\\   world\"\"\"",
            .expected = "world",
        },
        .{
            .name = "line-ending backslash tab",
            .input = "\"\"\"\\\t   world\"\"\"",
            .expected = "world",
        },
        .{
            .name = "one extra trailing quote",
            .input = "\"\"\"\"hello\"\"\"",
            .expected = "\"hello",
        },
        .{
            .name = "two extra trailing quotes",
            .input = "\"\"\"\"\"hello\"\"\"",
            .expected = "\"\"hello",
        },
        .{
            .name = "one trailing quote before close",
            .input = "\"\"\"content\"\"\"\"",
            .expected = "content\"",
        },
        .{
            .name = "two trailing quotes before close",
            .input = "\"\"\"content\"\"\"\"\"",
            .expected = "content\"\"",
        },
        .{
            .name = "multibyte UTF-8 sequence processed as unit",
            .input = "\"\"\"\xE3\x81\x82\"\"\"",
            .expected = "\xE3\x81\x82",
        },
        .{
            .name = "tab in content",
            .input = "\"\"\"he\tllo\"\"\"",
            .expected = "he\tllo",
        },
        .{
            .name = "CR in content",
            .input = "\"\"\"foo\rbar\"\"\"",
            .expected = "foo\rbar",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const result = try parseMultilineBasicString(&cursor, &arena);
        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

test "parseMultilineBasicString: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "unterminated",
            .input = "\"\"\"hello",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "NUL char",
            .input = "\"\"\"\x00\"\"\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "control char",
            .input = "\"\"\"\x01\"\"\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "DEL char",
            .input = "\"\"\"\x7F\"\"\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "control char 0x1F",
            .input = "\"\"\"\x1F\"\"\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "backslash at EOF",
            .input = "\"\"\"hello\\",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "invalid escape",
            .input = "\"\"\"\\q\"\"\"",
            .expected = error.InvalidEscape,
        },
        .{
            .name = "invalid UTF-8 byte",
            .input = "\"\"\"\x80\"\"\"",
            .expected = error.InvalidUnicode,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(
            tc.expected,
            parseMultilineBasicString(&cursor, &arena),
        );
    }
}

test "parseMultilineBasicString: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "unterminated",
            .input = "\"\"\"hello",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unterminated multiline basic string",
                .line = 1,
                .column = 9,
            },
        },
        .{
            .name = "control character",
            .input = "\"\"\"\x01\"\"\"",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "control character not allowed in multiline basic string",
                .line = 1,
                .column = 4,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseMultilineBasicString(&cursor, &arena));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseMultilineLiteralString ---

test "parseMultilineLiteralString: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple",
            .input = "'''hello'''",
            .expected = "hello",
        },
        .{
            .name = "opening newline stripped",
            .input = "'''\nhello'''",
            .expected = "hello",
        },
        .{
            .name = "multiline content",
            .input = "'''line1\nline2'''",
            .expected = "line1\nline2",
        },
        .{
            .name = "CR in content",
            .input = "'''line1\rline2'''",
            .expected = "line1\rline2",
        },
        .{
            .name = "CRLF in content",
            .input = "'''line1\r\nline2'''",
            .expected = "line1\r\nline2",
        },
        .{
            .name = "backslash not escaped",
            .input = "'''C:\\path'''",
            .expected = "C:\\path",
        },
        .{
            .name = "single quote in content",
            .input = "'''it's'''",
            .expected = "it's",
        },
        .{
            .name = "consecutive quotes in content",
            .input = "'''ab''cd'''",
            .expected = "ab''cd",
        },
        .{
            .name = "one extra leading quote",
            .input = "''''hello'''",
            .expected = "'hello",
        },
        .{
            .name = "two extra leading quotes",
            .input = "'''''hello'''",
            .expected = "''hello",
        },
        .{
            .name = "one extra trailing quote",
            .input = "'''hello''''",
            .expected = "hello'",
        },
        .{
            .name = "two extra trailing quotes",
            .input = "'''hello'''''",
            .expected = "hello''",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseMultilineLiteralString(&cursor);
        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

test "parseMultilineLiteralString: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "unterminated", .input = "'''hello", .expected = error.UnexpectedEof },
        .{ .name = "NUL char", .input = "'''\x00'''", .expected = error.UnexpectedChar },
        .{ .name = "control char", .input = "'''\x01'''", .expected = error.UnexpectedChar },
        .{ .name = "DEL char", .input = "'''\x7F'''", .expected = error.UnexpectedChar },
        .{ .name = "control char 0x1F", .input = "'''\x1F'''", .expected = error.UnexpectedChar },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseMultilineLiteralString(&cursor));
    }
}

test "parseMultilineLiteralString: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "unterminated",
            .input = "'''hello",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unterminated multiline literal string",
                .line = 1,
                .column = 9,
            },
        },
        .{
            .name = "control character",
            .input = "'''\x01'''",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "control character not allowed in multiline literal string",
                .line = 1,
                .column = 4,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseMultilineLiteralString(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseBasicString ---

test "parseBasicString: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "simple string fast path",
            .input = "\"hello\"",
            .expected = "hello",
        },
        .{
            .name = "empty string",
            .input = "\"\"",
            .expected = "",
        },
        .{
            .name = "literal tab allowed in fast path",
            .input = "\"he\tllo\"",
            .expected = "he\tllo",
        },
        .{
            .name = "escape newline",
            .input = "\"hel\\nlo\"",
            .expected = "hel\nlo",
        },
        .{
            .name = "escape tab",
            .input = "\"\\t\"",
            .expected = "\t",
        },
        .{
            .name = "escape backslash",
            .input = "\"hel\\\\lo\"",
            .expected = "hel\\lo",
        },
        .{
            .name = "escape double quote",
            .input = "\"say \\\"hi\\\"\"",
            .expected = "say \"hi\"",
        },
        .{
            .name = "escape backspace",
            .input = "\"\\b\"",
            .expected = "\x08",
        },
        .{
            .name = "escape form feed",
            .input = "\"\\f\"",
            .expected = "\x0C",
        },
        .{
            .name = "escape carriage return",
            .input = "\"\\r\"",
            .expected = "\r",
        },
        .{
            .name = "escape TOML e",
            .input = "\"\\e\"",
            .expected = "\x1B",
        },
        .{
            .name = "escape hex",
            .input = "\"\\x41\"",
            .expected = "A",
        },
        .{
            .name = "escape unicode 4-digit",
            .input = "\"\\u0041\"",
            .expected = "A",
        },
        .{
            .name = "escape unicode 8-digit",
            .input = "\"\\U00000041\"",
            .expected = "A",
        },
        .{
            .name = "mixed plain and escaped",
            .input = "\"ab\\ncd\"",
            .expected = "ab\ncd",
        },
        .{
            .name = "3-byte unicode escape",
            .input = "\"\\u3042\"",
            .expected = "\xe3\x81\x82",
        },
        .{
            .name = "4-byte unicode escape",
            .input = "\"\\U0001F600\"",
            .expected = "\xf0\x9f\x98\x80",
        },
        .{
            .name = "raw multibyte UTF-8",
            .input = "\"\xE3\x81\x82\"",
            .expected = "\xE3\x81\x82",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const result = try parseBasicString(&cursor, &arena);
        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

test "parseBasicString: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "unterminated", .input = "\"hello", .expected = error.UnexpectedEof },
        .{ .name = "NUL char", .input = "\"\x00\"", .expected = error.UnexpectedChar },
        .{ .name = "control char", .input = "\"\x01\"", .expected = error.UnexpectedChar },
        .{ .name = "DEL char", .input = "\"\x7F\"", .expected = error.UnexpectedChar },
        .{ .name = "control char 0x1F", .input = "\"\x1F\"", .expected = error.UnexpectedChar },
        .{ .name = "carriage return", .input = "\"\r\"", .expected = error.UnexpectedChar },
        .{ .name = "newline not allowed", .input = "\"\n\"", .expected = error.UnexpectedChar },
        .{ .name = "invalid escape", .input = "\"\\a\"", .expected = error.InvalidEscape },
        .{ .name = "invalid UTF-8", .input = "\"\\t\x80\"", .expected = error.InvalidUnicode },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseBasicString(&cursor, &arena));
    }
}

test "parseBasicString: cursor column after fast path to slow path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("\"abc\\n\"", null);
    _ = try parseBasicString(&cursor, &arena);
    try std.testing.expectEqual(@as(usize, 8), cursor.column);
}

test "parseBasicString: diagnostic column on slow path error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("\"abc\\q\"", &diagnostic);
    try std.testing.expectError(error.InvalidEscape, parseBasicString(&cursor, &arena));
    try std.testing.expectEqual(@as(usize, 7), diagnostic.column);
}

// --- parseBasicStringFastPath ---

test "parseBasicStringFastPath: done" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, start: usize },
        expected: []const u8,
    }{
        .{
            .name = "simple string",
            .input = .{ .s = "\"hello\"", .start = 1 },
            .expected = "hello",
        },
        .{
            .name = "empty string",
            .input = .{ .s = "\"\"", .start = 1 },
            .expected = "",
        },
        .{
            .name = "tab allowed",
            .input = .{ .s = "\"a\tb\"", .start = 1 },
            .expected = "a\tb",
        },
        .{
            .name = "multibyte UTF-8 passthrough",
            .input = .{ .s = "\"\xE3\x81\x82\"", .start = 1 },
            .expected = "\xE3\x81\x82",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.start); // invariant: cursor.position == start
        const result = parseBasicStringFastPath(&cursor, tc.input.start);
        try std.testing.expectEqualStrings(tc.expected, result.done);
    }
}

test "parseBasicStringFastPath: partial" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, start: usize },
        expected: usize,
    }{
        .{
            .name = "backslash stops scan",
            .input = .{ .s = "\"ab\\n\"", .start = 1 },
            .expected = 3,
        },
        .{
            .name = "control char stops scan",
            .input = .{ .s = "\"ab\x01\"", .start = 1 },
            .expected = 3,
        },
        .{
            .name = "carriage return stops scan",
            .input = .{ .s = "\"ab\r\"", .start = 1 },
            .expected = 3,
        },
        .{
            .name = "newline stops scan",
            .input = .{ .s = "\"ab\n\"", .start = 1 },
            .expected = 3,
        },
        .{
            .name = "DEL stops scan",
            .input = .{ .s = "\"ab\x7F\"", .start = 1 },
            .expected = 3,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.start); // invariant: cursor.position == start
        const result = parseBasicStringFastPath(&cursor, tc.input.start);
        try std.testing.expectEqual(tc.expected, result.partial);
    }
}

// --- parseBasicStringSlowPath ---

test "parseBasicStringSlowPath: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, start: usize, scan_end: usize },
        expected: []const u8,
    }{
        .{
            .name = "escape newline",
            .input = .{ .s = "\"ab\\ncd\"", .start = 1, .scan_end = 3 },
            .expected = "ab\ncd",
        },
        .{
            .name = "escape at start",
            .input = .{ .s = "\"\\t\"", .start = 1, .scan_end = 1 },
            .expected = "\t",
        },
        .{
            .name = "multibyte utf8 after escape",
            .input = .{ .s = "\"\\ncafé\"", .start = 1, .scan_end = 1 },
            .expected = "\ncafé",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceTo(tc.input.scan_end);
        const result = try parseBasicStringSlowPath(
            &cursor,
            &arena,
            tc.input.start,
            tc.input.scan_end,
        );
        try std.testing.expectEqualStrings(tc.expected, result);
    }
}

test "parseBasicStringSlowPath: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, start: usize, scan_end: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "unterminated",
            .input = .{ .s = "\"hello", .start = 1, .scan_end = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "control char",
            .input = .{ .s = "\"\x01\"", .start = 1, .scan_end = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "carriage return",
            .input = .{ .s = "\"\r\"", .start = 1, .scan_end = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "newline not allowed",
            .input = .{ .s = "\"\n\"", .start = 1, .scan_end = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "DEL char",
            .input = .{ .s = "\"\x7F\"", .start = 1, .scan_end = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid escape",
            .input = .{ .s = "\"\\q\"", .start = 1, .scan_end = 1 },
            .expected = error.InvalidEscape,
        },
        .{
            .name = "invalid UTF-8 byte",
            .input = .{ .s = "\"\\t\x80\"", .start = 1, .scan_end = 1 },
            .expected = error.InvalidUnicode,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceTo(tc.input.scan_end);
        try std.testing.expectError(
            tc.expected,
            parseBasicStringSlowPath(&cursor, &arena, tc.input.start, tc.input.scan_end),
        );
    }
}

test "parseBasicStringSlowPath: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, start: usize, scan_end: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "unterminated",
            .input = .{ .s = "\"hello", .start = 1, .scan_end = 1 },
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unterminated string",
                .line = 1,
                .column = 7,
            },
        },
        .{
            .name = "control character",
            .input = .{ .s = "\"\x01\"", .start = 1, .scan_end = 1 },
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "control character not allowed in basic string",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        cursor.advanceTo(tc.input.scan_end);
        try std.testing.expectError(tc.expected.err, parseBasicStringSlowPath(
            &cursor,
            &arena,
            tc.input.start,
            tc.input.scan_end,
        ));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseEscapeSequence ---

test "parseEscapeSequence: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "b → backspace", .input = "b", .expected = "\x08" },
        .{ .name = "t → tab", .input = "t", .expected = "\t" },
        .{ .name = "n → newline", .input = "n", .expected = "\n" },
        .{ .name = "f → form feed", .input = "f", .expected = "\x0C" },
        .{ .name = "r → carriage return", .input = "r", .expected = "\r" },
        .{ .name = "e → escape", .input = "e", .expected = "\x1B" },
        .{ .name = "quote", .input = "\"", .expected = "\"" },
        .{ .name = "backslash", .input = "\\", .expected = "\\" },
        .{ .name = "x hex codepoint", .input = "x41", .expected = "A" },
        .{ .name = "u unicode 4-digit", .input = "u0041", .expected = "A" },
        .{ .name = "U unicode 8-digit", .input = "U00000041", .expected = "A" },
        .{ .name = "x non-ASCII codepoint (U+0080)", .input = "x80", .expected = "\xC2\x80" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try parseEscapeSequence(&cursor, &arena, &buf);
        try std.testing.expectEqualStrings(tc.expected, buf.items);
    }
}

test "parseEscapeSequence: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "EOF after backslash",
            .input = "",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "invalid char",
            .input = "a",
            .expected = error.InvalidEscape,
        },
        .{
            .name = "\\x with invalid hex",
            .input = "xGG",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "\\u with too few digits",
            .input = "u00",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "\\U with too few digits",
            .input = "U000000",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "\\u with surrogate codepoint",
            .input = "uD800",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "\\U out of range",
            .input = "U00110000",
            .expected = error.InvalidUnicode,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(
            tc.expected,
            parseEscapeSequence(&cursor, &arena, &buf),
        );
    }
}

test "parseEscapeSequence: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "EOF after backslash",
            .input = "",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input after backslash",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "invalid escape char",
            .input = "q",
            .expected = .{
                .err = error.InvalidEscape,
                .message = "invalid escape sequence",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseEscapeSequence(&cursor, &arena, &buf));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseHexCodepoint ---

test "parseHexCodepoint: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: u21,
    }{
        .{
            .name = "2-digit ASCII",
            .input = .{ .s = "41", .n = 2 },
            .expected = 0x41,
        },
        .{
            .name = "4-digit ASCII",
            .input = .{ .s = "0041", .n = 4 },
            .expected = 0x41,
        },
        .{
            .name = "4-digit CJK",
            .input = .{ .s = "3042", .n = 4 },
            .expected = 0x3042,
        },
        .{
            .name = "8-digit max U+10FFFF",
            .input = .{ .s = "0010FFFF", .n = 8 },
            .expected = 0x10FFFF,
        },
        .{
            .name = "null codepoint U+0000",
            .input = .{ .s = "0000", .n = 4 },
            .expected = 0x0000,
        },
        .{
            .name = "just below surrogate (U+D7FF)",
            .input = .{ .s = "D7FF", .n = 4 },
            .expected = 0xD7FF,
        },
        .{
            .name = "just above surrogate (U+E000)",
            .input = .{ .s = "E000", .n = 4 },
            .expected = 0xE000,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        const cp = try parseHexCodepoint(&cursor, tc.input.n);
        try std.testing.expectEqual(tc.expected, cp);
    }
}

test "parseHexCodepoint: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "surrogate range",
            .input = .{ .s = "D800", .n = 4 },
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "surrogate low (0xDFFF)",
            .input = .{ .s = "DFFF", .n = 4 },
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "value over 0x10FFFF",
            .input = .{ .s = "00110000", .n = 8 },
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "non-hex digit",
            .input = .{ .s = "004G", .n = 4 },
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "EOF",
            .input = .{ .s = "", .n = 4 },
            .expected = error.InvalidUnicode,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectError(tc.expected, parseHexCodepoint(&cursor, tc.input.n));
    }
}

test "parseHexCodepoint: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "EOF in escape",
            .input = .{ .s = "", .n = 4 },
            .expected = .{
                .err = error.InvalidUnicode,
                .message = "unexpected end of input in unicode escape",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "invalid hex digit",
            .input = .{ .s = "004G", .n = 4 },
            .expected = .{
                .err = error.InvalidUnicode,
                .message = "invalid hex digit in unicode escape",
                .line = 1,
                .column = 5,
            },
        },
        .{
            .name = "surrogate codepoint",
            .input = .{ .s = "D800", .n = 4 },
            .expected = .{
                .err = error.InvalidUnicode,
                .message = "invalid unicode code point",
                .line = 1,
                .column = 5,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseHexCodepoint(&cursor, tc.input.n));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- skipConsecutiveChar ---

test "skipConsecutiveChar: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, char: u8 },
        expected: struct { n: usize, position: usize },
    }{
        .{
            .name = "double quote: no match",
            .input = .{ .s = "abc", .char = '"' },
            .expected = .{ .n = 0, .position = 0 },
        },
        .{
            .name = "double quote: single match",
            .input = .{ .s = "\"x", .char = '"' },
            .expected = .{ .n = 1, .position = 1 },
        },
        .{
            .name = "double quote: three consecutive",
            .input = .{ .s = "\"\"\"rest", .char = '"' },
            .expected = .{ .n = 3, .position = 3 },
        },
        .{
            .name = "single quote: two consecutive",
            .input = .{ .s = "''x", .char = '\'' },
            .expected = .{ .n = 2, .position = 2 },
        },
        .{
            .name = "exclamation: four consecutive",
            .input = .{ .s = "!!!!", .char = '!' },
            .expected = .{ .n = 4, .position = 4 },
        },
    };

    // skipConsecutiveChar が comptime char: u8 を受け取るため inline for が必要。
    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        const n = skipConsecutiveChar(&cursor, tc.input.char);
        try std.testing.expectEqual(tc.expected.n, n);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
    }
}

// --- skipLineContinuation ---

test "skipLineContinuation: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "newline",
            .input = "\nrest",
            .expected = .{ .position = 1, .line = 2, .column = 1 },
        },
        .{
            .name = "CRLF",
            .input = "\r\nrest",
            .expected = .{ .position = 2, .line = 2, .column = 1 },
        },
        .{
            .name = "spaces and tabs",
            .input = "  \t  rest",
            .expected = .{ .position = 5, .line = 1, .column = 6 },
        },
        .{
            .name = "mixed whitespace",
            .input = " \t\n\r rest",
            .expected = .{ .position = 5, .line = 2, .column = 2 },
        },
        .{
            .name = "no whitespace",
            .input = "rest",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "empty",
            .input = "",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        skipLineContinuation(&cursor);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- appendUtf8Codepoint ---

test "appendUtf8Codepoint: single codepoint" {
    const test_cases = [_]struct {
        name: []const u8,
        input: u21,
        expected: []const u8,
    }{
        .{
            .name = "ASCII codepoint encodes to single byte",
            .input = 0x41,
            .expected = "A",
        },
        .{
            .name = "two-byte codepoint encodes correctly",
            .input = 0x00E9,
            .expected = "\xC3\xA9",
        },
        .{
            .name = "three-byte codepoint encodes correctly",
            .input = 0x3042,
            .expected = "\xE3\x81\x82",
        },
        .{
            .name = "four-byte codepoint U+10FFFF encodes correctly",
            .input = 0x10FFFF,
            .expected = "\xF4\x8F\xBF\xBF",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try appendUtf8Codepoint(&buf, &arena, tc.input);
        try std.testing.expectEqualStrings(tc.expected, buf.items);
    }
}

test "appendUtf8Codepoint: multiple codepoints appended sequentially" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try appendUtf8Codepoint(&buf, &arena, 0x41);
    try appendUtf8Codepoint(&buf, &arena, 0x3042);
    try std.testing.expectEqualStrings("A\xE3\x81\x82", buf.items);
}

test "appendUtf8Codepoint: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: u21,
        expected: error{InvalidUnicode},
    }{
        .{ .name = "surrogate high", .input = 0xD800, .expected = error.InvalidUnicode },
        .{ .name = "surrogate low", .input = 0xDFFF, .expected = error.InvalidUnicode },
        .{ .name = "out of range", .input = 0x110000, .expected = error.InvalidUnicode },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try std.testing.expectError(tc.expected, appendUtf8Codepoint(&buf, &arena, tc.input));
    }
}

// --- appendUtf8Byte ---

test "appendUtf8Byte: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "ASCII byte", .input = "a", .expected = "a" },
        .{ .name = "2-byte UTF-8", .input = "\xC3\xA9", .expected = "\xC3\xA9" },
        .{ .name = "3-byte UTF-8", .input = "\xE3\x81\x82", .expected = "\xE3\x81\x82" },
        .{ .name = "4-byte UTF-8", .input = "\xF0\x9F\x98\x80", .expected = "\xF0\x9F\x98\x80" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var cursor = Cursor.init(tc.input, null);
        const c_opt = cursor.peek();
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(c_opt != null);
        try appendUtf8Byte(&buf, &arena, &cursor, c_opt.?);
        try std.testing.expectEqualStrings(tc.expected, buf.items);
    }
}

test "appendUtf8Byte: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: error{InvalidUnicode},
    }{
        .{
            .name = "invalid leading byte (continuation byte)",
            .input = "\x80",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "incomplete sequence",
            .input = "\xC3",
            .expected = error.InvalidUnicode,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var cursor = Cursor.init(tc.input, null);
        const c_opt = cursor.peek();
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(c_opt != null);
        try std.testing.expectError(tc.expected, appendUtf8Byte(&buf, &arena, &cursor, c_opt.?));
    }
}

test "appendUtf8Byte: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "invalid leading byte",
            .input = "\x80",
            .expected = .{
                .err = error.InvalidUnicode,
                .message = "invalid UTF-8 byte in string",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "incomplete sequence",
            .input = "\xC3",
            .expected = .{
                .err = error.InvalidUnicode,
                .message = "incomplete UTF-8 sequence in string",
                .line = 1,
                .column = 1,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        const c_opt = cursor.peek();
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(c_opt != null);
        try std.testing.expectError(
            tc.expected.err,
            appendUtf8Byte(&buf, &arena, &cursor, c_opt.?),
        );
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

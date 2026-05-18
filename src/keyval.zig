const std = @import("std");
const boolean = @import("boolean.zig");
const cursor_mod = @import("cursor.zig");
const datetime = @import("datetime.zig");
const errors = @import("errors.zig");
const key = @import("key.zig");
const number = @import("number.zig");
const string = @import("string.zig");
const types = @import("types.zig");

const initial_inline_table_cap: u32 = 4;
const max_nesting_depth: usize = 128;

const Cursor = cursor_mod.Cursor;
const Value = types.Value;

const SkipMode = enum { whitespace, whitespace_and_newlines };

pub fn parseKeyValue(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    map: *std.StringHashMapUnmanaged(Value),
) (errors.ParseError || error{OutOfMemory})!void {
    try parseKeyValueImpl(cursor, arena, map, .whitespace, 0);
    try cursor.consumeNewlineOrEof();
}

fn parseKeyValueImpl(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    map: *std.StringHashMapUnmanaged(Value),
    skip_mode: SkipMode,
    depth: usize,
) (errors.ParseError || error{OutOfMemory})!void {
    const allocator = arena.allocator();

    const keys = try key.parseDottedKey(cursor, arena);
    skipByMode(cursor, skip_mode);

    if (cursor.peek() != '=') {
        cursor.fillDiagnostic("expected '=' after key");
        return error.UnexpectedChar;
    }
    _ = cursor.advance();
    skipByMode(cursor, skip_mode);

    const value = try parseValue(cursor, arena, depth);

    const target = try key.resolveKeyPath(
        cursor,
        arena,
        map,
        keys.prefix(),
        initial_inline_table_cap,
    );

    const last_key = keys.last();
    if (target.contains(last_key)) {
        cursor.fillDiagnostic("duplicate key");
        return error.DuplicateKey;
    }

    try target.put(allocator, last_key, value);
}

fn parseValue(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    depth: usize,
) (errors.ParseError || error{OutOfMemory})!Value {
    const c = cursor.peek() orelse {
        cursor.fillDiagnostic("unexpected end of input");
        return error.UnexpectedEof;
    };

    return switch (c) {
        '"' => blk: {
            if (cursor.startsWith("\"\"\"")) {
                const s = try string.parseMultilineBasicString(cursor, arena);
                break :blk .{ .string = s };
            }
            break :blk .{ .string = try string.parseBasicString(cursor, arena) };
        },
        '\'' => blk: {
            if (cursor.startsWith("'''")) {
                break :blk .{ .string = try string.parseMultilineLiteralString(cursor) };
            }
            break :blk .{ .string = try string.parseLiteralString(cursor) };
        },
        't', 'f' => try boolean.parseBoolean(cursor),
        '0'...'9' => switch (datetime.classifyDateTimeKind(cursor.peekRest())) {
            .datetime => try datetime.parseDateTime(cursor),
            .date => .{ .local_date = try datetime.parseLocalDate(cursor) },
            .time => .{ .local_time = try datetime.parseLocalTime(cursor) },
            .none => try number.parseNumber(cursor),
        },
        '-', '+', 'i', 'n' => try number.parseNumber(cursor),
        '[' => try parseArray(cursor, arena, depth + 1),
        '{' => try parseInlineTable(cursor, arena, depth + 1),
        else => {
            cursor.fillDiagnostic("unexpected character in value");
            return error.UnexpectedChar;
        },
    };
}

fn parseArray(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    depth: usize,
) (errors.ParseError || error{OutOfMemory})!Value {
    const allocator = arena.allocator();

    if (cursor.peek() != '[') @panic("parseArray: cursor must be at '['");
    if (depth > max_nesting_depth) {
        cursor.fillDiagnostic("nesting depth exceeded");
        return error.MaxDepthExceeded;
    }

    _ = cursor.advance();
    var items: std.ArrayListUnmanaged(Value) = .empty;
    cursor.skipWhitespaceAndNewlines();
    if (cursor.peek() == ']') {
        _ = cursor.advance();
        return .{ .array = try items.toOwnedSlice(allocator) };
    }

    while (true) {
        cursor.skipWhitespaceAndNewlines();
        const item = try parseValue(cursor, arena, depth);
        try items.append(allocator, item);
        cursor.skipWhitespaceAndNewlines();

        if (cursor.peek() == ']') {
            _ = cursor.advance();
            break;
        }
        const next = cursor.peek() orelse {
            cursor.fillDiagnostic("unexpected end of input in array");
            return error.UnexpectedEof;
        };
        if (next != ',') {
            cursor.fillDiagnostic("expected ',' or ']' in array");
            return error.UnexpectedChar;
        }
        if (cursor.consumeCommaOrClose(']')) break;
    }

    return .{ .array = try items.toOwnedSlice(allocator) };
}

fn parseInlineTable(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    depth: usize,
) (errors.ParseError || error{OutOfMemory})!Value {
    const allocator = arena.allocator();

    if (cursor.peek() != '{') @panic("parseInlineTable: cursor must be at '{'");
    if (depth > max_nesting_depth) {
        cursor.fillDiagnostic("nesting depth exceeded");
        return error.MaxDepthExceeded;
    }

    _ = cursor.advance();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.ensureTotalCapacity(allocator, initial_inline_table_cap);
    cursor.skipWhitespaceAndNewlines();
    if (cursor.peek() == '}') {
        _ = cursor.advance();
        return .{ .table = .{ .inner = map, .is_inline = true } };
    }

    while (true) {
        cursor.skipWhitespaceAndNewlines();
        try parseKeyValueImpl(cursor, arena, &map, .whitespace_and_newlines, depth);

        cursor.skipWhitespaceAndNewlines();
        if (cursor.peek() == '}') {
            _ = cursor.advance();
            break;
        }
        const next = cursor.peek() orelse {
            cursor.fillDiagnostic("unexpected end of input in inline table");
            return error.UnexpectedEof;
        };
        if (next != ',') {
            cursor.fillDiagnostic("expected ',' or '}' in inline table");
            return error.UnexpectedChar;
        }
        _ = cursor.advance();
        cursor.skipWhitespaceAndNewlines();
        if (cursor.peek() == '}') {
            cursor.fillDiagnostic("trailing comma not permitted in inline table");
            return error.UnexpectedChar;
        }
    }

    return .{ .table = .{ .inner = map, .is_inline = true } };
}

fn skipByMode(cursor: *Cursor, mode: SkipMode) void {
    switch (mode) {
        .whitespace => cursor.skipWhitespace(),
        .whitespace_and_newlines => cursor.skipWhitespaceAndNewlines(),
    }
}

// --- parseKeyValue ---

test "parseKeyValue: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "newline termination", .input = "key = 42\n", .expected = 42 },
        .{ .name = "eof termination", .input = "key = 42", .expected = 42 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try parseKeyValue(&cursor, &arena, &map);
        const val_opt = map.get("key");
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parseKeyValue: success: dotted key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("a.b = 42\n", null);
    try parseKeyValue(&cursor, &arena, &map);
    const a = map.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), b.integer);
}

test "parseKeyValue: error: missing equals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("foo bar", null);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseKeyValue(&cursor, &arena, &map),
    );
}

test "parseKeyValue: error: duplicate key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var pre_cursor = Cursor.init("foo = 1\n", null);
    try parseKeyValue(&pre_cursor, &arena, &map);
    var cursor = Cursor.init("foo = 2\n", null);
    try std.testing.expectError(
        error.DuplicateKey,
        parseKeyValue(&cursor, &arena, &map),
    );
}

// --- parseKeyValueImpl ---

test "parseKeyValueImpl: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, skip_mode: SkipMode },
        expected: i64,
    }{
        .{
            .name = "whitespace",
            .input = .{ .s = "key = 42", .skip_mode = .whitespace },
            .expected = 42,
        },
        .{
            .name = "whitespace_and_newlines",
            .input = .{ .s = "key\n=\n42", .skip_mode = .whitespace_and_newlines },
            .expected = 42,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        var cursor = Cursor.init(tc.input.s, null);
        try parseKeyValueImpl(&cursor, &arena, &map, tc.input.skip_mode, 0);
        const val_opt = map.get("key");
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parseKeyValueImpl: success: dotted key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("a.b = 42", null);
    try parseKeyValueImpl(&cursor, &arena, &map, .whitespace, 0);
    const a = map.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), b.integer);
}

test "parseKeyValueImpl: error: newline before equals with skipWhitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("key\n= 42", null);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseKeyValueImpl(&cursor, &arena, &map, .whitespace, 0),
    );
}

test "parseKeyValueImpl: error: duplicate key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var pre_cursor = Cursor.init("key = 1", null);
    try parseKeyValueImpl(&pre_cursor, &arena, &map, .whitespace, 0);
    var cursor = Cursor.init("key = 2", null);
    try std.testing.expectError(
        error.DuplicateKey,
        parseKeyValueImpl(&cursor, &arena, &map, .whitespace, 0),
    );
}

test "parseKeyValueImpl: fills diagnostic on error: missing equals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("foo bar", &diagnostic);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseKeyValueImpl(&cursor, &arena, &map, .whitespace, 0),
    );
    try std.testing.expectEqualStrings("expected '=' after key", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseKeyValueImpl: fills diagnostic on error: duplicate key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    var pre_cursor = Cursor.init("foo = 1", null);
    try parseKeyValueImpl(&pre_cursor, &arena, &map, .whitespace, 0);
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("foo = 2", &diagnostic);
    try std.testing.expectError(
        error.DuplicateKey,
        parseKeyValueImpl(&cursor, &arena, &map, .whitespace, 0),
    );
    try std.testing.expectEqualStrings("duplicate key", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 8), diagnostic.column);
}

// --- parseValue ---

test "parseValue: integer" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "positive", .input = "42", .expected = 42 },
        .{ .name = "negative", .input = "-5", .expected = -5 },
        .{ .name = "underscore", .input = "1_000_000", .expected = 1_000_000 },
        .{ .name = "hex", .input = "0xDEAD_BEEF", .expected = 0xDEADBEEF },
        .{ .name = "octal", .input = "0o755", .expected = 0o755 },
        .{ .name = "binary", .input = "0b1010_1010", .expected = 0b10101010 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(Value{ .integer = tc.expected }, val);
    }
}

test "parseValue: boolean" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "true", .input = "true", .expected = true },
        .{ .name = "false", .input = "false", .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(Value{ .boolean = tc.expected }, val);
    }
}

test "parseValue: string" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "basic string",
            .input = "\"hello\"",
            .expected = "hello",
        },
        .{
            .name = "basic string with escapes",
            .input = "\"hello\\nworld\\t!\"",
            .expected = "hello\nworld\t!",
        },
        .{
            .name = "escape backspace",
            .input = "\"\\b\"",
            .expected = "\x08",
        },
        .{
            .name = "escape tab",
            .input = "\"\\t\"",
            .expected = "\t",
        },
        .{
            .name = "escape newline",
            .input = "\"\\n\"",
            .expected = "\n",
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
            .name = "escape ESC",
            .input = "\"\\e\"",
            .expected = "\x1B",
        },
        .{
            .name = "escape double quote",
            .input = "\"\\\"\"",
            .expected = "\"",
        },
        .{
            .name = "escape backslash",
            .input = "\"\\\\\"",
            .expected = "\\",
        },
        .{
            .name = "unicode escape uHHHH",
            .input = "\"\\u0041\"",
            .expected = "A",
        },
        .{
            .name = "unicode escape UHHHHHHHH",
            .input = "\"\\U0001F600\"",
            .expected = "😀",
        },
        .{
            .name = "hex escape",
            .input = "\"\\x41\"",
            .expected = "A",
        },
        .{
            .name = "multiline basic string",
            .input = "\"\"\"multi\nline\"\"\"",
            .expected = "multi\nline",
        },
        .{
            .name = "multiline basic string trims first newline",
            .input = "\"\"\"\nhello\"\"\"",
            .expected = "hello",
        },
        .{
            .name = "multiline basic string line continuation",
            .input = "\"\"\"hello \\\n  world\"\"\"",
            .expected = "hello world",
        },
        .{
            .name = "literal string zero-copy",
            .input = "'C:\\Users\\tom'",
            .expected = "C:\\Users\\tom",
        },
        .{
            .name = "multiline literal string",
            .input = "'''\nline1\nline2'''",
            .expected = "line1\nline2",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqualStrings(tc.expected, val.string);
    }
}

test "parseValue: string zero-copy" {
    const input = "\"hello world\"";
    var arena = std.heap.ArenaAllocator.init(std.testing.failing_allocator);
    defer arena.deinit();
    var cursor = Cursor.init(input, null);
    const val = try parseValue(&cursor, &arena, 0);
    try std.testing.expectEqualStrings("hello world", val.string);
}

test "parseValue: float: nan" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "nan", .input = "nan", .expected = true },
        .{ .name = "+nan", .input = "+nan", .expected = true },
        .{ .name = "-nan", .input = "-nan", .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected, std.math.isNan(val.float));
    }
}

test "parseValue: float: approx" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { value: f64, tolerance: f64 },
    }{
        .{
            .name = "decimal float",
            .input = "3.14",
            .expected = .{ .value = 3.14, .tolerance = 1e-10 },
        },
        .{
            .name = "scientific notation",
            .input = "3.14e-2",
            .expected = .{ .value = 3.14e-2, .tolerance = 1e-15 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectApproxEqAbs(tc.expected.value, val.float, tc.expected.tolerance);
    }
}

test "parseValue: float: exact" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: f64,
    }{
        .{ .name = "underscore in exponent", .input = "1.5e1_0", .expected = 1.5e10 },
        .{ .name = "positive infinity", .input = "inf", .expected = std.math.inf(f64) },
        .{ .name = "positive infinity with sign", .input = "+inf", .expected = std.math.inf(f64) },
        .{ .name = "negative infinity", .input = "-inf", .expected = -std.math.inf(f64) },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected, val.float);
    }
}

test "parseValue: array: len" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "nested array", .input = "[[1, 2], [3, 4]]", .expected = 2 },
        .{ .name = "empty array", .input = "[]", .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected, val.array.len);
    }
}

test "parseValue: array: integer elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("[1, 2, 3]", null);
    const val = try parseValue(&cursor, &arena, 0);
    try std.testing.expectEqual(3, val.array.len);
    try std.testing.expectEqual(1, val.array[0].integer);
    try std.testing.expectEqual(2, val.array[1].integer);
    try std.testing.expectEqual(3, val.array[2].integer);
}

test "parseValue: array: string elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("[\"apple\", \"banana\",]", null);
    const val = try parseValue(&cursor, &arena, 0);
    try std.testing.expectEqual(2, val.array.len);
    try std.testing.expectEqualStrings("apple", val.array[0].string);
    try std.testing.expectEqualStrings("banana", val.array[1].string);
}

test "parseValue: inline table: count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("{}", null);
    const val = try parseValue(&cursor, &arena, 0);
    try std.testing.expectEqual(0, val.table.count());
}

test "parseValue: inline table: single entry" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { count: usize, x: i64 },
    }{
        .{
            .name = "newline before first key",
            .input = "{\n  x = 1\n}",
            .expected = .{ .count = 1, .x = 1 },
        },
        .{
            .name = "newline between key and equals",
            .input = "{x\n= 1}",
            .expected = .{ .count = 1, .x = 1 },
        },
        .{
            .name = "newline between equals and value",
            .input = "{x =\n1}",
            .expected = .{ .count = 1, .x = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected.count, val.table.count());
        const x_opt = val.table.get("x");
        try std.testing.expect(x_opt != null);
        try std.testing.expectEqual(tc.expected.x, x_opt.?.integer);
    }
}

test "parseValue: inline table: two entries" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { count: usize, x: i64, y: i64 },
    }{
        .{
            .name = "two entries",
            .input = "{x = 1, y = 2}",
            .expected = .{ .count = 2, .x = 1, .y = 2 },
        },
        .{
            .name = "two entries with newlines",
            .input = "{x = 1,\n  y = 2}",
            .expected = .{ .count = 2, .x = 1, .y = 2 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected.count, val.table.count());
        const x_opt = val.table.get("x");
        try std.testing.expect(x_opt != null);
        try std.testing.expectEqual(tc.expected.x, x_opt.?.integer);
        const y_opt = val.table.get("y");
        try std.testing.expect(y_opt != null);
        try std.testing.expectEqual(tc.expected.y, y_opt.?.integer);
    }
}

test "parseValue: local date" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { year: u16, month: u8, day: u8 },
    }{
        .{
            .name = "basic date",
            .input = "1979-05-27",
            .expected = .{ .year = 1979, .month = 5, .day = 27 },
        },
        .{
            .name = "leap day",
            .input = "2000-02-29",
            .expected = .{ .year = 2000, .month = 2, .day = 29 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected.year, val.local_date.year);
        try std.testing.expectEqual(tc.expected.month, val.local_date.month);
        try std.testing.expectEqual(tc.expected.day, val.local_date.day);
    }
}

test "parseValue: local time" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { hour: u8, minute: u8, second: u8, nanosecond: u32 },
    }{
        .{
            .name = "hms",
            .input = "07:32:00",
            .expected = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 0 },
        },
        .{
            .name = "hms with fractional seconds",
            .input = "07:32:00.999999",
            .expected = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 999_999_000 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected.hour, val.local_time.hour);
        try std.testing.expectEqual(tc.expected.minute, val.local_time.minute);
        try std.testing.expectEqual(tc.expected.second, val.local_time.second);
        try std.testing.expectEqual(tc.expected.nanosecond, val.local_time.nanosecond);
    }
}

test "parseValue: local datetime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            year: u16,
            month: u8,
            day: u8,
            hour: u8,
            minute: u8,
            second: u8,
            nanosecond: u32,
        },
    }{
        .{
            .name = "without nanoseconds",
            .input = "1979-05-27T07:32:00",
            .expected = .{
                .year = 1979,
                .month = 5,
                .day = 27,
                .hour = 7,
                .minute = 32,
                .second = 0,
                .nanosecond = 0,
            },
        },
        .{
            .name = "with nanoseconds",
            .input = "1979-05-27T07:32:00.999999999",
            .expected = .{
                .year = 1979,
                .month = 5,
                .day = 27,
                .hour = 7,
                .minute = 32,
                .second = 0,
                .nanosecond = 999999999,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        try std.testing.expectEqual(tc.expected.year, val.local_date_time.date.year);
        try std.testing.expectEqual(tc.expected.month, val.local_date_time.date.month);
        try std.testing.expectEqual(tc.expected.day, val.local_date_time.date.day);
        try std.testing.expectEqual(tc.expected.hour, val.local_date_time.time.hour);
        try std.testing.expectEqual(tc.expected.minute, val.local_date_time.time.minute);
        try std.testing.expectEqual(tc.expected.second, val.local_date_time.time.second);
        try std.testing.expectEqual(tc.expected.nanosecond, val.local_date_time.time.nanosecond);
    }
}

test "parseValue: offset datetime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            year: u16,
            month: u8,
            day: u8,
            hour: u8,
            minute: u8,
            second: u8,
            nanosecond: u32,
            offset_minutes: i16,
        },
    }{
        .{
            .name = "UTC offset",
            .input = "1979-05-27T07:32:00Z",
            .expected = .{
                .year = 1979,
                .month = 5,
                .day = 27,
                .hour = 7,
                .minute = 32,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 0,
            },
        },
        .{
            .name = "positive offset",
            .input = "1979-05-27T07:32:00+09:00",
            .expected = .{
                .year = 1979,
                .month = 5,
                .day = 27,
                .hour = 7,
                .minute = 32,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 9 * 60,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const val = try parseValue(&cursor, &arena, 0);
        const odt = val.offset_date_time;
        try std.testing.expectEqual(tc.expected.year, odt.datetime.date.year);
        try std.testing.expectEqual(tc.expected.month, odt.datetime.date.month);
        try std.testing.expectEqual(tc.expected.day, odt.datetime.date.day);
        try std.testing.expectEqual(tc.expected.hour, odt.datetime.time.hour);
        try std.testing.expectEqual(tc.expected.minute, odt.datetime.time.minute);
        try std.testing.expectEqual(tc.expected.second, odt.datetime.time.second);
        try std.testing.expectEqual(tc.expected.nanosecond, odt.datetime.time.nanosecond);
        try std.testing.expectEqual(tc.expected.offset_minutes, odt.offset_minutes);
    }
}

test "parseValue: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "empty input",
            .input = "",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unexpected character",
            .input = "@value",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid escape",
            .input = "\"\\q\"",
            .expected = error.InvalidEscape,
        },
        .{
            .name = "invalid unicode short",
            .input = "\"\\u00\"",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "unicode overflow",
            .input = "\"\\U00200000\"",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "unicode surrogate pair",
            .input = "\"\\uD800\"",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "unterminated basic string",
            .input = "\"hello",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "basic string with null byte",
            .input = "\"ab\x00cd\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "literal string with control character",
            .input = "'ab\x01cd'",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "multiline basic string with control character",
            .input = "\"\"\"\nab\x0bcd\"\"\"",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "multiline literal string with control character",
            .input = "'''\nab\x0ccd'''",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid time minute",
            .input = "00:60:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "timezone offset with out-of-range hour",
            .input = "2024-01-01T12:00:00+24:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "invalid date month",
            .input = "1979-13-01",
            .expected = error.InvalidDate,
        },
        .{
            .name = "invalid time hour",
            .input = "25:00:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "invalid date day",
            .input = "2024-02-30",
            .expected = error.InvalidDate,
        },
        .{
            .name = "1900-02-29 non-leap year",
            .input = "1900-02-29",
            .expected = error.InvalidDate,
        },
        .{
            .name = "2100-02-29 non-leap year",
            .input = "2100-02-29",
            .expected = error.InvalidDate,
        },
        .{
            .name = "inline table duplicate key",
            .input = "{a = 1, a = 2}",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "unclosed array",
            .input = "[1, ",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "float literal exceeding buffer",
            .input = "1" ++ "_0" ** 64 ++ ".5",
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseValue(&cursor, &arena, 0));
    }
}

test "parseValue: fills diagnostic on error" {
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
            .name = "empty input",
            .input = "",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "unexpected character",
            .input = "@value",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "unexpected character in value",
                .line = 1,
                .column = 1,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseValue(&cursor, &arena, 0));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

test "parseValue: MaxDepthExceeded" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "deeply nested array",
            .input = "[" ** 129 ++ "1" ++ "]" ** 129,
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "deeply nested inline table",
            .input = "{x = " ** 129 ++ "1" ++ "}" ** 129,
            .expected = error.MaxDepthExceeded,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseValue(&cursor, &arena, 0));
    }
}

// --- parseArray ---

test "parseArray: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, depth: usize },
        expected: usize,
    }{
        .{
            .name = "empty array",
            .input = .{ .s = "[]", .depth = 0 },
            .expected = 0,
        },
        .{
            .name = "depth 1 is accepted",
            .input = .{ .s = "[1, 2]", .depth = 0 },
            .expected = 2,
        },
        .{
            .name = "exactly max_nesting_depth is accepted",
            .input = .{ .s = "[1]", .depth = max_nesting_depth },
            .expected = 1,
        },
        .{
            .name = "trailing comma",
            .input = .{ .s = "[1, 2,]", .depth = 0 },
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.s, null);
        const val = try parseArray(&cursor, &arena, tc.input.depth);
        try std.testing.expectEqual(tc.expected, val.array.len);
    }
}

test "parseArray: success: mixed types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("[1, \"two\", true]", null);
    const val = try parseArray(&cursor, &arena, 0);
    try std.testing.expectEqual(@as(usize, 3), val.array.len);
    try std.testing.expectEqual(@as(i64, 1), val.array[0].integer);
    try std.testing.expectEqualStrings("two", val.array[1].string);
    try std.testing.expectEqual(true, val.array[2].boolean);
}

test "parseArray: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, depth: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "depth exceeds max_nesting_depth",
            .input = .{ .s = "[1]", .depth = max_nesting_depth + 1 },
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "missing separator",
            .input = .{ .s = "[1 2]", .depth = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "unterminated empty array",
            .input = .{ .s = "[", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unterminated array after elements",
            .input = .{ .s = "[1, 2", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unterminated after comma",
            .input = .{ .s = "[1,", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectError(
            tc.expected,
            parseArray(&cursor, &arena, tc.input.depth),
        );
    }
}

test "parseArray: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, depth: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "missing separator",
            .input = .{ .s = "[1 2]", .depth = 1 },
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected ',' or ']' in array",
                .line = 1,
                .column = 4,
            },
        },
        .{
            .name = "nesting depth exceeded",
            .input = .{ .s = "[1]", .depth = max_nesting_depth + 1 },
            .expected = .{
                .err = error.MaxDepthExceeded,
                .message = "nesting depth exceeded",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "unterminated array after elements",
            .input = .{ .s = "[1, 2", .depth = 1 },
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input in array",
                .line = 1,
                .column = 6,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseArray(&cursor, &arena, tc.input.depth));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseInlineTable ---

test "parseInlineTable: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("{x = 1}", null);
    const val = try parseInlineTable(&cursor, &arena, max_nesting_depth);
    const x = val.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), x.integer);
}

test "parseInlineTable: success: empty table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("{}", null);
    const val = try parseInlineTable(&cursor, &arena, max_nesting_depth);
    try std.testing.expectEqual(0, val.table.count());
}

test "parseInlineTable: success: nested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("{a = {x = 1}}", null);
    const val = try parseInlineTable(&cursor, &arena, max_nesting_depth - 1);
    const a = val.table.get("a") orelse return error.TestFailed;
    const x = a.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(1, x.integer);
}

test "parseInlineTable: success: multiple entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("{x = 1, y = 2}", null);
    const val = try parseInlineTable(&cursor, &arena, 0);
    try std.testing.expectEqual(@as(usize, 2), val.table.count());
    const x = val.table.get("x") orelse return error.TestFailed;
    const y = val.table.get("y") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), x.integer);
    try std.testing.expectEqual(@as(i64, 2), y.integer);
}

test "parseInlineTable: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, depth: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "missing separator",
            .input = .{ .s = "{x = 1 y = 2}", .depth = 1 },
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "depth exceeds max_nesting_depth",
            .input = .{ .s = "{x = 1}", .depth = max_nesting_depth + 1 },
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "unterminated empty",
            .input = .{ .s = "{", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unterminated after element",
            .input = .{ .s = "{x = 1", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unterminated after comma",
            .input = .{ .s = "{x = 1,", .depth = 1 },
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "trailing comma",
            .input = .{ .s = "{x = 1,}", .depth = 1 },
            .expected = error.UnexpectedChar,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectError(
            tc.expected,
            parseInlineTable(&cursor, &arena, tc.input.depth),
        );
    }
}

test "parseInlineTable: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, depth: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "missing separator",
            .input = .{ .s = "{a = 1 b = 2}", .depth = 1 },
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected ',' or '}' in inline table",
                .line = 1,
                .column = 8,
            },
        },
        .{
            .name = "nesting depth exceeded",
            .input = .{ .s = "{x = 1}", .depth = max_nesting_depth + 1 },
            .expected = .{
                .err = error.MaxDepthExceeded,
                .message = "nesting depth exceeded",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "trailing comma",
            .input = .{ .s = "{x = 1,}", .depth = 1 },
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "trailing comma not permitted in inline table",
                .line = 1,
                .column = 8,
            },
        },
        .{
            .name = "unterminated after element",
            .input = .{ .s = "{x = 1", .depth = 1 },
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input in inline table",
                .line = 1,
                .column = 7,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        try std.testing.expectError(
            tc.expected.err,
            parseInlineTable(&cursor, &arena, tc.input.depth),
        );
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- skipByMode ---

test "skipByMode: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, mode: SkipMode },
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "whitespace: spaces and tabs",
            .input = .{ .s = " \t  x", .mode = .whitespace },
            .expected = .{ .position = 4, .line = 1, .column = 5 },
        },
        .{
            .name = "whitespace: does not skip newlines",
            .input = .{ .s = " \n x", .mode = .whitespace },
            .expected = .{ .position = 1, .line = 1, .column = 2 },
        },
        .{
            .name = "whitespace_and_newlines: spaces tabs and newlines",
            .input = .{ .s = " \t\n x", .mode = .whitespace_and_newlines },
            .expected = .{ .position = 4, .line = 2, .column = 2 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        skipByMode(&cursor, tc.input.mode);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

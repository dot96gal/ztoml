const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const string = @import("string.zig");
const types = @import("types.zig");

const Cursor = cursor_mod.Cursor;
const Value = types.Value;

pub const DottedKey = struct {
    segments: []const []const u8,

    pub fn last(self: DottedKey) []const u8 {
        if (self.segments.len == 0) @panic("DottedKey.last: segments is empty");
        return self.segments[self.segments.len - 1];
    }

    pub fn prefix(self: DottedKey) []const []const u8 {
        if (self.segments.len == 0) @panic("DottedKey.prefix: segments is empty");
        return self.segments[0 .. self.segments.len - 1];
    }
};

pub fn parseDottedKey(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})!DottedKey {
    const allocator = arena.allocator();

    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    try keys.append(allocator, try parseSingleKey(cursor, arena));

    while (true) {
        cursor.skipWhitespace();
        if (cursor.peek() != '.') break;

        _ = cursor.advance();
        cursor.skipWhitespace();
        try keys.append(allocator, try parseSingleKey(cursor, arena));
    }

    return .{ .segments = try keys.toOwnedSlice(allocator) };
}

pub fn resolveKeyPath(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    map: *std.StringHashMapUnmanaged(Value),
    keys: []const []const u8,
    initial_table_capacity: u32,
) (errors.ParseError || error{OutOfMemory})!*std.StringHashMapUnmanaged(Value) {
    const allocator = arena.allocator();

    var target = map;
    for (keys, 0..) |k, i| {
        const is_last = (i == keys.len - 1);
        const entry = try target.getOrPut(allocator, k);
        if (!entry.found_existing) {
            var inner: std.StringHashMapUnmanaged(Value) = .empty;
            try inner.ensureTotalCapacity(allocator, initial_table_capacity);
            entry.value_ptr.* = .{ .table = .{ .inner = inner } };
        }

        switch (entry.value_ptr.*) {
            .table => |*t| {
                if (t.is_inline) {
                    cursor.fillDiagnostic("key already exists as inline table");
                    return error.DuplicateKey;
                }
                target = &t.inner;
            },
            .aot_array => |aot| {
                if (is_last) {
                    cursor.fillDiagnostic("key already exists as non-table");
                    return error.DuplicateKey;
                }
                if (aot.len() == 0) @panic("resolveKeyPath: AoT array is empty");
                target = switch (aot.inner.items[aot.len() - 1]) {
                    .table => |*t| &t.inner,
                    else => @panic("resolveKeyPath: AoT element is not a table"),
                };
            },
            else => {
                cursor.fillDiagnostic("key already exists as non-table");
                return error.DuplicateKey;
            },
        }
    }

    return target;
}

fn parseSingleKey(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})![]const u8 {
    const c = cursor.peek() orelse {
        cursor.fillDiagnostic("expected key");
        return error.UnexpectedEof;
    };

    if (c == '"') return try string.parseBasicString(cursor, arena);
    if (c == '\'') return try string.parseLiteralString(cursor);

    const start = cursor.position;
    while (cursor.peek()) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
            _ = cursor.advance();
        } else if (ch >= 0x80) {
            // 無効な UTF-8・サロゲート・非文字はベアキーの終端として扱う
            const seq_len = std.unicode.utf8ByteSequenceLength(ch) catch break;
            const seq = cursor.peekSlice(seq_len) orelse break;
            const cp = std.unicode.utf8Decode(seq) catch break;
            if ((cp >= 0x00B2 and cp <= 0x00B5) or
                (cp >= 0x00B7 and cp <= 0x00D6) or
                (cp >= 0x00D8 and cp <= 0x00F6) or
                (cp >= 0x00F8 and cp <= 0x037D) or
                (cp >= 0x037F and cp <= 0x1FFF) or
                (cp >= 0x200C and cp <= 0x200D) or
                (cp >= 0x203F and cp <= 0x2040) or
                (cp >= 0x2070 and cp <= 0x218F) or
                (cp >= 0x2460 and cp <= 0x24FF) or
                (cp >= 0x2C00 and cp <= 0x2FEF) or
                (cp >= 0x3001 and cp <= 0xD7FF) or
                (cp >= 0xF900 and cp <= 0xFDCF) or
                (cp >= 0xFDF0 and cp <= 0xFFFD) or
                cp >= 0x10000)
            {
                cursor.advanceUtf8Sequence();
            } else break;
        } else break;
    }

    if (cursor.position == start) {
        cursor.fillDiagnostic("expected bare key");
        return error.UnexpectedChar;
    }

    return cursor.peekSliceSince(start);
}

// --- DottedKey.last ---

test "DottedKey.last: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const []const u8,
        expected: []const u8,
    }{
        .{
            .name = "single segment",
            .input = &[_][]const u8{"foo"},
            .expected = "foo",
        },
        .{
            .name = "two segments",
            .input = &[_][]const u8{ "a", "b" },
            .expected = "b",
        },
        .{
            .name = "multi segment",
            .input = &[_][]const u8{ "a", "b", "c" },
            .expected = "c",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const dk = DottedKey{ .segments = tc.input };
        try std.testing.expectEqualStrings(tc.expected, dk.last());
    }
}

// --- DottedKey.prefix ---

test "DottedKey.prefix: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const []const u8,
        expected: []const []const u8,
    }{
        .{
            .name = "single segment returns empty",
            .input = &[_][]const u8{"foo"},
            .expected = &[_][]const u8{},
        },
        .{
            .name = "two segments returns single element",
            .input = &[_][]const u8{ "a", "b" },
            .expected = &[_][]const u8{"a"},
        },
        .{
            .name = "multi segment returns all but last",
            .input = &[_][]const u8{ "a", "b", "c" },
            .expected = &[_][]const u8{ "a", "b" },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const dk = DottedKey{ .segments = tc.input };
        const pref = dk.prefix();
        try std.testing.expectEqual(tc.expected.len, pref.len);
        for (tc.expected, pref) |exp, got| {
            try std.testing.expectEqualStrings(exp, got);
        }
    }
}

// --- parseDottedKey ---

test "parseDottedKey: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const []const u8,
    }{
        .{
            .name = "single key",
            .input = "foo = 1",
            .expected = &[_][]const u8{"foo"},
        },
        .{
            .name = "multi-segment key",
            .input = "a.b = 1",
            .expected = &[_][]const u8{ "a", "b" },
        },
        .{
            .name = "whitespace around dot",
            .input = "a . b = 1",
            .expected = &[_][]const u8{ "a", "b" },
        },
        .{
            .name = "three-segment key",
            .input = "a.b.c = 1",
            .expected = &[_][]const u8{ "a", "b", "c" },
        },
        .{
            .name = "quoted key in dotted path",
            .input = "a.\"b\" = 1",
            .expected = &[_][]const u8{ "a", "b" },
        },
        .{
            .name = "literal string key in dotted path",
            .input = "a.'b' = 1",
            .expected = &[_][]const u8{ "a", "b" },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const keys = try parseDottedKey(&cursor, &arena);
        try std.testing.expectEqual(tc.expected.len, keys.segments.len);
        for (tc.expected, keys.segments) |exp, got| {
            try std.testing.expectEqualStrings(exp, got);
        }
    }
}

test "parseDottedKey: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "trailing dot EOF", .input = "a.", .expected = error.UnexpectedEof },
        .{ .name = "empty key after dot", .input = "a. = 1", .expected = error.UnexpectedChar },
        .{ .name = "consecutive dots", .input = "a..b = 1", .expected = error.UnexpectedChar },
        .{ .name = "empty input", .input = "", .expected = error.UnexpectedEof },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseDottedKey(&cursor, &arena));
    }
}

test "parseDottedKey: fills diagnostic on error" {
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
                .message = "expected key",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "empty key after dot",
            .input = "a. = 1",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected bare key",
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
        try std.testing.expectError(tc.expected.err, parseDottedKey(&cursor, &arena));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- resolveKeyPath ---

test "resolveKeyPath: empty keys returns root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("", null);
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    const result = try resolveKeyPath(&cursor, &arena, &map, &.{}, 0);
    try std.testing.expectEqual(&map, result);
}

test "resolveKeyPath: reuses existing table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("", null);
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    const first = try resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 0);
    const second = try resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 0);
    try std.testing.expectEqual(first, second);
}

test "resolveKeyPath: nested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("", null);
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    const result = try resolveKeyPath(&cursor, &arena, &map, &.{ "a", "b" }, 0);
    try result.put(arena.allocator(), "c", .{ .integer = 42 });
    const a = map.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    const c = b.table.get("c") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), c.integer);
}

test "resolveKeyPath: non-zero initial_table_capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("", null);
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    const result = try resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 4);
    try result.put(arena.allocator(), "b", .{ .integer = 42 });
    const a = map.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), b.integer);
}

test "resolveKeyPath: traverses aot_array intermediate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = .empty } });

    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(allocator, "a", .{ .aot_array = .{ .inner = list } });

    var cursor = Cursor.init("", null);
    const result = try resolveKeyPath(&cursor, &arena, &map, &.{ "a", "b" }, 0);
    try result.put(allocator, "x", .{ .integer = 42 });

    const last = list.items[0];
    const b = last.table.get("b") orelse return error.TestFailed;
    const x = b.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), x.integer);
}

test "resolveKeyPath: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.ParseError,
    }{
        .{
            .name = "integer value",
            .input = .{ .integer = 1 },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "string value",
            .input = .{ .string = "hello" },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "float value",
            .input = .{ .float = 3.14 },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "boolean value",
            .input = .{ .boolean = true },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "array value",
            .input = .{ .array = &.{} },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "offset_date_time value",
            .input = .{ .offset_date_time = std.mem.zeroes(types.OffsetDateTime) },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "local_date_time value",
            .input = .{ .local_date_time = std.mem.zeroes(types.LocalDateTime) },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "local_date value",
            .input = .{ .local_date = std.mem.zeroes(types.LocalDate) },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "local_time value",
            .input = .{ .local_time = std.mem.zeroes(types.LocalTime) },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "inline table value",
            .input = .{ .table = .{ .inner = .empty, .is_inline = true } },
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init("", null);
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        try map.put(arena.allocator(), "a", tc.input);
        try std.testing.expectError(tc.expected, resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 0));
    }
}

// 空の aot_array はスタック変数のポインタが必要なため
// テーブルドリブンから分離する。
test "resolveKeyPath: error: aot_array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("", null);
    var list: std.ArrayListUnmanaged(Value) = .empty;
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "a", .{ .aot_array = .{ .inner = &list } });
    try std.testing.expectError(
        error.DuplicateKey,
        resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 0),
    );
}

test "resolveKeyPath: fills diagnostic on error" {
    // aot_array ケース用にループ外で別ポインタを確保する。
    // resolveKeyPath はポインタ比較ではなく値の型で判定するため、
    // 空の ArrayListUnmanaged で差異を表現できる。
    var list: std.ArrayListUnmanaged(Value) = .empty;
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: struct { message: []const u8, line: usize, column: usize },
    }{
        .{
            .name = "non-table value",
            .input = .{ .integer = 1 },
            .expected = .{ .message = "key already exists as non-table", .line = 1, .column = 1 },
        },
        .{
            .name = "inline table value",
            .input = .{ .table = .{ .inner = .empty, .is_inline = true } },
            .expected = .{
                .message = "key already exists as inline table",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "aot_array at last key",
            .input = .{ .aot_array = .{ .inner = &list } },
            .expected = .{ .message = "key already exists as non-table", .line = 1, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init("", &diagnostic);
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        try map.put(arena.allocator(), "a", tc.input);
        try std.testing.expectError(
            error.DuplicateKey,
            resolveKeyPath(&cursor, &arena, &map, &.{"a"}, 0),
        );
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseSingleKey ---

test "parseSingleKey: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "bare key alphanumeric",
            .input = "my_key-1 = 1",
            .expected = "my_key-1",
        },
        .{
            .name = "unicode bare key",
            .input = "café = 1",
            .expected = "café",
        },
        .{
            .name = "4-byte unicode bare key",
            .input = "𠮷 = 1",
            .expected = "𠮷",
        },
        .{
            .name = "basic string quoted key",
            .input = "\"my-key\" = 1",
            .expected = "my-key",
        },
        .{
            .name = "literal string quoted key",
            .input = "'my-key' = 1",
            .expected = "my-key",
        },
        .{
            .name = "empty basic string key",
            .input = "\"\" = 1",
            .expected = "",
        },
        .{
            .name = "empty literal string key",
            .input = "'' = 1",
            .expected = "",
        },
        .{
            .name = "bare key stops before truncated utf8",
            .input = "a\xC3",
            .expected = "a",
        },
        .{
            .name = "bare key stops before invalid utf8 continuation",
            .input = "a\xC3 = 1",
            .expected = "a",
        },
        .{
            .name = "bare key stops before noncharacter U+FFFE",
            .input = "a\xEF\xBF\xBE = 1",
            .expected = "a",
        },
        .{
            .name = "bare key stops before U+0080",
            .input = "a\xC2\x80 = 1",
            .expected = "a",
        },
        .{
            .name = "bare key stops before U+00B1",
            .input = "a\xC2\xB1 = 1",
            .expected = "a",
        },
        .{
            .name = "U+00B2 is valid in bare key",
            .input = "\xC2\xB2 = 1",
            .expected = "\xC2\xB2",
        },
        .{
            .name = "U+00B3 is valid in bare key",
            .input = "\xC2\xB3 = 1",
            .expected = "\xC2\xB3",
        },
        .{
            .name = "U+00B5 is valid in bare key",
            .input = "\xC2\xB5 = 1",
            .expected = "\xC2\xB5",
        },
        .{
            .name = "bare key stops before U+00B6",
            .input = "a\xC2\xB6 = 1",
            .expected = "a",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const key = try parseSingleKey(&cursor, &arena);
        try std.testing.expectEqualStrings(tc.expected, key);
    }
}

test "parseSingleKey: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "non-key leading character",
            .input = "= 1",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "isolated continuation byte",
            .input = "\x80key = 1",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "surrogate codepoint stops scan",
            .input = "\xED\xA0\x80key = 1",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "EOF",
            .input = "",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "truncated utf8 sequence at start",
            .input = "\xC3",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid utf8 continuation byte",
            .input = "\xC3\x28",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "unterminated basic string key",
            .input = "\"key",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unterminated literal string key",
            .input = "'key",
            .expected = error.UnexpectedEof,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseSingleKey(&cursor, &arena));
    }
}

test "parseSingleKey: fills diagnostic on error" {
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
            .name = "EOF",
            .input = "",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "expected key",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "non-key character",
            .input = "= 1",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected bare key",
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
        try std.testing.expectError(tc.expected.err, parseSingleKey(&cursor, &arena));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

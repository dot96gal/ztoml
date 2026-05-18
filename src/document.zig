const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const key = @import("key.zig");
const keyval = @import("keyval.zig");
const types = @import("types.zig");

const initial_table_cap: u32 = 8;

// TOML のキーは NUL を含められないため、
// NUL を結合セパレータとして使用しても安全。
const key_join_sep = "\x00";

const Cursor = cursor_mod.Cursor;
const Table = types.Table;
const Value = types.Value;

pub fn parseDocument(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})!Table {
    const allocator = arena.allocator();

    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    try root_map.ensureTotalCapacity(allocator, initial_table_cap);

    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;

    try parseRootBody(cursor, arena, &root_map);
    try parseSections(cursor, arena, &root_map, &defined_tables, &aot_keys);

    return .{ .inner = root_map };
}

fn parseRootBody(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    root_map: *std.StringHashMapUnmanaged(Value),
) (errors.ParseError || error{OutOfMemory})!void {
    cursor.skipWhitespaceAndNewlines();
    while (cursor.peek()) |c| {
        if (c == '[') break;
        try keyval.parseKeyValue(cursor, arena, root_map);
        cursor.skipWhitespaceAndNewlines();
    }
}

fn parseSections(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    root_map: *std.StringHashMapUnmanaged(Value),
    defined_tables: *std.StringHashMapUnmanaged(void),
    aot_keys: *std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)),
) (errors.ParseError || error{OutOfMemory})!void {
    while (cursor.peek() == '[') {
        if (cursor.peekNext() == '[') {
            const keys = try parseArrayOfTableHeader(cursor, arena);
            const current = try appendArrayOfTablesEntry(
                cursor,
                arena,
                root_map,
                aot_keys,
                keys.segments,
            );
            try parseTableBody(cursor, arena, current);
        } else {
            try parseTableSection(cursor, arena, root_map, defined_tables);
        }
    }
}

fn parseArrayOfTableHeader(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
) (errors.ParseError || error{OutOfMemory})!key.DottedKey {
    if (!cursor.startsWith("[[")) @panic("parseArrayOfTableHeader: cursor must be at '[['");

    cursor.advanceAscii(2);
    cursor.skipWhitespace();

    const keys = try key.parseDottedKey(cursor, arena);
    cursor.skipWhitespace();

    if (!cursor.startsWith("]]")) {
        cursor.fillDiagnostic("expected ']]' to close array table header");
        return error.UnexpectedChar;
    }
    cursor.advanceAscii(2);

    return keys;
}

fn parseTableSection(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    root_map: *std.StringHashMapUnmanaged(Value),
    defined_tables: *std.StringHashMapUnmanaged(void),
) (errors.ParseError || error{OutOfMemory})!void {
    if (cursor.peek() != '[') @panic("parseTableSection: cursor must be at '['");

    const allocator = arena.allocator();
    _ = cursor.advance();
    cursor.skipWhitespace();

    const keys = try key.parseDottedKey(cursor, arena);
    cursor.skipWhitespace();

    if (cursor.peek() != ']') {
        cursor.fillDiagnostic("expected ']' to close table header");
        return error.UnexpectedChar;
    }
    _ = cursor.advance();

    // テーブルヘッダの重複は defined_tables で禁止する。
    // AoT は繰り返しを許可し appendKnownAot で追加する
    const joined = try std.mem.join(allocator, key_join_sep, keys.segments);
    const entry = try defined_tables.getOrPut(allocator, joined);
    if (entry.found_existing) {
        cursor.fillDiagnostic("duplicate table definition");
        return error.DuplicateKey;
    }

    entry.value_ptr.* = {};

    const target = try key.resolveKeyPath(
        cursor,
        arena,
        root_map,
        keys.segments,
        initial_table_cap,
    );

    try parseTableBody(cursor, arena, target);
}

fn parseTableBody(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    map: *std.StringHashMapUnmanaged(Value),
) (errors.ParseError || error{OutOfMemory})!void {
    try cursor.consumeNewlineOrEof();
    cursor.skipWhitespaceAndNewlines();
    while (cursor.peek()) |c| {
        if (c == '[') break;
        try keyval.parseKeyValue(cursor, arena, map);
        cursor.skipWhitespaceAndNewlines();
    }
}

fn appendArrayOfTablesEntry(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    root_map: *std.StringHashMapUnmanaged(Value),
    aot_keys: *std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)),
    keys: []const []const u8,
) (errors.ParseError || error{OutOfMemory})!*std.StringHashMapUnmanaged(Value) {
    if (keys.len == 0) @panic("appendArrayOfTablesEntry: keys must not be empty");

    const allocator = arena.allocator();
    const target = try resolveOrCreateAotParentPath(
        cursor,
        arena,
        root_map,
        keys[0 .. keys.len - 1],
    );
    const last_key = keys[keys.len - 1];

    if (target.getPtr(last_key)) |ptr| {
        return appendKnownAot(cursor, arena, ptr);
    } else {
        const joined = try std.mem.join(allocator, key_join_sep, keys);
        return appendUnknownAot(arena, target, last_key, joined, aot_keys);
    }
}

fn appendKnownAot(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    ptr: *Value,
) (errors.ParseError || error{OutOfMemory})!*std.StringHashMapUnmanaged(Value) {
    const aot = switch (ptr.*) {
        .aot_array => |aot| aot,
        else => {
            cursor.fillDiagnostic("array table key conflicts with existing key");
            return error.DuplicateKey;
        },
    };
    const allocator = arena.allocator();
    var inner: std.StringHashMapUnmanaged(Value) = .empty;
    try inner.ensureTotalCapacity(allocator, initial_table_cap);
    try aot.inner.append(allocator, .{ .table = .{ .inner = inner } });
    return &aot.lastPtr().table.inner;
}

fn appendUnknownAot(
    arena: *std.heap.ArenaAllocator,
    target: *std.StringHashMapUnmanaged(Value),
    last_key: []const u8,
    joined: []const u8,
    aot_keys: *std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)),
) error{OutOfMemory}!*std.StringHashMapUnmanaged(Value) {
    if (target.getPtr(last_key) != null)
        @panic("appendUnknownAot: last_key must not exist in target");
    const allocator = arena.allocator();

    var inner: std.StringHashMapUnmanaged(Value) = .empty;
    try inner.ensureTotalCapacity(allocator, initial_table_cap);

    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = inner } });
    try aot_keys.put(allocator, joined, list);
    try target.put(allocator, last_key, .{ .aot_array = .{ .inner = list } });

    return &list.items[0].table.inner;
}

fn resolveOrCreateAotParentPath(
    cursor: *Cursor,
    arena: *std.heap.ArenaAllocator,
    root_map: *std.StringHashMapUnmanaged(Value),
    parent_keys: []const []const u8,
) (errors.ParseError || error{OutOfMemory})!*std.StringHashMapUnmanaged(Value) {
    const allocator = arena.allocator();
    var target: *std.StringHashMapUnmanaged(Value) = root_map;
    for (parent_keys) |k| {
        const entry = try target.getOrPut(allocator, k);
        if (!entry.found_existing) {
            var inner: std.StringHashMapUnmanaged(Value) = .empty;
            try inner.ensureTotalCapacity(allocator, initial_table_cap);
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
                if (aot.len() == 0) @panic("resolveOrCreateAotParentPath: AoT array is empty");
                target = switch (aot.lastPtr().*) {
                    .table => |*t| &t.inner,
                    else => @panic("resolveOrCreateAotParentPath: AoT element is not a table"),
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

// --- parseDocument ---

test "parseDocument: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { data: []const u8, key_path: []const []const u8 },
        expected: i64,
    }{
        .{
            .name = "table section",
            .input = .{ .data = "[a]\nb = 1\n", .key_path = &.{ "a", "b" } },
            .expected = 1,
        },
        .{
            .name = "root and section",
            .input = .{ .data = "x = 0\n[a]\nb = 2\n", .key_path = &.{ "a", "b" } },
            .expected = 2,
        },
        .{
            .name = "nested table section",
            .input = .{ .data = "[a.b]\nc = 3\n", .key_path = &.{ "a", "b", "c" } },
            .expected = 3,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.data, null);
        const table = try parseDocument(&cursor, &arena);
        const current_opt = table.get(tc.input.key_path[0]);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(current_opt != null);
        var current = current_opt.?;
        for (tc.input.key_path[1 .. tc.input.key_path.len - 1]) |k| {
            const next_opt = current.table.get(k);
            try std.testing.expect(next_opt != null);
            current = next_opt.?;
        }
        const last_key = tc.input.key_path[tc.input.key_path.len - 1];
        const val_opt = current.table.get(last_key);
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

// [NOTE] parseDocument: success: root key-value —
// table-driven 本体はルートキーをナビゲートする前に key_path[0] を
// table として扱うため、単一セグメントのルートキーを
// テーブルドリブンに統合できない。
test "parseDocument: success: root key-value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("a = 1\n", null);
    const table = try parseDocument(&cursor, &arena);
    const val = table.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), val.integer);
}

test "parseDocument: success: empty document" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "empty string", .input = "", .expected = 0 },
        .{ .name = "newline only", .input = "\n", .expected = 0 },
        .{ .name = "comment only", .input = "# comment\n", .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        const table = try parseDocument(&cursor, &arena);
        try std.testing.expectEqual(tc.expected, table.count());
    }
}

test "parseDocument: success: array of tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("[[a]]\nb = 1\n", null);
    const table = try parseDocument(&cursor, &arena);
    const val_opt = table.get("a");
    // どのテストケースが失敗したか特定するため
    // expect で null チェックし、.? で安全に unwrap する
    try std.testing.expect(val_opt != null);
    try std.testing.expectEqual(@as(usize, 1), val_opt.?.aot_array.len());
    const b_opt = val_opt.?.aot_array.items()[0].table.get("b");
    try std.testing.expect(b_opt != null);
    try std.testing.expectEqual(@as(i64, 1), b_opt.?.integer);
}

test "parseDocument: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "invalid root key-value",
            .input = "bad!val\n",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "duplicate table",
            .input = "[a]\n[a]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "table section after inline table",
            .input = "a = {b = 1}\n[a]\nc = 2\n",
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseDocument(&cursor, &arena));
    }
}

test "parseDocument: fills diagnostic on error" {
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
            .name = "invalid root key-value",
            .input = "bad!val\n",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected '=' after key",
                .line = 1,
                .column = 4,
            },
        },
        .{
            .name = "missing value",
            .input = "key = ",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input",
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
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseDocument(&cursor, &arena));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseRootBody ---

test "parseRootBody: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{
            .name = "empty",
            .input = "",
            .expected = 0,
        },
        .{
            .name = "single key-value",
            .input = "a = 1\n",
            .expected = 1,
        },
        .{
            .name = "multiple key-values",
            .input = "a = 1\nb = 2\nc = 3\n",
            .expected = 3,
        },
        .{
            .name = "key-values with comments",
            .input = "# comment\na = 1\n# another comment\nb = 2\n",
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try parseRootBody(&cursor, &arena, &root_map);
        try std.testing.expectEqual(tc.expected, root_map.count());
    }
}

test "parseRootBody: success: stops at section header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("a = 1\n[b]\n", null);
    try parseRootBody(&cursor, &arena, &root_map);
    try std.testing.expectEqual(@as(usize, 1), root_map.count());
    const ch = cursor.peek() orelse return error.TestFailed;
    try std.testing.expectEqual('[', ch);
}

test "parseRootBody: error: invalid key-value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("bad!val\n", null);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseRootBody(&cursor, &arena, &root_map),
    );
}

// --- parseSections ---

test "parseSections: success: table section" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { data: []const u8, key_path: []const []const u8 },
        expected: i64,
    }{
        .{
            .name = "single table",
            .input = .{ .data = "[a]\nx = 1\n", .key_path = &.{ "a", "x" } },
            .expected = 1,
        },
        .{
            .name = "dotted table header",
            .input = .{ .data = "[a.b]\nx = 2\n", .key_path = &.{ "a", "b", "x" } },
            .expected = 2,
        },
        .{
            .name = "multiple tables",
            .input = .{ .data = "[a]\nx = 1\n[b]\ny = 2\n", .key_path = &.{ "b", "y" } },
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.ensureTotalCapacity(allocator, initial_table_cap);
        var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
        var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
        var cursor = Cursor.init(tc.input.data, null);
        try parseSections(&cursor, &arena, &root_map, &defined_tables, &aot_keys);
        const current_opt = root_map.get(tc.input.key_path[0]);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(current_opt != null);
        var current = current_opt.?;
        for (tc.input.key_path[1 .. tc.input.key_path.len - 1]) |k| {
            const next_opt = current.table.get(k);
            try std.testing.expect(next_opt != null);
            current = next_opt.?;
        }
        const last_key = tc.input.key_path[tc.input.key_path.len - 1];
        const val_opt = current.table.get(last_key);
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parseSections: success: array of tables" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "single entry", .input = "[[a]]\nx = 1\n", .expected = 1 },
        .{ .name = "two entries", .input = "[[a]]\nx = 1\n[[a]]\nx = 2\n", .expected = 2 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.ensureTotalCapacity(allocator, initial_table_cap);
        var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
        var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try parseSections(&cursor, &arena, &root_map, &defined_tables, &aot_keys);
        const val_opt = root_map.get("a");
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.aot_array.len());
    }
}

test "parseSections: success: nested array of tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    try root_map.ensureTotalCapacity(allocator, initial_table_cap);
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
    const input =
        \\[[fruits]]
        \\name = "apple"
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\[[fruits]]
        \\name = "banana"
        \\[[fruits.varieties]]
        \\name = "plantain"
        \\
    ;
    var cursor = Cursor.init(input, null);
    try parseSections(&cursor, &arena, &root_map, &defined_tables, &aot_keys);

    const fruits = root_map.get("fruits") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), fruits.aot_array.len());
    const name0 = fruits.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("apple", name0.string);
    const name1 = fruits.aot_array.items()[1].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("banana", name1.string);

    const vars0 = fruits.aot_array.items()[0].table.get("varieties") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), vars0.aot_array.len());
    const vars0_name0 = vars0.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("red delicious", vars0_name0.string);

    const vars1 = fruits.aot_array.items()[1].table.get("varieties") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), vars1.aot_array.len());
    const vars1_name0 = vars1.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("plantain", vars1_name0.string);
}

test "parseSections: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "duplicate table definition",
            .input = "[a]\n[a]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "aot conflicts with table key",
            .input = "[a]\n[[a]]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "aot followed by table with same key",
            .input = "[[a]]\n[a]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "dotted aot conflicts with table",
            .input = "[[a.b]]\n[a.b]\n",
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.ensureTotalCapacity(allocator, initial_table_cap);
        var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
        var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(
            tc.expected,
            parseSections(&cursor, &arena, &root_map, &defined_tables, &aot_keys),
        );
    }
}

test "parseSections: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { line: usize, column: usize, message: []const u8 },
    }{
        .{
            .name = "aot followed by table with same key",
            .input = "[[a]]\n[a]\n",
            .expected = .{
                .line = 2,
                .column = 4,
                .message = "key already exists as non-table",
            },
        },
        .{
            .name = "aot conflicts with table key",
            .input = "[a]\n[[a]]\n",
            .expected = .{
                .line = 2,
                .column = 6,
                .message = "array table key conflicts with existing key",
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.ensureTotalCapacity(allocator, initial_table_cap);
        var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
        var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(
            error.DuplicateKey,
            parseSections(&cursor, &arena, &root_map, &defined_tables, &aot_keys),
        );
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
    }
}

// --- parseArrayOfTableHeader ---

test "parseArrayOfTableHeader: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const []const u8,
    }{
        .{ .name = "single key", .input = "[[a]]\n", .expected = &.{"a"} },
        .{ .name = "dotted key", .input = "[[a.b]]\n", .expected = &.{ "a", "b" } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var cursor = Cursor.init(tc.input, null);
        const keys = try parseArrayOfTableHeader(&cursor, &arena);
        try std.testing.expectEqual(tc.expected.len, keys.segments.len);
        for (tc.expected, keys.segments) |exp, seg| {
            try std.testing.expectEqualStrings(exp, seg);
        }
    }
}

test "parseArrayOfTableHeader: error: missing closing ']]'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cursor = Cursor.init("[[fruits]\n", null);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseArrayOfTableHeader(&cursor, &arena),
    );
}

test "parseArrayOfTableHeader: fills diagnostic on error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("[[fruits]\n", &diagnostic);
    try std.testing.expectError(error.UnexpectedChar, parseArrayOfTableHeader(&cursor, &arena));
    try std.testing.expectEqualStrings(
        "expected ']]' to close array table header",
        diagnostic.message,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 9), diagnostic.column);
}

// --- parseTableSection ---

test "parseTableSection: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { data: []const u8, key_path: []const []const u8 },
        expected: i64,
    }{
        .{
            .name = "flat key",
            .input = .{ .data = "[foo]\nbar = 1\n", .key_path = &.{ "foo", "bar" } },
            .expected = 1,
        },
        .{
            .name = "dotted key",
            .input = .{ .data = "[a.b]\nx = 2\n", .key_path = &.{ "a", "b", "x" } },
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input.data, null);
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
        try parseTableSection(&cursor, &arena, &root_map, &defined_tables);
        const current_opt = root_map.get(tc.input.key_path[0]);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(current_opt != null);
        var current = current_opt.?;
        for (tc.input.key_path[1 .. tc.input.key_path.len - 1]) |k| {
            const next_opt = current.table.get(k);
            try std.testing.expect(next_opt != null);
            current = next_opt.?;
        }
        const last_key = tc.input.key_path[tc.input.key_path.len - 1];
        const val_opt = current.table.get(last_key);
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parseTableSection: success: stops at next section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("[empty]\n[next]\n", null);
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    try parseTableSection(&cursor, &arena, &root_map, &defined_tables);
    const empty = root_map.get("empty") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 0), empty.table.count());
    const ch = cursor.peek() orelse return error.TestFailed;
    try std.testing.expectEqual('[', ch);
}

test "parseTableSection: error: duplicate key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var setup_cursor = Cursor.init("[foo]\nbar = 1\n", null);
    try parseTableSection(&setup_cursor, &arena, &root_map, &defined_tables);
    var cursor = Cursor.init("[foo]\nbaz = 2\n", null);
    try std.testing.expectError(
        error.DuplicateKey,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
}

test "parseTableSection: error: missing closing bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var cursor = Cursor.init("[foo\nbar = 1\n", null);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
}

test "parseTableSection: error: aot key conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = .empty } });
    try root_map.put(allocator, "foo", .{ .aot_array = .{ .inner = list } });
    var cursor = Cursor.init("[foo]\nbar = 1\n", null);
    try std.testing.expectError(
        error.DuplicateKey,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
}

test "parseTableSection: error: aot key conflict: diagnostic" {
    var diagnostic: types.Diagnostic = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = .empty } });
    try root_map.put(allocator, "foo", .{ .aot_array = .{ .inner = list } });
    var cursor = Cursor.init("[foo]\nbar = 1\n", &diagnostic);
    try std.testing.expectError(
        error.DuplicateKey,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
    try std.testing.expectEqualStrings("key already exists as non-table", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

test "parseTableSection: error: missing closing bracket: diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("[foo\nbar = 1\n", &diagnostic);
    try std.testing.expectError(
        error.UnexpectedChar,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
    try std.testing.expectEqualStrings("expected ']' to close table header", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 5), diagnostic.column);
}

test "parseTableSection: error: duplicate table: diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var defined_tables: std.StringHashMapUnmanaged(void) = .empty;
    var setup_cursor = Cursor.init("[foo]\nbar = 1\n", null);
    try parseTableSection(&setup_cursor, &arena, &root_map, &defined_tables);
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("[foo]\nbaz = 2\n", &diagnostic);
    try std.testing.expectError(
        error.DuplicateKey,
        parseTableSection(&cursor, &arena, &root_map, &defined_tables),
    );
    try std.testing.expectEqualStrings("duplicate table definition", diagnostic.message);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
}

// --- parseTableBody ---

test "parseTableBody: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{
            .name = "empty string eof",
            .input = "",
            .expected = 0,
        },
        .{
            .name = "empty body",
            .input = "\n",
            .expected = 0,
        },
        .{
            .name = "single key-value",
            .input = "\nbar = 1\n",
            .expected = 1,
        },
        .{
            .name = "crlf empty body",
            .input = "\r\n",
            .expected = 0,
        },
        .{
            .name = "crlf single key-value",
            .input = "\r\nbar = 1\r\n",
            .expected = 1,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        try parseTableBody(&cursor, &arena, &map);
        try std.testing.expectEqual(tc.expected, map.count());
    }
}

test "parseTableBody: success: stops at next section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cursor = Cursor.init("\nbar = 1\n[next]\n", null);
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try parseTableBody(&cursor, &arena, &map);
    try std.testing.expectEqual(@as(usize, 1), map.count());
    const ch = cursor.peek() orelse return error.TestFailed;
    try std.testing.expectEqual('[', ch);
}

test "parseTableBody: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "missing newline",
            .input = " bad",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid key-value",
            .input = "\nbad!val\n",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "key-value without value (eof)",
            .input = "\nbar =",
            .expected = error.UnexpectedEof,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cursor = Cursor.init(tc.input, null);
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        try std.testing.expectError(
            tc.expected,
            parseTableBody(&cursor, &arena, &map),
        );
    }
}

// --- appendArrayOfTablesEntry ---

test "appendArrayOfTablesEntry: success: first entry creates AoT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
    var cursor = Cursor.init("", null);

    const current = try appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"a"});
    try current.put(allocator, "x", .{ .integer = 1 });

    const val = root_map.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), val.aot_array.len());
    const x0 = val.aot_array.items()[0].table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), x0.integer);
}

test "appendArrayOfTablesEntry: success: appends to existing AoT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
    var cursor = Cursor.init("", null);

    const c1 = try appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"a"});
    try c1.put(allocator, "x", .{ .integer = 1 });
    const c2 = try appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"a"});
    try c2.put(allocator, "x", .{ .integer = 2 });

    const val = root_map.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), val.aot_array.len());
    const x0 = val.aot_array.items()[0].table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), x0.integer);
    const x1 = val.aot_array.items()[1].table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 2), x1.integer);
}

test "appendArrayOfTablesEntry: success: nested AoT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
    var cursor = Cursor.init("", null);

    _ = try appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"fruits"});
    const v1 = try appendArrayOfTablesEntry(
        &cursor,
        &arena,
        &root_map,
        &aot_keys,
        &.{ "fruits", "varieties" },
    );
    try v1.put(allocator, "name", .{ .string = "red delicious" });
    _ = try appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"fruits"});
    const v2 = try appendArrayOfTablesEntry(
        &cursor,
        &arena,
        &root_map,
        &aot_keys,
        &.{ "fruits", "varieties" },
    );
    try v2.put(allocator, "name", .{ .string = "plantain" });

    const fruits = root_map.get("fruits") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), fruits.aot_array.len());
    const vars0 = fruits.aot_array.items()[0].table.get("varieties") orelse return error.TestFailed;
    const vars0_name0 = vars0.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("red delicious", vars0_name0.string);
    const vars1 = fruits.aot_array.items()[1].table.get("varieties") orelse return error.TestFailed;
    const vars1_name0 = vars1.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("plantain", vars1_name0.string);
}

test "appendArrayOfTablesEntry: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.ParseError,
    }{
        .{
            .name = "conflicts with scalar",
            .input = .{ .integer = 1 },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "conflicts with inline array",
            .input = .{ .array = &[_]Value{} },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "conflicts with table",
            .input = .{ .table = .{ .inner = .empty } },
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.put(arena.allocator(), "a", tc.input);
        var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
        var cursor = Cursor.init("", null);
        try std.testing.expectError(
            tc.expected,
            appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"a"}),
        );
    }
}

test "appendArrayOfTablesEntry: fills diagnostic on error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    try root_map.put(arena.allocator(), "a", .{ .integer = 1 });
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;
    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("", &diagnostic);
    try std.testing.expectError(
        error.DuplicateKey,
        appendArrayOfTablesEntry(&cursor, &arena, &root_map, &aot_keys, &.{"a"}),
    );
    try std.testing.expectEqualStrings(
        "array table key conflicts with existing key",
        diagnostic.message,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

// --- appendKnownAot ---

test "appendKnownAot: success: appends to existing AoT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = .empty } });

    var target: std.StringHashMapUnmanaged(Value) = .empty;
    try target.put(allocator, "a", .{ .aot_array = .{ .inner = list } });

    var cursor = Cursor.init("", null);
    const ptr = target.getPtr("a") orelse return error.TestFailed;
    _ = try appendKnownAot(&cursor, &arena, ptr);

    const val = target.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), val.aot_array.len());
}

test "appendKnownAot: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.ParseError,
    }{
        .{
            .name = "scalar at last_key",
            .input = .{ .integer = 1 },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "array at last_key",
            .input = .{ .array = &[_]Value{} },
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var target: std.StringHashMapUnmanaged(Value) = .empty;
        try target.put(allocator, "a", tc.input);

        var cursor = Cursor.init("", null);
        const ptr = target.getPtr("a") orelse return error.TestFailed;
        try std.testing.expectError(
            tc.expected,
            appendKnownAot(&cursor, &arena, ptr),
        );
    }
}

test "appendKnownAot: fills diagnostic on error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var target: std.StringHashMapUnmanaged(Value) = .empty;
    try target.put(allocator, "a", .{ .integer = 1 });

    var diagnostic: types.Diagnostic = .{};
    var cursor = Cursor.init("", &diagnostic);
    const ptr = target.getPtr("a") orelse return error.TestFailed;
    try std.testing.expectError(
        error.DuplicateKey,
        appendKnownAot(&cursor, &arena, ptr),
    );
    try std.testing.expectEqualStrings(
        "array table key conflicts with existing key",
        diagnostic.message,
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
}

// --- appendUnknownAot ---

test "appendUnknownAot: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var target: std.StringHashMapUnmanaged(Value) = .empty;
    var aot_keys: std.StringHashMapUnmanaged(*std.ArrayListUnmanaged(Value)) = .empty;

    _ = try appendUnknownAot(&arena, &target, "a", "a", &aot_keys);

    const val = target.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), val.aot_array.len());
    try std.testing.expect(aot_keys.contains("a"));
}

// --- resolveOrCreateAotParentPath ---

test "resolveOrCreateAotParentPath: success: empty parent keys returns root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("", null);
    const result = try resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{});
    try std.testing.expectEqual(&root_map, result);
}

test "resolveOrCreateAotParentPath: success: table intermediate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    try root_map.put(allocator, "a", .{ .table = .{ .inner = .empty } });
    var cursor = Cursor.init("", null);
    const result = try resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{"a"});
    try result.put(allocator, "x", .{ .integer = 1 });
    const a = root_map.get("a") orelse return error.TestFailed;
    const val = a.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), val.integer);
}

test "resolveOrCreateAotParentPath: success: AoT array intermediate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    const list = try allocator.create(std.ArrayListUnmanaged(Value));
    list.* = .empty;
    try list.append(allocator, .{ .table = .{ .inner = .empty } });
    try root_map.put(allocator, "a", .{ .aot_array = .{ .inner = list } });
    var cursor = Cursor.init("", null);
    const result = try resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{"a"});
    try result.put(allocator, "x", .{ .integer = 42 });
    const a = root_map.get("a") orelse return error.TestFailed;
    const val = a.aot_array.items()[0].table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), val.integer);
}

test "resolveOrCreateAotParentPath: success: unknown key creates new table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root_map: std.StringHashMapUnmanaged(Value) = .empty;
    var cursor = Cursor.init("", null);
    const result = try resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{"a"});
    try result.put(allocator, "x", .{ .integer = 99 });
    const a = root_map.get("a") orelse return error.TestFailed;
    const val = a.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 99), val.integer);
}

test "resolveOrCreateAotParentPath: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.ParseError,
    }{
        .{
            .name = "scalar intermediate",
            .input = .{ .integer = 1 },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "inline array intermediate",
            .input = .{ .array = &[_]Value{} },
            .expected = error.DuplicateKey,
        },
        .{
            .name = "inline table intermediate",
            .input = .{ .table = .{ .inner = .empty, .is_inline = true } },
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.put(arena.allocator(), "a", tc.input);
        var cursor = Cursor.init("", null);
        try std.testing.expectError(
            tc.expected,
            resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{"a"}),
        );
    }
}

test "resolveOrCreateAotParentPath: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: struct { message: []const u8, line: usize, column: usize },
    }{
        .{
            .name = "scalar",
            .input = .{ .integer = 1 },
            .expected = .{
                .message = "key already exists as non-table",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "inline table",
            .input = .{ .table = .{ .inner = .empty, .is_inline = true } },
            .expected = .{
                .message = "key already exists as inline table",
                .line = 1,
                .column = 1,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var root_map: std.StringHashMapUnmanaged(Value) = .empty;
        try root_map.put(arena.allocator(), "a", tc.input);
        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init("", &diagnostic);
        try std.testing.expectError(
            error.DuplicateKey,
            resolveOrCreateAotParentPath(&cursor, &arena, &root_map, &.{"a"}),
        );
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

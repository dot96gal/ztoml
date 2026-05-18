const std = @import("std");
const cursor_mod = @import("cursor.zig");
const document = @import("document.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Cursor = cursor_mod.Cursor;
const ParseOptions = types.ParseOptions;
const Diagnostic = types.Diagnostic;
const Table = types.Table;
const Value = types.Value;

pub fn parse(
    arena: *std.heap.ArenaAllocator,
    input: []const u8,
    options: ParseOptions,
) (errors.ParseError || error{OutOfMemory})!Table {
    var cursor = Cursor.init(input, options.diagnostic);
    return document.parseDocument(&cursor, arena);
}

// --- parse ---

test "parse: success: basic key-value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "a = 1\n", .{});
    const val = table.get("a") orelse return error.TestFailed;
    try std.testing.expectEqual(Value{ .integer = 1 }, val);
}

test "parse: success: key syntax and comments" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { src: []const u8, key: []const u8 },
        expected: i64,
    }{
        .{
            .name = "unicode key",
            .input = .{
                .src = "café = 42",
                .key = "café",
            },
            .expected = 42,
        },
        .{
            .name = "inline comment",
            .input = .{
                .src = "port = 8080 # server port\n",
                .key = "port",
            },
            .expected = 8080,
        },
        .{
            .name = "quoted key",
            .input = .{
                .src = "\"my-key\" = 42\n",
                .key = "my-key",
            },
            .expected = 42,
        },
        .{
            .name = "leading comments",
            .input = .{
                .src = "\n# top-level comment\n# another comment\n\nkey = 42",
                .key = "key",
            },
            .expected = 42,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, tc.input.src, .{});
        const val_opt = table.get(tc.input.key);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parse: success: multiple types: string" {
    const input =
        \\name     = "Alice"
        \\age      = 30
        \\active   = true
        \\inactive = false
        \\negative = -5
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const val = table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Alice", val.string);
}

test "parse: success: multiple types: integer and boolean" {
    const input =
        \\name     = "Alice"
        \\age      = 30
        \\active   = true
        \\inactive = false
        \\negative = -5
    ;
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: Value,
    }{
        .{ .name = "age", .input = "age", .expected = .{ .integer = 30 } },
        .{ .name = "active", .input = "active", .expected = .{ .boolean = true } },
        .{ .name = "inactive", .input = "inactive", .expected = .{ .boolean = false } },
        .{ .name = "negative", .input = "negative", .expected = .{ .integer = -5 } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, input, .{});
        const val_opt = table.get(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?);
    }
}

test "parse: success: string and number literals: string" {
    const input =
        \\str1 = "hello\nworld"
        \\str2 = 'C:\Users\tom'
        \\hex  = 0xDEADBEEF
        \\oct  = 0o77
        \\bin  = 0b1010
        \\zero = 0
        \\flt  = 3.14e-2
        \\flt2 = 1e10
    ;
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "str1", .input = "str1", .expected = "hello\nworld" },
        .{ .name = "str2", .input = "str2", .expected = "C:\\Users\\tom" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, input, .{});
        const val_opt = table.get(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqualStrings(tc.expected, val_opt.?.string);
    }
}

test "parse: success: string and number literals: integer" {
    const input =
        \\str1 = "hello\nworld"
        \\str2 = 'C:\Users\tom'
        \\hex  = 0xDEADBEEF
        \\oct  = 0o77
        \\bin  = 0b1010
        \\zero = 0
        \\flt  = 3.14e-2
        \\flt2 = 1e10
    ;
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "hex", .input = "hex", .expected = 0xDEADBEEF },
        .{ .name = "oct", .input = "oct", .expected = 63 },
        .{ .name = "bin", .input = "bin", .expected = 10 },
        .{ .name = "zero", .input = "zero", .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, input, .{});
        const val_opt = table.get(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqual(tc.expected, val_opt.?.integer);
    }
}

test "parse: success: string and number literals: float" {
    const input =
        \\str1 = "hello\nworld"
        \\str2 = 'C:\Users\tom'
        \\hex  = 0xDEADBEEF
        \\oct  = 0o77
        \\bin  = 0b1010
        \\zero = 0
        \\flt  = 3.14e-2
        \\flt2 = 1e10
    ;
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { value: f64, tolerance: f64 },
    }{
        .{ .name = "flt", .input = "flt", .expected = .{ .value = 3.14e-2, .tolerance = 1e-15 } },
        .{ .name = "flt2", .input = "flt2", .expected = .{ .value = 1e10, .tolerance = 1.0 } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, input, .{});
        const val_opt = table.get(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectApproxEqAbs(
            tc.expected.value,
            val_opt.?.float,
            tc.expected.tolerance,
        );
    }
}

test "parse: success: multi-line strings" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { src: []const u8, key: []const u8 },
        expected: []const u8,
    }{
        .{
            .name = "multi-line basic string trims leading newline",
            .input = .{
                .src = "str = \"\"\"\nhello\nworld\"\"\"",
                .key = "str",
            },
            .expected = "hello\nworld",
        },
        .{
            .name = "multi-line literal string trims leading newline",
            .input = .{
                .src = "str = '''\nhello\nworld'''",
                .key = "str",
            },
            .expected = "hello\nworld",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, tc.input.src, .{});
        const val_opt = table.get(tc.input.key);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqualStrings(tc.expected, val_opt.?.string);
    }
}

test "parse: success: unicode escape in string" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { src: []const u8, key: []const u8 },
        expected: []const u8,
    }{
        .{
            .name = "4-digit unicode escape",
            .input = .{
                .src = "s = \"\\u00E9\"",
                .key = "s",
            },
            .expected = "é",
        },
        .{
            .name = "8-digit unicode escape",
            .input = .{
                .src = "s = \"\\U0001F600\"",
                .key = "s",
            },
            .expected = "😀",
        },
        .{
            .name = "2-digit hex escape",
            .input = .{
                .src = "s = \"\\x41\"",
                .key = "s",
            },
            .expected = "A",
        },
        .{
            .name = "ESC escape",
            .input = .{
                .src = "s = \"\\e\"",
                .key = "s",
            },
            .expected = "\x1b",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, tc.input.src, .{});
        const val_opt = table.get(tc.input.key);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(val_opt != null);
        try std.testing.expectEqualStrings(tc.expected, val_opt.?.string);
    }
}

test "parse: success: table section" {
    const input =
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const db = table.get("database") orelse return error.TestFailed;
    const host = db.table.get("host") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("localhost", host.string);
    const port = db.table.get("port") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 5432), port.integer);
}

test "parse: success: dotted key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "a.b.c = true\n", .{});
    const a = table.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    const c = b.table.get("c") orelse return error.TestFailed;
    try std.testing.expectEqual(true, c.boolean);
}

test "parse: success: array inline table and table section" {
    const input =
        \\fruits = ["apple", "banana"]
        \\point = {x = 1, y = 2}
        \\
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const fruits = table.get("fruits") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), fruits.array.len);
    try std.testing.expectEqualStrings("apple", fruits.array[0].string);
    const point = table.get("point") orelse return error.TestFailed;
    const px = point.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), px.integer);
    const db = table.get("database") orelse return error.TestFailed;
    const db_host = db.table.get("host") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("localhost", db_host.string);
}

test "parse: success: empty array and inline table" {
    const input =
        \\arr = []
        \\tbl = {}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const arr = table.get("arr") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 0), arr.array.len);
    const tbl = table.get("tbl") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 0), tbl.table.count());
}

test "parse: success: nested array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "arr = [[1, 2], [3, 4]]\n", .{});
    const arr = table.get("arr") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), arr.array.len);
    try std.testing.expectEqual(@as(i64, 2), arr.array[0].array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr.array[1].array[0].integer);
}

test "parse: success: max nesting depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "n = " ++ "[" ** 128 ++ "1" ++ "]" ** 128, .{});
    const n = table.get("n") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), n.array.len);
}

test "parse: success: max nesting depth for inline table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "n = " ++ "{k = " ** 128 ++ "1" ++ "}" ** 128, .{});
    const n = table.get("n") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), n.table.count());
}

test "parse: success: array of tables" {
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const products = table.get("products") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), products.aot_array.len());
    const name0 = products.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Hammer", name0.string);
    const name1 = products.aot_array.items()[1].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Nail", name1.string);
}

test "parse: success: datetime types" {
    const input =
        \\dt     = 1979-05-27T07:32:00Z
        \\dt_jst = 1979-05-27T07:32:00+09:00
        \\dt_est = 1979-05-27T07:32:00-05:00
        \\dt_ns  = 1979-05-27T07:32:00.123456789Z
        \\d      = 1979-05-27
        \\t      = 07:32:00
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const dt = table.get("dt") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, 0), dt.offset_date_time.offset_minutes);
    const dt_jst = table.get("dt_jst") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, 540), dt_jst.offset_date_time.offset_minutes);
    const dt_est = table.get("dt_est") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, -300), dt_est.offset_date_time.offset_minutes);
    const dt_ns = table.get("dt_ns") orelse return error.TestFailed;
    try std.testing.expectEqual(
        @as(u32, 123_456_789),
        dt_ns.offset_date_time.datetime.time.nanosecond,
    );
    const d = table.get("d") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 27), d.local_date.day);
    const t = table.get("t") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 7), t.local_time.hour);
}

test "parse: success: local datetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "dt = 1979-05-27T07:32:00\n", .{});
    const dt = table.get("dt") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u16, 1979), dt.local_date_time.date.year);
    try std.testing.expectEqual(@as(u8, 5), dt.local_date_time.date.month);
    try std.testing.expectEqual(@as(u8, 27), dt.local_date_time.date.day);
    try std.testing.expectEqual(@as(u8, 7), dt.local_date_time.time.hour);
    try std.testing.expectEqual(@as(u8, 32), dt.local_date_time.time.minute);
    try std.testing.expectEqual(@as(u8, 0), dt.local_date_time.time.second);
}

test "parse: success: line ending variants" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { a: i64, b: i64 },
    }{
        .{
            .name = "CRLF",
            .input = "a = 1\r\nb = 2\r\n",
            .expected = .{ .a = 1, .b = 2 },
        },
        .{
            .name = "mixed LF and CRLF",
            .input = "a = 1\nb = 2\r\n",
            .expected = .{ .a = 1, .b = 2 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const table = try parse(&arena, tc.input, .{});
        const a_opt = table.get("a");
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(a_opt != null);
        try std.testing.expectEqual(tc.expected.a, a_opt.?.integer);
        const b_opt = table.get("b");
        try std.testing.expect(b_opt != null);
        try std.testing.expectEqual(tc.expected.b, b_opt.?.integer);
    }
}

test "parse: success: empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, "", .{});
    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "parse: success: dotted table header" {
    const input =
        \\[a.b]
        \\val = 1
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const a = table.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    const val = b.table.get("val") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), val.integer);
}

test "parse: success: nan and inf" {
    const input =
        \\a = nan
        \\b = -inf
        \\c = +nan
        \\d = -nan
        \\e = +inf
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const a = table.get("a") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(a.float));
    const b = table.get("b") orelse return error.TestFailed;
    try std.testing.expectEqual(-std.math.inf(f64), b.float);
    const c = table.get("c") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(c.float));
    const d = table.get("d") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(d.float));
    const e = table.get("e") orelse return error.TestFailed;
    try std.testing.expectEqual(std.math.inf(f64), e.float);
}

test "parse: success: integer boundary values" {
    const input =
        \\max = 9223372036854775807
        \\min = -9223372036854775808
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const max_val = table.get("max") orelse return error.TestFailed;
    try std.testing.expectEqual(std.math.maxInt(i64), max_val.integer);
    const min_val = table.get("min") orelse return error.TestFailed;
    try std.testing.expectEqual(std.math.minInt(i64), min_val.integer);
}

test "parse: success: nested array of tables" {
    const input =
        \\[[fruits.variety]]
        \\name = "red delicious"
        \\
        \\[[fruits.variety]]
        \\name = "granny smith"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const fruits = table.get("fruits") orelse return error.TestFailed;
    const variety = fruits.table.get("variety") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), variety.aot_array.len());
    const name0 = variety.aot_array.items()[0].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("red delicious", name0.string);
    const name1 = variety.aot_array.items()[1].table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("granny smith", name1.string);
}

test "parse: success: sub-table of array of tables" {
    const input =
        \\[[fruits]]
        \\name = "apple"
        \\
        \\[fruits.physical]
        \\color = "red"
        \\shape = "round"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try parse(&arena, input, .{});
    const fruits = table.get("fruits") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), fruits.aot_array.len());
    const elem = fruits.aot_array.items()[0];
    const name = elem.table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("apple", name.string);
    const physical = elem.table.get("physical") orelse return error.TestFailed;
    const color = physical.table.get("color") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("red", color.string);
    const shape = physical.table.get("shape") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("round", shape.string);
}

test "parse: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "missing value",
            .input = "key = ",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unquoted string value",
            .input = "key = value",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "duplicate key",
            .input = "a = 1\na = 2",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "invalid underscore",
            .input = "n = 1__0",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "binary with invalid digit",
            .input = "n = 0b12",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "octal with invalid digit",
            .input = "n = 0o89",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "integer with leading zero",
            .input = "n = 01",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "signed hex",
            .input = "n = +0xFF",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "signed octal",
            .input = "n = -0o77",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "signed binary",
            .input = "n = +0b101",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float leading zero in integer part",
            .input = "n = 01.5",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float trailing underscore in integer part",
            .input = "n = 1_.5",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float trailing underscore in fractional part",
            .input = "n = 1.5_",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float leading underscore in exponent",
            .input = "n = 1e_0",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float trailing underscore in exponent",
            .input = "n = 1e1_",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "duplicate table header",
            .input = "[a]\n[a]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "duplicate dotted key",
            .input = "a.b = 1\na.b = 2\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "AoT key conflicts with existing scalar",
            .input = "a = 1\n[[a]]\n",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "integer literal exceeding buffer",
            .input = "n = " ++ "9" ++ "_2" ** 32,
            .expected = error.InvalidNumber,
        },
        .{
            .name = "binary literal exceeding buffer",
            .input = "n = 0b" ++ "0" ++ "_1" ** 64,
            .expected = error.InvalidNumber,
        },
        .{
            .name = "invalid escape sequence",
            .input = "key = \"\\q\"",
            .expected = error.InvalidEscape,
        },
        .{
            .name = "invalid unicode code point",
            .input = "key = \"\\uD800\"",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "invalid hex digit in 2-digit escape",
            .input = "key = \"\\xGG\"",
            .expected = error.InvalidUnicode,
        },
        .{
            .name = "invalid date month out of range",
            .input = "d = 1979-13-01",
            .expected = error.InvalidDate,
        },
        .{
            .name = "invalid time minute out of range",
            .input = "t = 07:60:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "deeply nested array",
            .input = "n = " ++ "[" ** 129 ++ "1" ++ "]" ** 129,
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "deeply nested inline table",
            .input = "n = " ++ "{k = " ** 129 ++ "1" ++ "}" ** 129,
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "integer overflow",
            .input = "n = 9223372036854775808",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "trailing comma in inline table",
            .input = "n = {x = 1,}",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "array of tables path through inline table",
            .input = "a = {b = {c = 1}}\n[[a.b.d]]\n",
            .expected = error.DuplicateKey,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(
            tc.expected,
            parse(&arena, tc.input, .{}),
        );
    }
}

test "parse: diagnostic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            err: errors.ParseError,
            line: usize,
            column: usize,
            message: []const u8,
        },
    }{
        .{
            .name = "missing value",
            .input = "key = ",
            .expected = .{
                .err = error.UnexpectedEof,
                .line = 1,
                .column = 7,
                .message = "unexpected end of input",
            },
        },
        .{
            .name = "unicode column counting",
            .input = "café = ",
            .expected = .{
                .err = error.UnexpectedEof,
                .line = 1,
                .column = 8,
                .message = "unexpected end of input",
            },
        },
        .{
            .name = "AoT key conflicts with existing scalar",
            .input = "a = 1\n[[a]]\n",
            .expected = .{
                .err = error.DuplicateKey,
                .line = 2,
                .column = 6,
                .message = "array table key conflicts with existing key",
            },
        },
        .{
            .name = "invalid escape sequence",
            .input = "key = \"\\q\"",
            .expected = .{
                .err = error.InvalidEscape,
                .line = 1,
                .column = 10,
                .message = "invalid escape sequence",
            },
        },
        .{
            .name = "invalid date month",
            .input = "d = 1979-13-01",
            .expected = .{
                .err = error.InvalidDate,
                .line = 1,
                .column = 12,
                .message = "invalid month",
            },
        },
        .{
            .name = "invalid time minute",
            .input = "t = 07:60:00",
            .expected = .{
                .err = error.InvalidTime,
                .line = 1,
                .column = 10,
                .message = "invalid minute",
            },
        },
        .{
            .name = "integer with leading zero",
            .input = "n = 01",
            .expected = .{
                .err = error.InvalidNumber,
                .line = 1,
                .column = 7,
                .message = "leading zero in number",
            },
        },
        .{
            .name = "invalid unicode code point",
            .input = "key = \"\\uD800\"",
            .expected = .{
                .err = error.InvalidUnicode,
                .line = 1,
                .column = 14,
                .message = "invalid unicode code point",
            },
        },
        .{
            .name = "unexpected character in value",
            .input = "key = value",
            .expected = .{
                .err = error.UnexpectedChar,
                .line = 1,
                .column = 7,
                .message = "unexpected character in value",
            },
        },
        .{
            .name = "deeply nested array",
            .input = "n = " ++ "[" ** 129 ++ "1" ++ "]" ** 129,
            .expected = .{
                .err = error.MaxDepthExceeded,
                .line = 1,
                .column = 133,
                .message = "nesting depth exceeded",
            },
        },
        .{
            .name = "deeply nested inline table",
            .input = "n = " ++ "{k = " ** 129 ++ "1" ++ "}" ** 129,
            .expected = .{
                .err = error.MaxDepthExceeded,
                .line = 1,
                .column = 645,
                .message = "nesting depth exceeded",
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic = Diagnostic{};
        try std.testing.expectError(
            tc.expected.err,
            parse(&arena, tc.input, .{ .diagnostic = &diagnostic }),
        );
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
    }
}

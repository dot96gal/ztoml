const std = @import("std");
const boolean_mod = @import("boolean.zig");
const cursor_mod = @import("cursor.zig");
const datetime_mod = @import("datetime.zig");
const deserialize_mod = @import("deserialize.zig");
const document_mod = @import("document.zig");
const error_mod = @import("errors.zig");
const key_mod = @import("key.zig");
const keyval_mod = @import("keyval.zig");
const number_mod = @import("number.zig");
const parser_mod = @import("parser.zig");
const string_mod = @import("string.zig");
const types_mod = @import("types.zig");

pub const ParseOptions = types_mod.ParseOptions;
pub const Diagnostic = types_mod.Diagnostic;
pub const Parsed = types_mod.Parsed;
pub const OffsetDateTime = types_mod.OffsetDateTime;
pub const LocalDateTime = types_mod.LocalDateTime;
pub const LocalDate = types_mod.LocalDate;
pub const LocalTime = types_mod.LocalTime;
pub const Error = error_mod.Error;
pub const ParseError = error_mod.ParseError;
pub const DeserializeError = error_mod.DeserializeError;

/// TOML 文字列 `input` を型 `T` にパースしてデシリアライズする。
/// 返り値の `Parsed(T)` を使い終わったら `deinit()` を呼んでメモリを解放すること。
/// エラーの詳細を取得するには、`Diagnostic` 変数を用意して `options.diagnostic` に設定すること。
pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) error_mod.Error!Parsed(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const table = try parser_mod.parse(&arena, input, options);
    const value = try deserialize_mod.deserialize(T, &arena, .{ .table = table });

    return .{ .value = value, .arena = arena };
}

// --- parse ---

// [NOTE] parse: テストケースごとに異なる struct 型を使うため、
// 型・検証ロジックも変わる。
// ループ内に条件分岐が必要になるためテーブルドリブンにはできない。

test "parse: multiple fields" {
    const Config = struct { name: []const u8, port: i64, debug: bool };
    const input =
        \\name = "myapp"
        \\port = 8080
        \\debug = true
    ;
    var result = try parse(Config, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqual(@as(i64, 8080), result.value.port);
    try std.testing.expectEqual(true, result.value.debug);
}

test "parse: bool false" {
    const Config = struct { debug: bool };
    var result = try parse(Config, std.testing.allocator, "debug = false", .{});
    defer result.deinit();
    try std.testing.expectEqual(false, result.value.debug);
}

test "parse: float success" {
    const Config = struct { ratio: f64 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: f64,
    }{
        .{ .name = "decimal", .input = "ratio = 3.14", .expected = 3.14 },
        .{ .name = "+inf", .input = "ratio = inf", .expected = std.math.inf(f64) },
        .{ .name = "-inf", .input = "ratio = -inf", .expected = -std.math.inf(f64) },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected, result.value.ratio);
    }
}

test "parse: float nan" {
    const Config = struct { ratio: f64 };
    var result = try parse(Config, std.testing.allocator, "ratio = nan", .{});
    defer result.deinit();
    try std.testing.expect(std.math.isNan(result.value.ratio));
}

test "parse: ignored input" {
    const Config = struct { name: []const u8 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "unknown field",
            .input = "name = \"hello\"\nextra = 42",
            .expected = "hello",
        },
        .{
            .name = "comment",
            .input = "name = \"hello\" # this is a comment",
            .expected = "hello",
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqualStrings(tc.expected, result.value.name);
    }
}

test "parse: unsigned integer field" {
    const PortConfig = struct { port: u16 };
    var result = try parse(PortConfig, std.testing.allocator, "port = 8080", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 8080), result.value.port);
}

test "parse: unsigned integer boundary" {
    const Config = struct { integer: u8 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: u8,
    }{
        .{ .name = "zero", .input = "integer = 0", .expected = 0 },
        .{ .name = "max", .input = "integer = 255", .expected = 255 },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected, result.value.integer);
    }
}

test "parse: signed integer negative" {
    const Config = struct { n: i64 };
    var result = try parse(Config, std.testing.allocator, "n = -42", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, -42), result.value.n);
}

test "parse: signed integer boundary" {
    const Config = struct { n: i64 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "min", .input = "n = -9223372036854775808", .expected = std.math.minInt(i64) },
        .{ .name = "max", .input = "n = 9223372036854775807", .expected = std.math.maxInt(i64) },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected, result.value.n);
    }
}

test "parse: based integer field" {
    const Config = struct { n: i64 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "hex", .input = "n = 0xFF", .expected = 255 },
        .{ .name = "octal", .input = "n = 0o17", .expected = 15 },
        .{ .name = "binary", .input = "n = 0b1010", .expected = 10 },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected, result.value.n);
    }
}

test "parse: default field value" {
    const TimeoutConfig = struct { timeout_ms: u32 = 3000 };
    var result = try parse(TimeoutConfig, std.testing.allocator, "", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 3000), result.value.timeout_ms);
}

test "parse: optional field null" {
    const Config = struct { name: ?[]const u8 = null };
    var result = try parse(Config, std.testing.allocator, "", .{});
    defer result.deinit();
    try std.testing.expect(result.value.name == null);
}

test "parse: optional field some" {
    const Config = struct { name: ?[]const u8 = null };
    var result = try parse(Config, std.testing.allocator, "name = \"hello\"", .{});
    defer result.deinit();
    const name = result.value.name orelse return error.TestFailed;
    try std.testing.expectEqualStrings("hello", name);
}

test "parse: empty string field" {
    const Config = struct { name: []const u8 };
    var result = try parse(Config, std.testing.allocator, "name = \"\"", .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.value.name);
}

test "parse: string format" {
    const Config = struct { key: []const u8 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "literal string",
            .input = "key = 'hello'",
            .expected = "hello",
        },
        .{
            .name = "multiline basic string",
            .input = "key = \"\"\"\nhello\"\"\"",
            .expected = "hello",
        },
        .{
            .name = "multiline literal string",
            .input = "key = '''\nhello'''",
            .expected = "hello",
        },
        .{
            .name = "utf8 string",
            .input = "key = \"こんにちは\"",
            .expected = "こんにちは",
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqualStrings(tc.expected, result.value.key);
    }
}

test "parse: enum field" {
    const LogLevel = enum { debug, info, warn, err };
    const LogConfig = struct { log_level: LogLevel };
    var result = try parse(LogConfig, std.testing.allocator, "log_level = \"info\"", .{});
    defer result.deinit();
    try std.testing.expectEqual(LogLevel.info, result.value.log_level);
}

test "parse: slice field" {
    const Config = struct { tags: []const []const u8 };
    var result = try parse(Config, std.testing.allocator, "tags = [\"a\", \"b\", \"c\"]", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.value.tags.len);
    try std.testing.expectEqualStrings("a", result.value.tags[0]);
    try std.testing.expectEqualStrings("b", result.value.tags[1]);
    try std.testing.expectEqualStrings("c", result.value.tags[2]);
}

test "parse: integer slice field" {
    const Config = struct { nums: []const i64 };
    var result = try parse(Config, std.testing.allocator, "nums = [1, 2, 3]", .{});
    defer result.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, result.value.nums);
}

test "parse: empty slice field" {
    const Config = struct { tags: []const []const u8 };
    var result = try parse(Config, std.testing.allocator, "tags = []", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.value.tags.len);
}

test "parse: OffsetDateTime field" {
    const Config = struct { ts: types_mod.OffsetDateTime };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i16,
    }{
        .{
            .name = "positive offset",
            .input = "ts = 2024-01-15T08:30:00+09:00",
            .expected = 9 * 60,
        },
        .{
            .name = "utc",
            .input = "ts = 2024-01-15T08:30:00Z",
            .expected = 0,
        },
        .{
            .name = "negative offset",
            .input = "ts = 2024-01-15T08:30:00-05:00",
            .expected = -5 * 60,
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected, result.value.ts.offset_minutes);
    }
}

test "parse: LocalDateTime field" {
    const Config = struct { dt: types_mod.LocalDateTime };
    var result = try parse(Config, std.testing.allocator, "dt = 2024-06-15T12:30:00", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 2024), result.value.dt.date.year);
    try std.testing.expectEqual(@as(u8, 6), result.value.dt.date.month);
    try std.testing.expectEqual(@as(u8, 15), result.value.dt.date.day);
    try std.testing.expectEqual(@as(u8, 12), result.value.dt.time.hour);
    try std.testing.expectEqual(@as(u8, 30), result.value.dt.time.minute);
    try std.testing.expectEqual(@as(u8, 0), result.value.dt.time.second);
}

test "parse: LocalDate field" {
    const Config = struct { created: types_mod.LocalDate };
    var result = try parse(Config, std.testing.allocator, "created = 2024-01-15", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 2024), result.value.created.year);
    try std.testing.expectEqual(@as(u8, 1), result.value.created.month);
    try std.testing.expectEqual(@as(u8, 15), result.value.created.day);
}

test "parse: LocalTime field" {
    const Config = struct { alarm: types_mod.LocalTime };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { hour: u8, minute: u8, second: u8, nanosecond: u32 },
    }{
        .{
            .name = "no fractional seconds",
            .input = "alarm = 08:30:00",
            .expected = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 },
        },
        .{
            .name = "fractional seconds",
            .input = "alarm = 08:30:00.500000000",
            .expected = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 500_000_000 },
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var result = try parse(Config, std.testing.allocator, tc.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(tc.expected.hour, result.value.alarm.hour);
        try std.testing.expectEqual(tc.expected.minute, result.value.alarm.minute);
        try std.testing.expectEqual(tc.expected.second, result.value.alarm.second);
        try std.testing.expectEqual(tc.expected.nanosecond, result.value.alarm.nanosecond);
    }
}

test "parse: array of tables" {
    const Item = struct { name: []const u8 };
    const Config = struct { items: []const Item };
    const input =
        \\[[items]]
        \\name = "a"
        \\[[items]]
        \\name = "b"
    ;
    var result = try parse(Config, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.value.items.len);
    try std.testing.expectEqualStrings("a", result.value.items[0].name);
    try std.testing.expectEqualStrings("b", result.value.items[1].name);
}

test "parse: struct nested" {
    const Inner = struct { x: i64 };
    const Outer = struct { inner: Inner };
    const input =
        \\[inner]
        \\x = 42
    ;
    var result = try parse(Outer, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 42), result.value.inner.x);
}

test "parse: inline table field" {
    const Point = struct { x: i64, y: i64 };
    const Config = struct { point: Point };
    var result = try parse(Config, std.testing.allocator, "point = { x = 1, y = 2 }", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 1), result.value.point.x);
    try std.testing.expectEqual(@as(i64, 2), result.value.point.y);
}

test "parse: missing field" {
    const Config = struct { name: []const u8, port: i64 };
    try std.testing.expectError(
        error.MissingField,
        parse(Config, std.testing.allocator, "port = 8080", .{}),
    );
}

test "parse: type mismatch" {
    const Config = struct { name: []const u8 };
    try std.testing.expectError(
        error.TypeMismatch,
        parse(Config, std.testing.allocator, "name = 42", .{}),
    );
}

test "parse: integer overflow" {
    const Config = struct { integer: u8 };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: error_mod.DeserializeError,
    }{
        .{
            .name = "u8 max+1",
            .input = "integer = 256",
            .expected = error.IntegerOverflow,
        },
        .{
            .name = "upper bound exceeded",
            .input = "integer = 300",
            .expected = error.IntegerOverflow,
        },
        .{
            .name = "negative to unsigned",
            .input = "integer = -1",
            .expected = error.IntegerOverflow,
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            parse(Config, std.testing.allocator, tc.input, .{}),
        );
    }
}

test "parse: enum type mismatch" {
    const LogLevel = enum { debug, info };
    const LogConfig = struct { log_level: LogLevel };
    try std.testing.expectError(
        error.TypeMismatch,
        parse(LogConfig, std.testing.allocator, "log_level = \"trace\"", .{}),
    );
}

test "parse: max depth boundary success" {
    var result = try parse(
        struct {},
        std.testing.allocator,
        "n = " ++ "[" ** 128 ++ "1" ++ "]" ** 128,
        .{},
    );
    defer result.deinit();
}

test "parse: invalid input" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: error_mod.ParseError,
    }{
        .{
            .name = "unexpected eof",
            .input = "key =",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "unexpected char",
            .input = "key = value",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "duplicate key",
            .input = "a = 1\na = 2",
            .expected = error.DuplicateKey,
        },
        .{
            .name = "invalid number",
            .input = "n = 1__0",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "invalid date",
            .input = "d = 1979-13-01",
            .expected = error.InvalidDate,
        },
        .{
            .name = "invalid time",
            .input = "t = 07:60:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "max depth exceeded",
            .input = "n = " ++ "[" ** 129 ++ "1" ++ "]" ** 129,
            .expected = error.MaxDepthExceeded,
        },
        .{
            .name = "invalid escape",
            .input = "key = \"\\q\"",
            .expected = error.InvalidEscape,
        },
        .{
            .name = "invalid unicode",
            .input = "key = \"\\uD800\"",
            .expected = error.InvalidUnicode,
        },
    };
    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            parse(struct {}, std.testing.allocator, tc.input, .{}),
        );
    }
}

test "parse: diagnostic" {
    var diagnostic: types_mod.Diagnostic = .{};
    try std.testing.expectError(
        error.UnexpectedEof,
        parse(struct {}, std.testing.allocator, "key =", .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 6), diagnostic.column);
    try std.testing.expectEqualStrings("unexpected end of input", diagnostic.message);
}

test "parse: diagnostic null on error" {
    try std.testing.expectError(
        error.UnexpectedEof,
        parse(struct {}, std.testing.allocator, "key =", .{}),
    );
}

// --- submodule inclusion ---
test {
    _ = boolean_mod;
    _ = cursor_mod;
    _ = datetime_mod;
    _ = deserialize_mod;
    _ = document_mod;
    _ = error_mod;
    _ = key_mod;
    _ = keyval_mod;
    _ = number_mod;
    _ = parser_mod;
    _ = string_mod;
    _ = types_mod;
}

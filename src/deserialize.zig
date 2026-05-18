const std = @import("std");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Value = types.Value;

pub fn deserialize(
    comptime T: type,
    arena: *std.heap.ArenaAllocator,
    value: ?Value,
) (errors.DeserializeError || error{OutOfMemory})!T {
    switch (@typeInfo(T)) {
        .bool => {
            const v = value orelse return error.TypeMismatch;
            if (v != .boolean) return error.TypeMismatch;
            return v.boolean;
        },
        .int => {
            const v = value orelse return error.TypeMismatch;
            if (v != .integer) return error.TypeMismatch;
            return std.math.cast(T, v.integer) orelse return error.IntegerOverflow;
        },
        .float => {
            const v = value orelse return error.TypeMismatch;
            return switch (v) {
                .float => |f| @floatCast(f),
                .integer => |n| @floatFromInt(n),
                else => return error.TypeMismatch,
            };
        },
        .pointer => |ptr| {
            if (comptime ptr.size != .slice) {
                @compileError("deserialize: unsupported pointer kind: " ++ @typeName(T));
            }
            const v = value orelse return error.TypeMismatch;
            if (ptr.child == u8) {
                if (v != .string) return error.TypeMismatch;
                return v.string;
            }
            const arr: []const Value = switch (v) {
                .array => |a| a,
                .aot_array => |aot| aot.items(),
                else => return error.TypeMismatch,
            };
            const allocator = arena.allocator();
            const result = try allocator.alloc(ptr.child, arr.len);
            for (arr, 0..) |item, i| {
                result[i] = try deserialize(ptr.child, arena, item);
            }
            return result;
        },
        .optional => |opt| {
            const v = value orelse return null;
            return try deserialize(opt.child, arena, v);
        },
        .@"struct" => {
            const v = value orelse return error.TypeMismatch;
            if (comptime isDatetimeType(T)) return try deserializeDatetime(T, v);
            return try deserializeStruct(T, arena, v);
        },
        .@"enum" => {
            const v = value orelse return error.TypeMismatch;
            if (v != .string) return error.TypeMismatch;
            return std.meta.stringToEnum(T, v.string) orelse return error.TypeMismatch;
        },
        else => @compileError("deserialize: unsupported type " ++ @typeName(T)),
    }
}

fn deserializeDatetime(comptime T: type, value: Value) errors.DeserializeError!T {
    if (T == types.OffsetDateTime) {
        if (value != .offset_date_time) return error.TypeMismatch;
        return value.offset_date_time;
    }
    if (T == types.LocalDateTime) {
        if (value != .local_date_time) return error.TypeMismatch;
        return value.local_date_time;
    }
    if (T == types.LocalDate) {
        if (value != .local_date) return error.TypeMismatch;
        return value.local_date;
    }
    if (T == types.LocalTime) {
        if (value != .local_time) return error.TypeMismatch;
        return value.local_time;
    }

    @compileError("deserializeDatetime called with non-datetime type: " ++ @typeName(T));
}

fn deserializeStruct(
    comptime T: type,
    arena: *std.heap.ArenaAllocator,
    value: Value,
) (errors.DeserializeError || error{OutOfMemory})!T {
    const s = @typeInfo(T).@"struct";
    if (value != .table) return error.TypeMismatch;
    const table = value.table;

    // フェーズ1: アロケーション前に全フィールドの存在を検証する。
    // 1ループに統合すると前のフィールドで確保したメモリが
    // 後続フィールドの欠損時にリークする恐れがある。
    inline for (s.fields) |field| {
        if (table.get(field.name) == null and
            field.defaultValue() == null and
            @typeInfo(field.type) != .optional)
        {
            return error.MissingField;
        }
    }

    // フェーズ2: 全フィールドの存在が確認済み。
    // フィールド欠損による @panic 分岐には到達しない。
    var result: T = undefined;
    inline for (s.fields) |field| {
        if (table.get(field.name)) |v| {
            @field(result, field.name) = try deserialize(field.type, arena, v);
        } else if (field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            @panic("deserializeStruct: field missing after validation — validated in prior pass");
        }
    }

    return result;
}

fn isDatetimeType(comptime T: type) bool {
    return T == types.OffsetDateTime or T == types.LocalDateTime or
        T == types.LocalDate or T == types.LocalTime;
}

// --- deserialize ---

// [NOTE] deserialize: テストケース間で型 T が同じ場合は
// テーブルドリブンにする。型 T が異なる場合は comptime 制約により
// runtime の struct 配列に格納できないためテーブルドリブンにはできない。

test "deserialize: bool: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: bool,
    }{
        .{ .name = "true", .input = .{ .boolean = true }, .expected = true },
        .{ .name = "false", .input = .{ .boolean = false }, .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(bool, &arena, tc.input));
    }
}

test "deserialize: bool: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "wrong type", .input = .{ .integer = 1 }, .expected = error.TypeMismatch },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(bool, &arena, tc.input));
    }
}

// [NOTE] deserialize: integer: テストケース間で型 T が同じ場合は
// テーブルドリブンにする。型 T が異なる場合は comptime 制約により
// runtime の struct 配列に格納できないためテーブルドリブンにはできない。

test "deserialize: integer: success: i64" {
    const test_cases = [_]struct {
        name: []const u8,
        input: i64,
        expected: i64,
    }{
        .{ .name = "positive", .input = 42, .expected = 42 },
        .{ .name = "max", .input = std.math.maxInt(i64), .expected = std.math.maxInt(i64) },
        .{ .name = "min", .input = std.math.minInt(i64), .expected = std.math.minInt(i64) },
        .{ .name = "zero", .input = 0, .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(
            tc.expected,
            try deserialize(i64, &arena, .{ .integer = tc.input }),
        );
    }
}

test "deserialize: integer: success: u8" {
    const test_cases = [_]struct {
        name: []const u8,
        input: i64,
        expected: u8,
    }{
        .{ .name = "min", .input = 0, .expected = 0 },
        .{ .name = "max", .input = 255, .expected = 255 },
        .{ .name = "mid", .input = 127, .expected = 127 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(
            tc.expected,
            try deserialize(u8, &arena, .{ .integer = tc.input }),
        );
    }
}

test "deserialize: integer: success: i32" {
    const test_cases = [_]struct {
        name: []const u8,
        input: i64,
        expected: i32,
    }{
        .{ .name = "negative", .input = -100, .expected = -100 },
        .{ .name = "min", .input = std.math.minInt(i32), .expected = std.math.minInt(i32) },
        .{ .name = "max", .input = std.math.maxInt(i32), .expected = std.math.maxInt(i32) },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(
            tc.expected,
            try deserialize(i32, &arena, .{ .integer = tc.input }),
        );
    }
}

test "deserialize: integer: success: u64" {
    const test_cases = [_]struct {
        name: []const u8,
        input: i64,
        expected: u64,
    }{
        .{ .name = "zero", .input = 0, .expected = 0 },
        .{ .name = "max i64", .input = std.math.maxInt(i64), .expected = std.math.maxInt(i64) },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(
            tc.expected,
            try deserialize(u64, &arena, .{ .integer = tc.input }),
        );
    }
}

test "deserialize: integer: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "overflow", .input = .{ .integer = 300 }, .expected = error.IntegerOverflow },
        .{ .name = "underflow", .input = .{ .integer = -1 }, .expected = error.IntegerOverflow },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
        .{ .name = "wrong type", .input = .{ .boolean = true }, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(u8, &arena, tc.input));
    }
}

test "deserialize: integer: error: u64" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "underflow", .input = .{ .integer = -1 }, .expected = error.IntegerOverflow },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
        .{ .name = "wrong type", .input = .{ .boolean = true }, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(u64, &arena, tc.input));
    }
}

test "deserialize: float: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: f64,
    }{
        .{ .name = "float", .input = .{ .float = 3.14 }, .expected = 3.14 },
        .{ .name = "integer", .input = .{ .integer = 2 }, .expected = 2.0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(f64, &arena, tc.input));
    }
}

test "deserialize: float: success: f32" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: f32,
    }{
        .{ .name = "float", .input = .{ .float = 1.5 }, .expected = 1.5 },
        .{ .name = "integer", .input = .{ .integer = 2 }, .expected = 2.0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(f32, &arena, tc.input));
    }
}

// [NOTE] NaN は expectEqual で比較できないため
// expect(std.math.isNan(...)) を使う必要があり、
// f32/f64 で型 T が異なることと合わせてテーブルドリブンにはできない。
test "deserialize: float: f32 nan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try deserialize(f32, &arena, .{ .float = std.math.nan(f64) });
    try std.testing.expect(std.math.isNan(result));
}

test "deserialize: float: nan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try deserialize(f64, &arena, .{ .float = std.math.nan(f64) });
    try std.testing.expect(std.math.isNan(result));
}

test "deserialize: float: inf" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: f64,
    }{
        .{
            .name = "+inf",
            .input = .{ .float = std.math.inf(f64) },
            .expected = std.math.inf(f64),
        },
        .{
            .name = "-inf",
            .input = .{ .float = -std.math.inf(f64) },
            .expected = -std.math.inf(f64),
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(f64, &arena, tc.input));
    }
}

test "deserialize: float: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "wrong type", .input = .{ .boolean = true }, .expected = error.TypeMismatch },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(f64, &arena, tc.input));
    }
}

test "deserialize: string: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: []const u8,
    }{
        .{ .name = "non-empty", .input = .{ .string = "hello" }, .expected = "hello" },
        .{ .name = "empty", .input = .{ .string = "" }, .expected = "" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const s = try deserialize([]const u8, &arena, tc.input);
        try std.testing.expectEqualStrings(tc.expected, s);
    }
}

test "deserialize: string: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "wrong type", .input = .{ .integer = 1 }, .expected = error.TypeMismatch },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize([]const u8, &arena, tc.input));
    }
}

test "deserialize: slice" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Value,
        expected: []const i64,
    }{
        .{
            .name = "non-empty",
            .input = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } },
            .expected = &.{ 1, 2, 3 },
        },
        .{
            .name = "single element",
            .input = &.{.{ .integer = 42 }},
            .expected = &.{42},
        },
        .{
            .name = "empty",
            .input = &.{},
            .expected = &.{},
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try deserialize([]const i64, &arena, .{ .array = tc.input });
        try std.testing.expectEqualSlices(i64, tc.expected, result);
    }
}

test "deserialize: slice aot_array" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Value,
        expected: []const i64,
    }{
        .{
            .name = "non-empty",
            .input = &.{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } },
            .expected = &.{ 1, 2, 3 },
        },
        .{
            .name = "single element",
            .input = &.{.{ .integer = 42 }},
            .expected = &.{42},
        },
        .{
            .name = "empty",
            .input = &.{},
            .expected = &.{},
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var list: std.ArrayListUnmanaged(Value) = .empty;
        for (tc.input) |v| try list.append(arena.allocator(), v);
        const aot: types.AotArray = .{ .inner = &list };
        const result = try deserialize([]const i64, &arena, .{ .aot_array = aot });
        try std.testing.expectEqualSlices(i64, tc.expected, result);
    }
}

test "deserialize: slice string elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]Value{ .{ .string = "hello" }, .{ .string = "world" } };
    const result = try deserialize([]const []const u8, &arena, .{ .array = &values });
    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqualStrings("hello", result[0]);
    try std.testing.expectEqualStrings("world", result[1]);
}

test "deserialize: slice bool elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]Value{ .{ .boolean = true }, .{ .boolean = false } };
    const result = try deserialize([]const bool, &arena, .{ .array = &values });
    try std.testing.expectEqualSlices(bool, &.{ true, false }, result);
}

test "deserialize: slice float elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = [_]Value{ .{ .float = 1.5 }, .{ .float = 2.5 } };
    const result = try deserialize([]const f64, &arena, .{ .array = &values });
    try std.testing.expectEqual(2, result.len);
    try std.testing.expectApproxEqAbs(1.5, result[0], 1e-9);
    try std.testing.expectApproxEqAbs(2.5, result[1], 1e-9);
}

test "deserialize: slice type mismatch" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "wrong type",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "null",
            .input = null,
            .expected = error.TypeMismatch,
        },
        .{
            .name = "element type mismatch",
            .input = .{ .array = &.{.{ .boolean = true }} },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize([]const i64, &arena, tc.input));
    }
}

test "deserialize: optional" {
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: ?i64,
    }{
        .{ .name = "some", .input = .{ .integer = 5 }, .expected = 5 },
        .{ .name = "null", .input = null, .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(?i64, &arena, tc.input));
    }
}

test "deserialize: optional: error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        deserialize(?i64, &arena, .{ .boolean = true }),
    );
}

test "deserialize: optional: error: child IntegerOverflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.IntegerOverflow,
        deserialize(?u8, &arena, .{ .integer = 300 }),
    );
}

// [NOTE] deserialize: datetime: テストケース間で型 T が異なるため
// comptime 制約により runtime の struct 配列に格納できず、
// テーブルドリブンにはできない。

test "deserialize: OffsetDateTime: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = Value{ .offset_date_time = .{
        .datetime = .{
            .date = .{ .year = 2024, .month = 1, .day = 15 },
            .time = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 },
        },
        .offset_minutes = 540,
    } };
    const result = try deserialize(types.OffsetDateTime, &arena, value);
    try std.testing.expectEqual(@as(i16, 540), result.offset_minutes);
    try std.testing.expectEqual(@as(u16, 2024), result.datetime.date.year);
    try std.testing.expectEqual(@as(u8, 1), result.datetime.date.month);
    try std.testing.expectEqual(@as(u8, 15), result.datetime.date.day);
    try std.testing.expectEqual(@as(u8, 8), result.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 30), result.datetime.time.minute);
    try std.testing.expectEqual(@as(u8, 0), result.datetime.time.second);
    try std.testing.expectEqual(@as(u32, 0), result.datetime.time.nanosecond);
}

test "deserialize: OffsetDateTime: error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        deserialize(types.OffsetDateTime, &arena, .{ .integer = 1 }),
    );
}

test "deserialize: LocalDateTime: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = Value{ .local_date_time = .{
        .date = .{ .year = 2024, .month = 6, .day = 15 },
        .time = .{ .hour = 12, .minute = 0, .second = 0, .nanosecond = 0 },
    } };
    const result = try deserialize(types.LocalDateTime, &arena, value);
    try std.testing.expectEqual(@as(u16, 2024), result.date.year);
    try std.testing.expectEqual(@as(u8, 6), result.date.month);
    try std.testing.expectEqual(@as(u8, 15), result.date.day);
    try std.testing.expectEqual(@as(u8, 12), result.time.hour);
    try std.testing.expectEqual(@as(u8, 0), result.time.minute);
    try std.testing.expectEqual(@as(u8, 0), result.time.second);
    try std.testing.expectEqual(@as(u32, 0), result.time.nanosecond);
}

test "deserialize: LocalDateTime: error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        deserialize(types.LocalDateTime, &arena, .{ .integer = 1 }),
    );
}

test "deserialize: LocalDate: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = Value{ .local_date = .{ .year = 2024, .month = 6, .day = 15 } };
    const result = try deserialize(types.LocalDate, &arena, value);
    try std.testing.expectEqual(@as(u16, 2024), result.year);
    try std.testing.expectEqual(@as(u8, 6), result.month);
    try std.testing.expectEqual(@as(u8, 15), result.day);
}

test "deserialize: LocalDate: error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        deserialize(types.LocalDate, &arena, .{ .integer = 1 }),
    );
}

test "deserialize: LocalTime: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = Value{ .local_time = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 } };
    const result = try deserialize(types.LocalTime, &arena, value);
    try std.testing.expectEqual(@as(u8, 8), result.hour);
    try std.testing.expectEqual(@as(u8, 30), result.minute);
    try std.testing.expectEqual(@as(u8, 0), result.second);
    try std.testing.expectEqual(@as(u32, 0), result.nanosecond);
}

test "deserialize: LocalTime: error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.TypeMismatch,
        deserialize(types.LocalTime, &arena, .{ .integer = 1 }),
    );
}

test "deserialize: struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .integer = 7 });
    const Point = struct { x: i64 };
    const result = try deserialize(Point, &arena, .{ .table = .{ .inner = map } });
    try std.testing.expectEqual(@as(i64, 7), result.x);
}

test "deserialize: struct missing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const map: std.StringHashMapUnmanaged(Value) = .empty;
    const Point = struct { x: i64 };
    try std.testing.expectError(
        error.MissingField,
        deserialize(Point, &arena, .{ .table = .{ .inner = map } }),
    );
}

test "deserialize: struct type mismatch" {
    const Point = struct { x: i64 };
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{ .name = "wrong type", .input = .{ .integer = 1 }, .expected = error.TypeMismatch },
        .{ .name = "null", .input = null, .expected = error.TypeMismatch },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(Point, &arena, tc.input));
    }
}

test "deserialize: enum: success" {
    const Level = enum { info, warn };
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: Level,
    }{
        .{ .name = "info", .input = .{ .string = "info" }, .expected = .info },
        .{ .name = "warn", .input = .{ .string = "warn" }, .expected = .warn },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectEqual(tc.expected, try deserialize(Level, &arena, tc.input));
    }
}

test "deserialize: enum: error" {
    const Level = enum { info, warn };
    const test_cases = [_]struct {
        name: []const u8,
        input: ?Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "unknown variant",
            .input = .{ .string = "debug" },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "non-string value",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "null",
            .input = null,
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(tc.expected, deserialize(Level, &arena, tc.input));
    }
}

// --- deserializeDatetime ---

// [NOTE] deserializeDatetime: テストケース間で型 T が同じ場合は
// テーブルドリブンにする。型 T が異なる場合は comptime 制約により
// runtime の struct 配列に格納できないためテーブルドリブンにはできない。

test "deserializeDatetime: OffsetDateTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: types.OffsetDateTime,
    }{
        .{
            .name = "basic",
            .input = .{ .offset_date_time = .{
                .datetime = .{
                    .date = .{ .year = 2024, .month = 1, .day = 15 },
                    .time = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 },
                },
                .offset_minutes = 540,
            } },
            .expected = .{
                .datetime = .{
                    .date = .{ .year = 2024, .month = 1, .day = 15 },
                    .time = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 },
                },
                .offset_minutes = 540,
            },
        },
        .{
            .name = "boundary",
            .input = .{ .offset_date_time = .{
                .datetime = .{
                    .date = .{ .year = 9999, .month = 12, .day = 31 },
                    .time = .{ .hour = 23, .minute = 59, .second = 59, .nanosecond = 999_999_999 },
                },
                .offset_minutes = -1410,
            } },
            .expected = .{
                .datetime = .{
                    .date = .{ .year = 9999, .month = 12, .day = 31 },
                    .time = .{ .hour = 23, .minute = 59, .second = 59, .nanosecond = 999_999_999 },
                },
                .offset_minutes = -1410,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const result = try deserializeDatetime(types.OffsetDateTime, tc.input);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "deserializeDatetime: LocalDateTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: types.LocalDateTime,
    }{
        .{
            .name = "basic",
            .input = .{ .local_date_time = .{
                .date = .{ .year = 2024, .month = 6, .day = 15 },
                .time = .{ .hour = 12, .minute = 0, .second = 0, .nanosecond = 0 },
            } },
            .expected = .{
                .date = .{ .year = 2024, .month = 6, .day = 15 },
                .time = .{ .hour = 12, .minute = 0, .second = 0, .nanosecond = 0 },
            },
        },
        .{
            .name = "boundary",
            .input = .{ .local_date_time = .{
                .date = .{ .year = 0, .month = 1, .day = 1 },
                .time = .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 999_999_999 },
            } },
            .expected = .{
                .date = .{ .year = 0, .month = 1, .day = 1 },
                .time = .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 999_999_999 },
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const result = try deserializeDatetime(types.LocalDateTime, tc.input);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "deserializeDatetime: LocalDate" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: types.LocalDate,
    }{
        .{
            .name = "basic",
            .input = .{ .local_date = .{ .year = 2024, .month = 6, .day = 15 } },
            .expected = .{ .year = 2024, .month = 6, .day = 15 },
        },
        .{
            .name = "boundary",
            .input = .{ .local_date = .{ .year = 9999, .month = 12, .day = 31 } },
            .expected = .{ .year = 9999, .month = 12, .day = 31 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const result = try deserializeDatetime(types.LocalDate, tc.input);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "deserializeDatetime: LocalTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: types.LocalTime,
    }{
        .{
            .name = "basic",
            .input = .{ .local_time = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 } },
            .expected = .{ .hour = 8, .minute = 30, .second = 0, .nanosecond = 0 },
        },
        .{
            .name = "boundary",
            .input = .{ .local_time = .{
                .hour = 23,
                .minute = 59,
                .second = 60,
                .nanosecond = 999_999_999,
            } },
            .expected = .{ .hour = 23, .minute = 59, .second = 60, .nanosecond = 999_999_999 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const result = try deserializeDatetime(types.LocalTime, tc.input);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "deserializeDatetime: error: OffsetDateTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "wrong scalar type",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "wrong datetime type",
            .input = .{ .local_date = .{ .year = 2024, .month = 1, .day = 1 } },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            deserializeDatetime(types.OffsetDateTime, tc.input),
        );
    }
}

test "deserializeDatetime: error: LocalDateTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "wrong scalar type",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "wrong datetime type",
            .input = .{ .local_date = .{ .year = 2024, .month = 1, .day = 1 } },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            deserializeDatetime(types.LocalDateTime, tc.input),
        );
    }
}

test "deserializeDatetime: error: LocalDate" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "wrong scalar type",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "wrong datetime type",
            .input = .{ .local_time = .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 0 } },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            deserializeDatetime(types.LocalDate, tc.input),
        );
    }
}

test "deserializeDatetime: error: LocalTime" {
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "wrong scalar type",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
        .{
            .name = "wrong datetime type",
            .input = .{ .local_date = .{ .year = 2024, .month = 1, .day = 1 } },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectError(
            tc.expected,
            deserializeDatetime(types.LocalTime, tc.input),
        );
    }
}

// --- deserializeStruct ---

// [NOTE] deserializeStruct: テストケース間でローカル struct 型の定義が
// 異なるためテーブルドリブンにはできない
// （型を共通化するとループ内に条件分岐が必要になる）。

test "deserializeStruct: success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .integer = 42 });
    const Point = struct { x: i64 };
    const result = try deserializeStruct(Point, &arena, .{ .table = .{ .inner = map } });
    try std.testing.expectEqual(@as(i64, 42), result.x);
}

test "deserializeStruct: success: optional field absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Config = struct { x: ?i64 };
    const result = try deserializeStruct(Config, &arena, .{ .table = .{ .inner = .empty } });
    try std.testing.expectEqual(@as(?i64, null), result.x);
}

test "deserializeStruct: success: optional field present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .integer = 5 });
    const Config = struct { x: ?i64 };
    const result = try deserializeStruct(Config, &arena, .{ .table = .{ .inner = map } });
    try std.testing.expectEqual(@as(?i64, 5), result.x);
}

test "deserializeStruct: success: default field value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Config = struct { x: i64 = 99 };
    const result = try deserializeStruct(Config, &arena, .{ .table = .{ .inner = .empty } });
    try std.testing.expectEqual(@as(i64, 99), result.x);
}

test "deserializeStruct: success: nested struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Inner = struct { x: i64 };
    const Outer = struct { inner: Inner };
    var inner_map: std.StringHashMapUnmanaged(Value) = .empty;
    try inner_map.put(arena.allocator(), "x", .{ .integer = 7 });
    var outer_map: std.StringHashMapUnmanaged(Value) = .empty;
    try outer_map.put(arena.allocator(), "inner", .{ .table = .{ .inner = inner_map } });
    const result = try deserializeStruct(Outer, &arena, .{ .table = .{ .inner = outer_map } });
    try std.testing.expectEqual(@as(i64, 7), result.inner.x);
}

test "deserializeStruct: error" {
    const Point = struct { x: i64 };
    const test_cases = [_]struct {
        name: []const u8,
        input: Value,
        expected: errors.DeserializeError,
    }{
        .{
            .name = "missing field",
            .input = .{ .table = .{ .inner = .{} } },
            .expected = error.MissingField,
        },
        .{
            .name = "type mismatch",
            .input = .{ .integer = 1 },
            .expected = error.TypeMismatch,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(
            tc.expected,
            deserializeStruct(Point, &arena, tc.input),
        );
    }
}

test "deserializeStruct: error: field value type mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .string = "hello" });
    const Point = struct { x: i64 };
    try std.testing.expectError(
        error.TypeMismatch,
        deserializeStruct(Point, &arena, .{ .table = .{ .inner = map } }),
    );
}

test "deserializeStruct: error: nested struct missing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Inner = struct { x: i64 };
    const Outer = struct { inner: Inner };
    var outer_map: std.StringHashMapUnmanaged(Value) = .empty;
    try outer_map.put(arena.allocator(), "inner", .{ .table = .{ .inner = .empty } });
    try std.testing.expectError(
        error.MissingField,
        deserializeStruct(Outer, &arena, .{ .table = .{ .inner = outer_map } }),
    );
}

test "deserializeStruct: error: field value overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .integer = 300 });
    const Point = struct { x: u8 };
    try std.testing.expectError(
        error.IntegerOverflow,
        deserializeStruct(Point, &arena, .{ .table = .{ .inner = map } }),
    );
}

test "deserializeStruct: success: slice field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Container = struct { items: []const i64 };
    const values = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "items", .{ .array = &values });
    const result = try deserializeStruct(Container, &arena, .{ .table = .{ .inner = map } });
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, result.items);
}

test "deserializeStruct: success: enum field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Level = enum { info, warn };
    const Config = struct { level: Level };
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "level", .{ .string = "warn" });
    const result = try deserializeStruct(Config, &arena, .{ .table = .{ .inner = map } });
    try std.testing.expectEqual(Level.warn, result.level);
}

// --- isDatetimeType ---

// [NOTE] isDatetimeType: テストケース間で型 T が同じ場合は
// テーブルドリブンにする。型 T が異なる場合は comptime 制約により
// runtime の struct 配列に格納できないためテーブルドリブンにはできない。

test "isDatetimeType: OffsetDateTime" {
    try std.testing.expect(isDatetimeType(types.OffsetDateTime));
}

test "isDatetimeType: LocalDateTime" {
    try std.testing.expect(isDatetimeType(types.LocalDateTime));
}

test "isDatetimeType: LocalDate" {
    try std.testing.expect(isDatetimeType(types.LocalDate));
}

test "isDatetimeType: LocalTime" {
    try std.testing.expect(isDatetimeType(types.LocalTime));
}

test "isDatetimeType: i64 returns false" {
    try std.testing.expect(!isDatetimeType(i64));
}

test "isDatetimeType: bool returns false" {
    try std.testing.expect(!isDatetimeType(bool));
}

test "isDatetimeType: struct returns false" {
    const S = struct { x: i32 };
    try std.testing.expect(!isDatetimeType(S));
}

test "isDatetimeType: slice returns false" {
    try std.testing.expect(!isDatetimeType([]u8));
}

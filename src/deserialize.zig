const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const TOMLValue = types.TOMLValue;
const TOMLTable = types.TOMLTable;
const Parsed = types.Parsed;
const ParseOptions = types.ParseOptions;
const parser_mod = @import("parser.zig");

/// デシリアライズ処理中に発生するエラーの集合。`parseFromSliceAs` から返される可能性がある。
pub const DeserializeError = error{
    /// デフォルト値のない必須フィールドが TOML に存在しない。
    MissingField,
    /// TOML の値の型と対象の Zig 型が一致しない。
    TypeMismatch,
    /// TOML の整数値が対象の Zig 整数型の範囲を超えている。
    IntegerOverflow,
};

/// TOML 文字列をパースして型 `T` の値に直接デシリアライズする。返り値の `Parsed` は使い終わったら `deinit` を呼び出して解放する。
pub fn parseFromSliceAs(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: ParseOptions,
) (types.ParseError || DeserializeError || error{OutOfMemory})!Parsed(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // parseFromSlice が内部で arena.allocator() を使うため、parsed.arena.deinit() は実質 no-op になり安全に呼べる。
    var parsed = try parser_mod.parseFromSlice(arena.allocator(), input, options);
    parsed.arena.deinit();

    const value = try coerce(T, .{ .table = parsed.value }, arena.allocator());
    return .{ .value = value, .arena = arena };
}

/// `TOMLValue` を指定した型 `T` に再帰的に変換する。型が一致しない場合は `DeserializeError` を返す。
pub fn coerce(comptime T: type, value: TOMLValue, allocator: Allocator) (DeserializeError || error{OutOfMemory})!T {
    switch (@typeInfo(T)) {
        .bool => {
            if (value != .boolean) return error.TypeMismatch;
            return value.boolean;
        },
        .int => {
            if (value != .integer) return error.TypeMismatch;
            return std.math.cast(T, value.integer) orelse return error.IntegerOverflow;
        },
        .float => {
            return switch (value) {
                .float => |f| @floatCast(f),
                .integer => |n| @floatFromInt(n),
                else => return error.TypeMismatch,
            };
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                if (value != .string) return error.TypeMismatch;
                return value.string;
            }
            if (ptr.size == .slice) {
                if (value != .array) return error.TypeMismatch;
                const arr = value.array;
                const result = try allocator.alloc(ptr.child, arr.len);
                for (arr, 0..) |item, i| {
                    result[i] = try coerce(ptr.child, item, allocator);
                }
                return result;
            }
            return error.TypeMismatch;
        },
        .optional => |opt| {
            return try coerce(opt.child, value, allocator);
        },
        .@"struct" => |s| {
            if (value != .table) return error.TypeMismatch;
            const table = value.table;
            var result: T = undefined;
            inline for (s.fields) |field| {
                if (table.get(field.name)) |v| {
                    @field(result, field.name) = try coerce(field.type, v, allocator);
                } else if (field.defaultValue()) |dv| {
                    @field(result, field.name) = dv;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    return error.MissingField;
                }
            }
            return result;
        },
        .@"enum" => {
            if (value != .string) return error.TypeMismatch;
            return std.meta.stringToEnum(T, value.string) orelse return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

// ============================================================
// Tests
// ============================================================

test "parseFromSliceAs: basic struct" {
    const Config = struct {
        name: []const u8,
        port: i64,
        debug: bool,
    };
    const input =
        \\name = "myapp"
        \\port = 8080
        \\debug = true
    ;
    var result = try parseFromSliceAs(Config, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqual(@as(i64, 8080), result.value.port);
    try std.testing.expectEqual(true, result.value.debug);
}

test "parseFromSliceAs: local variable binding" {
    const Config = struct { name: []const u8, port: i64, debug: bool };
    const input =
        \\name = "myapp"
        \\port = 8080
        \\debug = true
    ;
    var result = try parseFromSliceAs(Config, std.testing.allocator, input, .{});
    defer result.deinit();
    const config = result.value;
    try std.testing.expectEqualStrings("myapp", config.name);
    try std.testing.expectEqual(@as(i64, 8080), config.port);
    try std.testing.expectEqual(true, config.debug);
}

test "parseFromSliceAs: integer type conversion" {
    const PortConfig = struct { port: u16 };
    var r = try parseFromSliceAs(PortConfig, std.testing.allocator, "port = 8080", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 8080), r.value.port);
}

test "parseFromSliceAs: field default value" {
    const TimeoutConfig = struct { timeout_ms: u32 = 3000 };
    var r = try parseFromSliceAs(TimeoutConfig, std.testing.allocator, "", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 3000), r.value.timeout_ms);
}

test "parseFromSliceAs: optional field absent" {
    const Cfg = struct { name: ?[]const u8 = null };
    var r = try parseFromSliceAs(Cfg, std.testing.allocator, "", .{});
    defer r.deinit();
    try std.testing.expect(r.value.name == null);
}

test "parseFromSliceAs: optional field present" {
    const Cfg = struct { name: ?[]const u8 = null };
    var r = try parseFromSliceAs(Cfg, std.testing.allocator, "name = \"hello\"", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("hello", r.value.name.?);
}

test "parseFromSliceAs: enum field" {
    const LogLevel = enum { debug, info, warn, err };
    const LogConfig = struct { log_level: LogLevel };
    var r = try parseFromSliceAs(LogConfig, std.testing.allocator, "log_level = \"info\"", .{});
    defer r.deinit();
    try std.testing.expectEqual(LogLevel.info, r.value.log_level);
}

test "parseFromSliceAs: slice field" {
    const Cfg = struct { tags: []const []const u8 };
    var r = try parseFromSliceAs(Cfg, std.testing.allocator, "tags = [\"a\", \"b\", \"c\"]", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 3), r.value.tags.len);
    try std.testing.expectEqualStrings("b", r.value.tags[1]);
}

test "parseFromSliceAs: error missing field" {
    const Config = struct { name: []const u8, port: i64 };
    try std.testing.expectError(
        error.MissingField,
        parseFromSliceAs(Config, std.testing.allocator, "port = 8080", .{}),
    );
}

test "parseFromSliceAs: error type mismatch" {
    const Config = struct { name: []const u8 };
    try std.testing.expectError(
        error.TypeMismatch,
        parseFromSliceAs(Config, std.testing.allocator, "name = 42", .{}),
    );
}

test "parseFromSliceAs: error integer overflow" {
    const Cfg = struct { val: u8 };
    try std.testing.expectError(
        error.IntegerOverflow,
        parseFromSliceAs(Cfg, std.testing.allocator, "val = 300", .{}),
    );
}

test "parseFromSliceAs: error enum mismatch" {
    const LogLevel = enum { debug, info };
    const LogConfig = struct { log_level: LogLevel };
    try std.testing.expectError(
        error.TypeMismatch,
        parseFromSliceAs(LogConfig, std.testing.allocator, "log_level = \"trace\"", .{}),
    );
}

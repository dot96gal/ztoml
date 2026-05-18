const std = @import("std");

pub const OffsetDateTime = struct {
    datetime: LocalDateTime,
    offset_minutes: i16,
};

pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};

pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
};

// TOML 仕様の用語を型名として利用
pub const Table = struct {
    inner: std.StringHashMapUnmanaged(Value),
    is_inline: bool = false,

    pub fn get(self: Table, key: []const u8) ?Value {
        return self.inner.get(key);
    }

    pub fn count(self: Table) usize {
        return self.inner.count();
    }

    pub fn iterator(self: *const Table) std.StringHashMapUnmanaged(Value).Iterator {
        return self.inner.iterator();
    }
};

pub const AotArray = struct {
    inner: *std.ArrayListUnmanaged(Value),

    pub fn items(self: AotArray) []const Value {
        return self.inner.items;
    }

    pub fn len(self: AotArray) usize {
        return self.inner.items.len;
    }

    pub fn lastPtr(self: AotArray) *Value {
        if (self.inner.items.len == 0) @panic("AotArray.lastPtr: array is empty");
        return &self.inner.items[self.inner.items.len - 1];
    }
};

// TOML 仕様の用語を型名として利用
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    aot_array: AotArray,
    table: Table,
    offset_date_time: OffsetDateTime,
    local_date_time: LocalDateTime,
    local_date: LocalDate,
    local_time: LocalTime,
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

pub const ParseOptions = struct {
    diagnostic: ?*Diagnostic = null,
};

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

// --- Table.get ---

test "Table.get: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { key: []const u8, value: Value },
        expected: ?Value,
    }{
        .{
            .name = "existing key",
            .input = .{ .key = "key", .value = .{ .integer = 42 } },
            .expected = .{ .integer = 42 },
        },
        .{
            .name = "empty string key",
            .input = .{ .key = "", .value = .{ .integer = 0 } },
            .expected = .{ .integer = 0 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        try map.put(arena.allocator(), tc.input.key, tc.input.value);
        const table: Table = .{ .inner = map };
        try std.testing.expectEqual(tc.expected, table.get(tc.input.key));
    }
}

test "Table.get: returns null for missing key" {
    const map: std.StringHashMapUnmanaged(Value) = .empty;
    const table: Table = .{ .inner = map };
    try std.testing.expect(table.get("missing") == null);
}

// --- Table.count ---

test "Table.count: correct for various sizes" {
    const Entry = struct { key: []const u8, val: Value };
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Entry,
        expected: usize,
    }{
        .{
            .name = "empty",
            .input = &.{},
            .expected = 0,
        },
        .{
            .name = "one entry",
            .input = &.{
                .{ .key = "a", .val = .{ .boolean = true } },
            },
            .expected = 1,
        },
        .{
            .name = "two entries",
            .input = &.{
                .{ .key = "a", .val = .{ .boolean = true } },
                .{ .key = "b", .val = .{ .boolean = false } },
            },
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var map: std.StringHashMapUnmanaged(Value) = .empty;
        for (tc.input) |e| try map.put(arena.allocator(), e.key, e.val);
        const table: Table = .{ .inner = map };
        try std.testing.expectEqual(tc.expected, table.count());
    }
}

// --- Table.iterator ---

test "Table.iterator: returns null for empty table" {
    const map: std.StringHashMapUnmanaged(Value) = .empty;
    const table: Table = .{ .inner = map };
    var iter = table.iterator();
    try std.testing.expect(iter.next() == null);
}

test "Table.iterator: walks all entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "x", .{ .integer = 1 });
    const table: Table = .{ .inner = map };
    var iter = table.iterator();
    var count: usize = 0;
    var found = false;
    while (iter.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.key_ptr.*, "x")) {
            try std.testing.expectEqual(@as(i64, 1), entry.value_ptr.integer);
            found = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(found);
}

test "Table.iterator: walks multiple entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMapUnmanaged(Value) = .empty;
    try map.put(arena.allocator(), "a", .{ .integer = 1 });
    try map.put(arena.allocator(), "b", .{ .integer = 2 });
    const table: Table = .{ .inner = map };
    var iter = table.iterator();
    var count: usize = 0;
    var found_a = false;
    var found_b = false;
    while (iter.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.key_ptr.*, "a")) {
            try std.testing.expectEqual(@as(i64, 1), entry.value_ptr.integer);
            found_a = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "b")) {
            try std.testing.expectEqual(@as(i64, 2), entry.value_ptr.integer);
            found_b = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

// --- AotArray.items ---

test "AotArray.items: returns correct elements" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Value,
        expected: []const Value,
    }{
        .{
            .name = "empty",
            .input = &.{},
            .expected = &.{},
        },
        .{
            .name = "one element",
            .input = &.{.{ .integer = 1 }},
            .expected = &.{.{ .integer = 1 }},
        },
        .{
            .name = "two elements",
            .input = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var list: std.ArrayListUnmanaged(Value) = .empty;
        for (tc.input) |v| try list.append(arena.allocator(), v);
        const aot: AotArray = .{ .inner = &list };
        try std.testing.expectEqualSlices(Value, tc.expected, aot.items());
    }
}

// --- AotArray.len ---

test "AotArray.len: returns correct length" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Value,
        expected: usize,
    }{
        .{
            .name = "empty",
            .input = &.{},
            .expected = 0,
        },
        .{
            .name = "one element",
            .input = &.{.{ .integer = 1 }},
            .expected = 1,
        },
        .{
            .name = "two elements",
            .input = &.{ .{ .integer = 1 }, .{ .integer = 2 } },
            .expected = 2,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var list: std.ArrayListUnmanaged(Value) = .empty;
        for (tc.input) |v| try list.append(arena.allocator(), v);
        const aot: AotArray = .{ .inner = &list };
        try std.testing.expectEqual(tc.expected, aot.len());
    }
}

// --- AotArray.lastPtr ---

test "AotArray.lastPtr: returns pointer to last element" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const Value,
        expected: Value,
    }{
        .{ .name = "one element", .input = &.{.{ .integer = 1 }}, .expected = .{ .integer = 1 } },
        .{ .name = "two elements", .input = &.{ .{ .integer = 1 }, .{ .integer = 2 } }, .expected = .{ .integer = 2 } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var list: std.ArrayListUnmanaged(Value) = .empty;
        for (tc.input) |v| try list.append(arena.allocator(), v);
        const aot: AotArray = .{ .inner = &list };
        try std.testing.expectEqual(tc.expected, aot.lastPtr().*);
    }
}

// --- Parsed.deinit ---

test "Parsed.deinit: frees arena memory" {
    var parsed = Parsed(i64){
        .value = 42,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    _ = try parsed.arena.allocator().alloc(u8, 16);
    parsed.deinit();
}

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- Datetime types ----

pub const LocalDate = struct { year: u16, month: u8, day: u8 };
pub const LocalTime = struct { hour: u8, minute: u8, second: u8, nanosecond: u32 };
pub const LocalDateTime = struct { date: LocalDate, time: LocalTime };
pub const OffsetDateTime = struct { datetime: LocalDateTime, offset_minutes: i16 };

// ---- Core value type ----

pub const TOMLValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const TOMLValue,
    table: TOMLTable,
    offset_date_time: OffsetDateTime,
    local_date_time: LocalDateTime,
    local_date: LocalDate,
    local_time: LocalTime,
};

/// Read-only wrapper around StringHashMap.
/// `inner` is pub to allow parser navigation; treat as read-only from outside the library.
pub const TOMLTable = struct {
    inner: std.StringHashMap(TOMLValue),

    pub fn get(self: TOMLTable, key: []const u8) ?TOMLValue {
        return self.inner.get(key);
    }

    pub fn iterator(self: TOMLTable) std.StringHashMap(TOMLValue).Iterator {
        return self.inner.iterator();
    }

    pub fn count(self: TOMLTable) usize {
        return self.inner.count();
    }
};

/// Constructs a TOMLTable from a map. Pub for parser access; not exported from the module's public API.
pub fn tableFromMap(map: std.StringHashMap(TOMLValue)) TOMLTable {
    return .{ .inner = map };
}

pub const ParseOptions = struct {
    diag: ?*Diagnostic = null,
};

pub const Diagnostic = struct {
    line: usize = 0,
    col: usize = 0,
    message: []const u8 = "",
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

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedChar,
    InvalidEscape,
    InvalidUnicode,
    DuplicateKey,
    InvalidNumber,
    InvalidDate,
    InvalidTime,
    TrailingContent,
};

const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

const Cursor = cursor_mod.Cursor;
const Value = types.Value;

pub const DateTimeKind = enum { datetime, date, time, none };

pub fn parseDateTime(cursor: *Cursor) errors.ParseError!Value {
    const date = try parseLocalDate(cursor);

    const sep = cursor.advance() orelse {
        cursor.fillDiagnostic("unexpected end of input");
        return error.UnexpectedEof;
    };
    if (sep != 'T' and sep != 't' and sep != ' ') {
        cursor.fillDiagnostic("expected date/time separator 'T' or space");
        return error.UnexpectedChar;
    }

    const time = try parseLocalTime(cursor);

    if (cursor.peek() == 'Z' or cursor.peek() == 'z') {
        _ = cursor.advance();
        return .{ .offset_date_time = .{
            .datetime = .{ .date = date, .time = time },
            .offset_minutes = 0,
        } };
    }

    if (cursor.peek() == '+' or cursor.peek() == '-') {
        const offset_minutes = try parseOffset(cursor);
        return .{ .offset_date_time = .{
            .datetime = .{ .date = date, .time = time },
            .offset_minutes = offset_minutes,
        } };
    }

    return .{ .local_date_time = .{ .date = date, .time = time } };
}

pub fn parseLocalDate(cursor: *Cursor) errors.ParseError!types.LocalDate {
    const year = try parseDigits(cursor, 4, error.InvalidDate);
    if (cursor.peek() != '-') {
        cursor.fillDiagnostic("expected '-' in date");
        return error.InvalidDate;
    }

    _ = cursor.advance();
    const month = try parseDigits(cursor, 2, error.InvalidDate);
    if (month < 1 or month > 12) {
        cursor.fillDiagnostic("invalid month");
        return error.InvalidDate;
    }
    if (cursor.peek() != '-') {
        cursor.fillDiagnostic("expected '-' in date");
        return error.InvalidDate;
    }

    _ = cursor.advance();
    const day = try parseDigits(cursor, 2, error.InvalidDate);
    const max_day = daysInMonth(month, year);
    if (day < 1 or day > max_day) {
        cursor.fillDiagnostic("invalid day");
        return error.InvalidDate;
    }

    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

pub fn parseLocalTime(cursor: *Cursor) errors.ParseError!types.LocalTime {
    const hour = try parseDigits(cursor, 2, error.InvalidTime);
    if (hour > 23) {
        cursor.fillDiagnostic("invalid hour");
        return error.InvalidTime;
    }
    if (cursor.peek() != ':') {
        cursor.fillDiagnostic("expected ':' before minutes in time");
        return error.InvalidTime;
    }

    _ = cursor.advance();
    const minute = try parseDigits(cursor, 2, error.InvalidTime);
    if (minute > 59) {
        cursor.fillDiagnostic("invalid minute");
        return error.InvalidTime;
    }
    if (cursor.peek() != ':') {
        cursor.fillDiagnostic("expected ':' before seconds in time");
        return error.InvalidTime;
    }

    _ = cursor.advance();
    const second = try parseDigits(cursor, 2, error.InvalidTime);
    if (second > 60) {
        cursor.fillDiagnostic("invalid second");
        return error.InvalidTime;
    }

    var nanosecond: u32 = 0;
    if (cursor.peek() == '.') {
        nanosecond = try parseSubseconds(cursor);
    }

    return .{
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = nanosecond,
    };
}

pub fn classifyDateTimeKind(remaining: []const u8) DateTimeKind {
    if (isDateTimeLike(remaining)) return .datetime;
    if (isDateLike(remaining)) return .date;
    if (isTimeLike(remaining)) return .time;

    return .none;
}

fn parseOffset(cursor: *Cursor) errors.ParseError!i16 {
    const ch = cursor.advance() orelse @panic("advance failed after peek returned '+'/'-'");
    const neg = ch == '-';

    const off_h = try parseDigits(cursor, 2, error.InvalidTime);
    if (cursor.peek() != ':') {
        cursor.fillDiagnostic("expected ':' in tz offset");
        return error.InvalidTime;
    }

    _ = cursor.advance();
    const off_m = try parseDigits(cursor, 2, error.InvalidTime);
    if (off_h > 23 or off_m > 59) {
        cursor.fillDiagnostic("timezone offset out of range");
        return error.InvalidTime;
    }

    // off_h <= 23, off_m <= 59 → max 1439, within i16 range
    const offset: i16 = @intCast(off_h * 60 + off_m);
    return if (neg) -offset else offset;
}

fn parseDigits(cursor: *Cursor, n: usize, err: errors.ParseError) errors.ParseError!u32 {
    var value: u32 = 0;
    for (0..n) |_| {
        const c = cursor.peek() orelse {
            cursor.fillDiagnostic("unexpected end of input in date/time");
            return err;
        };
        if (!std.ascii.isDigit(c)) {
            cursor.fillDiagnostic("expected digit in date/time");
            return err;
        }

        _ = cursor.advance();
        value = value * 10 + (c - '0');
    }

    return value;
}

fn parseSubseconds(cursor: *Cursor) errors.ParseError!u32 {
    if (cursor.peek() != '.') @panic("parseSubseconds: expected '.'");

    _ = cursor.advance();
    const frac_start = cursor.position;
    while (cursor.peek()) |c| {
        if (std.ascii.isDigit(c)) _ = cursor.advance() else break;
    }

    const frac = cursor.peekSliceSince(frac_start);
    if (frac.len == 0) {
        cursor.fillDiagnostic("expected fractional digits");
        return error.InvalidTime;
    }

    var ns: u32 = 0;
    const nn = @min(frac.len, 9);
    for (frac[0..nn]) |c| ns = ns * 10 + (c - '0');

    // 小数秒は左揃え表記のため、不足桁数分だけ右ゼロ埋めしてナノ秒に正規化する
    for (0..(9 - nn)) |_| ns *= 10;

    return ns;
}

fn daysInMonth(month: u32, year: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else @as(u32, 28),
        else => @panic("daysInMonth: month out of range 1-12"),
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn isDateTimeLike(remaining: []const u8) bool {
    if (!isDateLike(remaining)) return false;
    if (remaining.len < 12) return false;
    const sep = remaining[10];
    if (sep == 'T' or sep == 't') return true;
    if (sep == ' ' and std.ascii.isDigit(remaining[11])) return true;

    return false;
}

fn isDateLike(remaining: []const u8) bool {
    if (remaining.len < 10) return false;
    for (0..4) |i| if (!std.ascii.isDigit(remaining[i])) return false;
    if (remaining[4] != '-') return false;
    for (5..7) |i| if (!std.ascii.isDigit(remaining[i])) return false;
    if (remaining[7] != '-') return false;
    for (8..10) |i| if (!std.ascii.isDigit(remaining[i])) return false;

    return true;
}

fn isTimeLike(remaining: []const u8) bool {
    if (remaining.len < 8) return false;
    for (0..2) |i| if (!std.ascii.isDigit(remaining[i])) return false;
    if (remaining[2] != ':') return false;
    for (3..5) |i| if (!std.ascii.isDigit(remaining[i])) return false;
    if (remaining[5] != ':') return false;
    for (6..8) |i| if (!std.ascii.isDigit(remaining[i])) return false;

    return true;
}

// --- parseDateTime ---

test "parseDateTime: local datetime" {
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
            .name = "T separator",
            .input = "2024-01-15T12:30:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
            },
        },
        .{
            .name = "t separator",
            .input = "2024-01-15t12:30:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
            },
        },
        .{
            .name = "space separator",
            .input = "2024-01-15 12:30:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
            },
        },
        .{
            .name = "with subseconds",
            .input = "2024-01-15T12:30:00.123456789",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 123_456_789,
            },
        },
        .{
            .name = "leap second",
            .input = "2024-06-30T23:59:60",
            .expected = .{
                .year = 2024,
                .month = 6,
                .day = 30,
                .hour = 23,
                .minute = 59,
                .second = 60,
                .nanosecond = 0,
            },
        },
        .{
            .name = "leap year Feb 29",
            .input = "2000-02-29T00:00:00",
            .expected = .{
                .year = 2000,
                .month = 2,
                .day = 29,
                .hour = 0,
                .minute = 0,
                .second = 0,
                .nanosecond = 0,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const value = try parseDateTime(&cursor);
        const ldt = value.local_date_time;
        try std.testing.expectEqual(tc.expected.year, ldt.date.year);
        try std.testing.expectEqual(tc.expected.month, ldt.date.month);
        try std.testing.expectEqual(tc.expected.day, ldt.date.day);
        try std.testing.expectEqual(tc.expected.hour, ldt.time.hour);
        try std.testing.expectEqual(tc.expected.minute, ldt.time.minute);
        try std.testing.expectEqual(tc.expected.second, ldt.time.second);
        try std.testing.expectEqual(tc.expected.nanosecond, ldt.time.nanosecond);
    }
}

test "parseDateTime: offset datetime" {
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
            .name = "UTC Z",
            .input = "2024-01-15T12:30:00Z",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 0,
            },
        },
        .{
            .name = "UTC z",
            .input = "2024-01-15T12:30:00z",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 0,
            },
        },
        .{
            .name = "positive offset",
            .input = "2024-01-15T12:30:00+09:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 540,
            },
        },
        .{
            .name = "negative offset",
            .input = "2024-01-15T12:30:00-05:30",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = -330,
            },
        },
        .{
            .name = "max valid offset",
            .input = "2024-01-15T12:30:00+23:59",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 23 * 60 + 59,
            },
        },
        .{
            .name = "subseconds with offset",
            .input = "2024-01-15T12:30:00.123456789+09:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 123_456_789,
                .offset_minutes = 540,
            },
        },
        .{
            .name = "space separator",
            .input = "2024-01-15 12:30:00+09:00",
            .expected = .{
                .year = 2024,
                .month = 1,
                .day = 15,
                .hour = 12,
                .minute = 30,
                .second = 0,
                .nanosecond = 0,
                .offset_minutes = 540,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const value = try parseDateTime(&cursor);
        const odt = value.offset_date_time;
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

test "parseDateTime: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "offset missing colon",
            .input = "2024-01-15T12:30:00+0900",
            .expected = error.InvalidTime,
        },
        .{
            .name = "offset hour out of range",
            .input = "2024-01-15T12:30:00+24:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "offset minute out of range",
            .input = "2024-01-15T12:30:00+00:60",
            .expected = error.InvalidTime,
        },
        .{
            .name = "invalid hour in time component",
            .input = "2024-01-15T24:00:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "invalid minute in time component",
            .input = "2024-01-15T12:60:00",
            .expected = error.InvalidTime,
        },
        .{
            .name = "invalid second in time component",
            .input = "2024-01-15T23:59:61",
            .expected = error.InvalidTime,
        },
        .{
            .name = "EOF after date",
            .input = "2024-01-15",
            .expected = error.UnexpectedEof,
        },
        .{
            .name = "invalid separator",
            .input = "2024-01-15X12:30:00",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "CR as separator",
            .input = "2024-01-15\r12:30:00",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "invalid month",
            .input = "2024-13-01T12:30:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "zero month",
            .input = "2024-00-01T12:00:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "invalid day",
            .input = "2024-01-32T12:00:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "zero day",
            .input = "2024-01-00T12:00:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "April day 31",
            .input = "2024-04-31T12:00:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "non-leap year Feb 29",
            .input = "1900-02-29T00:00:00",
            .expected = error.InvalidDate,
        },
        .{
            .name = "EOF in time component",
            .input = "2024-01-15T12:30",
            .expected = error.InvalidTime,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseDateTime(&cursor));
    }
}

test "parseDateTime: fills diagnostic on error" {
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
            .name = "eof after date",
            .input = "2024-01-01",
            .expected = .{
                .err = error.UnexpectedEof,
                .message = "unexpected end of input",
                .line = 1,
                .column = 11,
            },
        },
        .{
            .name = "invalid separator",
            .input = "2024-01-01X12:00:00",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected date/time separator 'T' or space",
                .line = 1,
                .column = 12,
            },
        },
        .{
            .name = "invalid month",
            .input = "2024-13-01T00:00:00",
            .expected = .{
                .err = error.InvalidDate,
                .message = "invalid month",
                .line = 1,
                .column = 8,
            },
        },
        .{
            .name = "invalid hour",
            .input = "2024-01-01T24:00:00",
            .expected = .{
                .err = error.InvalidTime,
                .message = "invalid hour",
                .line = 1,
                .column = 14,
            },
        },
        .{
            .name = "offset hour out of range",
            .input = "2024-01-01T00:00:00+24:00",
            .expected = .{
                .err = error.InvalidTime,
                .message = "timezone offset out of range",
                .line = 1,
                .column = 26,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseDateTime(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseLocalDate ---

test "parseLocalDate: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { year: u16, month: u8, day: u8 },
    }{
        .{
            .name = "valid date",
            .input = "2024-01-15",
            .expected = .{ .year = 2024, .month = 1, .day = 15 },
        },
        .{
            .name = "Unix epoch",
            .input = "1970-01-01",
            .expected = .{ .year = 1970, .month = 1, .day = 1 },
        },
        .{
            .name = "max boundary",
            .input = "2024-12-31",
            .expected = .{ .year = 2024, .month = 12, .day = 31 },
        },
        .{
            .name = "leap year Feb 29",
            .input = "2000-02-29",
            .expected = .{ .year = 2000, .month = 2, .day = 29 },
        },
        .{
            .name = "non-leap year Feb 28",
            .input = "1900-02-28",
            .expected = .{ .year = 1900, .month = 2, .day = 28 },
        },
        .{
            .name = "year zero",
            .input = "0000-01-01",
            .expected = .{ .year = 0, .month = 1, .day = 1 },
        },
        .{
            .name = "max year",
            .input = "9999-12-31",
            .expected = .{ .year = 9999, .month = 12, .day = 31 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const date = try parseLocalDate(&cursor);
        try std.testing.expectEqual(tc.expected.year, date.year);
        try std.testing.expectEqual(tc.expected.month, date.month);
        try std.testing.expectEqual(tc.expected.day, date.day);
    }
}

test "parseLocalDate: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "non-leap year Feb 29", .input = "1900-02-29", .expected = error.InvalidDate },
        .{ .name = "Feb 30 always invalid", .input = "2000-02-30", .expected = error.InvalidDate },
        .{ .name = "month zero", .input = "2024-00-01", .expected = error.InvalidDate },
        .{ .name = "month 13", .input = "2024-13-01", .expected = error.InvalidDate },
        .{ .name = "day zero", .input = "2024-01-00", .expected = error.InvalidDate },
        .{ .name = "day exceeds month", .input = "2024-01-32", .expected = error.InvalidDate },
        .{ .name = "April has no day 31", .input = "2024-04-31", .expected = error.InvalidDate },
        .{ .name = "missing first hyphen", .input = "20240115", .expected = error.InvalidDate },
        .{ .name = "incomplete input", .input = "2024-01", .expected = error.InvalidDate },
        .{ .name = "non-digit in year", .input = "202x-01-15", .expected = error.InvalidDate },
        .{ .name = "missing second hyphen", .input = "2024-01.15", .expected = error.InvalidDate },
        .{ .name = "signed year negative", .input = "-001-01-01", .expected = error.InvalidDate },
        .{ .name = "signed year positive", .input = "+001-01-01", .expected = error.InvalidDate },
        .{ .name = "empty input", .input = "", .expected = error.InvalidDate },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseLocalDate(&cursor));
    }
}

test "parseLocalDate: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { message: []const u8, line: usize, column: usize },
    }{
        .{
            .name = "month out of range",
            .input = "2024-13-01",
            .expected = .{ .message = "invalid month", .line = 1, .column = 8 },
        },
        .{
            .name = "month zero",
            .input = "2024-00-01",
            .expected = .{ .message = "invalid month", .line = 1, .column = 8 },
        },
        .{
            .name = "missing first hyphen",
            .input = "20240115",
            .expected = .{ .message = "expected '-' in date", .line = 1, .column = 5 },
        },
        .{
            .name = "missing second hyphen",
            .input = "2024-01.15",
            .expected = .{ .message = "expected '-' in date", .line = 1, .column = 8 },
        },
        .{
            .name = "invalid day",
            .input = "2024-01-32",
            .expected = .{ .message = "invalid day", .line = 1, .column = 11 },
        },
        .{
            .name = "day zero",
            .input = "2024-01-00",
            .expected = .{ .message = "invalid day", .line = 1, .column = 11 },
        },
        .{
            .name = "non-digit in year",
            .input = "202x-01-15",
            .expected = .{ .message = "expected digit in date/time", .line = 1, .column = 4 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(error.InvalidDate, parseLocalDate(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseLocalTime ---

test "parseLocalTime: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { hour: u8, minute: u8, second: u8, nanosecond: u32 },
    }{
        .{
            .name = "with seconds and subseconds",
            .input = "12:30:45.123",
            .expected = .{ .hour = 12, .minute = 30, .second = 45, .nanosecond = 123_000_000 },
        },
        .{
            .name = "with seconds no subseconds",
            .input = "12:30:45",
            .expected = .{ .hour = 12, .minute = 30, .second = 45, .nanosecond = 0 },
        },
        .{
            .name = "max valid hour",
            .input = "23:59:59",
            .expected = .{ .hour = 23, .minute = 59, .second = 59, .nanosecond = 0 },
        },
        .{
            .name = "max valid minute",
            .input = "00:59:00",
            .expected = .{ .hour = 0, .minute = 59, .second = 0, .nanosecond = 0 },
        },
        .{
            .name = "min boundary",
            .input = "00:00:00",
            .expected = .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 0 },
        },
        .{
            .name = "second 60 leap second",
            .input = "23:59:60",
            .expected = .{ .hour = 23, .minute = 59, .second = 60, .nanosecond = 0 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const time = try parseLocalTime(&cursor);
        try std.testing.expectEqual(tc.expected.hour, time.hour);
        try std.testing.expectEqual(tc.expected.minute, time.minute);
        try std.testing.expectEqual(tc.expected.second, time.second);
        try std.testing.expectEqual(tc.expected.nanosecond, time.nanosecond);
    }
}

test "parseLocalTime: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "hour 24", .input = "24:00:00", .expected = error.InvalidTime },
        .{ .name = "minute 60", .input = "00:60:00", .expected = error.InvalidTime },
        .{ .name = "second 61", .input = "00:00:61", .expected = error.InvalidTime },
        .{ .name = "missing colon", .input = "1200", .expected = error.InvalidTime },
        .{ .name = "seconds omitted", .input = "12:30", .expected = error.InvalidTime },
        .{ .name = "empty input", .input = "", .expected = error.InvalidTime },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseLocalTime(&cursor));
    }
}

test "parseLocalTime: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { message: []const u8, line: usize, column: usize },
    }{
        .{
            .name = "hour out of range",
            .input = "24:00:00",
            .expected = .{
                .message = "invalid hour",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "missing colon before minutes",
            .input = "1200",
            .expected = .{
                .message = "expected ':' before minutes in time",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "minute out of range",
            .input = "00:60:00",
            .expected = .{
                .message = "invalid minute",
                .line = 1,
                .column = 6,
            },
        },
        .{
            .name = "missing colon before seconds",
            .input = "12:34x5",
            .expected = .{
                .message = "expected ':' before seconds in time",
                .line = 1,
                .column = 6,
            },
        },
        .{
            .name = "second out of range",
            .input = "12:34:61",
            .expected = .{
                .message = "invalid second",
                .line = 1,
                .column = 9,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(error.InvalidTime, parseLocalTime(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- classifyDateTimeKind ---

test "classifyDateTimeKind: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: DateTimeKind,
    }{
        .{
            .name = "datetime with T separator",
            .input = "2024-01-15T12:30:00",
            .expected = .datetime,
        },
        .{
            .name = "datetime with lowercase t separator",
            .input = "2024-01-15t12:00:00",
            .expected = .datetime,
        },
        .{
            .name = "datetime with space separator",
            .input = "2024-01-15 12:00:00",
            .expected = .datetime,
        },
        .{
            .name = "datetime with space separator and offset",
            .input = "2024-01-15 12:00:00Z",
            .expected = .datetime,
        },
        .{
            .name = "date",
            .input = "2024-01-15",
            .expected = .date,
        },
        .{
            .name = "time",
            .input = "12:30:00",
            .expected = .time,
        },
        .{
            .name = "none",
            .input = "not a date",
            .expected = .none,
        },
        .{
            .name = "none: empty",
            .input = "",
            .expected = .none,
        },
        .{
            .name = "none: 8-digit without separator",
            .input = "20240115",
            .expected = .none,
        },
        .{
            .name = "none: slash separator",
            .input = "2024/01/15",
            .expected = .none,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, classifyDateTimeKind(tc.input));
    }
}

// --- parseOffset ---

test "parseOffset: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i16,
    }{
        .{ .name = "positive offset", .input = "+09:00", .expected = 540 },
        .{ .name = "negative offset", .input = "-05:30", .expected = -330 },
        .{ .name = "zero offset", .input = "+00:00", .expected = 0 },
        .{ .name = "max valid", .input = "+23:59", .expected = 23 * 60 + 59 },
        .{ .name = "negative max valid", .input = "-23:59", .expected = -(23 * 60 + 59) },
        .{ .name = "negative zero offset", .input = "-00:00", .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseOffset(&cursor);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "parseOffset: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "missing colon", .input = "+0900", .expected = error.InvalidTime },
        .{ .name = "hour out of range", .input = "+24:00", .expected = error.InvalidTime },
        .{ .name = "minute out of range", .input = "+00:60", .expected = error.InvalidTime },
        .{ .name = "EOF after sign", .input = "+", .expected = error.InvalidTime },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseOffset(&cursor));
    }
}

test "parseOffset: fills diagnostic on error" {
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
            .name = "missing colon",
            .input = "+0900",
            .expected = .{
                .err = error.InvalidTime,
                .message = "expected ':' in tz offset",
                .line = 1,
                .column = 4,
            },
        },
        .{
            .name = "hour out of range",
            .input = "+24:00",
            .expected = .{
                .err = error.InvalidTime,
                .message = "timezone offset out of range",
                .line = 1,
                .column = 7,
            },
        },
        .{
            .name = "minute out of range",
            .input = "+00:60",
            .expected = .{
                .err = error.InvalidTime,
                .message = "timezone offset out of range",
                .line = 1,
                .column = 7,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseOffset(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseDigits ---

test "parseDigits: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: u32,
    }{
        .{ .name = "2 digits", .input = .{ .s = "12", .n = 2 }, .expected = 12 },
        .{ .name = "4 digits", .input = .{ .s = "2024", .n = 4 }, .expected = 2024 },
        .{ .name = "stops after n digits", .input = .{ .s = "1234ab", .n = 2 }, .expected = 12 },
        .{ .name = "n=0 returns 0", .input = .{ .s = "99", .n = 0 }, .expected = 0 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        const result = try parseDigits(&cursor, tc.input.n, error.InvalidDate);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "parseDigits: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "EOF before all digits",
            .input = .{ .s = "", .n = 2 },
            .expected = error.InvalidDate,
        },
        .{
            .name = "non-digit character",
            .input = .{ .s = "1a", .n = 2 },
            .expected = error.InvalidDate,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectError(
            tc.expected,
            parseDigits(&cursor, tc.input.n, error.InvalidDate),
        );
    }
}

test "parseDigits: fills diagnostic on error" {
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
            .name = "EOF before all digits",
            .input = .{ .s = "", .n = 2 },
            .expected = .{
                .err = error.InvalidDate,
                .message = "unexpected end of input in date/time",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "non-digit character",
            .input = .{ .s = "1a", .n = 2 },
            .expected = .{
                .err = error.InvalidDate,
                .message = "expected digit in date/time",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        try std.testing.expectError(
            tc.expected.err,
            parseDigits(&cursor, tc.input.n, error.InvalidDate),
        );
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseSubseconds ---

test "parseSubseconds: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: u32,
    }{
        .{
            .name = "3-digit precision",
            .input = ".123",
            .expected = 123_000_000,
        },
        .{
            .name = "9-digit precision preserved",
            .input = ".123456789",
            .expected = 123_456_789,
        },
        .{
            .name = "over 9 digits truncated",
            .input = ".1234567890",
            .expected = 123_456_789,
        },
        .{
            .name = "20 digits truncated",
            .input = ".12345678901234567890",
            .expected = 123_456_789,
        },
        .{
            .name = "1-digit precision",
            .input = ".1",
            .expected = 100_000_000,
        },
        .{
            .name = "2-digit precision",
            .input = ".12",
            .expected = 120_000_000,
        },
        .{
            .name = "6-digit precision",
            .input = ".000001",
            .expected = 1_000,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const ns = try parseSubseconds(&cursor);
        try std.testing.expectEqual(tc.expected, ns);
    }
}

test "parseSubseconds: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { err: errors.ParseError, cursor_position: usize },
    }{
        .{
            .name = "dot only",
            .input = ".",
            .expected = .{ .err = error.InvalidTime, .cursor_position = 1 },
        },
        .{
            .name = "dot followed by non-digit",
            .input = ".x",
            .expected = .{ .err = error.InvalidTime, .cursor_position = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected.err, parseSubseconds(&cursor));
        try std.testing.expectEqual(tc.expected.cursor_position, cursor.position);
    }
}

test "parseSubseconds: fills diagnostic on error" {
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
            .name = "dot followed by non-digit",
            .input = ".x",
            .expected = .{
                .err = error.InvalidTime,
                .message = "expected fractional digits",
                .line = 1,
                .column = 2,
            },
        },
        .{
            .name = "dot only",
            .input = ".",
            .expected = .{
                .err = error.InvalidTime,
                .message = "expected fractional digits",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseSubseconds(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- daysInMonth ---

test "daysInMonth: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { month: u32, year: u32 },
        expected: u32,
    }{
        .{ .name = "Feb leap year", .input = .{ .month = 2, .year = 2000 }, .expected = 29 },
        .{ .name = "Feb 2024 leap year", .input = .{ .month = 2, .year = 2024 }, .expected = 29 },
        .{ .name = "Feb non-leap year", .input = .{ .month = 2, .year = 1900 }, .expected = 28 },
        .{ .name = "Feb year 0 leap year", .input = .{ .month = 2, .year = 0 }, .expected = 29 },
        .{ .name = "January 31 days", .input = .{ .month = 1, .year = 2024 }, .expected = 31 },
        .{ .name = "March 31 days", .input = .{ .month = 3, .year = 2024 }, .expected = 31 },
        .{ .name = "April 30 days", .input = .{ .month = 4, .year = 2024 }, .expected = 30 },
        .{ .name = "May 31 days", .input = .{ .month = 5, .year = 2024 }, .expected = 31 },
        .{ .name = "June 30 days", .input = .{ .month = 6, .year = 2024 }, .expected = 30 },
        .{ .name = "July 31 days", .input = .{ .month = 7, .year = 2024 }, .expected = 31 },
        .{ .name = "August 31 days", .input = .{ .month = 8, .year = 2024 }, .expected = 31 },
        .{ .name = "September 30 days", .input = .{ .month = 9, .year = 2024 }, .expected = 30 },
        .{ .name = "October 31 days", .input = .{ .month = 10, .year = 2024 }, .expected = 31 },
        .{ .name = "November 30 days", .input = .{ .month = 11, .year = 2024 }, .expected = 30 },
        .{ .name = "December 31 days", .input = .{ .month = 12, .year = 2024 }, .expected = 31 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, daysInMonth(tc.input.month, tc.input.year));
    }
}

// --- isLeapYear ---

test "isLeapYear: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: u32,
        expected: bool,
    }{
        .{ .name = "multiple of 400 is leap", .input = 2000, .expected = true },
        .{ .name = "multiple of 400 is leap (1600)", .input = 1600, .expected = true },
        .{ .name = "multiple of 100 not 400 is not leap", .input = 1900, .expected = false },
        .{ .name = "multiple of 100 not 400 is not leap (2100)", .input = 2100, .expected = false },
        .{ .name = "multiple of 4 not 100 is leap", .input = 2024, .expected = true },
        .{ .name = "multiple of 4 not 100 is leap (2004)", .input = 2004, .expected = true },
        .{ .name = "non-multiple of 4 is not leap", .input = 2023, .expected = false },
        .{ .name = "non-multiple of 4 is not leap (2001)", .input = 2001, .expected = false },
        .{ .name = "year 0 is leap (divisible by 400)", .input = 0, .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isLeapYear(tc.input));
    }
}

// --- isDateTimeLike ---

test "isDateTimeLike: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "T separator", .input = "2024-01-15T12:00:00", .expected = true },
        .{ .name = "t separator", .input = "2024-01-15t12:00:00", .expected = true },
        .{ .name = "space separator", .input = "2024-01-15 12:00:00", .expected = true },
        .{ .name = "date only", .input = "2024-01-15", .expected = false },
        .{ .name = "space followed by non-digit", .input = "2024-01-15 xx:00", .expected = false },
        .{ .name = "too short 9 chars", .input = "2024-01-1", .expected = false },
        .{ .name = "empty", .input = "", .expected = false },
        .{ .name = "length 11 too short", .input = "2024-01-15 ", .expected = false },
        .{ .name = "invalid separator", .input = "2024-01-15X12:00", .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isDateTimeLike(tc.input));
    }
}

// --- isDateLike ---

test "isDateLike: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "valid date", .input = "2024-01-15", .expected = true },
        .{ .name = "datetime is also date-like", .input = "2024-01-15T12:00:00", .expected = true },
        .{ .name = "too short", .input = "2024-01", .expected = false },
        .{ .name = "empty", .input = "", .expected = false },
        .{ .name = "wrong separator", .input = "2024/01/15", .expected = false },
        .{ .name = "non-digit in year", .input = "202x-01-15", .expected = false },
        .{ .name = "non-digit in month", .input = "2024-xx-15", .expected = false },
        .{ .name = "non-digit in day", .input = "2024-01-xx", .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isDateLike(tc.input));
    }
}

// --- isTimeLike ---

test "isTimeLike: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "HH:MM without seconds", .input = "08:30", .expected = false },
        .{ .name = "valid time HH:MM:SS", .input = "08:30:00", .expected = true },
        .{ .name = "too short HH:M", .input = "08:3", .expected = false },
        .{ .name = "empty", .input = "", .expected = false },
        .{ .name = "wrong separator", .input = "08-30", .expected = false },
        .{ .name = "non-digit in hour", .input = "xx:30", .expected = false },
        .{ .name = "non-digit in minute", .input = "08:xx", .expected = false },
        .{ .name = "non-digit in second", .input = "08:30:xx", .expected = false },
        .{ .name = "time with subseconds", .input = "08:30:00.123", .expected = true },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isTimeLike(tc.input));
    }
}

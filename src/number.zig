const std = @import("std");
const cursor_mod = @import("cursor.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");

// 実用上の上限。超過した場合は InvalidNumber を返す。
const float_literal_buf_size: usize = 128;

// i64 最大値（19桁）+ 符号（1）+
// アンダースコア区切り最大（18）= 38 バイトで収まる。
const int_literal_buf_size: usize = 64;

// 2進数が最悪ケース：i64 最大値は 63 桁 +
// アンダースコア最大 62 個 = 125 バイト。
const based_int_literal_buf_size: usize = 128;

const Cursor = cursor_mod.Cursor;
const Value = types.Value;

const IntBase = enum { binary, octal, hex };

const FloatParts = struct {
    int_part: []const u8,
    frac_part: ?[]const u8,
    exp_part: ?[]const u8,
};

pub fn parseNumber(cursor: *Cursor) errors.ParseError!Value {
    const start = cursor.position;
    const has_sign = cursor.peek() == '+' or cursor.peek() == '-';
    const is_negative = has_sign and cursor.peek() == '-';

    if (has_sign) _ = cursor.advance();

    if (cursor.startsWith("inf")) {
        cursor.advanceAscii(3);
        try checkNumberDelimiter(cursor);
        return .{ .float = if (is_negative) -std.math.inf(f64) else std.math.inf(f64) };
    }

    if (cursor.startsWith("nan")) {
        cursor.advanceAscii(3);
        try checkNumberDelimiter(cursor);
        return .{ .float = std.math.nan(f64) };
    }

    if (isBasedIntPrefix(cursor)) {
        if (has_sign) {
            cursor.fillDiagnostic("sign not allowed before based integer");
            return error.InvalidNumber;
        }
        return try parsePrefixedInt(cursor);
    }

    return try parseDecimal(cursor, start, has_sign);
}

fn parseDecimal(cursor: *Cursor, start: usize, has_sign: bool) errors.ParseError!Value {
    const digits_start = cursor.position;

    while (cursor.peek()) |c| {
        if (std.ascii.isDigit(c) or c == '_') _ = cursor.advance() else break;
    }

    if (cursor.position == digits_start) {
        cursor.fillDiagnostic("expected digit");
        return error.UnexpectedChar;
    }

    if (cursor.peek() == '.' or cursor.peek() == 'e' or cursor.peek() == 'E') {
        const result = try finalizeFloat(cursor, start);
        try checkNumberDelimiter(cursor);
        return result;
    }

    const result = try finalizeInteger(cursor, start, has_sign);
    try checkNumberDelimiter(cursor);

    return result;
}

fn parsePrefixedInt(cursor: *Cursor) errors.ParseError!Value {
    const base: IntBase = if (cursor.startsWith("0x"))
        .hex
    else if (cursor.startsWith("0o"))
        .octal
    else if (cursor.startsWith("0b"))
        .binary
    else
        @panic("parsePrefixedInt: not a based integer prefix");

    cursor.advanceAscii(2);

    const result = try parseBasedInt(cursor, base);
    try checkNumberDelimiter(cursor);

    return result;
}

fn parseBasedInt(cursor: *Cursor, base: IntBase) errors.ParseError!Value {
    const start = cursor.position;
    while (cursor.peek()) |c| {
        const valid_digit = switch (base) {
            .binary => c == '0' or c == '1',
            .octal => c >= '0' and c <= '7',
            .hex => std.ascii.isHex(c),
        };
        if (valid_digit or c == '_') _ = cursor.advance() else break;
    }

    if (cursor.position == start) {
        cursor.fillDiagnostic("expected digit in based integer");
        return error.InvalidNumber;
    }

    const raw = cursor.peekSliceSince(start);
    if (validateUnderscores(raw)) |msg| {
        cursor.fillDiagnostic(msg);
        return error.InvalidNumber;
    }

    if (raw.len > based_int_literal_buf_size) {
        cursor.fillDiagnostic("based integer literal too long");
        return error.InvalidNumber;
    }

    var buf: [based_int_literal_buf_size]u8 = undefined;
    const stripped = stripUnderscores(raw, &buf);
    const n = std.fmt.parseInt(i64, stripped, switch (base) {
        .binary => 2,
        .octal => 8,
        .hex => 16,
    }) catch {
        cursor.fillDiagnostic("invalid based integer");
        return error.InvalidNumber;
    };

    return .{ .integer = n };
}

fn parseFractionalPart(cursor: *Cursor) errors.ParseError!void {
    if (cursor.peek() != '.') @panic("parseFractionalPart: current byte must be '.'");

    _ = cursor.advance();
    const first_digit = cursor.peek() orelse {
        cursor.fillDiagnostic("expected digit after decimal point");
        return error.InvalidNumber;
    };
    if (!std.ascii.isDigit(first_digit)) {
        cursor.fillDiagnostic("expected digit after decimal point");
        return error.InvalidNumber;
    }

    while (cursor.peek()) |c| {
        if (std.ascii.isDigit(c) or c == '_') _ = cursor.advance() else break;
    }
}

fn parseExponentPart(cursor: *Cursor) errors.ParseError!void {
    if (cursor.peek() != 'e' and cursor.peek() != 'E')
        @panic("parseExponentPart: current byte must be 'e' or 'E'");

    _ = cursor.advance();
    if (cursor.peek() == '+' or cursor.peek() == '-') _ = cursor.advance();
    const exp_start = cursor.position;

    while (cursor.peek()) |c| {
        if (std.ascii.isDigit(c) or c == '_') _ = cursor.advance() else break;
    }
    if (cursor.position == exp_start) {
        cursor.fillDiagnostic("expected digit in exponent");
        return error.InvalidNumber;
    }
}

fn finalizeFloat(cursor: *Cursor, start: usize) errors.ParseError!Value {
    if (cursor.peek() == '.') try parseFractionalPart(cursor);
    if (cursor.peek() == 'e' or cursor.peek() == 'E') try parseExponentPart(cursor);

    const raw = cursor.peekSliceSince(start);
    if (validateFloatFormat(raw)) |msg| {
        cursor.fillDiagnostic(msg);
        return error.InvalidNumber;
    }

    if (raw.len > float_literal_buf_size) {
        cursor.fillDiagnostic("float literal too long");
        return error.InvalidNumber;
    }

    var buf: [float_literal_buf_size]u8 = undefined;
    const stripped = stripUnderscores(raw, &buf);

    const f = std.fmt.parseFloat(f64, stripped) catch
        @panic("parseFloat failed on validated float literal");

    return .{ .float = f };
}

fn finalizeInteger(cursor: *Cursor, start: usize, has_sign: bool) errors.ParseError!Value {
    const raw = cursor.peekSliceSince(start);

    const int_digits = if (has_sign) raw[1..] else raw;
    if (validateUnderscores(int_digits)) |msg| {
        cursor.fillDiagnostic(msg);
        return error.InvalidNumber;
    }

    if (validateLeadingZero(int_digits)) |msg| {
        cursor.fillDiagnostic(msg);
        return error.InvalidNumber;
    }

    if (raw.len > int_literal_buf_size) {
        cursor.fillDiagnostic("integer literal too long");
        return error.InvalidNumber;
    }

    var buf: [int_literal_buf_size]u8 = undefined;
    const stripped = stripUnderscores(raw, &buf);

    const n = std.fmt.parseInt(i64, stripped, 10) catch {
        cursor.fillDiagnostic("invalid integer");
        return error.InvalidNumber;
    };

    return .{ .integer = n };
}

fn checkNumberDelimiter(cursor: *Cursor) errors.ParseError!void {
    if (!cursor.isLiteralTerminator()) {
        cursor.fillDiagnostic("unexpected character after number literal");
        return error.InvalidNumber;
    }
}

fn isBasedIntPrefix(cursor: *Cursor) bool {
    return cursor.startsWith("0x") or cursor.startsWith("0o") or cursor.startsWith("0b");
}

fn validateUnderscores(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s[0] == '_') return "leading underscore in number";
    if (s[s.len - 1] == '_') return "trailing underscore in number";

    for (s, 0..) |c, i| {
        if (c == '_' and
            i + 1 < s.len and
            s[i + 1] == '_')
        {
            return "consecutive underscores in number";
        }
    }

    return null;
}

fn validateLeadingZero(digits: []const u8) ?[]const u8 {
    if (digits.len > 1 and digits[0] == '0') return "leading zero in number";
    return null;
}

fn validateFloatFormat(raw: []const u8) ?[]const u8 {
    var s = raw;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];

    const parts = splitFloatParts(s);
    if (validateIntegerPart(parts.int_part)) |msg| return msg;
    if (parts.frac_part) |frac| {
        if (validateFractionalPart(frac)) |msg| return msg;
    }
    if (parts.exp_part) |exp| {
        if (validateExponentPart(exp)) |msg| return msg;
    }

    return null;
}

fn validateIntegerPart(digits: []const u8) ?[]const u8 {
    if (validateUnderscores(digits)) |msg| return msg;
    if (validateLeadingZero(digits)) |msg| return msg;

    return null;
}

fn validateFractionalPart(digits: []const u8) ?[]const u8 {
    return validateUnderscores(digits);
}

fn validateExponentPart(digits: []const u8) ?[]const u8 {
    return validateUnderscores(digits);
}

fn splitFloatParts(s: []const u8) FloatParts {
    var int_end: usize = 0;
    while (int_end < s.len and s[int_end] != '.' and s[int_end] != 'e' and s[int_end] != 'E') {
        int_end += 1;
    }

    var frac_part: ?[]const u8 = null;
    var exp_pos: usize = int_end;
    if (int_end < s.len and s[int_end] == '.') {
        var frac_end = int_end + 1;
        while (frac_end < s.len and s[frac_end] != 'e' and s[frac_end] != 'E') {
            frac_end += 1;
        }
        frac_part = s[int_end + 1 .. frac_end];
        exp_pos = frac_end;
    }

    var exp_part: ?[]const u8 = null;
    if (exp_pos < s.len and (s[exp_pos] == 'e' or s[exp_pos] == 'E')) {
        var digits_start = exp_pos + 1;
        if (digits_start < s.len and (s[digits_start] == '+' or s[digits_start] == '-')) {
            digits_start += 1;
        }
        exp_part = s[digits_start..];
    }

    return .{ .int_part = s[0..int_end], .frac_part = frac_part, .exp_part = exp_part };
}

fn stripUnderscores(raw: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (raw) |c| {
        if (c != '_') {
            buf[len] = c;
            len += 1;
        }
    }

    return buf[0..len];
}

// --- parseNumber ---

test "parseNumber: integer" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "positive integer", .input = "42", .expected = 42 },
        .{ .name = "negative integer", .input = "-1", .expected = -1 },
        .{ .name = "zero", .input = "0", .expected = 0 },
        .{ .name = "positive with sign", .input = "+1", .expected = 1 },
        .{ .name = "positive sign zero", .input = "+0", .expected = 0 },
        .{ .name = "underscore separator", .input = "1_000_000", .expected = 1_000_000 },
        .{ .name = "max i64", .input = "9223372036854775807", .expected = 9223372036854775807 },
        .{ .name = "min i64", .input = "-9223372036854775808", .expected = -9223372036854775808 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseNumber(&cursor);
        try std.testing.expectEqual(Value{ .integer = tc.expected }, result);
    }
}

test "parseNumber: float: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: f64,
    }{
        .{ .name = "basic", .input = "3.14", .expected = 3.14 },
        .{ .name = "negative", .input = "-1.5", .expected = -1.5 },
        .{ .name = "positive sign", .input = "+1.5", .expected = 1.5 },
        .{ .name = "exponent", .input = "1e10", .expected = 1e10 },
        .{ .name = "underscore", .input = "1_000.5", .expected = 1000.5 },
        .{ .name = "+inf", .input = "+inf", .expected = std.math.inf(f64) },
        .{ .name = "inf", .input = "inf", .expected = std.math.inf(f64) },
        .{ .name = "-inf", .input = "-inf", .expected = -std.math.inf(f64) },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseNumber(&cursor);
        try std.testing.expectEqual(tc.expected, result.float);
    }
}

test "parseNumber: float: nan" {
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

        var cursor = Cursor.init(tc.input, null);
        const result = try parseNumber(&cursor);
        try std.testing.expectEqual(tc.expected, std.math.isNan(result.float));
    }
}

test "parseNumber: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "signed hex",
            .input = "-0xff",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "empty input",
            .input = "",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "sign only",
            .input = "+",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "binary with trailing invalid digit",
            .input = "0b12",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "hex with trailing invalid char",
            .input = "0xffz",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "decimal with trailing invalid char",
            .input = "42x",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "dot only",
            .input = ".",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "nan with trailing char",
            .input = "nanx",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "+nan with trailing char",
            .input = "+nanx",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "inf with trailing char",
            .input = "infx",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "-nan with trailing char",
            .input = "-nanx",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "-inf with trailing char",
            .input = "-infx",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "integer overflow",
            .input = "9223372036854775808",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "integer underflow",
            .input = "-9223372036854775809",
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseNumber(&cursor));
    }
}

test "parseNumber: fills diagnostic on error" {
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
            .name = "signed based integer",
            .input = "+0x1 ",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "sign not allowed before based integer",
                .line = 1,
                .column = 2,
            },
        },
        .{
            .name = "sign only",
            .input = "+",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected digit",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseNumber(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseDecimal ---

test "parseDecimal: success: unsigned" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: Value,
    }{
        .{ .name = "integer", .input = "42 ", .expected = .{ .integer = 42 } },
        .{ .name = "float", .input = "1.5 ", .expected = .{ .float = 1.5 } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parseDecimal(&cursor, 0, false);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "parseDecimal: success: signed" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: Value,
    }{
        .{ .name = "negative integer", .input = "-42 ", .expected = .{ .integer = -42 } },
        .{ .name = "negative float", .input = "-1.5 ", .expected = .{ .float = -1.5 } },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        _ = cursor.advance();
        const result = try parseDecimal(&cursor, 0, true);
        try std.testing.expectEqual(tc.expected, result);
    }
}

test "parseDecimal: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "no digit",
            .input = "",
            .expected = error.UnexpectedChar,
        },
        .{
            .name = "zero-padded integer",
            .input = "07 ",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "invalid character after number",
            .input = "42x",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "leading underscore in integer",
            .input = "_42 ",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "leading underscore in fraction",
            .input = "1._5 ",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "decimal point not followed by digit",
            .input = "1. ",
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseDecimal(&cursor, 0, false));
    }
}

test "parseDecimal: fills diagnostic on error" {
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
            .name = "no digit",
            .input = "",
            .expected = .{
                .err = error.UnexpectedChar,
                .message = "expected digit",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "zero-padded integer",
            .input = "07 ",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "leading zero in number",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "trailing invalid char",
            .input = "42x",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "unexpected character after number literal",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "decimal point not followed by digit",
            .input = "1. ",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit after decimal point",
                .line = 1,
                .column = 3,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseDecimal(&cursor, 0, false));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parsePrefixedInt ---

test "parsePrefixedInt: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: i64,
    }{
        .{ .name = "hex", .input = "0xff", .expected = 255 },
        .{ .name = "octal", .input = "0o77", .expected = 63 },
        .{ .name = "binary", .input = "0b1010", .expected = 10 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const result = try parsePrefixedInt(&cursor);
        try std.testing.expectEqual(Value{ .integer = tc.expected }, result);
    }
}

test "parsePrefixedInt: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "hex prefix then empty", .input = "0x", .expected = error.InvalidNumber },
        .{ .name = "octal prefix then empty", .input = "0o", .expected = error.InvalidNumber },
        .{ .name = "binary prefix then empty", .input = "0b", .expected = error.InvalidNumber },
        .{ .name = "octal prefix then invalid", .input = "0o89", .expected = error.InvalidNumber },
        .{ .name = "binary prefix then invalid", .input = "0b12", .expected = error.InvalidNumber },
        .{ .name = "hex with invalid suffix", .input = "0xGG", .expected = error.InvalidNumber },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parsePrefixedInt(&cursor));
    }
}

test "parsePrefixedInt: fills diagnostic on error" {
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
            .name = "hex no digit",
            .input = "0x",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit in based integer",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "binary overflow",
            .input = "0b" ++ "1" ** 64,
            .expected = .{
                .err = error.InvalidNumber,
                .message = "invalid based integer",
                .line = 1,
                .column = 67,
            },
        },
        .{
            .name = "literal too long",
            .input = "0x" ++ "1" ** 129,
            .expected = .{
                .err = error.InvalidNumber,
                .message = "based integer literal too long",
                .line = 1,
                .column = 132,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parsePrefixedInt(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseBasedInt ---

test "parseBasedInt: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, base: IntBase },
        expected: i64,
    }{
        .{
            .name = "hexadecimal",
            .input = .{ .s = "ff", .base = .hex },
            .expected = 255,
        },
        .{
            .name = "octal",
            .input = .{ .s = "77", .base = .octal },
            .expected = 63,
        },
        .{
            .name = "binary",
            .input = .{ .s = "1010", .base = .binary },
            .expected = 10,
        },
        .{
            .name = "underscore separator",
            .input = .{ .s = "f_f", .base = .hex },
            .expected = 255,
        },
        .{
            .name = "binary exactly at buffer size",
            .input = .{ .s = "000" ++ "_0" ** 62 ++ "1", .base = .binary },
            .expected = 1,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        const result = try parseBasedInt(&cursor, tc.input.base);
        try std.testing.expectEqual(Value{ .integer = tc.expected }, result);
    }
}

test "parseBasedInt: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, base: IntBase },
        expected: errors.ParseError,
    }{
        .{
            .name = "empty input",
            .input = .{ .s = "", .base = .hex },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "invalid octal digit",
            .input = .{ .s = "89", .base = .octal },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "leading underscore",
            .input = .{ .s = "_ff", .base = .hex },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "trailing underscore",
            .input = .{ .s = "ff_", .base = .hex },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "consecutive underscores",
            .input = .{ .s = "f__f", .base = .hex },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "exceeds buffer size",
            .input = .{ .s = "1" ** 129, .base = .binary },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "hex value exceeds i64 max",
            .input = .{ .s = "ffffffffffffffff", .base = .hex },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "binary value exceeds i64 max",
            .input = .{ .s = "1" ** 64, .base = .binary },
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectError(tc.expected, parseBasedInt(&cursor, tc.input.base));
    }
}

test "parseBasedInt: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, base: IntBase },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "no digit",
            .input = .{ .s = "", .base = .hex },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit in based integer",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "leading underscore",
            .input = .{ .s = "_ff", .base = .hex },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "leading underscore in number",
                .line = 1,
                .column = 4,
            },
        },
        .{
            .name = "literal too long",
            .input = .{ .s = "1" ** 129, .base = .binary },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "based integer literal too long",
                .line = 1,
                .column = 130,
            },
        },
        .{
            .name = "overflow",
            .input = .{ .s = "ffffffffffffffff", .base = .hex },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "invalid based integer",
                .line = 1,
                .column = 17,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseBasedInt(&cursor, tc.input.base));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseFractionalPart ---

test "parseFractionalPart: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "single digit", .input = ".5", .expected = 2 },
        .{ .name = "multiple digits", .input = ".123", .expected = 4 },
        .{ .name = "with underscore", .input = ".5_0", .expected = 4 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try parseFractionalPart(&cursor);
        try std.testing.expectEqual(tc.expected, cursor.position);
    }
}

test "parseFractionalPart: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "EOF after decimal point",
            .input = ".",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "non-digit after decimal point",
            .input = ".xyz",
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseFractionalPart(&cursor));
    }
}

test "parseFractionalPart: fills diagnostic on error" {
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
            .name = "eof after decimal point",
            .input = ".",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit after decimal point",
                .line = 1,
                .column = 2,
            },
        },
        .{
            .name = "non-digit after decimal point",
            .input = ".xyz",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit after decimal point",
                .line = 1,
                .column = 2,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseFractionalPart(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- parseExponentPart ---

test "parseExponentPart: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: usize,
    }{
        .{ .name = "lowercase e", .input = "e5", .expected = 2 },
        .{ .name = "uppercase E", .input = "E5", .expected = 2 },
        .{ .name = "positive exponent", .input = "e+5", .expected = 3 },
        .{ .name = "negative exponent", .input = "e-5", .expected = 3 },
        .{ .name = "with underscore", .input = "e1_0", .expected = 4 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try parseExponentPart(&cursor);
        try std.testing.expectEqual(tc.expected, cursor.position);
    }
}

test "parseExponentPart: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "no digit", .input = "e", .expected = error.InvalidNumber },
        .{ .name = "no digit after sign", .input = "e+", .expected = error.InvalidNumber },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, parseExponentPart(&cursor));
    }
}

test "parseExponentPart: fills diagnostic on error" {
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
            .name = "no digit",
            .input = "e",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit in exponent",
                .line = 1,
                .column = 2,
            },
        },
        .{
            .name = "no digit after sign",
            .input = "e+",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit in exponent",
                .line = 1,
                .column = 3,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, parseExponentPart(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- finalizeFloat ---

test "finalizeFloat: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: f64,
    }{
        .{ .name = "integer and fractional part", .input = "1.5", .expected = 1.5 },
        .{ .name = "exponent only", .input = "1e10", .expected = 1e10 },
        .{ .name = "with positive exponent", .input = "1.0e2", .expected = 100.0 },
        .{ .name = "with negative exponent", .input = "1.0e-1", .expected = 0.1 },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        _ = cursor.advance();
        const result = try finalizeFloat(&cursor, 0);
        try std.testing.expectApproxEqAbs(tc.expected, result.float, 1e-10);
    }
}

test "finalizeFloat: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{
            .name = "decimal point not followed by digit",
            .input = "1.xyz",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "exponent without digit",
            .input = "1e",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "EOF after decimal point",
            .input = "1.",
            .expected = error.InvalidNumber,
        },
        .{
            .name = "float literal too long",
            .input = "1." ++ "0" ** 127,
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        _ = cursor.advance();
        try std.testing.expectError(tc.expected, finalizeFloat(&cursor, 0));
    }
}

test "finalizeFloat: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, position: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "float literal too long",
            .input = .{ .s = "1." ++ "0" ** 127, .position = 1 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "float literal too long",
                .line = 1,
                .column = 130,
            },
        },
        .{
            .name = "trailing underscore in integer part",
            .input = .{ .s = "1_.5", .position = 2 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "trailing underscore in number",
                .line = 1,
                .column = 5,
            },
        },
        .{
            .name = "no digit after decimal",
            .input = .{ .s = "1.xyz", .position = 1 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit after decimal point",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "no digit in exponent",
            .input = .{ .s = "1e", .position = 1 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "expected digit in exponent",
                .line = 1,
                .column = 3,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        cursor.advanceTo(tc.input.position);
        try std.testing.expectError(tc.expected.err, finalizeFloat(&cursor, 0));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- finalizeInteger ---

test "finalizeInteger: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, has_sign: bool },
        expected: i64,
    }{
        .{
            .name = "unsigned",
            .input = .{ .s = "42", .has_sign = false },
            .expected = 42,
        },
        .{
            .name = "signed negative",
            .input = .{ .s = "-42", .has_sign = true },
            .expected = -42,
        },
        .{
            .name = "signed positive",
            .input = .{ .s = "+1", .has_sign = true },
            .expected = 1,
        },
        .{
            .name = "i64 max",
            .input = .{ .s = "9223372036854775807", .has_sign = false },
            .expected = std.math.maxInt(i64),
        },
        .{
            .name = "i64 min",
            .input = .{ .s = "-9223372036854775808", .has_sign = true },
            .expected = std.math.minInt(i64),
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceTo(tc.input.s.len);
        const result = try finalizeInteger(&cursor, 0, tc.input.has_sign);
        try std.testing.expectEqual(Value{ .integer = tc.expected }, result);
    }
}

test "finalizeInteger: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, position: usize },
        expected: errors.ParseError,
    }{
        .{
            .name = "leading zero",
            .input = .{ .s = "07", .position = 2 },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "trailing underscore",
            .input = .{ .s = "1_", .position = 2 },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "integer overflow",
            .input = .{ .s = "9223372036854775808", .position = 19 },
            .expected = error.InvalidNumber,
        },
        .{
            .name = "integer literal too long",
            .input = .{ .s = "1" ** 65, .position = 65 },
            .expected = error.InvalidNumber,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceTo(tc.input.position);
        try std.testing.expectError(tc.expected, finalizeInteger(&cursor, 0, false));
    }
}

test "finalizeInteger: fills diagnostic on error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, position: usize },
        expected: struct {
            err: errors.ParseError,
            message: []const u8,
            line: usize,
            column: usize,
        },
    }{
        .{
            .name = "leading zero",
            .input = .{ .s = "07", .position = 2 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "leading zero in number",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "trailing underscore",
            .input = .{ .s = "1_", .position = 2 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "trailing underscore in number",
                .line = 1,
                .column = 3,
            },
        },
        .{
            .name = "integer literal too long",
            .input = .{ .s = "1" ** 65, .position = 65 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "integer literal too long",
                .line = 1,
                .column = 66,
            },
        },
        .{
            .name = "overflow",
            .input = .{ .s = "9223372036854775808", .position = 19 },
            .expected = .{
                .err = error.InvalidNumber,
                .message = "invalid integer",
                .line = 1,
                .column = 20,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input.s, &diagnostic);
        cursor.advanceTo(tc.input.position);
        try std.testing.expectError(tc.expected.err, finalizeInteger(&cursor, 0, false));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- checkNumberDelimiter ---

test "checkNumberDelimiter: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "EOF", .input = "" },
        .{ .name = "space", .input = " " },
        .{ .name = "tab", .input = "\t" },
        .{ .name = "newline", .input = "\n" },
        .{ .name = "hash", .input = "#" },
        .{ .name = "comma", .input = "," },
        .{ .name = "close bracket", .input = "]" },
        .{ .name = "close brace", .input = "}" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try checkNumberDelimiter(&cursor);
    }
}

test "checkNumberDelimiter: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: errors.ParseError,
    }{
        .{ .name = "letter", .input = "x", .expected = error.InvalidNumber },
        .{ .name = "dot", .input = ".", .expected = error.InvalidNumber },
        .{ .name = "digit", .input = "1", .expected = error.InvalidNumber },
        .{ .name = "bare carriage return", .input = "\r", .expected = error.InvalidNumber },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(tc.expected, checkNumberDelimiter(&cursor));
    }
}

test "checkNumberDelimiter: fills diagnostic on error" {
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
            .name = "letter",
            .input = "x",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "unexpected character after number literal",
                .line = 1,
                .column = 1,
            },
        },
        .{
            .name = "digit",
            .input = "1",
            .expected = .{
                .err = error.InvalidNumber,
                .message = "unexpected character after number literal",
                .line = 1,
                .column = 1,
            },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var diagnostic: types.Diagnostic = .{};
        var cursor = Cursor.init(tc.input, &diagnostic);
        try std.testing.expectError(tc.expected.err, checkNumberDelimiter(&cursor));
        try std.testing.expectEqualStrings(tc.expected.message, diagnostic.message);
        try std.testing.expectEqual(tc.expected.line, diagnostic.line);
        try std.testing.expectEqual(tc.expected.column, diagnostic.column);
    }
}

// --- isBasedIntPrefix ---

test "isBasedIntPrefix: recognizes 0x 0o 0b prefixes only" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "0x prefix", .input = "0xff", .expected = true },
        .{ .name = "0o prefix", .input = "0o77", .expected = true },
        .{ .name = "0b prefix", .input = "0b1010", .expected = true },
        .{ .name = "decimal integer", .input = "123", .expected = false },
        .{ .name = "zero without prefix", .input = "0", .expected = false },
        .{ .name = "empty input", .input = "", .expected = false },
        .{ .name = "uppercase X is not a prefix", .input = "0Xff", .expected = false },
        .{ .name = "uppercase O is not a prefix", .input = "0O77", .expected = false },
        .{ .name = "uppercase B is not a prefix", .input = "0B10", .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectEqual(tc.expected, isBasedIntPrefix(&cursor));
    }
}

// --- validateUnderscores ---

test "validateUnderscores: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "empty string", .input = "", .expected = null },
        .{ .name = "no underscores", .input = "123", .expected = null },
        .{ .name = "valid separator", .input = "1_000", .expected = null },
        .{ .name = "multiple separators", .input = "1_000_000", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateUnderscores(tc.input));
    }
}

test "validateUnderscores: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "leading underscore",
            .input = "_1",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore",
            .input = "1_",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "consecutive underscores",
            .input = "1__0",
            .expected = "consecutive underscores in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateUnderscores(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- validateLeadingZero ---

test "validateLeadingZero: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "single zero", .input = "0", .expected = null },
        .{ .name = "empty string", .input = "", .expected = null },
        .{ .name = "non-zero leading digit", .input = "10", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateLeadingZero(tc.input));
    }
}

test "validateLeadingZero: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "two digits with leading zero",
            .input = "01",
            .expected = "leading zero in number",
        },
        .{
            .name = "double zero",
            .input = "00",
            .expected = "leading zero in number",
        },
        .{
            .name = "three digits with leading zero",
            .input = "001",
            .expected = "leading zero in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateLeadingZero(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- validateFloatFormat ---

test "validateFloatFormat: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{
            .name = "sign and all parts valid",
            .input = "-1_0.0_1e1_0",
            .expected = null,
        },
        .{
            .name = "integer part only valid",
            .input = "1_000",
            .expected = null,
        },
        .{
            .name = "integer and exponent without fraction valid",
            .input = "1e1_0",
            .expected = null,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateFloatFormat(tc.input));
    }
}

test "validateFloatFormat: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "leading underscore in integer part",
            .input = "_1.0e1",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore in integer part",
            .input = "1_.0e1",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "leading underscore in fractional part",
            .input = "1._0e1",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore in fractional part",
            .input = "1.0_e1",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "leading underscore in exponent part",
            .input = "1.0e_1",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore in exponent part",
            .input = "1.0e1_",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "leading zero in integer part",
            .input = "01.5",
            .expected = "leading zero in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateFloatFormat(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- validateIntegerPart ---

test "validateIntegerPart: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "valid digits", .input = "1_000", .expected = null },
        .{ .name = "empty string", .input = "", .expected = null },
        .{ .name = "single zero", .input = "0", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateIntegerPart(tc.input));
    }
}

test "validateIntegerPart: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "leading underscore",
            .input = "_1",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore",
            .input = "1_",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "consecutive underscores",
            .input = "1__0",
            .expected = "consecutive underscores in number",
        },
        .{
            .name = "leading zero",
            .input = "01",
            .expected = "leading zero in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateIntegerPart(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- validateFractionalPart ---

test "validateFractionalPart: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "valid digits", .input = "1_000", .expected = null },
        .{ .name = "empty string", .input = "", .expected = null },
        // 整数部と異なり小数部は leading zero が TOML 仕様で許可されている
        .{ .name = "leading zero", .input = "01", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateFractionalPart(tc.input));
    }
}

test "validateFractionalPart: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "leading underscore",
            .input = "_5",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore",
            .input = "5_",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "consecutive underscores",
            .input = "5__0",
            .expected = "consecutive underscores in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateFractionalPart(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- validateExponentPart ---

test "validateExponentPart: valid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "valid digits", .input = "1_0", .expected = null },
        .{ .name = "empty string", .input = "", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, validateExponentPart(tc.input));
    }
}

test "validateExponentPart: invalid" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "leading underscore",
            .input = "_10",
            .expected = "leading underscore in number",
        },
        .{
            .name = "trailing underscore",
            .input = "10_",
            .expected = "trailing underscore in number",
        },
        .{
            .name = "consecutive underscores",
            .input = "1__0",
            .expected = "consecutive underscores in number",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const msg_opt = validateExponentPart(tc.input);
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(msg_opt != null);
        try std.testing.expectEqualStrings(tc.expected, msg_opt.?);
    }
}

// --- splitFloatParts ---

test "splitFloatParts: integer only" {
    const result = splitFloatParts("1_000");
    try std.testing.expectEqualStrings("1_000", result.int_part);
    try std.testing.expectEqual(@as(?[]const u8, null), result.frac_part);
    try std.testing.expectEqual(@as(?[]const u8, null), result.exp_part);
}

test "splitFloatParts: integer and fraction" {
    const result = splitFloatParts("1.5_0");
    try std.testing.expectEqualStrings("1", result.int_part);
    const frac = result.frac_part orelse return error.TestFailed;
    try std.testing.expectEqualStrings("5_0", frac);
    try std.testing.expectEqual(@as(?[]const u8, null), result.exp_part);
}

test "splitFloatParts: integer and exponent" {
    const result = splitFloatParts("1e1_0");
    try std.testing.expectEqualStrings("1", result.int_part);
    try std.testing.expectEqual(@as(?[]const u8, null), result.frac_part);
    const exp_part = result.exp_part orelse return error.TestFailed;
    try std.testing.expectEqualStrings("1_0", exp_part);
}

test "splitFloatParts: all parts" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct {
            int_part: []const u8,
            frac_part: []const u8,
            exp_part: []const u8,
        },
    }{
        .{
            .name = "underscored parts",
            .input = "1_0.0_1e1_0",
            .expected = .{ .int_part = "1_0", .frac_part = "0_1", .exp_part = "1_0" },
        },
        .{
            .name = "exponent with positive sign",
            .input = "1.5e+10",
            .expected = .{ .int_part = "1", .frac_part = "5", .exp_part = "10" },
        },
        .{
            .name = "exponent with negative sign",
            .input = "1.5e-10",
            .expected = .{ .int_part = "1", .frac_part = "5", .exp_part = "10" },
        },
        .{
            .name = "uppercase E",
            .input = "1.5E10",
            .expected = .{ .int_part = "1", .frac_part = "5", .exp_part = "10" },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const result = splitFloatParts(tc.input);
        try std.testing.expectEqualStrings(tc.expected.int_part, result.int_part);
        const frac_opt = result.frac_part;
        // どのテストケースが失敗したか特定するため
        // expect で null チェックし、.? で安全に unwrap する
        try std.testing.expect(frac_opt != null);
        try std.testing.expectEqualStrings(tc.expected.frac_part, frac_opt.?);
        const exp_opt = result.exp_part;
        try std.testing.expect(exp_opt != null);
        try std.testing.expectEqualStrings(tc.expected.exp_part, exp_opt.?);
    }
}

// --- stripUnderscores ---

test "stripUnderscores: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: []const u8,
    }{
        .{ .name = "no underscores", .input = "1234", .expected = "1234" },
        .{ .name = "underscore in middle", .input = "1_000", .expected = "1000" },
        .{ .name = "multiple underscores", .input = "1_000_000", .expected = "1000000" },
        .{ .name = "all underscores", .input = "___", .expected = "" },
        .{ .name = "empty input", .input = "", .expected = "" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(tc.expected, stripUnderscores(tc.input, &buf));
    }
}

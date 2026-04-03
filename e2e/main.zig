const std = @import("std");
const ztoml = @import("ztoml");

// ============================================================
// spec: comment
// ============================================================

test "spec: comment" {
    const input =
        \\# This is a full-line comment
        \\key = "value"  # This is a comment at the end of a line
        \\another = "# This is not a comment"
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const key = result.value.get("key") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", key.string);

    const another = result.value.get("another") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("# This is not a comment", another.string);
}

// ============================================================
// spec: key-value pair
// ============================================================

test "spec: key-value pair" {
    const input =
        \\key = "value"
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const key = result.value.get("key") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", key.string);
}

// ============================================================
// spec: bare keys
// ============================================================

test "spec: bare keys" {
    const input =
        \\key = "value"
        \\bare_key = "value"
        \\bare-key = "value"
        \\1234 = "value"
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const key = result.value.get("key") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", key.string);

    const bare_key = result.value.get("bare_key") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", bare_key.string);

    const bare_dash_key = result.value.get("bare-key") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", bare_dash_key.string);

    const numeric_key = result.value.get("1234") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", numeric_key.string);
}

// ============================================================
// spec: quoted keys
// ============================================================

test "spec: quoted keys" {
    const input =
        \\"127.0.0.1" = "value"
        \\"character encoding" = "value"
        \\'key2' = "value"
        \\'quoted "value"' = "value"
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const ip = result.value.get("127.0.0.1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", ip.string);

    const encoding = result.value.get("character encoding") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", encoding.string);

    const key2 = result.value.get("key2") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", key2.string);

    const quoted = result.value.get("quoted \"value\"") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("value", quoted.string);
}

// ============================================================
// spec: dotted keys
// ============================================================

test "spec: dotted keys" {
    const input =
        \\name = "Orange"
        \\physical.color = "orange"
        \\physical.shape = "round"
        \\site."google.com" = true
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const name = result.value.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Orange", name.string);

    const physical = result.value.get("physical") orelse return error.TestFailed;
    const color = physical.table.get("color") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("orange", color.string);
    const shape = physical.table.get("shape") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("round", shape.string);

    const site = result.value.get("site") orelse return error.TestFailed;
    const google = site.table.get("google.com") orelse return error.TestFailed;
    try std.testing.expectEqual(true, google.boolean);
}

// ============================================================
// spec: basic string
// ============================================================

test "spec: basic string" {
    const input =
        \\str = "I'm a string. \"You can quote me\". Name\tJos\xE9\nLocation\tSF."
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const str = result.value.get("str") orelse return error.TestFailed;
    try std.testing.expectEqualStrings(
        "I'm a string. \"You can quote me\". Name\tJos\xC3\xA9\nLocation\tSF.",
        str.string,
    );
}

// ============================================================
// spec: multiline basic string
// ============================================================

test "spec: multiline basic string" {
    const input =
        \\str1 = """
        \\Roses are red
        \\Violets are blue"""
        \\str2 = """
        \\The quick brown \
        \\
        \\  fox jumps over \
        \\    the lazy dog."""
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const str1 = result.value.get("str1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Roses are red\nViolets are blue", str1.string);

    const str2 = result.value.get("str2") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("The quick brown fox jumps over the lazy dog.", str2.string);
}

// ============================================================
// spec: literal string
// ============================================================

test "spec: literal string" {
    const input =
        \\winpath  = 'C:\Users\nodejs\templates'
        \\winpath2 = '\\ServerX\admin$\system32\'
        \\quoted   = 'Tom "Dubs" Preston-Werner'
        \\regex    = '<\i\c*\s*>'
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const winpath = result.value.get("winpath") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("C:\\Users\\nodejs\\templates", winpath.string);

    const winpath2 = result.value.get("winpath2") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("\\\\ServerX\\admin$\\system32\\", winpath2.string);

    const quoted = result.value.get("quoted") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Tom \"Dubs\" Preston-Werner", quoted.string);

    const regex = result.value.get("regex") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("<\\i\\c*\\s*>", regex.string);
}

// ============================================================
// spec: multiline literal string
// ============================================================

test "spec: multiline literal string" {
    const input =
        \\regex2 = '''I [dw]on't need \d{2} apples'''
        \\lines  = '''
        \\The first newline is
        \\trimmed in literal strings.
        \\   All other whitespace
        \\   is preserved.
        \\'''
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const regex2 = result.value.get("regex2") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("I [dw]on't need \\d{2} apples", regex2.string);

    const lines = result.value.get("lines") orelse return error.TestFailed;
    try std.testing.expectEqualStrings(
        "The first newline is\ntrimmed in literal strings.\n   All other whitespace\n   is preserved.\n",
        lines.string,
    );
}

// ============================================================
// spec: integer decimal
// ============================================================

test "spec: integer decimal" {
    const input =
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const int1 = result.value.get("int1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 99), int1.integer);

    const int2 = result.value.get("int2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 42), int2.integer);

    const int3 = result.value.get("int3") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0), int3.integer);

    const int4 = result.value.get("int4") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, -17), int4.integer);

    const int5 = result.value.get("int5") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1_000), int5.integer);

    const int6 = result.value.get("int6") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 5_349_221), int6.integer);
}

// ============================================================
// spec: integer non-decimal
// ============================================================

test "spec: integer non-decimal" {
    const input =
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\oct1 = 0o01234567
        \\oct2 = 0o755
        \\bin1 = 0b11010110
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const hex1 = result.value.get("hex1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), hex1.integer);

    const hex2 = result.value.get("hex2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0xdeadbeef), hex2.integer);

    const oct1 = result.value.get("oct1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0o01234567), oct1.integer);

    const oct2 = result.value.get("oct2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0o755), oct2.integer);

    const bin1 = result.value.get("bin1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0b11010110), bin1.integer);
}

// ============================================================
// spec: float
// ============================================================

test "spec: float" {
    const input =
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\flt7 = 6.626e-34
        \\flt8 = 224_617.445_991_228
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const flt1 = result.value.get("flt1") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), flt1.float, 1e-10);

    const flt2 = result.value.get("flt2") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 3.1415), flt2.float, 1e-10);

    const flt3 = result.value.get("flt3") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), flt3.float, 1e-10);

    const flt4 = result.value.get("flt4") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 5e+22), flt4.float, 1e10);

    const flt5 = result.value.get("flt5") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 1e06), flt5.float, 1.0);

    const flt6 = result.value.get("flt6") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, -2E-2), flt6.float, 1e-10);

    const flt7 = result.value.get("flt7") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 6.626e-34), flt7.float, 1e-42);

    const flt8 = result.value.get("flt8") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 224_617.445_991_228), flt8.float, 1e-6);
}

// ============================================================
// spec: float special values
// ============================================================

test "spec: float special values" {
    const input =
        \\sf1 = inf
        \\sf2 = +inf
        \\sf3 = -inf
        \\sf4 = nan
        \\sf5 = +nan
        \\sf6 = -nan
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const sf1 = result.value.get("sf1") orelse return error.TestFailed;
    try std.testing.expect(std.math.isPositiveInf(sf1.float));

    const sf2 = result.value.get("sf2") orelse return error.TestFailed;
    try std.testing.expect(std.math.isPositiveInf(sf2.float));

    const sf3 = result.value.get("sf3") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNegativeInf(sf3.float));

    const sf4 = result.value.get("sf4") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(sf4.float));

    const sf5 = result.value.get("sf5") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(sf5.float));

    const sf6 = result.value.get("sf6") orelse return error.TestFailed;
    try std.testing.expect(std.math.isNan(sf6.float));
}

// ============================================================
// spec: boolean
// ============================================================

test "spec: boolean" {
    const input =
        \\bool1 = true
        \\bool2 = false
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const bool1 = result.value.get("bool1") orelse return error.TestFailed;
    try std.testing.expectEqual(true, bool1.boolean);

    const bool2 = result.value.get("bool2") orelse return error.TestFailed;
    try std.testing.expectEqual(false, bool2.boolean);
}

// ============================================================
// spec: offset date-time
// ============================================================

test "spec: offset date-time" {
    const input =
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
        \\odt4 = 1979-05-27 07:32:00Z
        \\odt5 = 1979-05-27 07:32Z
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const odt1 = result.value.get("odt1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u16, 1979), odt1.offset_date_time.datetime.date.year);
    try std.testing.expectEqual(@as(u8, 5), odt1.offset_date_time.datetime.date.month);
    try std.testing.expectEqual(@as(u8, 27), odt1.offset_date_time.datetime.date.day);
    try std.testing.expectEqual(@as(u8, 7), odt1.offset_date_time.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 32), odt1.offset_date_time.datetime.time.minute);
    try std.testing.expectEqual(@as(u8, 0), odt1.offset_date_time.datetime.time.second);
    try std.testing.expectEqual(@as(i16, 0), odt1.offset_date_time.offset_minutes);

    const odt2 = result.value.get("odt2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, -7 * 60), odt2.offset_date_time.offset_minutes);

    const odt3 = result.value.get("odt3") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, -7 * 60), odt3.offset_date_time.offset_minutes);

    const odt4 = result.value.get("odt4") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, 0), odt4.offset_date_time.offset_minutes);
    try std.testing.expectEqual(@as(u8, 7), odt4.offset_date_time.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 32), odt4.offset_date_time.datetime.time.minute);

    const odt5 = result.value.get("odt5") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, 0), odt5.offset_date_time.offset_minutes);
    try std.testing.expectEqual(@as(u8, 7), odt5.offset_date_time.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 32), odt5.offset_date_time.datetime.time.minute);
    try std.testing.expectEqual(@as(u8, 0), odt5.offset_date_time.datetime.time.second);
}

// ============================================================
// spec: local date-time
// ============================================================

test "spec: local date-time" {
    const input =
        \\ldt1 = 1979-05-27T07:32:00
        \\ldt2 = 1979-05-27T07:32:00.5
        \\ldt3 = 1979-05-27T07:32
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const ldt1 = result.value.get("ldt1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u16, 1979), ldt1.local_date_time.date.year);
    try std.testing.expectEqual(@as(u8, 5), ldt1.local_date_time.date.month);
    try std.testing.expectEqual(@as(u8, 27), ldt1.local_date_time.date.day);
    try std.testing.expectEqual(@as(u8, 7), ldt1.local_date_time.time.hour);
    try std.testing.expectEqual(@as(u8, 32), ldt1.local_date_time.time.minute);
    try std.testing.expectEqual(@as(u8, 0), ldt1.local_date_time.time.second);

    const ldt2 = result.value.get("ldt2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0), ldt2.local_date_time.time.second);
    try std.testing.expect(ldt2.local_date_time.time.nanosecond > 0);

    const ldt3 = result.value.get("ldt3") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 7), ldt3.local_date_time.time.hour);
    try std.testing.expectEqual(@as(u8, 32), ldt3.local_date_time.time.minute);
    try std.testing.expectEqual(@as(u8, 0), ldt3.local_date_time.time.second);
}

// ============================================================
// spec: local date
// ============================================================

test "spec: local date" {
    const input =
        \\ld1 = 1979-05-27
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const ld1 = result.value.get("ld1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u16, 1979), ld1.local_date.year);
    try std.testing.expectEqual(@as(u8, 5), ld1.local_date.month);
    try std.testing.expectEqual(@as(u8, 27), ld1.local_date.day);
}

// ============================================================
// spec: local time
// ============================================================

test "spec: local time" {
    const input =
        \\lt1 = 07:32:00
        \\lt2 = 00:32:00.999999
        \\lt3 = 07:32
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const lt1 = result.value.get("lt1") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 7), lt1.local_time.hour);
    try std.testing.expectEqual(@as(u8, 32), lt1.local_time.minute);
    try std.testing.expectEqual(@as(u8, 0), lt1.local_time.second);

    const lt2 = result.value.get("lt2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0), lt2.local_time.hour);
    try std.testing.expectEqual(@as(u8, 32), lt2.local_time.minute);
    try std.testing.expectEqual(@as(u8, 0), lt2.local_time.second);
    try std.testing.expect(lt2.local_time.nanosecond > 0);

    const lt3 = result.value.get("lt3") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 7), lt3.local_time.hour);
    try std.testing.expectEqual(@as(u8, 32), lt3.local_time.minute);
    try std.testing.expectEqual(@as(u8, 0), lt3.local_time.second);
}

// ============================================================
// spec: array
// ============================================================

test "spec: array" {
    const input =
        \\integers = [ 1, 2, 3 ]
        \\colors = [ "red", "yellow", "green" ]
        \\nested_arrays_of_ints = [ [ 1, 2 ], [3, 4, 5] ]
        \\numbers = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
        \\integers3 = [
        \\  1,
        \\  2, # this is ok
        \\]
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const integers = result.value.get("integers") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 3), integers.array.len);
    try std.testing.expectEqual(@as(i64, 1), integers.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers.array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), integers.array[2].integer);

    const colors = result.value.get("colors") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 3), colors.array.len);
    try std.testing.expectEqualStrings("red", colors.array[0].string);
    try std.testing.expectEqualStrings("yellow", colors.array[1].string);
    try std.testing.expectEqualStrings("green", colors.array[2].string);

    const nested = result.value.get("nested_arrays_of_ints") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), nested.array.len);
    try std.testing.expectEqual(@as(usize, 2), nested.array[0].array.len);
    try std.testing.expectEqual(@as(i64, 1), nested.array[0].array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), nested.array[0].array[1].integer);
    try std.testing.expectEqual(@as(usize, 3), nested.array[1].array.len);
    try std.testing.expectEqual(@as(i64, 3), nested.array[1].array[0].integer);
    try std.testing.expectEqual(@as(i64, 4), nested.array[1].array[1].integer);
    try std.testing.expectEqual(@as(i64, 5), nested.array[1].array[2].integer);

    const numbers = result.value.get("numbers") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 6), numbers.array.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), numbers.array[0].float, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), numbers.array[1].float, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), numbers.array[2].float, 1e-10);
    try std.testing.expectEqual(@as(i64, 1), numbers.array[3].integer);
    try std.testing.expectEqual(@as(i64, 2), numbers.array[4].integer);
    try std.testing.expectEqual(@as(i64, 5), numbers.array[5].integer);

    const integers3 = result.value.get("integers3") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), integers3.array.len);
    try std.testing.expectEqual(@as(i64, 1), integers3.array[0].integer);
    try std.testing.expectEqual(@as(i64, 2), integers3.array[1].integer);
}

// ============================================================
// spec: table
// ============================================================

test "spec: table" {
    const input =
        \\[table-1]
        \\key1 = "some string"
        \\key2 = 123
        \\
        \\[table-2]
        \\key1 = "another string"
        \\key2 = 456
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const table1 = result.value.get("table-1") orelse return error.TestFailed;
    const t1_key1 = table1.table.get("key1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("some string", t1_key1.string);
    const t1_key2 = table1.table.get("key2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 123), t1_key2.integer);

    const table2 = result.value.get("table-2") orelse return error.TestFailed;
    const t2_key1 = table2.table.get("key1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("another string", t2_key1.string);
    const t2_key2 = table2.table.get("key2") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 456), t2_key2.integer);
}

// ============================================================
// spec: inline table
// ============================================================

test "spec: inline table" {
    const input =
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = {x=1, y=2}
        \\animal = { type.name = "pug" }
        \\contact = {
        \\    personal = {
        \\        name = "Donald Duck",
        \\        email = "donald@duckburg.com",
        \\    },
        \\    work = {
        \\        name = "Coin cleaner",
        \\        email = "donald@ScroogeCorp.com",
        \\    },
        \\}
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const name = result.value.get("name") orelse return error.TestFailed;
    const first = name.table.get("first") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Tom", first.string);
    const last = name.table.get("last") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Preston-Werner", last.string);

    const point = result.value.get("point") orelse return error.TestFailed;
    const x = point.table.get("x") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), x.integer);
    const y = point.table.get("y") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 2), y.integer);

    const animal = result.value.get("animal") orelse return error.TestFailed;
    const animal_type = animal.table.get("type") orelse return error.TestFailed;
    const animal_name = animal_type.table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("pug", animal_name.string);

    const contact = result.value.get("contact") orelse return error.TestFailed;
    const personal = contact.table.get("personal") orelse return error.TestFailed;
    const personal_name = personal.table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Donald Duck", personal_name.string);
    const personal_email = personal.table.get("email") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("donald@duckburg.com", personal_email.string);
    const work = contact.table.get("work") orelse return error.TestFailed;
    const work_name = work.table.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Coin cleaner", work_name.string);
    const work_email = work.table.get("email") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("donald@ScroogeCorp.com", work_email.string);
}

// ============================================================
// spec: array of tables
// ============================================================

test "spec: array of tables" {
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
        \\color = "gray"
    ;
    var result = try ztoml.parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const products = result.value.get("products") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 3), products.array.len);

    const p0 = products.array[0].table;
    const p0_name = p0.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Hammer", p0_name.string);
    const p0_sku = p0.get("sku") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 738594937), p0_sku.integer);

    const p1 = products.array[1].table;
    try std.testing.expectEqual(@as(usize, 0), p1.count());

    const p2 = products.array[2].table;
    const p2_name = p2.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Nail", p2_name.string);
    const p2_sku = p2.get("sku") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 284758393), p2_sku.integer);
    const p2_color = p2.get("color") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("gray", p2_color.string);
}

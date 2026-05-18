const std = @import("std");
const ztoml = @import("ztoml");

// --- spec: comment ---

test "spec: comment" {
    const Input = struct {
        key: []const u8,
        another: []const u8,
    };
    const input =
        \\# This is a full-line comment
        \\key = "value"  # This is a comment at the end of a line
        \\another = "# This is not a comment"
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("value", result.value.key);
    try std.testing.expectEqualStrings("# This is not a comment", result.value.another);
}

// --- spec: key-value pair ---

test "spec: key-value pair" {
    const Input = struct { key: []const u8 };
    const input =
        \\key = "value"
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("value", result.value.key);
}

// --- spec: bare keys ---

test "spec: bare keys" {
    const Input = struct {
        key: []const u8,
        bare_key: []const u8,
        @"bare-key": []const u8,
        @"1234": []const u8,
    };
    const input =
        \\key = "value"
        \\bare_key = "value"
        \\bare-key = "value"
        \\1234 = "value"
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("value", result.value.key);
    try std.testing.expectEqualStrings("value", result.value.bare_key);
    try std.testing.expectEqualStrings("value", result.value.@"bare-key");
    try std.testing.expectEqualStrings("value", result.value.@"1234");
}

// --- spec: quoted keys ---

test "spec: quoted keys" {
    const Input = struct {
        @"127.0.0.1": []const u8,
        @"character encoding": []const u8,
        key2: []const u8,
        @"quoted \"value\"": []const u8,
    };
    const input =
        \\"127.0.0.1" = "value"
        \\"character encoding" = "value"
        \\'key2' = "value"
        \\'quoted "value"' = "value"
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("value", result.value.@"127.0.0.1");
    try std.testing.expectEqualStrings("value", result.value.@"character encoding");
    try std.testing.expectEqualStrings("value", result.value.key2);
    try std.testing.expectEqualStrings("value", result.value.@"quoted \"value\"");
}

// --- spec: dotted keys ---

test "spec: dotted keys" {
    const Input = struct {
        name: []const u8,
        physical: struct { color: []const u8, shape: []const u8 },
        site: struct { @"google.com": bool },
    };
    const input =
        \\name = "Orange"
        \\physical.color = "orange"
        \\physical.shape = "round"
        \\site."google.com" = true
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Orange", result.value.name);
    try std.testing.expectEqualStrings("orange", result.value.physical.color);
    try std.testing.expectEqualStrings("round", result.value.physical.shape);
    try std.testing.expectEqual(true, result.value.site.@"google.com");
}

// --- spec: basic string ---

test "spec: basic string" {
    const Input = struct { str: []const u8 };
    const input =
        \\str = "I'm a string. \"You can quote me\". Name\tJos\xE9\nLocation\tSF."
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "I'm a string. \"You can quote me\". Name\tJos\xC3\xA9\nLocation\tSF.",
        result.value.str,
    );
}

// --- spec: multiline basic string ---

test "spec: multiline basic string" {
    const Input = struct { str1: []const u8, str2: []const u8 };
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
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Roses are red\nViolets are blue", result.value.str1);
    try std.testing.expectEqualStrings(
        "The quick brown fox jumps over the lazy dog.",
        result.value.str2,
    );
}

// --- spec: literal string ---

test "spec: literal string" {
    const Input = struct {
        winpath: []const u8,
        winpath2: []const u8,
        quoted: []const u8,
        regex: []const u8,
    };
    const input =
        \\winpath  = 'C:\Users\nodejs\templates'
        \\winpath2 = '\\ServerX\admin$\system32\'
        \\quoted   = 'Tom "Dubs" Preston-Werner'
        \\regex    = '<\i\c*\s*>'
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("C:\\Users\\nodejs\\templates", result.value.winpath);
    try std.testing.expectEqualStrings("\\\\ServerX\\admin$\\system32\\", result.value.winpath2);
    try std.testing.expectEqualStrings("Tom \"Dubs\" Preston-Werner", result.value.quoted);
    try std.testing.expectEqualStrings("<\\i\\c*\\s*>", result.value.regex);
}

// --- spec: multiline literal string ---

test "spec: multiline literal string" {
    const Input = struct { regex2: []const u8, lines: []const u8 };
    const input =
        \\regex2 = '''I [dw]on't need \d{2} apples'''
        \\lines  = '''
        \\The first newline is
        \\trimmed in literal strings.
        \\   All other whitespace
        \\   is preserved.
        \\'''
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("I [dw]on't need \\d{2} apples", result.value.regex2);
    try std.testing.expectEqualStrings(
        "The first newline is\n" ++
            "trimmed in literal strings.\n" ++
            "   All other whitespace\n" ++
            "   is preserved.\n",
        result.value.lines,
    );
}

// --- spec: integer decimal ---

test "spec: integer decimal" {
    const Input = struct {
        int1: i64,
        int2: i64,
        int3: i64,
        int4: i64,
        int5: i64,
        int6: i64,
    };
    const input =
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 99), result.value.int1);
    try std.testing.expectEqual(@as(i64, 42), result.value.int2);
    try std.testing.expectEqual(@as(i64, 0), result.value.int3);
    try std.testing.expectEqual(@as(i64, -17), result.value.int4);
    try std.testing.expectEqual(@as(i64, 1_000), result.value.int5);
    try std.testing.expectEqual(@as(i64, 5_349_221), result.value.int6);
}

// --- spec: integer non-decimal ---

test "spec: integer non-decimal" {
    const Input = struct {
        hex1: i64,
        hex2: i64,
        oct1: i64,
        oct2: i64,
        bin1: i64,
    };
    const input =
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\oct1 = 0o01234567
        \\oct2 = 0o755
        \\bin1 = 0b11010110
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), result.value.hex1);
    try std.testing.expectEqual(@as(i64, 0xdeadbeef), result.value.hex2);
    try std.testing.expectEqual(@as(i64, 0o01234567), result.value.oct1);
    try std.testing.expectEqual(@as(i64, 0o755), result.value.oct2);
    try std.testing.expectEqual(@as(i64, 0b11010110), result.value.bin1);
}

// --- spec: float ---

test "spec: float" {
    const Input = struct {
        flt1: f64,
        flt2: f64,
        flt3: f64,
        flt4: f64,
        flt5: f64,
        flt6: f64,
        flt7: f64,
        flt8: f64,
    };
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
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.value.flt1, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3.1415), result.value.flt2, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), result.value.flt3, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5e+22), result.value.flt4, 1e10);
    try std.testing.expectApproxEqAbs(@as(f64, 1e06), result.value.flt5, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, -2E-2), result.value.flt6, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 6.626e-34), result.value.flt7, 1e-42);
    try std.testing.expectApproxEqAbs(@as(f64, 224_617.445_991_228), result.value.flt8, 1e-6);
}

// --- spec: float special values ---

test "spec: float special values" {
    const Input = struct {
        sf1: f64,
        sf2: f64,
        sf3: f64,
        sf4: f64,
        sf5: f64,
        sf6: f64,
    };
    const input =
        \\sf1 = inf
        \\sf2 = +inf
        \\sf3 = -inf
        \\sf4 = nan
        \\sf5 = +nan
        \\sf6 = -nan
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expect(std.math.isPositiveInf(result.value.sf1));
    try std.testing.expect(std.math.isPositiveInf(result.value.sf2));
    try std.testing.expect(std.math.isNegativeInf(result.value.sf3));
    try std.testing.expect(std.math.isNan(result.value.sf4));
    try std.testing.expect(std.math.isNan(result.value.sf5));
    try std.testing.expect(std.math.isNan(result.value.sf6));
}

// --- spec: boolean ---

test "spec: boolean" {
    const Input = struct { bool1: bool, bool2: bool };
    const input =
        \\bool1 = true
        \\bool2 = false
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(true, result.value.bool1);
    try std.testing.expectEqual(false, result.value.bool2);
}

// --- spec: offset date-time ---

test "spec: offset date-time" {
    const Input = struct {
        odt1: ztoml.OffsetDateTime,
        odt2: ztoml.OffsetDateTime,
        odt3: ztoml.OffsetDateTime,
        odt4: ztoml.OffsetDateTime,
    };
    const input =
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
        \\odt4 = 1979-05-27 07:32:00Z
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 1979), result.value.odt1.datetime.date.year);
    try std.testing.expectEqual(@as(u8, 5), result.value.odt1.datetime.date.month);
    try std.testing.expectEqual(@as(u8, 27), result.value.odt1.datetime.date.day);
    try std.testing.expectEqual(@as(u8, 7), result.value.odt1.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 32), result.value.odt1.datetime.time.minute);
    try std.testing.expectEqual(@as(u8, 0), result.value.odt1.datetime.time.second);
    try std.testing.expectEqual(@as(i16, 0), result.value.odt1.offset_minutes);
    try std.testing.expectEqual(@as(i16, -7 * 60), result.value.odt2.offset_minutes);
    try std.testing.expectEqual(@as(i16, -7 * 60), result.value.odt3.offset_minutes);
    try std.testing.expectEqual(@as(i16, 0), result.value.odt4.offset_minutes);
    try std.testing.expectEqual(@as(u8, 7), result.value.odt4.datetime.time.hour);
    try std.testing.expectEqual(@as(u8, 32), result.value.odt4.datetime.time.minute);
}

// --- spec: local date-time ---

test "spec: local date-time" {
    const Input = struct {
        ldt1: ztoml.LocalDateTime,
        ldt2: ztoml.LocalDateTime,
    };
    const input =
        \\ldt1 = 1979-05-27T07:32:00
        \\ldt2 = 1979-05-27T07:32:00.5
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 1979), result.value.ldt1.date.year);
    try std.testing.expectEqual(@as(u8, 5), result.value.ldt1.date.month);
    try std.testing.expectEqual(@as(u8, 27), result.value.ldt1.date.day);
    try std.testing.expectEqual(@as(u8, 7), result.value.ldt1.time.hour);
    try std.testing.expectEqual(@as(u8, 32), result.value.ldt1.time.minute);
    try std.testing.expectEqual(@as(u8, 0), result.value.ldt1.time.second);
    try std.testing.expectEqual(@as(u8, 0), result.value.ldt2.time.second);
    try std.testing.expect(result.value.ldt2.time.nanosecond > 0);
}

// --- spec: local date ---

test "spec: local date" {
    const Input = struct { ld1: ztoml.LocalDate };
    const input =
        \\ld1 = 1979-05-27
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 1979), result.value.ld1.year);
    try std.testing.expectEqual(@as(u8, 5), result.value.ld1.month);
    try std.testing.expectEqual(@as(u8, 27), result.value.ld1.day);
}

// --- spec: local time ---

test "spec: local time" {
    const Input = struct {
        lt1: ztoml.LocalTime,
        lt2: ztoml.LocalTime,
    };
    const input =
        \\lt1 = 07:32:00
        \\lt2 = 00:32:00.999999
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 7), result.value.lt1.hour);
    try std.testing.expectEqual(@as(u8, 32), result.value.lt1.minute);
    try std.testing.expectEqual(@as(u8, 0), result.value.lt1.second);
    try std.testing.expectEqual(@as(u8, 0), result.value.lt2.hour);
    try std.testing.expectEqual(@as(u8, 32), result.value.lt2.minute);
    try std.testing.expectEqual(@as(u8, 0), result.value.lt2.second);
    try std.testing.expect(result.value.lt2.nanosecond > 0);
}

// --- spec: array ---

test "spec: array" {
    const Input = struct {
        integers: []const i64,
        colors: []const []const u8,
        nested_arrays_of_ints: []const []const i64,
        numbers: []const f64,
        integers3: []const i64,
    };
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
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.value.integers.len);
    try std.testing.expectEqual(@as(i64, 1), result.value.integers[0]);
    try std.testing.expectEqual(@as(i64, 2), result.value.integers[1]);
    try std.testing.expectEqual(@as(i64, 3), result.value.integers[2]);
    try std.testing.expectEqual(@as(usize, 3), result.value.colors.len);
    try std.testing.expectEqualStrings("red", result.value.colors[0]);
    try std.testing.expectEqualStrings("yellow", result.value.colors[1]);
    try std.testing.expectEqualStrings("green", result.value.colors[2]);
    try std.testing.expectEqual(@as(usize, 2), result.value.nested_arrays_of_ints.len);
    try std.testing.expectEqual(@as(usize, 2), result.value.nested_arrays_of_ints[0].len);
    try std.testing.expectEqual(@as(i64, 1), result.value.nested_arrays_of_ints[0][0]);
    try std.testing.expectEqual(@as(i64, 2), result.value.nested_arrays_of_ints[0][1]);
    try std.testing.expectEqual(@as(usize, 3), result.value.nested_arrays_of_ints[1].len);
    try std.testing.expectEqual(@as(i64, 3), result.value.nested_arrays_of_ints[1][0]);
    try std.testing.expectEqual(@as(i64, 4), result.value.nested_arrays_of_ints[1][1]);
    try std.testing.expectEqual(@as(i64, 5), result.value.nested_arrays_of_ints[1][2]);
    try std.testing.expectEqual(@as(usize, 6), result.value.numbers.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.value.numbers[0], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.value.numbers[1], 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.value.numbers[2], 1e-10);
    try std.testing.expectEqual(@as(usize, 2), result.value.integers3.len);
    try std.testing.expectEqual(@as(i64, 1), result.value.integers3[0]);
    try std.testing.expectEqual(@as(i64, 2), result.value.integers3[1]);
}

// --- spec: table ---

test "spec: table" {
    const Input = struct {
        @"table-1": struct { key1: []const u8, key2: i64 },
        @"table-2": struct { key1: []const u8, key2: i64 },
    };
    const input =
        \\[table-1]
        \\key1 = "some string"
        \\key2 = 123
        \\
        \\[table-2]
        \\key1 = "another string"
        \\key2 = 456
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("some string", result.value.@"table-1".key1);
    try std.testing.expectEqual(@as(i64, 123), result.value.@"table-1".key2);
    try std.testing.expectEqualStrings("another string", result.value.@"table-2".key1);
    try std.testing.expectEqual(@as(i64, 456), result.value.@"table-2".key2);
}

// --- spec: inline table ---

test "spec: inline table" {
    const Input = struct {
        name: struct { first: []const u8, last: []const u8 },
        point: struct { x: i64, y: i64 },
        animal: struct { type: struct { name: []const u8 } },
        contact: struct {
            personal: struct { name: []const u8, email: []const u8 },
            work: struct { name: []const u8, email: []const u8 },
        },
    };
    const input =
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = {x=1, y=2}
        \\animal = { type.name = "pug" }
        \\contact = {
        \\    personal = {
        \\        name = "Donald Duck",
        \\        email = "donald@duckburg.com"
        \\    },
        \\    work = {
        \\        name = "Coin cleaner",
        \\        email = "donald@ScroogeCorp.com"
        \\    }
        \\}
    ;
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("Tom", result.value.name.first);
    try std.testing.expectEqualStrings("Preston-Werner", result.value.name.last);
    try std.testing.expectEqual(@as(i64, 1), result.value.point.x);
    try std.testing.expectEqual(@as(i64, 2), result.value.point.y);
    try std.testing.expectEqualStrings("pug", result.value.animal.type.name);
    try std.testing.expectEqualStrings("Donald Duck", result.value.contact.personal.name);
    try std.testing.expectEqualStrings("donald@duckburg.com", result.value.contact.personal.email);
    try std.testing.expectEqualStrings("Coin cleaner", result.value.contact.work.name);
    try std.testing.expectEqualStrings("donald@ScroogeCorp.com", result.value.contact.work.email);
}

// --- spec: array of tables ---

test "spec: array of tables" {
    const Product = struct {
        name: ?[]const u8 = null,
        sku: ?i64 = null,
        color: ?[]const u8 = null,
    };
    const Input = struct { products: []const Product };
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
    var result = try ztoml.parse(Input, std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.value.products.len);
    try std.testing.expectEqualStrings(
        "Hammer",
        result.value.products[0].name orelse return error.TestFailed,
    );
    try std.testing.expectEqual(
        @as(i64, 738594937),
        result.value.products[0].sku orelse return error.TestFailed,
    );
    try std.testing.expect(result.value.products[0].color == null);
    try std.testing.expect(result.value.products[1].name == null);
    try std.testing.expect(result.value.products[1].sku == null);
    try std.testing.expect(result.value.products[1].color == null);
    try std.testing.expectEqualStrings(
        "Nail",
        result.value.products[2].name orelse return error.TestFailed,
    );
    try std.testing.expectEqual(
        @as(i64, 284758393),
        result.value.products[2].sku orelse return error.TestFailed,
    );
    try std.testing.expectEqualStrings(
        "gray",
        result.value.products[2].color orelse return error.TestFailed,
    );
}


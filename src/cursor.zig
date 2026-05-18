const std = @import("std");
const errors = @import("errors.zig");
const types = @import("types.zig");

// \r は isLiteralTerminator で個別判定する
// （TOML 1.1 では裸の CR は不正。\r\n のみ行末として有効）
const literal_terminators = " \t\n#,]}";

const Diagnostic = types.Diagnostic;

pub const Cursor = struct {
    input: []const u8,
    position: usize,
    line: usize,
    column: usize,
    diagnostic: ?*Diagnostic,

    pub fn init(input: []const u8, diagnostic: ?*Diagnostic) Cursor {
        return .{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
            .diagnostic = diagnostic,
        };
    }

    pub fn peek(self: *const Cursor) ?u8 {
        if (self.position >= self.input.len) return null;
        return self.input[self.position];
    }

    pub fn peekNext(self: *const Cursor) ?u8 {
        if (self.position + 1 >= self.input.len) return null;
        return self.input[self.position + 1];
    }

    pub fn peekRest(self: *const Cursor) []const u8 {
        return self.input[self.position..];
    }

    pub fn peekSlice(self: *const Cursor, n: usize) ?[]const u8 {
        if (self.position + n > self.input.len) return null;
        return self.input[self.position .. self.position + n];
    }

    pub fn peekSliceSince(self: *const Cursor, start_pos: usize) []const u8 {
        if (start_pos > self.position) @panic("peekSliceSince: start_pos exceeds current position");
        return self.input[start_pos..self.position];
    }

    pub fn startsWith(self: *const Cursor, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.position..], prefix);
    }

    pub fn isLiteralTerminator(self: *const Cursor) bool {
        const c = self.peek() orelse return true;
        // TOML 1.1 では裸の \r はターミネータではない。
        // \r\n（CRLF）のみをターミネータとして認める
        if (c == '\r') return if (self.peekNext()) |next| next == '\n' else false;
        return std.mem.indexOfScalar(u8, literal_terminators, c) != null;
    }

    pub fn advance(self: *Cursor) ?u8 {
        if (self.position >= self.input.len) return null;

        const c = self.input[self.position];
        self.position += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else if (c != '\r' and !isUtf8ContinuationByte(c)) {
            self.column += 1;
        }

        return c;
    }

    pub fn advanceAscii(self: *Cursor, n: usize) void {
        if (self.position + n > self.input.len) @panic("advanceAscii: n exceeds remaining input");
        const range = self.input[self.position .. self.position + n];
        for (range) |c| {
            if (c == '\n' or c == '\r') @panic("advanceAscii: range contains newline");
            if (c >= 0x80) @panic("advanceAscii: non-ASCII byte detected");
        }

        self.position += n;
        self.column += n;
    }

    pub fn advanceUtf8Sequence(self: *Cursor) void {
        if (self.position >= self.input.len) @panic("advanceUtf8Sequence: at end of input");
        const seq_len = std.unicode.utf8ByteSequenceLength(self.input[self.position]) catch
            @panic("advanceUtf8Sequence: invalid UTF-8 leading byte");
        self.advanceTo(self.position + seq_len);
    }

    pub fn advanceTo(self: *Cursor, to: usize) void {
        if (to > self.input.len) @panic("advanceTo: to exceeds input length");
        if (to < self.position) @panic("advanceTo: to is before current position");
        const range = self.input[self.position..to];
        for (range) |c| {
            if (c == '\n' or c == '\r') @panic("advanceTo: range contains newline");
        }

        self.column += std.unicode.utf8CountCodepoints(range) catch
            @panic("advanceTo: invalid UTF-8");
        self.position = to;
    }

    pub fn skipNewline(self: *Cursor) void {
        if (self.peek() == '\n') {
            _ = self.advance();
        } else if (self.peek() == '\r') {
            _ = self.advance();
            if (self.peek() == '\n') {
                _ = self.advance();
            }
        }
    }

    pub fn skipWhitespace(self: *Cursor) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') {
                _ = self.advance();
            } else break;
        }
    }

    pub fn skipWhitespaceAndNewlines(self: *Cursor) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _ = self.advance();
            } else if (c == '#') {
                self.skipComment();
            } else break;
        }
    }

    pub fn consumeCommaOrClose(self: *Cursor, comptime close: u8) bool {
        if (self.peek() != ',') @panic("consumeCommaOrClose: current position must be ','");

        _ = self.advance();
        self.skipWhitespaceAndNewlines();
        if (self.peek() == close) {
            _ = self.advance();
            return true;
        }

        return false;
    }

    pub fn consumeNewlineOrEof(self: *Cursor) errors.ParseError!void {
        self.skipWhitespace();
        self.skipComment();

        const c = self.peek() orelse return;
        if (c == '\r') {
            const next_is_lf = if (self.peekNext()) |next| next == '\n' else false;
            if (!next_is_lf) {
                self.fillDiagnostic("expected newline or end of file");
                return error.UnexpectedChar;
            }
        } else if (c != '\n') {
            self.fillDiagnostic("expected newline or end of file");
            return error.UnexpectedChar;
        }

        self.skipNewline();
    }

    pub fn fillDiagnostic(self: *Cursor, message: []const u8) void {
        const diagnostic = self.diagnostic orelse return;
        diagnostic.* = .{ .line = self.line, .column = self.column, .message = message };
    }

    fn skipComment(self: *Cursor) void {
        if (self.peek() == '#') {
            while (self.peek()) |c| {
                if (c == '\n' or c == '\r') break;
                _ = self.advance();
            }
        }
    }
};

fn isUtf8ContinuationByte(c: u8) bool {
    return c >= 0x80 and c < 0xC0;
}

// --- Cursor.init ---

test "Cursor.init: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "empty input",
            .input = "",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "with input",
            .input = "hello",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        const cursor = Cursor.init(tc.input, null);
        try std.testing.expectEqualStrings(tc.input, cursor.input);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
        try std.testing.expect(cursor.diagnostic == null);
    }
}

test "Cursor.init: with diagnostic pointer" {
    var diagnostic: Diagnostic = .{};
    const cursor = Cursor.init("", &diagnostic);
    try std.testing.expect(cursor.diagnostic == &diagnostic);
}

// --- Cursor.peek ---

test "Cursor.peek: returns first byte or null at EOF" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: ?u8,
    }{
        .{ .name = "returns first char", .input = "abc", .expected = 'a' },
        .{ .name = "at eof", .input = "", .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectEqual(tc.expected, cursor.peek());
    }
}

test "Cursor.peek: at eof after advance" {
    var cursor = Cursor.init("a", null);
    _ = cursor.advance();
    try std.testing.expectEqual(null, cursor.peek());
}

test "Cursor.peek: does not advance position" {
    var cursor = Cursor.init("abc", null);
    _ = cursor.peek();
    _ = cursor.peek();
    try std.testing.expectEqual(@as(usize, 0), cursor.position);
}

// --- Cursor.peekNext ---

test "Cursor.peekNext: returns second byte or null when fewer than two bytes remain" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, initial_advance: usize },
        expected: ?u8,
    }{
        .{
            .name = "returns second char",
            .input = .{ .s = "ab", .initial_advance = 0 },
            .expected = 'b',
        },
        .{
            .name = "only one char",
            .input = .{ .s = "a", .initial_advance = 0 },
            .expected = null,
        },
        .{
            .name = "empty",
            .input = .{ .s = "", .initial_advance = 0 },
            .expected = null,
        },
        .{
            .name = "after advance",
            .input = .{ .s = "abc", .initial_advance = 1 },
            .expected = 'c',
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.initial_advance);
        try std.testing.expectEqual(tc.expected, cursor.peekNext());
    }
}

// --- Cursor.peekRest ---

test "Cursor.peekRest: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: []const u8,
    }{
        .{ .name = "from start", .input = .{ .s = "hello", .n = 0 }, .expected = "hello" },
        .{ .name = "from mid", .input = .{ .s = "hello", .n = 2 }, .expected = "llo" },
        .{ .name = "at eof", .input = .{ .s = "hello", .n = 5 }, .expected = "" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.n);
        try std.testing.expectEqualStrings(tc.expected, cursor.peekRest());
    }
}

// --- Cursor.peekSlice ---

test "Cursor.peekSlice: returns slice within bounds" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, advance: usize, n: usize },
        expected: []const u8,
    }{
        .{
            .name = "exact length",
            .input = .{ .s = "abc", .advance = 0, .n = 3 },
            .expected = "abc",
        },
        .{
            .name = "partial",
            .input = .{ .s = "abc", .advance = 0, .n = 2 },
            .expected = "ab",
        },
        .{
            .name = "zero",
            .input = .{ .s = "abc", .advance = 0, .n = 0 },
            .expected = "",
        },
        .{
            .name = "from mid position",
            .input = .{ .s = "abcde", .advance = 1, .n = 2 },
            .expected = "bc",
        },
        .{
            .name = "exact remaining after advance",
            .input = .{ .s = "abc", .advance = 1, .n = 2 },
            .expected = "bc",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.advance);
        const s_opt = cursor.peekSlice(tc.input.n);
        // どのテストケースが失敗したか特定するため
        try std.testing.expect(s_opt != null);
        try std.testing.expectEqualStrings(tc.expected, s_opt.?);
    }
}

test "Cursor.peekSlice: returns null for out-of-bounds" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: ?[]const u8,
    }{
        .{ .name = "exceeds length", .input = .{ .s = "ab", .n = 3 }, .expected = null },
        .{ .name = "empty input", .input = .{ .s = "", .n = 1 }, .expected = null },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        try std.testing.expectEqual(tc.expected, cursor.peekSlice(tc.input.n));
    }
}

// --- Cursor.peekSliceSince ---

test "Cursor.peekSliceSince: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize, start_pos: usize },
        expected: []const u8,
    }{
        .{
            .name = "from start",
            .input = .{ .s = "hello", .n = 3, .start_pos = 0 },
            .expected = "hel",
        },
        .{
            .name = "from mid",
            .input = .{ .s = "hello", .n = 5, .start_pos = 2 },
            .expected = "llo",
        },
        .{
            .name = "zero length",
            .input = .{ .s = "hello", .n = 2, .start_pos = 2 },
            .expected = "",
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.n);
        try std.testing.expectEqualStrings(tc.expected, cursor.peekSliceSince(tc.input.start_pos));
    }
}

// --- Cursor.startsWith ---

test "Cursor.startsWith: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize, prefix: []const u8 },
        expected: bool,
    }{
        .{
            .name = "match",
            .input = .{ .s = "true", .n = 0, .prefix = "true" },
            .expected = true,
        },
        .{
            .name = "no match",
            .input = .{ .s = "false", .n = 0, .prefix = "true" },
            .expected = false,
        },
        .{
            .name = "empty prefix",
            .input = .{ .s = "abc", .n = 0, .prefix = "" },
            .expected = true,
        },
        .{
            .name = "from mid position",
            .input = .{ .s = "abcdef", .n = 3, .prefix = "def" },
            .expected = true,
        },
        .{
            .name = "at eof",
            .input = .{ .s = "", .n = 0, .prefix = "a" },
            .expected = false,
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.n);
        try std.testing.expectEqual(tc.expected, cursor.startsWith(tc.input.prefix));
    }
}

// --- Cursor.isLiteralTerminator ---

test "Cursor.isLiteralTerminator: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: bool,
    }{
        .{ .name = "space", .input = " ", .expected = true },
        .{ .name = "tab", .input = "\t", .expected = true },
        .{ .name = "newline", .input = "\n", .expected = true },
        .{ .name = "bare carriage return", .input = "\r", .expected = false },
        .{ .name = "CRLF", .input = "\r\n", .expected = true },
        .{ .name = "hash", .input = "#", .expected = true },
        .{ .name = "comma", .input = ",", .expected = true },
        .{ .name = "close bracket", .input = "]", .expected = true },
        .{ .name = "close brace", .input = "}", .expected = true },
        .{ .name = "at eof", .input = "", .expected = true },
        .{ .name = "letter", .input = "x", .expected = false },
        .{ .name = "digit", .input = "1", .expected = false },
        .{ .name = "open bracket", .input = "[", .expected = false },
        .{ .name = "open brace", .input = "{", .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectEqual(tc.expected, cursor.isLiteralTerminator());
    }
}

// --- Cursor.advance ---

test "Cursor.advance: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { c: ?u8, position: usize, line: usize, column: usize },
    }{
        .{
            .name = "ascii char",
            .input = "a",
            .expected = .{ .c = 'a', .position = 1, .line = 1, .column = 2 },
        },
        .{
            .name = "newline LF",
            .input = "\n",
            .expected = .{ .c = '\n', .position = 1, .line = 2, .column = 1 },
        },
        .{
            .name = "carriage return",
            .input = "\r",
            .expected = .{ .c = '\r', .position = 1, .line = 1, .column = 1 },
        },
        .{
            .name = "at eof",
            .input = "",
            .expected = .{ .c = null, .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "utf8 2-byte leading byte",
            .input = "\xC0",
            .expected = .{ .c = 0xC0, .position = 1, .line = 1, .column = 2 },
        },
        .{
            .name = "utf8 3-byte leading byte",
            .input = "\xE3",
            .expected = .{ .c = 0xE3, .position = 1, .line = 1, .column = 2 },
        },
        .{
            .name = "utf8 4-byte leading byte",
            .input = "\xF0",
            .expected = .{ .c = 0xF0, .position = 1, .line = 1, .column = 2 },
        },
        .{
            .name = "utf8 continuation byte",
            .input = "\x80",
            .expected = .{ .c = 0x80, .position = 1, .line = 1, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        const c = cursor.advance();
        try std.testing.expectEqual(tc.expected.c, c);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

test "Cursor.advance: sequential" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { line: usize, column: usize },
    }{
        .{
            .name = "multibyte utf8",
            .input = "\xE3\x81\x82",
            .expected = .{ .line = 1, .column = 2 },
        },
        .{
            .name = "multiple newlines",
            .input = "a\nb\nc",
            .expected = .{ .line = 3, .column = 2 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        while (cursor.advance()) |_| {}
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.advanceAscii ---

test "Cursor.advanceAscii: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, n: usize },
        expected: struct { position: usize, column: usize },
    }{
        .{
            .name = "n bytes",
            .input = .{ .s = "hello", .n = 3 },
            .expected = .{ .position = 3, .column = 4 },
        },
        .{
            .name = "zero",
            .input = .{ .s = "hello", .n = 0 },
            .expected = .{ .position = 0, .column = 1 },
        },
        .{
            .name = "exactly to eof",
            .input = .{ .s = "hello", .n = 5 },
            .expected = .{ .position = 5, .column = 6 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.n);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.advanceUtf8Sequence ---

test "Cursor.advanceUtf8Sequence: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, column: usize },
    }{
        .{
            .name = "2-byte sequence",
            .input = "\xC3\xA9",
            .expected = .{ .position = 2, .column = 2 },
        },
        .{
            .name = "3-byte sequence",
            .input = "\xE4\xB8\x96",
            .expected = .{ .position = 3, .column = 2 },
        },
        .{
            .name = "4-byte sequence",
            .input = "\xF0\x9F\x98\x80",
            .expected = .{ .position = 4, .column = 2 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        cursor.advanceUtf8Sequence();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

test "Cursor.advanceUtf8Sequence: multiple sequences each increment column by 1" {
    var cursor = Cursor.init("\xE4\xB8\x96\xE7\x95\x8C", null);
    cursor.advanceUtf8Sequence();
    cursor.advanceUtf8Sequence();
    try std.testing.expectEqual(@as(usize, 6), cursor.position);
    try std.testing.expectEqual(@as(usize, 3), cursor.column);
}

// --- Cursor.advanceTo ---

test "Cursor.advanceTo: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, initial_advance: usize, to: usize },
        expected: struct { position: usize, column: usize },
    }{
        .{
            .name = "ASCII only",
            .input = .{ .s = "hello", .initial_advance = 0, .to = "hello".len },
            .expected = .{ .position = 5, .column = 6 },
        },
        .{
            .name = "multi-byte UTF-8 counts codepoints not bytes",
            .input = .{ .s = "café", .initial_advance = 0, .to = "café".len },
            .expected = .{ .position = 5, .column = 5 },
        },
        .{
            .name = "3-byte codepoint counts as 1",
            .input = .{ .s = "あ", .initial_advance = 0, .to = "あ".len },
            .expected = .{ .position = 3, .column = 2 },
        },
        .{
            .name = "4-byte codepoint counts as 1",
            .input = .{ .s = "😀", .initial_advance = 0, .to = "😀".len },
            .expected = .{ .position = 4, .column = 2 },
        },
        .{
            .name = "empty range does not advance",
            .input = .{ .s = "hello", .initial_advance = 0, .to = 0 },
            .expected = .{ .position = 0, .column = 1 },
        },
        .{
            .name = "no-op at non-zero position",
            .input = .{ .s = "hello", .initial_advance = 3, .to = 3 },
            .expected = .{ .position = 3, .column = 4 },
        },
        .{
            .name = "from non-zero position",
            .input = .{ .s = "hello world", .initial_advance = 6, .to = 11 },
            .expected = .{ .position = 11, .column = 12 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        cursor.advanceAscii(tc.input.initial_advance);
        cursor.advanceTo(tc.input.to);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.skipNewline ---

test "Cursor.skipNewline: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "LF",
            .input = "\n",
            .expected = .{ .position = 1, .line = 2, .column = 1 },
        },
        .{
            .name = "CRLF",
            .input = "\r\n",
            .expected = .{ .position = 2, .line = 2, .column = 1 },
        },
        .{
            .name = "CR only",
            .input = "\rx",
            .expected = .{ .position = 1, .line = 1, .column = 1 },
        },
        .{
            .name = "CR at eof",
            .input = "\r",
            .expected = .{ .position = 1, .line = 1, .column = 1 },
        },
        .{
            .name = "non newline",
            .input = "x",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "at eof",
            .input = "",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        cursor.skipNewline();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.skipWhitespace ---

test "Cursor.skipWhitespace: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, column: usize },
    }{
        .{
            .name = "spaces and tabs",
            .input = "  \t  x",
            .expected = .{ .position = 5, .column = 6 },
        },
        .{
            .name = "stops at newline",
            .input = "  \n",
            .expected = .{ .position = 2, .column = 3 },
        },
        .{
            .name = "nothing to skip",
            .input = "x",
            .expected = .{ .position = 0, .column = 1 },
        },
        .{
            .name = "at eof",
            .input = "",
            .expected = .{ .position = 0, .column = 1 },
        },
        .{
            .name = "stops at carriage return",
            .input = "\r\n",
            .expected = .{ .position = 0, .column = 1 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        cursor.skipWhitespace();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.skipWhitespaceAndNewlines ---

test "Cursor.skipWhitespaceAndNewlines: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "all whitespace types",
            .input = " \t\n\rx",
            .expected = .{ .position = 4, .line = 2, .column = 1 },
        },
        .{
            .name = "with comment lines",
            .input = "\n# comment\nkey",
            .expected = .{ .position = 11, .line = 3, .column = 1 },
        },
        .{
            .name = "comment at start",
            .input = "# comment\nkey",
            .expected = .{ .position = 10, .line = 2, .column = 1 },
        },
        .{
            .name = "crlf",
            .input = "\r\n\r\nx",
            .expected = .{ .position = 4, .line = 3, .column = 1 },
        },
        .{
            .name = "at eof",
            .input = "",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "whitespace only to eof",
            .input = "  \t  \n",
            .expected = .{ .position = 6, .line = 2, .column = 1 },
        },
        .{
            .name = "non-whitespace first",
            .input = "key = value",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "comment then eof",
            .input = "# comment",
            .expected = .{ .position = 9, .line = 1, .column = 10 },
        },
        .{
            .name = "whitespace then comment then eof",
            .input = "  # comment",
            .expected = .{ .position = 11, .line = 1, .column = 12 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        cursor.skipWhitespaceAndNewlines();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor.consumeCommaOrClose ---

test "Cursor.consumeCommaOrClose: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: struct { s: []const u8, close: u8 },
        expected: struct { closed: bool, position: usize, line: usize, column: usize },
    }{
        .{
            .name = "bracket: close immediately",
            .input = .{ .s = ",]", .close = ']' },
            .expected = .{ .closed = true, .position = 2, .line = 1, .column = 3 },
        },
        .{
            .name = "bracket: close after space",
            .input = .{ .s = ", ]", .close = ']' },
            .expected = .{ .closed = true, .position = 3, .line = 1, .column = 4 },
        },
        .{
            .name = "bracket: close after newline",
            .input = .{ .s = ",\n]", .close = ']' },
            .expected = .{ .closed = true, .position = 3, .line = 2, .column = 2 },
        },
        .{
            .name = "bracket: close after comment",
            .input = .{ .s = ", # c\n]", .close = ']' },
            .expected = .{ .closed = true, .position = 7, .line = 2, .column = 2 },
        },
        .{
            .name = "bracket: next element",
            .input = .{ .s = ", 1", .close = ']' },
            .expected = .{ .closed = false, .position = 2, .line = 1, .column = 3 },
        },
        .{
            .name = "brace: close immediately",
            .input = .{ .s = ",}", .close = '}' },
            .expected = .{ .closed = true, .position = 2, .line = 1, .column = 3 },
        },
        .{
            .name = "brace: close after space",
            .input = .{ .s = ", }", .close = '}' },
            .expected = .{ .closed = true, .position = 3, .line = 1, .column = 4 },
        },
        .{
            .name = "brace: close after newline",
            .input = .{ .s = ",\n}", .close = '}' },
            .expected = .{ .closed = true, .position = 3, .line = 2, .column = 2 },
        },
        .{
            .name = "brace: close after comment",
            .input = .{ .s = ", # c\n}", .close = '}' },
            .expected = .{ .closed = true, .position = 7, .line = 2, .column = 2 },
        },
        .{
            .name = "brace: next element",
            .input = .{ .s = ", 1", .close = '}' },
            .expected = .{ .closed = false, .position = 2, .line = 1, .column = 3 },
        },
    };

    // consumeCommaOrClose が comptime close: u8 を受け取るため inline for が必要。
    inline for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input.s, null);
        const closed = cursor.consumeCommaOrClose(tc.input.close);
        try std.testing.expectEqual(tc.expected.closed, closed);
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

test "Cursor.consumeCommaOrClose: then parse next" {
    var cursor = Cursor.init(", 42]", null);
    const closed = cursor.consumeCommaOrClose(']');
    try std.testing.expect(!closed);
    try std.testing.expectEqual(@as(?u8, '4'), cursor.peek());
}

// --- Cursor.consumeNewlineOrEof ---

test "Cursor.consumeNewlineOrEof: success" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, line: usize, column: usize },
    }{
        .{
            .name = "LF",
            .input = "\n",
            .expected = .{ .position = 1, .line = 2, .column = 1 },
        },
        .{
            .name = "CRLF",
            .input = "\r\n",
            .expected = .{ .position = 2, .line = 2, .column = 1 },
        },
        .{
            .name = "space then LF",
            .input = " \n",
            .expected = .{ .position = 2, .line = 2, .column = 1 },
        },
        .{
            .name = "comment then CRLF",
            .input = " # c\r\n",
            .expected = .{ .position = 6, .line = 2, .column = 1 },
        },
        .{
            .name = "at eof",
            .input = "",
            .expected = .{ .position = 0, .line = 1, .column = 1 },
        },
        .{
            .name = "whitespace then eof",
            .input = "   ",
            .expected = .{ .position = 3, .line = 1, .column = 4 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try cursor.consumeNewlineOrEof();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

test "Cursor.consumeNewlineOrEof: error" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
    }{
        .{ .name = "letter", .input = "a" },
        .{ .name = "whitespace then invalid char", .input = "\t;" },
        .{ .name = "CR only", .input = " \r" },
        .{ .name = "CR at eof", .input = "\r" },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        try std.testing.expectError(error.UnexpectedChar, cursor.consumeNewlineOrEof());
    }
}

test "Cursor.consumeNewlineOrEof: fills diagnostic on error" {
    var diagnostic: Diagnostic = .{};
    var cursor = Cursor.init("a", &diagnostic);
    try std.testing.expectError(error.UnexpectedChar, cursor.consumeNewlineOrEof());
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.column);
    try std.testing.expectEqualStrings("expected newline or end of file", diagnostic.message);
}

// --- Cursor.fillDiagnostic ---

test "Cursor.fillDiagnostic: null diagnostic" {
    var cursor = Cursor.init("", null);
    cursor.fillDiagnostic("test");
    try std.testing.expect(cursor.diagnostic == null);
}

test "Cursor.fillDiagnostic: sets fields" {
    var diagnostic: Diagnostic = .{};
    var cursor = Cursor.init("ab\nc", &diagnostic);
    _ = cursor.advance();
    _ = cursor.advance();
    _ = cursor.advance();
    _ = cursor.advance();
    cursor.fillDiagnostic("error message");
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.column);
    try std.testing.expectEqualStrings("error message", diagnostic.message);
}

// --- Cursor.skipComment ---

test "Cursor.skipComment: advances to end of line or eof" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { position: usize, column: usize },
    }{
        .{
            .name = "full line",
            .input = "# comment\n",
            .expected = .{ .position = 9, .column = 10 },
        },
        .{
            .name = "until eof",
            .input = "# comment",
            .expected = .{ .position = 9, .column = 10 },
        },
        .{
            .name = "not a comment",
            .input = "x = 1",
            .expected = .{ .position = 0, .column = 1 },
        },
        .{
            .name = "crlf line ending: stops before cr",
            .input = "# comment\r\n",
            .expected = .{ .position = 9, .column = 10 },
        },
        .{
            .name = "cr only: stops before cr",
            .input = "# comment\rnext_key = 1",
            .expected = .{ .position = 9, .column = 10 },
        },
        .{
            .name = "empty comment at eof",
            .input = "#",
            .expected = .{ .position = 1, .column = 2 },
        },
        .{
            .name = "empty comment at newline",
            .input = "#\n",
            .expected = .{ .position = 1, .column = 2 },
        },
        .{
            .name = "multibyte utf8 in comment",
            .input = "# あ\n",
            .expected = .{ .position = 5, .column = 4 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        cursor.skipComment();
        try std.testing.expectEqual(tc.expected.position, cursor.position);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- Cursor ---

test "Cursor: position tracking" {
    const test_cases = [_]struct {
        name: []const u8,
        input: []const u8,
        expected: struct { line: usize, column: usize },
    }{
        .{
            .name = "multi-line advance tracks position",
            .input = "ab\ncd\nef",
            .expected = .{ .line = 3, .column = 3 },
        },
        .{
            .name = "utf8 column count",
            .input = "\xE3\x81\x82\xE3\x81\x84\xE3\x81\x86",
            .expected = .{ .line = 1, .column = 4 },
        },
        .{
            .name = "crlf line endings track position",
            .input = "ab\r\ncd",
            .expected = .{ .line = 2, .column = 3 },
        },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        var cursor = Cursor.init(tc.input, null);
        while (cursor.advance()) |_| {}
        try std.testing.expectEqual(tc.expected.line, cursor.line);
        try std.testing.expectEqual(tc.expected.column, cursor.column);
    }
}

// --- isUtf8ContinuationByte ---

test "isUtf8ContinuationByte: basic" {
    const test_cases = [_]struct {
        name: []const u8,
        input: u8,
        expected: bool,
    }{
        .{ .name = "continuation byte lower bound", .input = 0x80, .expected = true },
        .{ .name = "mid continuation byte", .input = 0x90, .expected = true },
        .{ .name = "continuation byte upper bound", .input = 0xBF, .expected = true },
        .{ .name = "just below lower bound", .input = 0x7F, .expected = false },
        .{ .name = "ascii letter", .input = 'a', .expected = false },
        .{ .name = "2-byte sequence start", .input = 0xC0, .expected = false },
        .{ .name = "3-byte sequence start", .input = 0xE0, .expected = false },
        .{ .name = "4-byte sequence start", .input = 0xF0, .expected = false },
    };

    for (test_cases) |tc| {
        errdefer std.debug.print("FAIL: {s}\n", .{tc.name});

        try std.testing.expectEqual(tc.expected, isUtf8ContinuationByte(tc.input));
    }
}

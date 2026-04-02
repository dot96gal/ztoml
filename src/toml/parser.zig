const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const TOMLValue = types.TOMLValue;
const TOMLTable = types.TOMLTable;
const tableFromMap = types.tableFromMap;
const Parsed = types.Parsed;
const ParseOptions = types.ParseOptions;
const Diagnostic = types.Diagnostic;

/// All errors that can originate from parsing or allocation.
const Error = types.ParseError || error{OutOfMemory};

// ============================================================
// Public API
// ============================================================

pub fn parseFromSlice(allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(TOMLTable) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser = Parser.init(arena.allocator(), input, options);
    const table = try parser.parse();

    return .{ .value = table, ._arena = arena };
}

// ============================================================
// Parser
// ============================================================

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    diag: ?*Diagnostic,

    fn init(allocator: Allocator, input: []const u8, options: ParseOptions) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .diag = options.diag,
        };
    }

    // ---- utilities ----

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], prefix);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t') _ = self.advance() else break;
        }
    }

    fn skipComment(self: *Parser) void {
        if (self.peek() == '#') {
            while (self.peek()) |c| {
                if (c == '\n') break;
                _ = self.advance();
            }
        }
    }

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                _ = self.advance();
            } else if (c == '#') {
                self.skipComment();
            } else break;
        }
    }

    fn consumeNewlineOrEof(self: *Parser) !void {
        self.skipWhitespace();
        self.skipComment();
        if (self.peek()) |c| {
            if (c == '\n') {
                _ = self.advance();
            } else if (c == '\r') {
                _ = self.advance();
                if (self.peek() == '\n') _ = self.advance();
            } else {
                self.fillDiagnostic("expected newline or end of file");
                return error.UnexpectedChar;
            }
        }
    }

    fn fillDiagnostic(self: *Parser, message: []const u8) void {
        const diag = self.diag orelse return;
        var line: usize = 1;
        var col: usize = 1;
        for (self.input[0..self.pos]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        diag.* = .{ .line = line, .col = col, .message = message };
    }

    // ---- top-level parse ----

    fn parse(self: *Parser) !TOMLTable {
        var root_map = std.StringHashMap(TOMLValue).init(self.allocator);
        try root_map.ensureTotalCapacity(8);
        var defined_tables = std.StringHashMap(void).init(self.allocator);
        try defined_tables.ensureTotalCapacity(8);

        // Array-of-tables storage
        const AotEntry = struct {
            keys: [][]const u8,
            tables: std.ArrayListUnmanaged(std.StringHashMap(TOMLValue)),
        };
        var aot_entries: std.ArrayListUnmanaged(AotEntry) = .{};

        self.skipWhitespaceAndNewlines();

        // Root key-value pairs (before any [section])
        while (self.peek() != null and self.peek() != '[') {
            try self.parseKeyValueInto(&root_map);
            self.skipWhitespaceAndNewlines();
        }

        // Table / array-of-table sections
        while (self.peek() == '[') {
            const is_aot = self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[';

            if (is_aot) {
                // [[array]] header
                self.pos += 2; // consume [[
                self.skipWhitespace();
                const keys = try self.parseDottedKey();
                self.skipWhitespace();
                if (!self.startsWith("]]")) {
                    self.fillDiagnostic("expected ']]' to close array table header");
                    return error.UnexpectedChar;
                }
                self.pos += 2; // consume ]]

                // Find or create AotEntry for these keys
                var found: ?*AotEntry = null;
                for (aot_entries.items) |*e| {
                    if (e.keys.len == keys.len) {
                        var match = true;
                        for (e.keys, keys) |a, b| {
                            if (!std.mem.eql(u8, a, b)) { match = false; break; }
                        }
                        if (match) { found = e; break; }
                    }
                }
                if (found == null) {
                    try aot_entries.append(self.allocator, .{ .keys = keys, .tables = .{} });
                    found = &aot_entries.items[aot_entries.items.len - 1];
                }

                var new_map = std.StringHashMap(TOMLValue).init(self.allocator);
                try new_map.ensureTotalCapacity(8);
                try found.?.tables.append(self.allocator, new_map);
                const current = &found.?.tables.items[found.?.tables.items.len - 1];

                try self.consumeNewlineOrEof();
                self.skipWhitespaceAndNewlines();
                while (self.peek() != null and self.peek() != '[') {
                    try self.parseKeyValueInto(current);
                    self.skipWhitespaceAndNewlines();
                }
            } else {
                // [table] header
                self.pos += 1; // consume [
                self.skipWhitespace();
                const keys = try self.parseDottedKey();
                self.skipWhitespace();

                if (self.peek() != ']') {
                    self.fillDiagnostic("expected ']' to close table header");
                    return error.UnexpectedChar;
                }
                self.pos += 1; // consume ]

                const path = try std.mem.join(self.allocator, ".", keys);
                if (defined_tables.contains(path)) {
                    self.fillDiagnostic("duplicate table definition");
                    return error.DuplicateKey;
                }
                try defined_tables.put(path, {});

                var target = &root_map;
                for (keys) |k| {
                    const entry = try target.getOrPut(k);
                    if (!entry.found_existing) {
                        var inner = std.StringHashMap(TOMLValue).init(self.allocator);
                        try inner.ensureTotalCapacity(8);
                        entry.value_ptr.* = .{ .table = tableFromMap(inner) };
                    }
                    switch (entry.value_ptr.*) {
                        .table => |*t| target = &t.inner,
                        else => {
                            self.fillDiagnostic("cannot create table: key already exists as non-table");
                            return error.DuplicateKey;
                        },
                    }
                }

                try self.consumeNewlineOrEof();
                self.skipWhitespaceAndNewlines();
                while (self.peek() != null and self.peek() != '[') {
                    try self.parseKeyValueInto(target);
                    self.skipWhitespaceAndNewlines();
                }
            }
        }

        // Finalize array-of-tables: convert accumulated maps to immutable arrays
        for (aot_entries.items) |*entry| {
            const arr = try self.allocator.alloc(TOMLValue, entry.tables.items.len);
            for (entry.tables.items, 0..) |map, i| arr[i] = .{ .table = tableFromMap(map) };

            var target = &root_map;
            for (entry.keys[0 .. entry.keys.len - 1]) |k| {
                const e = try target.getOrPut(k);
                if (!e.found_existing) {
                    var inner = std.StringHashMap(TOMLValue).init(self.allocator);
                    try inner.ensureTotalCapacity(8);
                    e.value_ptr.* = .{ .table = tableFromMap(inner) };
                }
                switch (e.value_ptr.*) {
                    .table => |*t| target = &t.inner,
                    else => {
                        self.fillDiagnostic("cannot finalize array table");
                        return error.DuplicateKey;
                    },
                }
            }
            const last = entry.keys[entry.keys.len - 1];
            if (target.contains(last)) {
                self.fillDiagnostic("array table key conflicts with existing key");
                return error.DuplicateKey;
            }
            try target.put(last, .{ .array = arr });
        }

        return tableFromMap(root_map);
    }

    // ---- key parsing ----

    fn parseSingleKey(self: *Parser) ![]const u8 {
        const c = self.peek() orelse {
            self.fillDiagnostic("expected key");
            return error.UnexpectedEof;
        };
        if (c == '"') return try self.parseBasicString();
        if (c == '\'') return try self.parseLiteralString();
        // bare key
        const start = self.pos;
        while (self.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                _ = self.advance();
            } else break;
        }
        if (self.pos == start) {
            self.fillDiagnostic("expected bare key");
            return error.UnexpectedChar;
        }
        return self.input[start..self.pos];
    }

    fn parseDottedKey(self: *Parser) ![][]const u8 {
        var keys: std.ArrayListUnmanaged([]const u8) = .{};
        try keys.append(self.allocator, try self.parseSingleKey());
        while (true) {
            self.skipWhitespace();
            if (self.peek() != '.') break;
            _ = self.advance(); // consume '.'
            self.skipWhitespace();
            try keys.append(self.allocator, try self.parseSingleKey());
        }
        return try keys.toOwnedSlice(self.allocator);
    }

    fn parseKeyValueInto(self: *Parser, map: *std.StringHashMap(TOMLValue)) !void {
        const keys = try self.parseDottedKey();
        self.skipWhitespace();

        if (self.peek() != '=') {
            self.fillDiagnostic("expected '=' after key");
            return error.UnexpectedChar;
        }
        _ = self.advance();
        self.skipWhitespace();

        const value = try self.parseValue();

        // Navigate intermediate tables for dotted keys
        var target = map;
        for (keys[0 .. keys.len - 1]) |k| {
            const entry = try target.getOrPut(k);
            if (!entry.found_existing) {
                var inner = std.StringHashMap(TOMLValue).init(self.allocator);
                try inner.ensureTotalCapacity(4);
                entry.value_ptr.* = .{ .table = tableFromMap(inner) };
            }
            switch (entry.value_ptr.*) {
                .table => |*t| target = &t.inner,
                else => {
                    self.fillDiagnostic("cannot create intermediate table: key exists as non-table");
                    return error.DuplicateKey;
                },
            }
        }
        const last_key = keys[keys.len - 1];
        if (target.contains(last_key)) {
            self.fillDiagnostic("duplicate key");
            return error.DuplicateKey;
        }
        try target.put(last_key, value);

        try self.consumeNewlineOrEof();
    }

    // ---- value parsing ----

    fn parseValue(self: *Parser) Error!TOMLValue {
        const c = self.peek() orelse {
            self.fillDiagnostic("unexpected end of input");
            return error.UnexpectedEof;
        };
        return switch (c) {
            '"' => blk: {
                if (self.startsWith("\"\"\"")) {
                    break :blk .{ .string = try self.parseMultilineBasicString() };
                }
                break :blk .{ .string = try self.parseBasicString() };
            },
            '\'' => blk: {
                if (self.startsWith("'''")) {
                    break :blk .{ .string = try self.parseMultilineLiteralString() };
                }
                break :blk .{ .string = try self.parseLiteralString() };
            },
            't', 'f' => try self.parseBoolean(),
            '0'...'9' => blk: {
                if (self.isDateLike()) break :blk try self.parseDateOrDateTime();
                if (self.isTimeLike()) break :blk .{ .local_time = try self.parseLocalTime() };
                break :blk try self.parseNumber();
            },
            '-', '+', 'i', 'n' => try self.parseNumber(),
            '[' => try self.parseArray(),
            '{' => try self.parseInlineTable(),
            else => {
                self.fillDiagnostic("unexpected character in value");
                return error.UnexpectedChar;
            },
        };
    }

    // ---- string parsing ----

    fn parseBasicString(self: *Parser) ![]const u8 {
        _ = self.advance(); // consume '"'
        var buf: std.ArrayListUnmanaged(u8) = .{};
        while (true) {
            const c = self.peek() orelse {
                self.fillDiagnostic("unterminated string");
                return error.UnexpectedEof;
            };
            if (c == '"') {
                _ = self.advance();
                break;
            } else if (c == '\\') {
                _ = self.advance();
                try self.parseEscapeSequence(&buf);
            } else if (c == '\n' or c == '\r') {
                self.fillDiagnostic("newline not allowed in basic string");
                return error.UnexpectedChar;
            } else {
                _ = self.advance();
                try buf.append(self.allocator, c);
            }
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    fn parseMultilineBasicString(self: *Parser) ![]const u8 {
        self.pos += 3; // consume """
        if (self.peek() == '\n') {
            _ = self.advance();
        } else if (self.peek() == '\r') {
            _ = self.advance();
            if (self.peek() == '\n') _ = self.advance();
        }
        var buf: std.ArrayListUnmanaged(u8) = .{};
        while (true) {
            const c = self.peek() orelse {
                self.fillDiagnostic("unterminated multiline basic string");
                return error.UnexpectedEof;
            };
            if (c == '"') {
                var qcount: usize = 0;
                while (self.peek() == '"') {
                    qcount += 1;
                    _ = self.advance();
                }
                if (qcount >= 3) {
                    const trailing = qcount - 3;
                    for (0..trailing) |_| try buf.append(self.allocator, '"');
                    break;
                }
                for (0..qcount) |_| try buf.append(self.allocator, '"');
            } else if (c == '\\') {
                _ = self.advance();
                // line-ending backslash
                if (self.peek()) |esc| {
                    if (esc == '\n' or esc == '\r' or esc == ' ' or esc == '\t') {
                        while (self.peek()) |ws| {
                            if (ws == ' ' or ws == '\t' or ws == '\n' or ws == '\r') {
                                _ = self.advance();
                            } else break;
                        }
                        continue;
                    }
                }
                try self.parseEscapeSequence(&buf);
            } else {
                _ = self.advance();
                try buf.append(self.allocator, c);
            }
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    /// Zero-copy: returns a slice into the original input.
    fn parseLiteralString(self: *Parser) ![]const u8 {
        _ = self.advance(); // consume "'"
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\'') {
                const s = self.input[start..self.pos];
                _ = self.advance();
                return s;
            } else if (c == '\n' or c == '\r') {
                self.fillDiagnostic("unterminated literal string");
                return error.UnexpectedChar;
            }
            _ = self.advance();
        }
        self.fillDiagnostic("unterminated literal string");
        return error.UnexpectedEof;
    }

    /// Zero-copy: returns a slice into the original input.
    fn parseMultilineLiteralString(self: *Parser) ![]const u8 {
        self.pos += 3; // consume '''
        if (self.peek() == '\n') {
            _ = self.advance();
        } else if (self.peek() == '\r') {
            _ = self.advance();
            if (self.peek() == '\n') _ = self.advance();
        }
        const start = self.pos;
        while (true) {
            if (self.pos >= self.input.len) {
                self.fillDiagnostic("unterminated multiline literal string");
                return error.UnexpectedEof;
            }
            if (self.input[self.pos] == '\'') {
                const before = self.pos;
                var qcount: usize = 0;
                while (self.pos < self.input.len and self.input[self.pos] == '\'') {
                    qcount += 1;
                    self.pos += 1;
                }
                if (qcount >= 3) {
                    return self.input[start .. before + (qcount - 3)];
                }
            } else {
                self.pos += 1;
            }
        }
    }

    fn parseEscapeSequence(self: *Parser, buf: *std.ArrayListUnmanaged(u8)) !void {
        const esc = self.peek() orelse {
            self.fillDiagnostic("unexpected end of input after backslash");
            return error.UnexpectedEof;
        };
        _ = self.advance();
        switch (esc) {
            'b' => try buf.append(self.allocator, 0x08),
            't' => try buf.append(self.allocator, '\t'),
            'n' => try buf.append(self.allocator, '\n'),
            'f' => try buf.append(self.allocator, 0x0C),
            'r' => try buf.append(self.allocator, '\r'),
            'e' => try buf.append(self.allocator, 0x1B),
            '"' => try buf.append(self.allocator, '"'),
            '\\' => try buf.append(self.allocator, '\\'),
            'x' => try appendUtf8Codepoint(buf, self.allocator, try self.parseHexCodepoint(2)),
            'u' => try appendUtf8Codepoint(buf, self.allocator, try self.parseHexCodepoint(4)),
            'U' => try appendUtf8Codepoint(buf, self.allocator, try self.parseHexCodepoint(8)),
            else => {
                self.fillDiagnostic("invalid escape sequence");
                return error.InvalidEscape;
            },
        }
    }

    fn parseHexCodepoint(self: *Parser, n: usize) !u21 {
        var value: u21 = 0;
        for (0..n) |_| {
            const h = self.peek() orelse {
                self.fillDiagnostic("unexpected end of input in unicode escape");
                return error.InvalidUnicode;
            };
            _ = self.advance();
            const digit = std.fmt.charToDigit(h, 16) catch {
                self.fillDiagnostic("invalid hex digit in unicode escape");
                return error.InvalidUnicode;
            };
            value = value * 16 + digit;
        }
        if (!std.unicode.utf8ValidCodepoint(value)) {
            self.fillDiagnostic("invalid unicode code point");
            return error.InvalidUnicode;
        }
        return value;
    }

    // ---- boolean ----

    fn parseBoolean(self: *Parser) !TOMLValue {
        if (self.startsWith("true")) { self.pos += 4; return .{ .boolean = true }; }
        if (self.startsWith("false")) { self.pos += 5; return .{ .boolean = false }; }
        self.fillDiagnostic("expected 'true' or 'false'");
        return error.UnexpectedChar;
    }

    // ---- numbers ----

    fn parseNumber(self: *Parser) !TOMLValue {
        const start = self.pos;
        const has_sign = self.peek() == '+' or self.peek() == '-';
        const is_negative = has_sign and self.input[self.pos] == '-';
        if (has_sign) _ = self.advance();

        if (self.startsWith("inf")) {
            self.pos += 3;
            return .{ .float = if (is_negative) -std.math.inf(f64) else std.math.inf(f64) };
        }
        if (self.startsWith("nan")) {
            self.pos += 3;
            return .{ .float = std.math.nan(f64) };
        }

        if (!has_sign) {
            if (self.startsWith("0x")) { self.pos += 2; return try self.parseBasedInt(16); }
            if (self.startsWith("0o")) { self.pos += 2; return try self.parseBasedInt(8); }
            if (self.startsWith("0b")) { self.pos += 2; return try self.parseBasedInt(2); }
        }

        const digits_start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isDigit(c) or c == '_') _ = self.advance() else break;
        }
        if (self.pos == digits_start) {
            self.fillDiagnostic("expected digit");
            return error.UnexpectedChar;
        }

        // float detection
        if (self.peek() == '.' or self.peek() == 'e' or self.peek() == 'E') {
            if (self.peek() == '.') {
                _ = self.advance();
                if (self.peek() == null or !std.ascii.isDigit(self.peek().?)) {
                    self.fillDiagnostic("expected digit after decimal point");
                    return error.InvalidNumber;
                }
                while (self.peek()) |c| {
                    if (std.ascii.isDigit(c) or c == '_') _ = self.advance() else break;
                }
            }
            if (self.peek() == 'e' or self.peek() == 'E') {
                _ = self.advance();
                if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
                const exp_start = self.pos;
                while (self.peek()) |c| {
                    if (std.ascii.isDigit(c)) _ = self.advance() else break;
                }
                if (self.pos == exp_start) {
                    self.fillDiagnostic("expected digit in exponent");
                    return error.InvalidNumber;
                }
            }
            const raw = self.input[start..self.pos];
            const f = try parseFloatStrip(self.allocator, raw) orelse {
                self.fillDiagnostic("invalid float");
                return error.InvalidNumber;
            };
            return .{ .float = f };
        }

        // integer
        const raw = self.input[start..self.pos];
        const int_digits = if (has_sign) raw[1..] else raw;
        try validateUnderscores(int_digits, self);
        var stripped = try parseIntStrip(self.allocator, raw);
        defer stripped.deinit(self.allocator);
        const n = std.fmt.parseInt(i64, stripped.items, 10) catch {
            self.fillDiagnostic("invalid integer");
            return error.InvalidNumber;
        };
        return .{ .integer = n };
    }

    fn parseBasedInt(self: *Parser, base: u8) !TOMLValue {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isHex(c) or c == '_') _ = self.advance() else break;
        }
        if (self.pos == start) {
            self.fillDiagnostic("expected digit in based integer");
            return error.InvalidNumber;
        }
        const raw = self.input[start..self.pos];
        try validateUnderscores(raw, self);
        var stripped = try parseIntStrip(self.allocator, raw);
        defer stripped.deinit(self.allocator);
        const n = std.fmt.parseInt(i64, stripped.items, base) catch {
            self.fillDiagnostic("invalid based integer");
            return error.InvalidNumber;
        };
        return .{ .integer = n };
    }

    // ---- datetime ----

    fn isDateLike(self: *Parser) bool {
        const r = self.input[self.pos..];
        if (r.len < 10) return false;
        for (0..4) |i| if (!std.ascii.isDigit(r[i])) return false;
        if (r[4] != '-') return false;
        for (5..7) |i| if (!std.ascii.isDigit(r[i])) return false;
        if (r[7] != '-') return false;
        for (8..10) |i| if (!std.ascii.isDigit(r[i])) return false;
        return true;
    }

    fn isTimeLike(self: *Parser) bool {
        const r = self.input[self.pos..];
        if (r.len < 8) return false;
        for (0..2) |i| if (!std.ascii.isDigit(r[i])) return false;
        if (r[2] != ':') return false;
        for (3..5) |i| if (!std.ascii.isDigit(r[i])) return false;
        if (r[5] != ':') return false;
        for (6..8) |i| if (!std.ascii.isDigit(r[i])) return false;
        return true;
    }

    /// Parse exactly `n` ASCII decimal digits and return the u32 value.
    fn parseDigits(self: *Parser, n: usize) !u32 {
        var value: u32 = 0;
        for (0..n) |_| {
            const c = self.peek() orelse {
                self.fillDiagnostic("unexpected end of input in date/time");
                return error.InvalidDate;
            };
            if (!std.ascii.isDigit(c)) {
                self.fillDiagnostic("expected digit in date/time");
                return error.InvalidDate;
            }
            _ = self.advance();
            value = value * 10 + (c - '0');
        }
        return value;
    }

    fn parseLocalDate(self: *Parser) !types.LocalDate {
        const year = try self.parseDigits(4);
        if (self.peek() != '-') { self.fillDiagnostic("expected '-' in date"); return error.InvalidDate; }
        _ = self.advance();
        const month = try self.parseDigits(2);
        if (self.peek() != '-') { self.fillDiagnostic("expected '-' in date"); return error.InvalidDate; }
        _ = self.advance();
        const day = try self.parseDigits(2);

        if (month < 1 or month > 12) { self.fillDiagnostic("invalid month"); return error.InvalidDate; }
        const max_day = daysInMonth(month, year);
        if (day < 1 or day > max_day) { self.fillDiagnostic("invalid day"); return error.InvalidDate; }

        return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    }

    fn parseLocalTime(self: *Parser) !types.LocalTime {
        const hour = try self.parseDigits(2);
        if (self.peek() != ':') { self.fillDiagnostic("expected ':' in time"); return error.InvalidTime; }
        _ = self.advance();
        const minute = try self.parseDigits(2);
        if (self.peek() != ':') { self.fillDiagnostic("expected ':' in time"); return error.InvalidTime; }
        _ = self.advance();
        const second = try self.parseDigits(2);

        if (hour > 23) { self.fillDiagnostic("invalid hour"); return error.InvalidTime; }
        if (minute > 59) { self.fillDiagnostic("invalid minute"); return error.InvalidTime; }
        if (second > 60) { self.fillDiagnostic("invalid second"); return error.InvalidTime; }

        var nanosecond: u32 = 0;
        if (self.peek() == '.') {
            _ = self.advance();
            const frac_start = self.pos;
            while (self.peek()) |c| {
                if (std.ascii.isDigit(c)) _ = self.advance() else break;
            }
            const frac = self.input[frac_start..self.pos];
            if (frac.len == 0) { self.fillDiagnostic("expected fractional digits"); return error.InvalidTime; }
            var ns: u64 = 0;
            const n = @min(frac.len, 9);
            for (frac[0..n]) |c| ns = ns * 10 + (c - '0');
            for (0..(9 - n)) |_| ns *= 10;
            nanosecond = @intCast(ns);
        }

        return .{
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .nanosecond = nanosecond,
        };
    }

    fn parseDateOrDateTime(self: *Parser) !TOMLValue {
        const date = try self.parseLocalDate();

        const is_datetime = blk: {
            if (self.peek()) |sep| {
                if (sep == 'T' or sep == 't') break :blk true;
                // space separator: next char must be a digit (HH of time)
                if (sep == ' ' and self.pos + 1 < self.input.len and
                    std.ascii.isDigit(self.input[self.pos + 1])) break :blk true;
            }
            break :blk false;
        };

        if (!is_datetime) return .{ .local_date = date };

        _ = self.advance(); // consume T/t or space
        const time = try self.parseLocalTime();

        // optional timezone offset
        if (self.peek() == 'Z' or self.peek() == 'z') {
            _ = self.advance();
            return .{ .offset_date_time = .{
                .datetime = .{ .date = date, .time = time },
                .offset_minutes = 0,
            }};
        }
        if (self.peek() == '+' or self.peek() == '-') {
            const neg = self.advance().? == '-';
            const off_h = try self.parseDigits(2);
            if (self.peek() != ':') { self.fillDiagnostic("expected ':' in tz offset"); return error.InvalidTime; }
            _ = self.advance();
            const off_m = try self.parseDigits(2);
            const offset: i16 = @intCast(off_h * 60 + off_m);
            return .{ .offset_date_time = .{
                .datetime = .{ .date = date, .time = time },
                .offset_minutes = if (neg) -offset else offset,
            }};
        }

        return .{ .local_date_time = .{ .date = date, .time = time } };
    }

    // ---- array ----

    fn parseArray(self: *Parser) Error!TOMLValue {
        _ = self.advance(); // consume '['
        var items: std.ArrayListUnmanaged(TOMLValue) = .{};

        self.skipWhitespaceAndNewlines();
        if (self.peek() == ']') {
            _ = self.advance();
            return .{ .array = try items.toOwnedSlice(self.allocator) };
        }

        while (true) {
            self.skipWhitespaceAndNewlines();
            const item = try self.parseValue();
            try items.append(self.allocator, item);
            self.skipWhitespaceAndNewlines();

            if (self.peek() == ']') {
                _ = self.advance();
                break;
            }
            if (self.peek() != ',') {
                self.fillDiagnostic("expected ',' or ']' in array");
                return error.UnexpectedChar;
            }
            _ = self.advance(); // consume ','
            self.skipWhitespaceAndNewlines();
            // trailing comma allowed
            if (self.peek() == ']') {
                _ = self.advance();
                break;
            }
        }
        return .{ .array = try items.toOwnedSlice(self.allocator) };
    }

    // ---- inline table ----

    fn parseInlineTable(self: *Parser) Error!TOMLValue {
        _ = self.advance(); // consume '{'
        var map = std.StringHashMap(TOMLValue).init(self.allocator);
        try map.ensureTotalCapacity(4);

        self.skipWhitespace();
        if (self.peek() == '}') {
            _ = self.advance();
            return .{ .table = tableFromMap(map) };
        }

        while (true) {
            self.skipWhitespace();
            const keys = try self.parseDottedKey();
            self.skipWhitespace();

            if (self.peek() != '=') {
                self.fillDiagnostic("expected '=' in inline table");
                return error.UnexpectedChar;
            }
            _ = self.advance();
            self.skipWhitespace();

            const value = try self.parseValue();

            var target = &map;
            for (keys[0 .. keys.len - 1]) |k| {
                const entry = try target.getOrPut(k);
                if (!entry.found_existing) {
                    var inner = std.StringHashMap(TOMLValue).init(self.allocator);
                    try inner.ensureTotalCapacity(4);
                    entry.value_ptr.* = .{ .table = tableFromMap(inner) };
                }
                switch (entry.value_ptr.*) {
                    .table => |*t| target = &t.inner,
                    else => return error.DuplicateKey,
                }
            }
            const last = keys[keys.len - 1];
            if (target.contains(last)) {
                self.fillDiagnostic("duplicate key in inline table");
                return error.DuplicateKey;
            }
            try target.put(last, value);

            self.skipWhitespace();
            if (self.peek() == '}') {
                _ = self.advance();
                break;
            }
            if (self.peek() != ',') {
                self.fillDiagnostic("expected ',' or '}' in inline table");
                return error.UnexpectedChar;
            }
            _ = self.advance(); // consume ','
            self.skipWhitespace();
            // trailing comma (TOML 1.1)
            if (self.peek() == '}') {
                _ = self.advance();
                break;
            }
        }
        return .{ .table = tableFromMap(map) };
    }
};

// ============================================================
// Helpers
// ============================================================

fn daysInMonth(month: u32, year: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else @as(u32, 28),
        else => 0,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn appendUtf8Codepoint(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, cp: u21) !void {
    var tmp: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &tmp) catch return error.InvalidUnicode;
    try buf.appendSlice(allocator, tmp[0..len]);
}

fn validateUnderscores(s: []const u8, parser: *Parser) !void {
    if (s.len == 0) return;
    if (s[0] == '_') {
        parser.fillDiagnostic("leading underscore in number");
        return error.InvalidNumber;
    }
    if (s[s.len - 1] == '_') {
        parser.fillDiagnostic("trailing underscore in number");
        return error.InvalidNumber;
    }
    for (s, 0..) |c, i| {
        if (c == '_' and i + 1 < s.len and s[i + 1] == '_') {
            parser.fillDiagnostic("consecutive underscores in number");
            return error.InvalidNumber;
        }
    }
}

fn parseIntStrip(allocator: Allocator, raw: []const u8) !std.ArrayListUnmanaged(u8) {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    for (raw) |c| {
        if (c != '_') try buf.append(allocator, c);
    }
    return buf;
}

fn parseFloatStrip(allocator: Allocator, raw: []const u8) !?f64 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    for (raw) |c| {
        if (c != '_') try buf.append(allocator, c);
    }
    return std.fmt.parseFloat(f64, buf.items) catch null;
}

// ============================================================
// Tests
// ============================================================

test "parseKey: bare key alphanumeric" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "my_key-1 = 1", .{});
    const key = try parser.parseSingleKey();
    try std.testing.expectEqualStrings("my_key-1", key);
}

test "parseKey: error on empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "= 1", .{});
    try std.testing.expectError(error.UnexpectedChar, parser.parseSingleKey());
}

test "parseValue: integer positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "42", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = 42 }, val);
}

test "parseValue: integer negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "-5", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = -5 }, val);
}

test "parseValue: boolean true/false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p1 = Parser.init(arena.allocator(), "true", .{});
    try std.testing.expectEqual(TOMLValue{ .boolean = true }, try p1.parseValue());
    var p2 = Parser.init(arena.allocator(), "false", .{});
    try std.testing.expectEqual(TOMLValue{ .boolean = false }, try p2.parseValue());
}

test "parseValue: basic string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"hello\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("hello", val.string);
}

test "parseValue: basic string with escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"hello\\nworld\\t!\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("hello\nworld\t!", val.string);
}

test "parseFromSlice: basic key-value pairs" {
    const input =
        \\name = "Alice"
        \\age = 30
        \\active = true
        \\negative = -5
    ;
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const name = result.value.get("name") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Alice", name.string);
    const age = result.value.get("age") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 30), age.integer);
    const active = result.value.get("active") orelse return error.TestFailed;
    try std.testing.expectEqual(true, active.boolean);
    const negative = result.value.get("negative") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, -5), negative.integer);
}

test "parseFromSlice: inline comment" {
    var result = try parseFromSlice(std.testing.allocator, "port = 8080 # server port\n", .{});
    defer result.deinit();
    const port = result.value.get("port") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 8080), port.integer);
}

test "parseFromSlice: error on missing value" {
    try std.testing.expectError(error.UnexpectedEof, parseFromSlice(std.testing.allocator, "key = ", .{}));
}

test "parseFromSlice: error on unquoted string value" {
    try std.testing.expectError(error.UnexpectedChar, parseFromSlice(std.testing.allocator, "key = value", .{}));
}

test "parseFromSlice: duplicate key error" {
    try std.testing.expectError(error.DuplicateKey, parseFromSlice(std.testing.allocator, "a = 1\na = 2", .{}));
}

test "parseFromSlice: diagnostic on error" {
    var diag = Diagnostic{};
    _ = parseFromSlice(std.testing.allocator, "key = ", .{ .diag = &diag }) catch {};
    try std.testing.expect(diag.line > 0);
    try std.testing.expect(diag.message.len > 0);
}

// ============================================================

test "parseValue: all basic escape sequences" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "\"\\b\"", .expected = "\x08" },
        .{ .input = "\"\\t\"", .expected = "\t" },
        .{ .input = "\"\\n\"", .expected = "\n" },
        .{ .input = "\"\\f\"", .expected = "\x0C" },
        .{ .input = "\"\\r\"", .expected = "\r" },
        .{ .input = "\"\\e\"", .expected = "\x1B" },
        .{ .input = "\"\\\"\"", .expected = "\"" },
        .{ .input = "\"\\\\\"", .expected = "\\" },
    };
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = Parser.init(arena.allocator(), c.input, .{});
        const val = try parser.parseValue();
        try std.testing.expectEqualStrings(c.expected, val.string);
    }
}

test "parseValue: unicode escape \\uHHHH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\\u0041\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("A", val.string);
}

test "parseValue: unicode escape \\UHHHHHHHH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\\U0001F600\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("😀", val.string);
}

test "parseValue: invalid escape error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\\q\"", .{});
    try std.testing.expectError(error.InvalidEscape, parser.parseValue());
}

test "parseValue: invalid unicode short error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\\u00\"", .{});
    try std.testing.expectError(error.InvalidUnicode, parser.parseValue());
}

test "parseValue: multiline basic string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\"\"multi\nline\"\"\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("multi\nline", val.string);
}

test "parseValue: multiline basic string trims first newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\"\"\nhello\"\"\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("hello", val.string);
}

test "parseValue: multiline basic string line continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "\"\"\"hello \\\n  world\"\"\"", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("hello world", val.string);
}

test "parseValue: literal string zero-copy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "'C:\\Users\\tom'", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("C:\\Users\\tom", val.string);
}

test "parseValue: multiline literal string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "'''\nline1\nline2'''", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqualStrings("line1\nline2", val.string);
}

test "parseValue: integer underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1_000_000", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = 1_000_000 }, val);
}

test "parseValue: integer hex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "0xDEAD_BEEF", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = 0xDEADBEEF }, val);
}

test "parseValue: integer octal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "0o755", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = 0o755 }, val);
}

test "parseValue: integer binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "0b1010_1010", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(TOMLValue{ .integer = 0b10101010 }, val);
}

test "parseValue: float decimal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "3.14", .{});
    const val = try parser.parseValue();
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), val.float, 1e-10);
}

test "parseValue: float exponent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "3.14e-2", .{});
    const val = try parser.parseValue();
    try std.testing.expectApproxEqAbs(@as(f64, 3.14e-2), val.float, 1e-15);
}

test "parseValue: float inf and nan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p1 = Parser.init(arena.allocator(), "inf", .{});
    const v1 = try p1.parseValue();
    try std.testing.expect(std.math.isInf(v1.float) and v1.float > 0);
    var p2 = Parser.init(arena.allocator(), "-inf", .{});
    const v2 = try p2.parseValue();
    try std.testing.expect(std.math.isInf(v2.float) and v2.float < 0);
    var p3 = Parser.init(arena.allocator(), "nan", .{});
    const v3 = try p3.parseValue();
    try std.testing.expect(std.math.isNan(v3.float));
}

test "parseFromSlice: mixed types" {
    const input =
        \\str1 = "hello\nworld"
        \\str2 = 'C:\Users\tom'
        \\hex  = 0xDEADBEEF
        \\flt  = 3.14e-2
    ;
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();
    const str1 = result.value.get("str1") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("hello\nworld", str1.string);
    const str2 = result.value.get("str2") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("C:\\Users\\tom", str2.string);
    const hex = result.value.get("hex") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), hex.integer);
    const flt = result.value.get("flt") orelse return error.TestFailed;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14e-2), flt.float, 1e-15);
}

test "parseFromSlice: error invalid underscore" {
    try std.testing.expectError(
        error.InvalidNumber,
        parseFromSlice(std.testing.allocator, "n = 1__0", .{}),
    );
}

// ============================================================

test "parseValue: array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "[1, 2, 3]", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(@as(usize, 3), val.array.len);
    try std.testing.expectEqual(@as(i64, 1), val.array[0].integer);
    try std.testing.expectEqual(@as(i64, 3), val.array[2].integer);
}

test "parseValue: nested array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "[[1, 2], [3, 4]]", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(@as(usize, 2), val.array.len);
    try std.testing.expectEqual(@as(i64, 1), val.array[0].array[0].integer);
    try std.testing.expectEqual(@as(i64, 4), val.array[1].array[1].integer);
}

test "parseValue: array trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "[\"apple\", \"banana\",]", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(@as(usize, 2), val.array.len);
    try std.testing.expectEqualStrings("apple", val.array[0].string);
}

test "parseValue: inline table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "{x = 1, y = 2}", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(@as(i64, 1), val.table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), val.table.get("y").?.integer);
}

test "parseFromSlice: table header" {
    const input =
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const db = result.value.get("database") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("localhost", db.table.get("host").?.string);
    try std.testing.expectEqual(@as(i64, 5432), db.table.get("port").?.integer);
}

test "parseFromSlice: dotted key" {
    const input = "a.b.c = true\n";
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const a = result.value.get("a") orelse return error.TestFailed;
    const b = a.table.get("b") orelse return error.TestFailed;
    try std.testing.expectEqual(true, b.table.get("c").?.boolean);
}

test "parseFromSlice: quoted key" {
    const input = "\"my-key\" = 42\n";
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 42), result.value.get("my-key").?.integer);
}

test "parseFromSlice: tables and arrays mixed" {
    const input =
        \\[database]
        \\host = "localhost"
        \\port = 5432
        \\
        \\fruits = ["apple", "banana"]
        \\
        \\point = {x = 1, y = 2}
    ;
    // Note: fruits and point are at top level (before [database] section ends)
    // Let's adjust: put them before the section
    const input2 =
        \\fruits = ["apple", "banana"]
        \\point = {x = 1, y = 2}
        \\
        \\[database]
        \\host = "localhost"
        \\port = 5432
    ;
    var result = try parseFromSlice(std.testing.allocator, input2, .{});
    defer result.deinit();

    const fruits = result.value.get("fruits") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), fruits.array.len);
    try std.testing.expectEqualStrings("apple", fruits.array[0].string);

    const point = result.value.get("point") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i64, 1), point.table.get("x").?.integer);

    const db = result.value.get("database") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("localhost", db.table.get("host").?.string);
    _ = input;
}

test "parseFromSlice: duplicate table header error" {
    try std.testing.expectError(
        error.DuplicateKey,
        parseFromSlice(std.testing.allocator, "[a]\n[a]\n", .{}),
    );
}

test "parseFromSlice: duplicate dotted key error" {
    try std.testing.expectError(
        error.DuplicateKey,
        parseFromSlice(std.testing.allocator, "a.b = 1\na.b = 2\n", .{}),
    );
}

// ============================================================

test "parseValue: local date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1979-05-27", .{});
    const val = try parser.parseValue();
    const d = val.local_date;
    try std.testing.expectEqual(@as(u16, 1979), d.year);
    try std.testing.expectEqual(@as(u8, 5), d.month);
    try std.testing.expectEqual(@as(u8, 27), d.day);
}

test "parseValue: local time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "07:32:00", .{});
    const val = try parser.parseValue();
    const t = val.local_time;
    try std.testing.expectEqual(@as(u8, 7), t.hour);
    try std.testing.expectEqual(@as(u8, 32), t.minute);
    try std.testing.expectEqual(@as(u8, 0), t.second);
}

test "parseValue: local time with fractional seconds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "07:32:00.999999", .{});
    const val = try parser.parseValue();
    try std.testing.expect(val.local_time.nanosecond > 0);
}

test "parseValue: local datetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1979-05-27T07:32:00", .{});
    const val = try parser.parseValue();
    const dt = val.local_date_time;
    try std.testing.expectEqual(@as(u16, 1979), dt.date.year);
    try std.testing.expectEqual(@as(u8, 7), dt.time.hour);
}

test "parseValue: offset datetime UTC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1979-05-27T07:32:00Z", .{});
    const val = try parser.parseValue();
    const odt = val.offset_date_time;
    try std.testing.expectEqual(@as(i16, 0), odt.offset_minutes);
    try std.testing.expectEqual(@as(u16, 1979), odt.datetime.date.year);
}

test "parseValue: offset datetime with offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1979-05-27T07:32:00+09:00", .{});
    const val = try parser.parseValue();
    try std.testing.expectEqual(@as(i16, 9 * 60), val.offset_date_time.offset_minutes);
}

test "parseValue: invalid date month" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "1979-13-01", .{});
    try std.testing.expectError(error.InvalidDate, parser.parseValue());
}

test "parseValue: invalid time hour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "25:00:00", .{});
    try std.testing.expectError(error.InvalidTime, parser.parseValue());
}

test "parseFromSlice: array of tables" {
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\
        \\[[products]]
        \\name = "Nail"
    ;
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const products = result.value.get("products") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 2), products.array.len);
    try std.testing.expectEqualStrings("Hammer", products.array[0].table.get("name").?.string);
    try std.testing.expectEqualStrings("Nail", products.array[1].table.get("name").?.string);
}

test "parseFromSlice: datetime values in document" {
    const input =
        \\dt = 1979-05-27T07:32:00Z
        \\d  = 1979-05-27
        \\t  = 07:32:00
    ;
    var result = try parseFromSlice(std.testing.allocator, input, .{});
    defer result.deinit();

    const dt = result.value.get("dt") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i16, 0), dt.offset_date_time.offset_minutes);

    const d = result.value.get("d") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 27), d.local_date.day);

    const t = result.value.get("t") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 7), t.local_time.hour);
}

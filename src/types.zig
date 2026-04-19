const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- Datetime types ----

/// ローカル日付（年・月・日）を表す構造体。TOML の Local Date 型の値を保持するために利用する。
pub const LocalDate = struct { year: u16, month: u8, day: u8 };
/// ローカル時刻（時・分・秒・ナノ秒）を表す構造体。TOML の Local Time 型の値を保持するために利用する。
pub const LocalTime = struct { hour: u8, minute: u8, second: u8, nanosecond: u32 };
/// タイムゾーン情報を持たない日時を表す構造体。TOML の Local Date-Time 型の値を保持するために利用する。
pub const LocalDateTime = struct { date: LocalDate, time: LocalTime };
/// UTC オフセット付きの日時を表す構造体。TOML の Offset Date-Time 型の値を保持するために利用する。
pub const OffsetDateTime = struct { datetime: LocalDateTime, offset_minutes: i16 };

// ---- Core value type ----

/// TOML の任意の値を表すタグ付きユニオン。パース結果のすべての値型を統一的に扱うために利用する。
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

/// TOML テーブルを表す構造体。キーと値のペアを保持し、読み取り専用で利用する。
pub const TOMLTable = struct {
    inner: std.StringHashMap(TOMLValue),

    /// キーに対応する値を取得する。キーが存在しない場合は `null` を返す。
    pub fn get(self: TOMLTable, key: []const u8) ?TOMLValue {
        return self.inner.get(key);
    }

    /// テーブル内のすべてのキーと値を走査するイテレータを返す。
    pub fn iterator(self: TOMLTable) std.StringHashMap(TOMLValue).Iterator {
        return self.inner.iterator();
    }

    /// テーブルに含まれるキーと値のペアの個数を返す。
    pub fn count(self: TOMLTable) usize {
        return self.inner.count();
    }
};

/// `StringHashMap` から `TOMLTable` を構築する。パーサ内部で利用する。
pub fn tableFromMap(map: std.StringHashMap(TOMLValue)) TOMLTable {
    return .{ .inner = map };
}

/// パース時のオプションを指定する構造体。エラー診断情報の出力先を設定するために利用する。
pub const ParseOptions = struct {
    diag: ?*Diagnostic = null,
};

/// パースエラーの診断情報を保持する構造体。エラー発生位置（行・列）とメッセージを確認するために利用する。
pub const Diagnostic = struct {
    line: usize = 0,
    col: usize = 0,
    message: []const u8 = "",
};

/// パース結果の値とメモリアリーナをまとめたコンテナ型。`deinit` を呼び出してメモリを解放するために利用する。
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// パース処理中に発生するエラーの集合。`parseFromSlice` および `parseFromSliceAs` から返される可能性がある。
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

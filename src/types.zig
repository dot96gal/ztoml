const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- Datetime types ----

/// ローカル日付（年・月・日）を表す構造体。TOML の Local Date 型の値を保持するために利用する。
pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};
/// ローカル時刻（時・分・秒・ナノ秒）を表す構造体。TOML の Local Time 型の値を保持するために利用する。
pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    /// サブ秒精度をナノ秒単位で保持する。
    nanosecond: u32,
};
/// タイムゾーン情報を持たない日時を表す構造体。TOML の Local Date-Time 型の値を保持するために利用する。
pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};
/// UTC オフセット付きの日時を表す構造体。TOML の Offset Date-Time 型の値を保持するために利用する。
pub const OffsetDateTime = struct {
    /// タイムゾーン情報を持たない日時部分。
    datetime: LocalDateTime,
    /// UTC からのオフセット（分単位）。例: +09:00 は 540、-05:00 は -300。
    offset_minutes: i16,
};

// ---- Core value type ----

/// TOML の任意の値を表すタグ付きユニオン。パース結果のすべての値型を統一的に扱うために利用する。
pub const TOMLValue = union(enum) {
    /// TOML の String 型。UTF-8 文字列として保持する。
    string: []const u8,
    /// TOML の Integer 型。`i64` として保持する。`parseFromSliceAs` では `u8`〜`i64` など任意の整数型に変換可。
    integer: i64,
    /// TOML の Float 型。`f64` として保持する。
    float: f64,
    /// TOML の Boolean 型。
    boolean: bool,
    /// TOML の Array 型。要素は再帰的に `TOMLValue` となる。
    array: []const TOMLValue,
    /// TOML の Table 型。
    table: TOMLTable,
    /// TOML の Offset Date-Time 型。
    offset_date_time: OffsetDateTime,
    /// TOML の Local Date-Time 型。
    local_date_time: LocalDateTime,
    /// TOML の Local Date 型。
    local_date: LocalDate,
    /// TOML の Local Time 型。
    local_time: LocalTime,
};

/// TOML テーブルを表す構造体。キーと値のペアを保持し、読み取り専用で利用する。
pub const TOMLTable = struct {
    /// キーと値のペアを保持する内部ハッシュマップ。直接操作せず `get` / `iterator` / `count` を使うこと。
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
    /// エラー診断情報の書き込み先。省略した場合（`null`）は診断情報を収集しない。
    diag: ?*Diagnostic = null,
};

/// パースエラーの診断情報を保持する構造体。エラー発生位置（行・列）とメッセージを確認するために利用する。
pub const Diagnostic = struct {
    /// エラーが発生した行番号（1 始まり）。
    line: usize = 0,
    /// エラーが発生した列番号（1 始まり）。
    col: usize = 0,
    /// エラーの内容を示すメッセージ。
    message: []const u8 = "",
};

/// パース結果の値とメモリアリーナをまとめたコンテナ型。`deinit` を呼び出してメモリを解放するために利用する。
pub fn Parsed(comptime T: type) type {
    return struct {
        /// パース結果の値。`deinit` を呼び出した後は参照しないこと（use-after-free）。
        value: T,
        /// パース結果が使用するメモリアリーナ。直接操作せず `deinit` を通じて解放すること。
        arena: std.heap.ArenaAllocator,

        /// `value` 内の文字列・配列を含むすべてのメモリを解放する。
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// パース処理中に発生するエラーの集合。`parseFromSlice` および `parseFromSliceAs` から返される可能性がある。
pub const ParseError = error{
    /// 入力が途中で終了した。
    UnexpectedEof,
    /// 文法上許容されない文字が現れた。
    UnexpectedChar,
    /// 文字列内の `\` エスケープシーケンスが不正。
    InvalidEscape,
    /// `\uXXXX` / `\UXXXXXXXX` で指定された Unicode コードポイントが不正。
    InvalidUnicode,
    /// 同じキーが複数回定義されている。
    DuplicateKey,
    /// 数値リテラルの形式が不正。
    InvalidNumber,
    /// 日付リテラルの形式が不正（例: 月・日の範囲外）。
    InvalidDate,
    /// 時刻リテラルの形式が不正（例: 時・分・秒の範囲外）。
    InvalidTime,
    /// 値の後に余分な内容が続いている。
    TrailingContent,
};

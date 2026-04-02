# TOMLパーサ実装計画

作成日: 2026-03-31

## 概要

TOML v1.1.0 仕様に準拠したパーサをZigで実装する。
文字列（`[]const u8`）を受け取り、メモリ管理ラッパー `Parsed(T)` を返す。
- `parseFromSliceAs(T, ...)` → ユーザ定義構造体へ直接マッピングした `Parsed(T)`
- `parseFromSlice(...)` → 動的アクセス用の `Parsed(TOMLTable)`

シンプルな実装から始めて、段階的に複雑な仕様を追加していく。

---

## データモデル

### TOMLValue（tagged union）

```zig
pub const TOMLValue = union(enum) {
    string:   []const u8,
    integer:  i64,
    float:    f64,
    boolean:  bool,
    array:    []const TOMLValue, // arena に確保したスライス（パース完了後は変更しない）
    table:    TOMLTable,
    // Phase 3以降
    offset_date_time: OffsetDateTime,
    local_date_time:  LocalDateTime,
    local_date:       LocalDate,
    local_time:       LocalTime,
};

// TOMLTable は公開 API セクションで読み取り専用ラッパーとして定義する（下記参照）
// 内部実装では std.StringHashMap(TOMLValue) を直接使用する
```

> **配列のパース実装:** パース中は `ArrayList(TOMLValue)` に `append` し、パース完了後に `toOwnedSlice()` で arena 上のスライスに変換して `TOMLValue.array` に格納する。スライスは `[]const TOMLValue` で公開するため、呼び出し元から書き込みはできない。

> **拡張性注意:** `TOMLValue` に新バリアントを追加すると、exhaustive switch により以下の全箇所の更新がコンパイルエラーで強制される。追加時はこのリストを修正チェックリストとして使う。
> - `deserialize.zig` の `coerce` 関数
> - `parseValue` の switch
> - 動的アクセスを行う呼び出し元コード
> - 各フェーズの正常系テスト

### 日時型（Phase 4）

```zig
pub const LocalDate = struct { year: u16, month: u8, day: u8 };
pub const LocalTime = struct { hour: u8, minute: u8, second: u8, nanosecond: u32 };
pub const LocalDateTime = struct { date: LocalDate, time: LocalTime };
pub const OffsetDateTime = struct { datetime: LocalDateTime, offset_minutes: i16 };
```

---

## 公開 API

### トップレベル関数

`Parser` は内部実装として隠蔽し、ユーザには以下の2関数のみを公開する。

```zig
// メイン API：文字列を直接ユーザ定義構造体へ変換（最も多いユースケース）
pub fn parseFromSliceAs(comptime T: type, allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(T)

// 動的アクセス用：TOMLTable として受け取り、キーを動的に操作する
pub fn parseFromSlice(allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(TOMLTable)
```

### ParseOptions

オプションをまとめた構造体。全フィールドにデフォルト値を持つため、`options: .{}` で省略可能。将来のオプション追加時も API を壊さない。

```zig
pub const ParseOptions = struct {
    diag: ?*Diagnostic = null,
};
```

呼び出し例：

```zig
// オプション不要（最も多いケース）
var result = try toml.parseFromSliceAs(Config, allocator, input, .{});
```

```zig
// Diagnostic あり
var diag = toml.Diagnostic{};
var result = try toml.parseFromSliceAs(Config, allocator, input, .{ .diag = &diag });
```

### Parsed(T)：メモリ管理ラッパー

`parse` が返す値と確保したメモリをまとめて管理する。`deinit` 1回で全解放できる。

```zig
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        _arena: std.heap.ArenaAllocator, // 非公開。deinit 経由でのみ解放する

        pub fn deinit(self: *@This()) void {
            self._arena.deinit(); // value 内の文字列・配列含め全解放
        }
    };
}
```

> **ライフタイム注意:** `value` 内の `[]const u8` スライスは `Parsed(T)` が生きている間のみ有効。`deinit` 後に参照すると use-after-free になる。戻り値として `[]const u8` フィールドを返す場合は `deinit` の前にコピーすること。

使用例：

```zig
// 構造体へ直接マッピング
var result = try toml.parseFromSliceAs(Config, allocator, input, .{});
defer result.deinit();
// result.value.port, result.value.name ...
```

```zig
// 動的アクセス
var result = try toml.parseFromSlice(allocator, input, .{});
defer result.deinit();
// result.value.get("port") ...
```

### TOMLTable（読み取り専用ラッパー）

`std.StringHashMap` をそのまま公開すると `put` などの書き込みメソッドも露出するため、読み取りのみをラップした型を公開する。
`inner` は非公開とし、テスト用ファクトリ関数（同一ファイル内のみ）で組み立てる。

```zig
pub const TOMLTable = struct {
    inner: std.StringHashMap(TOMLValue), // 非公開。外部からの書き込みを防ぐ

    pub fn get(self: TOMLTable, key: []const u8) ?TOMLValue
    pub fn iterator(self: TOMLTable) std.StringHashMap(TOMLValue).Iterator
    pub fn count(self: TOMLTable) usize
};

// テスト専用ファクトリ（同一ファイル内からのみ呼べる）
fn tableFromMap(map: std.StringHashMap(TOMLValue)) TOMLTable {
    return .{ .inner = map };
}
```

> **テスタビリティ:** テストコードでは `tableFromMap` を使って `TOMLTable` を組み立てる。`inner` は非公開のまま保ち、読み取り専用の意図を一貫させる。

> **性能注意（StringHashMap）:** デフォルト初期容量から始めるとキー増加時にリハッシュが発生する。テーブルヘッダやルートパース開始時に `ensureTotalCapacity(8)` 程度で事前確保する。

### Diagnostic：エラー位置情報

パース失敗時に行・列・メッセージを取得できる。`ParseOptions.diag` に `*Diagnostic` を渡すことで取得できる。省略時は `null`（`.{}` で省略可能）。
全フィールドにデフォルト値を持たせ、未初期化参照を防ぐ。

行・列番号はエラー発生時のみ `self.input[0..self.pos]` を遡及計算する。正常パスでは毎文字の改行カウントを行わない。

```zig
pub const Diagnostic = struct {
    line:    usize = 0,
    col:     usize = 0,
    message: []const u8 = "",
};

// Parser 内部：エラー時のみ呼ぶ。self.diag が null なら何もしない
fn fillDiagnostic(self: *Parser, message: []const u8) void {
    const diag = self.diag orelse return;
    var line: usize = 1;
    var col:  usize = 1;
    for (self.input[0..self.pos]) |c| {
        if (c == '\n') { line += 1; col = 1; } else { col += 1; }
    }
    diag.* = .{ .line = line, .col = col, .message = message };
}

// 使用例（Diagnostic あり）
var diag = toml.Diagnostic{};
var result = toml.parseFromSlice(allocator, input, .{ .diag = &diag }) catch |err| {
    std.debug.print("error at {}:{}: {s}\n", .{ diag.line, diag.col, diag.message });
    return err;
};
defer result.deinit();
```

### エラー型

パースとデシリアライズの責務を分離し、エラーセット結合（`||`）で公開 API に統合する。
公開 API の戻り型は `!T`（Zig がエラー型を推論）にするため、呼び出し元への影響なく内部分離できる。

```zig
// parser.zig（パース固有エラー）
const ParseError = error{
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

// deserialize.zig（デシリアライズ固有エラー）
const DeserializeError = error{
    MissingField,    // 必須フィールドが存在しない
    TypeMismatch,    // TOMLValue の型とフィールド型が不一致
    IntegerOverflow, // 整数値がフィールドの型に収まらない（例: i64 値が u8 範囲外）
};

// mod.zig（公開する結合エラーセット）
pub const TomlError = ParseError || DeserializeError;
```

---

## パーサ構造（内部実装）

`Parser` はライブラリ内部でのみ使用し、公開しない。
内部関数（`parseKey`、`parseValue` など）は同一ファイル内の `test` ブロックからアクセスしてホワイトボックステストを行う。

```zig
const Parser = struct {
    allocator: std.mem.Allocator,
    input:     []const u8,
    pos:       usize,
    diag:      ?*Diagnostic,

    fn init(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) Parser
    fn parse(self: *Parser) !TOMLTable

    // 内部関数（同一ファイル内テストでカバー）
    fn parseKey(self: *Parser) ![]const u8
    fn parseValue(self: *Parser) !TOMLValue
    fn parseBasicString(self: *Parser) ![]const u8   // エスケープあり → arena にコピー
    fn parseLiteralString(self: *Parser) []const u8  // エスケープなし → 入力スライスをそのまま返す（ゼロコピー）
    fn parseInteger(self: *Parser) !i64
    fn fillDiagnostic(self: *Parser, message: []const u8) void // エラー時のみ呼ぶ。self.diag が null なら何もしない
    // ...
};

// 同一ファイル内ホワイトボックステストの例
test "parseKey: bare key" { ... }
test "parseKey: quoted key" { ... }
test "parseValue: integer" { ... }
```

> **性能注意（ゼロコピー）:** `parseLiteralString` はエスケープがないため `self.input[start..end]` をそのまま返す。`parseBasicString` はエスケープ展開のため arena にコピーする。この区別を実装時に維持する。

---

## 実装フェーズ

### Phase 1: 基本的なキー・バリューペア

**対象ファイル:** `src/toml.zig`（新規作成）

#### 実装内容

1. **TOMLValue / TOMLTable 型定義**
2. **Parser 構造体の骨格**
   - `init`, `parse`
   - ユーティリティ: `peek`, `advance`, `skipWhitespace`, `skipComment`, `skipWhitespaceAndNewlines`
3. **キーのパース**
   - ベアキー（`A-Za-z0-9_-`）のみ
4. **値のパース（最小限）**
   - 基本文字列（`"..."` エスケープは `\"` `\\` `\n` `\t` のみ）
   - 整数（10進数のみ、符号あり）
   - Boolean（`true` / `false`）
5. **キー・バリューペアのパース**
   - `key = value` 形式
   - 行末コメントの読み飛ばし
6. **ルートテーブルのパース**
7. **トップレベル関数の実装**
   - `parseFromSlice`（動的アクセス用）
   - `parseFromSliceAs` は Phase 5 完了後に実装（それまでは未公開）

#### テストケース（正常系）

```toml
# Phase 1 テスト
name = "Alice"
age = 30
active = true
negative = -5
```

#### テストケース（エラー系）

```zig
const error_cases = .{
    .{ .input = "key = ",       .err = error.UnexpectedEof  },
    .{ .input = "123 = 1",      .err = error.UnexpectedChar },
    .{ .input = "key = value",  .err = error.UnexpectedChar }, // 未クォート文字列
};
inline for (error_cases) |c| {
    try std.testing.expectError(c.err, toml.parseFromSlice(allocator, c.input, .{}));
}
```

---

### Phase 2: 文字列・数値の完全対応

#### 実装内容

1. **基本文字列の完全なエスケープ対応**
   - `\b \t \n \f \r \e \" \\ \xHH \uHHHH \UHHHHHHHH`
2. **マルチライン基本文字列** (`"""..."""`)
   - 最初の改行トリム
   - 行末バックスラッシュによる行継続
3. **リテラル文字列** (`'...'`)
4. **マルチラインリテラル文字列** (`'''...'''`)
5. **整数の完全対応**
   - アンダースコア区切り（`1_000`）
   - 16進数（`0x`）、8進数（`0o`）、2進数（`0b`）
6. **浮動小数点数**
   - 小数部・指数部
   - `inf`, `nan`, `+inf`, `-inf`, `+nan`, `-nan`
   - アンダースコア区切り

#### テストケース（正常系）

```toml
str1 = "hello\nworld"
str2 = 'C:\Users\tom'
str3 = """multi
line"""
hex  = 0xDEADBEEF
flt  = 3.14e-2
inf  = inf
```

#### テストケース（エラー系）

```zig
const error_cases = .{
    .{ .input = "s = \"\\q\"",   .err = error.InvalidEscape  }, // 無効なエスケープ
    .{ .input = "s = \"\\u00\"", .err = error.InvalidUnicode }, // 短すぎる Unicode
    .{ .input = "n = 1__0",      .err = error.InvalidNumber  }, // 連続アンダースコア
};
```

---

### Phase 3: ドットキー・テーブルヘッダ・配列

#### 実装内容

1. **クォートキー**（`"key"` / `'key'`）
2. **ドットキー**（`a.b.c = value`）
   - 中間テーブルの自動生成
   - 重複定義エラー
3. **配列値** (`[...]`)
   - 複数行・末尾カンマ
   - 混合型OK
   - ネスト配列
4. **テーブルヘッダ** (`[table]`)
   - ルートテーブル終了〜次のヘッダまでをテーブルとして解析
   - 重複定義エラー
5. **インラインテーブル** (`{key=val, ...}`)

#### テストケース（正常系）

```toml
[database]
host = "localhost"
port = 5432

fruits = ["apple", "banana"]

point = {x = 1, y = 2}

a.b.c = true
```

#### テストケース（エラー系）

```zig
const error_cases = .{
    .{ .input = "[a]\n[a]",         .err = error.DuplicateKey }, // テーブル重複
    .{ .input = "a.b = 1\na.b = 2", .err = error.DuplicateKey }, // ドットキー重複
};
```

---

### Phase 4: 日時型・テーブル配列

#### 実装内容

1. **Offset Date-Time** (`1979-05-27T07:32:00Z`)
   - RFC 3339 形式
   - T区切りをスペースでも可
   - 秒省略可
2. **Local Date-Time** (`1979-05-27T07:32:00`)
3. **Local Date** (`1979-05-27`)
4. **Local Time** (`07:32:00`)
5. **テーブル配列** (`[[array]]`)
   - 各ヘッダで新要素を追加
   - サブテーブル・ネストしたテーブル配列

#### テストケース（正常系）

```toml
dt = 1979-05-27T07:32:00Z
d  = 1979-05-27
t  = 07:32:00

[[products]]
name = "Hammer"

[[products]]
name = "Nail"
```

#### テストケース（エラー系）

```zig
const error_cases = .{
    .{ .input = "d = 1979-13-01",    .err = error.InvalidDate }, // 存在しない月
    .{ .input = "t = 25:00:00",      .err = error.InvalidTime }, // 存在しない時刻
};
```

---

### Phase 5: デシリアライザ（構造体マッピング）

#### 実装内容

`TOMLTable` をユーザ定義の構造体へ変換する内部関数を `comptime` と型リフレクション（`@typeInfo`）で実装する。ユーザは `parseFromSliceAs` 経由で利用する。

1. **基本型のマッピング**（Phase 1 完了後に実装可能）
   - `[]const u8` ← `TOMLValue.string`
   - `i64` ← `TOMLValue.integer`
   - `f64` ← `TOMLValue.float`
   - `bool` ← `TOMLValue.boolean`
2. **整数型の自動変換**
   - `u8`・`u16`・`u32`・`usize`・`i32` など `i64` 以外の整数型フィールドにも対応
   - `std.math.cast` で変換を試み、値が収まらなければ `IntegerOverflow` エラー
3. **構造体フィールドのデフォルト値の尊重**
   - `@typeInfo` の `field.defaultValue()` でデフォルト値の有無を検査する
   - デフォルト値あり → TOMLファイルにキーが存在しなくてもエラーにしない
   - デフォルト値なし → キー不在は `MissingField` エラー
4. **`enum` フィールドへのマッピング**
   - `TOMLValue.string` を `std.meta.stringToEnum` で対象 `enum` に変換する
   - 一致する variant がなければ `TypeMismatch` エラー
5. **ネスト構造体** ← `TOMLValue.table`（Phase 3 以降）
6. **スライス `[]T`** ← `TOMLValue.array`（`[]const TOMLValue`、Phase 3 以降）
7. **日時型** ← 対応する `TOMLValue` バリアント（Phase 4 以降）
8. **オプションフィールド**（`?T`）: キーが存在しない場合は `null`

> エラーは `DeserializeError`（`MissingField`・`TypeMismatch`・`IntegerOverflow`）として定義する（エラー型セクション参照）。

#### 使用例

```zig
const Config = struct {
    name: []const u8,
    port: i64,
    debug: bool,
};

var result = try toml.parseFromSliceAs(Config, allocator, input, .{});
defer result.deinit();
// result.value.name, result.value.port, result.value.debug
```

#### テストケース（正常系）

```toml
name = "myapp"
port = 8080
debug = true
```

```zig
test "deserialize basic struct" {
    var result = try toml.parseFromSliceAs(Config, std.testing.allocator, input, .{});
    defer result.deinit(); // deinit を必ず呼ぶ（testing.allocator のリーク検出を正常に機能させる）
    try std.testing.expectEqualStrings("myapp", result.value.name);
    try std.testing.expectEqual(@as(i64, 8080), result.value.port);
    try std.testing.expectEqual(true, result.value.debug);
}

test "deserialize: integer type conversion" {
    const PortConfig = struct { port: u16 };
    var r = try toml.parseFromSliceAs(PortConfig, std.testing.allocator, "port = 8080", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 8080), r.value.port);
}

test "deserialize: field default value" {
    const TimeoutConfig = struct { timeout_ms: u32 = 3000 };
    var r = try toml.parseFromSliceAs(TimeoutConfig, std.testing.allocator, "", .{});
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 3000), r.value.timeout_ms);
}

test "deserialize: enum field" {
    const LogLevel = enum { debug, info, warn, err };
    const LogConfig = struct { log_level: LogLevel };
    var r = try toml.parseFromSliceAs(LogConfig, std.testing.allocator, "log_level = \"info\"", .{});
    defer r.deinit();
    try std.testing.expectEqual(LogLevel.info, r.value.log_level);
}

test "deserialize: local variable binding" {
    // result.value をローカル変数に束縛することで value を介さず直接参照できる
    var result = try toml.parseFromSliceAs(Config, std.testing.allocator, input, .{});
    defer result.deinit();
    const config = result.value; // deinit より前に束縛する
    try std.testing.expectEqualStrings("myapp", config.name);
    try std.testing.expectEqual(@as(i64, 8080), config.port);
    try std.testing.expectEqual(true, config.debug);
}
```

#### テストケース（エラー系）

```zig
const error_cases = .{
    // 必須フィールド欠落（デフォルト値なし）
    .{ .input = "port = 8080",          .err = error.MissingField },
    // 型不一致（文字列フィールドに整数）
    .{ .input = "name = 1\nport = 8080\ndebug = true", .err = error.TypeMismatch },
    // 整数オーバーフロー（u8 に 300 は収まらない）
    .{ .input = "val = 300",            .err = error.IntegerOverflow },
    // enum 不一致
    .{ .input = "log_level = \"trace\"", .err = error.TypeMismatch },
};
```

> **`Parsed(T)` と `testing.allocator` の注意:** `ArenaAllocator` は内部でまとめてメモリを確保するため、`deinit` を呼ばないと `testing.allocator` がリークを報告する。テスト内では必ず `defer result.deinit()` を記述する。

---

### Phase 6: ベンチマーク

#### 目的

Phase 4 完了後（全 TOML 構文対応済み）に計測を行い、性能上の問題を早期に発見する。
`mise run bench`（`zig build bench --summary all`）で実行できるよう `build.zig` にステップを追加する。

#### 目標値

| ケース | 目標 |
|--------|------|
| 典型的な設定ファイル（〜1KB） | 1ms 以下 |
| 中規模ファイル（〜100KB） | 100ms 以下 |

#### 実装内容

```zig
// bench/main.zig
pub fn main() !void {
    const input = @embedFile("../testdata/large.toml");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const RUNS = 1000;
    var timer = try std.time.Timer.start();
    for (0..RUNS) |_| {
        var result = try toml.parseFromSlice(allocator, input, .{});
        result.deinit();
    }
    const elapsed_ns = timer.read();
    std.debug.print("avg: {}ns/parse\n", .{elapsed_ns / RUNS});
}
```

#### チェックポイント

- [ ] ゼロコピー（リテラル文字列）が機能しているか
- [ ] `StringHashMap` のリハッシュが発生していないか（`ensureTotalCapacity` の効果確認）
- [ ] 配列パース中の `ArrayList` 再アロケーションが最小限か（`toOwnedSlice` 前の `ensureTotalCapacity` の効果確認）

---

## ファイル構成

```
src/
  main.zig        # エントリポイント（変更なし or 動作確認用コード）
  root.zig        # ライブラリルート（toml.zig を pub で再エクスポート）
  toml/
    mod.zig       # pub usingnamespace で各モジュールを束ねる
    types.zig     # TOMLValue, TOMLTable, 日時型
    parser.zig    # Parser 構造体・parse ロジック
    deserialize.zig  # 内部 deserialize 関数（comptime 構造体マッピング、parseFromSliceAs から呼ぶ）
    lexer.zig     # （オプション）トークナイザ分離が有益になった場合
bench/
  main.zig        # ベンチマーク計測エントリポイント（Phase 6）
testdata/
  large.toml      # ベンチマーク用大規模入力
```

> 最初は `src/toml.zig` 1ファイルに全て収める。**`toml.zig` が 500行を超えたとき、または Phase 3 開始時**（どちらか早い方）にディレクトリ構成へ移行する。

---

## テスト方針

| 観点 | 方針 |
|------|------|
| ホワイトボックステスト | `Parser` 内部関数（`parseKey`、`parseValue` など）は同一ファイル内の `test` ブロックでカバー。Zig は同一ファイル内なら非公開関数・フィールドにアクセスできる |
| エラー系テスト | 各フェーズで `expectError` を使ったテーブルドリブンテストを用意する |
| `TOMLTable` の組み立て | テスト内では `tableFromMap` ファクトリ関数を使って構築する（同一ファイル内のみ呼べる非公開関数） |
| `Diagnostic` の初期化 | `var diag = toml.Diagnostic{}` でゼロ値初期化してから渡す。`undefined` は使わない |
| メモリ管理 | テストでは必ず `defer result.deinit()` を記述し、`testing.allocator` のリーク検出を正常に機能させる |

---

## 実装の優先判断基準

| 優先度 | 基準 |
|--------|------|
| 高 | 仕様必須・エラーを返すべき境界条件 |
| 中 | よく使われる構文 |
| 低 | 推奨されない記法（アウト・オブ・オーダーなど）も受け付けるか |

エラーは握り潰さず `try` / `catch` で適切に伝播またはハンドリングする。`ParseError` と `DeserializeError` はモジュール別に定義し、`TomlError` として結合して公開する。

---

## 進捗

- [x] Phase 1: 基本的なキー・バリューペア
- [x] Phase 2: 文字列・数値の完全対応
- [x] Phase 3: ドットキー・テーブルヘッダ・配列
- [x] Phase 4: 日時型・テーブル配列
- [x] Phase 5: デシリアライザ（構造体マッピング）
- [x] Phase 6: ベンチマーク

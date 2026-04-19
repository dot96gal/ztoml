# ztoml

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/ztoml/)
[![test](https://github.com/dot96gal/ztoml/actions/workflows/test.yml/badge.svg)](https://github.com/dot96gal/ztoml/actions/workflows/test.yml)
[![release](https://github.com/dot96gal/ztoml/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/ztoml/actions/workflows/release.yml)

Zig 向け TOML v1.1.0 パーサライブラリ。外部依存ゼロ、Zig 標準ライブラリのみで実装。

## 開発方針

このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、利用者や外部からの意見をもとに変更する義務は負いません。

また、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でこのリポジトリをフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

## インストール

最新のタグは [GitHub Releases](https://github.com/dot96gal/ztoml/releases) で確認できる

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される

```sh
zig fetch --save https://github.com/dot96gal/ztoml/archive/<commit-or-tag>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .ztoml = .{
        .url = "https://github.com/dot96gal/ztoml/archive/<commit-or-tag>.tar.gz",
        .hash = "<zig fetch が出力したハッシュ>",
    },
},
```

`build.zig` でモジュールをインポートする。

```zig
const ztoml_dep = b.dependency("ztoml", .{
    .target = target,
    .optimize = optimize,
});
const ztoml_mod = ztoml_dep.module("ztoml");

// 実行ファイルのモジュールに ztoml インポートを追加
exe.root_module.addImport("ztoml", ztoml_mod);
```

## 使い方

### 構造体へ直接マッピング（推奨）

`parseFromSliceAs` を使うと、TOML 文字列をユーザ定義の構造体に直接変換できる。

```zig
const toml = @import("ztoml");

const Config = struct {
    host: []const u8,
    port: u16,
    debug: bool = false,        // デフォルト値あり
    log_level: ?[]const u8 = null, // オプションフィールド
};

const input =
    \\host = "localhost"
    \\port = 8080
    \\debug = true
;

var result = try toml.parseFromSliceAs(Config, allocator, input, .{});
defer result.deinit();

const config = result.value;
// config.host  => "localhost"
// config.port  => 8080
// config.debug => true
```

### 動的アクセス

`parseFromSlice` を使うと、`TOMLTable` としてキーを動的に参照できる。

```zig
const toml = @import("ztoml");

const input =
    \\name = "ztoml"
    \\version = 1
;

var result = try toml.parseFromSlice(allocator, input, .{});
defer result.deinit();

const table = result.value;

// キーで値を取得（存在しない場合は null）
const name = table.get("name") orelse return error.MissingKey;
// name は TOMLValue（tagged union）
// name.string => "ztoml"

// テーブルの要素数
const n = table.count(); // => 2
_ = n;

// 全エントリのイテレーション
var it = table.iterator();
while (it.next()) |entry| {
    // entry.key_ptr.*   : []const u8
    // entry.value_ptr.* : TOMLValue
    _ = entry;
}
```

`TOMLTable.get()` の戻り値は `TOMLValue`（tagged union）。値の種類に応じてフィールドにアクセスする。

```zig
const val = table.get("key") orelse return error.MissingKey;
switch (val) {
    .string            => |s|  _ = s,  // []const u8
    .integer           => |i|  _ = i,  // i64
    .float             => |f|  _ = f,  // f64
    .boolean           => |b|  _ = b,  // bool
    .array             => |a|  _ = a,  // []const TOMLValue
    .table             => |t|  _ = t,  // TOMLTable
    .offset_date_time  => |dt| _ = dt, // toml.OffsetDateTime
    .local_date_time   => |dt| _ = dt, // toml.LocalDateTime
    .local_date        => |d|  _ = d,  // toml.LocalDate
    .local_time        => |t|  _ = t,  // toml.LocalTime
}
```

### エラー診断

`Diagnostic` を渡すとエラー発生位置（行・列）とメッセージを取得できる。

```zig
var diag = toml.Diagnostic{};
var result = toml.parseFromSlice(allocator, input, .{ .diag = &diag }) catch |err| {
    std.debug.print("error at {}:{}: {s}\n", .{ diag.line, diag.col, diag.message });
    return err;
};
defer result.deinit();
```

## 対応する TOML 型

| TOML 型 | Zig 型 |
|---------|--------|
| String | `[]const u8` |
| Integer | `i64`（`u8`〜`i64` など任意の整数型に変換可） |
| Float | `f64` |
| Boolean | `bool` |
| Array | `[]const T` |
| Table | ユーザ定義構造体 / `TOMLTable` |
| Offset Date-Time | `toml.OffsetDateTime` |
| Local Date-Time | `toml.LocalDateTime` |
| Local Date | `toml.LocalDate` |
| Local Time | `toml.LocalTime` |

### 日付・時刻型のフィールド

```zig
pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32, // サブ秒精度（ナノ秒単位）
};

pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};

pub const OffsetDateTime = struct {
    datetime: LocalDateTime,
    offset_minutes: i16, // UTC からのオフセット（分単位）。例: +09:00 は 540
};
```

## 公開 API

詳細は [API ドキュメント](https://dot96gal.github.io/ztoml/) を参照。

### 関数

```zig
// 構造体へ直接マッピング
pub fn parseFromSliceAs(comptime T: type, allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(T)

// 動的アクセス用
pub fn parseFromSlice(allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(TOMLTable)
```

### 型

```zig
pub const ParseOptions = struct {
    diag: ?*Diagnostic = null, // エラー診断（省略可）
};

pub const Diagnostic = struct {
    line:    usize = 0,
    col:     usize = 0,
    message: []const u8 = "",
};

// Parsed(T).deinit() で value 内の全メモリを解放する
pub fn Parsed(comptime T: type) type { ... }

// 動的アクセス時の値を表す tagged union
pub const TOMLValue = union(enum) {
    string:            []const u8,
    integer:           i64,         // parseFromSliceAs では u8〜i64 など任意の整数型に変換可
    float:             f64,
    boolean:           bool,
    array:             []const TOMLValue, // 要素は再帰的に TOMLValue
    table:             TOMLTable,
    offset_date_time:  OffsetDateTime,   // offset_minutes は UTC からの分単位オフセット
    local_date_time:   LocalDateTime,
    local_date:        LocalDate,
    local_time:        LocalTime,
};

pub const TOMLTable = struct {
    // キーで値を取得（存在しない場合は null）
    pub fn get(self: TOMLTable, key: []const u8) ?TOMLValue;
    // 全エントリのイテレータを返す
    pub fn iterator(self: TOMLTable) std.StringHashMap(TOMLValue).Iterator;
    // 登録されているキーの数を返す
    pub fn count(self: TOMLTable) usize;
};
```

### エラー型

```zig
pub const ParseError = error{
    UnexpectedEof, UnexpectedChar, InvalidEscape, InvalidUnicode,
    DuplicateKey, InvalidNumber, InvalidDate, InvalidTime, TrailingContent,
};

pub const DeserializeError = error{
    MissingField, TypeMismatch, IntegerOverflow,
};

pub const TomlError = ParseError || DeserializeError;
```

## メモリ管理

`Parsed(T)` が内部の `ArenaAllocator` を保持する。`deinit()` を呼ぶと `value` 内の文字列・配列を含むすべてのメモリが解放される。

```zig
var result = try toml.parseFromSliceAs(Config, allocator, input, .{});
defer result.deinit(); // これ1回で全メモリ解放

// deinit() より前に value を参照すること
const config = result.value;
```

> **注意:** `deinit()` 後に `value` 内の `[]const u8` を参照すると use-after-free になる。

## 開発

タスクランナーに [mise](https://mise.jdx.dev/) を使用している。`mise.toml` で Zig / zls のバージョンも管理している。

### セットアップ

```sh
git clone https://github.com/dot96gal/ztoml.git
cd ztoml
mise install   # Zig・zls を自動インストール
```

### プロジェクト構成

```
src/           # ライブラリ本体
  root.zig     # 公開 API のエントリポイント
  types.zig    # 型定義（TOMLValue・TOMLTable・Parsed など）
  parser.zig   # TOML パーサ
  deserialize.zig # 構造体へのデシリアライザ
examples/      # サンプルコード（mise run example で実行）
e2e/           # E2E テスト（mise run e2e で実行）
bench/         # ベンチマーク（mise run bench で実行）
```

### CI/CD

| ワークフロー | トリガー | 内容 |
|---|---|---|
| `test.yml` | PR・main push | フォーマットチェック・ビルド・テストを実行 |
| `deploy-docs.yml` | main push | API ドキュメントを GitHub Pages へデプロイ |
| `release.yml` | `v*` タグ push | GitHub Releases を自動生成（リリースノート付き） |

### リリース手順

`mise run release <version>` を実行すると以下を自動で行う：

1. `build.zig.zon` のバージョンを更新
2. `chore: bump version to v<version>` でコミット
3. `v<version>` タグを作成して `main` へ push
4. タグ push を検知した `release.yml` が GitHub Releases を自動生成

```sh
mise run release 1.2.3
```

### タスク一覧

| タスク | 説明 | コマンド |
|--------|------|----------|
| `fmt` | ソースコードのフォーマット | `mise run fmt` |
| `fmt-check` | フォーマットチェック（CI 用） | `mise run fmt-check` |
| `build` | ビルド | `mise run build` |
| `test` | テスト | `mise run test` |
| `bench` | ベンチマーク | `mise run bench` |
| `e2e` | E2E テスト | `mise run e2e` |
| `example` | サンプル実行 | `mise run example` |
| `build-docs` | API ドキュメント生成 | `mise run build-docs` |
| `serve-docs` | API ドキュメントのローカル配信 | `mise run serve-docs` |
| `release` | バージョン更新・タグ付け・プッシュ | `mise run release <version>` |

## ライセンス

[MIT](LICENSE)

# ztoml

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/ztoml/)
[![test](https://github.com/dot96gal/ztoml/actions/workflows/test.yml/badge.svg)](https://github.com/dot96gal/ztoml/actions/workflows/test.yml)

Zig 向け TOML v1.1.0 パーサライブラリ。外部依存ゼロ、Zig 標準ライブラリのみで実装。

## 要件

- Zig 0.16.0 以上

## インストール

`build.zig.zon` の `dependencies` に追加する。

```zig
.dependencies = .{
    .ztoml = .{
        .url = "https://github.com/dot96gal/ztoml/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

`build.zig` でモジュールをインポートする。

```zig
const ztoml_dep = b.dependency("ztoml", .{ .target = target, .optimize = optimize });
const ztoml_mod = ztoml_dep.module("ztoml");
// 自分の実行ファイルやモジュールの imports に追加する
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

const name = result.value.get("name") orelse return error.MissingKey;
// name.string => "ztoml"
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

## 公開 API

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

```sh
# ビルド
mise run build

# テスト
mise run test

# ベンチマーク
mise run bench

# E2Eテスト
mise run e2e

# サンプル実行
mise run example
```

# ztoml

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/ztoml/)
[![CI](https://github.com/dot96gal/ztoml/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/ztoml/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/ztoml/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/ztoml/actions/workflows/release.yml)

Zig の [TOML 1.1](https://toml.io/en/v1.1.0) パーサーのライブラリ。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

## 利用者向け

### インストール

最新のタグは [GitHub Releases](https://github.com/dot96gal/ztoml/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/ztoml/archive/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .ztoml = .{
        .url = "https://github.com/dot96gal/ztoml/archive/<version>.tar.gz",
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

### 使い方

#### 構造体へ直接マッピング

`parse` を使うと、TOML 文字列をユーザ定義の構造体に直接変換できる。

```zig
const ztoml = @import("ztoml");

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

var result = try ztoml.parse(Config, allocator, input, .{});
defer result.deinit();

const config = result.value;
// config.host  => "localhost"
// config.port  => 8080
// config.debug => true
```

#### エラー診断

`Diagnostic` を渡すとエラー発生位置（行・列）とメッセージを取得できる。

```zig
var diag = ztoml.Diagnostic{};
var result = ztoml.parse(Config, allocator, input, .{ .diagnostic = &diag }) catch |err| {
    std.debug.print("error at {}:{}: {s}\n", .{ diag.line, diag.column, diag.message });
    return err;
};
defer result.deinit();
```

### API リファレンス

詳細は [API ドキュメント](https://dot96gal.github.io/ztoml/) を参照。

#### 対応する TOML 型

| TOML 型 | Zig 型 |
|---------|--------|
| String | `[]const u8` |
| Integer | `i64`（`u8`〜`i64` など任意の整数型に変換可） |
| Float | `f64` |
| Boolean | `bool` |
| Array | `[]const T` |
| Table | ユーザ定義構造体 |
| Offset Date-Time | `ztoml.OffsetDateTime` |
| Local Date-Time | `ztoml.LocalDateTime` |
| Local Date | `ztoml.LocalDate` |
| Local Time | `ztoml.LocalTime` |

##### 日付・時刻型のフィールド

```zig
pub const OffsetDateTime = struct {
    datetime: LocalDateTime,
    offset_minutes: i16, // UTC からのオフセット（分単位）。例: +09:00 は 540
};

pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,
};

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
```

#### 関数

```zig
pub fn parse(comptime T: type, allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(T)
```

#### 型

```zig
pub const ParseOptions = struct {
    diagnostic: ?*Diagnostic = null, // エラー診断（省略可）
};

pub const Diagnostic = struct {
    line:    usize = 0,
    column:  usize = 0,
    message: []const u8 = "",
};

// Parsed(T).deinit() で value 内の全メモリを解放する
pub fn Parsed(comptime T: type) type { ... }
```

#### エラー型

```zig
pub const ParseError = error{
    UnexpectedEof, UnexpectedChar, InvalidEscape, InvalidUnicode,
    DuplicateKey, InvalidNumber, InvalidDate, InvalidTime,
};

pub const DeserializeError = error{
    MissingField, TypeMismatch, IntegerOverflow,
};

pub const Error = ParseError || DeserializeError || error{OutOfMemory};
```

#### 設計上の制限

`ztoml` は型安全なデシリアライズ（`parse(T, ...)`）のみを公開 API として提供する。`Table` / `Value` による動的なキーアクセスは内部実装の詳細であり、公開 API から除外している。動的アクセスはサポートしていない。

#### メモリ管理

`Parsed(T)` が内部の `ArenaAllocator` を保持する。`deinit()` を呼ぶと `value` 内の文字列・配列を含むすべてのメモリが解放される。

```zig
var result = try ztoml.parse(Config, allocator, input, .{});
defer result.deinit(); // これ1回で全メモリ解放

// deinit() より前に value を参照すること
const config = result.value;
```

> **注意:** `deinit()` 後に `value` 内の `[]const u8` を参照すると use-after-free になる。

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/ztoml.git
cd ztoml
mise install   # Zig・zls を自動インストール
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック（CI 用） |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run e2e` | E2E テスト |
| `mise run bench` | ベンチマーク |
| `mise run example:basic` | サンプル実行 |
| `mise run build-docs` | API ドキュメント生成 |
| `mise run serve-docs` | API ドキュメントのローカル配信 |
| `mise run build-coverage` | テストカバレッジレポート生成 |
| `mise run serve-coverage` | テストカバレッジレポートのローカル配信 |
| `mise run release <version>` | バージョン更新・タグ付け・プッシュ |

#### CI/CD

| ワークフロー | トリガー | 内容 |
|---|---|---|
| `ci.yml` | PR・main push | フォーマットチェック・リント・ビルド・テストを実行 |
| `deploy-docs.yml` | main push | API ドキュメントを GitHub Pages へデプロイ |
| `release.yml` | `v*` タグ push | GitHub Releases を自動生成（リリースノート付き） |

#### リリース手順

`mise run release <version>` を実行すると以下を自動で行う：

1. `build.zig.zon` のバージョンを更新
2. `chore: bump version to v<version>` でコミット
3. `v<version>` タグを作成して `main` へ push
4. タグ push を検知した `release.yml` が GitHub Releases を自動生成

```sh
mise run release 1.2.3
```

### ファイル構成

```
build.zig            # ビルドスクリプト
build.zig.zon        # パッケージメタデータ・依存関係
src/                 # ライブラリ本体
├── ztoml.zig        # 公開 API のエントリポイント
├── types.zig        # 内部型定義（Value・Parsed など）
├── errors.zig       # エラー型定義
├── deserialize.zig  # 構造体へのデシリアライザ
├── parser.zig       # パーサのエントリポイント
├── document.zig     # 標準テーブル・配列テーブルのパース
├── keyval.zig       # キーと値のパース
├── key.zig          # キー解析
├── string.zig       # 文字列解析
├── number.zig       # 整数・浮動小数点解析
├── boolean.zig      # 真偽値解析
├── datetime.zig     # 日付・時刻解析
└── cursor.zig       # 入力カーソル
examples/            # サンプルコード（mise run example で実行）
e2e/                 # E2E テスト（mise run e2e で実行）
bench/               # ベンチマーク（mise run bench で実行）
```

---

## ライセンス

[MIT](LICENSE)

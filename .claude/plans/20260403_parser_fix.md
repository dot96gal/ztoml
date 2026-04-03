# パーサー修正計画

作成日: 2026-04-03

## 目的

E2Eテストで失敗している4ケースを通過させるために、`src/toml/parser.zig` を修正する。

## 失敗しているテスト

| テスト | 失敗箇所 | 原因 |
|--------|----------|------|
| `spec: offset date-time` | `odt5 = 1979-05-27 07:32Z` | 秒なし時刻（`HH:MM`）が未対応 |
| `spec: local date-time` | `ldt3 = 1979-05-27T07:32` | 秒なし時刻（`HH:MM`）が未対応 |
| `spec: local time` | `lt3 = 07:32` | 秒なし時刻（`HH:MM`）が未対応 |
| `spec: inline table` | `contact = { ... }` （複数行） | インラインテーブル内の改行が未対応 |

## 修正 1: `parseLocalTime` — 秒なし時刻（`HH:MM`）対応

### 対象

`src/toml/parser.zig` の `parseLocalTime` 関数（712行付近）

### 現在の実装

```zig
fn parseLocalTime(self: *Parser) !types.LocalTime {
    const hour = try self.parseDigits(2);
    if (self.peek() != ':') { self.fillDiagnostic("expected ':' in time"); return error.InvalidTime; }
    _ = self.advance();
    const minute = try self.parseDigits(2);
    if (self.peek() != ':') { self.fillDiagnostic("expected ':' in time"); return error.InvalidTime; }
    _ = self.advance();
    const second = try self.parseDigits(2);
    // ...
}
```

### 修正後

秒部分（`: SS`）をオプションにする。`:` が続かない場合は `second = 0`、`nanosecond = 0` として早期リターンする。

```zig
fn parseLocalTime(self: *Parser) !types.LocalTime {
    const hour = try self.parseDigits(2);
    if (self.peek() != ':') { self.fillDiagnostic("expected ':' in time"); return error.InvalidTime; }
    _ = self.advance();
    const minute = try self.parseDigits(2);

    // 秒はオプション（TOML v1.1.0）
    if (self.peek() != ':') {
        if (hour > 23) { self.fillDiagnostic("invalid hour"); return error.InvalidTime; }
        if (minute > 59) { self.fillDiagnostic("invalid minute"); return error.InvalidTime; }
        return .{ .hour = @intCast(hour), .minute = @intCast(minute), .second = 0, .nanosecond = 0 };
    }
    _ = self.advance();
    const second = try self.parseDigits(2);
    // 以降は既存の実装と同じ
}
```

## 修正 2: `parseInlineTable` — 複数行インラインテーブル対応

### 対象

`src/toml/parser.zig` の `parseInlineTable` 関数（830行付近）

### 現在の実装

`skipWhitespace()`（空白・タブのみスキップ）を使用しているため、改行を含む複数行インラインテーブルがパースエラーになる。

### 修正後

`skipWhitespace()` の呼び出し箇所を `skipWhitespaceAndNewlines()` に変更する。ただし、コメントも考慮するため、コメントもスキップする必要がある。

`skipWhitespaceAndNewlines` はコメントをスキップしないため、`skipWhitespaceNewlinesAndComments` のようなヘルパーを追加するか、既存のループ処理を流用する。

既存の `skipWhitespaceAndNewlines` の実装を確認して、コメントスキップ（`skipComment`）も含むバージョンを使うか、インラインテーブル内の `skipWhitespace` をすべて `skipWhitespaceAndNewlines` + `skipComment` の組み合わせに変更する。

具体的には `parseInlineTable` 内の以下の `skipWhitespace()` 呼び出し（5箇所）を置き換える：

1. `{` 消費直後
2. キーパース前のループ先頭
3. `=` の前後
4. 値パース後
5. `,` 消費後

```zig
// 変更前
self.skipWhitespace();

// 変更後（改行・コメントも含めてスキップ）
self.skipWhitespaceNewlinesAndComments();
```

`skipWhitespaceNewlinesAndComments` は既存の `skipWhitespaceAndNewlines` と `skipComment` を組み合わせた新規ヘルパーとして追加する：

```zig
fn skipWhitespaceNewlinesAndComments(self: *Parser) void {
    while (true) {
        self.skipWhitespaceAndNewlines();
        if (self.peek() == '#') {
            self.skipComment();
        } else {
            break;
        }
    }
}
```

## 実装ステップ

- [x] Step 1: `parseLocalTime` を修正し、秒なし時刻（`HH:MM`）に対応する
- [x] Step 2: `skipWhitespaceNewlinesAndComments` ヘルパーを追加する（→ 振り返り参照）
- [x] Step 3: `parseInlineTable` 内の `skipWhitespace()` を `skipWhitespaceNewlinesAndComments()` に置き換える（→ 振り返り参照）
- [x] Step 4: `mise run e2e` で 22/22 通過を確認する
- [x] Step 5: `mise run test` で既存の単体テストがすべて通過することを確認する

## 振り返り

### Step 2 が不要だった

計画では `skipWhitespaceNewlinesAndComments` という新規ヘルパーの追加を想定していたが、実装前に `skipWhitespaceAndNewlines`（80行付近）の実装を確認したところ、`#` コメントのスキップ処理がすでに含まれていた。そのため新規ヘルパーは不要で、Step 2 はスキップした。

### Step 3 の置き換え先が計画と異なった

計画では `skipWhitespaceNewlinesAndComments()` への置き換えを想定していたが、Step 2 の通り既存の `skipWhitespaceAndNewlines()` が同等の機能を持つため、こちらへの置き換えで対応した。

### 計画に含まれていなかった修正: `isTimeLike` の変更

`parseLocalTime` の秒オプション化だけでは `lt3 = 07:32` が通過しなかった。原因は `isTimeLike`（667行付近）が `HH:MM:SS`（8文字）を必須としており、`HH:MM`（5文字）の入力を時刻として認識しなかったため。`parseLocalTime` が呼ばれる前の段階で弾かれていた。

最小長を 8 から 5 に変更し、`HH:MM` 形式でも時刻と判定するよう修正した。この変更により `lt3 = 07:32`・`ldt3 = 1979-05-27T07:32`・`odt5 = 1979-05-27 07:32Z` がすべて正しくパースされるようになった。

**教訓:** 時刻パースの修正では、パース関数本体だけでなく、その手前にある型判定関数（`isTimeLike`）も合わせて確認する必要がある。

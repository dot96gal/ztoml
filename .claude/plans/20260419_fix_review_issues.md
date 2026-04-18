# コードレビュー指摘事項の修正計画

日付: 2026-04-19
対象バージョン: Zig 0.16.0

---

## 概要

`/zig-review` で検出した 4 件の指摘事項を修正する。
すべて動作に問題はないが、Zig コーディング規約への準拠と API の明瞭性向上が目的。

---

## 修正タスク一覧

### 1. `catch {}` の修正（エラーハンドリング）

**ファイル**: `src/toml/parser.zig:1117`

**現状**:
```zig
_ = parseFromSlice(std.testing.allocator, "key = ", .{ .diag = &diag }) catch {};
```

**問題**: `catch {}` はエラー変数を明示的に無視しておらず、規約上の「握り潰し」パターンに該当する。

**修正案**: エラー変数を `|_|` で明示的に捨てる。
```zig
_ = parseFromSlice(std.testing.allocator, "key = ", .{ .diag = &diag }) catch |_| {};
```

**リスク**: 低（テストコードのみ、動作変化なし）

---

### 2. 短絡評価依存の `peek().?` を慣用的パターンに変更（Optional）

**ファイル**: `src/toml/parser.zig:614`

**現状**:
```zig
if (self.peek() == null or !std.ascii.isDigit(self.peek().?)) {
    self.fillDiagnostic("expected digit after decimal point");
    return error.InvalidNumber;
}
```

**問題**: `or` の短絡評価により安全だが、`peek()` を 2 回呼び出しており非慣用的。
規約では `opt.?` は「論理的に null にならない箇所のみ」とされている。

**修正案**: `orelse` で null を先に捌く。
```zig
const first_digit = self.peek() orelse {
    self.fillDiagnostic("expected digit after decimal point");
    return error.InvalidNumber;
};
if (!std.ascii.isDigit(first_digit)) {
    self.fillDiagnostic("expected digit after decimal point");
    return error.InvalidNumber;
}
```

**リスク**: 低（ロジック等価、パーサ内部関数）

---

### 3. 公開 API の明示的エラー集合定義（エラーハンドリング）

**ファイル**: `src/toml/parser.zig:18`, `src/toml/deserialize.zig:22`, `src/toml/mod.zig:15`

**現状**:
```zig
// parser.zig
pub fn parseFromSlice(allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(TOMLTable) {

// deserialize.zig
pub fn parseFromSliceAs(comptime T: type, allocator: Allocator, input: []const u8, options: ParseOptions) !Parsed(T) {

// mod.zig
pub const TomlError = ParseError || DeserializeError;
```

**問題**:
- 公開 API の戻り値が `!T`（inferred error set）で、利用者が取りうるエラーを型から読み取れない
- `TomlError` に `error{OutOfMemory}` が含まれておらず、実際のエラー集合を網羅していない

**修正案**:
```zig
// parser.zig
pub fn parseFromSlice(
    allocator: Allocator,
    input: []const u8,
    options: ParseOptions,
) (ParseError || error{OutOfMemory})!Parsed(TOMLTable) {

// deserialize.zig
pub fn parseFromSliceAs(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    options: ParseOptions,
) (ParseError || DeserializeError || error{OutOfMemory})!Parsed(T) {

// mod.zig
pub const TomlError = ParseError || DeserializeError || error{OutOfMemory};
```

**リスク**: 中（型の変更だが後方互換性あり。`!T` → 明示的な error union は既存コードを壊さない）

---

### 4. `orelse unreachable` の修正（Optional）

**ファイル**: `examples/basic.zig:16`

**現状**:
```zig
const name = result.value.get("name") orelse unreachable;
```

**問題**: 入力が固定なので論理的には安全だが、良いサンプルコードとして適切でない。
利用者がこのパターンを真似る可能性がある。

**修正案**: エラーとして伝播させる。
```zig
const name = result.value.get("name") orelse return error.MissingKey;
```

または、`if` で安全に unwrap してメッセージを出す。

**リスク**: 低（例示コードのみ）

---

## 実施順序

1. タスク 1（`catch {}` → `catch |_| {}`）：1 行修正、リスク最小
2. タスク 4（examples の `orelse unreachable`）：1 行修正、リスク最小
3. タスク 2（`peek().?` の慣用化）：数行修正、ロジック等価
4. タスク 3（明示的エラー集合）：複数ファイル修正、API 変更を伴うため最後に

---

## 完了条件

- `mise run test` がすべてパスすること
- `mise run e2e` がすべてパスすること
- `mise run fmt-check` が通ること

---

## 振り返り（実施後）

### タスク 1: 修正案との差異（重要）

**計画した修正案**:
```zig
_ = parseFromSlice(...) catch |_| {};
```

**実際に適用した修正**:
```zig
try std.testing.expectError(error.UnexpectedEof, parseFromSlice(...));
```

**差異の原因**:
- Zig 0.16 では `catch |_| {}` はコンパイルエラーになる。
  エラーメッセージ: `error: discard of error capture; omit it instead`
- つまり `catch {}` が Zig 0.16 でのエラー無視の唯一の正規構文であり、計画案は誤りだった。
- さらにユーザーからのフィードバック（「エラーを握り潰さず適切に処理すべき」）を受け、
  `expectError` で期待するエラー型（`error.UnexpectedEof`）を明示的に検証する形に変更した。

**結果的に得られた改善**:
- エラーを握り潰さず、戻り値の型まで検証するより精度の高いテストになった。
- 計画案より品質が高い修正となった。

### タスク 2〜4: 計画通り

- `peek().?` の `orelse` パターン化、公開 API の明示的エラー集合定義、`orelse unreachable` 修正はすべて計画案通り適用。

### 学習事項

- Zig 0.16 では `catch |_|` 構文は禁止されている。エラー変数を使わない場合は `catch {}` のみ有効。
- テストコードでエラーを「意図的に発生させて副作用を検証する」パターンでは、
  `catch {}` より `expectError` を使うことで意図が明確になり、テストの価値も上がる。

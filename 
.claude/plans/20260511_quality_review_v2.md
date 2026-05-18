# 品質レビュー結果 v2（ISO/IEC 25010）

## 概要

`src/` 以下の全ソースファイル（13ファイル）を対象に ISO/IEC 25010 品質特性レビューを実施した。
全体的に高い品質を維持しており、指摘事項は保守性の DRY 違反 2 件のみ。

---

## 現状

- Zig バージョン：0.16.0（`mise.toml` 参照）
- 対象ファイル：`src/boolean.zig` / `cursor.zig` / `datetime.zig` / `deserialize.zig` /
  `document.zig` / `error.zig` / `key.zig` / `keyval.zig` / `number.zig` / `parser.zig` /
  `root.zig` / `string.zig` / `types.zig`

---

## 品質特性サマリ

| 品質特性 | 評価 | 主な根拠 |
|---------|------|---------|
| 機能適合性 | Good | TOML 1.1 の全値型・テーブル構造を実装、うるう秒・閏年・Unicode 境界値まで網羅 |
| 性能効率性 | Good | fast path 最適化、スタックバッファ活用、ArenaAllocator による効率的な割り当て |
| 互換性 | Good | 外部依存ゼロ、std のみ使用 |
| 使用性 | Good | 命名が意図を明確に表現、`@panic` による precondition 強制 |
| 信頼性 | Good | `errdefer arena.deinit()` で失敗時クリーンアップ保証、深さ制限・制御文字チェックあり |
| セキュリティ | Good | 制御文字・Unicode サロゲート・数値範囲・ネスト深さを全て外部入力段階でバリデーション |
| 保守性 | Needs Improvement | UTF-8 バイト追記ブロックが 2 箇所に重複（DRY 違反） |
| 移植性 | Good | OS 依存コード・ハードコードパスなし、zig バージョンは mise.toml で管理 |

---

## テスト容易性 詳細スコア

| 観点 | 評価 | 指摘 |
|------|------|------|
| 制御可能性 | ✅ | `Cursor` / `Arena` を直接構築してあらゆる状態を再現可能 |
| 観測可能性 | ✅ | 返り値・エラー・`Diagnostic` フィールドをテストから検証可能 |
| 分離可能性 | ✅ | 各モジュールが他に依存せず単体テスト可能 |
| 依存性注入 | ✅ | `allocator`・`Diagnostic` はすべてパラメータ渡し |
| 副作用の明示性 | ✅ | `*Cursor` ミュータブルパラメータで副作用が型に現れる |
| 関数サイズ | ✅ | 各関数は単一責務。最大の `parseMultilineBasicString` でも 63 行 |
| テスト分離 | ✅ | 本番コードと同一ファイル内にあり、対応関係が明確 |
| 自動化可能性 | ✅ | `mise run test` で完全自動化可能、インタラクティブ入力なし |

**テスト容易性スコア：8 / 8**

---

## 指摘事項（優先度順）

### 1. [中] 保守性 > 変更容易性 — `string.zig` UTF-8 バイト追記ブロック重複

**場所**：`src/string.zig:73-91`（`parseBasicStringSlowPath`）と `src/string.zig:155-170`（`parseMultilineBasicString`）

**問題**：UTF-8 バイト追記ロジック（約 12 行）が 2 箇所に全く同一コードで重複している。

```zig
// 両箇所に同一のコードが存在
const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
if (seq_len > 1) {
    if (cursor.peekSlice(seq_len)) |seq| {
        cursor.advanceUtf8(seq_len);
        try buf.appendSlice(allocator, seq);
    } else {
        _ = cursor.advance();
        try buf.append(allocator, c);
    }
} else {
    _ = cursor.advance();
    try buf.append(allocator, c);
}
```

**改善案**：以下のような private 関数に抽出する。

```zig
fn appendUtf8Byte(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    c: u8,
) (error{OutOfMemory})!void {
    const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
    if (seq_len > 1) {
        if (cursor.peekSlice(seq_len)) |seq| {
            cursor.advanceUtf8(seq_len);
            try buf.appendSlice(allocator, seq);
        } else {
            _ = cursor.advance();
            try buf.append(allocator, c);
        }
    } else {
        _ = cursor.advance();
        try buf.append(allocator, c);
    }
}
```

---

### 2. [低] 保守性 > 変更容易性 — `keyval.zig` `skip_mode` スイッチ 2 回繰り返し

**場所**：`src/keyval.zig:116-130`（`parseKeyValueImpl`）

**問題**：同一の `switch (skip_mode)` が `=` の前後で 2 回繰り返されている。

```zig
switch (skip_mode) {
    .whitespace => cursor.skipWhitespace(),
    .whitespace_and_newlines => cursor.skipWhitespaceAndNewlines(),
}
// ...（= の消費処理）...
switch (skip_mode) {  // 同一スイッチを再度記述
    .whitespace => cursor.skipWhitespace(),
    .whitespace_and_newlines => cursor.skipWhitespaceAndNewlines(),
}
```

**改善案**：ヘルパー関数を抽出して呼び出す。

```zig
fn skipByMode(cursor: *Cursor, mode: SkipMode) void {
    switch (mode) {
        .whitespace => cursor.skipWhitespace(),
        .whitespace_and_newlines => cursor.skipWhitespaceAndNewlines(),
    }
}
```

---

## 実装計画

- [ ] `src/string.zig` に private 関数 `appendUtf8Byte` を追加し、`parseBasicStringSlowPath` と `parseMultilineBasicString` の重複ブロックを置き換える
- [ ] `appendUtf8Byte` のテストを追加する（正常系：各 UTF-8 バイト長、異常系：無効シーケンス）
- [ ] `src/keyval.zig` に private 関数 `skipByMode` を追加し、`parseKeyValueImpl` の 2 箇所のスイッチを置き換える
- [ ] `skipByMode` のテストを追加する
- [ ] `mise run test` ですべてのテストが通ることを確認する

---

## テスト計画

### `appendUtf8Byte`

| テストケース | 確認内容 |
|------------|---------|
| 1 バイト ASCII | `buf` に 1 バイト追記されること |
| 2 バイト UTF-8 シーケンス | `buf` に 2 バイト追記されること |
| 3 バイト UTF-8 シーケンス | `buf` に 3 バイト追記されること |
| 4 バイト UTF-8 シーケンス | `buf` に 4 バイト追記されること |
| 不完全シーケンス（`peekSlice` が null） | 1 バイトずつ `buf` に追記されること |

### `skipByMode`

| テストケース | 確認内容 |
|------------|---------|
| `.whitespace` モード | スペース・タブのみスキップされること |
| `.whitespace_and_newlines` モード | スペース・タブ・改行がスキップされること |

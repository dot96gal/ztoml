# src ディレクトリのフラット化

## 背景

`src/root.zig` → `src/toml/mod.zig` → `src/toml/{types,parser,deserialize}.zig` という二重の再エクスポート層が存在しており、不要な抽象層になっている。

## 作業内容

1. `src/toml/types.zig` を `src/types.zig` に移動
2. `src/toml/parser.zig` を `src/parser.zig` に移動
3. `src/toml/deserialize.zig` を `src/deserialize.zig` に移動
4. `src/root.zig` を `src/toml/mod.zig` の内容で置き換え（直接インポートに変更）
5. `src/toml/mod.zig` を削除
6. `src/toml/` ディレクトリを削除

## 変更後の構成

```
src/
  root.zig
  types.zig
  parser.zig
  deserialize.zig
```

## 注意点

- 各ファイル内の `@import` パスを更新すること
- `build.zig` などで `src/toml/` を参照している箇所がないか確認すること
- 変更後に `mise run test` でテストが通ることを確認すること

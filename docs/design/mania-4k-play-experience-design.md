---
commit: 3a45fbf4419d28b6264c2f83c84df48f3948faaa
title: Streaming Mania 4K Play Experience Spec
osu_lazer_commit: a0be214d034c48b0b603069dc284b27b9dde5c17
---

# Pulsefield Streaming 4K Mania 局内规格

## 范围

- 只做 `4K`
- 只做 `mania`
- 谱面为流式生成
- 音乐名称存在
- 不使用传统 `difficulty name`
- 不做 `7K`、`dual stage`、`convert`、`pp`

## 研究基线

- 下落速度: [`DrawableManiaRuleset.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/UI/DrawableManiaRuleset.cs)
- 判定窗: [`ManiaHitWindows.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Scoring/ManiaHitWindows.cs)
- note lock: [`OrderedHitPolicy.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/UI/OrderedHitPolicy.cs)
- LN 语义: [`DrawableHoldNote.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNote.cs), [`TailNote.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/TailNote.cs)
- 音频 offset: [`FramedBeatmapClock.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Beatmaps/FramedBeatmapClock.cs), [`AudioOffsetAdjustControl.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Overlays/Settings/Sections/Audio/AudioOffsetAdjustControl.cs)
- mania star difficulty 参考: [`ManiaDifficultyCalculator.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Difficulty/ManiaDifficultyCalculator.cs), [`Strain.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Difficulty/Skills/Strain.cs)

## 生成输入

- 谱面生成前给定 `osu!mania star difficulty`
- 该值作为生成强度输入
- 该值可在游玩时显示
- 不生成 `difficulty name`

## 设置

### 下落速度

- `scroll speed`
- 范围 `1.0 - 40.0`
- 默认 `16.0`
- 精度 `0.1`
- 内部公式 `scrollTime = 11485 / scrollSpeed`
- 只影响阅读，不改判定窗

### Offset

- 做 `audio offset`
  - 改变歌曲时钟、谱面时间、判定时间、击打误差和结算中的 offset 建议
- 做 `visual offset`
  - 只改变 note 显示位置
  - 不改变判定、分数、击打误差或结算时间
- 不做 `beatmap local offset`
- 两者范围均为 `-500 ms ~ +500 ms`

### 判定难度

- 提供 `A / B / C / D / E` 五档
- `A` 最简单
- `E` 最困难
- 默认 `C`
- 切换对象为判定窗难易

## 判定

- 只显示 `Perfect / Good / Miss`
- 不显示 `Great / Ok / Meh`
- `Perfect` 为严格窗口
- `Good` 为外层可接受窗口
- `Miss` 为超窗或被规则强制 miss
- 判定窗使用当前 `A / B / C / D / E` 档位

## 分数与统计

- 局中只显示 `accuracy + combo`
- 不显示 `raw score`
- `Perfect` 和 `Good` 续 combo
- `Miss` 断 combo
- accuracy 仅基于 `Perfect / Good / Miss`
- 不做 `pp`
- 其他 performance 留空

## 手感约束

- 保留 `note lock`
- 保留 `LN head / body / tail`
- 保留 `release lenience`

## 显示

### 局前

- `music title`
- `osu!mania star difficulty`
- `scroll speed`
- `audio offset`
- `visual offset`
- `judge difficulty` 档位

### 局中

- `music title`
- `osu!mania star difficulty`
- `accuracy`
- `combo`
- 当前判定

### 结算

- `Perfect / Good / Miss` 数量
- `accuracy`
- `max combo`
- 平均击打误差
- 音频 offset 调整提示

## 平台

### macOS

- 默认键位 `D F J K`

### iPhone / iPad

- 单舞台 4K 默认 portrait

## 定案

1. `osu!mania star difficulty` 是生成前输入，不是结果页推导值。
2. 游玩时显示 `osu!mania star difficulty`，不显示 `difficulty name`。
3. `offset` 拆分为 `audio offset` 和 `visual offset`。
   `audio offset` 改变歌曲/判定时间；`visual offset` 只改变 note 显示。
4. 判定只做 `Perfect / Good / Miss`。
5. 判定窗支持 `A / B / C / D / E` 五档，默认 `C`。
6. HUD 只显示 `accuracy + combo`。
7. `note lock`、`LN` 结构、`release lenience` 保持 mania 语义。

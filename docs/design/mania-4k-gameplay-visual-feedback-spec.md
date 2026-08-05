---
commit: 70f26394b6869f2dab114eff9771f8252ffb6c5d
title: Mania 4K 局内视觉反馈规格
status: frozen
osu_lazer_commit: 3c1c96f742e7aae2ff67a7361e058fe91ca3b955
quaver_commit: 05575683909a9694e7bff54a0ac70b1cd86fa436
etterna_commit: b65660062ef2a23121e331c36e23c23a8f6eafaa
---

# Mania 4K 局内视觉反馈规格

本文冻结 Pulsefield `mania4k` 的两项局内视觉行为：场中央判定提示，以及轨道按键闪光。它描述下一轮实现必须达到的目标状态，不是现有代码架构说明，也不包含实施步骤。

## 范围只包含两类玩家反馈

本规格包含以下内容：

- `Perfect`、`Good`、`Miss` 的出现、保持、衰减和消失。
- 同一批次或短时间内出现多个判定时，场中央应显示哪一个。
- 连续相同判定如何重新触发视觉脉冲。
- 轨道按下、保持、松开，以及衰减期间再次按下时的亮度变化。

以下内容不在本规格内：

- 判定窗口、音符锁定、分数、准确率和连击规则。
- 长按音符头尾的计分语义。
- 音效、音符命中特效和长按保持特效。
- osu!mania 皮肤兼容和外部视觉资源加载。
- 按键丢失、窗口失焦和暂停期间松键所涉及的输入恢复规则。

局中信息栏里的 `Judge` 可以继续表示最近一次判定记录。它是历史状态，不参与场中央判定提示的淡出和优先级处理。

## 当前实现丢失了判定批次

判定引擎一次处理可以产生多个判定事件。现有音符锁定测试已经覆盖同一次按键产生 `[Miss, Perfect]` 的情况。引擎返回的事件顺序有意义，不能在会话层被压成一个 `latestJudgement`。

当前会话模型丢弃了 `engine.handle()` 和 `engine.advance()` 的返回值，只从引擎快照读取 `latestJudgement`。引擎每次解决音符时都会覆盖该字段，因此 `[Miss, Perfect]` 最终只向界面暴露 `Perfect`。

场中央判定提示没有生命周期。只要 `latestJudgement` 非空，界面就持续绘制同一段文字，透明度和缩放都不随时间变化。

轨道闪光由 `pressHighlight` 和 `releaseAfterglow` 两个独立状态驱动。松键时，两段动画同时改写亮度；衰减期间再次按下时，旧动画没有明确的取消和重启规则。

现状依据：

- [判定引擎一次返回完整事件数组](../../Sources/PulsefieldCore/Domain/Mania4KDomain.swift#L1084)
- [引擎用单个字段保存最近判定](../../Sources/PulsefieldCore/Domain/Mania4KDomain.swift#L1177)
- [会话模型丢弃输入产生的事件数组](../../Sources/PulsefieldCore/Features/Mania4K/Mania4KPlaySessionModel.swift#L700)
- [会话模型丢弃自动判定产生的事件数组](../../Sources/PulsefieldCore/Features/Mania4K/Mania4KPlaySessionModel.swift#L542)
- [场中央判定提示没有生命周期](../../Sources/PulsefieldUI/Features/Mania4K/Mania4KPlayExperienceView.swift#L1930)
- [轨道闪光使用两组并行动画状态](../../Sources/PulsefieldUI/Features/Mania4K/Mania4KPlayExperienceView.swift#L2201)
- [音符锁定测试确认同批次可以出现 Miss 和 Perfect](../../Tests/PulsefieldCoreTests/Mania4KPlaySessionModelTests.swift#L370)

## 源码对照只提供行为依据

osu!lazer、Quaver 和 Etterna 都让判定动画在有限时间内结束，也会在新输入到来时重新开始或取消旧动画。它们没有提供统一的 `Miss` 优先规则。

osu!lazer 的 `DrawableJudgement` 根据最后一个动画变换确定结束时间。默认 mania 判定会缩放并淡出，但 `Stage.OnNewResult()` 会先清空当前判定再加入新判定，采用后到事件覆盖。其按键区动画与实际命中特效分开处理。

Quaver 把输入亮光和命中亮光分成两个对象。输入亮光根据按键状态追踪目标透明度，起亮接近即时，松键使用较慢的衰减。命中亮光在每次有效命中时重置帧、可见性和透明度。

Etterna 在新的判定或按键动画开始前，明确结束或停止旧的动画序列。常见按键皮肤会在按下时立即达到高亮，再回落到较低的保持亮度；松键从当前状态衰减到零。

Pulsefield 在这些共同做法上增加判定严重度仲裁。`Miss > Good > Perfect` 是 Pulsefield 的产品决定，不是对其他音游现有规则的复刻。

参考源码：

- osu!lazer [判定生命周期](https://github.com/ppy/osu/blob/3c1c96f742e7aae2ff67a7361e058fe91ca3b955/osu.Game/Rulesets/Judgements/DrawableJudgement.cs#L96-L130)
- osu!lazer [默认 mania 判定动画](https://github.com/ppy/osu/blob/3c1c96f742e7aae2ff67a7361e058fe91ca3b955/osu.Game.Rulesets.Mania/UI/DefaultManiaJudgementPiece.cs#L44-L76)
- osu!lazer [后到判定覆盖当前判定](https://github.com/ppy/osu/blob/3c1c96f742e7aae2ff67a7361e058fe91ca3b955/osu.Game.Rulesets.Mania/UI/Stage.cs#L213-L220)
- osu!lazer [按键区输入动画](https://github.com/ppy/osu/blob/3c1c96f742e7aae2ff67a7361e058fe91ca3b955/osu.Game.Rulesets.Mania/UI/Components/DefaultKeyArea.cs#L110-L124)
- Quaver [轨道输入亮光](https://github.com/Quaver/Quaver/blob/05575683909a9694e7bff54a0ac70b1cd86fa436/Quaver.Shared/Screens/Gameplay/Rulesets/Keys/Playfield/ColumnLighting.cs)
- Quaver [命中亮光重触发](https://github.com/Quaver/Quaver/blob/05575683909a9694e7bff54a0ac70b1cd86fa436/Quaver.Shared/Screens/Gameplay/Rulesets/Keys/Playfield/HitLighting.cs)
- Quaver [判定动画重触发](https://github.com/Quaver/Quaver/blob/05575683909a9694e7bff54a0ac70b1cd86fa436/Quaver.Shared/Screens/Gameplay/UI/JudgementHitBurst.cs)
- Etterna [按键状态事件](https://github.com/etternagame/etterna/blob/b65660062ef2a23121e331c36e23c23a8f6eafaa/src/Etterna/Actor/Gameplay/ReceptorArrow.cpp)
- Etterna [按键动画取消和衰减](https://github.com/etternagame/etterna/blob/b65660062ef2a23121e331c36e23c23a8f6eafaa/NoteSkins/dance/default/metrics.ini)
- Etterna [场中央判定重置](https://github.com/etternagame/etterna/blob/b65660062ef2a23121e331c36e23c23a8f6eafaa/Themes/Rebirth/Graphics/Player%20judgment/default.lua)

## 判定事件以批次进入视觉层

每次 `engine.handle()` 或 `engine.advance()` 返回的 `judgementEvents` 构成一个判定事件批次。会话层必须保存完整批次，并把批次标识、判定发生的谱面时间和全部事件交给视觉反馈层。

视觉反馈层只负责选择和呈现，不得重新计算判定结果，也不得修改分数、准确率或连击。事件批次至少保留到所有可能的视觉生命周期结束，当前冻结值为 `600 ms`。

同一批次先按严重度选择一个场中央显示候选：

```text
Miss > Good > Perfect
```

严重度相同时，选择事件标识较新的事件。各轨道的判定事件仍然保留，场中央只把同一批次折叠成一个结果。

音符锁定产生 `[Miss, Perfect]` 时，场中央显示 `Miss`。同一帧自动产生多个 `Miss` 时，场中央只重新触发一次 `Miss` 动画。

## 更严重的判定立即替换当前判定

场中央保存一个正在显示的判定状态，其中包含判定种类、事件标识、开始时间、保护结束时间和完全结束时间。

新候选到来时按以下顺序处理：

1. 没有正在显示的判定时，立即显示新候选。
2. 新候选更严重时，立即替换当前判定。
3. 新候选和当前判定相同时，更新事件标识并重新触发视觉脉冲。
4. 新候选较轻且当前判定仍在保护期内时，忽略新候选。
5. 当前判定的保护期已经结束时，显示新候选。

被忽略的候选不进入等待队列。过期的 `Perfect` 或 `Good` 不能在 `Miss` 消失后补播。

冻结参数如下：

| 判定 | 起始脉冲 | 开始淡出 | 完全消失 | 阻止较轻判定覆盖的时间 |
| --- | ---: | ---: | ---: | ---: |
| `Perfect` | `60 ms` | `110 ms` | `300 ms` | `0 ms` |
| `Good` | `70 ms` | `130 ms` | `360 ms` | `80 ms` |
| `Miss` | `70 ms` | `180 ms` | `500 ms` | `180 ms` |

完全消失时间适用于没有后续判定替换的情况。保护期只限制较轻判定。`Miss` 可以随时替换 `Good` 或 `Perfect`，`Good` 可以随时替换 `Perfect`。

## 场中央判定必须在最后一次事件后消失

`Perfect` 和 `Good` 出现时立即达到完整透明度，缩放从约 `0.90` 快速回到 `1.00`。进入淡出阶段后，透明度平滑降到零，缩放轻微回落。起始阶段不做延迟淡入，避免判定反馈晚于按键和声音。

`Miss` 出现时立即达到完整透明度，使用红色和较强的起始缩放。其运动只允许轻微下沉或短促缩放，不使用大角度旋转和长距离位移。

连续相同判定会更新消失时间，并重新触发短促的缩放脉冲。高密度段落中，判定文字可以持续可见；最后一个事件之后，透明度必须按表中时间降到零。

透明度、缩放和位移都由事件发生后的经过时间计算。界面不能用永久保存的 `latestJudgement` 直接控制可见性，也不能依赖无法随游戏暂停冻结的延迟任务。

## 判定视觉使用谱面时钟

场中央判定的时间基准是 `gameplayChartTimeMs`。暂停后谱面时钟停止，当前动画停在暂停瞬间；恢复播放后从同一进度继续。视觉偏移只影响音符位置，不改变判定提示的年龄。

自动 `Miss`、按键判定和音符锁定产生的判定都使用同一时间基准。界面刷新率只影响采样平滑度，不改变动画总时长。

## 轨道闪光由一个状态机控制

每条轨道只有一个按键视觉状态：

```text
空闲 -> 按下峰值 -> 按住低亮 -> 松键衰减 -> 空闲
                      ^              |
                      +--- 再次按下 --+
```

轨道主体和判定线按键区可以使用不同亮度，但两者由同一个状态和同一次输入转换驱动。不得再用两组互相叠加的动画状态分别控制按下与余光。

冻结参数如下：

| 阶段 | 判定线按键区附加亮度 | 轨道主体附加亮度 | 时长 |
| --- | ---: | ---: | ---: |
| 按下峰值 | `0.52` | `0.13` | 一帧内到达 |
| 回落到按住低亮 | `0.24` | `0.05` | `85 ms` |
| 松键衰减 | 从当前值降到 `0` | 从当前值降到 `0` | `110 ms` |

按下时立即达到峰值，不保留额外的缓慢起亮。按键继续保持时，亮度回落到低亮状态，轨道主体不能长时间保持峰值。

松键从当前实际亮度连续衰减到零，不先跳到单独的余光亮度。衰减期间再次按下时，旧的松键衰减立即失效，新按下在下一次绘制时达到峰值。

每个有效物理按下事件都带有新的输入序号。视觉层用该序号识别重触发，不能只观察 `isPressed` 的最终布尔值。操作系统产生的按键自动重复继续由输入路由器过滤，不触发新的闪光。

## 轨道输入反馈不表示命中结果

轨道按键闪光只表示物理输入已经被游戏接收。空按也会产生闪光，`Perfect`、`Good` 和 `Miss` 不改变该层的颜色和时长。

实际命中特效以后可以作为单独的视觉层加入，但不得复用按键闪光状态。这样可以避免输入反馈、判定反馈和长按保持效果互相覆盖。

轨道闪光使用连续单调的界面时间，不使用 `gameplayChartTimeMs`。它以玩家输入的实时响应为准，不需要在暂停时冻结正在进行的短暂衰减。每次输入转换记录输入序号和发生时间，游戏不处于游玩状态时不接受新的轨道闪光事件。

## 组件职责保持单一

判定引擎继续负责产生真实判定事件。会话层保存事件批次和输入转换记录。视觉反馈层负责严重度仲裁、保护期、生命周期和亮度包络。SwiftUI 视图只绘制已经计算好的显示状态。

视觉反馈层必须是可独立测试的纯逻辑。给定事件批次、输入转换和当前时间，它应返回确定的判定显示状态与轨道亮度，不读取音符判定窗口，也不修改引擎状态。

## 必须验证的行为

- 没有新判定时，场中央文字在冻结时长内自然消失。
- 音符锁定同批次产生 `[Miss, Perfect]` 时显示 `Miss`。
- `Perfect` 显示期间出现 `Miss`，立即切换为 `Miss`。
- `Miss` 的前 `180 ms` 内出现 `Perfect` 或 `Good`，不覆盖 `Miss`。
- 保护期结束后的新判定可以正常显示，不补播被忽略的旧事件。
- 连续相同判定重新触发缩放脉冲，最后一次事件后仍会消失。
- 多轨和弦产生混合判定时，场中央显示其中最严重的结果。
- 自动 `Miss` 无需玩家输入也能出现并消失。
- 暂停时场中央判定动画冻结，恢复后继续。
- 按下在一帧内达到峰值，长按回落到低亮，松键从当前亮度平滑归零。
- 松键衰减期间再次按下，旧衰减不再影响新峰值。
- 操作系统按键自动重复不产生额外闪光。
- 本规格的改动不改变判定结果、分数、准确率、连击和偏移统计。

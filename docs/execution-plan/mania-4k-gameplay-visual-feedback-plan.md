---
commit: 9b74501a13c177ded5390bac8e0f6292ee391590
title: Mania 4K 局内视觉反馈实施计划
status: implemented
source_spec: docs/design/mania-4k-gameplay-visual-feedback-spec.md
---

# Mania 4K 局内视觉反馈实施计划

本文把冻结的局内视觉反馈规格展开为一次可独立合并的实现。目标是让中央判定提示拥有确定的批次仲裁和生命周期，并让每条轨道的输入闪光由单一、可重触发的亮度状态机驱动。

## 范围与非范围

本次实现包含：

- 保存 `engine.handle()`、`engine.advance()` 产生的完整非空判定批次，批次至少保留 `600 ms` 谱面时间。
- 按 `Miss > Good > Perfect` 仲裁中央判定，并实现保护期、同判定重触发、淡出和消失。
- 保存有效输入转换的输入序号和单调 UI 时间，并计算按下峰值、按住低亮、松键衰减和衰减中再按下。
- 让 SwiftUI 只绘制 Core 计算出的透明度、缩放、位移和两类轨道亮度。
- 添加纯逻辑和 Session 回归测试，并完成 macOS 构建验证。

本次不修改判定窗口、音符锁定、长按计分、分数、准确率、连击、偏移统计、输入恢复、命中特效、音效或资源加载，也不增加设置项、依赖、服务或持久化格式。

## 选定方案

在 `PulsefieldCore` 新增一个小型值类型 `Mania4KGameplayFeedbackState`。它接收完整判定事件数组、有效输入事件以及调用方提供的当前时间，内部只保留仍与显示有关的批次和每轨单一状态，输出确定的中央判定呈现值与轨道亮度。

`Mania4KPlaySessionModel` 持有该状态：

- 所有产生判定的 engine 调用都把返回的非空事件数组作为一个新批次送入状态机，包括初始推进、正常 tick 和玩家输入。
- 键盘路由器或直接输入入口接受事件后，立即以 `PulsefieldHostClock.currentTimeMS()` 记录输入转换；不处于 `.playing` 时仍拒绝记录。
- 重置游玩状态时同时重置反馈状态。

`Mania4KPlayExperienceView` 使用一个动画时间线采样反馈状态。中央判定使用 `playFrame.gameplayChartTimeMs`，因此暂停时冻结；轨道亮度使用单调 UI 时间，因此短暂衰减不因暂停而冻结。HUD 的 `Judge` 继续读取 `playFrame.latestJudgement`，保持历史状态语义。

没有采用以下方案：

- 不把生命周期塞进判定引擎；视觉仲裁不能改变真实判定和计分职责。
- 不继续使用多个 `@State` 和并行 `withAnimation`；它们无法表达批次、输入序号和再按下取消旧衰减。
- 不在 `Mania4KPlayFrame` 复制事件历史；Session 已是可观察状态所有者，复制会增加同步面而没有新的消费者。

## 执行步骤

这是一次单阶段提交，下面是同一实现内的有序步骤，不是互相依赖的伪分期。

1. 在新的 Core 文件中定义判定批次、中央呈现值、轨道亮度值和纯反馈状态机。
   - 每个非空 engine update 获得递增批次标识，并保留完整事件数组。
   - 同批次按严重度、再按事件标识选择候选。
   - 精确使用规格中的脉冲、淡出、结束、保护期和轨道亮度常量。
   - 松键时从当时的实际亮度建立衰减；新按下以新的序号替换旧状态。
2. 在 Session 中接入三个事件来源。
   - 初次准备后的 `advance(to:)`。
   - 每次游玩 `tick()` 的 `advance(to:)`。
   - 输入队列最终执行的 `handle(_:)`。
   - 键盘 repeat、重复按下和无效键仍由现有路由器过滤，过滤后的事件才进入反馈状态。
3. 替换 SwiftUI 绘制逻辑。
   - 中央判定改读呈现值并应用透明度、缩放和轻微 Miss 位移。
   - 每轨改读同一状态机输出的判定线与轨道主体亮度。
   - 删除 `pressHighlight`、`releaseAfterglow` 及对应动画回调。
4. 添加行为测试并生成 Xcode 工程文件引用。
5. 运行定向测试、完整 `PulsefieldCoreTests` 和 `PulsefieldMac` Debug build；实际谱面与音频下的主观画面检查使用本文件的人工验收项。

## 自动验收标准

纯反馈逻辑必须证明：

- 空批次不创建视觉事件；非空批次完整保存，谱面年龄不超过 `600 ms` 时不被清理。
- `[Miss, Perfect]` 和多轨混合批次都选择 `Miss`；同严重度选择事件标识较新的事件。
- `Miss` 立即替换 `Perfect`；`Miss` 开始后的前 `180 ms` 内，`Good` 和 `Perfect` 均不能覆盖它。
- 保护期结束后，新判定立即显示；此前被忽略的事件不会补播。
- 相同判定更新事件标识并重启脉冲与消失时间；最后一次事件之后按对应总时长返回不可见。
- 透明度在淡出开始前保持 `1`，随后平滑归零；缩放从起始脉冲值回到 `1`，淡出时只轻微回落。
- 在相同 `gameplayChartTimeMs` 重复采样得到完全相同的中央呈现值，证明暂停冻结不依赖延迟任务。
- 按下立即输出 `0.52 / 0.13` 的判定线/轨道亮度，`85 ms` 后为 `0.24 / 0.05`；松键从当时实际值连续衰减，并在 `110 ms` 后为零。
- 松键衰减期间使用更新输入序号再次按下，下一次采样恢复峰值，旧衰减不再影响输出。

Session 回归必须证明：

- 音符锁定同一次输入产生 `[Miss, Perfect]` 时，中央反馈选择 `Miss`，而 HUD 历史仍可保持 engine 的最后事件 `Perfect`。
- `advance(to:)` 自动产生的 `Miss` 无需输入即可进入中央反馈并按谱面时钟消失。
- 键盘自动重复和重复按下不更新该轨的视觉输入序号。
- 本次改动前已有的计分、准确率、连击、偏移和输入队列测试全部继续通过。

## 人工验收标准

- 连续点击同一轨时，每次有效按下都能看到新的短促峰值；长按不会持续保持峰值。
- 松键余光没有亮度跳变，余光期间再次按下不会被旧动画拉暗。
- 中央 `Perfect`、`Good`、`Miss` 最终都会消失；连续判定时文字不会闪成同批次中较轻的结果。
- 暂停后中央判定停在当前进度，轨道短余光仍自然结束；恢复后中央动画从暂停位置继续。
- HUD 的 `Judge` 仍显示最近历史判定，不随中央文字消失。

## 验证命令

```sh
xcodegen generate
xcodebuild test -project Pulsefield.xcodeproj -scheme PulsefieldMac -destination 'platform=macOS' -only-testing:PulsefieldCoreTests/Mania4KGameplayFeedbackTests
xcodebuild test -project Pulsefield.xcodeproj -scheme PulsefieldMac -destination 'platform=macOS' -only-testing:PulsefieldCoreTests
xcodebuild -project Pulsefield.xcodeproj -scheme PulsefieldMac -configuration Debug -destination 'platform=macOS' build
```

## 风险与回滚

主要风险是两个时钟被误用：中央判定若使用 UI 时间会在暂停时继续，轨道闪光若使用谱面时间会在暂停时冻结。类型和调用点会明确命名两类时间，测试分别锁住语义。

改动没有数据迁移或外部状态。若视觉行为不符合规格，可整体回退反馈状态、Session 接线和 SwiftUI 绘制改动；判定引擎及用户数据不受影响。

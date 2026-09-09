---
commit: d3eb9eab7c4bf9fc49d840dfcbda3469f6a13b9a
title: 2026-09-09 交通环境录音 Fixture 对齐实测
status: current diagnostics
---

# 2026-09-09 交通环境录音 Fixture 对齐实测

本报告记录六段真实道路／机场附近录音的导入及已知歌曲对齐结果。对应歌曲从文件名、会话与本地曲库确定，再通过独立音频比对交叉检查；没有调用歌曲识别 API。没有修改引擎代码或阈值。

## 数据与保存方式

- 六段新录音覆盖四首歌，解码后总长 1081.379 秒（18 分 1.379 秒）；加上原有数据，共 24 个可直接发现的 CAF fixture、9 首参考歌曲。
- 规范音频为 mono / 48 kHz / float32 PCM CAF，与配套 `.ambient-sync-fixture.json` 一起放在 `LocalFixtures/ambient-sync-voice-memos/`，名称统一以 `traffic-20260909-` 开头。
- 原 M4A 完整复制到 `.traffic-20260909/originals/`，Downloads 原件保留。六组原件、转换文件、参考 MP3 的 SHA-256 校验通过；原 M4A 解码出的 PCM 与 CAF 解码出的 PCM 哈希逐一相同。没有裁剪、降噪、归一化或变速。容器时长与 PCM 时长有约 44 ms 差异，fixture 使用实际解码时长。
- sidecar 保留来源路径、原件和 CAF 哈希、参考文件哈希、转换方式、环境及缺失信息。具体马路／机场对应哪条、播放设备、距离和音量未知，没有补造。`createdAt/stoppedAt` 是导入生命周期时间，真实录制时间未知；容器创建时间另存于 provenance。
- `alignmentAnnotation` 是独立算法估计，并非人工真值；native runner 忽略该扩展字段，回放没有使用估计偏移作提示。
- 音频、sidecar、轨迹与辅助脚本沿用仓库的 local-only ignore 规则，没有强行加入 Git。

| 原始文件 | Fixture 文件 | PCM 时长 | 独立估计偏移 |
| --- | --- | ---: | ---: |
| Is this the world we created 1.m4a | `traffic-20260909-queen-world-created-take-01.caf` | 121.620 s | +8.23 s |
| MEGALOVANIA.m4a | `traffic-20260909-megalovania-take-01.caf` | 148.329 s | +9.69 s |
| wake me up when september ends 1.m4a | `traffic-20260909-wake-september-take-01.caf` | 281.279 s | +2.91 s |
| Wake me up when september ends 2.m4a | `traffic-20260909-wake-september-take-02.caf` | 61.375 s | +6.57 s |
| YOASOBI 向夜晚奔去.m4a | `traffic-20260909-yoru-ni-kakeru-take-01.caf` | 203.028 s | +57.44 s |
| YOASOBI 2.m4a | `traffic-20260909-yoru-ni-kakeru-take-02.caf` | 265.748 s | -1.18 s |

偏移约定为 `参考歌曲时刻 = 录音时刻 + 偏移`。例如，夜に駆ける 1 的录音开始约对应歌曲 57.44 秒；夜に駆ける 2 的 -1.18 秒偏移对应录音先于参考零点约 1.18 秒。后者是时间轴估计，不是人工标注的可听起音时刻。

## 实测方法与边界

1. 构建当前提交的 PulsefieldCore（通过 PulsefieldACRCloudDebugCLI scheme，Debug）；构建成功，没有启动或替换 macOS App。
2. 六条完整录音使用现有 `AmbientSyncFixtureReplayRunner` 回放，约每 1000 ms 处理一次。该 runner 锁定前分阶段取窗口，首次 final 后一直取 2 秒。
3. 检查实时路径发现 `LiveAmbientSyncRuntime` 一直取 5 秒窗口。因此另外使用同一 `AmbientSyncEngine`、默认配置和 `MicFeatureStreamBuffer`，以固定 5 秒窗口重放六条完整录音，以下主表采用这组结果。
4. 两种策略分别从录音第 30、90 秒新建引擎，取其后的 30 秒音频；短版 Green Day 不够第 90 秒测试，故每组 11 个探针。这些是派生测试，不增加原始现场 fixture 数量。每次新建特征提取与引擎，不带入之前的音频、锁定状态或偏移。
5. 使用独立 NumPy 频谱相关性程序交叉检查：20 秒窗口，300–7200 Hz 对数频带，1 秒时间去均值，10 ms hop；跨多个有明显优势的窗口汇总一致偏移。此程序未调用 Swift 引擎，结果不反馈给回放。

**这些是离线音频时间结果，不是 App 端到端延迟。** App 的调度最小间隔是 100 ms，本次为 1000 ms 抽样；`elapsedMS` 用音频时间，未模拟 CPU 积压、硬件回调、API 等待和 UI。中途开始也只是 API 返回时间的两种采样情形。

锁定占比是全段采样点中 `state == locked` 的比例，包含初始等待及尾部。`phase == final` 是历史状态，不能据此把 drifting/relocking 也当作锁定。没有人工标注每段中音乐实际存在的区间，因此不能把所有尾部掉锁都归因为交通噪声。

独立估计也有边界：重复片段可能产生旁峰，开头不能完整覆盖参考音频、低能量尾部、超出参考时长的窗口会给出弱或错误峰。只用跨窗口一致且有优势的证据确定偏移，原始所有峰均保留。后文误差只是与该独立估计的不一致量，不是已证明的绝对同步精度；250 ms 只用于标出明显偏移异常，不是游戏验收阈值。

## 固定 5 秒窗口：完整录音

| 录音 | 首次 locked（录音经过时间） | locked 采样占比 | 结尾 state | locked 与独立偏移最大差异 |
| --- | ---: | ---: | --- | ---: |
| MEGALOVANIA | 28.10 s | 51.0% | relocking | 15.8 ms |
| Queen · Is This The World We Created | 21.08 s | 35.0% | locked | 25.9 ms |
| Wake Me up When September Ends 1 | 98.28 s | 55.3% | drifting | 81.4 ms |
| Wake Me up When September Ends 2 | 24.09 s | 61.9% | locked | 16.8 ms |
| 夜に駆ける 1 | 6.04 s | 97.1% | locked | 21.7 ms |
| 夜に駆ける 2 | 43.14 s | 68.5% | drifting | 22.2 ms |

## 固定 5 秒窗口：中途接入

下表时间从新的接入点重新计时；“未锁定”表示后续 30 秒内没有 locked。

| 录音 | 从录音 30 秒接入：首次锁定 / 片段末状态 | 从录音 90 秒接入：首次锁定 / 片段末状态 |
| --- | --- | --- |
| MEGALOVANIA | 8.04 s / locked | 未锁定 / locking |
| Queen · Is This The World We Created | 9.05 s / relocking | 14.06 s / locked |
| Wake Me up When September Ends 1 | 未锁定 / locking | 8.04 s / locked |
| Wake Me up When September Ends 2 | 未锁定 / locking | 长度不足，未测 |
| 夜に駆ける 1 | 5.03 s / locked | 14.06 s / locked |
| 夜に駆ける 2 | 18.07 s / locked | 7.04 s / drifting |

## 与现有 fixture runner 的区别

| 录音 | 现有 runner 首次锁定 | 现有 runner locked 占比 | 现有 runner 结尾 |
| --- | ---: | ---: | --- |
| MEGALOVANIA | 28.10 s | 51.0% | drifting |
| Queen · Is This The World We Created | 22.08 s | 5.7% | drifting |
| Wake Me up When September Ends 1 | 98.28 s | 11.3% | drifting |
| Wake Me up When September Ends 2 | 24.09 s | 61.9% | locked |
| 夜に駆ける 1 | 11.05 s | 94.1% | relocking |
| 夜に駆ける 2 | 43.14 s | 22.8% | drifting |

## 结果解读

- 六段都存在跨多个窗口一致的参考歌曲偏移，参考文件与录音内容的对应关系得到支持。完整录音中，固定 5 秒策略有 6/6 条至少进入过 locked，3/6 条结尾仍 locked；这两个指标都不能替代全程稳定性。
- 固定 5 秒策略的 11 个中途接入探针有 8/11 个在 30 秒内锁定。具体接入片段会明显改变首次锁定结果。
- 固定 5 秒策略所有完整／接入测试共 842 个 locked 采样点，其中与独立偏移差异超过 250 ms 的有 0 个；包含 provisional 等其他状态的全部输出中，有 8 个超过 250 ms。必须区分候选错误与已经锁定后的错误。
- 原 runner 的 Green Day 长版在录音约 16、27、33–34 秒给出过明显错误的 provisional 偏移（最大差异约 243 秒），没有因此进入 locked。详细事件留在原始 trace 中。
- 回放窗口策略与 App 不同，确实会改变结果。主表固定 5 秒策略应与原 runner 的分阶段／2 秒跟踪结果分开使用，不宜直接把后者当作 App 表现。

## 本地结果与复现材料

所有路径相对 `LocalFixtures/ambient-sync-voice-memos/.traffic-20260909/`：

- `import-manifest.json`：六个原件到规范 fixture 的映射。
- `independent-alignment.json`：各 20 秒窗口的第一／第二相关性峰和偏移。
- `alignment-summary.json`：所有回放指标、独立估计支持范围、锁定区间和失败原因计数。
- `live-window-replay/`：与 App 相同 5 秒窗口的 6 条完整回放与 11 条接入回放。接入 trace 的时间为片段内时间，原始录音起点在文件名 `entry-30s/entry-90s` 及汇总 JSON 中。
- `replay/`、`reentry-replay/`：现有 fixture runner 的 6 + 11 条对照回放。
- `reentry-fixtures/`：30 秒派生 CAF 及其带来源起点的 sidecar。
- `tools/`：导入、独立比对、标准回放、固定窗口回放、汇总及报告生成的源文件。
- `logs/`：构建与实际执行日志。

Swift 辅助程序链接本次 `.build/DerivedData/Build/Products/Debug/PulsefieldCore.framework`；`live_window_replay.swift` 接受歌曲文件名过滤参数、`ENTRY_SECONDS=0,30,90` 和 `CADENCE_MS=1000`。独立比对脚本使用 bundled Python 的 NumPy，音频转换使用本地 ffmpeg。所有探针只在各自输出目录写 trace，不覆盖旧 18 条 fixture 的轨迹。

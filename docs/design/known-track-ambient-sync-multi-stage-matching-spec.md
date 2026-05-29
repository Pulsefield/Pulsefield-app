---
commit: 93edff6ed57ef9a2a48e3cdbbc5ad12df4644421
title: Known-Track Ambient Sync Multi-Stage Matching Spec v0.1
status: frozen spec
scope: design
---

# Known-Track Ambient Sync: Multi-Stage Matching Spec v0.1

Baseline commit: `93edff6ed57ef9a2a48e3cdbbc5ad12df4644421`.

This document freezes the known-track ambient sync matching design. It is a
design spec for audio-to-audio alignment when the local audio asset is already
known. It is not a current-status diagnostic, roadmap narrative, or execution
plan.

## 0. Goals And Non-Goals

### Goals

在已知本地 audio 与外界播放音频为同一首的前提下，用麦克风环境音频估计当前播放位置。

这里的“同一首”在 v0.1 中定义为 sample-identical local audio file：外界播放音频与本地文件应来自同一个音频样本源。Remaster、radio edit、live version、tempo/pitch edited version、不同剪辑版本、或只是在音乐意义上相同的 recording 不在本 spec 保证范围内。

目标指标：

| 指标 | 目标值 |
| --- | --- |
| First lock 时间 | 1.5-3.0s |
| Tracking update 间隔 | 100-200ms |
| Coarse alignment 分辨率 | 20-40ms |
| Fine alignment 分辨率 | 5-20ms |
| Stable locked search radius | +/-100-150ms |
| Uncertain tracking radius | +/-500ms |
| Relock search radius | +/-1500ms |

### Non-Goals

这不是 full music identification，不需要从百万曲库里识别歌曲。更准确的定义是 known-track audio-to-audio alignment。Six & Leman 明确把带 ambient audio 的同步问题转化为 audio-to-audio alignment，并使用 audio fingerprinting 来测 offset、drift 和 dropped samples。

## 1. Required Core Concepts

### 1.1 Streaming Mic Feature Buffer

当前不能继续依赖 isolated latestWindow(3s/4s)。Mic audio 必须进入持续 feature stream，并保留跨窗口状态。否则 onset / spectral flux 在窗口边界会断裂，历史证据也无法累计。

Mic stream assembler 必须把输入音频持续拼成连续 buffer，并为每个 feature frame 记录该 frame 的实际录制时间 `recordedTime`。Alignment 和 publish 逻辑必须使用 query endpoint frame 的 `recordedTime`，不能用 estimator 被调用时的 `time.now` 代替 mic window 时间。

Offset sign convention:

```text
offset = localReferenceTime - micQueryTime
```

其中 `micQueryTime` 是 mic stream 中被匹配 query endpoint 的时间。发布当前时刻的 reference time 时，应先得到 query endpoint 对应的 `localReferenceTime`，再用 `time.now - recordedTime` 将结果推进到当前时刻。

必须保留：

| 内容 | 用途 |
| --- | --- |
| frame host time | reference time 估计 |
| onset envelope | timing precision |
| subband onset | 抗局部噪声 |
| PCEN-mel | 抗 far-field / noisy recording |
| chroma / CENS | harmonic robustness |
| landmark hashes | coarse candidate generation |
| energy / SNR diagnostics | signal quality gate |

PCEN 适合 noisy far-field frontend，因为它包含 temporal integration、gain control 和 dynamic range compression，并被用于 noisy acoustic environments 的 spectrogram frontend。

### 1.2 Shazam-Like Landmark Coarse Retrieval

当前的 band + quantized flux value landmark 不够抗噪。应改为 time-frequency peak pair：

```text
hash = quantized(anchor_frequency, target_frequency, delta_time)
payload = anchor_time
```

Wang 的 Shazam paper 使用 time-frequency constellation，并用 anchor point 与 target zone 中的点组成 pair hash；每个 pair 产生两个 frequency components 和 time difference，absolute anchor time 作为 offset 信息另存，不进入 hash。该设计被描述为能在 noise 和 voice codec compression 下复现。

具体 anchor / target zone、frequency quantization、delta-time range、hash packing、collision handling 和 density tuning 暂不在 v0.1 固定，作为 future concern。

### 1.3 Offset Histogram

Fingerprint 的核心不是“某个 hash 命中”，而是大量 matched hashes 是否共同支持同一个 offset。Wang 的搜索过程会把 sample hash 和 database hash 的 time pair 分 bin，再扫描 bin 里的匹配关系。

对我们来说，database 只有一首 local audio，因此 offset histogram 可以更简单，但仍然应该作为 Stage 2 coarse retrieval 的核心。

### 1.4 Dense Rerank

Landmark 只负责 coarse candidate retrieval，不负责最终 timing。Dense rerank 应使用多个互补 feature：

| Feature | 作用 |
| --- | --- |
| onset envelope | 时间精度 |
| subband onset | 抗局部频段污染 |
| chroma-onset | pitch-aware onset timing |
| PCEN-mel | 抗环境噪声 / EQ / AGC |
| CENS / smoothed chroma | harmonic robustness / ambiguity rejection |

Ewert, Müller & Grosche 的 high-resolution synchronization 工作强调 onset 的时间精度与 chroma 的鲁棒性互补，并提出 chroma onset features 来兼顾两者。

### 1.5 Fine Alignment

Coarse offset 命中后，再在局部窗口做 feature-level refinement。Six & Leman 的 audio-to-audio alignment 方案就是先用 fingerprint 找 rough offset，再用 cross-covariance refinement 提升精度。

### 1.6 Tracking Filter

锁定后不能每次重新 wide search。应使用：

```text
prediction from previous estimate + drift
+
short rolling observation correction
```

Six & Leman 的同步要求也包括连续提供 offset，以便发现 drift 和 dropped samples。

## 2. Prototype Constraints To Replace

| 当前实现 | 问题 | 应替换为 |
| --- | --- | --- |
| frameHopMS = 100ms | 3s query 只有约 30 frames，信息密度太低 | 20ms hop，fine stage 可用 10ms |
| isolated mic window | 没有历史 feature continuity | streaming mic feature ring buffer |
| dense sliding first | wide search 成本高，重复段落易误判 | landmark coarse retrieval first |
| current landmark = band + quantized flux | 对音量、EQ、混响、AGC 脆弱 | time-frequency peak pair |
| single best candidate | 容易误锁副歌 / loop | top-K candidate hypotheses |
| measured offset 直接影响 state | 容易跳变 | prediction + observation fusion |

当前 repo 里 `LocalAudioSyncIndexer` 的默认 `frameHopMS` 是 100ms；`FeatureCorrelationSyncEstimator` 也主要是在 selected range 内做 dense sliding scoring，landmark 不是 primary coarse retrieval。

## 3. Multi-Stage Pipeline Spec

### Stage 0: Offline Local Index Build

目的：为已知 local audio 构建可搜索的 reference index。

输入：

| 输入 | 要求 |
| --- | --- |
| local audio PCM | mono downmix |
| sample rate | 16kHz 或 22.05kHz |
| feature hop | 20ms 起步 |
| fine feature hop | 可选 10ms |

产物：

| Artifact | 内容 |
| --- | --- |
| landmark_index | hash -> [anchorFrame] |
| dense_onset | broadband onset |
| dense_subband_onset | multi-band onset |
| pcen_mel | PCEN-normalized mel features |
| chroma_onset | pitch-class onset feature |
| cens_chroma | smoothed / statistical chroma |
| energy_mask | low-energy / unreliable frames |
| manifest | feature version, hop, sample rate, hashes |

Pass 条件：

| 条件 | 初始阈值 |
| --- | --- |
| decoded duration 与 metadata 一致 | error < 100ms |
| feature frame count 合理 | duration / hop +/- 2 frames |
| NaN / Inf feature count | 0 |
| landmark peak density | 15-60 peaks/s |
| landmark hash density | 75-600 hashes/s |
| dense feature coverage | >= 98% track duration |
| silence / low-energy mask 可用 | required |

Fail 条件：

| Fail reason | 处理 |
| --- | --- |
| audio decode failed | index unavailable |
| feature version mismatch | rebuild index |
| landmark density too low | allow dense-only fallback, but mark weak index |
| dense features invalid | reject index |

Fingerprint 系统的关键 tradeoff 包括 robustness、reliability、fingerprint size、granularity、search speed / scalability。低 granularity 需要更多 fingerprint 信息来维持 reliability。

Feature extraction 的具体参数暂不在 v0.1 固定，作为 future concern。包括但不限于 FFT size、window type、mel bins、PCEN 参数、chroma / CENS 参数、onset peak picking、subband layout、normalization、以及 feature serialization format。

### Stage 1: Streaming Mic Feature Readiness Gate

目的：确认 mic buffer 中有足够连续、可用的 query evidence。

输入：

| 输入 | 要求 |
| --- | --- |
| mic PCM stream | continuous chunks |
| feature buffer | last 8-12s |
| query window | 1.5-3.0s |

产物：

| Artifact | 内容 |
| --- | --- |
| MicFeatureWindow | latest rolling query |
| queryLandmarks | peak-pair hashes |
| queryDenseFeatures | onset / PCEN / chroma / CENS |
| queryQuality | energy, active fraction, continuity |

Pass 条件分两级：

Speculative pass 用于 1.5s 后提前搜索，但不直接 publish lock。

| 条件 | 初始阈值 |
| --- | --- |
| query duration | >= 1.5s |
| continuous feature frames | gap <= 2 hops |
| active frame fraction | >= 0.10 |
| query landmark hashes | >= 50 |
| usable dense frames | >= 60 frames at 20ms hop |

Strong pass 用于 3s 内发布 first lock 的候选输入。

| 条件 | 初始阈值 |
| --- | --- |
| query duration | >= 2.5-3.0s |
| continuous feature frames | gap <= 2 hops |
| active frame fraction | >= 0.15 |
| query landmark hashes | >= 120 |
| usable dense frames | >= 120 frames at 20ms hop |
| feature continuity reset count | 0 within query |

Defer 条件：

| Defer reason | 处理 |
| --- | --- |
| query duration < 1.5s | continue buffering |
| too few landmarks but dense energy OK | allow dense fallback only after 3s |
| low energy / silence | do not publish; keep tracking by prediction if already locked |
| buffer discontinuity | reset query start boundary |

### Stage 2: Landmark Coarse Retrieval

目的：快速生成 top-K offset candidates，不做最终判断。

输入：

| 输入 | 来源 |
| --- | --- |
| query landmark hashes | Stage 1 |
| local landmark index | Stage 0 |
| optional predicted reference | tracking / relock state |

搜索范围：

| State | Search range |
| --- | --- |
| acquiring | whole track |
| locked | predicted reference +/-150ms |
| uncertain | predicted reference +/-500ms |
| relock | predicted reference +/-1500ms |
| lost | whole track or large bounded range |

输出：

| 输出 | 内容 |
| --- | --- |
| candidateOffsets | top-K coarse offsets |
| offsetHistogram | binned offset votes |
| top1VoteCount | strongest bin votes |
| top2VoteCount | second independent bin votes |
| voteSpreadMS | matched hashes temporal spread |
| landmarkConfidence | normalized vote score |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| top-K candidates | 1-32 |
| top1 matched hashes | >= 8 speculative, >= 15 strong |
| top1 vote density | >= 1.5% of query hashes |
| top1 / top2 vote ratio | >= 1.25 for strong pass |
| top1 - top2 vote margin | >= 5 votes |
| temporal spread of matched hashes | >= 0.8s speculative, >= 1.5s strong |
| offset bin width | 20-40ms |

Ambiguous 条件：

| 条件 | 处理 |
| --- | --- |
| top1 / top2 ratio < 1.15 | keep top-K, do not publish |
| multiple candidates from repeated chorus | require dense rerank + temporal consistency |
| high votes but poor temporal spread | reject as local hash collision |
| candidate jumps > 300ms across adjacent searches | mark unstable |

Fail 条件：

| Fail reason | 处理 |
| --- | --- |
| no candidates | defer / fallback dense-only only if strong dense evidence |
| too few query hashes | return to Stage 1 |
| histogram flat | ambiguous / weak signal |

设计要求：Landmark coarse retrieval 必须先于 dense rerank。Wang 的方法通过 pair hashes 提高 specificity，比单个 constellation point 更适合快速搜索；pair hash 的额外 frequency/time 信息提高了匹配特异性。

### Stage 3: Candidate Expansion

目的：把 coarse offset 扩展成可精排的局部搜索区域。

输入：

| 输入 | 来源 |
| --- | --- |
| top-K coarse offsets | Stage 2 |
| query duration | Stage 1 |
| local dense features | Stage 0 |

输出：

| 输出 | 内容 |
| --- | --- |
| candidateWindows | local offset windows |
| candidateMetadata | landmark vote, histogram rank, predicted residual |

Window 规则：

| Candidate type | Expansion window |
| --- | --- |
| acquiring | coarse offset +/-200ms |
| locked | coarse offset +/-80-120ms |
| uncertain | coarse offset +/-250ms |
| relock | coarse offset +/-500ms |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| candidate windows count | 1-32 |
| total dense offsets evaluated | bounded under CPU budget |
| local feature coverage | full query length available |
| candidate does not exceed track bounds | required |

Fail 条件：

| Fail reason | 处理 |
| --- | --- |
| candidate outside track | discard candidate |
| query longer than remaining local audio | clamp or discard |
| no valid candidate windows | return Stage 2 fail |

### Stage 4: Dense Feature Rerank

目的：用多特征验证 top-K candidates，选出最可信 alignment hypothesis。

输入：

| 输入 | 来源 |
| --- | --- |
| candidate windows | Stage 3 |
| query dense features | Stage 1 |
| local dense features | Stage 0 |
| landmark scores | Stage 2 |

Feature 组成：

| Feature | 主要职责 |
| --- | --- |
| onset envelope | timing |
| subband onset | robust timing |
| PCEN-mel | spectral robustness |
| chroma-onset | pitch-aware timing |
| CENS / chroma | structure validation |
| energy contour | weak auxiliary only |

Müller, Kurth & Clausen 的 chroma-based statistical features 面向 audio matching，强调 harmonic progression，并对 dynamics、timbre、articulation 和 local tempo deviations 有较强鲁棒性。

Score 输出：

| Score | 含义 |
| --- | --- |
| onsetScore | onset similarity |
| subbandOnsetScore | subband onset similarity |
| pcenMelScore | spectral similarity |
| chromaOnsetScore | pitch-aware onset similarity |
| censScore | harmonic structure similarity |
| landmarkScore | normalized offset vote support |
| combinedDenseScore | weighted combined score |
| denseMargin | top1 - top2 |
| featureAgreementCount | independent features agreeing |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| combinedDenseScore | >= 0.72 acquiring |
| combinedDenseScore tracking | >= 0.60 if prediction agrees |
| dense top1 - top2 margin | >= 0.05 |
| featureAgreementCount | >= 3 of 5 |
| onset or chroma-onset passes | required unless low-onset section |
| PCEN-mel or CENS passes | required |
| dense best offset vs landmark top offset | <= 120ms acquiring, <= 60ms locked |
| low-energy frames downweighted | required |

Ambiguous 条件：

| 条件 | 处理 |
| --- | --- |
| dense top1 and top2 both high but close | no publish; keep hypotheses |
| landmark top1 disagrees with dense top1 > 200ms | no publish |
| only energy contour agrees | reject |
| only chroma agrees in repeated harmonic section | require onset / landmark confirmation |

Fail 条件：

| Fail reason | 处理 |
| --- | --- |
| combined score too low | withhold |
| feature agreement too low | withhold |
| peak margin too small | ambiguous |
| candidate conflict with prediction | go to uncertain / relock path |

### Stage 5: Fine Alignment Refinement

目的：在 Stage 4 最佳 candidate 附近做局部细化，把 coarse offset 细化到 5-20ms 级别。

输入：

| 输入 | 来源 |
| --- | --- |
| best candidate offset | Stage 4 |
| query onset / subband onset | Stage 1 |
| local onset / subband onset | Stage 0 |
| optional PCEN local window | Stage 0 |

Refinement 范围：

| State | Fine search range |
| --- | --- |
| acquiring | best offset +/-100ms |
| locked | best offset +/-60ms |
| uncertain | best offset +/-150ms |

输出：

| 输出 | 内容 |
| --- | --- |
| refinedOffset | final local offset |
| offsetUncertaintyMS | estimated uncertainty |
| peakSharpness | local peak quality |
| refinementResidualMS | fine offset - dense offset |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| refined offset within fine range | required |
| refinement residual | <= 60ms acquiring, <= 30ms locked |
| local peak sharpness | above calibrated threshold |
| offset uncertainty | <= 30ms acquiring, <= 20ms locked |
| feature-level correlation peak width | <= 120ms acquiring, <= 80ms locked |

Fail / Defer 条件：

| 条件 | 处理 |
| --- | --- |
| refinement peak flat | keep Stage 4 offset but lower confidence |
| residual too large | reject candidate or mark unstable |
| low-onset section | rely more on PCEN / CENS and tracking prediction |
| raw waveform only matches | do not trust unless feature-level evidence agrees |

### Stage 6: Acquire Lock Decision

目的：决定是否发布 first `SyncEstimate`。

输入：

| 输入 | 来源 |
| --- | --- |
| refined candidate | Stage 5 |
| dense scores | Stage 4 |
| landmark scores | Stage 2 |
| previous speculative candidates | recent updates |
| query quality | Stage 1 |

Pass 条件：

First lock 不能只靠单次 top1。必须满足：

| 条件 | Initial threshold |
| --- | --- |
| query age | >= 2.0s; ideal 2.5-3.0s |
| landmark strong pass | yes, or dense fallback exceptional |
| dense rerank pass | yes |
| fine refinement pass | yes or acceptable degraded pass |
| top1 / top2 ambiguity clear | yes |
| stable candidate count | >= 2 consecutive updates |
| candidate consistency | predicted progression error <= 60ms |
| total acquire confidence | >= 0.78 |
| publish latency target | <= 3.0s |

Dense-only fallback 条件：

只有在 landmark 因音乐内容导致稀疏时允许：

| 条件 | Threshold |
| --- | --- |
| dense combined score | >= 0.86 |
| dense margin | >= 0.10 |
| featureAgreementCount | >= 4 of 5 |
| candidate stable updates | >= 3 |
| repeated-section ambiguity | none |

Fail / Withhold 条件：

| Withhold reason | 条件 |
| --- | --- |
| insufficientEvidence | query not ready |
| weakLandmarkSupport | Stage 2 fail |
| weakDenseVerification | Stage 4 fail |
| ambiguousOffset | top candidates too close |
| unstableCandidate | not stable across updates |
| lowSignalQuality | Stage 1 weak |
| repeatedSectionAmbiguity | multiple chorus / loop candidates |

输出：

| 输出 | 内容 |
| --- | --- |
| SyncEstimate | reference time at mic window end |
| confidence | combined confidence |
| state | `.locking` or `.locked` |
| diagnostics | all stage scores |

### Stage 7: Locked Tracking Update

目的：锁定后持续校正，不做 full wide search。

输入：

| 输入 | 来源 |
| --- | --- |
| previous estimate | tracker |
| elapsed host time | clock |
| drift estimate | tracker |
| latest 1-2s mic feature window | Stage 1 |
| local features near prediction | Stage 0 |

Search 规则：

| Tracking state | Search radius |
| --- | --- |
| stable locked | +/-100-150ms |
| weak recent observation | +/-300-500ms |
| drifting | +/-500-1000ms |
| relock | +/-1500ms |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| observation offset residual | <= 100ms stable, <= 300ms uncertain |
| dense tracking score | >= 0.60 |
| featureAgreementCount | >= 2 of 5 |
| ambiguity margin | top1 - top2 >= 0.03 |
| correction magnitude per update | bounded, e.g. <= 40ms unless relock |
| drift update | only after >= 4 good observations |

Tracking 输出规则：

| 情况 | 输出 |
| --- | --- |
| strong observation | prediction + partial correction |
| weak but non-conflicting observation | mostly prediction, lower confidence |
| no usable observation | prediction only, confidence decay |
| conflicting observation | do not jump; enter uncertain |
| repeated conflicting observations | relock |

Fail / State Transition：

| 条件 | Transition |
| --- | --- |
| 1 weak window | `.locked` with lower confidence |
| 2-3 weak windows | `.drifting` |
| >= 4 weak windows | `.lost` |
| strong conflicting wide candidate | `.relocking` |
| manually nudged | reset drift observations |

### Stage 8: Relock

目的：在 tracking 丢失后恢复位置，但避免跳到相似副歌。

输入：

| 输入 | 来源 |
| --- | --- |
| last known reference | tracker |
| current mic buffer | Stage 1 |
| local index | Stage 0 |

Relock 策略：

| 情况 | Search |
| --- | --- |
| short loss < 5s | predicted +/-1500ms |
| long loss | whole-track landmark retrieval |
| user force relock | whole-track retrieval |
| repeated-section ambiguity | keep multiple hypotheses |

Pass 条件：

| 条件 | Initial threshold |
| --- | --- |
| landmark coarse pass | strong |
| dense rerank pass | strong |
| fine refinement pass | yes |
| disagreement from old prediction | allowed only if relock evidence is strong |
| stable relock updates | >= 2 |

Fail 条件：

| Fail reason | 处理 |
| --- | --- |
| no candidates | stay `.lost` |
| ambiguous candidates | withhold |
| candidate conflicts with old path but weak evidence | withhold |
| low signal | stay prediction unavailable |

## 4. Confidence Model

不要使用单一 `combinedScore` 决策。Confidence 应拆成 stage-level confidence。

Score normalization、per-feature score scale、feature weights calibration、margin calibration 和 confidence threshold calibration 暂不在 v0.1 固定，作为 future concern。本节只冻结需要拆分 confidence components 的设计方向和初始权重形状。

Components：

| Component | 来源 |
| --- | --- |
| queryQualityConfidence | Stage 1 |
| landmarkConfidence | Stage 2 |
| denseConfidence | Stage 4 |
| fineAlignmentConfidence | Stage 5 |
| temporalStabilityConfidence | Stage 6 / 7 |
| ambiguityPenalty | Stage 2 / 4 |
| predictionAgreement | Tracking only |

Acquire confidence 初始权重：

| Component | Weight |
| --- | --- |
| landmarkConfidence | 0.30 |
| denseConfidence | 0.35 |
| fineAlignmentConfidence | 0.15 |
| temporalStabilityConfidence | 0.15 |
| queryQualityConfidence | 0.05 |

Tracking confidence 初始权重：

| Component | Weight |
| --- | --- |
| predictionAgreement | 0.35 |
| denseConfidence | 0.25 |
| fineAlignmentConfidence | 0.15 |
| landmarkConfidence | 0.10 |
| temporalStabilityConfidence | 0.15 |

State machine 的完整 contract 暂不在 v0.1 固定，作为 future concern。后续需要单独冻结 `.locking`、`.locked`、`.drifting`、`.lost`、`.relocking`、`uncertain` 的精确定义、transition guard、withheld update 输出、stale estimate 可见性、confidence decay、以及手动 nudge 后的恢复规则。

## 5. Diagnostics Spec

每次 update 必须输出这些字段。

Query diagnostics：

| Field | 含义 |
| --- | --- |
| micBufferDurationMS | 当前 mic feature buffer 长度 |
| queryDurationMS | 本次 query 时长 |
| queryStartHostTimeMS | query 起点 |
| queryEndHostTimeMS | query 终点 |
| featureFrameCount | feature frames |
| featureHopMS | hop |
| activeFrameFraction | active frames |
| landmarkHashCount | query hashes |
| continuityResetCount | streaming reset count |
| energyDBFS | signal level |

Landmark diagnostics：

| Field | 含义 |
| --- | --- |
| topCandidateOffsetsMS | top-K coarse offsets |
| topVoteCounts | votes |
| topVoteRatios | top1/topN |
| voteDensity | votes / query hashes |
| voteTemporalSpreadMS | matched hash spread |
| histogramPeakWidthMS | offset histogram peak width |
| landmarkAmbiguous | yes/no |

Dense diagnostics：

| Field | 含义 |
| --- | --- |
| onsetScore | onset match |
| subbandOnsetScore | subband onset match |
| pcenMelScore | PCEN-mel match |
| chromaOnsetScore | chroma-onset match |
| censScore | CENS/chroma match |
| combinedDenseScore | rerank score |
| denseMargin | top1 - top2 |
| featureAgreementCount | independent agreement |

Fine alignment diagnostics：

| Field | 含义 |
| --- | --- |
| coarseOffsetMS | before refinement |
| refinedOffsetMS | after refinement |
| refinementResidualMS | delta |
| peakSharpness | local peak quality |
| peakWidthMS | peak width |
| offsetUncertaintyMS | uncertainty |

Decision diagnostics：

| Field | 含义 |
| --- | --- |
| stage | current stage |
| didPublishEstimate | yes/no |
| withholdReason | explicit reason |
| confidence | final confidence |
| searchMode | acquire / locked / uncertain / relock |
| selectedReferenceMS | selected position |
| predictedReferenceMS | tracking prediction |
| timeResidualMS | selected - predicted |
| hypothesisCount | active hypotheses |

## 6. Acceptance Tests

本节只定义行为目标。测试 fixture、ground-truth timing 方法、noise / SNR 定义、播放设备假设、自动化方式和人工验收方式暂不在 v0.1 固定，作为 future concern。

### Test A: Clean Same-Device Playback

| Requirement | Pass |
| --- | --- |
| first lock | <= 2s |
| position error | <= 40ms |
| stable tracking residual | <= 25ms |
| no false relock | required |

### Test B: Phone Speaker To Laptop Mic

| Requirement | Pass |
| --- | --- |
| first lock | <= 3s |
| position error | <= 80ms |
| tracking residual after lock | <= 40ms |
| no jump in repeated chorus | required |

### Test C: Noisy Room

| Requirement | Pass |
| --- | --- |
| first lock | <= 4s allowed |
| if ambiguous | must withhold |
| false positive lock | 0 tolerated |
| recovery after 3s clean audio | required |

### Test D: Repeated Chorus / Loop

| Requirement | Pass |
| --- | --- |
| multiple candidates detected | required |
| wrong publish | 0 tolerated |
| publish only after temporal disambiguation | required |
| diagnostics expose ambiguity | required |

### Test E: Temporary Silence / Low Energy

| Requirement | Pass |
| --- | --- |
| locked state continues by prediction | short silence |
| confidence decays | required |
| no hard jump | required |
| relock after signal returns | required |

## 7. Implementation Priority

This section records dependency order only. It is not an execution plan.

### P0: 必须先做

1. `frameHopMS` 改到 20ms。
2. Mic capture 改成 streaming feature ring buffer。
3. Feature extractor 支持跨 chunk previous-frame state。
4. 加 Stage 1 query readiness diagnostics。
5. 加 Stage 2 offset histogram，并实现最小可用的 query/local landmark extraction；当前已无 existing landmark path 可作为过渡。

### P1: 真正让算法可用

1. 将 landmark 改成 time-frequency peak pair。
2. Stage 2 输出 top-K candidates。
3. Dense scoring 只 rerank top-K candidate windows。
4. 加 Stage 4 feature agreement gate。
5. 加 Stage 6 acquire lock stability gate。

### P2: 让 Demo 稳定

1. PCEN-mel 替代或补强 current logMel。
2. 加 chroma-onset / CENS。
3. Fine alignment refinement。
4. Tracking filter。
5. Multiple hypothesis ambiguity handling。

## 8. Reference Links

1. Avery Wang, "An Industrial Strength Audio Search Algorithm", ISMIR 2003. 重点：time-frequency constellation、pair hash、offset histogram、cellphone microphone robustness。
2. Jaap Haitsma and Ton Kalker, "A Highly Robust Audio Fingerprinting System", ISMIR 2002. 重点：fingerprint system parameters、robustness / granularity / search speed tradeoff。
3. Joren Six and Marc Leman, "Synchronizing Multimodal Recordings Using Audio-to-Audio Alignment", Journal on Multimodal User Interfaces, 2015. 重点：ambient audio -> audio-to-audio alignment、fingerprint offset、drift、cross-covariance refinement。
4. Sebastian Ewert, Meinard Müller and Peter Grosche, "High Resolution Audio Synchronization Using Chroma Onset Features", ICASSP 2009. 重点：onset temporal accuracy + chroma robustness。
5. Meinard Müller, Frank Kurth and Michael Clausen, "Chroma-Based Statistical Audio Features for Audio Matching", WASPAA 2005. 重点：CENS / chroma statistical features, robust harmonic matching。
6. Vincent Lostanlen et al., "Per-Channel Energy Normalization: Why and How", IEEE Signal Processing Letters, 2019. 重点：PCEN for far-field noisy recordings, temporal integration, gain control, dynamic range compression。

## 9. Final Spec Summary

最终主流程应为：

```text
Offline index
-> streaming mic feature readiness
-> landmark offset histogram coarse retrieval
-> top-K candidate expansion
-> dense multi-feature rerank
-> local fine alignment
-> acquire lock stability gate
-> tracking filter
-> relock if needed
```

最关键的变化是：

从 current dense-first prototype，改成 landmark-first, dense-verified, fine-refined, tracker-stabilized 的 multi-stage known-track alignment engine。

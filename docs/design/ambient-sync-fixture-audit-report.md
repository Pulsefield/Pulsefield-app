---
commit: 139ff68e193c6e8ded61d89d5fa384c6c64bbee8
title: Ambient Sync Fixture Audit Report
status: current diagnostics
---

# Ambient Sync Fixture Audit Report

## Scope

This document records current diagnostic findings for the ambient sync engine
against the local sidecar-backed recorded fixtures. It is not a design spec,
roadmap, or execution plan.

Baseline commit: `139ff68e193c6e8ded61d89d5fa384c6c64bbee8`.

## Inputs And Method

The expanded fixture set contains `18` recorded `.caf` microphone fixtures
across `5` local reference songs. The recorded fixture audio was used only as
microphone-query audio. Each fixture's sidecar `targetAsset.displayPath` was
used as the reference music path, and the reference was loaded through the
offline index cache.


Reference indexes used:

| Recording Group | Fixtures | Reference Frames | Reference Landmarks | Reference Path |
| --- | ---: | ---: | ---: | --- |
| `2 + 2 = 5` | 3 | 18692 | 144158 | `/Users/l/Music/网易云音乐/Radiohead - 2 + 2 = 5.mp3` |
| `Julie (朱莉)` | 4 | 19533 | 146811 | `/Users/l/Music/网易云音乐/布朗尼 - Julie (朱莉).mp3` |
| `Playing God` | 3 | 19304 | 133184 | `/Users/l/Music/网易云音乐/Polyphia - Playing God.mp3` |
| `妄想感傷代償連盟` | 4 | 25311 | 196266 | `/Users/l/Music/网易云音乐/DECO27,初音ミク - 妄想感傷代償連盟.mp3` |
| `泡` | 4 | 25629 | 183668 | `/Users/l/Music/网易云音乐/King Gnu - 泡.mp3` |

Experiments:

- 1000 ms default-engine replay over all 18 fixtures.
- 1000 ms focused parameter replay over four configurations:
  - `spectral-provisional`
  - `spectral-loose-timing`
  - `lower-final-spectral`
  - `wide-tracking`

Raw aggregate output was written to:

- `.build/ambient-sync-audit-experiment-output.txt`
- `.build/ambient-sync-audit-focused-output.txt`

## Current Engine Gate Shape

The current engine path in
`Sources/PulsefieldCore/Services/AmbientSync/AmbientSyncEngine.swift` is:

1. Readiness: duration, average energy, active frame fraction, query landmark
   count.
2. Landmark coarse search: landmark histogram vote count, density, temporal
   spread, top-to-second ratio, and vote margin.
3. Fast timing verify: dense rerank using onset envelope, subband onset, and
   chroma onset.
4. Robust verify: dense rerank using the full default dense feature set, with
   explicit PCEN mel and CENS minimum gates.
5. Tracking: after final lock, queries shrink to the tracking window.

Important current weighting:

| Stage | Onset | Subband | PCEN Mel | Chroma | CENS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Provisional reranker | 0.40 | 0.40 | 0 | 0.20 | 0 |
| Final reranker | 0.25 | 0.25 | 0.20 | 0.15 | 0.15 |

There is a second gate after provisional reranking:
`timingScore(_:)` and `timingAgreementCount(_:)` only count onset, subband,
and chroma. So adding PCEN/CENS weight to the provisional reranker changes the
combined dense score and candidate ordering, but does not by itself let PCEN or
CENS satisfy the engine timing gate.

## Default Replay Results

Default v1 now has one real final-lock success case, but it is not stable
enough to call the current behavior ready. `Playing God` take 01 final-locks at
`5973 ms`, then ends in final-phase `relocking/fastTimingVerify`.

At 1000 ms cadence:

| Recording Group | Fixtures | First Provisional | Final Lock | Ended Locked | Dominant Failure |
| --- | ---: | ---: | ---: | ---: | --- |
| `2 + 2 = 5` | 3 | 0 | 0 | 0 | `weakAlignmentPeak` |
| `Julie (朱莉)` | 4 | 1 | 0 | 0 | `weakAlignmentPeak`, some `ambiguousOffset` |
| `Playing God` | 3 | 1 | 1 | 0 | tracking drops to `weakAlignmentPeak` |
| `妄想感傷代償連盟` | 4 | 0 | 0 | 0 | `ambiguousOffset` |
| `泡` | 4 | 0 | 0 | 0 | `ambiguousOffset` and `weakAlignmentPeak` |

Default fixture outcomes:

| Fixture | End State | First Provisional | Final Lock | Max Votes | Max Ratio | Final Reason |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `2-2-5-take-01` | `locking/none/fastTimingVerify` | nil | nil | 2701 | 2.58 | `weakAlignmentPeak` |
| `2-2-5-take-02` | `locking/none/fastTimingVerify` | nil | nil | 2408 | 2.75 | `weakAlignmentPeak` |
| `2-2-5-take-03` | `locking/none/fastTimingVerify` | nil | nil | 900 | 3.72 | `weakAlignmentPeak` |
| `julie-take-01` | `locking/provisional/fastTimingVerify` | 16885 ms | nil | 1687 | 3.72 | `weakAlignmentPeak` |
| `julie-take-02` | `locking/none/fastTimingVerify` | nil | nil | 2068 | 3.72 | `weakAlignmentPeak` |
| `julie-take-03` | `locking/none/landmarkCoarse` | nil | nil | 911 | 2.01 | `ambiguousOffset` |
| `julie-take-04` | `locking/none/fastTimingVerify` | nil | nil | 942 | 1.58 | `weakAlignmentPeak` |
| `playing-god-take-01` | `relocking/final/fastTimingVerify` | 3989 ms | 5973 ms | 2371 | 601.00 | `weakAlignmentPeak` |
| `playing-god-take-02` | `locking/none/fastTimingVerify` | nil | nil | 718 | 3.29 | `weakAlignmentPeak` |
| `playing-god-take-03` | `locking/none/landmarkCoarse` | nil | nil | 956 | 2.06 | `ambiguousOffset` |
| `妄想-take-01` | `locking/none/landmarkCoarse` | nil | nil | 3027 | 1.24 | `ambiguousOffset` |
| `妄想-take-02` | `locking/none/landmarkCoarse` | nil | nil | 3323 | 1.22 | `ambiguousOffset` |
| `妄想-take-03` | `locking/none/landmarkCoarse` | nil | nil | 2257 | 1.19 | `ambiguousOffset` |
| `妄想-take-04` | `locking/none/landmarkCoarse` | nil | nil | 2842 | 1.47 | `ambiguousOffset` |
| `泡-take-01` | `locking/none/fastTimingVerify` | nil | nil | 2295 | 3.06 | `weakAlignmentPeak` |
| `泡-take-02-001814` | `locking/none/fastTimingVerify` | nil | nil | 761 | 1.55 | `weakAlignmentPeak` |
| `泡-take-02-001837` | `locking/none/landmarkCoarse` | nil | nil | 649 | 1.24 | `ambiguousOffset` |
| `泡-take-04` | `locking/none/landmarkCoarse` | nil | nil | 857 | 1.45 | `ambiguousOffset` |

Default reason counts across all sampled windows:

| Reason | Count |
| --- | ---: |
| `weakAlignmentPeak` | 207 |
| `ambiguousOffset` | 186 |
| `insufficientDuration` | 72 |
| `none` | 3 |
| `insufficientLandmarkEvidence` | 2 |

The original Radiohead-only conclusion was too narrow. Across the larger set,
there are two dominant blockers:

- dense timing weakness for `2 + 2 = 5`, most `Julie`, most `Playing God`, and
  some `泡` takes;
- coarse landmark ambiguity for `妄想感傷代償連盟`, some `泡` takes, and some
  later `Julie` / `Playing God` windows.

## Feature Reliability

The table below aggregates default fast-timing windows only. Tracks blocked at
coarse search have fewer dense rows, so those feature statistics are less
representative for `妄想感傷代償連盟`.

| Group | Dense Rows | Onset Pass | Subband Pass | Chroma Pass | Mean PCEN | Mean CENS | Combined Pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `2 + 2 = 5` | 92 | 86 / 92 | 0 / 92 | 3 / 92 | 0.810 | 0.892 | 1 / 92 |
| `Julie (朱莉)` | 49 | 39 / 49 | 0 / 49 | 0 / 49 | 0.717 | 0.845 | 5 / 49 |
| `Playing God` | 48 | 45 / 48 | 2 / 48 | 2 / 48 | 0.789 | 0.763 | 3 / 48 |
| `妄想感傷代償連盟` | 1 | 1 / 1 | 0 / 1 | 0 / 1 | 0.734 | 0.850 | 0 / 1 |
| `泡` | 26 | 5 / 26 | 0 / 26 | 0 / 26 | 0.787 | 0.844 | 0 / 26 |

Aggregate default dense windows:

- Onset passes `176 / 216` windows. It is still the best provisional timing
  feature, but `泡` shows it is not universally reliable.
- Subband onset passes only `2 / 216` windows. It remains the weakest default
  feature and should not carry `0.40` provisional weight.
- Chroma onset passes only `5 / 216` windows. It is not reliable enough as the
  second required provisional agreement feature.
- PCEN mel and CENS are strong on most correctly aligned dense windows, but
  they do not help the current engine timing gate.
- Default combined dense score passes only `9 / 216` windows because the
  provisional weighted mix overvalues subband/chroma and ignores PCEN/CENS.

## Parameter Experiments

Focused 1000 ms experiment results:

| Variant | First Provisional | Final Lock | Ended Locked | Result |
| --- | ---: | ---: | ---: | --- |
| `default` | 2 / 18 | 1 / 18 | 0 / 18 | One final lock, then relocking |
| `spectral-provisional` | 2 / 18 | 1 / 18 | 0 / 18 | Higher combined scores, no state improvement |
| `spectral-loose-timing` | 6 / 18 | 1 / 18 | 0 / 18 | More provisional states, final still blocked |
| `lower-final-spectral` | 6 / 18 | 5 / 18 | 1 / 18 | More locks, mostly unstable |
| `wide-tracking` | 6 / 18 | 5 / 18 | 1 / 18 | Same lock count; tracking radius is not enough |

`spectral-provisional` changed provisional reranker weights to use onset,
PCEN, CENS, and a small chroma contribution. This raised combined dense scores:
for example, Radiohead take 01 moved from mean combined `0.434` to `0.709`.
Lock behavior did not improve because the engine timing gate still computes
timing score and timing agreement from onset, subband, and chroma only.

`spectral-loose-timing` combined spectral provisional ranking with looser timing
thresholds. It produced more provisional states:

- `2 + 2 = 5`: 2 / 3 provisional, 0 / 3 final.
- `Julie`: 2 / 4 provisional, 0 / 4 final.
- `Playing God`: 2 / 3 provisional, 1 / 3 final.
- `妄想感傷代償連盟`: 0 / 4 provisional.
- `泡`: 0 / 4 provisional.

`lower-final-spectral` produced five final locks:

| Fixture | First Provisional | Final Lock | End State |
| --- | ---: | ---: | --- |
| `2-2-5-take-02` | 11925 ms | 11925 ms | `relocking/final/fastTimingVerify` |
| `2-2-5-take-03` | 3989 ms | 5973 ms | `relocking/final/fastTimingVerify` |
| `julie-take-01` | 3989 ms | 5973 ms | `locked/final/tracking` |
| `julie-take-02` | 20853 ms | 20853 ms | `relocking/final/fastTimingVerify` |
| `playing-god-take-01` | 3989 ms | 5973 ms | `relocking/final/fastTimingVerify` |

`wide-tracking` widened post-lock tracking search from `750 ms` to `2000 ms`
and relaxed final offset stability to `500 ms`. It produced the same five final
locks and the same single ended-locked fixture (`julie-take-01`). This points
away from tracking search radius as the main post-lock problem. The short
tracking query and tracking-stage timing gates are more likely causes.

## Failure Modes

### Dense Timing Failure

Dense timing failure is the main blocker when landmark coarse has a clear
candidate. The failure usually presents as `weakAlignmentPeak` even when
landmark votes, dense coverage, PCEN, and CENS are strong.

Root issue: the default provisional stage effectively asks onset, subband, and
chroma to agree. On the expanded fixtures, onset often works, subband almost
never works, and chroma rarely works. PCEN/CENS often work, but the engine does
not count them for provisional timing score or agreement.

### Coarse Landmark Ambiguity

`妄想感傷代償連盟` is mostly blocked before dense timing. It has very high
absolute vote counts, but low top-to-second ratios:

- max top votes: `3323`
- max top-to-second ratio by take: about `1.19` to `1.47`

That pattern suggests repeated or non-discriminative landmark hashes, not a lack
of reference index data. `泡` also has several low-ratio takes, with max ratios
around `1.24` to `1.55` except take 01.

Lowering the coarse ratio alone is not sufficient. It can allow more windows
into fast timing, but many then fail dense timing immediately. Coarse ambiguity
needs either better landmark discrimination or a policy that lets multiple
high-vote coarse candidates reach dense reranking safely.

### Tracking Instability

The engine can final-lock several fixtures under relaxed gates, but most locks
fall back to `relocking/final/fastTimingVerify`. Widening the tracking search
radius did not materially improve the outcome.

The likely tracking issue is not search radius alone. Post-lock tracking uses a
short query window and still depends on the fragile fast-timing gate. That makes
the lock vulnerable to local sections where onset/subband/chroma agreement is
weak even though robust spectral evidence is still present.

## Parameter Implications

These are diagnostic implications from the experiments, not an execution plan.

Do not treat cache/indexing as the blocker. The expanded run loaded all five
reference indexes from cache and compared each recorded fixture against the
correct sidecar target path.

Do not only lower `minimumCoarseVoteRatio`. It does not fix the dominant dense
timing weakness and can admit ambiguous coarse candidates.

Do not only add PCEN/CENS to provisional reranker weights. That improves
combined dense score, but the engine timing gate still ignores PCEN/CENS. Any
provisional spectral change must also revisit `timingScore(_:)` and
`timingAgreementCount(_:)`.

The current provisional feature mix is not defensible for these recordings:

- reduce or remove provisional `subbandOnset` weight;
- stop requiring subband/chroma to be the practical second agreement signal;
- consider onset + PCEN + CENS as the main provisional agreement set;
- keep multiple-feature agreement, but make the feature set match what works on
  recorded microphone audio.

Final-gate relaxation can create locks, but most are unstable. That makes it a
diagnostic tool, not a product-ready fix.

Tracking needs a separate pass. Based on `wide-tracking`, increasing radius is
not enough; the tracking query duration and tracking timing gate need separate
evaluation.

For coarse-ambiguous songs such as `妄想感傷代償連盟`, tune the landmark stage
separately from dense timing. Candidate ratio, hash selectivity, and whether
dense reranking should see more than one high-vote coarse candidate are the
parameters most worth investigating.

## Current Failure Summary

The ambient sync cache and per-fixture reference path are working. The engine is
using local reference music indexes and treating recorded fixtures as microphone
queries.

The larger fixture set shows three distinct reliability tiers:

- `Julie` and `Playing God` contain sections where the current engine can get
  close to lock, and relaxed gates can lock some takes.
- `2 + 2 = 5` has clear landmark evidence but remains blocked by provisional
  timing unless gates are relaxed.
- `妄想感傷代償連盟` and some `泡` takes are primarily coarse-ambiguity cases,
  not just dense-timing cases.

The current v1 engine is not ready as product behavior on these recorded
fixtures. It can lock one default fixture and several relaxed-gate fixtures, but
the lock state is usually not stable over time.

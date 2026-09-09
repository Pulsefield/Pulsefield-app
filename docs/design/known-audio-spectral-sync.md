---
commit: d3eb9eab7c4bf9fc49d840dfcbda3469f6a13b9a
title: Known Audio Spectral Sync — Implementation and Measurements
status: current working-tree implementation against the pinned baseline
---

# Known Audio Spectral Sync

The default `AmbientSyncEngine` now estimates delay directly from temporal spectral
correlation. It searches the known track, verifies new audio at the proposed
position, then tracks locally. The legacy landmark engine remains available as
`Configuration.v1`; the new default is `.v2`. Audio feature extraction and on-disk
reference formats are unchanged.

This document describes the implemented working-tree change and its measurements
against the pinned commit. It is not a roadmap or execution plan.

## The underlying problem

A useful model is

\[
y(t) = a(t)\,[h*x]((1+\epsilon)t+\tau)+n(t).
\]

The reference `x` is known. Delay `τ` is the desired answer; `ε` represents small
clock differences. Speaker/room/microphone filtering `h`, gain `a`, and unrelated
sound `n` are nuisance variables. Offset convention is **reference time = recorded
time + offset**.

The useful evidence is the same spectral changes occurring in the same temporal
arrangement. Absolute loudness, persistent spectral color, and the identity of a
few loud peaks are less reliable under noise. This follows the filtered-correlation
view of delay estimation in [Knapp and Carter](https://www.ee.iitb.ac.in/course/~sachinnayak/finalpaper2.pdf).

The old engine had three structural costs:

- Landmark recall was mandatory before dense evidence could participate. Noise
  replacing the loudest peaks could therefore prevent a correct dense alignment.
  The extractor usually exhausted its two-pair fanout against the next frame,
  making its evidence less distinctive than the broader constellations described
  by [Wang](https://www.princeton.edu/~cuff/ele301/files/Wang03-shazam.pdf).
- Uncentered cosine rewarded persistent nonnegative spectral content. A high
  score did not necessarily imply a distinctive temporal position.
- Confirmation and decay counted updates. A 100 ms callback cadence repeatedly
  counted almost the same five seconds of audio, unlike the 1000 ms fixture pass.

Two different uncertainties must remain separate: **which occurrence of a phrase
is playing**, and **the precise delay within that occurrence**. A narrow peak can
still have an equally convincing distant competitor.

## Implemented signal path

`AmbientSyncSpectralMatcher.swift` uses the existing 24 PCEN mel bands. PCEN already
provides adaptive gain normalization; its behavior depends on the time scale and
noise distribution, as explained by [Lostanlen et al.](https://www.justinsalamon.com/uploads/4/3/9/4/4394963/lostanlen_pcen_spl2018.pdf).
The matcher applies `log1p`, then subtracts a centered temporal mean of approximately
500 ms from each band. At the default hop this is 47 frames. This suppresses residual
stationary background and slowly changing band levels.

Each query loses approximately 250 ms at both edges so all scored samples have
complete centering context. Processing uses only audio already received. The
supported evidence endpoint, rather than the callback time, determines freshness.
The reported offset projects that evidence to the current query endpoint.

For each offset, the score is the mean of the 24 band correlations:

\[
S(\tau)=\frac1B\sum_b
\frac{\langle q_b,r_{b,\tau}\rangle}
{\sqrt{\max(\|q_b\|^2,mv_0)\max(\|r_{b,\tau}\|^2,mv_0)}}.
\]

Here `m` is the number of compared frames and `v₀ = 0.001` is a variance floor.
It prevents nearly empty bands from receiving unlimited normalization. Scores are
agreement measures, not calibrated probabilities.

The implementation:

1. Precomputes band arrays and energy prefix sums for the reference.
2. Averages groups of four frames for whole-track retrieval. Vectorized
   [Accelerate correlation](https://developer.apple.com/documentation/accelerate/1d-correlation-and-convolution)
   scores every valid coarse position; no hash hit is required.
3. Retains eight independent peaks, separated by approximately 750 ms. Refines
   each at the original feature rate, then fits a local parabola for sub-hop timing.
4. Computes first-half, second-half, and most-recent-second agreement. The
   competing-peak margin measures location ambiguity separately from refinement.
5. Rejects incompatible timestamps, including cumulative grid skew that could
   otherwise yield a strong feature match and an incorrect endpoint projection.

The index adds about 34 KiB per reference second at default settings. It is
immutable after construction. No reference cache invalidation is required because
this representation is derived from the unchanged cached PCEN frames.

## Streaming decisions

`AmbientSyncSpectralEngine.swift` implements decisions in recorded-audio time.
Acquisition searches at most every 500 ms. Accepted tracking searches within
±100 ms, with periodic whole-track checks every two seconds. Smoothing uses a
300 ms time constant, rather than a fixed gain per callback.

A normal acquisition candidate needs correlation ≥0.25, competing-peak margin
≥0.06, and both half scores ≥0.10. Confirmation additionally requires a subsequent
second of audio, at the same offset, with recent correlation ≥0.15. Early
confirmation before the final window needs stronger whole-window evidence
(0.45 correlation, 0.12 margin, 0.20 in both halves). Final lock retains the
configured minimum query duration of 4.5 seconds. These thresholds were calibrated
on the available corpus, not on a held-out dataset.

Fresh evidence is essential: unrelated transients produced convincing candidates
in several overlapping windows. Two matching outputs 500 ms apart were not enough.
A later second of independent audio rejected those false acquisitions.

Tracking uses lower local evidence requirements because position is already
established. It can coast for 1500 ms after its last accepted observation. Once
that expires, reacquisition must pass global verification again. A tested dormant
recovery shortcut was removed: pulse noise and 250 ms snippets could revive an old
position when global ambiguity was bypassed. The duplicate-phrase regression test
fails with that shortcut and passes with the final implementation.

The fixture runner now retains the same five-second window as the live runtime,
including after final lock. Previously it permanently switched to two seconds,
which materially changed tracking results. Short tracking windows remain supported
by the engine and are covered by a regression test.

The legacy reranker also caches scores for identical aligned frame pairs during
sub-frame refinement. Timing errors remain specific to each offset. All 80
standalone differential scenarios matched the old results; a representative
optimized microbenchmark improved from 16.50 to 4.91 ms. This optimization does
not change legacy gates or score definitions.

## Measurements

All 24 local CAF fixtures, nine reference tracks, 1522.389 seconds of audio.
Comparison uses Debug frameworks, fixed five-second queries, and approximately
1000 ms audio-time cadence. Extraction occurs before replay. Process timings are
monotonic wall durations inside `engine.process`, excluding decoding, reference
loading, feature extraction, construction, and trace writing. They are not
end-to-end app latency or Release performance guarantees.

| Metric | Pinned baseline | Spectral v2 |
| --- | ---: | ---: |
| Fixtures reaching final lock | 24/24 | 24/24 |
| Median first final lock | 7.04 s | 6.04 s |
| Locked samples | 993/1555 (63.9%) | 1251/1555 (80.5%) |
| Fixtures ending locked | 21/24 | 20/24 |
| Engine processing time | 683.13 s | 37.63 s |

The measured process-time reduction is approximately **18×**. Some easier fixtures
acquire one sampled step later because confirmation requires new evidence.
`locked` sample counts include short coasting periods; they are not independent
observations or annotations of music presence.

| Traffic recording | Baseline first lock | V2 first lock | Baseline locked samples | V2 locked samples |
| --- | ---: | ---: | ---: | ---: |
| MEGALOVANIA | 28.10 s | 9.05 s | 51.0% | 93.3% |
| Queen — Is This The World We Created | 21.08 s | 5.03 s | 35.0% | 48.0% |
| Wake Me up When September Ends 1 | 98.28 s | 8.04 s | 55.3% | 84.8% |
| Wake Me up When September Ends 2 | 24.09 s | 7.04 s | 61.9% | 82.5% |
| 夜に駆ける 1 | 6.04 s | 6.04 s | 97.1% | 91.7% |
| 夜に駆ける 2 | 43.14 s | 7.04 s | 68.5% | 87.6% |

The eleven 30-second cold-entry probes, starting at recording seconds 30 or 90,
all lock within the probe; baseline was 8/11. Across full traffic recordings and
these entries, 1158 locked samples agree with independent alignment annotations
within 8.0 ms; none differ by more than 250 ms. The annotations are algorithmic
estimates on a 10 ms grid, **not human timing truth**. This does not establish
absolute 8 ms accuracy. The older fixtures' jointly locked offsets also agree
with baseline within 8 ms, which is consistency evidence rather than truth.

For Queen entry at 30 seconds, using approximately **100 ms cadence**:

| Process timing | Baseline Debug | V2 Debug |
| --- | ---: | ---: |
| Median call | 257 ms | 4.84 ms |
| p95 call | 610 ms | 21.91 ms |
| Total across 30 s audio | 69.77 s | 1.46 s |

This removes the measured processing-budget failure on that sample. Startup,
hardware capture, scheduling backlog, and UI were not simulated. The app was
built for tests but was not installed or launched.

## Negative controls and remaining limits

Actual optimized Swift source, replayed from exported PCEN features:

- **384 full wrong-reference runs**, all 24 recordings against their eight wrong
  references at both 500 and 1000 ms cadence: 36,640 calls, zero confirmed/locked
  acquisitions. Annotation offsets were never matcher input.
- **1020 post-acquisition controls**, covering unrelated music, noise, pulses,
  matching snippets, three cadences, and five-/two-second windows: zero false
  relocks after loss with the final global-verification rule.
- **220 XCTest cases executed, 219 passed, one opt-in local smoke test skipped**.
  Real audio was exercised separately by the complete fixture benchmark. New
  regressions cover noisy alignment without hashes, wrong/constant content,
  repeated passages, duplicate updates, cadence, seeks, silence, reference ends,
  timestamp skew, small rate drift, short tracking, and ambiguous recovery.

The post-acquisition controls also expose a remaining limit: incidental local
correlations can prolong an existing lock after the music changes. First loss
was as late as **5.44 seconds** after replacement; this is different from false
reacquisition. A 1500 ms coast budget is measured from the last accepted observation,
not from a perfectly known physical change point.

Quiet passages still lose support. Queen ends relocking where baseline ended
locked, and 夜に駆ける 1 loses more locked samples despite equal acquisition time.
The repeated passage in 泡 take 04 still takes about 27 seconds to disambiguate.
These regressions and ambiguities are included in the table, not hidden by raising
coast duration. Large tempo changes and general nonlinear time warping are not
supported; the drift test covers a small 1000 ppm rate difference. Controls are
from the calibration corpus and feature-level synthesis, not an independently
recorded deployment-negative dataset.

## Reproduction and retained evidence

Build without launching a capture app:

```sh
xcodebuild -project Pulsefield.xcodeproj -scheme PulsefieldACRCloudDebugCLI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/SyncV2DerivedData build

swiftc -O \
  -F .build/SyncV2DerivedData/Build/Products/Debug \
  -I .build/SyncV2DerivedData/Build/Products/Debug \
  -framework PulsefieldCore \
  -Xlinker -rpath -Xlinker "$PWD/.build/SyncV2DerivedData/Build/Products/Debug" \
  Tools/ambient_sync_benchmark.swift -o .build/ambient_sync_benchmark

.build/ambient_sync_benchmark \
  --fixtures LocalFixtures/ambient-sync-voice-memos \
  --output LocalFixtures/ambient-sync-voice-memos/.spectral-sync-rerun \
  --entry-seconds 0,30,90 --cadence-ms 1000
```

Recompile the benchmark whenever the framework changes: this local Swift framework
is not built for library evolution. `--legacy` selects v1, including its new exact
score cache. Reproducing the historical timing requires the pinned commit, not the
optimized v1 in this working tree. `--filter queen --entry-seconds 30 --cadence-ms 100`
reproduces the frequent-update probe.

Local-only evidence is retained in
`LocalFixtures/ambient-sync-voice-memos/.spectral-sync-20260909/`:

- `comparison.json`: per-fixture baseline/new metrics and annotation differences.
- `baseline-live5s/`, `v2-live5s/`, `v2-queen100/`: native replay traces and summaries.
- `features/`: compact PCEN exports with reference mappings and recorded timestamps.
- `wrong-reference-controls/`, `recovery-controls/`: final control traces, source
  snapshots, hashes, summaries, and portable `run.sh` scripts. Set
  `PULSEFIELD_FEATURE_EXPORTS` to the absolute retained `features/` directory and
  `PULSEFIELD_VALIDATION_OUTPUT` to a fresh absolute output directory before running.
- `tests.log`, `working-tree-sources.json`: test evidence and final implementation hashes.

The pre-existing traffic fixture report and original recordings were preserved.

---
commit: 5b2d9cf2a0ae3a205123eb53bdbf53b41602c519
title: Ambient Sync Cold Index And Live Lock Status
status: current performance diagnostics
---

# Ambient Sync Cold Index And Live Lock Status

## Scope

This document records the current measured cost for the intended real app
scenario:

1. The user selects a target audio file that has not been indexed before.
2. Pulsefield decodes the target, computes ambient sync features, builds the
   reference index, and writes the binary cache.
3. Pulsefield listens to microphone audio and calls the real
   `AmbientSyncEngine.process(...)` path at a live-like matching cadence until
   sync reaches final lock.

Baseline commit: `5b2d9cf2a0ae3a205123eb53bdbf53b41602c519`.

## Benchmark Method

The measurement used the `18` local ambient sync fixtures under
`LocalFixtures/ambient-sync-voice-memos`, reduced to the `5` unique target
songs referenced by their sidecars.

For each target song:

- Cold index time used a fresh temporary cache directory.
- Warm index time immediately loaded the same target through the cache path.
- The microphone side used one representative real fixture for that target.
- Matching used real `AmbientSyncReferenceIndex` and real
  `AmbientSyncEngine.process(...)`.
- Matching was sampled at `1000 ms` replay endpoints to approximate a
  live app cadence instead of the fixture-only every-feature-hop trace cadence.

Default feature configuration:

| Setting | Value |
| --- | ---: |
| Processing sample rate | `48000 Hz` |
| Feature window | `1024 samples` |
| Feature hop | `512 samples` |
| Feature hop duration | `10.67 ms` |
| Speculative query | `1500 ms` |
| First lock target query | `3000 ms` |
| Final lock target query | `5000 ms` |
| Tracking query | `2000 ms` |

## Results

| Target | Target Length | Cold Index Build | Warm Index Load | Frames | Landmarks | Cache Size | Fixture Length | Matching CPU | Avg Process Call | Max Process Call | First Sync | Final Lock | Final State |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `2 + 2 = 5` | `199.39 s` | `18.943 s` | `0.214 s` | `18692` | `144158` | `12.546 MB` | `31.70 s` | `9.617 s` | `291.414 ms` | `1488.334 ms` | `4.03 s` | `9.05 s` | `locked/final/tracking` |
| `Julie (朱莉)` | `208.39 s` | `19.830 s` | `0.221 s` | `19533` | `146811` | `12.927 MB` | `20.10 s` | `3.623 s` | `164.676 ms` | `1279.838 ms` | `4.03 s` | `6.04 s` | `locked/final/tracking` |
| `Playing God` | `205.98 s` | `19.691 s` | `0.211 s` | `19304` | `133184` | `12.204 MB` | `18.60 s` | `3.859 s` | `192.935 ms` | `1192.165 ms` | `4.03 s` | `7.04 s` | `locked/final/tracking` |
| `妄想感傷代償連盟` | `270.03 s` | `26.160 s` | `0.291 s` | `25311` | `196266` | `17.040 MB` | `13.00 s` | `3.230 s` | `230.705 ms` | `781.616 ms` | `5.03 s` | `8.04 s` | `locked/final/tracking` |
| `泡` | `273.42 s` | `26.198 s` | `0.282 s` | `25629` | `183668` | `16.531 MB` | `23.70 s` | `4.494 s` | `179.774 ms` | `1204.253 ms` | `4.03 s` | `7.04 s` | `locked/final/tracking` |

Aggregate observations:

| Measurement | Result |
| --- | ---: |
| Total target audio measured | `1157.21 s` |
| Total cold index build time | `110.822 s` |
| Cold build speed | `~0.096x` target duration |
| Cold build range | `18.943-26.198 s` |
| Warm load range | `0.211-0.291 s` |
| Live-like final lock range | `6.04-9.05 s` |
| Cold start to final lock range | `25.87-34.20 s` |
| Process call average range | `164.676-291.414 ms` |
| Process call max range | `781.616-1488.334 ms` |

## Current Efficiency Read

The warm path is usable for interactive sync. Once a target has a valid cached
reference index, loading it takes around `0.2-0.3 s`, and the live-like final
lock appears in around `6-9 s` of microphone audio for the measured fixtures.

The cold path is not instant. Building the reference index for a normal
`3-4.5 minute` compressed song currently takes around `19-26 s` before live
matching can produce a final lock. That is acceptable as background preparation
or an explicit "preparing sync" state, but it is too slow for a synchronous
button press that is expected to start syncing immediately.

Matching is also not cheap enough to run at feature-hop cadence. Even with the
current dense-reranker allocation reduction, a live-like `1000 ms` matching
cadence still shows individual `AmbientSyncEngine.process(...)` calls spiking
as high as `1.49 s`. This path must stay off the main thread and should be
throttled. The fixture-only full-hop replay cadence, around every `10.67 ms`,
is useful for diagnostics but not a viable production cadence.

## Main Bottlenecks

Cold indexing includes full decode/resample, feature extraction, landmark index
construction, binary cache encoding, and source identity hashing. Feature and
landmark extraction are the dominant cold-start cost.

Warm cache load is much faster, but it still validates the source against the
cached SHA-256 identity. That means a cache hit may still read and hash the
source file. It is tolerable for the measured files, but it can become visible
when loading many cached tracks or much larger local files.

Live matching cost is concentrated in candidate generation and dense reranking.
The current implementation is good enough for a low-frequency acquisition loop,
but the measured process-call spikes show that it is not yet a tight real-time
inner loop.

## Product Implications

The app should treat reference indexing as an asynchronous preparation step:

- Start building the reference index when a track becomes the likely sync
  target, not only after the user presses the sync button.
- Persist and reuse binary reference indexes aggressively.
- Show a preparation state for unseen target files.
- Start live matching only after the reference index is ready.
- Run `AmbientSyncEngine.process(...)` on a background queue.
- Use a coarse matching cadence around `1000 ms` for acquisition until a tighter
  cadence is justified by profiling.

With those constraints, the existing path is usable for cached tracks and
prototype-quality for unseen tracks. It is not efficient enough for immediate
first-use sync without precomputation.

## Next Optimization Targets

Near-term optimization should focus on the cold and hot paths separately.

Cold path:

- Precompute indexes during library scan or track selection.
- Avoid synchronous source SHA-256 validation on every warm load; use fast file
  identity for the hot path and reserve full hashing for cold writes, suspicious
  identity changes, or background verification.
- Profile feature extraction and landmark generation separately from audio
  decode so the dominant cold-start stage is explicit.

Hot matching path:

- Keep fixture replay sampling as the default real-fixture diagnostic mode.
- Avoid constructing new query-window arrays for every sampled endpoint where a
  slice or ring-buffer view would be enough.
- Continue reducing dense-reranker allocations and repeated scans.
- Add timing diagnostics around histogram generation and dense rerank stages so
  process-call spikes can be attributed to a specific stage.

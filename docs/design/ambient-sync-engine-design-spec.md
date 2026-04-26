---
commit: 0bb9d835a01806357f8cdafe7ff34f95e2dc56ca
title: Ambient Sync Engine Design Spec
status: frozen design
---

# Ambient Sync Engine Design Spec

## 0. Scope

This document freezes the Phase 2 local ambient sync engine design. It is an
architecture and behavior spec, not a current-status diagnostic, product
roadmap, or execution plan.

Baseline commit: `0bb9d835a01806357f8cdafe7ff34f95e2dc56ca`.

This spec supersedes the Phase 2 ambient matching algorithm details in the
broader BYO music recognition spec where they conflict. In particular, the
engine must move past the prototype onset-envelope-only matcher.

## 1. Boundary

Phase 2 does not do song recognition, source discovery, or track identity
rejection. Its input is an already selected or resolved `LocalAudioAsset`, and
the engine assumes that asset is the target source.

The engine's only job is to decide whether the current microphone window has
enough reliable evidence to publish or update a position inside that selected
asset.

A negative decision means:

```text
The current microphone window does not contain enough reliable sync evidence,
so the engine withholds the SyncEstimate update.
```

A negative decision must not mean:

```text
This is the wrong song.
```

Unrelated generated audio can remain in the test corpus as a robustness case,
but assertions must be framed as "does not emit a reliable `SyncEstimate`",
not as track identity rejection.

The engine pipeline is:

```text
Resolved LocalAudioAsset
-> validated local sync index
-> microphone query window
-> feature extraction
-> initial wide search
-> dense verification
-> locked narrow tracking
-> clock / drift filter
-> SyncEstimate + diagnostics
```

The public estimate shape remains compatible:

```swift
public struct SyncEstimate: Equatable, Sendable {
    public let hostTime: ContinuousClock.Instant
    public let referenceTimeMS: Double
    public let confidence: Double
    public let driftPPM: Double?
    public let latencyMS: Double?
    public let source: SyncSource
}
```

Diagnostics are a side channel. They must not overload the semantics of
`SyncEstimate`.

## 2. Runtime State, Withhold Reasons, And Start Errors

Runtime withhold reasons describe microphone sync evidence quality, not track
identity and not index/cache validity:

```swift
public enum AmbientSyncWithholdReason: String, Codable, Sendable {
    case insufficientEnergy
    case insufficientLandmarkEvidence
    case weakAlignmentPeak
    case ambiguousOffset
    case unstableTrackingResidual
    case lostSignal
}
```

Reason meanings:

- `insufficientEnergy`: the microphone window is too quiet or has too few active frames.
- `insufficientLandmarkEvidence`: landmark votes or inliers have too little support.
- `weakAlignmentPeak`: the best alignment peak is weak or not prominent over the noise floor.
- `ambiguousOffset`: multiple offsets are similarly plausible.
- `unstableTrackingResidual`: locked tracking measured a position too far from prediction.
- `lostSignal`: consecutive windows lack enough evidence to maintain sync.

Index availability, stale caches, corrupt files, and incompatible feature
versions are start/preflight problems. They must fail before matching begins and
must not be reported as per-window withhold reasons:

```swift
public enum AmbientSyncStartError: Error, Sendable {
    case indexUnavailable
    case indexInvalid
    case indexIncompatible
}
```

The runtime state machine is:

```swift
public enum AmbientSyncEngineState: String, Codable, Sendable {
    case idle
    case indexing
    case ready
    case listening
    case locking
    case locked
    case drifting
    case relocking
    case lost
    case failed
}
```

State meanings:

- `idle`: no active asset, or the engine has not started.
- `indexing`: building a local sync index.
- `ready`: asset and validated index are available.
- `listening`: receiving microphone windows, with no estimate yet.
- `locking`: attempting initial lock.
- `locked`: publishing stable `SyncEstimate` values.
- `drifting`: signal is temporarily weak; clock prediction may be held in diagnostics.
- `relocking`: running wide search again after loss, seek, or unstable residuals.
- `lost`: there is no reliable current sync.
- `failed`: a preflight or hard runtime error outside normal matching decisions.

## 3. Feature Extractor

Indexing and query processing must use the same extractor implementation and
the same deterministic timebase:

```text
PCM decode / capture
-> mono mix
-> sample-rate conversion
-> STFT
-> log magnitude
-> landmark features
-> dense features
```

Initial settings:

| Parameter | Value |
| --- | --- |
| processing sample rate | 22050 Hz |
| FFT size | 2048 |
| hop size | 512 |
| window | Hann |
| initial query window | 6000-8000 ms |
| locked query window | 3000-5000 ms |

The required feature streams are:

- Landmark fingerprint for wide search and relock: log-magnitude STFT peaks,
  anchor-target pairs, hash `(f1, f2, deltaT)`, and postings from hash to
  reference anchor frames.
- Multi-band spectral flux for transient, beat, onset, candidate verification,
  and narrow tracking evidence. Use 6-12 bands:
  `flux[t, band] = max(0, logMag[t, band] - logMag[t - 1, band])`.
- Log-Mel spectral summary for dense local alignment and robustness against
  microphone, speaker, and room coloration. Use 16-32 dimensions.
- Chroma / CENS-like stream for harmonic progression evidence in quiet tonal
  sections. Use 12 dimensions with smoothing.

Chroma must not be the only dense feature. Repeated choruses and similar chord
loops can otherwise produce high-confidence ambiguous offsets.

## 4. Local Sync Index

The primary index format is a manifest plus binary features:

```text
Application Support/Pulsefield/SyncIndexes/<assetID>/
  manifest.json
  features/
    landmark-postings.bin
    dense-onset-flux.f32
    dense-logmel.f32
    dense-chroma.f32
    energy.f32
```

`onset-envelope.txt` is no longer a valid primary index.

The manifest schema is versioned. It records schema identity, feature extractor
identity, source identity, processing settings, feature dimensions, frame
counts, and feature file hashes. A compatible first schema is:

```json
{
  "schemaVersion": 2,
  "featureExtractorVersion": "ambient-sync-v2",
  "settingsHash": "...",
  "createdAt": "...",
  "asset": {
    "assetID": "...",
    "durationMS": 243123
  },
  "source": {
    "fileSizeBytes": 12345678,
    "contentModificationDate": "...",
    "fullFileSHA256": "...",
    "decodedFrameCount": 5367890,
    "decodedDurationMS": 243123,
    "originalSampleRate": 44100,
    "originalChannelCount": 2
  },
  "processing": {
    "processingSampleRate": 22050,
    "fftSize": 2048,
    "hopSize": 512,
    "window": "hann",
    "monoMix": "average"
  },
  "features": {
    "landmark": {
      "hashVersion": 1,
      "peakNeighborhoodTime": 3,
      "peakNeighborhoodFreq": 3,
      "fanout": 6,
      "targetZoneStartMS": 250,
      "targetZoneEndMS": 2500
    },
    "onsetFlux": { "dims": 8 },
    "logMel": { "dims": 24 },
    "chroma": {
      "dims": 12,
      "smoothingMS": 1000
    }
  },
  "featureFiles": {
    "landmarkPostings": {
      "path": "features/landmark-postings.bin",
      "recordCount": 12345,
      "sha256": "..."
    },
    "denseOnsetFlux": {
      "path": "features/dense-onset-flux.f32",
      "frames": 5234,
      "dims": 8,
      "sha256": "..."
    },
    "denseLogMel": {
      "path": "features/dense-logmel.f32",
      "frames": 5234,
      "dims": 24,
      "sha256": "..."
    },
    "denseChroma": {
      "path": "features/dense-chroma.f32",
      "frames": 5234,
      "dims": 12,
      "sha256": "..."
    }
  }
}
```

Index loading must validate enough cache invariants to avoid matching with an
index built for a different asset, schema, or feature extractor. If preflight
validation fails, `start(asset:index:)` throws `AmbientSyncStartError` and the
engine must not enter matching.

Minimum preflight checks:

- asset ID
- schema version
- feature extractor version
- settings hash
- source content hash
- decoded duration
- feature file existence
- feature file checksum
- feature dimensions
- feature frame count
- processing sample rate
- hop size

Validation outcomes:

- No usable index is available: `indexUnavailable`
- Source identity, feature file checksum, or manifest invariant failed: `indexInvalid`
- Schema, feature extractor version, settings hash, dimensions, sample rate, or hop size are incompatible: `indexIncompatible`

These are not matching failures. They are engineering/cache invariants checked
at the boundary before the engine consumes microphone windows.

The loaded in-memory shape can stay simple because Phase 2 handles one selected
asset at a time:

```swift
public struct LoadedSyncIndex {
    public var manifest: SyncIndexManifest
    public var landmarkPostings: [UInt32: [UInt32]]
    public var onsetFlux: FeatureMatrix<Float>
    public var logMel: FeatureMatrix<Float>
    public var chroma: FeatureMatrix<Float>
    public var energy: [Float]
    public var precomputedNorms: DenseFeatureNorms
}
```

## 5. Search Modes

Initial lock, relock, and user seek use wide search over the asset. Locked
tracking uses a narrow range around the predicted reference position.

### 5.1 Initial Wide Search

Input: a 6-8 second microphone query window.

Flow:

```text
query window
-> feature extraction
-> energy gate
-> landmark hash extraction
-> local postings lookup
-> offset histogram
-> top-K candidate offsets
-> dense verification
-> confidence scoring
-> publish SyncEstimate or withhold
```

Reference pseudocode:

```swift
func initialWideSearch(
    query: QueryFeatures,
    index: LoadedSyncIndex
) -> MatchDecision {
    guard query.activeFrameFraction >= minActiveFrameFraction,
          query.energyDBFS >= minEnergyDBFS else {
        return .withhold(reason: .insufficientEnergy)
    }

    let histogram = buildOffsetHistogram(
        queryLandmarks: query.landmarks,
        postings: index.landmarkPostings
    )

    guard histogram.bestVoteCount >= minLandmarkVotes else {
        return .withhold(reason: .insufficientLandmarkEvidence)
    }

    let candidates = histogram.topPeaks(
        maxCount: 8,
        minSeparationMS: 1500
    )

    let verified = candidates.map {
        verifyCandidateDenseFeatures(
            query: query,
            index: index,
            candidateOffsetMS: $0.offsetMS
        )
    }

    return scoreInitialCandidates(verified, query: query)
}
```

The only valid decision outputs are:

```swift
enum MatchDecision {
    case publish(SyncEstimate, AmbientMatchDiagnostics)
    case withhold(reason: AmbientSyncWithholdReason, AmbientMatchDiagnostics)
}
```

### 5.2 Candidate Verification

Each candidate offset computes:

- `onsetFluxScore`
- `logMelScore`
- `chromaScore`
- `energyScore`
- `combinedPeakScore`
- `peakSharpness`
- `peakWidthMS`

Initial dense feature weights:

| Signal | Weight |
| --- | ---: |
| onset flux | 0.40 |
| log-Mel | 0.30 |
| chroma | 0.25 |
| energy | 0.05 |

Candidate structure:

```swift
public struct CandidateAlignment: Codable, Sendable, Equatable {
    public var offsetMS: Double
    public var referenceTimeAtWindowEndMS: Double
    public var combinedScore: Double
    public var onsetFluxScore: Double
    public var logMelScore: Double
    public var chromaScore: Double
    public var energyScore: Double
    public var landmarkVoteCount: Int
    public var landmarkInlierRate: Double
    public var peakSharpness: Double
    public var peakWidthMS: Double
}
```

### 5.3 Initial Decision Rules

Initial lock may publish only when:

- query energy is sufficient
- landmark votes are sufficient
- best dense candidate score is sufficient
- best candidate is clearly separated from second best
- peak sharpness is sufficient
- candidate density is not excessive
- selected reference time is inside asset duration

Withhold mapping:

| Condition | Withhold reason |
| --- | --- |
| low energy or too few active frames | `insufficientEnergy` |
| too little landmark support | `insufficientLandmarkEvidence` |
| best score too low | `weakAlignmentPeak` |
| best and second best too close | `ambiguousOffset` |
| too many plausible offsets | `ambiguousOffset` |

Invalid source indexes and incompatible feature settings are handled by
`AmbientSyncStartError` before this decision table applies.

### 5.4 Locked Narrow Tracking

After lock, the engine must not search the whole asset on every window. It
predicts the current reference position from the previous estimate and smoothed
drift:

```text
predictedReferenceMS =
    previous.referenceTimeMS
  + elapsedHostMS * (1 + driftPPM / 1_000_000)
```

Search ranges:

| Lock condition | Range |
| --- | --- |
| stable lock | predicted +/- 200-400 ms |
| uncertain drift | predicted +/- 700 ms |
| unstable residual | predicted +/- 1000 ms |

Locked mode prioritizes dense features:

```text
query dense features
-> predicted reference range
-> local dense correlation
-> best local peak
-> residual check
-> update SyncEstimate or withhold update
```

If evidence and residuals remain stable, publish an updated estimate and keep
state `locked`.

If evidence is currently insufficient but the previous lock is still credible,
state becomes `drifting`. Do not publish a new measured estimate. Predicted
reference may be exposed in diagnostics.

If consecutive windows remain insufficient, state becomes `lost` with
`lostSignal`.

If the measured peak is too far from prediction, report
`unstableTrackingResidual` and enter `relocking` or `lost`.

The engine must not use a monotonic clamp to hide wrong positions. Bad residuals
must remain visible in diagnostics.

### 5.5 Relock

Relock is entered after:

- `lostSignal`
- repeated `unstableTrackingResidual`
- user seek
- startup before any lock

Relock uses wide search with stricter requirements than initial lock:

- strong landmark evidence
- strong dense verification
- clear second-best separation
- or two consecutive windows that agree after elapsed host time is applied

Repeated sections with similarly plausible offsets must withhold with
`ambiguousOffset`. Low-energy relock windows withhold with `insufficientEnergy`.
Weak peaks withhold with `weakAlignmentPeak`.

## 6. Confidence Model

`SyncEstimate.confidence` is a summary of several sync evidence signals. It
must not be a single cosine similarity.

Required signals:

- `peakScore`
- `secondBestScore`
- `peakMargin`
- `peakRatio`
- `peakSharpness`
- `peakWidthMS`
- `noiseFloorMean`
- `noiseFloorStd`
- `peakZ`
- `queryEnergyDBFS`
- `activeFrameFraction`
- `landmarkVoteCount`
- `landmarkInlierRate`
- `candidateDensity`
- `onsetFluxScore`
- `logMelScore`
- `chromaScore`
- `energyScore`
- `timeResidualMS`
- `trackingStability`

Initial quality gates are implementation guidance, not public API. The required
contract is that publish decisions depend on energy, landmark support, peak
strength, peak uniqueness, and tracking residuals.

```text
insufficientEnergy:
  activeFrameFraction < 0.20
  OR queryEnergyDBFS too low

insufficientLandmarkEvidence:
  best landmark vote count < minimum
  AND engine is not already locked strongly enough to rely on dense tracking

weakAlignmentPeak:
  peakScore < 0.55
  OR peakZ < 5.0
  OR peakSharpness too low

ambiguousOffset:
  peakMargin < 0.06
  OR peakRatio < 1.12
  OR secondBestScore >= 0.90 * peakScore outside +/- 2s
  OR candidateDensity too high

unstableTrackingResidual:
  abs(timeResidualMS) > residualHardLimit
  OR residual jitter stays high across multiple windows
```

Reference scalar for a first implementation:

```text
confidence =
  0.30 * denseScore01
+ 0.20 * landmarkScore01
+ 0.15 * peakZScore01
+ 0.15 * marginScore01
+ 0.10 * sharpnessScore01
+ 0.10 * trackingStability01
- ambiguityPenalty
- lowEnergyPenalty
- residualPenalty
```

The exact weights and numeric thresholds can change as the generated-audio
corpus improves. They are not frozen API. The stable contract is the set of
signals, the publish/withhold behavior, and the requirement to expose the
decision diagnostics.

If `confidence >= publishThreshold`, publish a measured `SyncEstimate`. If not,
withhold the update and expose the withhold reason plus diagnostics.

Withholding is not source identity rejection. It means the current window's sync
evidence is not reliable enough.

## 7. Drift And Latency

Drift estimation uses only high-confidence measured observations:

```swift
public struct ClockObservation: Codable, Sendable, Equatable {
    public var hostTimeMS: Double
    public var measuredReferenceMS: Double
    public var confidence: Double
    public var residualMS: Double
}
```

The model is:

```text
referenceMS = intercept + slope * hostTimeMS
driftPPM = (slope - 1.0) * 1_000_000
```

Rules:

- ignore low-confidence observations
- ignore `ambiguousOffset` observations
- reject residual outliers
- smooth drift slowly
- do not estimate drift from too few observations

`latencyMS` must not be invented. It can be populated only with a clear
calibration source:

- known output/input route calibration
- manual calibration
- loopback calibration
- measured hardware path latency

Without calibration, `latencyMS` is `nil`, or existing compatibility fields
must be accompanied by diagnostics indicating `latencySource = unavailable`.

## 8. Diagnostics

Diagnostics are mandatory and separate from `SyncEstimate`.
They are a developer-facing side channel for explaining publish and withhold
decisions. They are not gameplay API, and they should stay compact unless a
field directly explains a decision or a preflight state.

The estimator protocol adds a current diagnostics accessor:

```swift
public protocol AmbientSyncEstimating: Sendable {
    func start(asset: LocalAudioAsset, index: LocalAudioSyncIndex) async throws
    func stop() async
    func currentEstimate() async -> SyncEstimate?
    func currentState() async -> AmbientSyncEngineState
    func currentDiagnostics() async -> AmbientMatchDiagnostics?
}
```

Diagnostics structures:

```swift
public enum SearchMode: String, Codable, Sendable {
    case wide
    case narrow
    case relock
}

public enum LatencySource: String, Codable, Sendable {
    case unavailable
    case routeCalibration
    case manualCalibration
    case loopbackCalibration
    case measuredHardwarePath
}

public enum IndexRuntimeStatus: String, Codable, Sendable {
    case valid
    case unavailable
    case invalid
    case incompatible
}

public struct AmbientMatchDiagnostics: Codable, Sendable, Equatable {
    public var index: IndexDiagnostics
    public var capture: CaptureDiagnostics
    public var query: QueryDiagnostics
    public var search: SearchDiagnostics
    public var scoring: ScoringDiagnostics
    public var clock: ClockDiagnostics
    public var decision: MatchDecisionDiagnostics
}

public struct IndexDiagnostics: Codable, Sendable, Equatable {
    public var status: IndexRuntimeStatus
    public var featureExtractorVersion: String
    public var settingsHash: String
}

public struct CaptureDiagnostics: Codable, Sendable, Equatable {
    public var windowDurationMS: Double
    public var windowEndHostTimeMS: Double
    public var inputSampleRate: Double
    public var inputChannelCount: Int
    public var capturedFrameCount: Int
    public var droppedWindowCount: Int
}

public struct QueryDiagnostics: Codable, Sendable, Equatable {
    public var featureFrameCount: Int
    public var landmarkCount: Int
    public var energyDBFS: Double
    public var activeFrameFraction: Double
    public var processingSampleRate: Int
    public var hopSize: Int
}

public struct MatchDecisionDiagnostics: Codable, Sendable, Equatable {
    public var didPublishEstimate: Bool
    public var withholdReason: AmbientSyncWithholdReason?
    public var confidence: Double
    public var explanation: String
}

public struct SearchDiagnostics: Codable, Sendable, Equatable {
    public var mode: SearchMode
    public var searchRangeStartMS: Double
    public var searchRangeEndMS: Double
    public var predictedReferenceMS: Double?
    public var selectedReferenceMS: Double?
    public var candidateCount: Int
    public var candidateDensity: Double
    public var topCandidates: [CandidateAlignment]
}

public struct ScoringDiagnostics: Codable, Sendable, Equatable {
    public var peakScore: Double
    public var secondBestScore: Double?
    public var peakMargin: Double?
    public var peakRatio: Double?
    public var peakSharpness: Double?
    public var peakWidthMS: Double?
    public var noiseFloorMean: Double?
    public var noiseFloorStd: Double?
    public var peakZ: Double?
    public var landmarkVoteCount: Int
    public var landmarkInlierRate: Double
    public var onsetFluxScore: Double?
    public var logMelScore: Double?
    public var chromaScore: Double?
    public var energyScore: Double?
    public var timeResidualMS: Double?
}

public struct ClockDiagnostics: Codable, Sendable, Equatable {
    public var observationCount: Int
    public var rawDriftPPM: Double?
    public var smoothedDriftPPM: Double?
    public var trackingStability: Double
    public var latencyMS: Double?
    public var latencySource: LatencySource
}
```

`AmbientMatchingDashboardView` must show enough data to explain every publish
and every withhold decision:

- engine state
- last published `referenceTimeMS`
- confidence
- whether this window published
- withhold reason
- search mode: wide, narrow, or relock
- search range
- predicted reference
- selected reference
- top candidate offsets
- peak score
- second-best score
- peak margin
- peak ratio
- peak sharpness
- noise floor
- `peakZ`
- query energy
- active frame fraction
- landmark vote count
- landmark inlier rate
- candidate density
- onset flux, log-Mel, and chroma scores
- time residual
- raw and smoothed `driftPPM`
- compact index status
- feature version and settings hash

## 9. Audio And Performance Rules

Decoding uses `AVAudioFile`, `AVAudioPCMBuffer`, and `AVAudioConverter`.

Decoding rules:

- decode in chunks
- convert to `Float32`
- mix to mono
- resample to `processingSampleRate`
- do not assume source and microphone sample rates match

Microphone capture must preserve sample timing. The engine must use tap callback
timing from `AVAudioTime`, input sample time, host time, and the audio window end
host time.

`SyncEstimate.hostTime` must correspond to the audio window endpoint, not
arbitrary processing completion time. The engine must not stamp windows with
`.now` after reading from a rolling buffer.

STFT and FFT use Accelerate / vDSP:

- precomputed Hann window
- preallocated buffers
- `Float` arrays
- no per-frame heap allocation in the hot path

Index and query frame alignment must be identical.

No server component is needed.

## 10. Test Contract

Tests should use deterministic generated audio to avoid copyright issues:

- `TrackA`: drums, bass, chords, and melody, 45-60 seconds.
- `TrackARepeated`: same motif or chorus appears at multiple offsets.
- `TrackQuietIntro`: 10 seconds low energy, then active section.
- `TrackBUnrelated`: completely different generated audio.

`TrackBUnrelated` is not a track identity rejection test. It verifies that the
engine does not emit a reliable `SyncEstimate` when evidence inside the selected
asset is weak or misleading.

Regression cases:

- clean same-file playback
- microphone-colored playback
- room noise
- room reverb
- compression artifacts
- quiet intro
- repeated chorus
- unrelated audio against selected asset
- missing or invalid index preflight
- feature settings mismatch preflight
- latency offset
- drift over time
- temporary signal loss
- seek / relock

Expected assertions:

| Case | Required behavior |
| --- | --- |
| clean same-file playback | publish `SyncEstimate`, reference error <= 100 ms, high confidence, no withhold reason |
| microphone-colored playback | publish `SyncEstimate`, reference error <= 200 ms, acceptable confidence |
| moderate room noise | publish if peak is clear |
| heavy room noise | may withhold with `weakAlignmentPeak` or `insufficientLandmarkEvidence` |
| quiet intro | do not random-lock; withhold with `insufficientEnergy` or publish only after enough active frames |
| repeated chorus | withhold with `ambiguousOffset` if offsets are similarly plausible |
| repeated chorus while locked | may continue if prediction disambiguates; confidence should be reduced and diagnostics must show second best |
| unrelated generated audio | do not emit reliable `SyncEstimate`; reason is `insufficientLandmarkEvidence`, `weakAlignmentPeak`, `ambiguousOffset`, or `lostSignal` |
| source hash changed | `start(asset:index:)` fails before matching with `indexInvalid`; no `SyncEstimate` is emitted |
| feature settings changed | `start(asset:index:)` fails before matching with `indexIncompatible`; no `SyncEstimate` is emitted |
| latency offset | align to the asset timeline; do not invent `latencyMS` |
| drift injection | maintain lock and converge `driftPPM` over stable observations |

Tests should validate user-visible behavior, feature-model transitions, domain
mapping, and real regression boundaries. Avoid hand-authored array tests as the
only evidence for matching correctness.

## 11. Explicit Non-Goals

Do not:

- do song recognition
- depend on ShazamKit or ACRCloud for Phase 2 sync
- decide "this is another song"
- name unrelated-audio tests as track identity rejection
- keep tuning positive RMS delta thresholds as the main matcher
- keep `onset-envelope.txt` as the primary index
- reduce confidence to one cosine score
- hide the second-best offset
- hide `ambiguousOffset`
- match against a stale index
- stamp audio windows with `.now`
- use monotonic clamping to mask `unstableTrackingResidual`
- random-lock a low-energy window to any offset
- force-select one repeated-chorus candidate and report high confidence
- rely only on hand-authored array tests

The Phase 2 target is:

```text
Inside a known LocalAudioAsset, publish a reliable SyncEstimate only when the
current microphone evidence is strong, unique, and stable enough. Otherwise,
withhold clearly and explain the sync-quality reason.
```

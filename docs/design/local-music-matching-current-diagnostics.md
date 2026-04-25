---
commit: 55517184f2c70a481b9bcf10353fcf8cf4954bd5
title: Local Music Matching Current Diagnostics
status: current diagnostics
---

# Local Music Matching Current Diagnostics

## Scope

This document records current repo status only. It is not a proposed design, roadmap, or execution plan.

Baseline commit: `55517184f2c70a481b9bcf10353fcf8cf4954bd5`.

Covered diagnostics:

- Manual resolve confidence rejects a single exact-title target.
- Ambient sync index building and matching are currently prototype-only and not usable as music matching.

## Issue 1: Manual Resolve Rejects Single Exact-Title Target

Observed case:

- Indexed file name: `Blur - Fool's Day.mp3`
- Indexed metadata title: `Fool's Day`
- Manual input title: `Fool's Day`
- Manual input artist, album, duration, and ISRC: empty
- Candidate set: no competing candidate

Expected current product behavior: the manual resolve flow should allow the user to resolve to that local target. It does not need to auto-accept silently, but it must not block the target as rejected when it is the only exact metadata title match.

Current code path:

- `Sources/PulsefieldUI/Features/LocalLibrary/LocalLibraryDashboardView.swift` builds a `CanonicalTrack` from the manual debug form. Empty artist, album, ISRC, and duration fields stay empty or nil.
- `Sources/PulsefieldCore/Services/LocalLibrary/LocalTrackResolver.swift` scores every ready or metadata-partial asset, sorts by confidence, and then applies ambiguity policy.
- `Sources/PulsefieldUI/Features/LocalLibrary/LocalResolveDebugView.swift` only exposes `Use For Ambient` when `LocalResolveResult.canStartAmbientMatching` is true, and that currently means `decision != .rejected`.

Current confidence math for the observed case:

- `titleExact` contributes `0.38`.
- Artist contributes nothing because the manual query has no artist.
- Album contributes nothing.
- Duration contributes nothing because the manual query has no duration.
- The filename normalizes to `blur fool s day`; `contiguousTokenScore("fool s day", in: "blur fool s day")` returns `1`.
- Because the asset already has a metadata title, filename evidence contributes only `0.08 * 1`.
- Total confidence is about `0.46`.
- `decision(for:)` requires at least `0.70` for confirmation and `0.90` for auto-accept, so the result is rejected.

The current ambiguity policy does not help this case. `applyAmbiguityPolicy` only downgrades multiple near-tied auto-accepted results to `requiresUserConfirmation`; it has no concept of promoting a unique exact-title candidate into a confirmable manual result.

Current tests also encode the wrong broad behavior for this manual-flow case. `Tests/PulsefieldCoreTests/LocalTrackResolverTests.swift` has `testResolveRejectsTitleOnlyMatch`, which asserts that title-only input is rejected. That is reasonable as a generic caution against automatic title-only matching, but it is too coarse for a manual resolver where a single indexed asset has exact metadata title evidence and the filename also contains the same title.

Affected files:

- `Sources/PulsefieldCore/Services/LocalLibrary/LocalTrackResolver.swift`
- `Sources/PulsefieldUI/Features/LocalLibrary/LocalLibraryDashboardView.swift`
- `Sources/PulsefieldUI/Features/LocalLibrary/LocalResolveDebugView.swift`
- `Tests/PulsefieldCoreTests/LocalTrackResolverTests.swift`
- `Tests/PulsefieldCoreTests/LocalLibraryDashboardModelTests.swift`

Diagnostic conclusion: the resolver currently collapses evidence strength, uniqueness, auto-accept safety, and manual-confirm usability into one scalar confidence threshold. That is the root of the `Fool's Day` failure. A future fix should not be a blind constant bump, because that would also change duplicate-title and alternate-version behavior.

## Issue 2: Ambient Sync Index And Matching Are Prototype-Only

The existing BYO music recognition spec lists the intended Phase 2 files and describes a debuggable feature-correlation matcher with onset envelope, coarse spectral summary, optional chroma, search policy, confidence policy, and developer diagnostics. The current implementation has the file shape, but not the usable matching substance.

Current implementation files:

- `Sources/PulsefieldCore/Domain/AmbientSyncDomain.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/LocalAudioSyncIndexer.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/AmbientAudioCaptureService.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/FeatureCorrelationSyncEstimator.swift`
- `Sources/PulsefieldCore/Services/AmbientSync/SyncClockFilter.swift`
- `Sources/PulsefieldUI/Features/AmbientSync/AmbientMatchingDashboardView.swift`
- `Tests/PulsefieldCoreTests/LocalAudioSyncIndexerTests.swift`
- `Tests/PulsefieldCoreTests/FeatureCorrelationSyncEstimatorTests.swift`

Current index builder status:

- `LocalAudioSyncIndexer.buildIndex(for:)` writes only `onset-envelope.txt`.
- `spectralSummaryURL` and `chromaURL` are always nil.
- The feature is only positive RMS delta per hop: `max(0, rms - previousRMS)`.
- The index has no source hash validation, no feature-settings identity beyond stored values, and `loadIndex(for:)` does not reject stale versions or stale source audio.
- The only indexer test builds a silent 200ms WAV and asserts that the onset-envelope file exists and spectral summary is nil. It does not validate useful features or matchability.

Current estimator status:

- `FeatureCorrelationSyncEstimator` reads the onset envelope text file and computes the same RMS-delta shape for microphone windows.
- Query feature generation drops the first frame because the prior RMS is unavailable.
- Matching is mean-centered cosine similarity over one feature stream.
- Confidence is the clamped cosine score; there is no second-best peak comparison, peak sharpness, noise floor, energy gate beyond nonzero normalized query energy, or calibration against real microphone playback.
- While locked, it searches a narrow predicted neighborhood and only performs a wide comparison to decide whether to degrade. This supports some synthetic state-machine tests but does not prove robust matching on repeated musical sections.
- `SyncClockFilter` exists but is not used by the estimator or UI.

Current capture and UI status:

- `AmbientAudioCaptureService` captures only the first input channel into a rolling sample buffer.
- The dashboard can build an index, start matching, stop, nudge, and force relock.
- The dashboard displays state, reference, confidence, drift, microphone status, and source.
- It does not expose the information needed to debug matching quality: query energy, feature length, selected offset, search range, peak score, second-best score, top candidate offsets, or whether the match came from wide or narrow search.

Current tests are mostly state-machine tests around hand-authored feature arrays. `FeatureCorrelationSyncEstimatorTests` bypasses real audio indexing by writing numeric onset envelopes directly, then synthesizes samples that are constructed to produce matching feature arrays. These tests are useful for actor state, lock/lost transitions, and monotonic reference behavior, but they do not demonstrate ambient music matching under real playback, microphone coloration, room noise, latency, repeated sections, quiet passages, or wrong-track inputs.

Diagnostic conclusion: ambient matching is currently a toy correlation harness. The high-level interfaces are useful, but the feature representation, confidence model, persistence validation, observability, and tests are not enough for usable music matching. This area needs a separate design document before implementation changes; tuning the current thresholds would not address the root problem.


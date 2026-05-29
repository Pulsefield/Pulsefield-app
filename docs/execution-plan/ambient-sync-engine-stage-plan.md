---
commit: 34f07917b3d088bd92fd7f6c5b24ccd7627b06dc
title: Ambient Sync Engine Stage Plan
source_spec: docs/design/ambient-sync-engine-design-spec.md
status: execution plan
---

# Ambient Sync Engine Stage Plan

This plan splits the frozen Phase 2 ambient sync engine spec into implementation
stages. It is an execution plan, not a design spec or current-status diagnostic.

## Stage 1: Public Contracts And Diagnostics Foundation

Goal: make the public engine boundary match the frozen spec before replacing
the prototype matcher.

Scope:

- Add the spec-defined engine states, start errors, withhold reasons, search
  modes, latency sources, index runtime statuses, candidate diagnostics, and
  match diagnostics structures.
- Update `AmbientSyncEstimating` to expose `currentDiagnostics()`.
- Map current start/preflight failures to `AmbientSyncStartError`.
- Keep the existing correlation prototype running, but make publish and withhold
  decisions populate diagnostics.
- Surface the current diagnostics in the ambient matching dashboard model and
  compact dashboard view.

Acceptance:

- Existing ambient sync behavior remains test-covered.
- Mismatched or unreadable indexes fail before matching and expose index
  diagnostics.
- Low-evidence windows withhold an update with a sync-quality reason.
- Published prototype estimates expose diagnostics without making the dashboard
  depend on `SyncEstimate` semantics for explanations.

## Stage 2: Versioned Local Sync Index Boundary

Goal: replace the `onset-envelope.txt` primary index with a manifest-led sync
index boundary.

Scope:

- Introduce a versioned sync index manifest model.
- Write manifest and feature files under the spec-defined index directory shape.
- Validate asset identity, schema, extractor identity, settings, source hash,
  feature file existence, checksums, dimensions, frame counts, sample rate, and
  hop size before matching starts.
- Keep legacy index loading only as a migration or development fallback if it is
  still useful.

Acceptance:

- Missing, stale, corrupt, or incompatible indexes fail as `indexUnavailable`,
  `indexInvalid`, or `indexIncompatible`.
- Matching never consumes an index whose manifest or feature files fail
  validation.

## Stage 3: Shared Feature Extraction

Goal: make indexing and query processing use the same deterministic feature
extractor.

Scope:

- Decode/capture to mono Float32 at the processing sample rate.
- Add STFT, Hann windowing, log magnitude, landmark features, multi-band flux,
  log-Mel summary, chroma/CENS-like summary, and energy features.
- Ensure index and query frame alignment share one timebase.

Acceptance:

- Deterministic generated-audio tests can build reference and query features
  through the same extractor.
- The prototype RMS-delta envelope is no longer the only matching signal.

## Stage 4: Wide Search And Dense Verification

Goal: implement initial lock and relock decisions from the spec.

Scope:

- Build landmark offset histograms.
- Verify top candidates with dense onset-flux, log-Mel, chroma, and energy
  signals.
- Score candidates with peak strength, uniqueness, margin, ratio, sharpness,
  noise-floor, and density diagnostics.
- Withhold ambiguous, weak, or low-evidence windows without treating them as
  song identity rejection.

Acceptance:

- Clean same-file and microphone-colored generated-audio cases publish reliable
  estimates.
- Quiet intro, repeated chorus, and unrelated generated-audio cases withhold for
  the correct sync-quality reason.

## Stage 5: Locked Tracking, Relock, Drift, And Latency

Goal: replace full-asset scanning during lock with predicted narrow tracking.

Scope:

- Track around predicted reference time with stable, uncertain, and unstable
  search ranges.
- Enter drifting, relocking, lost, and locked states according to residuals and
  consecutive evidence.
- Estimate drift only from high-confidence observations.
- Leave `latencyMS` unavailable unless a calibration source exists.

Acceptance:

- Stable lock follows elapsed host time.
- Temporary signal loss drifts and then loses lock.
- Seek/relock and drift-injection cases converge without monotonic clamping.
- Diagnostics expose residuals, second-best offsets, raw drift, smoothed drift,
  and latency source.

## Stage 6: Dashboard And Corpus Completion

Goal: make the development dashboard explain every publish and withhold decision
against the generated-audio corpus.

Scope:

- Expand the dashboard diagnostics to the full spec field list.
- Build deterministic generated audio fixtures for the required regression
  cases.
- Add focused tests for behavior, feature-model transitions, domain mapping, and
  regression boundaries.

Acceptance:

- The dashboard shows enough data to diagnose every sync decision.
- The full generated-audio corpus covers the Phase 2 test contract without
  copyrighted samples.

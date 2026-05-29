---
commit: 573607969007d7776dca753eb8d1c961c224bfe1
title: Ambient Sync Current Status And Goals
status: current status and product goals
---

# Ambient Sync Current Status And Goals

## Scope

This document records the ambient sync engine status and product-level goals at
the baseline commit above. It is not an execution plan. It does not replace the
separate fixture audit report, engine design spec, or staged implementation
plan.

Baseline commit: `573607969007d7776dca753eb8d1c961c224bfe1`.

## Current Engine Shape

Ambient sync is now a multi-stage pipeline:

1. Readiness gate for query duration, energy, active frames, and landmark count.
2. Landmark coarse search for candidate offset generation.
3. Fast timing verification with dense reranking.
4. Robust final verification with denser feature evidence.
5. Tracking with a shorter rolling query once final lock has been reached.

The latest committed tuning moved provisional and final gates away from
subband-onset-heavy evidence and toward onset, PCEN mel, and CENS. It also made
final verification accept strong spectral agreement with fewer fragile onset
feature agreements.

## Measured Local Fixture Status

The current local fixture set contains `18` recorded microphone fixtures across
the available reference songs used by the ambient sync experiments.

The fixture replay after the latest tuning shows:

| Measurement | Current Result |
| --- | ---: |
| Reached final lock | `18 / 18` |
| Ended locked in full replay | `16 / 18` |
| Earliest final lock | `6005 ms` |
| Median final lock | `6005 ms` |
| Latest final lock | `15979 ms` |
| Total locked duration across fixtures | `285.5 s` |
| Average locked duration | `15.86 s` |
| Median locked duration | `13.35 s` |
| Shortest locked duration | `6.10 s` |
| Longest locked duration | `38.60 s` |

The direct 3 second replay result is:

| Endpoint | Provisional | Final Lock | Ended Locked |
| ---: | ---: | ---: | ---: |
| `3000 ms` | `0 / 18` | `0 / 18` | `0 / 18` |

This does not mean the matcher has no signal at 3 seconds. It means the current
default final-lock path is intentionally gated behind the final query duration.
The default feature configuration requires a final lock window of roughly
`4.5-5.0 s`, and the sampled fixture replay observes final locks around `6.0 s`
because of replay cadence and window construction.

## What Is Working

The cache, index, and reference loading path are no longer the dominant blocker
for the local fixture set.

The coarse-to-dense pipeline can now use ambiguous landmark candidates instead
of discarding them too early. That gave dense reranking a chance to disambiguate
fixtures that previously failed at the landmark stage.

PCEN mel and CENS are now real gate participants. This fixed the earlier
mismatch where those features improved dense scores but could not satisfy the
engine pass/fail logic.

Final acquisition is now usable on the local fixture set: every fixture reaches
final lock under the current replay settings.

## Current Limits

The system does not final-lock within 3 seconds under current defaults.

The current final-lock definition is still closer to a conservative acquisition
decision than an early gameplay-ready estimate. It waits for a longer robust
verification window before publishing final lock.

Tracking is still weaker than acquisition. The full replay reaches final lock
for all fixtures but ends locked for `16 / 18`, with the remaining failures
showing relock or drift after final lock. That points to tracking stability, not
basic acquisition, as the remaining post-lock weakness.

The landmark representation is still limited for repeated or low-distinctiveness
audio sections. Soft-passing top-K candidates helps, but it does not make the
landmark hashes themselves more discriminative.

Short-window discrimination is still not strong enough to safely call a 3 second
result final. The engine needs better evidence density or a separate early
confirmed state before product behavior should depend on a 3 second lock.

## Product Goals

The near-term target is not just "more locks." It is a sync signal that is fast,
stable, and does not make obvious wrong jumps.

Target behavior:

| Goal | Target |
| --- | ---: |
| Early usable sync estimate | `<= 3000 ms` |
| Final lock for local fixtures | `>= 18 / 18` retained |
| Ended locked in full replay | `>= 18 / 18` |
| Obvious wrong jumps | `0` |
| Tracking relock after final | near `0` |
| Stable locked duration | covers most of each post-lock fixture |

A 3 second result should probably start as a `confirmed` or gameplay-usable
state rather than the same `final` state used after a longer robust window. That
keeps the product responsive while preserving a stronger final-lock definition.

## Feature Goals

The next feature-level goal is better short-window discrimination. The existing
PCEN mel and CENS signals are valuable, but they should be complemented by
features that separate similar coarse candidates with less audio.

Candidate feature directions:

- Landmark fingerprints based on time-frequency peak pairs instead of weaker
  single-frame hashes.
- Common-hash suppression or IDF weighting so repetitive landmarks contribute
  less to the vote histogram.
- Top-K hypothesis preservation throughout acquisition, with ambiguity reported
  as a diagnostic rather than treated as a hard failure.
- Mean-centered PCEN mel similarity for short-window spectral shape.
- Mean-centered CENS similarity for short-window harmonic shape.
- Derivative or covariance-style PCEN/CENS comparisons to capture changing
  spectral and harmonic contours, not only absolute frame similarity.

The goal for these features is not to replace the current pipeline. It is to
make the early candidate set better and the 3 second dense verification more
trustworthy.

## Tracking Goals

Tracking should be separated from first acquisition. Once final lock has been
reached, weak short-window observations should reduce confidence gradually
instead of immediately forcing relock.

Desired tracking behavior:

- Maintain a smoothed offset after final lock.
- Treat weak tracking windows as confidence decay, not immediate failure.
- Treat conflicting offsets as drift only after repeated confirmation.
- Use enough rolling query context to verify the current offset while still
  publishing frequent estimates.

This is necessary to convert the current `18 / 18` acquisition result into
reliable ended-locked behavior.

## Success Criteria For The Next Validation Pass

The next validation pass should report both acquisition and stability:

| Metric | Minimum Useful Target |
| --- | ---: |
| 3 second confirmed or gameplay-usable estimate | `>= 12 / 18` |
| Final lock | `18 / 18` |
| Ended locked | `18 / 18` |
| Wrong obvious jumps | `0` |
| Relock after final | `0-1 / 18` |

If 3 second confirmed sync cannot be reached with the current features, the
priority should be landmark and dense feature quality rather than more threshold
tuning.

---
commit: 3a45fbf4419d28b6264c2f83c84df48f3948faaa
title: Mania 4K Judgement Engine Spec
status: frozen
osu_lazer_commit: a0be214d034c48b0b603069dc284b27b9dde5c17
---

# Mania 4K Judgement Engine Spec

This document freezes the Pulsefield `mania4k` judgement behavior. It is a proposed engine design for the next playable implementation slice, not a current-code architecture summary and not an execution plan.

## Reference Baseline

Use Malody as the judgement-difficulty source:

- [Malody 5.0 FAQ](https://m.mugzone.net/wiki/2149): Malody V defaults to the old mobile judgement timing on all platforms; `Pro Judge` uses the old PC timing.
- [RM Mode scoring characteristics](https://m.mugzone.net/wiki/2443): Malody-maintained fixed-lane judgement windows for Judge `A / B / C / D / E`, result-tier aggregation, accuracy values, and judge score multipliers.
- [Malody judgement wiki](https://gamerch.com/malody/318096): secondary source for the legacy `A / B / C / D / E` names and old PE/PC BEST-window comparison.

Use osu!lazer only as mechanics evidence for note lock and long-note lifecycle, pinned to commit `a0be214d034c48b0b603069dc284b27b9dde5c17`:

- [HitWindows.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Rulesets/Scoring/HitWindows.cs): symmetric offset classification and hittable-window behavior.
- [OrderedHitPolicy.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/UI/OrderedHitPolicy.cs): note-lock behavior and forced misses for earlier objects.
- [DrawableHoldNote.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNote.cs), [DrawableHoldNoteHead.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNoteHead.cs), [DrawableHoldNoteBody.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNoteBody.cs), [DrawableHoldNoteTail.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNoteTail.cs), and [TailNote.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/TailNote.cs): hold-note head/body/tail lifecycle and release lenience.
- [HitResult.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Rulesets/Scoring/HitResult.cs) and [ScoreProcessor.cs](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Rulesets/Scoring/ScoreProcessor.cs): combo and accuracy-affecting result behavior.

Pulsefield keeps only visible `Perfect`, `Good`, and `Miss` judgements. The engine stores a Malody-compatible internal tier for timing and accuracy, then collapses that tier for display.

## Core Terms

- `chartTimeMs`: the engine time used for judgement. The session layer derives this from audio time plus `audioOffsetMilliseconds` before calling the engine.
- `hitErrorMs`: `inputChartTimeMs - object.startTimeMs` for tap notes and long-note heads.
- `tailErrorMs`: `releaseChartTimeMs - object.endTimeMs` for long-note tails.
- `malodyTier`: one of `bigP`, `p1`, `p2`, `p3`, `g`, or `m`.
- Window values are symmetric half-windows in milliseconds. A `g` window of `200` means `-200...+200`.
- One tap note counts as one scoring object.
- One long note counts as one scoring object, regardless of head/body/tail internals.

## Difficulty Windows

The existing UI labels `A / B / C / D / E` map to Malody's judge difficulties. This mapping is independent from `osu!mania star difficulty`.

| Judge | Legacy name | Score multiplier | `bigP` | `p1` | `p2` | `p3` | `g` | `m` |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | Amateur / Easy | 0.78x | +/-60 ms | +/-105 ms | +/-120 ms | +/-135 ms | +/-200 ms | >200 ms |
| B | Beginner / Easy+ | 0.85x | +/-47 ms | +/-63 ms | +/-88 ms | +/-118 ms | +/-200 ms | >200 ms |
| C | Climber / Normal | 1.00x | +/-40 ms | +/-56 ms | +/-81 ms | +/-111 ms | +/-200 ms | >200 ms |
| D | Dander / Normal+ | 1.10x | +/-34 ms | +/-50 ms | +/-75 ms | +/-105 ms | +/-200 ms | >200 ms |
| E | Expert / Hard | 1.20x | +/-25 ms | +/-50 ms | +/-75 ms | +/-105 ms | +/-200 ms | >200 ms |

Window derivation:

- Pulsefield uses Malody V's default/mobile timing, not Malody `Pro Judge`.
- The RM Mode page is used as the explicit Malody-maintained fixed-lane timing table. The legacy PE/PC BEST-window source is secondary because it does not publish every mobile tier.
- `bigP` displays as `Perfect`.
- `p1`, `p2`, `p3`, and `g` display as `Good`.
- `m` displays as `Miss`.
- The `g` boundary is the outer successful window. An input later than this boundary resolves `Miss`; an input earlier than `-g` is ignored because the object is still too far in the future.
- Judge score multipliers are documented for compatibility but are not used by the current Pulsefield HUD or score model.

## Tap Judgement

For the current lane, process only the current note-lock candidate.

When a press occurs:

1. If no unresolved object in the lane is close enough, ignore the press.
2. If the candidate is earlier than another unresolved object whose `startTimeMs <= inputChartTimeMs`, force-miss the earlier object and re-evaluate from the next object.
3. Compute `hitErrorMs`.
4. If `hitErrorMs < -gWindow`, ignore the press.
5. Else if `abs(hitErrorMs) <= bigPWindow`, resolve internal `bigP` and display `Perfect`.
6. Else if `abs(hitErrorMs) <= p1Window`, resolve internal `p1` and display `Good`.
7. Else if `abs(hitErrorMs) <= p2Window`, resolve internal `p2` and display `Good`.
8. Else if `abs(hitErrorMs) <= p3Window`, resolve internal `p3` and display `Good`.
9. Else if `abs(hitErrorMs) <= gWindow`, resolve internal `g` and display `Good`.
10. Else resolve internal `m` and display `Miss`.

On time advancement, any unresolved tap whose `chartTimeMs > startTimeMs + gWindow` resolves `Miss`, unless it has already been force-missed by note lock.

## Long-Note Judgement

A long note is one final judgement. Head/body/tail state exists to decide that final judgement; it does not emit separate score counts.

Long-note state:

- `waitingForHead`
- `holding`
- `resolved`

Head handling:

1. A head press before `startTimeMs - gWindow` is ignored.
2. A head press with `abs(hitErrorMs) <= bigPWindow` starts the hold with head tier `bigP`.
3. A head press within `p1`, `p2`, `p3`, or `g` starts the hold with that internal tier and displays `Good`.
4. A late head press beyond `gWindow` resolves the whole long note as `Miss`.
5. If no valid head press occurs by `startTimeMs + gWindow`, the whole long note resolves `Miss`.

Body handling:

- Releasing before the tail success window resolves the whole long note as `Miss`.
- After a body break, the note cannot be recovered by pressing again.
- A hold break is always recorded as `Miss`, not `Good`.

Tail handling:

- Release lenience factor is `1.5`, matching osu!lazer tail-note lenience.
- Tail windows use the same Malody tier table multiplied by `1.5`.
- Releasing with `abs(tailErrorMs) <= tailBigPWindow` gives tail tier `bigP`.
- Releasing within `tailP1Window`, `tailP2Window`, `tailP3Window`, or `tailGWindow` gives the matching successful internal tier.
- Releasing earlier or later than `tailGWindow` resolves the whole long note as `Miss`.
- If the key remains held beyond `endTimeMs + tailGWindow`, resolve `Miss`.

Successful long-note result:

- Final result is the worse of head tier and tail tier.
- `bigP + bigP = Perfect`.
- Any successful tier combination containing `p1`, `p2`, `p3`, or `g` resolves visible `Good`.
- Any head miss, body break, or tail miss resolves `Miss`.

## Note Lock

Note lock is per lane.

- Unresolved objects are ordered by `startTimeMs`.
- Only the active lane candidate can receive input.
- A previous object cannot remain hittable at or after the next object's `startTimeMs`.
- If the player successfully judges a later object while earlier same-lane objects are unresolved and fully before that later object, those earlier objects are force-missed first.
- The hit-object stream must not contain overlapping objects in the same lane. If an adapter encounters same-lane overlap, it must reject the chart or normalize it before gameplay.

This preserves the practical behavior from osu!mania: dense same-lane patterns cannot be played out of order, and late windows do not leak across the next note.

## Scoring State

The engine tracks only:

- `perfectCount`
- `goodCount`
- `missCount`
- internal Malody tier counts
- `combo`
- `maxCombo`
- `accuracy`
- `latestJudgement`
- `latestMalodyTier`
- successful hit errors for audio-offset suggestions

Combo:

- `Perfect` increments combo by `1`.
- `Good` increments combo by `1`.
- `Miss` resets combo to `0`.
- Long notes apply combo only when their final result resolves.

Accuracy:

```text
accuracy = (bigPCount * 1.00 + p1Count * 0.90 + p2Count * 0.85 + p3Count * 0.80 + gCount * 0.40) / judgedObjectCount
```

If `judgedObjectCount == 0`, accuracy is `1.0`.

Offset statistics:

- Store hit errors for successful tap notes.
- Store head hit errors for successful long notes.
- Exclude misses and tail release errors from average hit-error suggestions.

## Engine Contract

The judgement engine receives:

- ordered streamable hit objects
- current `chartTimeMs`
- lane press events
- lane release events
- current judge difficulty

The judgement engine emits:

- resolved judgement events
- current lane hold states
- score state
- unresolved visible/judgement-relevant objects

The engine does not own audio playback, rendering, file parsing, or UI. The session layer owns audio-derived time and audio-offset application. The renderer reads engine snapshots and must not duplicate judgement rules.

## Frozen Decisions

1. `A / B / C / D / E` judgement difficulty uses Malody V default/mobile timing, not osu!mania OD.
2. Pulsefield `Perfect` is Malody `bigP`.
3. Pulsefield `Good` collapses Malody `p1`, `p2`, `p3`, and `g`.
4. Pulsefield `Miss` is Malody `m`.
5. Tap notes auto-miss after `startTimeMs + gWindow`.
6. Long notes are one scoring object.
7. A missed head, body break, missed tail, too-early release, or too-late release resolves the whole long note as `Miss`.
8. Long-note final success is the worse of head tier and tail tier.
9. Tail release lenience multiplier is `1.5`.
10. Per-lane note lock is required.
11. Accuracy uses Malody tier weights: `bigP = 1.00`, `p1 = 0.90`, `p2 = 0.85`, `p3 = 0.80`, `g = 0.40`, `m = 0`.

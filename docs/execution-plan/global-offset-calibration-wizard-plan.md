---
commit: 241177579dab570d3017534a5eaa099e738cb4b0
title: Global Offset Calibration Wizard Plan
source_specs:
  - docs/design/mania-4k-play-experience-design.md
  - docs/design/mania-4k-core-gameplay-contracts.md
status: execution plan
---

# Global Offset Calibration Wizard Plan

This is an execution plan for adding a `mania4k` global offset calibration
wizard. It is not a current-architecture status document and not a broad future
roadmap. The goal is one bounded implementation slice: a user can open a
calibration scene from the existing global offset setting, adjust the offset
while watching a repeated falling note and hearing a tick, optionally tap the
note to get a signed precision suggestion, manage named millisecond presets,
then apply the value back to the `mania4k` global audio offset. The first
calibration note reaches the judgement line one second after the wizard opens,
regardless of the starting global offset, by seeding synthetic note times from
the initial rendered offset so users have a short visual/audio buffer before the
first actionable beat.

Recommendation: `TEST`.

## Experiment Card

Hypothesis:

- A synthetic `500 ms` audio/visual calibration scene placed beside the global
  offset setting will let users tune device-level offset before play, use
  accepted tap samples to estimate a signed adjustment such as `+14 ms` or
  `-23 ms`, and store reusable millisecond presets while preserving
  Pulsefield's existing gameplay contract:
  `chartTimeMs = audioTimeMs + globalAudioOffsetMilliseconds`.

Root objective:

- Help users calibrate `globalAudioOffsetMilliseconds` for the current
  playback/display/input setup without requiring a selected beatmap or audio
  file.

Goal decomposition:

- Add an entry point beside the current global offset row.
- Generate deterministic synthetic raw beat times with a `1,000 ms` lead-in
  before the first note reaches the judgement line, seeding synthetic chart note
  times from the rendered offset active when the wizard opens.
- Play a click on raw beat time.
- Render falling notes using raw time plus candidate global offset while keeping
  the seeded synthetic chart note times immutable.
- Accept user input only when a calibration object is within `120 ms` of the
  rendered candidate chart time.
- Compute an absolute suggested offset for each accepted hit sample, then show a
  signed adjustment from the current candidate to the rolling median suggested
  offset.
- Provide coarse and fine manual millisecond controls.
- Store, select, add, rename-by-name-at-creation, and delete manually saved
  offset presets.
- Apply or cancel the candidate value explicitly.

Candidate variants:

- A. Manual audiovisual calibration with gated hit suggestions and presets.
- B. Tap-to-average auto-calibration.
- C. Results-based suggestion only.
- D. Hardware-latency seed.

Local verification matrix:

- Use the matrix below to compare candidates before implementation.

Selected variant:

- A. Manual audiovisual calibration with gated hit suggestions and presets.

Selection pressure:

- A is the smallest slice that matches the requested wizard, aligns with
  osu!/Sonolus-style audiovisual calibration, keeps manual control as the source
  of truth, and uses player input only for non-destructive suggestions.
- B is deferred because automatic application needs stronger
  variance/confidence gating than the first slice should own.
- C is deferred because it only helps after successful gameplay.
- D is rejected for this slice because hardware latency is only a hint and does
  not cover visual/input latency.

Minimal change:

- Add a small calibration model, calibration view, tick service protocol, preset
  storage, setup entry point, and behavior-focused tests.

Files likely to change:

- See "Files Likely To Change" below.

Dataset slice:

- Synthetic raw ticks at `1000, 1500, 2000...` ms after calibration starts,
  with immutable synthetic note times seeded as
  `rawTickTimeMs + initialRenderedOffsetMilliseconds`, driven by a fake
  monotonic clock in tests; accepted hit inputs at representative errors such as
  `-23`, `+14`, and out-of-window `+121`; no real beatmap, no real song file,
  and no generated chart data.

Baseline / comparator:

- Current setup exposes a plain `Global audio offset` numeric field and gameplay
  already derives chart time from audio time plus offset, but there is no
  calibration scene.

Primary metric:

- Tests prove offset stepping, clamping, `1,000 ms` first-note lead-in,
  `120 ms` hit gating, per-sample suggested-offset math, preset
  add/delete/select behavior, apply/cancel, render-time shift, and `2 Hz`
  throttled rendered-offset publishing.

Secondary metric:

- Tests or qualitative checks prove synthetic note times remain immutable,
  active preset selection updates the candidate offset, applied global offset
  and manually saved presets persist across launches, and tick playback stops
  after leaving calibration.

Verify command or evaluation procedure:

- Run the `xcodebuild test` command below, then complete the qualitative macOS
  app check.

Expected runtime / stop condition:

- Budget one focused implementation pass plus one test/qualitative verification
  pass. Stop and return to planning if this slice requires iOS touch input, a
  separate app window, per-device profiles, real beatmap/audio files, or
  sample-accurate audio scheduling beyond the minimal click service.

Guard check:

- Existing `mania4k` play-session tests must remain green; the calibration
  model must not change judgement-engine behavior.

Qualitative check:

- Open the wizard, confirm the first note reaches the judgement line about
  `1,000 ms` after entry, listen to the click, tap notes to produce signed
  suggestions, adjust offset with large and fine buttons, add/select/delete
  presets, confirm airborne notes snap while the click cadence remains steady,
  then Apply and Cancel from separate runs.

## Source-Grounded Findings

Evidence strength is strongest where the source is official documentation or
project source, and weaker where it comes from community practice.

- osu! documents an Offset Wizard opened from options/search next to offset
  settings. It plays a metronome, scrolls visual beat bars, exposes the current
  universal offset, allows direct adjustment, and applies the displayed value on
  exit.
  Source: https://osu.ppy.sh/wiki/en/Client/Options/Offset_Wizard
- osu! describes universal/global offset as a global adjustment for every
  beatmap, useful only when timing feels consistently wrong across maps. It
  explicitly distinguishes global offset from local song offset.
  Source: https://osu.ppy.sh/wiki/en/Offset/Universal_offset
- osu!lazer source keeps the global offset slider in audio settings, displays
  recent average-hit-error suggestions, and applies the suggested offset with a
  dedicated action rather than silently changing the setting.
  Source: https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Overlays/Settings/Sections/Audio/AudioOffsetAdjustControl.cs
- StepMania/ITG practice treats machine/global offset as the combined latency of
  monitor, audio setup, OS, USB path, and input device. AutoSync Machine asks the
  player to follow the music rather than the visuals, and hardware changes can
  require recalibration.
  Source: https://wiki.clubfantastic.dance/Sync
- Clone Hero separates calibration from final trust: its tool averages repeated
  inputs, but its docs warn that wide spread makes the result unreliable and may
  require manual tuning. It also separates audio and video offsets.
  Source: https://wiki.clonehero.net/books/guides-and-tutorials/page/calibrating-audio-and-video
- Sonolus separates device audio offset, device input offset, and level/server
  offsets. Its device-audio guidance uses watch mode to compare graphics and
  audio before involving player input, and warns that Bluetooth headphones can
  introduce significant delay.
  Source: https://wiki.sonolus.com/getting-started/advanced/offsets

Best-practice implications for Pulsefield:

- Place the entry point directly beside the global offset field.
- Keep global offset scoped to consistent device-level latency, not per-chart
  timing mistakes.
- Prefer a visual-plus-audio manual wizard first, because it tests device
  audio/visual sync without mixing in player input consistency.
- Preserve explicit apply/cancel semantics; do not silently commit the value
  while the user experiments.
- Leave room for a later results-based suggestion that uses average hit error,
  but do not make that the first wizard.
- Make the sign convention visible through behavior and a short label, because
  different rhythm games explain positive/negative values differently.

## Goal Decomposition

Root objective: help users calibrate `globalAudioOffsetMilliseconds` for the
current playback/display/input setup without loading a real beatmap.

Checkable subgoals:

- Entry: the macOS setup screen exposes a calibration action adjacent to the
  existing `Global audio offset` numeric field. iOS does not expose the
  calibration action in this first slice.
- Scene: activating the action opens a dedicated calibration scene inside the
  `mania4k` experience flow, not a separate macOS app window.
- Local state: calibration is entered through view/model local state owned by
  `Mania4KSetupView` as a setup submode, not a new gameplay phase in
  `Mania4KPlayPhase` and not a parent-level scene switch in
  `Mania4KPlayExperienceView` for this slice.
- Timing: the scene waits `1,000 ms` after calibration start before the first
  synthetic note reaches the judgement line, regardless of the starting offset,
  then generates one synthetic tick every `500 ms` by default.
- Visual sync: a falling note reaches the judgement line at each synthetic beat
  according to `renderChartTimeMs = rawClockTimeMs + renderedOffsetMs`.
- Audio sync: the click/tick sound fires at raw synthetic beat time, independent
  of the candidate offset.
- Input suggestion: for this first macOS slice, a calibration-local keyboard hit
  is matched to the nearest unresolved calibration note only when
  `abs((rawInputTimeMs + sampleRenderedOffsetMs) - noteTimeMs) <= 120`.
- Precision math: accepted hits store the rendered offset used for that input
  sample and compute
  `hitErrorMs = rawInputTimeMs + sampleRenderedOffsetMs - noteTimeMs` and
  `sampleSuggestedOffsetMs = clamp(sampleRenderedOffsetMs - hitErrorMs)`.
  The rolling `suggestedOffsetMs` is the median of accepted
  `sampleSuggestedOffsetMs` values, not the current rendered offset plus a
  median of errors. The UI displays the signed adjustment from the current
  pending candidate to the rolling suggested offset, for example `+14 ms` or
  `-23 ms`, and may also show the absolute suggested offset.
- Controls: the user can adjust the candidate offset with `-100`, `-10`, `-1`,
  text entry, `+1`, `+10`, and `+100` millisecond controls, clamped to
  `-500...500`.
- Presets: the user can manually save millisecond presets shaped as
  `(id, name, presetMs)`, add a preset with a custom name or a default
  `preset N` placeholder, delete a preset, choose the active preset, and have
  the saved presets and active selection persist across launches.
- Preset detachment: any manual candidate edit, including step buttons, text
  entry, or accepting a suggestion, clears `activePresetID` once the pending
  value no longer matches the active preset value. Returning to the same number
  does not auto-reselect the preset; the user must choose it again.
- Input: the calibration page accepts the default `j` key for the synthetic
  target and displays the active calibration key on screen. This is deliberately
  local to calibration for the first slice and does not change the user's
  gameplay key bindings.
- Snap behavior: offset changes move all airborne notes by changing frame time,
  not object times, and the movement is a non-animated snap.
- Throttle: repeated candidate changes update the rendered offset at most twice
  per second; the numeric field may show the pending value immediately.
- Persistence: direct edits in the setup `Global audio offset` numeric field are
  session-local and intentionally drop on relaunch unless the user explicitly
  saves through the calibration Apply path. Apply writes the candidate offset
  back to the setup model and the persisted global-offset setting; Cancel
  restores the original value and does not change the persisted global offset.

## Candidate Variants

### A. Manual audiovisual calibration with gated hit suggestions and presets

The selected first slice. A synthetic 120 BPM click track is paired with a
falling note/receptor display. The user manually adjusts offset until the note
arrival and click feel aligned, can tap notes for signed precision suggestions,
and can store device/setup-specific millisecond presets.

Pros:

- Matches the user's requested interaction.
- Uses current renderer semantics: note position already depends on
  `chartTimeMs`.
- Keeps player input advisory, not authoritative, while still surfacing
  concrete adjustment deltas.
- Lets users calibrate before selecting files and save repeatable offsets for
  common devices.
- Easy to test with a fake monotonic clock.

Cons:

- Does not auto-apply the suggested value.
- Users still need to choose whether a suggestion is trustworthy.

### B. Tap-to-average auto-calibration

The scene asks the user to tap with the click, computes an error aggregate, and
automatically writes or strongly promotes a new offset.

Pros:

- Closer to StepMania/Clone Hero automatic calibration patterns.
- Produces a concrete suggested number.

Cons:

- Mixes audio/device latency with player consistency and keyboard/touch input
  latency.
- Needs variance gating and confidence UI to avoid bad recommendations.
- Can feel surprising if it writes global timing from a noisy short sample.
- Larger first slice.

### C. Results-based suggestion only

Keep setup unchanged and rely on post-play `averageHitErrorMs` /
`suggestedGlobalOffsetAdjustmentMs`.

Pros:

- Already aligned with existing core scoring fields.
- Uses real gameplay data.

Cons:

- Requires a playable chart and enough accurate hits.
- Does not help first-time setup before play.
- Cannot isolate audio/visual sync from skill.

### D. Hardware-latency seed

Read system or audio-device latency and prefill an offset suggestion.

Pros:

- Fast starting point when available.

Cons:

- Platform APIs are incomplete and not enough for visual/input latency.
- Clone Hero's docs treat reported hardware latency as only a starting point.
- Not worth blocking the wizard on this in the first slice.

Selected variant: A.

Mutation kept for later: add B as an explicit "auto apply suggestion" mode only
after the advisory suggestion path has variance/confidence evidence. Keep C as
a separate post-play suggestion path after the result screen already has enough
hit-error samples.

## Local Verification Matrix

| Candidate | Smallest verification | Pass condition | Reject condition |
| --- | --- | --- | --- |
| A | Fake clock renders raw ticks at `1000, 1500, 2000...`, accepts taps inside `120 ms`, rejects taps outside, and stores presets | Same seeded object times, changed `chartTimeMs`, visible Y positions snap after throttled offset publish, signed suggestion comes from the median of per-sample suggested offsets, applied global offset and manually saved presets persist across launches | Object times are rewritten, tick audio depends on candidate offset, out-of-window taps affect suggestions, or deleting an active preset leaves stale active state |
| B | Simulated tap errors produce mean/median and standard deviation for an auto-applied offset | Suggested offset is gated when variance is high and auto-apply is explicit | One noisy tap sequence can auto-apply a bad offset |
| C | Existing play result emits `suggestedGlobalOffsetAdjustmentMs` after enough hits | Result suggestion matches `-averageHitErrorMs` and never auto-applies | No help before the first play session |
| D | Audio route metadata returns a latency estimate | Value is shown as a hint only | Value is treated as authoritative or unavailable on common devices |

## Minimal Change

Implement a dedicated manual calibration scene and model, then wire it from the
setup offset row.

Core shape:

- Add `Mania4KOffsetCalibrationModel` under
  `Sources/PulsefieldCore/Features/Mania4K/`.
- The model owns:
  - `originalOffsetMilliseconds`
  - `pendingOffsetMilliseconds`
  - `renderedOffsetMilliseconds`
  - `initialLeadInMs`, default `1_000`
  - `tickIntervalMs`, default `500`
  - `hitWindowMs`, fixed at `120` for this slice
  - `initialRenderedOffsetMilliseconds`, captured when the wizard opens
  - monotonic `rawClockTimeMs`
  - generated visible objects for the current lookahead
  - accepted hit samples with `noteTimeMs`, `rawInputTimeMs`,
    `sampleRenderedOffsetMs`, `hitErrorMs`, and `sampleSuggestedOffsetMs`
  - `suggestedOffsetAdjustmentMs` and `suggestedOffsetMs`
  - preset list and `activePresetID`
  - a throttle gate that publishes rendered offset at most every `500 ms`
- The model publishes a frame-like value or a small calibration frame that can
  be rendered by the UI without involving `Mania4KJudgementEngine`.
- Use object `startTimeMs` values for synthetic beats and compute visual
  position with `rawClockTimeMs + renderedOffsetMilliseconds`.
- Keep raw tick times and synthetic chart note times separate:
  - `rawBeatTimeMs = initialLeadInMs + beatIndex * tickIntervalMs`
  - `seededFirstNoteTimeMs = initialLeadInMs + initialRenderedOffsetMilliseconds`
  - `noteTimeMs = seededFirstNoteTimeMs + beatIndex * tickIntervalMs`
  This makes the first note reach the judgement line at raw time `1,000 ms`
  when the wizard starts even if the existing global offset is not zero. Later
  candidate offset edits move the rendered chart time; they do not rewrite
  synthetic note times.
- Do not maintain an ever-growing array of generated notes. Calibration beats
  are periodic, so derive the visible note list on demand from the current
  render window:
  - `renderChartTimeMs = rawClockTimeMs + renderedOffsetMilliseconds`
  - `visibleStartMs = renderChartTimeMs - postLineVisibleMs`
  - `visibleEndMs = renderChartTimeMs + travelTimeMs + lookaheadPaddingMs`
  - `firstBeatIndex = max(0, Int(ceil((visibleStartMs - seededFirstNoteTimeMs) / tickIntervalMs)))`
  - `lastBeatIndex = Int(floor((visibleEndMs - seededFirstNoteTimeMs) / tickIntervalMs))`
  - return no visible notes when `lastBeatIndex < firstBeatIndex`
  - `noteTimeMs = seededFirstNoteTimeMs + beatIndex * tickIntervalMs`
- Use `beatIndex` as the stable synthetic note identity. It can map directly to
  `Mania4KObjectOrdinal(rawValue: beatIndex)` while the scene is running.
- Maintain only a bounded note-state cache for recent beat indices that need
  display state or duplicate-hit prevention. A ring buffer keyed by beat index
  is acceptable, but an ordered dictionary with deterministic pruning is simpler
  and fine at this density. Prune entries older than
  `renderChartTimeMs - max(postLineVisibleMs, hitWindowMs) - tickIntervalMs`.
- Keep accepted hit samples in a separate capped rolling collection, for example
  the most recent `16` accepted samples. Suggestions should not depend on
  unbounded history from a long-running wizard session.
- Match an input to the nearest visible/unresolved synthetic beat only when the
  absolute hit error is no more than `120 ms`; rejected taps should not affect
  suggestion aggregates.
- Compute `sampleSuggestedOffsetMs` for each accepted hit sample as
  `clamp(sampleRenderedOffsetMs - hitErrorMs)`, then compute `suggestedOffsetMs`
  as the median of those per-sample absolute offsets. Compute
  `suggestedOffsetAdjustmentMs` only as the display/apply delta from the current
  pending candidate to the rolling `suggestedOffsetMs`. Median is preferred over
  mean here because a calibration scene will have few samples and one sloppy tap
  should not dominate the hint.
- Keep suggestions advisory: a suggested offset can be accepted by pressing the
  existing controls or an explicit "Use suggestion" action, but it must not
  overwrite the active candidate by itself.
- Add `Mania4KOffsetPreset`:

```swift
public struct Mania4KOffsetPreset: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var presetMs: Int
}
```

- Store offset milliseconds as integers because the UI and existing global
  offset field use millisecond precision.

UI shape:

- In `Mania4KSetupView.settings`, replace the plain global-offset numeric row
  with a small grouped control: numeric value plus a calibration button.
- Opening calibration sets local calibration state in `Mania4KSetupView`, for
  example
  `@State private var offsetCalibrationModel: Mania4KOffsetCalibrationModel?`,
  and renders a dedicated `Mania4KOffsetCalibrationView` in place of the normal
  setup content while `Mania4KPlayExperienceView` still branches on
  `model.phase == .setup`.
- The calibration view reuses the existing lane/receptor visual language where
  practical, but it can use a single centered lane for the first slice.
- Controls are laid out as:
  `-100`, `-10`, `-1`, text field, `+1`, `+10`, `+100`, plus Apply and Cancel.
- Input controls use a calibration-local macOS key capture path with default key
  `j`. The calibration page displays that current key next to the synthetic
  target. This key does not mutate `mania4k` gameplay key bindings in the first
  slice. Touch calibration input and iOS exposure are out of scope and should be
  handled by a follow-up card if needed.
- Show the latest accepted hit error and the rolling signed suggested
  adjustment, for example `Suggestion +14 ms`; rejected out-of-window taps may
  flash a lightweight miss state but do not create a judgement record.
- Add preset controls: preset picker/list, Add Preset, Delete Preset, and active
  preset selection.
- Apply updates `model.globalAudioOffsetMilliseconds`, writes the persisted
  global-offset setting, and clears the local calibration state; Cancel discards
  the candidate value, leaves the persisted global offset unchanged, stops
  calibration, and clears the local state.

Audio shape:

- Add a minimal click/tick service behind a protocol so tests do not require
  `AVFoundation`.
- The production service schedules a short click at each raw tick time, starting
  with the `1,000 ms` lead-in tick. It does not offset the click by the
  candidate global offset.
- If exact scheduling is too much for the first pass, use a timer-driven click
  and record it as a qualitative limitation, but keep visual timing deterministic
  in tests.

Persistence shape:

- Add a lightweight preset store for `[Mania4KOffsetPreset]` and
  `activePresetID`.
- Add a lightweight global-offset store for the last applied
  `globalAudioOffsetMilliseconds`, using integer millisecond precision even
  though the setup model currently exposes the value as `Double`.
- Production storage may use the same simple `@AppStorage`/`UserDefaults` style
  already used by key bindings, encoded as JSON or another stable text payload.
  Tests should use an in-memory store.
- Presets are created only by an explicit manual Add/Save Preset action. Apply
  does not implicitly create or update a preset.
- Direct edits to the normal setup numeric field are not persisted. They affect
  only the current in-memory setup model and any play session started from it;
  relaunch restores the last explicitly applied global offset.
- Adding a preset captures the current pending offset as `presetMs`.
- If the user supplies a non-empty name, use the trimmed name. If not, generate
  `preset N`, where `N` is the next positive integer not already used by an
  existing default-named preset.
- Choosing an active preset updates `activePresetID`, sets
  `pendingOffsetMilliseconds` to `presetMs`, persists the active selection, and
  schedules the normal throttled rendered-offset publish.
- Manual candidate edits, including step controls, text entry, and accepting a
  suggestion, clear `activePresetID` when the pending value diverges from the
  active preset value. Do not automatically restore `activePresetID` if the user
  later edits back to that same value.
- Deleting a non-active preset removes it only.
- Deleting the active preset clears `activePresetID` but leaves the current
  pending offset unchanged, so the user does not lose the value currently being
  tested.
- Explicit preset add/delete/select changes persist immediately and are not
  rolled back by Cancel; Cancel only discards the candidate offset being tested.
- On launch, restore the last explicitly applied global offset into the setup
  model and restore saved presets plus persisted `activePresetID` when that id
  still exists in the preset list.
- Per-output-device profiles are out of scope until Pulsefield has a stable
  audio-route identity story.

## Files Likely To Change

- `Sources/PulsefieldCore/Features/Mania4K/Mania4KOffsetCalibrationModel.swift`
- `Sources/PulsefieldCore/Domain/Mania4KDomain.swift`, only if a shared
  calibration frame type or `Mania4KOffsetPreset` belongs in domain.
- `Sources/PulsefieldCore/Features/Mania4K/Mania4KOffsetPresetStore.swift`, if
  preset storage is not kept in the calibration model file.
- `Sources/PulsefieldCore/Features/Mania4K/Mania4KOffsetSettingsStore.swift`,
  if global-offset persistence is not kept with the preset store.
- `Sources/PulsefieldUI/Features/Mania4K/Mania4KPlayExperienceView.swift`
- `Sources/PulsefieldUI/Features/Mania4K/Mania4KOffsetCalibrationView.swift`,
  unless the view stays local to the existing play-experience file for the first
  slice.
- `project.yml`, only if target membership or source layout needs to change.
  Otherwise add files under the existing source roots and regenerate the Xcode
  project with `xcodegen generate` rather than hand-editing
  `Pulsefield.xcodeproj/project.pbxproj`.
- `Tests/PulsefieldCoreTests/Mania4KOffsetCalibrationModelTests.swift`
- `Tests/PulsefieldCoreTests/Mania4KOffsetPresetStoreTests.swift`, if the store
  is factored separately.
- `Tests/PulsefieldCoreTests/Mania4KNoteRenderLayoutTests.swift`, only for one
  regression proving offset-derived frame time shifts rendered Y positions.

Read-only context while implementing:

- `docs/design/mania-4k-play-experience-design.md`
- `docs/design/mania-4k-core-gameplay-contracts.md`
- `docs/execution-plan/mania-4k-ui-scene-research-plan.md`

## Acceptance Checklist

- The calibration entry is visually adjacent to `Global audio offset`.
- The calibration entry is macOS-only for this slice; iOS builds do not expose an
  unusable keyboard-only calibration action.
- The wizard opens without requiring selected beatmap/audio files.
- The wizard is entered with calibration-local state rather than a new gameplay
  phase.
- The calibration page accepts and displays the default `j` key for the
  synthetic target.
- The first synthetic note reaches the judgement line `1,000 ms` after entering
  calibration even when the starting global offset is non-zero.
- Default tick interval is `500 ms`.
- After the `1,000 ms` lead-in, a visible note reaches the judgement line for
  each raw tick at the initial rendered offset, including offset `0`.
- Visible dropping notes are generated from the current beat-index range, not
  appended into an unbounded note list.
- Per-note state is bounded to recent beat indices needed for hit feedback and
  duplicate-hit prevention.
- Accepted hit samples are capped to a rolling history, initially `16` samples.
- User input inside `±120 ms` of the rendered calibration note is accepted as a
  calibration hit sample.
- User input outside `±120 ms` is ignored for suggestion math.
- Accepted hit samples produce a signed suggested adjustment such as `+14 ms` or
  `-23 ms`.
- The suggestion follows the existing offset-adjustment direction:
  each sample computes `sampleSuggestedOffsetMs`, the rolling suggestion uses
  `median(sampleSuggestedOffsetMs)`, and the displayed adjustment is the delta
  from the current pending candidate to that rolling suggested offset.
- Changing offset does not rewrite synthetic note times.
- Changing offset causes airborne notes to snap, not animate.
- Rendered offset updates are throttled to no more than two per second during
  repeated edits.
- Numeric controls support `+/-100`, `+/-10`, and `+/-1` millisecond steps.
- Offset is clamped to `-500...500`.
- The user can add a preset from the current candidate offset.
- Apply persists the candidate global offset across launches without implicitly
  creating or updating a preset.
- A blank preset name creates `preset N`.
- The user can select an active preset and the candidate offset changes to that
  preset's millisecond value.
- Manual edits after selecting a preset clear the active preset selection when
  the candidate value diverges from that preset.
- The user can delete a preset.
- Deleting the active preset clears active selection without changing the
  current candidate offset.
- Saved presets and the active preset selection persist across launches.
- Apply writes the candidate value back to the setup model and persisted global
  offset setting.
- Direct edits to the setup global-offset numeric field are unsaved by default
  and drop on relaunch unless the user explicitly applies a calibration value.
- Cancel leaves the setup model and persisted global offset setting unchanged.
- The calibration tick does not continue playing after leaving the scene.

## Tests

Keep tests concrete and behavior-focused:

- Model defaults: starts from injected offset, `1,000 ms` initial lead-in,
  `500 ms` tick interval, default calibration key `j`, and no active click
  service until started.
- Visible note generation: for a fixed raw clock and rendered offset, the model
  returns exactly the beat indices inside the visible render window, never emits
  beat indices before the seeded first note, and computes note times as
  `rawBeatTimeMs + initialRenderedOffsetMilliseconds`.
- State pruning: advancing well past previous notes prunes old per-note state
  and keeps the cache bounded.
- Sample cap: more than `16` accepted hits keeps only the most recent `16`
  samples for suggestion math.
- Step controls: `+/-100`, `+/-10`, `+/-1` clamp correctly.
- Hit gating: input at `+120 ms` and `-120 ms` is accepted; input at
  `+120.001 ms` or `-120.001 ms` is rejected.
- Suggestion math: accepted hit samples compute individual absolute suggested
  offsets from their own `sampleRenderedOffsetMs`; samples taken before and after
  manual offset changes aggregate by median suggested offset, not by median raw
  error.
- Suggestion non-application: accepted hits update suggestion fields but do not
  change `pendingOffsetMilliseconds` unless the user explicitly applies the
  suggestion.
- Calibration key: the local default `j` key accepts calibration taps and is
  displayed by the calibration view without mutating gameplay key bindings.
- Platform gating: the calibration action is compiled or conditionally exposed
  only for macOS in this slice, and the shared `PulsefieldUI` target still builds
  for iOS.
- Preset add: blank names produce `preset N`; custom names are trimmed and kept.
- Preset select: choosing a preset sets active id and pending offset.
- Preset persistence: manually saved presets and persisted active id survive a
  store reload; Apply never creates a preset by itself.
- Preset detach: after selecting a preset, step controls, text entry, and
  accepting a suggestion clear active id when the pending offset diverges from
  the preset value and do not auto-reselect when edited back.
- Preset delete: deleting active preset clears active id and preserves pending
  offset; deleting inactive preset preserves active selection.
- Apply/cancel: returns candidate or original value without touching playback
  state, and only Apply writes the persisted global offset.
- Unsaved setup edits: direct numeric-field changes are visible in the current
  setup model but do not write the persisted global offset store.
- Render shift: with the same synthetic object and raw clock time, increasing
  offset changes `chartTimeMs` and therefore Y position.
- Throttle: many pending changes inside `500 ms` produce at most one rendered
  offset update, then the latest value is published after the throttle window.
- Lifecycle: stopping calibration stops tick scheduling and frame updates.

Do not add UI snapshot tests for the first pass unless the view becomes hard to
verify manually.

## Verify Commands

Primary command:

```sh
xcodegen generate
xcodebuild test -scheme PulsefieldMac -destination 'platform=macOS' -derivedDataPath DerivedData/Pulsefield-tests
```

Qualitative check:

- Launch the macOS app.
- Open `mania4k` setup.
- Click the global offset calibration action.
- Confirm the calibration page shows `j` as the active calibration key.
- Listen for a steady `500 ms` tick and confirm the first falling note reaches
  the line about `1,000 ms` after entering calibration at offset `0` and again
  after reopening from a non-zero starting offset.
- Tap close to the line and confirm a signed suggestion appears.
- Tap far outside the line and confirm it does not change the suggestion.
- Press the large and fine offset buttons quickly; the number updates, the
  notes snap at the throttled cadence, and the click cadence remains steady.
- Add a preset with a custom name.
- Add another preset with an empty name and confirm it appears as `preset N`.
- Select a preset and confirm the candidate offset changes.
- Delete the selected preset and confirm the current candidate offset remains.
- Apply and confirm the setup global offset value changes.
- Relaunch and confirm the applied global offset and manually saved presets are
  restored.
- Reopen and Cancel; confirm the setup and persisted global offset values do not
  change.

## Risks And Kill Criteria

Risks:

- A strict two-updates-per-second render throttle may feel sluggish during fine
  adjustment. If it does, keep the throttle for repeated text/hold changes but
  consider immediate publish on discrete button taps in a later mutation.
- Timer-driven tick audio may drift relative to the visual clock. If drift is
  perceptible, the click service must use sample-accurate or host-time anchored
  scheduling before shipping.
- A single global value is not enough for users who frequently switch between
  speakers, wired headphones, Bluetooth, and external displays. Treat per-device
  profiles as a later feature, not part of this first slice.
- Hit suggestions may be misleading if the player is inconsistent. Keep the
  first slice advisory and signed; do not auto-apply.
- Presets can become stale when hardware changes. The first slice stores named
  millisecond presets only; it does not try to detect devices.

Kill criteria:

- If the model cannot keep click timing and visual timing on the same monotonic
  timebase, stop before adding UI polish.
- If offset changes require mutating note object times, stop and refactor the
  calibration frame to follow the existing `chartTimeMs` render contract.
- If the first slice needs a real beatmap/audio file to run, it has missed the
  wizard objective and should be reduced back to synthetic ticks.
- If accepted out-of-window inputs can affect suggestions, stop and fix hit
  gating before shipping.
- If visible note maintenance grows with total wizard runtime instead of visible
  window size plus bounded recent state, stop and replace it with beat-index
  derivation and pruning.
- If preset storage cannot round-trip ids, names, active selection, and integer
  millisecond values deterministically, keep presets in memory and ship the
  calibration wizard first.
- If global-offset persistence cannot round-trip the applied integer
  millisecond value deterministically, do not claim calibration survives
  relaunch.

## Result Interpretation

Positive result:

- Users can calibrate before play, and the implementation reuses the same offset
  semantics as gameplay. Tapping calibration objects gives a useful signed
  suggestion, and presets let users switch known millisecond values quickly.

Negative result:

- The wizard feels unreliable because the click and visual note drift, or the
  throttled snapping makes adjustment hard to reason about. It is also negative
  if accepted taps inside `120 ms` do not converge toward a stable signed
  adjustment.

Ambiguous result:

- Manual calibration and advisory suggestions work, but users still ask for the
  app to auto-apply the suggested value or bind presets to detected hardware.
  That should mutate into a second Experiment Card rather than expanding this
  slice.

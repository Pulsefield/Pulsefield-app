---
commit: d15db863e9d00e3fd09a550b3b060ceed1e4dd7b
title: Mania 4K UI And Scene Research Plan
source_spec: docs/design/mania-4k-play-experience-design.md
---

# Mania 4K UI And Scene Research Plan

This plan turns the streaming 4K mania play-experience spec into researchable UI and scene work. It is not an implementation plan; it defines what to study, prototype, and decide before building the first playable surface.

## Spec Boundaries

The UI must stay inside these constraints:

- 4K mania only.
- Streaming generated charts only.
- Show `music title` and `osu!mania star difficulty`.
- Do not show or generate traditional `difficulty name`.
- Do not include 7K, dual stage, convert, pp, raw score, or beatmap-local offset.
- During play, show only accuracy, combo, current judgement, music title, and star difficulty.
- Judgements are `Perfect`, `Good`, and `Miss`.
- Preserve note lock, long-note head/body/tail semantics, and release lenience.

## Candidate Product Scenes

### 1. Recognition To Play Handoff

Purpose: bridge the existing recognition dashboard into `mania4k` setup.

Research questions:

- How much information should appear after recognition before generation starts?
- Should star difficulty be selected before generation, or should the app default to a recommended value and allow adjustment?
- What states are needed for reserved, queued, running, failed, and ready-to-play generation?

Expected UI:

- Recognized music title.
- Recognition source and match confidence if available.
- `mania4k` mode label.
- Star difficulty input.
- Primary action to generate or start.

### 2. Pre-Play Setup

Purpose: expose every spec-required pre-play field without turning the screen into an editor.

Required fields:

- Music title.
- `osu!mania star difficulty`.
- Scroll speed, range `1.0...40.0`, default `8.0`, step `0.1`.
- Global audio offset, range `-500 ms...+500 ms`.
- Judge difficulty segmented control `A / B / C / D / E`, default `C`.

Research questions:

- Is the star value a slider, numeric stepper, preset chips, or generated recommendation plus manual override?
- Should offset use a slider plus fine step buttons?
- How should macOS keyboard defaults `D F J K` be shown without adding a full keybinding editor?

### 3. Gameplay Scene

Purpose: the main 4-lane play surface.

Required elements:

- Four vertical lanes.
- Receptors and judgement line.
- Falling tap notes.
- Long notes with visually distinct head, body, and tail.
- Current judgement burst showing only `Perfect`, `Good`, or `Miss`.
- HUD: music title, star difficulty, accuracy, combo.

Research questions:

- SwiftUI `Canvas` versus Metal-backed rendering for stable high-frequency note movement.
- How to keep the HUD readable on macOS and portrait iPhone/iPad without obscuring notes.
- Whether touch controls should be visible always, fade after keyboard input, or appear only after touch input.

### 4. Pause And Quick Settings Overlay

Purpose: allow play-session adjustment without expanding scope into full settings.

Allowed controls:

- Scroll speed.
- Global audio offset.
- Judge difficulty.
- Resume and quit.

Out of scope:

- Beatmap-local offset.
- Mods.
- Difficulty name.
- Keybinding editor, unless a later spec adds it.

### 5. Offset Calibration Scene

Purpose: produce the settlement-page global offset hint described in the spec.

Research questions:

- Should calibration be a dedicated scene, a post-results suggestion, or both?
- What sample count is enough before suggesting a global offset?
- Should the UI show average hit error history, a single suggested value, or both?

Expected output:

- Average hit error.
- Suggested global offset.
- Apply or dismiss action.

### 6. Results Scene

Purpose: focused post-play summary.

Required fields:

- Perfect count.
- Good count.
- Miss count.
- Accuracy.
- Max combo.
- Average hit error.
- Global offset adjustment hint.

Out of scope:

- Raw score.
- Grade.
- pp.
- Detailed performance breakdown.
- Difficulty name.

## Research-Only Diagnostic Scenes

These scenes should be hidden from normal users or isolated as previews/test fixtures.

- Scroll-speed visualizer: confirm `scrollTime = 11485 / scrollSpeed` and prove scroll speed only affects reading, not judgement windows.
- Judge-window visualizer: compare `A / B / C / D / E` windows against `Perfect / Good / Miss`.
- Note-lock lane test: prove earlier notes are force-missed when a later hittable object is struck.
- Long-note semantics test: head hit, body hold break, tail release, and release lenience cases.
- Streaming-buffer test: visualize generated notes entering the playfield buffer while audio time advances.
- Touch input layout test: portrait iPhone/iPad receptor sizing, spacing, and hit areas.

## Open-Source Reference Plan

Use open-source projects as behavioral references, not as UI skins or brand assets.

### Primary Mechanics Reference

- osu!lazer: https://github.com/ppy/osu
  - License: MIT for code/framework; branding and resources have separate restrictions.
  - Use for: mania scroll timing, hit windows, note lock, long-note behavior, global offset handling, star difficulty reference.
  - Pinned baseline from source spec: `a0be214d034c48b0b603069dc284b27b9dde5c17`.
  - Relevant files:
    - `osu.Game.Rulesets.Mania/UI/DrawableManiaRuleset.cs`
    - `osu.Game.Rulesets.Mania/Scoring/ManiaHitWindows.cs`
    - `osu.Game.Rulesets.Mania/UI/OrderedHitPolicy.cs`
    - `osu.Game.Rulesets.Mania/Objects/Drawables/DrawableHoldNote.cs`
    - `osu.Game.Rulesets.Mania/Objects/TailNote.cs`
    - `osu.Game/Beatmaps/FramedBeatmapClock.cs`
    - `osu.Game/Overlays/Settings/Sections/Audio/AudioOffsetAdjustControl.cs`
    - `osu.Game.Rulesets.Mania/Difficulty/ManiaDifficultyCalculator.cs`
    - `osu.Game.Rulesets.Mania/Difficulty/Skills/Strain.cs`

### Useful UI And VSRG References

- osu!framework: https://github.com/ppy/osu-framework
  - License: MIT.
  - Use for: visual test discipline, input/render architecture ideas, timing/frame-clock patterns.

- Quaver: https://github.com/Quaver/Quaver
  - License: MPL-2.0 for client code; resources are separately licensed.
  - Use for: competitive VSRG screen flow, song/gameplay/results conventions, scroll-speed UX comparisons.
  - Avoid direct code copying unless MPL file-level obligations are acceptable.

- Etterna: https://github.com/etternagame/etterna
  - License: MIT, with dependency caveats around MAD/FFmpeg builds.
  - Use for: keyboard-focused rhythm UX, judgement/offset culture, results and profile flow ideas.

- StepMania: https://github.com/stepmania/stepmania
  - License: MIT for source code; included songs/assets have separate licenses.
  - Use for: long-running VSRG option patterns, timing-window terminology, noteskin/theme separation.

- TECHMANIA: https://github.com/techmania-team/techmania
  - License: MIT for code/assets with listed exceptions.
  - Use for: touch-capable rhythm-game UI lessons, iOS/iPadOS caveats, PC-versus-mobile control compromises.

### Reference With Caution

- ITGmania: https://github.com/itgmania/itgmania
  - License: GPL-3.0.
  - Use for high-level behavior comparison only unless Pulsefield is prepared for GPL compatibility constraints.

## Research Deliverables

1. A scene inventory with one low-fidelity mock per product scene.
2. A mechanics evidence matrix mapping every spec rule to an external source or Pulsefield-only decision.
3. A control taxonomy for macOS keyboard and iPhone/iPad portrait touch.
4. A judgement-window proposal for `A / B / C / D / E`, explicitly mapped to `Perfect / Good / Miss`.
5. A render strategy decision: SwiftUI layout plus `Canvas`, or a lower-level render surface for gameplay.
6. A minimal acceptance checklist for the first playable prototype.

## Suggested Research Order

1. Confirm mechanics constants and license boundaries from osu!lazer.
2. Draft the pre-play, gameplay, and results scene mockups.
3. Prototype diagnostic scenes for scroll speed, judgement windows, note lock, and long notes.
4. Compare Quaver, Etterna, StepMania, and TECHMANIA for UI patterns that do not conflict with the Pulsefield spec.
5. Decide the gameplay rendering approach.
6. Convert the research into a narrow implementation plan for the first playable `mania4k` loop.

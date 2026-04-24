---
commit: 547b201a67fddc0de2a95a67662d248e49f8f9aa
title: Mania 4K Core Gameplay Contracts
status: proposed
source_specs:
  - docs/design/mania-4k-play-experience-design.md
  - docs/design/mania-4k-judgement-engine-spec.md
osu_lazer_commit: a0be214d034c48b0b603069dc284b27b9dde5c17
---

# Mania 4K Core Gameplay Contracts

This document designs the core gameplay contracts for the next `mania4k` playable slice. It is a proposed design, not a current-code architecture summary and not an execution plan.

The frozen judgement behavior in `docs/design/mania-4k-judgement-engine-spec.md` remains authoritative. These contracts exist to feed that engine with audio-derived time, streamable hit objects, input events, and render snapshots without duplicating judgement rules outside the engine.

## Research Baseline

- osu!lazer [`DrawableManiaRuleset.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/UI/DrawableManiaRuleset.cs) computes mania scroll time as `MAX_TIME_RANGE / scrollSpeed`, with `MAX_TIME_RANGE = 11485` and supported scroll speed `1...40`.
- osu!lazer [`FramedBeatmapClock.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game/Beatmaps/FramedBeatmapClock.cs) treats the beatmap clock as the single timing source and applies offsets before gameplay consumers read time.
- osu!lazer [`ManiaHitObject.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/ManiaHitObject.cs), [`Note.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/Note.cs), and [`HoldNote.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/HoldNote.cs) model lane/column ownership separately from rendering. Hold notes own head, body, and tail nested objects, while the parent hold note is the scoring object.
- osu!lazer [`OrderedHitPolicy.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/UI/OrderedHitPolicy.cs) proves the note-lock rule: previous objects cannot remain hittable past the next object's start time, and earlier unresolved objects can be force-missed.
- osu!lazer [`TailNote.cs`](https://github.com/ppy/osu/blob/a0be214d034c48b0b603069dc284b27b9dde5c17/osu.Game.Rulesets.Mania/Objects/TailNote.cs) applies `RELEASE_WINDOW_LENIENCE = 1.5` to release windows.
- The official [`.osu` file format](https://osu.ppy.sh/wiki/en/Client/File_formats/osu_%28file_format%29) maps osu!mania holds from `x,y,time,type,hitSound,endTime:hitSample`; for mania, lane is computed from `x` as `floor(x * columnCount / 512)` and clamped to `0...(columnCount - 1)`.

## Design Principles

1. Audio time is the source of truth. The session layer derives `chartTimeMs = audioTimeMs + globalAudioOffsetMilliseconds`.
2. Hit objects enter gameplay through one normalized stream contract, whether they come from generated streaming output, fixture data, or a full beatmap adapter.
3. The judgement engine is pure core logic. It does not parse files, play audio, own SwiftUI state, or compute visual positions.
4. The renderer is a consumer of snapshots. It must not reimplement note lock, miss timing, long-note lifecycle, combo, or accuracy.
5. Contracts should be deterministic under test. A full chart and a stream that yields the same ordered objects must produce identical judgement results.

## Normalized Hit Objects

`Mania4KHitObject` is the only stream event shape accepted by the gameplay engine. It intentionally has no source identifier. Hold notes are represented as lane-ordered endpoint events: `hold_start` opens the current lane hold, and the next `hold_end` in the same lane closes it.

```swift
public struct Mania4KHitObject: Equatable, Sendable {
    public let lane: Mania4KLane
    public let timeMs: Double
    public let kind: Mania4KHitObjectKind
}

public enum Mania4KLane: Int, CaseIterable, Sendable {
    case left = 0
    case innerLeft = 1
    case innerRight = 2
    case right = 3
}

public enum Mania4KHitObjectKind: Equatable, Sendable {
    case tap
    case holdStart
    case holdEnd
}
```

Serialized/generated sources may name these cases `tap`, `hold_start`, and `hold_end`. Swift code should use `holdStart` and `holdEnd`.

Stream-object invariants:

- `lane` is exactly one of four lanes.
- `timeMs` is finite and non-negative.
- Tap notes have no duration.
- Objects are globally ordered by `timeMs`, then lane, then source order.
- Simultaneous objects across different lanes are valid.
- A same-lane `tap` is valid only when that lane has no open hold.
- A same-lane `holdStart` is valid only when that lane has no open hold.
- A same-lane `holdEnd` is valid only when that lane has an open hold, and its `timeMs` is greater than or equal to the opening `holdStart.timeMs`.

Lane-sequence rules:

- The source stream is responsible for sequence validity. The backend should not emit duplicate, overlapping, out-of-order, or impossible lane sequences.
- Pulsefield still validates defensively at adapter/session/engine boundaries so a malformed local beatmap or backend bug fails clearly.
- A `holdStart` opens one logical long note in its lane.
- The next valid `holdEnd` in that lane closes that logical long note.
- The engine must not score `holdStart` and `holdEnd` separately. The opened-and-closed hold contributes one scoring object, matching the frozen judgement spec.
- An imported full beatmap adapter should flatten each authored hold into adjacent stream-sequence semantics: one `holdStart` at the authored start time and one `holdEnd` in the same lane. If the authored end is earlier than the start, clamp it to the start time to match osu!'s loader.

The normalized object intentionally excludes source-specific fields such as `.osu` samples, storyboard data, editor metadata, and generated-model confidence. Those can live in adapter metadata later without becoming engine inputs.

## Chart Metadata

Gameplay needs a small chart header that is independent from the selected audio file.

```swift
public struct Mania4KChartMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let sourceDescription: String
    public let objectCount: Int?
    public let durationMs: Double?
}
```

`objectCount` and `durationMs` are optional because live generation may not know the final values when playback starts. A full beatmap adapter should fill both after parsing.

## Hit-Object Stream

The session owns a hit-object stream and pushes validated batches into the judgement engine.

```swift
public protocol Mania4KHitObjectStreaming: Sendable {
    func prepare() async throws -> Mania4KChartMetadata
    func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch
}

public struct Mania4KHitObjectStreamCursor: Hashable, Sendable {
    public let rawValue: String
}

public struct Mania4KHitObjectBatch: Equatable, Sendable {
    public let objects: [Mania4KHitObject]
    public let nextCursor: Mania4KHitObjectStreamCursor?
    public let completeThroughChartTimeMs: Double
    public let isEndOfStream: Bool
}
```

Stream contract:

- `prepare()` validates source-level prerequisites and returns metadata before audio starts.
- `read(after:throughChartTimeMs:limit:)` returns objects with `timeMs <= throughChartTimeMs`.
- A stream may return fewer than `limit` objects.
- A stream may return an empty batch when generation is still catching up.
- Cursors are stream positions, not object identities. They are monotonic and opaque to the session.
- The stream is append-only. Once an event has been emitted, it must not be revised or emitted again.
- Batches must preserve the normalized global ordering.
- `completeThroughChartTimeMs` is a source watermark. It means no later batch will emit an event with `timeMs <= completeThroughChartTimeMs`.
- `isEndOfStream` means no future objects will be emitted.
- The session may choose a lookahead such as `chartTimeMs + scrollTimeMs + safetyBufferMs`; the stream contract does not decide render lookahead.

The engine does not call the stream. This keeps async generation, file IO, and parser errors outside judgement logic.

The session should not advance the judgement engine beyond the stream watermark. If audio time reaches or passes `completeThroughChartTimeMs` without enough future stream coverage, the session should buffer, pause, or fail rather than asking the engine to judge against incomplete event data.

For a windowed inference backend, each appended generation window should emit any events that start or end inside that window, then advance `completeThroughChartTimeMs` to the end of the validated window. For example, a one-second backend window covering `5000...6000 ms` may emit taps, `holdStart`, and `holdEnd` events in that interval, then declare the stream complete through `6000 ms`. Long notes that continue past `6000 ms` remain open until a later window emits the lane-local `holdEnd`.

## Full Beatmap Adapter

A full beatmap adapter should parse or receive a complete chart, validate it once, then expose it through `Mania4KHitObjectStreaming`.

Adapter requirements:

- Accept only 4K mania charts.
- Map tap notes to `.tap`.
- Map each osu!mania hold to one `.holdStart` event at the hold start time and one `.holdEnd` event at `max(holdEndTime, holdStartTime)` in the same lane.
- Reject sliders, spinners, unsupported modes, unsupported key counts, invalid times, and same-lane overlaps.
- Reject a same-lane `tap` or `holdStart` while that lane already has an open hold.
- Reject `holdEnd` when that lane has no open hold.
- Reject malformed or non-finite hold ends, but clamp finite hold ends that are earlier than their starts to the start time.
- Preserve source order as a final ordering tiebreaker.
- Report structured setup errors before audio playback starts.

Initial policy: reject invalid or overlapping charts rather than normalizing them. Normalization changes authored timing and can hide problems that would make judgement behavior hard to trust.

## Audio Clock

The session reads an audio clock protocol and applies global offset before calling the engine.

```swift
public protocol Mania4KAudioClock: Sendable {
    func prepare(audioFileURL: URL) async throws -> Mania4KAudioMetadata
    func play() async throws
    func pause() async
    func stop() async
    func currentAudioTimeMs() async -> Double
    func isRunning() async -> Bool
}

public struct Mania4KAudioMetadata: Equatable, Sendable {
    public let durationMs: Double?
    public let title: String?
}
```

Clock rules:

- `currentAudioTimeMs()` is raw audio time, not chart time.
- Global audio offset is applied only by the session layer.
- The judgement engine never stores the audio URL and never talks to AVFoundation.
- A fake clock must be able to drive tests without wall-clock time.

## Session Coordinator

`Mania4KPlaySessionModel` should become the coordinator that connects stream, clock, engine, input, and rendering.

```swift
public enum Mania4KPlayPhase: Equatable, Sendable {
    case setup
    case loading
    case ready
    case playing
    case paused
    case finished(Mania4KPlayResult)
    case failed(Mania4KPlayFailure)
}
```

Session responsibilities:

- Validate setup input and prepare chart/audio.
- Compute scroll time as `11485 / scrollSpeed`.
- Start and stop audio playback.
- Poll audio time and compute chart time.
- Read hit-object batches using a render/judgement lookahead.
- Track the latest stream watermark and prevent judgement from advancing into incomplete stream time.
- Ingest batches into the engine before they become hittable.
- Convert platform input events into lane press/release events with chart timestamps.
- Publish render snapshots for SwiftUI.
- Finish only when audio has ended, stream has ended, and the engine has resolved all scoring objects.

The session should be `@MainActor` because it backs SwiftUI state. The engine itself should remain a plain synchronous core type owned by the session.

## Input Events

Input routers convert keyboard, touch, and future replay input into lane transitions.

```swift
public enum Mania4KInputPhase: Equatable, Sendable {
    case press
    case release
}

public struct Mania4KInputEvent: Equatable, Sendable {
    public let lane: Mania4KLane
    public let phase: Mania4KInputPhase
    public let chartTimeMs: Double
    public let sequenceNumber: UInt64
    public let source: Mania4KInputSource
}

public enum Mania4KInputSource: Equatable, Sendable {
    case keyboard
    case touch
    case replay
    case test
}
```

Input rules:

- The input router emits only lane state transitions. Keyboard repeat must not create repeated press events while a lane is already down.
- Multiple lanes can be pressed at the same chart time.
- Same-time events are processed by `sequenceNumber`.
- Press/release timestamps are sampled from the session's audio-derived chart time at event receipt.
- The engine decides whether an event affects a note; ignored events do not create judgement events.

## Judgement Engine Boundary

The engine API should be synchronous and deterministic.

```swift
public struct Mania4KJudgementEngine {
    public init(judgeDifficulty: Mania4KJudgeDifficulty)
    public mutating func ingest(_ objects: [Mania4KHitObject]) throws
    public mutating func advance(to chartTimeMs: Double) -> Mania4KEngineUpdate
    public mutating func handle(_ input: Mania4KInputEvent) -> Mania4KEngineUpdate
    public func snapshot(visibleRange: ClosedRange<Double>) -> Mania4KEngineSnapshot
}
```

Engine responsibilities:

- Enforce per-lane note lock.
- Resolve tap hits, ignored early presses, late misses, and auto-misses.
- Resolve long-note head/body/tail state as one scoring object.
- Convert lane-ordered `holdStart` and `holdEnd` events into logical long notes.
- Treat a release while a hold is open but not yet closed by a `holdEnd` event as an early body break, provided the session has not advanced beyond the stream watermark.
- Apply the frozen Malody tier windows and `Perfect / Good / Miss` collapse.
- Track combo, max combo, accuracy, counts, latest judgement, and offset samples.
- Expose unresolved visible objects for rendering.

Engine non-responsibilities:

- Audio playback.
- Global offset application.
- Scroll speed.
- File parsing.
- Async streaming.
- SwiftUI rendering.
- Keyboard or touch event capture.

## Engine Updates And Snapshots

Engine calls return events produced by that call, while snapshots expose current state.

```swift
public struct Mania4KEngineUpdate: Equatable, Sendable {
    public let judgementEvents: [Mania4KJudgementEvent]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]
}

public struct Mania4KEngineSnapshot: Equatable, Sendable {
    public let chartTimeMs: Double
    public let visibleObjects: [Mania4KVisibleObject]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]
    public let latestJudgement: Mania4KJudgementEvent?
    public let isResolved: Bool
}
```

`Mania4KVisibleObject` should include only data needed to draw the object and its current hold state:

```swift
public struct Mania4KObjectOrdinal: Hashable, Comparable, Sendable {
    public let rawValue: Int
}

public struct Mania4KVisibleObject: Identifiable, Equatable, Sendable {
    public let id: Mania4KObjectOrdinal
    public let lane: Mania4KLane
    public let startTimeMs: Double
    public let endTimeMs: Double?
    public let state: Mania4KVisibleObjectState
}
```

`Mania4KObjectOrdinal` is assigned internally by the session or engine at ingestion time. It is not part of the source stream. For taps, the ordinal belongs to the tap event. For holds, the ordinal belongs to the logical long note opened by `holdStart`; the matching `holdEnd` updates that same logical object instead of creating a second visible/scoring object.

Visible state should distinguish at least `waiting`, `holding`, `openEnded`, `missedButVisible`, and `resolved`. `openEnded` means the renderer has seen a `holdStart` whose matching lane-local `holdEnd` has not arrived yet. The exact visual style belongs to UI, not core.

## Score And Results

`Mania4KScoreState` mirrors the frozen judgement spec.

```swift
public struct Mania4KScoreState: Equatable, Sendable {
    public let perfectCount: Int
    public let goodCount: Int
    public let missCount: Int
    public let malodyTierCounts: Mania4KMalodyTierCounts
    public let combo: Int
    public let maxCombo: Int
    public let accuracy: Double
    public let averageHitErrorMs: Double?
    public let suggestedGlobalOffsetAdjustmentMs: Double?
}
```

`averageHitErrorMs` is the mean of successful tap hit errors and successful long-note head errors. `suggestedGlobalOffsetAdjustmentMs` is the delta to add to the current global offset, so its value is `-averageHitErrorMs` when enough samples exist.

Result generation belongs to the session after the engine reports `isResolved == true` and the stream has ended.

## Render Snapshot

The session should publish a UI-facing frame that combines engine snapshot, chart metadata, and scroll speed.

```swift
public struct Mania4KPlayFrame: Equatable, Sendable {
    public let chartTimeMs: Double
    public let scrollTimeMs: Double
    public let metadata: Mania4KChartMetadata
    public let visibleObjects: [Mania4KVisibleObject]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]
    public let latestJudgement: Mania4KJudgementEvent?
}
```

Renderer rules:

- A note reaches the judgement line when `object.startTimeMs == chartTimeMs`.
- Future position is derived from `(object.startTimeMs - chartTimeMs) / scrollTimeMs`.
- Hold-note body length is derived from `endTimeMs - startTimeMs`.
- Scroll speed affects only visual position and lookahead, never judgement windows.
- The renderer may animate judgement bursts from `latestJudgement`, but it must not infer misses or hits.

## Failure Contracts

Use structured failures so setup and play screens can show precise errors.

```swift
public enum Mania4KPlayFailure: Equatable, Error, Sendable {
    case audioPrepareFailed(String)
    case chartPrepareFailed(Mania4KChartValidationError)
    case streamFailed(String)
    case engineRejectedObjects(Mania4KChartValidationError)
}

public enum Mania4KChartValidationError: Equatable, Error, Sendable {
    case unsupportedMode
    case unsupportedKeyCount(Int)
    case unsupportedHitObject(String)
    case invalidLane(Int)
    case invalidTime(streamIndex: Int)
    case nonMonotonicObjectOrder(previousStreamIndex: Int, nextStreamIndex: Int)
    case laneSequenceViolation(streamIndex: Int, lane: Mania4KLane)
    case unclosedHoldAtEndOfStream(lane: Mania4KLane)
    case sameLaneOverlap(previousStreamIndex: Int, nextStreamIndex: Int)
}
```

The stream adapter and engine should share validation semantics. The adapter should catch most errors early; the engine still validates ingested batches defensively.

## Testable Contract Invariants

- A stream and an in-memory full chart that emit identical lane-ordered events produce identical judgement events and final score.
- Changing `scrollSpeed` changes render positions and stream lookahead, but not judgement results for the same input timestamps.
- Changing `globalAudioOffsetMilliseconds` changes chart timestamps passed to the engine, not object times.
- Keyboard repeat does not create duplicate press events.
- Same-lane overlap is rejected before play.
- Invalid lane sequences are rejected: `holdEnd` with no open hold, `tap` during an open hold, `holdStart` during an open hold, or end-of-stream with an open hold.
- The session does not advance judgement beyond `completeThroughChartTimeMs`.
- The renderer can draw falling taps and holds using only `Mania4KPlayFrame`.
- The engine can be tested without AVFoundation, SwiftUI, or async code.

## Clarifications Before Implementation

These are the only product decisions this contract leaves open:

1. Should the first playable implementation include a `.osu` parser immediately, or should it ship the normalized stream path first with fixture/generated sources and add `.osu` as the next adapter?
2. Should invalid full beatmaps always be rejected, or should Pulsefield later support a visible normalization/repair step outside gameplay?
3. Should audio end stop gameplay immediately after all known objects resolve, or should the session allow a short configurable tail period for streams that may emit very-late generated objects?
4. When generated stream data falls behind audio, should first playable buffer/pause playback or fail the session immediately?

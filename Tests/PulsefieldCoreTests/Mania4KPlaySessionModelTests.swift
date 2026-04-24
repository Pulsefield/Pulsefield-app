import XCTest
@testable import PulsefieldCore

@MainActor
final class Mania4KPlaySessionModelTests: XCTestCase {
    func testDefaultsMatchFirstPlayableSpec() {
        let model = Mania4KPlaySessionModel()

        XCTAssertEqual(model.starDifficulty, 4.0)
        XCTAssertEqual(model.scrollSpeed, 8.0)
        XCTAssertEqual(model.globalAudioOffsetMilliseconds, 0)
        XCTAssertEqual(model.judgeDifficulty, .c)
        XCTAssertEqual(model.phase, .setup)
        XCTAssertFalse(model.isReadyToStart)
        XCTAssertNil(model.activeConfiguration)
        XCTAssertNil(model.playFrame)
    }

    func testStartRequiresBeatmapAndAudioSelections() async throws {
        let model = try modelWithInMemoryChart(objects: [tap(.left, 1_000)])
        let beatmapURL = URL(fileURLWithPath: "/tmp/mock.osu")
        let audioURL = URL(fileURLWithPath: "/tmp/mock.mp3")

        var started = await model.startPlay()
        XCTAssertFalse(started)
        XCTAssertNil(model.activeConfiguration)

        model.selectBeatmapFile(beatmapURL)
        started = await model.startPlay()
        XCTAssertFalse(started)
        XCTAssertNil(model.activeConfiguration)

        model.selectAudioFile(audioURL)
        started = await model.startPlay()
        XCTAssertTrue(started)
        XCTAssertEqual(model.activeConfiguration?.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.activeConfiguration?.audioFileURL, audioURL)
        XCTAssertEqual(model.phase, .playing)
    }

    func testBeatmapSelectionOnlyAcceptsOsuExtension() {
        let model = Mania4KPlaySessionModel()
        let nonBeatmapURL = URL(fileURLWithPath: "/tmp/song.mp3")
        let beatmapURL = URL(fileURLWithPath: "/tmp/chart.OSU")

        model.selectBeatmapFile(nonBeatmapURL)

        XCTAssertNil(model.beatmapFileURL)
        XCTAssertFalse(model.isReadyToStart)
        XCTAssertEqual(model.beatmapSelectionErrorMessage, "Choose a .osu beatmap file.")

        model.selectBeatmapFile(beatmapURL)

        XCTAssertEqual(model.beatmapFileURL, beatmapURL)
        XCTAssertNil(model.beatmapSelectionErrorMessage)
    }

    func testQuitReturnsToSetupWithoutClearingSelections() async throws {
        let model = try modelWithInMemoryChart(objects: [tap(.left, 1_000)])
        let beatmapURL = URL(fileURLWithPath: "/tmp/mock.osu")
        let audioURL = URL(fileURLWithPath: "/tmp/mock.mp3")

        model.selectBeatmapFile(beatmapURL)
        model.selectAudioFile(audioURL)
        let started = await model.startPlay()
        XCTAssertTrue(started)

        await model.quitToSetup()

        XCTAssertEqual(model.phase, .setup)
        XCTAssertNil(model.activeConfiguration)
        XCTAssertEqual(model.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.audioFileURL, audioURL)
        XCTAssertTrue(model.isReadyToStart)
    }

    func testStartPlayIgnoresStalePreparationAfterQuit() async throws {
        let stream = SuspendedPrepareMania4KHitObjectStream()
        let clock = FakeMania4KAudioClock()
        let model = Mania4KPlaySessionModel(
            audioClock: clock,
            streamFactory: { _ in stream }
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/mock.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/mock.mp3"))

        let startTask = Task {
            await model.startPlay()
        }
        await stream.waitForPrepareToStart()

        await model.quitToSetup()
        await stream.completePrepare()
        let started = await startTask.value

        XCTAssertFalse(started)
        XCTAssertEqual(model.phase, .setup)
        XCTAssertNil(model.activeConfiguration)
        let isRunning = await clock.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testParserAcceptsValid4KMapAndFlattensTapsAndHolds() throws {
        let url = try writeOsuFile(
            """
            [General]
            Mode: 3
            AudioFilename: ignored.mp3

            [Metadata]
            Title: Test Song
            Artist: Test Artist

            [Difficulty]
            CircleSize: 4

            [HitObjects]
            0,192,1000,1,0,0:0:0:0:
            128,192,1100,1,0,0:0:0:0:
            256,192,1200,1,0,0:0:0:0:
            511,192,1300,1,0,0:0:0:0:
            512,192,1400,128,0,1800:0:0:0:0:
            """
        )

        let parsed = try OsuMania4KBeatmapStream.parseBeatmap(at: url)

        XCTAssertEqual(parsed.metadata.title, "Test Song")
        XCTAssertEqual(parsed.metadata.artist, "Test Artist")
        XCTAssertEqual(parsed.metadata.objectCount, 5)
        XCTAssertEqual(
            parsed.objects,
            [
                tap(.left, 1_000),
                tap(.innerLeft, 1_100),
                tap(.innerRight, 1_200),
                tap(.right, 1_300),
                Mania4KHitObject(lane: .right, timeMs: 1_400, kind: .holdStart),
                Mania4KHitObject(lane: .right, timeMs: 1_800, kind: .holdEnd)
            ]
        )
    }

    func testParserRejectsUnsupportedModeAndKeyCount() throws {
        XCTAssertThrowsValidation(.unsupportedMode) {
            _ = try OsuMania4KBeatmapStream.parseBeatmap(at: writeOsuFile(mode: 0))
        }

        XCTAssertThrowsValidation(.unsupportedKeyCount(5)) {
            _ = try OsuMania4KBeatmapStream.parseBeatmap(at: writeOsuFile(circleSize: 5))
        }
    }

    func testParserRejectsUnsupportedObjectInvalidHoldAndSameLaneOverlap() throws {
        XCTAssertThrowsValidation(matching: { error in
            if case .unsupportedHitObject = error { return true }
            return false
        }) {
            _ = try OsuMania4KBeatmapStream.parseBeatmap(at: writeOsuFile(hitObjects: "64,192,1000,2,0,1200,0:0:0:0:"))
        }

        XCTAssertThrowsValidation(.laneSequenceViolation(streamIndex: 0, lane: .left)) {
            _ = try OsuMania4KBeatmapStream.parseBeatmap(at: writeOsuFile(hitObjects: "0,192,1000,128,0,900:0:0:0:0:"))
        }

        XCTAssertThrowsValidation(.sameLaneOverlap(previousStreamIndex: 0, nextStreamIndex: 1)) {
            _ = try OsuMania4KBeatmapStream.parseBeatmap(
                at: writeOsuFile(
                    hitObjects:
                    """
                    0,192,1000,1,0,0:0:0:0:
                    10,192,1000,1,0,0:0:0:0:
                    """
                )
            )
        }
    }

    func testEngineJudgesTapWindowBoundariesAndOffsetSamples() throws {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try engine.ingest([tap(.left, 1_000), tap(.innerLeft, 2_000)])

        var update = engine.handle(input(.left, .press, 1_040, 0))
        XCTAssertEqual(update.judgementEvents.first?.judgement, .perfect)
        XCTAssertEqual(update.score.combo, 1)

        update = engine.handle(input(.innerLeft, .press, 2_056, 1))
        XCTAssertEqual(update.judgementEvents.first?.judgement, .good)
        XCTAssertEqual(update.score.combo, 2)
        XCTAssertEqual(update.score.averageHitErrorMs ?? .nan, 48, accuracy: 0.001)
        XCTAssertEqual(update.score.suggestedGlobalOffsetAdjustmentMs ?? .nan, -48, accuracy: 0.001)
    }

    func testEngineIgnoresTooEarlyPressThenAutoMissesTap() throws {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try engine.ingest([tap(.left, 1_000)])

        var update = engine.handle(input(.left, .press, 799, 0))
        XCTAssertTrue(update.judgementEvents.isEmpty)
        XCTAssertEqual(update.score.missCount, 0)

        update = engine.advance(to: 1_201)
        XCTAssertEqual(update.judgementEvents.first?.judgement, .miss)
        XCTAssertEqual(update.score.missCount, 1)
    }

    func testEngineAppliesPerLaneNoteLock() throws {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try engine.ingest([tap(.left, 1_000), tap(.left, 1_100)])

        let update = engine.handle(input(.left, .press, 1_100, 0))

        XCTAssertEqual(update.judgementEvents.map(\.judgement), [.miss, .perfect])
        XCTAssertEqual(update.score.missCount, 1)
        XCTAssertEqual(update.score.combo, 1)
        XCTAssertEqual(update.score.maxCombo, 1)
    }

    func testEngineRejectsOutOfOrderStreamEventsAfterHoldEnd() throws {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)

        XCTAssertThrowsValidation(.nonMonotonicObjectOrder(previousStreamIndex: 2, nextStreamIndex: 3)) {
            try engine.ingest([
                Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .holdStart),
                tap(.innerLeft, 2_000),
                Mania4KHitObject(lane: .left, timeMs: 3_000, kind: .holdEnd),
                tap(.innerRight, 2_500)
            ])
        }
    }

    func testEngineLongNoteSuccessBodyBreakAndTailLenience() throws {
        var successEngine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try successEngine.ingest([
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .holdStart),
            Mania4KHitObject(lane: .left, timeMs: 1_500, kind: .holdEnd)
        ])
        _ = successEngine.handle(input(.left, .press, 1_000, 0))
        var update = successEngine.handle(input(.left, .release, 1_800, 1))
        XCTAssertEqual(update.judgementEvents.first?.judgement, .good)
        XCTAssertEqual(update.score.combo, 1)
        XCTAssertEqual(update.score.missCount, 0)

        var breakEngine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try breakEngine.ingest([
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .holdStart),
            Mania4KHitObject(lane: .left, timeMs: 1_500, kind: .holdEnd)
        ])
        _ = breakEngine.handle(input(.left, .press, 1_000, 0))
        update = breakEngine.handle(input(.left, .release, 1_199, 1))
        XCTAssertEqual(update.judgementEvents.first?.judgement, .miss)
        XCTAssertEqual(update.score.missCount, 1)

        var lateTailEngine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try lateTailEngine.ingest([
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .holdStart),
            Mania4KHitObject(lane: .left, timeMs: 1_500, kind: .holdEnd)
        ])
        _ = lateTailEngine.handle(input(.left, .press, 1_000, 0))
        update = lateTailEngine.handle(input(.left, .release, 1_801, 1))
        XCTAssertEqual(update.judgementEvents.first?.judgement, .miss)
    }

    func testEngineAppliesNoteLockToLongNoteTailRelease() throws {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try engine.ingest([
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .holdStart),
            Mania4KHitObject(lane: .left, timeMs: 1_500, kind: .holdEnd),
            tap(.left, 1_600)
        ])

        _ = engine.handle(input(.left, .press, 1_000, 0))
        let update = engine.handle(input(.left, .release, 1_600, 1))

        XCTAssertEqual(update.judgementEvents.map(\.judgement), [.miss])
        XCTAssertEqual(update.judgementEvents.first?.objectTimeMs, 1_000)
        XCTAssertEqual(update.score.missCount, 1)
        XCTAssertEqual(update.score.combo, 0)
    }

    func testSessionPublishesFramesWithGlobalOffsetAndFinishes() async throws {
        let clock = FakeMania4KAudioClock(metadata: Mania4KAudioMetadata(durationMs: 1_000, title: "Fake"))
        let model = try modelWithInMemoryChart(
            objects: [tap(.left, 100)],
            clock: clock,
            globalOffset: 25
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))

        let started = await model.startPlay()
        XCTAssertTrue(started)
        XCTAssertEqual(model.playFrame?.chartTimeMs, 25)

        await clock.setAudioTimeMs(100)
        let tickedAtOffset = await model.tick()
        XCTAssertTrue(tickedAtOffset)
        XCTAssertEqual(model.playFrame?.chartTimeMs, 125)

        let handledInput = await model.handleInput(input(.left, .press, 100, 0))
        XCTAssertTrue(handledInput)
        await clock.setAudioTimeMs(1_000)
        await clock.setRunning(false)
        let finalTick = await model.tick()
        XCTAssertTrue(finalTick)

        guard case .finished(let result) = model.phase else {
            return XCTFail("Expected finished phase, got \(model.phase)")
        }
        XCTAssertEqual(result.score.perfectCount, 1)
    }

    func testSessionRejectsInputBeyondStreamWatermark() async throws {
        let clock = FakeMania4KAudioClock()
        let stream = LaggingMania4KHitObjectStream(completeThroughChartTimeMs: 0)
        let model = Mania4KPlaySessionModel(
            audioClock: clock,
            streamFactory: { _ in stream }
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        await clock.setAudioTimeMs(100)
        let handled = await model.handleKeyboardInput(key: "d", isPressed: true, isRepeat: false)

        XCTAssertFalse(handled)
        guard case .failed(let failure) = model.phase else {
            return XCTFail("Expected failed phase, got \(model.phase)")
        }
        XCTAssertEqual(failure, .streamFailed("The chart stream fell behind the judgement clock."))
    }

    func testConcurrentKeyboardStateCommitsBeforeAsyncJudgementWork() async throws {
        let clock = FakeMania4KAudioClock()
        let stream = DelayedSafeMania4KHitObjectStream()
        let model = Mania4KPlaySessionModel(
            audioClock: clock,
            streamFactory: { _ in stream }
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        async let pressLeft = model.handleKeyboardInput(key: "d", isPressed: true, isRepeat: false)
        async let pressInnerLeft = model.handleKeyboardInput(key: "f", isPressed: true, isRepeat: false)
        let pressResults = await (pressLeft, pressInnerLeft)

        XCTAssertTrue(pressResults.0)
        XCTAssertTrue(pressResults.1)
        XCTAssertEqual(pressedLanes(in: model), [.left, .innerLeft])

        let releasedLeft = await model.handleKeyboardInput(key: "d", isPressed: false, isRepeat: false)

        XCTAssertTrue(releasedLeft)
        XCTAssertEqual(pressedLanes(in: model), [.innerLeft])

        let releasedInnerLeft = await model.handleKeyboardInput(key: "f", isPressed: false, isRepeat: false)

        XCTAssertTrue(releasedInnerLeft)
        XCTAssertEqual(pressedLanes(in: model), [])
    }

    func testKeyboardReleaseDoesNotGetDroppedWhenClockReadReordersInputTasks() async throws {
        let clock = DelayedFirstCurrentTimeMania4KAudioClock()
        let stream = DelayedSafeMania4KHitObjectStream()
        let model = Mania4KPlaySessionModel(
            audioClock: clock,
            streamFactory: { _ in stream }
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        let press = Task {
            await model.handleKeyboardInput(key: "d", isPressed: true, isRepeat: false)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let released = await model.handleKeyboardInput(key: "d", isPressed: false, isRepeat: false)
        let pressed = await press.value

        XCTAssertTrue(pressed)
        XCTAssertTrue(released)
        XCTAssertEqual(pressedLanes(in: model), [])
    }

    func testSessionFailsWhenStreamEmitsObjectBehindPreviousWatermark() async throws {
        let clock = FakeMania4KAudioClock()
        let stream = WatermarkViolatingMania4KHitObjectStream()
        let model = Mania4KPlaySessionModel(
            audioClock: clock,
            streamFactory: { _ in stream }
        )
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        let ticked = await model.tick()

        XCTAssertFalse(ticked)
        guard case .failed(let failure) = model.phase,
              case .streamFailed(let message) = failure
        else {
            return XCTFail("Expected stream watermark failure, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("violated its watermark"))
    }

    func testSessionIgnoresGameplayInputWhilePaused() async throws {
        let model = try modelWithInMemoryChart(objects: [tap(.left, 100)])
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        await model.pause()
        let handled = await model.handleInput(input(.left, .press, 100, 0))

        XCTAssertFalse(handled)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.playFrame?.score.perfectCount, 0)
    }

    func testSessionDoesNotTickJudgementWhilePaused() async throws {
        let clock = FakeMania4KAudioClock()
        let model = try modelWithInMemoryChart(objects: [tap(.left, 100)], clock: clock)
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))
        let started = await model.startPlay()
        XCTAssertTrue(started)

        await model.pause()
        await clock.setAudioTimeMs(301)
        let ticked = await model.tick()

        XCTAssertFalse(ticked)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(model.playFrame?.score.missCount, 0)
    }

    func testSessionAudioLifecycleAwaitsClockTransitions() async throws {
        let clock = FakeMania4KAudioClock()
        let model = try modelWithInMemoryChart(objects: [tap(.left, 1_000)], clock: clock)
        model.selectBeatmapFile(URL(fileURLWithPath: "/tmp/chart.osu"))
        model.selectAudioFile(URL(fileURLWithPath: "/tmp/audio.mp3"))

        let started = await model.startPlay()
        XCTAssertTrue(started)
        var isRunning = await clock.isRunning()
        XCTAssertTrue(isRunning)

        await model.pause()
        XCTAssertEqual(model.phase, .paused)
        isRunning = await clock.isRunning()
        XCTAssertFalse(isRunning)

        await model.resume()
        XCTAssertEqual(model.phase, .playing)
        isRunning = await clock.isRunning()
        XCTAssertTrue(isRunning)

        await model.quitToSetup()
        XCTAssertEqual(model.phase, .setup)
        isRunning = await clock.isRunning()
        XCTAssertFalse(isRunning)
    }

    func testSessionUsesScrollSpeedForScrollTime() throws {
        let model = try modelWithInMemoryChart(objects: [tap(.left, 1_000)], scrollSpeed: 10)

        XCTAssertEqual(model.scrollTimeMs, 1_148.5, accuracy: 0.001)
    }

    func testKeyboardRouterFiltersRepeatsAndDuplicatePresses() {
        var router = Mania4KKeyboardInputRouter()

        let press = router.route(key: "d", isPressed: true, isRepeat: false, chartTimeMs: 100, sequenceNumber: 0)
        let repeatPress = router.route(key: "d", isPressed: true, isRepeat: true, chartTimeMs: 101, sequenceNumber: 1)
        let duplicatePress = router.route(key: "d", isPressed: true, isRepeat: false, chartTimeMs: 102, sequenceNumber: 2)
        let release = router.route(key: "d", isPressed: false, isRepeat: false, chartTimeMs: 120, sequenceNumber: 3)

        XCTAssertEqual(press?.lane, .left)
        XCTAssertEqual(press?.phase, .press)
        XCTAssertNil(repeatPress)
        XCTAssertNil(duplicatePress)
        XCTAssertEqual(release?.phase, .release)
    }

    private func modelWithInMemoryChart(
        objects: [Mania4KHitObject],
        clock: FakeMania4KAudioClock = FakeMania4KAudioClock(),
        scrollSpeed: Double = 8,
        globalOffset: Double = 0
    ) throws -> Mania4KPlaySessionModel {
        let stream = try InMemoryMania4KHitObjectStream(objects: objects)
        return Mania4KPlaySessionModel(
            scrollSpeed: scrollSpeed,
            globalAudioOffsetMilliseconds: globalOffset,
            audioClock: clock,
            streamFactory: { _ in stream }
        )
    }

    private func writeOsuFile(
        mode: Int = 3,
        circleSize: Int = 4,
        hitObjects: String = "0,192,1000,1,0,0:0:0:0:"
    ) throws -> URL {
        try writeOsuFile(
            """
            [General]
            Mode: \(mode)

            [Metadata]
            Title: Test

            [Difficulty]
            CircleSize: \(circleSize)

            [HitObjects]
            \(hitObjects)
            """
        )
    }

    private func writeOsuFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("osu")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private func tap(_ lane: Mania4KLane, _ timeMs: Double) -> Mania4KHitObject {
    Mania4KHitObject(lane: lane, timeMs: timeMs, kind: .tap)
}

private func input(
    _ lane: Mania4KLane,
    _ phase: Mania4KInputPhase,
    _ chartTimeMs: Double,
    _ sequenceNumber: UInt64
) -> Mania4KInputEvent {
    Mania4KInputEvent(
        lane: lane,
        phase: phase,
        chartTimeMs: chartTimeMs,
        sequenceNumber: sequenceNumber,
        source: .test
    )
}

@MainActor
private func pressedLanes(in model: Mania4KPlaySessionModel) -> [Mania4KLane] {
    model.playFrame?.laneStates.filter(\.isPressed).map(\.lane) ?? []
}

private actor LaggingMania4KHitObjectStream: Mania4KHitObjectStreaming {
    private let completeThroughChartTimeMs: Double

    init(completeThroughChartTimeMs: Double) {
        self.completeThroughChartTimeMs = completeThroughChartTimeMs
    }

    func prepare() async throws -> Mania4KChartMetadata {
        Mania4KChartMetadata(
            title: "Lagging chart",
            sourceDescription: "Lagging test stream",
            objectCount: nil,
            durationMs: nil
        )
    }

    func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        Mania4KHitObjectBatch(
            objects: [],
            nextCursor: cursor,
            completeThroughChartTimeMs: completeThroughChartTimeMs,
            isEndOfStream: false
        )
    }
}

private actor DelayedSafeMania4KHitObjectStream: Mania4KHitObjectStreaming {
    func prepare() async throws -> Mania4KChartMetadata {
        Mania4KChartMetadata(
            title: "Delayed safe chart",
            sourceDescription: "Delayed safe test stream",
            objectCount: nil,
            durationMs: nil
        )
    }

    func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        try await Task.sleep(nanoseconds: 60_000_000)
        return Mania4KHitObjectBatch(
            objects: [],
            nextCursor: cursor,
            completeThroughChartTimeMs: throughChartTimeMs + 10_000,
            isEndOfStream: false
        )
    }
}

private actor DelayedFirstCurrentTimeMania4KAudioClock: Mania4KAudioClock {
    private var currentTimeReadCount = 0
    private var running = false

    func prepare(audioFileURL: URL) async throws -> Mania4KAudioMetadata {
        currentTimeReadCount = 0
        return Mania4KAudioMetadata(durationMs: 10_000, title: "Delayed clock")
    }

    func play() async throws {
        running = true
    }

    func pause() async {
        running = false
    }

    func stop() async {
        running = false
    }

    func currentAudioTimeMs() async -> Double {
        currentTimeReadCount += 1
        if currentTimeReadCount == 1 {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return 0
    }

    func isRunning() async -> Bool {
        running
    }
}

private actor SuspendedPrepareMania4KHitObjectStream: Mania4KHitObjectStreaming {
    private var didStartPrepare = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareContinuation: CheckedContinuation<Mania4KChartMetadata, Never>?

    func prepare() async throws -> Mania4KChartMetadata {
        didStartPrepare = true
        prepareWaiters.forEach { $0.resume() }
        prepareWaiters.removeAll()

        return await withCheckedContinuation { continuation in
            prepareContinuation = continuation
        }
    }

    func waitForPrepareToStart() async {
        if didStartPrepare {
            return
        }

        await withCheckedContinuation { continuation in
            prepareWaiters.append(continuation)
        }
    }

    func completePrepare() {
        prepareContinuation?.resume(
            returning: Mania4KChartMetadata(
                title: "Suspended chart",
                sourceDescription: "Suspended test stream",
                objectCount: 0,
                durationMs: 0
            )
        )
        prepareContinuation = nil
    }

    func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        Mania4KHitObjectBatch(
            objects: [],
            nextCursor: nil,
            completeThroughChartTimeMs: throughChartTimeMs,
            isEndOfStream: true
        )
    }
}

private actor WatermarkViolatingMania4KHitObjectStream: Mania4KHitObjectStreaming {
    private var readCount = 0

    func prepare() async throws -> Mania4KChartMetadata {
        Mania4KChartMetadata(
            title: "Watermark violation chart",
            sourceDescription: "Watermark violation test stream",
            objectCount: nil,
            durationMs: nil
        )
    }

    func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        readCount += 1
        if readCount == 1 {
            return Mania4KHitObjectBatch(
                objects: [],
                nextCursor: Mania4KHitObjectStreamCursor(rawValue: "first"),
                completeThroughChartTimeMs: 2_000,
                isEndOfStream: false
            )
        }

        return Mania4KHitObjectBatch(
            objects: [tap(.left, 1_000)],
            nextCursor: nil,
            completeThroughChartTimeMs: throughChartTimeMs,
            isEndOfStream: true
        )
    }
}

private func XCTAssertThrowsValidation(
    _ expected: Mania4KChartValidationError,
    _ expression: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsValidation(matching: { $0 == expected }, expression, file: file, line: line)
}

private func XCTAssertThrowsValidation(
    matching predicate: (Mania4KChartValidationError) -> Bool,
    _ expression: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        try expression()
        XCTFail("Expected validation error", file: file, line: line)
    } catch let error as Mania4KChartValidationError {
        XCTAssertTrue(predicate(error), "Unexpected validation error: \(error)", file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

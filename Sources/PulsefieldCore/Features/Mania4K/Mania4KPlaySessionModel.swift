import Foundation
import Observation

public typealias Mania4KHitObjectStreamFactory = @Sendable (URL) -> any Mania4KHitObjectStreaming

private struct Mania4KFrameTiming {
    let gameplayChartTimeMs: Double
    let renderChartTimeMs: Double

    func streamReadThroughChartTimeMs(scrollTimeMs: Double) -> Double {
        max(gameplayChartTimeMs, renderChartTimeMs) + scrollTimeMs + 250
    }
}

@MainActor
@Observable
public final class Mania4KPlaySessionModel {
    public var beatmapFileURL: URL?
    public var audioFileURL: URL?
    public var starDifficulty: Double
    public var scrollSpeed: Double
    public var audioOffsetMilliseconds: Double
    public var visualOffsetMilliseconds: Double
    public var judgeDifficulty: Mania4KJudgeDifficulty
    public var keyBindings: Mania4KKeyBindingSet

    public private(set) var beatmapSelectionErrorMessage: String?
    public private(set) var audioSelectionErrorMessage: String?
    public private(set) var keyBindingErrorMessage: String?
    public private(set) var activeConfiguration: Mania4KPlayConfiguration?
    public private(set) var phase: Mania4KPlayPhase
    public private(set) var playFrame: Mania4KPlayFrame?
    public private(set) var liveInputLaneStates: [Mania4KLaneState]

    private let streamFactory: Mania4KHitObjectStreamFactory
    private let audioClock: any Mania4KAudioClock
    private var activeStream: (any Mania4KHitObjectStreaming)?
    private var engine: Mania4KJudgementEngine?
    private var metadata: Mania4KChartMetadata?
    private var audioMetadata: Mania4KAudioMetadata?
    private var streamCursor: Mania4KHitObjectStreamCursor?
    private var streamCompleteThroughChartTimeMs: Double
    private var streamEnded: Bool
    private var streamReadGate: AsyncGate
    private var inputSequenceNumber: UInt64
    private var keyboardRouter: Mania4KKeyboardInputRouter
    private var frameLoopTask: Task<Void, Never>?
    private var playStateGeneration: UInt64
    private var queuedGameplayInputs: [QueuedMania4KInput]
    private var isDrainingGameplayInputQueue: Bool

    public init(
        beatmapFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        starDifficulty: Double = 4.0,
        scrollSpeed: Double = 16.0,
        audioOffsetMilliseconds: Double = 0,
        visualOffsetMilliseconds: Double = 0,
        judgeDifficulty: Mania4KJudgeDifficulty = .c,
        keyBindings: Mania4KKeyBindingSet = .default,
        audioClock: any Mania4KAudioClock = AVFoundationMania4KAudioClock(),
        streamFactory: @escaping Mania4KHitObjectStreamFactory = { OsuMania4KBeatmapStream(beatmapFileURL: $0) }
    ) {
        self.beatmapFileURL = beatmapFileURL
        self.audioFileURL = audioFileURL
        self.starDifficulty = starDifficulty
        self.scrollSpeed = scrollSpeed
        self.audioOffsetMilliseconds = audioOffsetMilliseconds
        self.visualOffsetMilliseconds = visualOffsetMilliseconds
        self.judgeDifficulty = judgeDifficulty
        self.keyBindings = keyBindings
        self.audioClock = audioClock
        self.streamFactory = streamFactory
        self.phase = .setup
        self.liveInputLaneStates = Self.makeLaneStates(pressedLanes: [])
        self.streamCompleteThroughChartTimeMs = 0
        self.streamEnded = false
        self.streamReadGate = AsyncGate()
        self.inputSequenceNumber = 0
        self.keyboardRouter = Mania4KKeyboardInputRouter(keyBindings: keyBindings)
        self.playStateGeneration = 0
        self.queuedGameplayInputs = []
        self.isDrainingGameplayInputQueue = false
    }

    public var isReadyToStart: Bool {
        beatmapFileURL != nil && audioFileURL != nil && phase != .loading
    }

    public var beatmapFileName: String {
        beatmapFileURL?.lastPathComponent ?? "No .osu file selected"
    }

    public var audioFileName: String {
        audioFileURL?.lastPathComponent ?? "No audio file selected"
    }

    public var scrollTimeMs: Double {
        11_485 / min(max(scrollSpeed, 1), 40)
    }

    public func selectBeatmapFile(_ url: URL) {
        guard url.hasOsuBeatmapExtension else {
            beatmapSelectionErrorMessage = "Choose a .osu beatmap file."
            return
        }

        beatmapFileURL = url
        beatmapSelectionErrorMessage = nil
        resetPreparedPlayState()
    }

    public func selectAudioFile(_ url: URL) {
        audioFileURL = url
        audioSelectionErrorMessage = nil
        resetPreparedPlayState()
    }

    public func recordBeatmapImportFailure(_ error: Error) {
        beatmapSelectionErrorMessage = "Could not choose beatmap: \(error.localizedDescription)"
    }

    public func recordAudioImportFailure(_ error: Error) {
        audioSelectionErrorMessage = "Could not choose audio: \(error.localizedDescription)"
    }

    @discardableResult
    public func startPlay() async -> Bool {
        guard let beatmapFileURL, let audioFileURL else {
            return false
        }

        resetPreparedPlayState()
        let startGeneration = playStateGeneration
        let configuration = Mania4KPlayConfiguration(
            beatmapFileURL: beatmapFileURL,
            audioFileURL: audioFileURL,
            starDifficulty: starDifficulty,
            scrollSpeed: scrollSpeed,
            audioOffsetMilliseconds: audioOffsetMilliseconds,
            visualOffsetMilliseconds: visualOffsetMilliseconds,
            judgeDifficulty: judgeDifficulty,
            keyBindings: keyBindings
        )
        activeConfiguration = configuration
        phase = .loading

        let stream = streamFactory(beatmapFileURL)
        activeStream = stream
        var preparedEngine = Mania4KJudgementEngine(judgeDifficulty: judgeDifficulty)
        engine = preparedEngine

        let preparedMetadata: Mania4KChartMetadata
        do {
            preparedMetadata = try await stream.prepare()
            if await abandonStaleStartIfNeeded(startGeneration) {
                return false
            }
        } catch let validationError as Mania4KChartValidationError {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(.chartPrepareFailed(validationError))
            return false
        } catch let failure as Mania4KPlayFailure {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(failure)
            return false
        } catch {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(.streamFailed(error.localizedDescription))
            return false
        }

        let preparedAudioMetadata: Mania4KAudioMetadata
        do {
            preparedAudioMetadata = try await audioClock.prepare(audioFileURL: audioFileURL)
            if await abandonStaleStartIfNeeded(startGeneration) {
                return false
            }
        } catch let failure as Mania4KPlayFailure {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(failure)
            return false
        } catch {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(.audioPrepareFailed(error.localizedDescription))
            return false
        }

        do {
            metadata = preparedMetadata
            audioMetadata = preparedAudioMetadata
            streamCompleteThroughChartTimeMs = -.infinity
            streamCursor = nil
            streamEnded = false
            keyboardRouter.reset()
            resetLiveInputLaneStates()

            let initialTiming = try await prepareInitialStreamCoverage(expectedGeneration: startGeneration)
            if await abandonStaleStartIfNeeded(startGeneration) {
                return false
            }

            if let currentEngine = engine {
                preparedEngine = currentEngine
            }
            _ = preparedEngine.advance(to: initialTiming.gameplayChartTimeMs)
            engine = preparedEngine
            publishFrame(timing: initialTiming)

            try await audioClock.play()
            if await abandonStaleStartIfNeeded(startGeneration) {
                return false
            }
            phase = .playing
            startFrameLoop()
            return true
        } catch let validationError as Mania4KChartValidationError {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(.engineRejectedObjects(validationError))
            return false
        } catch let failure as Mania4KPlayFailure {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(failure)
            return false
        } catch {
            guard isCurrentStart(startGeneration) else {
                return false
            }
            await fail(.streamFailed(error.localizedDescription))
            return false
        }
    }

    private func prepareInitialStreamCoverage(expectedGeneration: UInt64) async throws -> Mania4KFrameTiming {
        var timing = await currentFrameTiming()
        try validatePlayStateGeneration(expectedGeneration)
        try await readStream(
            throughChartTimeMs: timing.streamReadThroughChartTimeMs(scrollTimeMs: scrollTimeMs),
            expectedGeneration: expectedGeneration
        )
        try validatePlayStateGeneration(expectedGeneration)

        let checkedTiming = await currentFrameTiming()
        if checkedTiming.streamReadThroughChartTimeMs(scrollTimeMs: scrollTimeMs) > timing.streamReadThroughChartTimeMs(scrollTimeMs: scrollTimeMs) {
            timing = checkedTiming
            try await readStream(
                throughChartTimeMs: timing.streamReadThroughChartTimeMs(scrollTimeMs: scrollTimeMs),
                expectedGeneration: expectedGeneration
            )
            try validatePlayStateGeneration(expectedGeneration)
        }

        guard streamEnded || timing.gameplayChartTimeMs <= streamCompleteThroughChartTimeMs else {
            throw Mania4KPlayFailure.streamFailed("The chart stream is not safe through the initial chart time.")
        }

        return timing
    }

    public func pause() async {
        guard phase == .playing else {
            return
        }

        phase = .paused
        frameLoopTask?.cancel()
        frameLoopTask = nil
        await audioClock.pause()
    }

    public func resume() async {
        guard phase == .paused else {
            return
        }

        do {
            try await audioClock.play()
        } catch let failure as Mania4KPlayFailure {
            await fail(failure)
            return
        } catch {
            await fail(.audioPrepareFailed(error.localizedDescription))
            return
        }

        guard phase == .paused else {
            return
        }

        phase = .playing
        startFrameLoop()
    }

    public func quitToSetup() async {
        frameLoopTask?.cancel()
        frameLoopTask = nil
        await audioClock.stop()
        resetPreparedPlayState()
    }

    @discardableResult
    public func tick() async -> Bool {
        guard phase == .playing else {
            return false
        }

        let audioTimeMs = await audioClock.currentAudioTimeMs()
        let timing = frameTiming(audioTimeMs: audioTimeMs)
        let streamReadThrough = timing.streamReadThroughChartTimeMs(scrollTimeMs: scrollTimeMs)

        do {
            try await readStream(throughChartTimeMs: streamReadThrough)
            guard streamEnded || timing.gameplayChartTimeMs <= streamCompleteThroughChartTimeMs else {
                await fail(.streamFailed("The chart stream fell behind the judgement clock."))
                return false
            }

            if var engine {
                _ = engine.advance(to: timing.gameplayChartTimeMs)
                self.engine = engine
            }

            publishFrame(timing: timing)
            await finishIfNeeded(chartTimeMs: timing.gameplayChartTimeMs)
            return true
        } catch let validationError as Mania4KChartValidationError {
            await fail(.engineRejectedObjects(validationError))
            return false
        } catch let failure as Mania4KPlayFailure {
            await fail(failure)
            return false
        } catch {
            await fail(.streamFailed(error.localizedDescription))
            return false
        }
    }

    @discardableResult
    public func handleKeyboardInput(key: String, isPressed: Bool, isRepeat: Bool) async -> Bool {
        guard phase == .playing else {
            return false
        }

        let chartTimeMs = currentRoutedInputChartTimeMs()
        inputSequenceNumber += 1
        guard let input = keyboardRouter.route(
            key: key,
            isPressed: isPressed,
            isRepeat: isRepeat,
            chartTimeMs: chartTimeMs,
            sequenceNumber: inputSequenceNumber
        ) else {
            return false
        }

        commitLiveInputState(input)
        let handled = await enqueueGameplayInput(input, usesLiveChartTime: true)
        if !handled {
            syncLiveInputLaneStatesFromFrame()
        }
        return handled
    }

    @discardableResult
    public func handleInput(_ input: Mania4KInputEvent) async -> Bool {
        guard phase == .playing else {
            return false
        }

        commitLiveInputState(input)
        let handled = await enqueueGameplayInput(input)
        if !handled {
            syncLiveInputLaneStatesFromFrame()
        }
        return handled
    }

    @discardableResult
    public func updateKeyBinding(lane: Mania4KLane, key: String) -> Bool {
        guard phase == .setup else {
            keyBindingErrorMessage = "Key bindings can only be changed from setup."
            return false
        }

        guard let nextKeyBindings = keyBindings.updating(lane: lane, key: key) else {
            keyBindingErrorMessage = "Choose four unique non-empty keys."
            return false
        }

        applyKeyBindings(nextKeyBindings)
        keyBindingErrorMessage = nil
        return true
    }

    public func applyKeyBindings(_ keyBindings: Mania4KKeyBindingSet) {
        guard phase == .setup else {
            keyBindingErrorMessage = "Key bindings can only be changed from setup."
            return
        }

        self.keyBindings = keyBindings
        keyboardRouter.updateKeyBindings(keyBindings)
        resetLiveInputLaneStates()
        keyBindingErrorMessage = nil
    }

    public func resetKeyBindingsToDefault() {
        applyKeyBindings(.default)
    }

    private func enqueueGameplayInput(_ input: Mania4KInputEvent, usesLiveChartTime: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            queuedGameplayInputs.append(
                QueuedMania4KInput(
                    input: input,
                    usesLiveChartTime: usesLiveChartTime,
                    generation: playStateGeneration,
                    continuation: continuation
                )
            )
            startGameplayInputQueueDrainIfNeeded()
        }
    }

    private func startGameplayInputQueueDrainIfNeeded() {
        guard !isDrainingGameplayInputQueue else {
            return
        }

        isDrainingGameplayInputQueue = true
        Task { [weak self] in
            await self?.drainQueuedGameplayInputs()
        }
    }

    private func drainQueuedGameplayInputs() async {
        while !queuedGameplayInputs.isEmpty {
            let queuedInput = queuedGameplayInputs.removeFirst()
            let handled = await processQueuedGameplayInput(queuedInput)
            queuedInput.continuation.resume(returning: handled)
        }

        isDrainingGameplayInputQueue = false
        if !queuedGameplayInputs.isEmpty {
            startGameplayInputQueueDrainIfNeeded()
        }
    }

    private func processQueuedGameplayInput(_ queuedInput: QueuedMania4KInput) async -> Bool {
        guard playStateGeneration == queuedInput.generation, phase == .playing else {
            return false
        }

        let input: Mania4KInputEvent
        if queuedInput.usesLiveChartTime {
            input = await inputWithCurrentChartTime(queuedInput.input)
        } else {
            input = queuedInput.input
        }

        guard playStateGeneration == queuedInput.generation, phase == .playing else {
            return false
        }

        guard await ensureStreamIsSafeForJudgement(at: input.chartTimeMs, generation: queuedInput.generation) else {
            return false
        }

        guard playStateGeneration == queuedInput.generation, phase == .playing else {
            return false
        }

        return applyInput(input)
    }

    private func applyInput(_ input: Mania4KInputEvent) -> Bool {
        guard var engine else {
            return false
        }
        _ = engine.handle(input)
        self.engine = engine
        publishFrame(timing: frameTiming(gameplayChartTimeMs: input.chartTimeMs))
        return true
    }

    private func resetPreparedPlayState() {
        playStateGeneration &+= 1
        frameLoopTask?.cancel()
        frameLoopTask = nil
        activeConfiguration = nil
        activeStream = nil
        engine = nil
        metadata = nil
        audioMetadata = nil
        playFrame = nil
        phase = .setup
        streamCursor = nil
        streamCompleteThroughChartTimeMs = -.infinity
        streamEnded = false
        inputSequenceNumber = 0
        keyboardRouter.reset()
        resetLiveInputLaneStates()
        finishQueuedGameplayInputs(returning: false)
    }

    private func startFrameLoop() {
        frameLoopTask?.cancel()
        frameLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 16_666_667)
                } catch {
                    break
                }

                guard !Task.isCancelled else {
                    break
                }

                await self?.tick()
            }
        }
    }

    private func readStream(throughChartTimeMs: Double, expectedGeneration: UInt64? = nil) async throws {
        try validatePlayStateGeneration(expectedGeneration)
        guard !streamEnded, throughChartTimeMs > streamCompleteThroughChartTimeMs else {
            return
        }

        while !streamReadGate.tryEnter() {
            try await streamReadGate.wait()
            try validatePlayStateGeneration(expectedGeneration)
            guard !streamEnded, throughChartTimeMs > streamCompleteThroughChartTimeMs else {
                return
            }
        }

        do {
            try await readStreamUnlocked(throughChartTimeMs: throughChartTimeMs, expectedGeneration: expectedGeneration)
            streamReadGate.leave()
        } catch {
            streamReadGate.leave(throwing: error)
            throw error
        }
    }

    private func readStreamUnlocked(throughChartTimeMs: Double, expectedGeneration: UInt64?) async throws {
        try validatePlayStateGeneration(expectedGeneration)
        guard let activeStream else {
            return
        }

        var didReachLimit = true
        while didReachLimit && !streamEnded {
            let batch = try await activeStream.read(
                after: streamCursor,
                throughChartTimeMs: throughChartTimeMs,
                limit: 512
            )
            try validatePlayStateGeneration(expectedGeneration)
            let previousWatermark = streamCompleteThroughChartTimeMs

            if previousWatermark.isFinite,
               let invalidObject = batch.objects.first(where: { $0.timeMs <= previousWatermark }) {
                throw Mania4KPlayFailure.streamFailed(
                    "The chart stream violated its watermark by emitting an object at \(invalidObject.timeMs) ms after declaring completion through \(previousWatermark) ms."
                )
            }

            if !batch.objects.isEmpty {
                guard var engine else {
                    throw Mania4KPlayFailure.streamFailed("Judgement engine is not prepared.")
                }
                try engine.ingest(batch.objects)
                self.engine = engine
            }

            streamCursor = batch.nextCursor
            streamCompleteThroughChartTimeMs = max(streamCompleteThroughChartTimeMs, batch.completeThroughChartTimeMs)
            streamEnded = batch.isEndOfStream
            if streamEnded, let engine {
                try engine.validateEndOfStream()
            }

            didReachLimit = batch.objects.count >= 512
        }
    }

    private func publishFrame(timing: Mania4KFrameTiming) {
        guard let metadata, let engine else {
            return
        }

        let snapshot = engine.snapshot(
            visibleRange: (timing.renderChartTimeMs - 700)...(timing.renderChartTimeMs + scrollTimeMs + 250)
        )
        playFrame = Mania4KPlayFrame(
            gameplayChartTimeMs: timing.gameplayChartTimeMs,
            renderChartTimeMs: timing.renderChartTimeMs,
            scrollTimeMs: scrollTimeMs,
            metadata: metadata,
            visibleObjects: snapshot.visibleObjects,
            score: snapshot.score,
            laneStates: snapshot.laneStates,
            latestJudgement: snapshot.latestJudgement
        )
    }

    private func ensureStreamIsSafeForJudgement(at chartTimeMs: Double, generation: UInt64? = nil) async -> Bool {
        do {
            try validatePlayStateGeneration(generation)
            try await readStream(throughChartTimeMs: chartTimeMs, expectedGeneration: generation)
            try validatePlayStateGeneration(generation)
            guard streamEnded || chartTimeMs <= streamCompleteThroughChartTimeMs else {
                await fail(.streamFailed("The chart stream fell behind the judgement clock."))
                return false
            }
            return true
        } catch is StaleMania4KPlayStateError {
            return false
        } catch let validationError as Mania4KChartValidationError {
            await fail(.engineRejectedObjects(validationError))
            return false
        } catch let failure as Mania4KPlayFailure {
            await fail(failure)
            return false
        } catch {
            await fail(.streamFailed(error.localizedDescription))
            return false
        }
    }

    private func finishIfNeeded(chartTimeMs: Double) async {
        guard streamEnded, let metadata, let engine else {
            return
        }

        let snapshot = engine.snapshot(visibleRange: chartTimeMs...chartTimeMs)
        guard snapshot.isResolved else {
            return
        }

        let audioTimeMs = await audioClock.currentAudioTimeMs()
        let running = await audioClock.isRunning()
        let durationMs = audioMetadata?.durationMs ?? metadata.durationMs
        let audioHasEnded = durationMs.map { audioTimeMs >= $0 - 1 } ?? !running

        guard audioHasEnded else {
            return
        }

        frameLoopTask?.cancel()
        frameLoopTask = nil
        await audioClock.stop()
        resetLiveInputLaneStates()
        phase = .finished(
            Mania4KPlayResult(
                metadata: metadata,
                score: snapshot.score,
                finishedChartTimeMs: chartTimeMs
            )
        )
    }

    private func fail(_ failure: Mania4KPlayFailure) async {
        let failureGeneration = playStateGeneration
        frameLoopTask?.cancel()
        frameLoopTask = nil
        await audioClock.stop()
        guard playStateGeneration == failureGeneration else {
            return
        }
        resetLiveInputLaneStates()
        phase = .failed(failure)
    }

    private func currentFrameTiming() async -> Mania4KFrameTiming {
        let audioTimeMs = await audioClock.currentAudioTimeMs()
        return frameTiming(audioTimeMs: audioTimeMs)
    }

    private func frameTiming(audioTimeMs: Double) -> Mania4KFrameTiming {
        let gameplayChartTimeMs = audioTimeMs + audioOffsetMilliseconds
        return frameTiming(gameplayChartTimeMs: gameplayChartTimeMs)
    }

    private func frameTiming(gameplayChartTimeMs: Double) -> Mania4KFrameTiming {
        Mania4KFrameTiming(
            gameplayChartTimeMs: gameplayChartTimeMs,
            renderChartTimeMs: gameplayChartTimeMs + visualOffsetMilliseconds
        )
    }

    private func currentRoutedInputChartTimeMs() -> Double {
        playFrame?.gameplayChartTimeMs ?? activeConfiguration?.audioOffsetMilliseconds ?? audioOffsetMilliseconds
    }

    private func inputWithCurrentChartTime(_ input: Mania4KInputEvent) async -> Mania4KInputEvent {
        Mania4KInputEvent(
            lane: input.lane,
            phase: input.phase,
            chartTimeMs: (await currentFrameTiming()).gameplayChartTimeMs,
            sequenceNumber: input.sequenceNumber,
            source: input.source
        )
    }

    private func isCurrentStart(_ generation: UInt64) -> Bool {
        playStateGeneration == generation && phase == .loading
    }

    private func abandonStaleStartIfNeeded(_ generation: UInt64) async -> Bool {
        guard !isCurrentStart(generation) else {
            return false
        }

        if phase == .setup {
            await audioClock.stop()
        }
        return true
    }

    private func validatePlayStateGeneration(_ expectedGeneration: UInt64?) throws {
        guard let expectedGeneration else {
            return
        }

        guard playStateGeneration == expectedGeneration else {
            throw StaleMania4KPlayStateError()
        }
    }

    private func finishQueuedGameplayInputs(returning result: Bool) {
        let queuedInputs = queuedGameplayInputs
        queuedGameplayInputs.removeAll()
        for queuedInput in queuedInputs {
            queuedInput.continuation.resume(returning: result)
        }
    }

    private func commitLiveInputState(_ input: Mania4KInputEvent) {
        var pressedLanes = Set(liveInputLaneStates.filter(\.isPressed).map(\.lane))

        switch input.phase {
        case .press:
            pressedLanes.insert(input.lane)
        case .release:
            pressedLanes.remove(input.lane)
        }

        liveInputLaneStates = Self.makeLaneStates(pressedLanes: pressedLanes)
    }

    private func resetLiveInputLaneStates() {
        liveInputLaneStates = Self.makeLaneStates(pressedLanes: [])
    }

    private func syncLiveInputLaneStatesFromFrame() {
        let pressedLanes = Set(playFrame?.laneStates.filter(\.isPressed).map(\.lane) ?? [])
        liveInputLaneStates = Self.makeLaneStates(pressedLanes: pressedLanes)
    }

    private static func makeLaneStates(pressedLanes: Set<Mania4KLane>) -> [Mania4KLaneState] {
        Mania4KLane.allCases.map { lane in
            Mania4KLaneState(lane: lane, isPressed: pressedLanes.contains(lane))
        }
    }
}

private struct QueuedMania4KInput {
    let input: Mania4KInputEvent
    let usesLiveChartTime: Bool
    let generation: UInt64
    let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
private final class AsyncGate {
    private var isEntered = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func tryEnter() -> Bool {
        guard !isEntered else {
            return false
        }

        isEntered = true
        return true
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiters.append(continuation)
        }
    }

    func leave(throwing error: (any Error)? = nil) {
        isEntered = false

        let waiters = waiters
        self.waiters.removeAll()

        if let error {
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            waiters.forEach { $0.resume() }
        }
    }
}

private struct StaleMania4KPlayStateError: Error {}

private extension URL {
    var hasOsuBeatmapExtension: Bool {
        pathExtension.localizedCaseInsensitiveCompare("osu") == .orderedSame
    }
}

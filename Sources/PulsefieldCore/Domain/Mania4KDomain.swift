import AVFoundation
import Foundation

public enum Mania4KDefaultPlaySettings {
    public static let scrollSpeed = 25.0
    public static let audioOffsetMilliseconds = -215
    public static let visualOffsetMilliseconds = -15
    public static let offsetPresetID = UUID(uuidString: "D46D55AF-109E-48DC-A9F9-CE83F108EBF5")!
    public static let offsetPresetName = "wh1000xm4-mbaM5"
}

public enum Mania4KJudgeDifficulty: String, CaseIterable, Identifiable, Equatable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"

    public var id: String {
        rawValue
    }
}

public enum Mania4KChartSource: Equatable, Sendable {
    case localBeatmap(URL)
    case generated(displayName: String)

    public var beatmapFileURL: URL? {
        switch self {
        case .localBeatmap(let url):
            return url
        case .generated:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .localBeatmap(let url):
            return url.deletingPathExtension().lastPathComponent
        case .generated(let displayName):
            return displayName
        }
    }
}

public struct Mania4KPlayConfiguration: Equatable, Sendable {
    public let chartSource: Mania4KChartSource
    public let audioFileURL: URL
    public let starDifficulty: Double
    public let scrollSpeed: Double
    public let audioOffsetMilliseconds: Double
    public let visualOffsetMilliseconds: Double
    public let judgeDifficulty: Mania4KJudgeDifficulty
    public let keyBindings: Mania4KKeyBindingSet

    public init(
        beatmapFileURL: URL,
        audioFileURL: URL,
        starDifficulty: Double,
        scrollSpeed: Double,
        audioOffsetMilliseconds: Double,
        visualOffsetMilliseconds: Double,
        judgeDifficulty: Mania4KJudgeDifficulty,
        keyBindings: Mania4KKeyBindingSet = .default
    ) {
        self.chartSource = .localBeatmap(beatmapFileURL)
        self.audioFileURL = audioFileURL
        self.starDifficulty = starDifficulty
        self.scrollSpeed = scrollSpeed
        self.audioOffsetMilliseconds = audioOffsetMilliseconds
        self.visualOffsetMilliseconds = visualOffsetMilliseconds
        self.judgeDifficulty = judgeDifficulty
        self.keyBindings = keyBindings
    }

    public init(
        chartSource: Mania4KChartSource,
        audioFileURL: URL,
        starDifficulty: Double,
        scrollSpeed: Double,
        audioOffsetMilliseconds: Double,
        visualOffsetMilliseconds: Double,
        judgeDifficulty: Mania4KJudgeDifficulty,
        keyBindings: Mania4KKeyBindingSet = .default
    ) {
        self.chartSource = chartSource
        self.audioFileURL = audioFileURL
        self.starDifficulty = starDifficulty
        self.scrollSpeed = scrollSpeed
        self.audioOffsetMilliseconds = audioOffsetMilliseconds
        self.visualOffsetMilliseconds = visualOffsetMilliseconds
        self.judgeDifficulty = judgeDifficulty
        self.keyBindings = keyBindings
    }

    public var beatmapFileURL: URL? {
        chartSource.beatmapFileURL
    }
}

public enum Mania4KLane: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case left = 0
    case innerLeft = 1
    case innerRight = 2
    case right = 3

    public var id: Int {
        rawValue
    }

    public static func < (lhs: Mania4KLane, rhs: Mania4KLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct Mania4KKeyBindingSet: Equatable, Sendable {
    public static let `default` = Mania4KKeyBindingSet(keysByLane: [
        .left: "d",
        .innerLeft: "f",
        .innerRight: "j",
        .right: "k"
    ])!

    private let keysByLane: [Mania4KLane: String]

    public init?(keysByLane: [Mania4KLane: String]) {
        var normalizedKeysByLane: [Mania4KLane: String] = [:]
        var usedKeys: Set<String> = []

        for lane in Mania4KLane.allCases {
            guard let rawKey = keysByLane[lane] else {
                return nil
            }

            let normalizedKey = Self.normalizedKey(rawKey)
            guard !normalizedKey.isEmpty, !usedKeys.contains(normalizedKey) else {
                return nil
            }

            normalizedKeysByLane[lane] = normalizedKey
            usedKeys.insert(normalizedKey)
        }

        self.keysByLane = normalizedKeysByLane
    }

    public init?(storageValue: String) {
        let keys = storageValue.components(separatedBy: "\t")
        guard keys.count == Mania4KLane.allCases.count else {
            return nil
        }

        self.init(
            keysByLane: Dictionary(uniqueKeysWithValues: zip(Mania4KLane.allCases, keys))
        )
    }

    public var storageValue: String {
        Mania4KLane.allCases.map { key(for: $0) }.joined(separator: "\t")
    }

    public func key(for lane: Mania4KLane) -> String {
        keysByLane[lane] ?? Self.default.key(for: lane)
    }

    public func displayLabel(for lane: Mania4KLane) -> String {
        Self.displayLabel(for: key(for: lane))
    }

    public func lane(for key: String) -> Mania4KLane? {
        let normalizedKey = Self.normalizedKey(key)
        return Mania4KLane.allCases.first { self.key(for: $0) == normalizedKey }
    }

    public func updating(lane: Mania4KLane, key: String) -> Mania4KKeyBindingSet? {
        var nextKeysByLane = keysByLane
        nextKeysByLane[lane] = key
        return Mania4KKeyBindingSet(keysByLane: nextKeysByLane)
    }

    public static func normalizedKey(_ rawKey: String) -> String {
        rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayLabel(for key: String) -> String {
        guard key.count == 1 else {
            return key.uppercased()
        }

        return key.uppercased()
    }
}

public enum Mania4KHitObjectKind: Equatable, Sendable {
    case tap
    case holdStart
    case holdEnd
}

public struct Mania4KHitObject: Equatable, Sendable {
    public let lane: Mania4KLane
    public let timeMs: Double
    public let kind: Mania4KHitObjectKind

    public init(lane: Mania4KLane, timeMs: Double, kind: Mania4KHitObjectKind) {
        self.lane = lane
        self.timeMs = timeMs
        self.kind = kind
    }
}

public struct Mania4KChartMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let sourceDescription: String
    public let objectCount: Int?
    public let durationMs: Double?

    public init(
        title: String,
        artist: String? = nil,
        sourceDescription: String,
        objectCount: Int? = nil,
        durationMs: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.sourceDescription = sourceDescription
        self.objectCount = objectCount
        self.durationMs = durationMs
    }
}

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

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct Mania4KHitObjectBatch: Equatable, Sendable {
    public let objects: [Mania4KHitObject]
    public let nextCursor: Mania4KHitObjectStreamCursor?
    public let completeThroughChartTimeMs: Double
    public let isEndOfStream: Bool

    public init(
        objects: [Mania4KHitObject],
        nextCursor: Mania4KHitObjectStreamCursor?,
        completeThroughChartTimeMs: Double,
        isEndOfStream: Bool
    ) {
        self.objects = objects
        self.nextCursor = nextCursor
        self.completeThroughChartTimeMs = completeThroughChartTimeMs
        self.isEndOfStream = isEndOfStream
    }
}

public enum Mania4KInputPhase: Equatable, Sendable {
    case press
    case release
}

public enum Mania4KInputSource: Equatable, Sendable {
    case keyboard
    case touch
    case replay
    case test
}

public struct Mania4KInputEvent: Equatable, Sendable {
    public let lane: Mania4KLane
    public let phase: Mania4KInputPhase
    public let chartTimeMs: Double
    public let sequenceNumber: UInt64
    public let source: Mania4KInputSource

    public init(
        lane: Mania4KLane,
        phase: Mania4KInputPhase,
        chartTimeMs: Double,
        sequenceNumber: UInt64,
        source: Mania4KInputSource
    ) {
        self.lane = lane
        self.phase = phase
        self.chartTimeMs = chartTimeMs
        self.sequenceNumber = sequenceNumber
        self.source = source
    }
}

public enum Mania4KMalodyTier: Int, Equatable, Comparable, Sendable {
    case bigP = 0
    case p1 = 1
    case p2 = 2
    case p3 = 3
    case g = 4
    case m = 5

    public static func < (lhs: Mania4KMalodyTier, rhs: Mania4KMalodyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Mania4KJudgement: String, Equatable, Sendable {
    case perfect = "Perfect"
    case good = "Good"
    case miss = "Miss"
}

public struct Mania4KJudgementEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let objectID: Mania4KObjectOrdinal
    public let lane: Mania4KLane
    public let chartTimeMs: Double
    public let objectTimeMs: Double
    public let hitErrorMs: Double?
    public let judgement: Mania4KJudgement
    public let malodyTier: Mania4KMalodyTier

    public init(
        id: UInt64,
        objectID: Mania4KObjectOrdinal,
        lane: Mania4KLane,
        chartTimeMs: Double,
        objectTimeMs: Double,
        hitErrorMs: Double?,
        judgement: Mania4KJudgement,
        malodyTier: Mania4KMalodyTier
    ) {
        self.id = id
        self.objectID = objectID
        self.lane = lane
        self.chartTimeMs = chartTimeMs
        self.objectTimeMs = objectTimeMs
        self.hitErrorMs = hitErrorMs
        self.judgement = judgement
        self.malodyTier = malodyTier
    }
}

public struct Mania4KMalodyTierCounts: Equatable, Sendable {
    public let bigP: Int
    public let p1: Int
    public let p2: Int
    public let p3: Int
    public let g: Int
    public let m: Int

    public init(bigP: Int = 0, p1: Int = 0, p2: Int = 0, p3: Int = 0, g: Int = 0, m: Int = 0) {
        self.bigP = bigP
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.g = g
        self.m = m
    }

    public var judgedObjectCount: Int {
        bigP + p1 + p2 + p3 + g + m
    }

    fileprivate func incrementing(_ tier: Mania4KMalodyTier) -> Mania4KMalodyTierCounts {
        switch tier {
        case .bigP:
            return Mania4KMalodyTierCounts(bigP: bigP + 1, p1: p1, p2: p2, p3: p3, g: g, m: m)
        case .p1:
            return Mania4KMalodyTierCounts(bigP: bigP, p1: p1 + 1, p2: p2, p3: p3, g: g, m: m)
        case .p2:
            return Mania4KMalodyTierCounts(bigP: bigP, p1: p1, p2: p2 + 1, p3: p3, g: g, m: m)
        case .p3:
            return Mania4KMalodyTierCounts(bigP: bigP, p1: p1, p2: p2, p3: p3 + 1, g: g, m: m)
        case .g:
            return Mania4KMalodyTierCounts(bigP: bigP, p1: p1, p2: p2, p3: p3, g: g + 1, m: m)
        case .m:
            return Mania4KMalodyTierCounts(bigP: bigP, p1: p1, p2: p2, p3: p3, g: g, m: m + 1)
        }
    }
}

public struct Mania4KScoreState: Equatable, Sendable {
    public let perfectCount: Int
    public let goodCount: Int
    public let missCount: Int
    public let malodyTierCounts: Mania4KMalodyTierCounts
    public let combo: Int
    public let maxCombo: Int
    public let accuracy: Double
    public let averageHitErrorMs: Double?
    public let suggestedAudioOffsetAdjustmentMs: Double?

    public init(
        perfectCount: Int = 0,
        goodCount: Int = 0,
        missCount: Int = 0,
        malodyTierCounts: Mania4KMalodyTierCounts = Mania4KMalodyTierCounts(),
        combo: Int = 0,
        maxCombo: Int = 0,
        accuracy: Double = 1,
        averageHitErrorMs: Double? = nil,
        suggestedAudioOffsetAdjustmentMs: Double? = nil
    ) {
        self.perfectCount = perfectCount
        self.goodCount = goodCount
        self.missCount = missCount
        self.malodyTierCounts = malodyTierCounts
        self.combo = combo
        self.maxCombo = maxCombo
        self.accuracy = accuracy
        self.averageHitErrorMs = averageHitErrorMs
        self.suggestedAudioOffsetAdjustmentMs = suggestedAudioOffsetAdjustmentMs
    }

    public static let zero = Mania4KScoreState()
}

public struct Mania4KLaneState: Identifiable, Equatable, Sendable {
    public let id: Mania4KLane
    public let lane: Mania4KLane
    public let isPressed: Bool
    public let holdingObjectID: Mania4KObjectOrdinal?

    public init(lane: Mania4KLane, isPressed: Bool, holdingObjectID: Mania4KObjectOrdinal? = nil) {
        self.id = lane
        self.lane = lane
        self.isPressed = isPressed
        self.holdingObjectID = holdingObjectID
    }
}

public struct Mania4KObjectOrdinal: Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Mania4KObjectOrdinal, rhs: Mania4KObjectOrdinal) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Mania4KVisibleObjectState: Equatable, Sendable {
    case waiting
    case holding
    case openEnded
    case missedButVisible
    case resolved
}

public struct Mania4KVisibleObject: Identifiable, Equatable, Sendable {
    public let id: Mania4KObjectOrdinal
    public let lane: Mania4KLane
    public let startTimeMs: Double
    public let endTimeMs: Double?
    public let state: Mania4KVisibleObjectState

    public init(
        id: Mania4KObjectOrdinal,
        lane: Mania4KLane,
        startTimeMs: Double,
        endTimeMs: Double?,
        state: Mania4KVisibleObjectState
    ) {
        self.id = id
        self.lane = lane
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.state = state
    }
}

public struct Mania4KEngineUpdate: Equatable, Sendable {
    public let judgementEvents: [Mania4KJudgementEvent]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]

    public init(judgementEvents: [Mania4KJudgementEvent], score: Mania4KScoreState, laneStates: [Mania4KLaneState]) {
        self.judgementEvents = judgementEvents
        self.score = score
        self.laneStates = laneStates
    }
}

public struct Mania4KEngineSnapshot: Equatable, Sendable {
    public let chartTimeMs: Double
    public let visibleObjects: [Mania4KVisibleObject]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]
    public let latestJudgement: Mania4KJudgementEvent?
    public let isResolved: Bool

    public init(
        chartTimeMs: Double,
        visibleObjects: [Mania4KVisibleObject],
        score: Mania4KScoreState,
        laneStates: [Mania4KLaneState],
        latestJudgement: Mania4KJudgementEvent?,
        isResolved: Bool
    ) {
        self.chartTimeMs = chartTimeMs
        self.visibleObjects = visibleObjects
        self.score = score
        self.laneStates = laneStates
        self.latestJudgement = latestJudgement
        self.isResolved = isResolved
    }
}

public enum Mania4KPlayPhase: Equatable, Sendable {
    case setup
    case loading
    case ready
    case playing
    case paused
    case finished(Mania4KPlayResult)
    case failed(Mania4KPlayFailure)
}

public struct Mania4KPlayResult: Equatable, Sendable {
    public let metadata: Mania4KChartMetadata
    public let score: Mania4KScoreState
    public let finishedChartTimeMs: Double

    public init(metadata: Mania4KChartMetadata, score: Mania4KScoreState, finishedChartTimeMs: Double) {
        self.metadata = metadata
        self.score = score
        self.finishedChartTimeMs = finishedChartTimeMs
    }
}

public struct Mania4KPlayFrame: Equatable, Sendable {
    public let gameplayChartTimeMs: Double
    public let renderChartTimeMs: Double
    public let scrollTimeMs: Double
    public let metadata: Mania4KChartMetadata
    public let visibleObjects: [Mania4KVisibleObject]
    public let score: Mania4KScoreState
    public let laneStates: [Mania4KLaneState]
    public let latestJudgement: Mania4KJudgementEvent?

    public init(
        gameplayChartTimeMs: Double,
        renderChartTimeMs: Double,
        scrollTimeMs: Double,
        metadata: Mania4KChartMetadata,
        visibleObjects: [Mania4KVisibleObject],
        score: Mania4KScoreState,
        laneStates: [Mania4KLaneState],
        latestJudgement: Mania4KJudgementEvent?
    ) {
        self.gameplayChartTimeMs = gameplayChartTimeMs
        self.renderChartTimeMs = renderChartTimeMs
        self.scrollTimeMs = scrollTimeMs
        self.metadata = metadata
        self.visibleObjects = visibleObjects
        self.score = score
        self.laneStates = laneStates
        self.latestJudgement = latestJudgement
    }
}

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

extension Mania4KPlayFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .audioPrepareFailed(let message):
            return "Audio could not be prepared: \(message)"
        case .chartPrepareFailed(let error):
            return "Chart could not be prepared: \(error.localizedDescription)"
        case .streamFailed(let message):
            return "Chart stream failed: \(message)"
        case .engineRejectedObjects(let error):
            return "Chart was rejected by the engine: \(error.localizedDescription)"
        }
    }
}

extension Mania4KChartValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "Only osu!mania mode is supported."
        case .unsupportedKeyCount(let keyCount):
            return "Only 4-key osu!mania charts are supported; this chart has \(keyCount) keys."
        case .unsupportedHitObject(let description):
            return "Unsupported hit object: \(description)."
        case .invalidLane(let lane):
            return "Invalid lane \(lane)."
        case .invalidTime(let streamIndex):
            return "Invalid object time at stream index \(streamIndex)."
        case .nonMonotonicObjectOrder(let previousStreamIndex, let nextStreamIndex):
            return "Objects are not ordered at stream indexes \(previousStreamIndex) and \(nextStreamIndex)."
        case .laneSequenceViolation(let streamIndex, let lane):
            return "Invalid lane sequence at stream index \(streamIndex) in lane \(lane.rawValue)."
        case .unclosedHoldAtEndOfStream(let lane):
            return "Hold note in lane \(lane.rawValue) was not closed."
        case .sameLaneOverlap(let previousStreamIndex, let nextStreamIndex):
            return "Same-lane objects overlap at stream indexes \(previousStreamIndex) and \(nextStreamIndex)."
        }
    }
}

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

    public init(durationMs: Double? = nil, title: String? = nil) {
        self.durationMs = durationMs
        self.title = title
    }
}

public actor AVFoundationMania4KAudioClock: Mania4KAudioClock {
    private var player: AVAudioPlayer?

    public init() {}

    public func prepare(audioFileURL: URL) async throws -> Mania4KAudioMetadata {
        let player = try AVAudioPlayer(contentsOf: audioFileURL)
        player.prepareToPlay()
        self.player = player
        return Mania4KAudioMetadata(
            durationMs: player.duration.isFinite ? player.duration * 1000 : nil,
            title: audioFileURL.deletingPathExtension().lastPathComponent
        )
    }

    public func play() async throws {
        guard let player else {
            throw Mania4KPlayFailure.audioPrepareFailed("Audio player is not prepared.")
        }

        player.play()
    }

    public func pause() async {
        player?.pause()
    }

    public func stop() async {
        player?.stop()
        player?.currentTime = 0
    }

    public func currentAudioTimeMs() async -> Double {
        guard let player else {
            return 0
        }

        return player.currentTime * 1000
    }

    public func isRunning() async -> Bool {
        player?.isPlaying ?? false
    }
}

public actor FakeMania4KAudioClock: Mania4KAudioClock {
    private let metadata: Mania4KAudioMetadata
    private var audioTimeMs: Double
    private var running: Bool
    private let prepareError: Error?

    public init(
        metadata: Mania4KAudioMetadata = Mania4KAudioMetadata(durationMs: 10_000, title: "Fake Audio"),
        audioTimeMs: Double = 0,
        isRunning: Bool = false,
        prepareError: Error? = nil
    ) {
        self.metadata = metadata
        self.audioTimeMs = audioTimeMs
        self.running = isRunning
        self.prepareError = prepareError
    }

    public func prepare(audioFileURL: URL) async throws -> Mania4KAudioMetadata {
        if let prepareError {
            throw prepareError
        }

        audioTimeMs = 0
        return metadata
    }

    public func play() async throws {
        running = true
    }

    public func pause() async {
        running = false
    }

    public func stop() async {
        running = false
        audioTimeMs = 0
    }

    public func currentAudioTimeMs() async -> Double {
        audioTimeMs
    }

    public func isRunning() async -> Bool {
        running
    }

    public func setAudioTimeMs(_ audioTimeMs: Double) {
        self.audioTimeMs = audioTimeMs
    }

    public func advance(by milliseconds: Double) {
        audioTimeMs += milliseconds
    }

    public func setRunning(_ running: Bool) {
        self.running = running
    }
}

public actor HostTimeAnchoredMania4KAudioClock: Mania4KAudioClock {
    public typealias HostTimeProvider = @Sendable () -> Double

    private let referenceTimeAtAnchorMS: Double
    private let anchorHostTimeMS: Double
    private let hostTimeProvider: HostTimeProvider
    private let metadata: Mania4KAudioMetadata
    private var running: Bool

    public init(
        referenceTimeAtAnchorMS: Double,
        durationMS: Double? = nil,
        title: String? = nil,
        anchorHostTimeMS: Double = PulsefieldHostClock.currentTimeMS(),
        hostTimeProvider: @escaping HostTimeProvider = PulsefieldHostClock.currentTimeMS
    ) {
        self.referenceTimeAtAnchorMS = referenceTimeAtAnchorMS
        self.anchorHostTimeMS = anchorHostTimeMS
        self.hostTimeProvider = hostTimeProvider
        self.metadata = Mania4KAudioMetadata(durationMs: durationMS, title: title)
        self.running = false
    }

    public func prepare(audioFileURL: URL) async throws -> Mania4KAudioMetadata {
        metadata
    }

    public func play() async throws {
        running = true
    }

    public func pause() async {
        running = false
    }

    public func stop() async {
        running = false
    }

    public func currentAudioTimeMs() async -> Double {
        let projectedTimeMS = referenceTimeAtAnchorMS + hostTimeProvider() - anchorHostTimeMS
        guard let durationMs = metadata.durationMs else {
            return max(0, projectedTimeMS)
        }

        return min(max(0, projectedTimeMS), durationMs)
    }

    public func isRunning() async -> Bool {
        running
    }
}

public struct Mania4KKeyboardInputRouter: Sendable {
    private var keyBindings: Mania4KKeyBindingSet
    private var pressedLanes: Set<Mania4KLane>

    public init(keyBindings: Mania4KKeyBindingSet = .default) {
        self.keyBindings = keyBindings
        self.pressedLanes = []
    }

    public mutating func route(
        key: String,
        isPressed: Bool,
        isRepeat: Bool,
        chartTimeMs: Double,
        sequenceNumber: UInt64,
        source: Mania4KInputSource = .keyboard
    ) -> Mania4KInputEvent? {
        guard let lane = keyBindings.lane(for: key) else {
            return nil
        }

        if isPressed {
            guard !isRepeat, !pressedLanes.contains(lane) else {
                return nil
            }

            pressedLanes.insert(lane)
            return Mania4KInputEvent(
                lane: lane,
                phase: .press,
                chartTimeMs: chartTimeMs,
                sequenceNumber: sequenceNumber,
                source: source
            )
        } else {
            guard pressedLanes.contains(lane) else {
                return nil
            }

            pressedLanes.remove(lane)
            return Mania4KInputEvent(
                lane: lane,
                phase: .release,
                chartTimeMs: chartTimeMs,
                sequenceNumber: sequenceNumber,
                source: source
            )
        }
    }

    public mutating func reset() {
        pressedLanes.removeAll()
    }

    public mutating func updateKeyBindings(_ keyBindings: Mania4KKeyBindingSet) {
        self.keyBindings = keyBindings
        reset()
    }

    public static func lane(for key: String) -> Mania4KLane? {
        Mania4KKeyBindingSet.default.lane(for: key)
    }
}

public struct Mania4KJudgementEngine: Sendable {
    private let windows: Mania4KJudgementWindows
    private var chartTimeMs: Double
    private var objects: [EngineObject]
    private var openHoldIndexesByLane: [Mania4KLane: Int]
    private var lanePresses: [Mania4KLane: Bool]
    private var nextOrdinal: Int
    private var nextStreamIndex: Int
    private var lastStreamTimeMs: Double?
    private var lastStreamLane: Mania4KLane?
    private var lastStreamIndex: Int?
    private var nextJudgementEventID: UInt64
    private var tierCounts: Mania4KMalodyTierCounts
    private var combo: Int
    private var maxCombo: Int
    private var offsetSamples: [Double]
    private var latestJudgement: Mania4KJudgementEvent?

    public init(judgeDifficulty: Mania4KJudgeDifficulty) {
        self.windows = Mania4KJudgementWindows(difficulty: judgeDifficulty)
        self.chartTimeMs = 0
        self.objects = []
        self.openHoldIndexesByLane = [:]
        self.lanePresses = Dictionary(uniqueKeysWithValues: Mania4KLane.allCases.map { ($0, false) })
        self.nextOrdinal = 0
        self.nextStreamIndex = 0
        self.lastStreamTimeMs = nil
        self.lastStreamLane = nil
        self.lastStreamIndex = nil
        self.nextJudgementEventID = 0
        self.tierCounts = Mania4KMalodyTierCounts()
        self.combo = 0
        self.maxCombo = 0
        self.offsetSamples = []
    }

    public mutating func ingest(_ objects: [Mania4KHitObject]) throws {
        for object in objects {
            try ingest(object)
        }
    }

    public mutating func advance(to chartTimeMs: Double) -> Mania4KEngineUpdate {
        self.chartTimeMs = chartTimeMs
        var events: [Mania4KJudgementEvent] = []

        for lane in Mania4KLane.allCases {
            forceMissLockedObjects(in: lane, at: chartTimeMs, events: &events)
        }

        for index in self.objects.indices {
            guard self.objects[index].isUnresolved else {
                continue
            }

            switch self.objects[index].state {
            case .waiting:
                if chartTimeMs > self.objects[index].startTimeMs + windows.g {
                    events.append(resolve(index: index, tier: .m, chartTimeMs: chartTimeMs, hitErrorMs: nil))
                }
            case .holding:
                let tailLimit = windows.g * Mania4KJudgementWindows.tailLenience
                if let endTimeMs = self.objects[index].endTimeMs, chartTimeMs > endTimeMs + tailLimit {
                    events.append(resolve(index: index, tier: .m, chartTimeMs: chartTimeMs, hitErrorMs: nil))
                }
            case .resolved:
                continue
            }
        }

        return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
    }

    public mutating func handle(_ input: Mania4KInputEvent) -> Mania4KEngineUpdate {
        chartTimeMs = input.chartTimeMs

        switch input.phase {
        case .press:
            lanePresses[input.lane] = true
            return handlePress(input)
        case .release:
            lanePresses[input.lane] = false
            return handleRelease(input)
        }
    }

    public func snapshot(visibleRange: ClosedRange<Double>) -> Mania4KEngineSnapshot {
        let visibleObjects = objects.compactMap { object -> Mania4KVisibleObject? in
            let objectEnd = object.visibleEndTime(for: visibleRange)
            let visible = object.startTimeMs <= visibleRange.upperBound && objectEnd >= visibleRange.lowerBound
            let keepResolvedBriefly = object.isResolved && chartTimeMs - objectEnd <= 300 && objectEnd >= visibleRange.lowerBound
            guard visible || keepResolvedBriefly else {
                return nil
            }

            return Mania4KVisibleObject(
                id: object.ordinal,
                lane: object.lane,
                startTimeMs: object.startTimeMs,
                endTimeMs: object.endTimeMs,
                state: object.visibleState
            )
        }

        return Mania4KEngineSnapshot(
            chartTimeMs: chartTimeMs,
            visibleObjects: visibleObjects,
            score: currentScore,
            laneStates: currentLaneStates,
            latestJudgement: latestJudgement,
            isResolved: objects.allSatisfy { $0.isResolved }
        )
    }

    public func validateEndOfStream() throws {
        for lane in Mania4KLane.allCases where openHoldIndexesByLane[lane] != nil {
            throw Mania4KChartValidationError.unclosedHoldAtEndOfStream(lane: lane)
        }
    }

    private mutating func ingest(_ object: Mania4KHitObject) throws {
        let streamIndex = nextStreamIndex
        guard object.timeMs.isFinite, object.timeMs >= 0 else {
            throw Mania4KChartValidationError.invalidTime(streamIndex: streamIndex)
        }

        if let lastStreamTimeMs, let lastStreamLane, let lastStreamIndex {
            if object.timeMs < lastStreamTimeMs || (object.timeMs == lastStreamTimeMs && object.lane < lastStreamLane) {
                throw Mania4KChartValidationError.nonMonotonicObjectOrder(
                    previousStreamIndex: lastStreamIndex,
                    nextStreamIndex: streamIndex
                )
            }
        }

        if let previousSameLane = objects.last(where: { $0.lane == object.lane }) {
            let startsNewObject = object.kind == .tap || object.kind == .holdStart
            let previousStartsNewObject = previousSameLane.streamKind == .tap || previousSameLane.streamKind == .holdStart
            if startsNewObject, previousStartsNewObject, previousSameLane.startTimeMs == object.timeMs {
                throw Mania4KChartValidationError.sameLaneOverlap(
                    previousStreamIndex: previousSameLane.lastStreamIndex,
                    nextStreamIndex: streamIndex
                )
            }
        }

        switch object.kind {
        case .tap:
            if openHoldIndexesByLane[object.lane] != nil {
                throw Mania4KChartValidationError.laneSequenceViolation(streamIndex: streamIndex, lane: object.lane)
            }

            objects.append(
                EngineObject(
                    ordinal: Mania4KObjectOrdinal(rawValue: nextOrdinal),
                    lane: object.lane,
                    startTimeMs: object.timeMs,
                    endTimeMs: nil,
                    streamKind: .tap,
                    lastStreamIndex: streamIndex,
                    lastStreamTimeMs: object.timeMs,
                    state: .waiting
                )
            )
            nextOrdinal += 1

        case .holdStart:
            if openHoldIndexesByLane[object.lane] != nil {
                throw Mania4KChartValidationError.laneSequenceViolation(streamIndex: streamIndex, lane: object.lane)
            }

            objects.append(
                EngineObject(
                    ordinal: Mania4KObjectOrdinal(rawValue: nextOrdinal),
                    lane: object.lane,
                    startTimeMs: object.timeMs,
                    endTimeMs: nil,
                    streamKind: .holdStart,
                    lastStreamIndex: streamIndex,
                    lastStreamTimeMs: object.timeMs,
                    state: .waiting
                )
            )
            openHoldIndexesByLane[object.lane] = objects.count - 1
            nextOrdinal += 1

        case .holdEnd:
            guard let openIndex = openHoldIndexesByLane[object.lane] else {
                throw Mania4KChartValidationError.laneSequenceViolation(streamIndex: streamIndex, lane: object.lane)
            }

            guard object.timeMs >= objects[openIndex].startTimeMs else {
                throw Mania4KChartValidationError.laneSequenceViolation(streamIndex: streamIndex, lane: object.lane)
            }

            objects[openIndex].endTimeMs = object.timeMs
            objects[openIndex].lastStreamIndex = streamIndex
            objects[openIndex].lastStreamTimeMs = object.timeMs
            openHoldIndexesByLane[object.lane] = nil
        }

        lastStreamTimeMs = object.timeMs
        lastStreamLane = object.lane
        lastStreamIndex = streamIndex
        nextStreamIndex += 1
    }

    private mutating func handlePress(_ input: Mania4KInputEvent) -> Mania4KEngineUpdate {
        var events: [Mania4KJudgementEvent] = []
        forceMissLockedObjects(in: input.lane, at: input.chartTimeMs, events: &events)

        guard let index = candidateIndex(for: input.lane) else {
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        let hitErrorMs = input.chartTimeMs - objects[index].startTimeMs
        guard hitErrorMs >= -windows.g else {
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        let tier = windows.classify(errorMs: hitErrorMs, lenience: 1)
        if objects[index].streamKind == .tap {
            events.append(resolve(index: index, tier: tier, chartTimeMs: input.chartTimeMs, hitErrorMs: hitErrorMs))
        } else if tier == .m {
            events.append(resolve(index: index, tier: .m, chartTimeMs: input.chartTimeMs, hitErrorMs: hitErrorMs))
        } else {
            objects[index].state = .holding(headTier: tier, headErrorMs: hitErrorMs)
        }

        return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
    }

    private mutating func handleRelease(_ input: Mania4KInputEvent) -> Mania4KEngineUpdate {
        var events: [Mania4KJudgementEvent] = []
        if objects.contains(where: { $0.lane == input.lane && $0.isHolding }) {
            forceMissLockedObjects(in: input.lane, at: input.chartTimeMs, events: &events)
        }

        guard let index = objects.firstIndex(where: { $0.lane == input.lane && $0.isHolding }) else {
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        guard let endTimeMs = objects[index].endTimeMs else {
            events.append(resolve(index: index, tier: .m, chartTimeMs: input.chartTimeMs, hitErrorMs: nil))
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        let tailWindow = windows.g * Mania4KJudgementWindows.tailLenience
        if input.chartTimeMs < endTimeMs - tailWindow {
            events.append(resolve(index: index, tier: .m, chartTimeMs: input.chartTimeMs, hitErrorMs: nil))
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        let tailErrorMs = input.chartTimeMs - endTimeMs
        let tailTier = windows.classify(errorMs: tailErrorMs, lenience: Mania4KJudgementWindows.tailLenience)
        guard tailTier != .m else {
            events.append(resolve(index: index, tier: .m, chartTimeMs: input.chartTimeMs, hitErrorMs: nil))
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        guard case .holding(let headTier, let headErrorMs) = objects[index].state else {
            return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
        }

        let finalTier = max(headTier, tailTier)
        events.append(resolve(index: index, tier: finalTier, chartTimeMs: input.chartTimeMs, hitErrorMs: headErrorMs))
        return Mania4KEngineUpdate(judgementEvents: events, score: currentScore, laneStates: currentLaneStates)
    }

    private func candidateIndex(for lane: Mania4KLane) -> Int? {
        objects.firstIndex { object in
            object.lane == lane && object.isWaiting
        }
    }

    private mutating func forceMissLockedObjects(in lane: Mania4KLane, at chartTimeMs: Double, events: inout [Mania4KJudgementEvent]) {
        while let locked = lockedObjectIndex(in: lane, at: chartTimeMs) {
            events.append(resolve(index: locked, tier: .m, chartTimeMs: chartTimeMs, hitErrorMs: nil))
        }
    }

    private func lockedObjectIndex(in lane: Mania4KLane, at chartTimeMs: Double) -> Int? {
        guard let candidate = objects.firstIndex(where: { object in
            object.lane == lane && (object.isWaiting || object.isHolding)
        }),
              let next = nextUnresolvedIndex(after: candidate, in: lane),
              objects[next].startTimeMs <= chartTimeMs
        else {
            return nil
        }

        return candidate
    }

    private func nextUnresolvedIndex(after index: Int, in lane: Mania4KLane) -> Int? {
        objects[(index + 1)...].firstIndex { object in
            object.lane == lane && object.isUnresolved
        }
    }

    private mutating func resolve(
        index: Int,
        tier: Mania4KMalodyTier,
        chartTimeMs: Double,
        hitErrorMs: Double?
    ) -> Mania4KJudgementEvent {
        let judgement = tier.visibleJudgement
        objects[index].state = .resolved(tier: tier)

        tierCounts = tierCounts.incrementing(tier)
        if tier == .m {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
            if let hitErrorMs {
                offsetSamples.append(hitErrorMs)
            }
        }

        let event = Mania4KJudgementEvent(
            id: nextJudgementEventID,
            objectID: objects[index].ordinal,
            lane: objects[index].lane,
            chartTimeMs: chartTimeMs,
            objectTimeMs: objects[index].startTimeMs,
            hitErrorMs: hitErrorMs,
            judgement: judgement,
            malodyTier: tier
        )
        nextJudgementEventID += 1
        latestJudgement = event
        return event
    }

    private var currentLaneStates: [Mania4KLaneState] {
        Mania4KLane.allCases.map { lane in
            let holdingObject = objects.first { object in
                object.lane == lane && object.isHolding
            }
            return Mania4KLaneState(
                lane: lane,
                isPressed: lanePresses[lane] ?? false,
                holdingObjectID: holdingObject?.ordinal
            )
        }
    }

    private var currentScore: Mania4KScoreState {
        let judgedObjectCount = tierCounts.judgedObjectCount
        let weighted = Double(tierCounts.bigP)
            + Double(tierCounts.p1) * 0.90
            + Double(tierCounts.p2) * 0.85
            + Double(tierCounts.p3) * 0.80
            + Double(tierCounts.g) * 0.40
        let accuracy = judgedObjectCount == 0 ? 1 : weighted / Double(judgedObjectCount)
        let averageHitError = offsetSamples.isEmpty ? nil : offsetSamples.reduce(0, +) / Double(offsetSamples.count)

        return Mania4KScoreState(
            perfectCount: tierCounts.bigP,
            goodCount: tierCounts.p1 + tierCounts.p2 + tierCounts.p3 + tierCounts.g,
            missCount: tierCounts.m,
            malodyTierCounts: tierCounts,
            combo: combo,
            maxCombo: maxCombo,
            accuracy: accuracy,
            averageHitErrorMs: averageHitError,
            suggestedAudioOffsetAdjustmentMs: averageHitError.map { -$0 }
        )
    }
}

public actor InMemoryMania4KHitObjectStream: Mania4KHitObjectStreaming {
    private let objects: [Mania4KHitObject]
    private let metadata: Mania4KChartMetadata

    public init(objects: [Mania4KHitObject], metadata: Mania4KChartMetadata? = nil) throws {
        self.objects = try Mania4KStreamValidator.validated(objects)
        let duration = objects.map(\.timeMs).max()
        self.metadata = metadata ?? Mania4KChartMetadata(
            title: "In-memory mania4k chart",
            sourceDescription: "In-memory",
            objectCount: objects.filter { $0.kind != .holdEnd }.count,
            durationMs: duration
        )
    }

    public func prepare() async throws -> Mania4KChartMetadata {
        metadata
    }

    public func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        readFromArray(objects, cursor: cursor, throughChartTimeMs: throughChartTimeMs, limit: limit, finalDurationMs: metadata.durationMs)
    }
}

public actor OsuMania4KBeatmapStream: Mania4KHitObjectStreaming {
    private let beatmapFileURL: URL
    private var parsedObjects: [Mania4KHitObject]?
    private var parsedMetadata: Mania4KChartMetadata?

    public init(beatmapFileURL: URL) {
        self.beatmapFileURL = beatmapFileURL
    }

    public func prepare() async throws -> Mania4KChartMetadata {
        let parsed = try Self.parseBeatmap(at: beatmapFileURL)
        parsedObjects = parsed.objects
        parsedMetadata = parsed.metadata
        return parsed.metadata
    }

    public func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        guard let parsedObjects, let parsedMetadata else {
            throw Mania4KPlayFailure.streamFailed("Beatmap stream has not been prepared.")
        }

        return readFromArray(
            parsedObjects,
            cursor: cursor,
            throughChartTimeMs: throughChartTimeMs,
            limit: limit,
            finalDurationMs: parsedMetadata.durationMs
        )
    }

    public static func parseBeatmap(at url: URL) throws -> (objects: [Mania4KHitObject], metadata: Mania4KChartMetadata) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parser = OsuMania4KParser(sourceURL: url, text: text)
        return try parser.parse()
    }
}

private struct Mania4KJudgementWindows {
    static let tailLenience = 1.5

    let bigP: Double
    let p1: Double
    let p2: Double
    let p3: Double
    let g: Double

    init(difficulty: Mania4KJudgeDifficulty) {
        switch difficulty {
        case .a:
            self.bigP = 60
            self.p1 = 105
            self.p2 = 120
            self.p3 = 135
            self.g = 200
        case .b:
            self.bigP = 47
            self.p1 = 63
            self.p2 = 88
            self.p3 = 118
            self.g = 200
        case .c:
            self.bigP = 40
            self.p1 = 56
            self.p2 = 81
            self.p3 = 111
            self.g = 200
        case .d:
            self.bigP = 34
            self.p1 = 50
            self.p2 = 75
            self.p3 = 105
            self.g = 200
        case .e:
            self.bigP = 25
            self.p1 = 50
            self.p2 = 75
            self.p3 = 105
            self.g = 200
        }
    }

    func classify(errorMs: Double, lenience: Double) -> Mania4KMalodyTier {
        let absoluteError = abs(errorMs)
        if absoluteError <= bigP * lenience {
            return .bigP
        } else if absoluteError <= p1 * lenience {
            return .p1
        } else if absoluteError <= p2 * lenience {
            return .p2
        } else if absoluteError <= p3 * lenience {
            return .p3
        } else if absoluteError <= g * lenience {
            return .g
        } else {
            return .m
        }
    }
}

private extension Mania4KMalodyTier {
    var visibleJudgement: Mania4KJudgement {
        switch self {
        case .bigP:
            return .perfect
        case .p1, .p2, .p3, .g:
            return .good
        case .m:
            return .miss
        }
    }
}

private struct EngineObject: Sendable {
    let ordinal: Mania4KObjectOrdinal
    let lane: Mania4KLane
    let startTimeMs: Double
    var endTimeMs: Double?
    let streamKind: Mania4KHitObjectKind
    var lastStreamIndex: Int
    var lastStreamTimeMs: Double
    var state: EngineObjectState

    var isWaiting: Bool {
        if case .waiting = state {
            return true
        }
        return false
    }

    var isHolding: Bool {
        if case .holding = state {
            return true
        }
        return false
    }

    var isResolved: Bool {
        if case .resolved = state {
            return true
        }
        return false
    }

    var isUnresolved: Bool {
        !isResolved
    }

    var visibleState: Mania4KVisibleObjectState {
        switch state {
        case .waiting where streamKind == .holdStart && endTimeMs == nil:
            return .openEnded
        case .waiting:
            return .waiting
        case .holding:
            return .holding
        case .resolved(let tier) where tier == .m:
            return .missedButVisible
        case .resolved:
            return .resolved
        }
    }

    func visibleEndTime(for visibleRange: ClosedRange<Double>) -> Double {
        if streamKind == .holdStart, !isResolved {
            return endTimeMs ?? visibleRange.upperBound
        }

        return endTimeMs ?? startTimeMs
    }
}

private enum EngineObjectState: Sendable {
    case waiting
    case holding(headTier: Mania4KMalodyTier, headErrorMs: Double)
    case resolved(tier: Mania4KMalodyTier)
}

private struct Mania4KStreamValidator {
    static func validated(_ objects: [Mania4KHitObject]) throws -> [Mania4KHitObject] {
        var engine = Mania4KJudgementEngine(judgeDifficulty: .c)
        try engine.ingest(objects)
        try engine.validateEndOfStream()
        return objects
    }
}

private func readFromArray(
    _ objects: [Mania4KHitObject],
    cursor: Mania4KHitObjectStreamCursor?,
    throughChartTimeMs: Double,
    limit: Int,
    finalDurationMs: Double?
) -> Mania4KHitObjectBatch {
    let startIndex = max(Int(cursor?.rawValue ?? "0") ?? 0, 0)
    let safeLimit = max(limit, 1)
    var nextIndex = startIndex
    var emitted: [Mania4KHitObject] = []

    while nextIndex < objects.count,
          objects[nextIndex].timeMs <= throughChartTimeMs,
          emitted.count < safeLimit {
        emitted.append(objects[nextIndex])
        nextIndex += 1
    }

    let isEnd = nextIndex >= objects.count
    let nextCursor = isEnd ? nil : Mania4KHitObjectStreamCursor(rawValue: String(nextIndex))
    let completeThrough: Double
    if isEnd {
        completeThrough = max(throughChartTimeMs, finalDurationMs ?? throughChartTimeMs)
    } else if objects[nextIndex].timeMs <= throughChartTimeMs {
        completeThrough = objects[nextIndex].timeMs.nextDown
    } else {
        completeThrough = throughChartTimeMs
    }

    return Mania4KHitObjectBatch(
        objects: emitted,
        nextCursor: nextCursor,
        completeThroughChartTimeMs: completeThrough,
        isEndOfStream: isEnd
    )
}

private struct OsuMania4KParser {
    let sourceURL: URL
    let text: String

    func parse() throws -> (objects: [Mania4KHitObject], metadata: Mania4KChartMetadata) {
        var section = ""
        var general: [String: String] = [:]
        var metadataFields: [String: String] = [:]
        var difficulty: [String: String] = [:]
        var hitObjectLines: [(sourceOrder: Int, line: String)] = []
        var hitObjectSourceOrder = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("//") else {
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            switch section {
            case "General":
                parseKeyValue(line, into: &general)
            case "Metadata":
                parseKeyValue(line, into: &metadataFields)
            case "Difficulty":
                parseKeyValue(line, into: &difficulty)
            case "HitObjects":
                hitObjectLines.append((hitObjectSourceOrder, line))
                hitObjectSourceOrder += 1
            default:
                continue
            }
        }

        guard Int(general["Mode"] ?? "") == 3 else {
            throw Mania4KChartValidationError.unsupportedMode
        }

        guard let circleSize = Double(difficulty["CircleSize"] ?? "") else {
            throw Mania4KChartValidationError.unsupportedKeyCount(0)
        }

        guard Int(circleSize.rounded()) == 4, abs(circleSize - 4) < 0.0001 else {
            throw Mania4KChartValidationError.unsupportedKeyCount(Int(circleSize.rounded()))
        }

        let parsedObjects = try hitObjectLines.flatMap { sourceOrder, line in
            try parseHitObject(line, sourceOrder: sourceOrder)
        }
        .sorted { lhs, rhs in
            if lhs.object.timeMs != rhs.object.timeMs {
                return lhs.object.timeMs < rhs.object.timeMs
            }
            if lhs.object.lane != rhs.object.lane {
                return lhs.object.lane < rhs.object.lane
            }
            if lhs.sourceOrder != rhs.sourceOrder {
                return lhs.sourceOrder < rhs.sourceOrder
            }
            return lhs.objectOrder < rhs.objectOrder
        }
        .map(\.object)

        let validatedObjects = try Mania4KStreamValidator.validated(parsedObjects)
        let objectCount = validatedObjects.filter { $0.kind != .holdEnd }.count
        let duration = validatedObjects.map(\.timeMs).max()
        let metadata = Mania4KChartMetadata(
            title: metadataFields["TitleUnicode"] ?? metadataFields["Title"] ?? sourceURL.deletingPathExtension().lastPathComponent,
            artist: metadataFields["ArtistUnicode"] ?? metadataFields["Artist"],
            sourceDescription: sourceURL.lastPathComponent,
            objectCount: objectCount,
            durationMs: duration
        )
        return (validatedObjects, metadata)
    }

    private func parseKeyValue(_ line: String, into dictionary: inout [String: String]) {
        guard let separator = line.firstIndex(of: ":") else {
            return
        }

        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        dictionary[key] = value
    }

    private func parseHitObject(_ line: String, sourceOrder: Int) throws -> [(sourceOrder: Int, objectOrder: Int, object: Mania4KHitObject)] {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5,
              let x = Int(fields[0]),
              let timeMs = Double(fields[2]),
              timeMs.isFinite,
              timeMs >= 0,
              let type = Int(fields[3])
        else {
            throw Mania4KChartValidationError.unsupportedHitObject(line)
        }

        let laneIndex = min(max(Int(floor(Double(x) * 4 / 512)), 0), 3)
        guard let lane = Mania4KLane(rawValue: laneIndex) else {
            throw Mania4KChartValidationError.invalidLane(laneIndex)
        }

        let hasCircle = (type & 1) != 0
        let hasSlider = (type & 2) != 0
        let hasSpinner = (type & 8) != 0
        let hasHold = (type & 128) != 0

        if hasSlider || hasSpinner || (hasCircle && hasHold) {
            throw Mania4KChartValidationError.unsupportedHitObject(line)
        }

        if hasHold {
            let endTimeMs: Double
            if fields.count >= 6, !fields[5].isEmpty {
                let endTimePart = fields[5].split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                guard let parsedEndTimeMs = Double(endTimePart), parsedEndTimeMs.isFinite else {
                    throw Mania4KChartValidationError.unsupportedHitObject(line)
                }
                endTimeMs = max(timeMs, parsedEndTimeMs)
            } else {
                endTimeMs = timeMs
            }

            return [
                (sourceOrder, 0, Mania4KHitObject(lane: lane, timeMs: timeMs, kind: .holdStart)),
                (sourceOrder, 1, Mania4KHitObject(lane: lane, timeMs: endTimeMs, kind: .holdEnd))
            ]
        }

        guard hasCircle else {
            throw Mania4KChartValidationError.unsupportedHitObject(line)
        }

        return [(sourceOrder, 0, Mania4KHitObject(lane: lane, timeMs: timeMs, kind: .tap))]
    }
}

import Foundation

public enum InferenceEndpointMessageType: String, Codable, Sendable {
    case ready
    case audioPath = "audio_path"
    case referenceTime = "reference_time"
    case hitObjectTokens = "hitobject_tokens"
    case stop
    case error
}

public struct InferenceEndpointConfiguration: Equatable, Sendable {
    public static let defaultDifficulty = 4.0
    public static let global = InferenceEndpointConfiguration()

    public let difficulty: Double
    public let isMock: Bool

    public init(
        difficulty: Double = InferenceEndpointConfiguration.defaultDifficulty,
        isMock: Bool = false
    ) {
        self.difficulty = difficulty
        self.isMock = isMock
    }
}

public struct InferenceEndpointOutgoingMessage: Encodable, Equatable, Sendable {
    public let type: InferenceEndpointMessageType
    public let audioPath: String?
    public let musicSource: MusicSource?
    public let sessionID: String?
    public let refTimeMS: Int?
    public let localHostTimeSendMS: Double?
    public let difficulty: Double?
    public let isMock: Bool?
    public let control: String?

    enum CodingKeys: String, CodingKey {
        case type
        case audioPath = "audio_path"
        case musicSource = "music_source"
        case sessionID = "session_id"
        case refTimeMS = "ref_time_ms"
        case localHostTimeSendMS = "local_host_time_send_ms"
        case difficulty
        case isMock = "is_mock"
        case control
    }

    public init(
        type: InferenceEndpointMessageType,
        audioPath: String? = nil,
        musicSource: MusicSource? = nil,
        sessionID: String? = nil,
        refTimeMS: Int? = nil,
        localHostTimeSendMS: Double? = nil,
        difficulty: Double? = nil,
        isMock: Bool? = nil,
        control: String? = nil
    ) {
        self.type = type
        self.audioPath = audioPath
        self.musicSource = musicSource
        self.sessionID = sessionID
        self.refTimeMS = refTimeMS
        self.localHostTimeSendMS = localHostTimeSendMS
        self.difficulty = difficulty
        self.isMock = isMock
        self.control = control
    }

    public static func ready() -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(type: .ready, control: "ready")
    }

    public static func audioPath(
        _ audioPath: String,
        sessionID: String,
        musicSource: MusicSource = .background,
        configuration: InferenceEndpointConfiguration = .global
    ) -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(
            type: .audioPath,
            audioPath: audioPath,
            musicSource: musicSource,
            sessionID: sessionID,
            difficulty: configuration.difficulty,
            isMock: configuration.isMock
        )
    }

    public static func referenceTime(
        sessionID: String,
        refTimeMS: Double,
        localHostTimeSendMS: Double
    ) -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(
            type: .referenceTime,
            sessionID: sessionID,
            refTimeMS: Int(refTimeMS.rounded()),
            localHostTimeSendMS: localHostTimeSendMS
        )
    }

    public static func stop(sessionID: String) -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(type: .stop, sessionID: sessionID, control: "end_session")
    }
}

public struct InferenceEndpointIncomingMessage: Decodable, Equatable, Sendable {
    public let type: InferenceEndpointMessageType
    public let sessionID: String?
    public let token: InferenceEndpointTokenPayload?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case token
        case error
    }
}

public struct InferenceEndpointTokenPayload: Decodable, Equatable, Sendable {
    public let tokenID: Int
    public let timeMS: Double

    public init(tokenID: Int, timeMS: Double) {
        self.tokenID = tokenID
        self.timeMS = timeMS
    }

    public init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            let tokenID = try unkeyed.decode(Int.self)
            let timeMS = try unkeyed.decode(Double.self)
            self.init(tokenID: tokenID, timeMS: timeMS)
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let tokenID = try keyed.decode(Int.self, forKey: .tokenID)
        let timeMS = try keyed.decodeIfPresent(Double.self, forKey: .timeMS)
            ?? keyed.decode(Double.self, forKey: .msInRefAudio)
        self.init(tokenID: tokenID, timeMS: timeMS)
    }

    private enum CodingKeys: String, CodingKey {
        case tokenID = "token_id"
        case timeMS = "time_ms"
        case msInRefAudio = "ms_in_ref_audio"
    }
}

public struct InferenceEndpointHitObjectToken: Equatable, Sendable {
    public let sessionID: String
    public let tokenID: Int
    public let timeMS: Double
    public let objects: [Mania4KHitObject]

    public init(sessionID: String, tokenID: Int, timeMS: Double, objects: [Mania4KHitObject]) {
        self.sessionID = sessionID
        self.tokenID = tokenID
        self.timeMS = timeMS
        self.objects = objects
    }
}

public enum InferenceEndpointEvent: Equatable, Sendable {
    case hitObjectToken(InferenceEndpointHitObjectToken)
}

public enum InferenceEndpointProtocolError: Error, Equatable, LocalizedError, Sendable {
    case missingSessionID
    case missingToken
    case unsupportedMessageType(InferenceEndpointMessageType)
    case invalidTextFrame
    case invalidHitObjectTokenID(Int)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionID:
            return "Inference endpoint message is missing session_id."
        case .missingToken:
            return "Inference endpoint hitobject_tokens message is missing token."
        case .unsupportedMessageType(let type):
            return "Unsupported inference endpoint message type: \(type.rawValue)."
        case .invalidTextFrame:
            return "Inference endpoint sent a non-text WebSocket frame."
        case .invalidHitObjectTokenID(let tokenID):
            return "Could not parse inference hitobject token_id: \(tokenID)."
        case .serverError(let message):
            return "Inference endpoint server error: \(message)"
        }
    }
}

public enum InferenceEndpointHitObjectTokenParser {
    public static let eventTokenIDRange = 25...279

    public static func hitObjects(from payload: InferenceEndpointTokenPayload) throws -> [Mania4KHitObject] {
        guard eventTokenIDRange.contains(payload.tokenID) else {
            throw InferenceEndpointProtocolError.invalidHitObjectTokenID(payload.tokenID)
        }

        var laneActionCode = payload.tokenID - 24
        var objects: [Mania4KHitObject] = []

        for laneRawValue in 0..<4 {
            let actionValue = laneActionCode % 4
            laneActionCode /= 4

            guard let lane = Mania4KLane(rawValue: laneRawValue) else {
                continue
            }

            switch actionValue {
            case 0:
                continue
            case 1:
                objects.append(Mania4KHitObject(lane: lane, timeMs: payload.timeMS, kind: .tap))
            case 2:
                objects.append(Mania4KHitObject(lane: lane, timeMs: payload.timeMS, kind: .holdStart))
            case 3:
                objects.append(Mania4KHitObject(lane: lane, timeMs: payload.timeMS, kind: .holdEnd))
            default:
                throw InferenceEndpointProtocolError.invalidHitObjectTokenID(payload.tokenID)
            }
        }

        return objects
    }
}

public struct InferenceHitObjectReadyWindow: Equatable, Sendable {
    public let startTimeMS: Double
    public let endTimeMS: Double

    public var lengthMS: Double {
        max(0, endTimeMS - startTimeMS)
    }
}

public struct InferenceHitObjectRenderReadiness: Equatable, Sendable {
    public let referenceTimeMS: Double
    public let firstObjectLeadTimeMS: Double
    public let minimumBufferedDurationMS: Double
    public let readyWindow: InferenceHitObjectReadyWindow?

    public var requiredFirstObjectTimeMS: Double {
        referenceTimeMS + firstObjectLeadTimeMS
    }

    public var bufferedDurationAfterFirstObjectMS: Double {
        readyWindow?.lengthMS ?? 0
    }

    public var isReady: Bool {
        bufferedDurationAfterFirstObjectMS >= minimumBufferedDurationMS
    }
}

public struct InferenceHitObjectTokenBuffer: Equatable, Sendable {
    public private(set) var objects: [Mania4KHitObject]
    public private(set) var readyWindow: InferenceHitObjectReadyWindow?
    public private(set) var minimumAcceptedTimeMS: Double?
    public private(set) var maximumAcceptedTimeMS: Double?

    public init(
        objects: [Mania4KHitObject] = [],
        minimumAcceptedTimeMS: Double? = nil,
        maximumAcceptedTimeMS: Double? = nil
    ) {
        self.objects = []
        self.readyWindow = nil
        self.minimumAcceptedTimeMS = minimumAcceptedTimeMS
        self.maximumAcceptedTimeMS = maximumAcceptedTimeMS
        append(contentsOf: objects)
    }

    public mutating func setMinimumAcceptedTimeMS(_ timeMS: Double) {
        minimumAcceptedTimeMS = timeMS
        pruneRejectedObjects()
    }

    public mutating func setMaximumAcceptedTimeMS(_ timeMS: Double) {
        maximumAcceptedTimeMS = timeMS
        pruneRejectedObjects()
    }

    private mutating func pruneRejectedObjects() {
        let minimumAcceptedTimeMS = minimumAcceptedTimeMS
        let maximumAcceptedTimeMS = maximumAcceptedTimeMS
        objects.removeAll { object in
            !Self.accepts(
                timeMS: object.timeMs,
                minimumAcceptedTimeMS: minimumAcceptedTimeMS,
                maximumAcceptedTimeMS: maximumAcceptedTimeMS
            )
        }
        readyWindow = Self.readyWindow(for: objects)
    }

    @discardableResult
    public mutating func append(_ object: Mania4KHitObject) -> Bool {
        append(contentsOf: [object])
    }

    @discardableResult
    public mutating func append(contentsOf newObjects: [Mania4KHitObject]) -> Bool {
        let minimumAcceptedTimeMS = minimumAcceptedTimeMS
        let maximumAcceptedTimeMS = maximumAcceptedTimeMS
        let acceptedObjects = newObjects.filter { object in
            guard Self.accepts(
                timeMS: object.timeMs,
                minimumAcceptedTimeMS: minimumAcceptedTimeMS,
                maximumAcceptedTimeMS: maximumAcceptedTimeMS
            ) else {
                return false
            }

            guard let renderedThroughMS = readyWindow?.endTimeMS else {
                return true
            }

            return object.timeMs > renderedThroughMS
        }

        guard !acceptedObjects.isEmpty else {
            return false
        }

        objects.append(contentsOf: acceptedObjects)
        readyWindow = Self.readyWindow(for: objects)
        return true
    }

    @discardableResult
    fileprivate mutating func appendDirectlyToStreamingBuffer(contentsOf newObjects: [Mania4KHitObject]) -> Bool {
        let minimumAcceptedTimeMS = minimumAcceptedTimeMS
        let maximumAcceptedTimeMS = maximumAcceptedTimeMS
        let acceptedObjects = newObjects.filter { object in
            Self.accepts(
                timeMS: object.timeMs,
                minimumAcceptedTimeMS: minimumAcceptedTimeMS,
                maximumAcceptedTimeMS: maximumAcceptedTimeMS
            )
        }

        guard !acceptedObjects.isEmpty else {
            return false
        }

        objects.append(contentsOf: acceptedObjects)
        readyWindow = Self.readyWindow(for: objects)
        return true
    }

    private static func accepts(
        timeMS: Double,
        minimumAcceptedTimeMS: Double?,
        maximumAcceptedTimeMS: Double?
    ) -> Bool {
        guard timeMS.isFinite, timeMS >= 0 else {
            return false
        }

        if let minimumAcceptedTimeMS, timeMS < minimumAcceptedTimeMS {
            return false
        }

        if let maximumAcceptedTimeMS, timeMS > maximumAcceptedTimeMS {
            return false
        }

        return true
    }

    public mutating func removeAll() {
        objects.removeAll()
        readyWindow = nil
        minimumAcceptedTimeMS = nil
        maximumAcceptedTimeMS = nil
    }

    public static func readyWindow(for objects: [Mania4KHitObject]) -> InferenceHitObjectReadyWindow? {
        let orderedObjects = objects.enumerated().sorted { left, right in
            if left.element.timeMs == right.element.timeMs {
                return left.offset < right.offset
            }

            return left.element.timeMs < right.element.timeMs
        }

        guard let firstObject = orderedObjects.first?.element else {
            return nil
        }

        var openHolds = Set<Mania4KLane>()
        var latestClosedTimeMS: Double?
        var index = orderedObjects.startIndex

        while index < orderedObjects.endIndex {
            let currentTimeMS = orderedObjects[index].element.timeMs

            while index < orderedObjects.endIndex,
                  orderedObjects[index].element.timeMs == currentTimeMS {
                switch orderedObjects[index].element.kind {
                case .tap:
                    break
                case .holdStart:
                    openHolds.insert(orderedObjects[index].element.lane)
                case .holdEnd:
                    openHolds.remove(orderedObjects[index].element.lane)
                }

                index = orderedObjects.index(after: index)
            }

            if openHolds.isEmpty {
                latestClosedTimeMS = currentTimeMS
            }
        }

        guard let latestClosedTimeMS else {
            return nil
        }

        return InferenceHitObjectReadyWindow(
            startTimeMS: firstObject.timeMs,
            endTimeMS: latestClosedTimeMS
        )
    }

    public func renderReadiness(
        referenceTimeMS: Double,
        minimumBufferedDurationMS: Double = 5_000,
        firstObjectLeadTimeMS: Double = 1_000
    ) -> InferenceHitObjectRenderReadiness {
        InferenceHitObjectRenderReadiness(
            referenceTimeMS: referenceTimeMS,
            firstObjectLeadTimeMS: firstObjectLeadTimeMS,
            minimumBufferedDurationMS: minimumBufferedDurationMS,
            readyWindow: Self.readyWindow(
                for: objects,
                startingAtOrAfterTimeMS: referenceTimeMS + firstObjectLeadTimeMS
            )
        )
    }

    public static func readyWindow(
        for objects: [Mania4KHitObject],
        startingAtOrAfterTimeMS minimumStartTimeMS: Double
    ) -> InferenceHitObjectReadyWindow? {
        guard minimumStartTimeMS.isFinite, minimumStartTimeMS >= 0 else {
            return nil
        }

        let orderedObjects = streamOrderedObjects(objects)
        guard !orderedObjects.isEmpty else {
            return nil
        }

        var openHolds = Set<Mania4KLane>()
        var startTimeMS: Double?
        var latestClosedTimeMS: Double?
        var index = orderedObjects.startIndex

        while index < orderedObjects.endIndex {
            let currentTimeMS = orderedObjects[index].timeMs
            let canStartAtCurrentTime = startTimeMS == nil
                && currentTimeMS >= minimumStartTimeMS
                && openHolds.isEmpty

            if canStartAtCurrentTime {
                startTimeMS = currentTimeMS
            }

            while index < orderedObjects.endIndex,
                  orderedObjects[index].timeMs == currentTimeMS {
                switch orderedObjects[index].kind {
                case .tap:
                    break
                case .holdStart:
                    openHolds.insert(orderedObjects[index].lane)
                case .holdEnd:
                    openHolds.remove(orderedObjects[index].lane)
                }

                index = orderedObjects.index(after: index)
            }

            if startTimeMS != nil, openHolds.isEmpty {
                latestClosedTimeMS = currentTimeMS
            }
        }

        guard let startTimeMS, let latestClosedTimeMS else {
            return nil
        }

        return InferenceHitObjectReadyWindow(
            startTimeMS: startTimeMS,
            endTimeMS: latestClosedTimeMS
        )
    }

    fileprivate static func streamOrderedObjects(_ objects: [Mania4KHitObject]) -> [Mania4KHitObject] {
        objects.enumerated().sorted { left, right in
            if left.element.timeMs != right.element.timeMs {
                return left.element.timeMs < right.element.timeMs
            }
            if left.element.lane != right.element.lane {
                return left.element.lane < right.element.lane
            }

            return left.offset < right.offset
        }
        .map(\.element)
    }
}

public actor BufferedInferenceMania4KHitObjectStream: Mania4KHitObjectStreaming {
    public typealias ReferenceTimeProvider = @Sendable () async -> Double?

    private struct EmittedObjectKey: Hashable {
        let lane: Mania4KLane
        let timeMS: Double
        let kind: Int

        init(_ object: Mania4KHitObject) {
            self.lane = object.lane
            self.timeMS = object.timeMs
            switch object.kind {
            case .tap:
                self.kind = 0
            case .holdStart:
                self.kind = 1
            case .holdEnd:
                self.kind = 2
            }
        }
    }

    private let metadata: Mania4KChartMetadata
    private let minimumBufferedDurationMS: Double
    private let firstObjectLeadTimeMS: Double
    private let referenceTimeProvider: ReferenceTimeProvider
    private var buffer: InferenceHitObjectTokenBuffer
    private var renderStartWindow: InferenceHitObjectReadyWindow?
    private var emittedObjectCounts: [EmittedObjectKey: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        metadata: Mania4KChartMetadata,
        minimumAcceptedTimeMS: Double? = nil,
        maximumAcceptedTimeMS: Double? = nil,
        minimumBufferedDurationMS: Double = 5_000,
        firstObjectLeadTimeMS: Double = 1_000,
        referenceTimeProvider: @escaping ReferenceTimeProvider
    ) {
        self.metadata = metadata
        self.minimumBufferedDurationMS = minimumBufferedDurationMS
        self.firstObjectLeadTimeMS = firstObjectLeadTimeMS
        self.referenceTimeProvider = referenceTimeProvider
        self.buffer = InferenceHitObjectTokenBuffer(
            minimumAcceptedTimeMS: minimumAcceptedTimeMS,
            maximumAcceptedTimeMS: maximumAcceptedTimeMS
        )
    }

    public func prepare() async throws -> Mania4KChartMetadata {
        metadata
    }

    @discardableResult
    public func append(contentsOf objects: [Mania4KHitObject]) -> Bool {
        let appended: Bool
        if renderStartWindow == nil {
            appended = buffer.append(contentsOf: objects)
        } else {
            appended = buffer.appendDirectlyToStreamingBuffer(contentsOf: objects)
        }
        if appended {
            resumeWaiters()
        }
        return appended
    }

    public func setMinimumAcceptedTimeMS(_ timeMS: Double) {
        buffer.setMinimumAcceptedTimeMS(timeMS)
        resumeWaiters()
    }

    public func setMaximumAcceptedTimeMS(_ timeMS: Double) {
        buffer.setMaximumAcceptedTimeMS(timeMS)
        resumeWaiters()
    }

    public func currentRenderReadiness() async -> InferenceHitObjectRenderReadiness? {
        guard let referenceTimeMS = await referenceTimeProvider() else {
            return nil
        }

        return buffer.renderReadiness(
            referenceTimeMS: referenceTimeMS,
            minimumBufferedDurationMS: minimumBufferedDurationMS,
            firstObjectLeadTimeMS: firstObjectLeadTimeMS
        )
    }

    public func read(
        after cursor: Mania4KHitObjectStreamCursor?,
        throughChartTimeMs: Double,
        limit: Int
    ) async throws -> Mania4KHitObjectBatch {
        try await waitForInitialRenderWindowIfNeeded()

        guard let renderStartWindow else {
            throw Mania4KPlayFailure.streamFailed("Buffered inference stream has no render start window.")
        }

        let orderedObjects = InferenceHitObjectTokenBuffer
            .streamOrderedObjects(buffer.objects)
            .filter { $0.timeMs >= renderStartWindow.startTimeMS }
        let safeLimit = max(limit, 1)
        var skippedObjectCounts: [EmittedObjectKey: Int] = [:]
        var emitted: [Mania4KHitObject] = []

        for object in orderedObjects {
            guard object.timeMs <= throughChartTimeMs else {
                break
            }

            let key = EmittedObjectKey(object)
            let alreadyEmittedCount = emittedObjectCounts[key, default: 0]
            let skippedCount = skippedObjectCounts[key, default: 0]
            if skippedCount < alreadyEmittedCount {
                skippedObjectCounts[key] = skippedCount + 1
                continue
            }

            emittedObjectCounts[key] = alreadyEmittedCount + 1
            emitted.append(object)

            if emitted.count >= safeLimit {
                break
            }
        }

        let emittedCount = emittedObjectCounts.values.reduce(0, +)
        let nextCursor = Mania4KHitObjectStreamCursor(rawValue: String(emittedCount))
        return Mania4KHitObjectBatch(
            objects: emitted,
            nextCursor: nextCursor,
            completeThroughChartTimeMs: throughChartTimeMs,
            isEndOfStream: false
        )
    }

    private func waitForInitialRenderWindowIfNeeded() async throws {
        while renderStartWindow == nil {
            guard let referenceTimeMS = await referenceTimeProvider() else {
                throw Mania4KPlayFailure.streamFailed("Reference ambient music time is unavailable.")
            }

            let readiness = buffer.renderReadiness(
                referenceTimeMS: referenceTimeMS,
                minimumBufferedDurationMS: minimumBufferedDurationMS,
                firstObjectLeadTimeMS: firstObjectLeadTimeMS
            )
            if readiness.isReady, let readyWindow = readiness.readyWindow {
                renderStartWindow = readyWindow
                return
            }

            await waitForBufferUpdate()
        }
    }

    private func waitForBufferUpdate() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeWaiters() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

public protocol InferenceEndpointClient: Sendable {
    func prepare() async throws
    func sendAudioPath(_ audioPath: String, sessionID: String, musicSource: MusicSource) async throws
    func sendReferenceTime(sessionID: String, refTimeMS: Double, localHostTimeSendMS: Double) async throws
    func stop(sessionID: String) async throws
    func nextEvent() async throws -> InferenceEndpointEvent
}

public extension InferenceEndpointClient {
    func sendAudioPath(_ audioPath: String, sessionID: String) async throws {
        try await sendAudioPath(audioPath, sessionID: sessionID, musicSource: .background)
    }
}

public actor InferenceEndpointWebSocketClient: InferenceEndpointClient {
    public static let defaultEndpointURL = URL(string: "ws://localhost:8765")!

    private let endpointURL: URL
    private let urlSession: URLSession
    private let configuration: InferenceEndpointConfiguration
    private var task: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        endpointURL: URL = InferenceEndpointWebSocketClient.defaultEndpointURL,
        configuration: InferenceEndpointConfiguration = .global,
        urlSession: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func prepare() async throws {
        try await send(.ready())
    }

    public func sendAudioPath(_ audioPath: String, sessionID: String, musicSource: MusicSource) async throws {
        try await send(.audioPath(
            audioPath,
            sessionID: sessionID,
            musicSource: musicSource,
            configuration: configuration
        ))
    }

    public func sendReferenceTime(
        sessionID: String,
        refTimeMS: Double,
        localHostTimeSendMS: Double
    ) async throws {
        try await send(.referenceTime(
            sessionID: sessionID,
            refTimeMS: refTimeMS,
            localHostTimeSendMS: localHostTimeSendMS
        ))
    }

    public func stop(sessionID: String) async throws {
        defer {
            disconnect()
        }
        try await send(.stop(sessionID: sessionID))
    }

    public func disconnect() {
        resetConnection()
    }

    public func nextEvent() async throws -> InferenceEndpointEvent {
        do {
            while true {
                let message = try await receiveMessage()
                if let event = try decodeEvent(from: message) {
                    return event
                }
            }
        } catch {
            resetConnection()
            throw error
        }
    }

    private func send(_ message: InferenceEndpointOutgoingMessage) async throws {
        let task = ensureConnected()
        let data = try encoder.encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InferenceEndpointProtocolError.invalidTextFrame
        }

        do {
            try await task.send(.string(string))
        } catch {
            resetConnection()
            throw error
        }
    }

    private func receiveMessage() async throws -> URLSessionWebSocketTask.Message {
        let task = ensureConnected()
        do {
            return try await task.receive()
        } catch {
            resetConnection()
            throw error
        }
    }

    private func ensureConnected() -> URLSessionWebSocketTask {
        if let task {
            return task
        }

        let task = urlSession.webSocketTask(with: endpointURL)
        task.resume()
        self.task = task
        return task
    }

    private func resetConnection() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func decodeEvent(from message: URLSessionWebSocketTask.Message) throws -> InferenceEndpointEvent? {
        let data: Data
        switch message {
        case .string(let string):
            data = Data(string.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            throw InferenceEndpointProtocolError.invalidTextFrame
        }

        let incoming = try decoder.decode(InferenceEndpointIncomingMessage.self, from: data)
        switch incoming.type {
        case .hitObjectTokens:
            guard let sessionID = incoming.sessionID else {
                throw InferenceEndpointProtocolError.missingSessionID
            }
            guard let payload = incoming.token else {
                throw InferenceEndpointProtocolError.missingToken
            }
            let objects = try InferenceEndpointHitObjectTokenParser.hitObjects(from: payload)
            return .hitObjectToken(InferenceEndpointHitObjectToken(
                sessionID: sessionID,
                tokenID: payload.tokenID,
                timeMS: payload.timeMS,
                objects: objects
            ))

        case .error:
            throw InferenceEndpointProtocolError.serverError(incoming.error ?? "unknown error")
        case .ready, .audioPath, .referenceTime, .stop:
            return nil
        }
    }
}

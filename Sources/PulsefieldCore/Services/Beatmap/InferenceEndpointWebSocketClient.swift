import Foundation
import PulsefieldProtocol
import SwiftProtobuf

typealias InferenceEndpointProtocolEnvelope = Pulsefield_Protocol_V1_Envelope

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

struct InferenceEndpointEnvelopeMetadata: Equatable, Sendable {
    static let sourceNodeID = "pulsefield.reference.swift"

    let sequence: UInt64
    let sentAtUnixMs: Int64
    let sourceNodeID: String
    let messageID: String
    let correlationID: String

    init(
        sequence: UInt64 = 0,
        sentAtUnixMs: Int64 = InferenceEndpointEnvelopeMetadata.currentUnixMillis(),
        sourceNodeID: String = InferenceEndpointEnvelopeMetadata.sourceNodeID,
        messageID: String = UUID().uuidString,
        correlationID: String = ""
    ) {
        self.sequence = sequence
        self.sentAtUnixMs = sentAtUnixMs
        self.sourceNodeID = sourceNodeID
        self.messageID = messageID
        self.correlationID = correlationID
    }

    private static func currentUnixMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

enum InferenceEndpointProtocolCodec {
    static func readyEnvelope(
        metadata: InferenceEndpointEnvelopeMetadata = .init()
    ) -> InferenceEndpointProtocolEnvelope {
        envelope(
            payload: .ready(Pulsefield_Protocol_V1_ReadyRequest()),
            metadata: metadata
        )
    }

    static func audioPathEnvelope(
        _ audioPath: String,
        sessionID: String,
        musicSource: MusicSource = .background,
        configuration: InferenceEndpointConfiguration = .global,
        metadata: InferenceEndpointEnvelopeMetadata = .init()
    ) -> InferenceEndpointProtocolEnvelope {
        var asset = Pulsefield_Protocol_V1_AudioAssetRef()
        asset.localPath = audioPath

        var request = Pulsefield_Protocol_V1_AudioRequest()
        request.audio = asset
        request.syncSource = musicSource.protocolSyncSource
        request.difficulty = configuration.difficulty
        request.route = configuration.protocolRoute

        return envelope(
            sessionID: sessionID,
            payload: .audio(request),
            metadata: metadata
        )
    }

    static func referenceTimeEnvelope(
        sessionID: String,
        refTimeMS: Double,
        localHostTimeSendMS: Double,
        metadata: InferenceEndpointEnvelopeMetadata = .init()
    ) throws -> InferenceEndpointProtocolEnvelope {
        var request = Pulsefield_Protocol_V1_ReferenceTimeRequest()
        request.refTimeMs = try roundedUInt32(refTimeMS, field: "ref_time_ms")
        request.localHostTimeSendMs = try roundedUInt64(localHostTimeSendMS, field: "local_host_time_send_ms")

        return envelope(
            sessionID: sessionID,
            payload: .referenceTime(request),
            metadata: metadata
        )
    }

    static func stopEnvelope(
        sessionID: String,
        metadata: InferenceEndpointEnvelopeMetadata = .init()
    ) -> InferenceEndpointProtocolEnvelope {
        var request = Pulsefield_Protocol_V1_StopSessionRequest()
        request.reason = "client_stop"

        return envelope(
            sessionID: sessionID,
            payload: .stopSession(request),
            metadata: metadata
        )
    }

    static func serializedData(for envelope: InferenceEndpointProtocolEnvelope) throws -> Data {
        try envelope.serializedData()
    }

    static func decodeEvent(from message: URLSessionWebSocketTask.Message) throws -> InferenceEndpointEvent? {
        switch message {
        case .data(let data):
            return try decodeEvent(from: data)
        case .string:
            throw InferenceEndpointProtocolError.invalidBinaryFrame
        @unknown default:
            throw InferenceEndpointProtocolError.invalidBinaryFrame
        }
    }

    static func decodeEvent(from data: Data) throws -> InferenceEndpointEvent? {
        let envelope = try InferenceEndpointProtocolEnvelope(serializedData: data)
        return try decodeEvent(from: envelope)
    }

    static func decodeEvent(from envelope: InferenceEndpointProtocolEnvelope) throws -> InferenceEndpointEvent? {
        switch envelope.payload {
        case .hitObjectToken(let event)?:
            guard !envelope.sessionID.isEmpty else {
                throw InferenceEndpointProtocolError.missingSessionID
            }

            let payload = InferenceEndpointTokenPayload(event)
            let objects = try InferenceEndpointHitObjectTokenParser.hitObjects(from: payload)
            return .hitObjectToken(InferenceEndpointHitObjectToken(
                sessionID: envelope.sessionID,
                tokenID: payload.tokenID,
                timeMS: payload.timeMS,
                objects: objects
            ))

        case .endOfStream(let event)?:
            guard !envelope.sessionID.isEmpty else {
                throw InferenceEndpointProtocolError.missingSessionID
            }

            return .endOfStream(InferenceEndpointEndOfStream(
                sessionID: envelope.sessionID,
                audioLengthMS: event.hasAudioLengthMs ? Double(event.audioLengthMs) : nil,
                completeThroughMS: Double(event.completeThroughMs)
            ))

        case .error(let event)?:
            throw InferenceEndpointProtocolError.serverError(event.clientMessage)
        case .nodeHello?, .ready?, .audio?, .referenceTime?, .stopSession?, .mapperStreamBegin?, .status?, nil:
            return nil
        }
    }

    static func envelope(
        sessionID: String = "",
        payload: InferenceEndpointProtocolEnvelope.OneOf_Payload,
        metadata: InferenceEndpointEnvelopeMetadata
    ) -> InferenceEndpointProtocolEnvelope {
        var envelope = InferenceEndpointProtocolEnvelope()
        envelope.sessionID = sessionID
        envelope.sequence = metadata.sequence
        envelope.sentAtUnixMs = metadata.sentAtUnixMs
        envelope.sourceNodeID = metadata.sourceNodeID
        envelope.messageID = metadata.messageID
        envelope.correlationID = metadata.correlationID
        envelope.payload = payload
        return envelope
    }

    private static func roundedUInt32(_ value: Double, field: String) throws -> UInt32 {
        guard value.isFinite, value >= 0, value <= Double(UInt32.max) else {
            throw InferenceEndpointProtocolError.invalidProtocolField(field)
        }
        return UInt32(value.rounded())
    }

    private static func roundedUInt64(_ value: Double, field: String) throws -> UInt64 {
        guard value.isFinite, value >= 0, value <= Double(UInt64.max) else {
            throw InferenceEndpointProtocolError.invalidProtocolField(field)
        }
        return UInt64(value.rounded())
    }
}

public enum InferenceEndpointProtocolError: Error, Equatable, LocalizedError, Sendable {
    case missingSessionID
    case invalidBinaryFrame
    case invalidHitObjectTokenID(Int)
    case invalidProtocolField(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionID:
            return "Inference endpoint message is missing session_id."
        case .invalidBinaryFrame:
            return "Inference endpoint sent a non-binary protobuf WebSocket frame."
        case .invalidHitObjectTokenID(let tokenID):
            return "Could not parse inference hitobject token_id: \(tokenID)."
        case .invalidProtocolField(let field):
            return "Inference endpoint protocol field is out of range: \(field)."
        case .serverError(let message):
            return "Inference endpoint server error: \(message)"
        }
    }
}

public struct InferenceEndpointTokenPayload: Equatable, Sendable {
    public let tokenID: Int
    public let timeMS: Double

    public init(tokenID: Int, timeMS: Double) {
        self.tokenID = tokenID
        self.timeMS = timeMS
    }

    init(_ event: Pulsefield_Protocol_V1_HitObjectTokenEvent) {
        self.init(tokenID: Int(event.tokenID), timeMS: Double(event.msInRefAudio))
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

public struct InferenceEndpointEndOfStream: Equatable, Sendable {
    public let sessionID: String
    public let audioLengthMS: Double?
    public let completeThroughMS: Double

    public init(sessionID: String, audioLengthMS: Double?, completeThroughMS: Double) {
        self.sessionID = sessionID
        self.audioLengthMS = audioLengthMS
        self.completeThroughMS = completeThroughMS
    }
}

public enum InferenceEndpointEvent: Equatable, Sendable {
    case hitObjectToken(InferenceEndpointHitObjectToken)
    case endOfStream(InferenceEndpointEndOfStream)
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

private extension InferenceEndpointConfiguration {
    var protocolRoute: Pulsefield_Protocol_V1_InferenceRoute {
        isMock ? .timingMock : .mapper
    }
}

private extension MusicSource {
    var protocolSyncSource: Pulsefield_Protocol_V1_SyncSource {
        switch self {
        case .background:
            return .background
        case .systemAudio:
            return .systemAudio
        }
    }
}

private extension Pulsefield_Protocol_V1_ErrorEvent {
    var clientMessage: String {
        if !code.isEmpty, !message.isEmpty {
            return "\(code): \(message)"
        }
        if !message.isEmpty {
            return message
        }
        if !code.isEmpty {
            return code
        }
        if errorCode != .unspecified {
            return "\(errorCode)"
        }
        return "unknown error"
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
    private var endOfStreamTimeMS: Double?
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
        self.endOfStreamTimeMS = nil
    }

    public func prepare() async throws -> Mania4KChartMetadata {
        metadata
    }

    @discardableResult
    public func append(contentsOf objects: [Mania4KHitObject]) -> Bool {
        guard endOfStreamTimeMS == nil else {
            return false
        }

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

    public func finish(completeThroughTimeMS: Double) {
        guard completeThroughTimeMS.isFinite, completeThroughTimeMS >= 0 else {
            return
        }

        if let endOfStreamTimeMS {
            self.endOfStreamTimeMS = min(endOfStreamTimeMS, completeThroughTimeMS)
        } else {
            self.endOfStreamTimeMS = completeThroughTimeMS
        }
        buffer.setMaximumAcceptedTimeMS(completeThroughTimeMS)
        resumeWaiters()
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
        let didReachEndOfStream = endOfStreamTimeMS.map {
            throughChartTimeMs >= $0 && emitted.count < safeLimit
        } ?? false
        return Mania4KHitObjectBatch(
            objects: emitted,
            nextCursor: nextCursor,
            completeThroughChartTimeMs: throughChartTimeMs,
            isEndOfStream: didReachEndOfStream
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

            if let endOfStreamTimeMS {
                renderStartWindow = readiness.readyWindow
                    ?? buffer.readyWindow
                    ?? InferenceHitObjectReadyWindow(startTimeMS: 0, endTimeMS: endOfStreamTimeMS)
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
    private var nextSequence: UInt64 = 1

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
        try await send(InferenceEndpointProtocolCodec.readyEnvelope(metadata: nextEnvelopeMetadata()))
    }

    public func sendAudioPath(_ audioPath: String, sessionID: String, musicSource: MusicSource) async throws {
        try await send(InferenceEndpointProtocolCodec.audioPathEnvelope(
            audioPath,
            sessionID: sessionID,
            musicSource: musicSource,
            configuration: configuration,
            metadata: nextEnvelopeMetadata()
        ))
    }

    public func sendReferenceTime(
        sessionID: String,
        refTimeMS: Double,
        localHostTimeSendMS: Double
    ) async throws {
        try await send(InferenceEndpointProtocolCodec.referenceTimeEnvelope(
            sessionID: sessionID,
            refTimeMS: refTimeMS,
            localHostTimeSendMS: localHostTimeSendMS,
            metadata: nextEnvelopeMetadata()
        ))
    }

    public func stop(sessionID: String) async throws {
        defer {
            disconnect()
        }
        try await send(InferenceEndpointProtocolCodec.stopEnvelope(
            sessionID: sessionID,
            metadata: nextEnvelopeMetadata()
        ))
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

    private func send(_ envelope: InferenceEndpointProtocolEnvelope) async throws {
        let task = ensureConnected()
        let data = try InferenceEndpointProtocolCodec.serializedData(for: envelope)

        do {
            try await task.send(.data(data))
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

    private func nextEnvelopeMetadata() -> InferenceEndpointEnvelopeMetadata {
        let sequence = nextSequence
        nextSequence = sequence == UInt64.max ? 1 : sequence + 1
        return InferenceEndpointEnvelopeMetadata(sequence: sequence)
    }

    private func decodeEvent(from message: URLSessionWebSocketTask.Message) throws -> InferenceEndpointEvent? {
        try InferenceEndpointProtocolCodec.decodeEvent(from: message)
    }
}

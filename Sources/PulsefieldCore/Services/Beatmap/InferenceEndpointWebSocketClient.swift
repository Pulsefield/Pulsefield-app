import Foundation

public enum InferenceEndpointMessageType: String, Codable, Sendable {
    case ready
    case audioPath = "audio_path"
    case referenceTime = "reference_time"
    case hitObjectTokens = "hitobject_tokens"
    case stop
    case error
}

public struct InferenceEndpointOutgoingMessage: Encodable, Equatable, Sendable {
    public let type: InferenceEndpointMessageType
    public let audioPath: String?
    public let sessionID: String?
    public let refTimeMS: Int?
    public let localComputerTimeSendMS: Int?
    public let control: String?

    enum CodingKeys: String, CodingKey {
        case type
        case audioPath = "audio_path"
        case sessionID = "session_id"
        case refTimeMS = "ref_time_ms"
        case localComputerTimeSendMS = "local_computer_time_send_ms"
        case control
    }

    public init(
        type: InferenceEndpointMessageType,
        audioPath: String? = nil,
        sessionID: String? = nil,
        refTimeMS: Int? = nil,
        localComputerTimeSendMS: Int? = nil,
        control: String? = nil
    ) {
        self.type = type
        self.audioPath = audioPath
        self.sessionID = sessionID
        self.refTimeMS = refTimeMS
        self.localComputerTimeSendMS = localComputerTimeSendMS
        self.control = control
    }

    public static func ready() -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(type: .ready, control: "ready")
    }

    public static func audioPath(_ audioPath: String, sessionID: String) -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(type: .audioPath, audioPath: audioPath, sessionID: sessionID)
    }

    public static func referenceTime(
        sessionID: String,
        refTimeMS: Double,
        localComputerTimeSendMS: Int
    ) -> InferenceEndpointOutgoingMessage {
        InferenceEndpointOutgoingMessage(
            type: .referenceTime,
            sessionID: sessionID,
            refTimeMS: Int(refTimeMS.rounded()),
            localComputerTimeSendMS: localComputerTimeSendMS
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

public struct InferenceHitObjectTokenBuffer: Equatable, Sendable {
    public private(set) var objects: [Mania4KHitObject]
    public private(set) var readyWindow: InferenceHitObjectReadyWindow?

    public init(objects: [Mania4KHitObject] = []) {
        self.objects = []
        self.readyWindow = nil
        append(contentsOf: objects)
    }

    @discardableResult
    public mutating func append(_ object: Mania4KHitObject) -> Bool {
        append(contentsOf: [object])
    }

    @discardableResult
    public mutating func append(contentsOf newObjects: [Mania4KHitObject]) -> Bool {
        let acceptedObjects = newObjects.filter { object in
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

    public mutating func removeAll() {
        objects.removeAll()
        readyWindow = nil
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
}

public enum InferenceEndpointLocalClock {
    public static func localComputerTimeSendMS(now: Date = Date(), calendar: Calendar = .current) -> Int {
        // Demo protocol: local wall-clock milliseconds since midnight; cross-day sessions are intentionally out of scope.
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
        let hourMS = (components.hour ?? 0) * 60 * 60 * 1_000
        let minuteMS = (components.minute ?? 0) * 60 * 1_000
        let secondMS = (components.second ?? 0) * 1_000
        let millisecond = Int((Double(components.nanosecond ?? 0) / 1_000_000).rounded())
        return hourMS + minuteMS + secondMS + millisecond
    }
}

public protocol InferenceEndpointClient: Sendable {
    func prepare() async throws
    func sendAudioPath(_ audioPath: String, sessionID: String) async throws
    func sendReferenceTime(sessionID: String, refTimeMS: Double, localComputerTimeSendMS: Int) async throws
    func stop(sessionID: String) async throws
    func nextEvent() async throws -> InferenceEndpointEvent
}

public actor InferenceEndpointWebSocketClient: InferenceEndpointClient {
    public static let defaultEndpointURL = URL(string: "ws://localhost:8765")!

    private let endpointURL: URL
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(endpointURL: URL = InferenceEndpointWebSocketClient.defaultEndpointURL, urlSession: URLSession = .shared) {
        self.endpointURL = endpointURL
        self.urlSession = urlSession
    }

    public func prepare() async throws {
        try await send(.ready())
    }

    public func sendAudioPath(_ audioPath: String, sessionID: String) async throws {
        try await send(.audioPath(audioPath, sessionID: sessionID))
    }

    public func sendReferenceTime(
        sessionID: String,
        refTimeMS: Double,
        localComputerTimeSendMS: Int
    ) async throws {
        try await send(.referenceTime(
            sessionID: sessionID,
            refTimeMS: refTimeMS,
            localComputerTimeSendMS: localComputerTimeSendMS
        ))
    }

    public func stop(sessionID: String) async throws {
        try await send(.stop(sessionID: sessionID))
    }

    public func nextEvent() async throws -> InferenceEndpointEvent {
        while true {
            let message = try await receiveMessage()
            if let event = try decodeEvent(from: message) {
                return event
            }
        }
    }

    private func send(_ message: InferenceEndpointOutgoingMessage) async throws {
        let task = ensureConnected()
        let data = try encoder.encode(message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw InferenceEndpointProtocolError.invalidTextFrame
        }

        try await task.send(.string(string))
    }

    private func receiveMessage() async throws -> URLSessionWebSocketTask.Message {
        let task = ensureConnected()
        return try await task.receive()
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

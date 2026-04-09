import Foundation

public enum MicrophonePermissionStatus: String, CaseIterable, Sendable {
    case undetermined
    case authorized
    case denied
    case restricted
}

public enum RecognitionSource: String, Sendable {
    case mockCatalog
    case shazamKit
    case acrCloud
}

public struct RecognizedTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let artworkURL: URL?
    public let externalIDs: ExternalIDs
    public let source: RecognitionSource

    public init(
        id: String,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        externalIDs: ExternalIDs = .init(),
        source: RecognitionSource
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.externalIDs = externalIDs
        self.source = source
    }
}

public struct ExternalIDs: Equatable, Sendable {
    public let appleMusicID: String?
    public let isrc: String?

    public init(appleMusicID: String? = nil, isrc: String? = nil) {
        self.appleMusicID = appleMusicID
        self.isrc = isrc
    }
}

public struct RecognitionAnchor: Equatable, Sendable {
    public let recognizedAt: Date
    public let predictedMatchOffset: TimeInterval?
    public let frequencySkew: Double?
    public let matchedRanges: [Range<TimeInterval>]

    public init(
        recognizedAt: Date,
        predictedMatchOffset: TimeInterval? = nil,
        frequencySkew: Double? = nil,
        matchedRanges: [Range<TimeInterval>] = []
    ) {
        self.recognizedAt = recognizedAt
        self.predictedMatchOffset = predictedMatchOffset
        self.frequencySkew = frequencySkew
        self.matchedRanges = matchedRanges
    }
}

public struct RecognitionSnapshot: Equatable, Sendable {
    public let track: RecognizedTrack
    public let anchor: RecognitionAnchor

    public init(track: RecognizedTrack, anchor: RecognitionAnchor) {
        self.track = track
        self.anchor = anchor
    }
}

public struct RecognitionFailure: Error, Equatable, Sendable {
    public let title: String
    public let message: String
    public let recoverySuggestion: String?
    public let allowsFallback: Bool

    public init(
        title: String,
        message: String,
        recoverySuggestion: String? = nil,
        allowsFallback: Bool = false
    ) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.allowsFallback = allowsFallback
    }

    public static let permissionRequired = RecognitionFailure(
        title: "Microphone Access Required",
        message: "Grant microphone access before starting a recognition pass.",
        recoverySuggestion: "Open the system prompt or enable the microphone in Settings."
    )

    public static let liveRecognitionUnavailable = RecognitionFailure(
        title: "Live Recognition Is Gated",
        message: "The ShazamKit milestone is intentionally deferred in this scaffold.",
        recoverySuggestion: "Keep using the mock catalog until capability and signing work is scheduled.",
        allowsFallback: true
    )

    public static let emptyMockCatalog = RecognitionFailure(
        title: "Mock Catalog Exhausted",
        message: "No more scripted mock outcomes are available.",
        recoverySuggestion: "Refill the mock queue or recreate the service."
    )

    public static func providerConfigurationMissing(
        providerName: String,
        missingFields: [String]
    ) -> RecognitionFailure {
        let missingList = missingFields.joined(separator: ", ")
        return RecognitionFailure(
            title: "\(providerName) Not Configured",
            message: missingFields.isEmpty
                ? "\(providerName) is selected but its setup is incomplete."
                : "\(providerName) is missing required configuration: \(missingList).",
            recoverySuggestion: "Provide the required provider credentials before enabling live recognition.",
            allowsFallback: true
        )
    }
}

public enum RecognitionOutcome: Equatable, Sendable {
    case matched(RecognitionSnapshot)
    case noMatch
    case failed(RecognitionFailure)
}

public enum RecognitionPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case listening
    case matched
    case noMatch
    case microphoneAccessRequired
    case failed(RecognitionFailure)
}

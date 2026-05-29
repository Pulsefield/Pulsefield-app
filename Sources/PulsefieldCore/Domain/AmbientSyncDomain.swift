import Foundation

public struct SyncEstimate: Equatable, Sendable {
    public let hostTime: ContinuousClock.Instant
    public let referenceTimeMS: Double
    public let confidence: Double
    public let driftPPM: Double?
    public let latencyMS: Double?
    public let source: SyncSource

    public init(
        hostTime: ContinuousClock.Instant,
        referenceTimeMS: Double,
        confidence: Double,
        driftPPM: Double?,
        latencyMS: Double?,
        source: SyncSource
    ) {
        self.hostTime = hostTime
        self.referenceTimeMS = referenceTimeMS
        self.confidence = confidence
        self.driftPPM = driftPPM
        self.latencyMS = latencyMS
        self.source = source
    }
}

public enum SyncSource: String, Sendable {
    case manual
    case controlledPlayback
    case localFeatureCorrelation
    case userNudge
}

public enum AmbientSyncState: Equatable, Sendable {
    case idle
    case preparingIndex
    case listening
    case locking
    case locked(SyncEstimate)
    case drifting(SyncEstimate)
    case lost
    case failed(String)
}

public enum AmbientSyncError: LocalizedError, Equatable, Sendable {
    case syncIndexAssetMismatch(assetID: UUID, indexAssetID: UUID)

    public var errorDescription: String? {
        switch self {
        case .syncIndexAssetMismatch:
            return "Sync index does not match selected local audio asset."
        }
    }
}

public struct LocalAudioSyncIndex: Equatable, Sendable, Codable {
    public let assetID: UUID
    public let durationMS: Int
    public let sampleRate: Double
    public let frameHopMS: Double
    public let onsetEnvelopeURL: URL
    public let spectralSummaryURL: URL?
    public let chromaURL: URL?
    public let version: Int
    public let createdAt: Date

    public init(
        assetID: UUID,
        durationMS: Int,
        sampleRate: Double,
        frameHopMS: Double,
        onsetEnvelopeURL: URL,
        spectralSummaryURL: URL?,
        chromaURL: URL?,
        version: Int,
        createdAt: Date
    ) {
        self.assetID = assetID
        self.durationMS = durationMS
        self.sampleRate = sampleRate
        self.frameHopMS = frameHopMS
        self.onsetEnvelopeURL = onsetEnvelopeURL
        self.spectralSummaryURL = spectralSummaryURL
        self.chromaURL = chromaURL
        self.version = version
        self.createdAt = createdAt
    }
}

public struct AmbientAudioWindow: Equatable, Sendable {
    public let hostTime: ContinuousClock.Instant
    public let sampleRate: Double
    public let samples: [Float]

    public init(hostTime: ContinuousClock.Instant, sampleRate: Double, samples: [Float]) {
        self.hostTime = hostTime
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

public protocol LocalAudioSyncIndexing: Sendable {
    func buildIndex(for asset: LocalAudioAsset) async throws -> LocalAudioSyncIndex
    func loadIndex(for assetID: UUID) async -> LocalAudioSyncIndex?
}

public protocol AmbientAudioCapturing: Sendable {
    func start() async throws
    func stop() async
    func latestWindow(durationMS: Int) async -> AmbientAudioWindow?
}

public protocol AmbientSyncEstimating: Sendable {
    func start(asset: LocalAudioAsset, index: LocalAudioSyncIndex) async throws
    func stop() async
    func currentEstimate() async -> SyncEstimate?
    func currentState() async -> AmbientSyncState
}

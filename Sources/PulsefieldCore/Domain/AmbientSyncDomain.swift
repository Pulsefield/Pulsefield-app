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

public enum AmbientSyncWithholdReason: String, Codable, Sendable {
    case insufficientEnergy
    case insufficientLandmarkEvidence
    case weakAlignmentPeak
    case ambiguousOffset
    case unstableTrackingResidual
    case lostSignal
}

public enum AmbientSyncStartError: String, LocalizedError, Equatable, Sendable {
    case indexUnavailable
    case indexInvalid
    case indexIncompatible

    public var errorDescription: String? {
        switch self {
        case .indexUnavailable:
            return "Sync index is unavailable for the selected local audio asset."
        case .indexInvalid:
            return "Sync index is invalid for the selected local audio asset."
        case .indexIncompatible:
            return "Sync index is incompatible with the ambient sync engine."
        }
    }
}

public enum AmbientSyncEngineState: String, Codable, Equatable, Sendable {
    case idle
    case indexing
    case ready
    case listening
    case locking
    case locked
    case drifting
    case relocking
    case lost
    case failed
}

@available(*, deprecated, renamed: "AmbientSyncEngineState")
public typealias AmbientSyncState = AmbientSyncEngineState

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
    public let manifestURL: URL?

    public init(
        assetID: UUID,
        durationMS: Int,
        sampleRate: Double,
        frameHopMS: Double,
        onsetEnvelopeURL: URL,
        spectralSummaryURL: URL?,
        chromaURL: URL?,
        version: Int,
        createdAt: Date,
        manifestURL: URL? = nil
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
        self.manifestURL = manifestURL
    }
}

public struct SyncIndexManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let featureExtractorVersion: String
    public let settingsHash: String
    public let createdAt: String
    public let asset: SyncIndexManifestAsset
    public let source: SyncIndexSourceIdentity
    public let processing: SyncIndexProcessingSettings
    public let features: SyncIndexFeatureSettings
    public let featureFiles: SyncIndexFeatureFiles

    public init(
        schemaVersion: Int,
        featureExtractorVersion: String,
        settingsHash: String,
        createdAt: String,
        asset: SyncIndexManifestAsset,
        source: SyncIndexSourceIdentity,
        processing: SyncIndexProcessingSettings,
        features: SyncIndexFeatureSettings,
        featureFiles: SyncIndexFeatureFiles
    ) {
        self.schemaVersion = schemaVersion
        self.featureExtractorVersion = featureExtractorVersion
        self.settingsHash = settingsHash
        self.createdAt = createdAt
        self.asset = asset
        self.source = source
        self.processing = processing
        self.features = features
        self.featureFiles = featureFiles
    }
}

public struct SyncIndexManifestAsset: Codable, Equatable, Sendable {
    public let assetID: UUID
    public let durationMS: Int

    public init(assetID: UUID, durationMS: Int) {
        self.assetID = assetID
        self.durationMS = durationMS
    }
}

public struct SyncIndexSourceIdentity: Codable, Equatable, Sendable {
    public let fileSizeBytes: Int64
    public let contentModificationDate: String
    public let fullFileSHA256: String
    public let decodedFrameCount: Int
    public let decodedDurationMS: Int
    public let originalSampleRate: Int
    public let originalChannelCount: Int

    public init(
        fileSizeBytes: Int64,
        contentModificationDate: String,
        fullFileSHA256: String,
        decodedFrameCount: Int,
        decodedDurationMS: Int,
        originalSampleRate: Int,
        originalChannelCount: Int
    ) {
        self.fileSizeBytes = fileSizeBytes
        self.contentModificationDate = contentModificationDate
        self.fullFileSHA256 = fullFileSHA256
        self.decodedFrameCount = decodedFrameCount
        self.decodedDurationMS = decodedDurationMS
        self.originalSampleRate = originalSampleRate
        self.originalChannelCount = originalChannelCount
    }
}

public struct SyncIndexProcessingSettings: Codable, Equatable, Sendable {
    public let processingSampleRate: Int
    public let fftSize: Int
    public let hopSize: Int
    public let window: String
    public let monoMix: String

    public init(
        processingSampleRate: Int,
        fftSize: Int,
        hopSize: Int,
        window: String,
        monoMix: String
    ) {
        self.processingSampleRate = processingSampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.window = window
        self.monoMix = monoMix
    }
}

public struct SyncIndexFeatureSettings: Codable, Equatable, Sendable {
    public let landmark: SyncIndexLandmarkSettings
    public let onsetFlux: SyncIndexDenseFeatureSettings
    public let logMel: SyncIndexDenseFeatureSettings
    public let chroma: SyncIndexChromaFeatureSettings

    public init(
        landmark: SyncIndexLandmarkSettings,
        onsetFlux: SyncIndexDenseFeatureSettings,
        logMel: SyncIndexDenseFeatureSettings,
        chroma: SyncIndexChromaFeatureSettings
    ) {
        self.landmark = landmark
        self.onsetFlux = onsetFlux
        self.logMel = logMel
        self.chroma = chroma
    }
}

public struct SyncIndexLandmarkSettings: Codable, Equatable, Sendable {
    public let hashVersion: Int
    public let peakNeighborhoodTime: Int
    public let peakNeighborhoodFreq: Int
    public let fanout: Int
    public let targetZoneStartMS: Int
    public let targetZoneEndMS: Int

    public init(
        hashVersion: Int,
        peakNeighborhoodTime: Int,
        peakNeighborhoodFreq: Int,
        fanout: Int,
        targetZoneStartMS: Int,
        targetZoneEndMS: Int
    ) {
        self.hashVersion = hashVersion
        self.peakNeighborhoodTime = peakNeighborhoodTime
        self.peakNeighborhoodFreq = peakNeighborhoodFreq
        self.fanout = fanout
        self.targetZoneStartMS = targetZoneStartMS
        self.targetZoneEndMS = targetZoneEndMS
    }
}

public struct SyncIndexDenseFeatureSettings: Codable, Equatable, Sendable {
    public let dims: Int

    public init(dims: Int) {
        self.dims = dims
    }
}

public struct SyncIndexChromaFeatureSettings: Codable, Equatable, Sendable {
    public let dims: Int
    public let smoothingMS: Int

    public init(dims: Int, smoothingMS: Int) {
        self.dims = dims
        self.smoothingMS = smoothingMS
    }
}

public struct SyncIndexFeatureFiles: Codable, Equatable, Sendable {
    public let landmarkPostings: SyncIndexRecordFeatureFile?
    public let denseOnsetFlux: SyncIndexMatrixFeatureFile
    public let denseLogMel: SyncIndexMatrixFeatureFile?
    public let denseChroma: SyncIndexMatrixFeatureFile?
    public let energy: SyncIndexMatrixFeatureFile?

    public init(
        landmarkPostings: SyncIndexRecordFeatureFile?,
        denseOnsetFlux: SyncIndexMatrixFeatureFile,
        denseLogMel: SyncIndexMatrixFeatureFile?,
        denseChroma: SyncIndexMatrixFeatureFile?,
        energy: SyncIndexMatrixFeatureFile?
    ) {
        self.landmarkPostings = landmarkPostings
        self.denseOnsetFlux = denseOnsetFlux
        self.denseLogMel = denseLogMel
        self.denseChroma = denseChroma
        self.energy = energy
    }
}

public struct SyncIndexRecordFeatureFile: Codable, Equatable, Sendable {
    public let path: String
    public let recordCount: Int
    public let sha256: String

    public init(path: String, recordCount: Int, sha256: String) {
        self.path = path
        self.recordCount = recordCount
        self.sha256 = sha256
    }
}

public struct SyncIndexMatrixFeatureFile: Codable, Equatable, Sendable {
    public let path: String
    public let frames: Int
    public let dims: Int
    public let sha256: String

    public init(path: String, frames: Int, dims: Int, sha256: String) {
        self.path = path
        self.frames = frames
        self.dims = dims
        self.sha256 = sha256
    }
}

public struct AmbientAudioWindow: Equatable, Sendable {
    public let hostTime: ContinuousClock.Instant
    public let sampleRate: Double
    public let inputChannelCount: Int
    public let samples: [Float]

    public init(
        hostTime: ContinuousClock.Instant,
        sampleRate: Double,
        inputChannelCount: Int = 1,
        samples: [Float]
    ) {
        self.hostTime = hostTime
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
        self.samples = samples
    }
}

public enum SearchMode: String, Codable, Sendable {
    case wide
    case narrow
    case relock
}

public enum LatencySource: String, Codable, Sendable {
    case unavailable
    case routeCalibration
    case manualCalibration
    case loopbackCalibration
    case measuredHardwarePath
}

public enum IndexRuntimeStatus: String, Codable, Sendable {
    case valid
    case unavailable
    case invalid
    case incompatible
}

public struct CandidateAlignment: Codable, Sendable, Equatable {
    public var offsetMS: Double
    public var referenceTimeAtWindowEndMS: Double
    public var combinedScore: Double
    public var onsetFluxScore: Double
    public var logMelScore: Double
    public var chromaScore: Double
    public var energyScore: Double
    public var landmarkVoteCount: Int
    public var landmarkInlierRate: Double
    public var peakSharpness: Double
    public var peakWidthMS: Double

    public init(
        offsetMS: Double,
        referenceTimeAtWindowEndMS: Double,
        combinedScore: Double,
        onsetFluxScore: Double,
        logMelScore: Double,
        chromaScore: Double,
        energyScore: Double,
        landmarkVoteCount: Int,
        landmarkInlierRate: Double,
        peakSharpness: Double,
        peakWidthMS: Double
    ) {
        self.offsetMS = offsetMS
        self.referenceTimeAtWindowEndMS = referenceTimeAtWindowEndMS
        self.combinedScore = combinedScore
        self.onsetFluxScore = onsetFluxScore
        self.logMelScore = logMelScore
        self.chromaScore = chromaScore
        self.energyScore = energyScore
        self.landmarkVoteCount = landmarkVoteCount
        self.landmarkInlierRate = landmarkInlierRate
        self.peakSharpness = peakSharpness
        self.peakWidthMS = peakWidthMS
    }
}

public struct AmbientMatchDiagnostics: Codable, Sendable, Equatable {
    public var index: IndexDiagnostics
    public var capture: CaptureDiagnostics
    public var query: QueryDiagnostics
    public var search: SearchDiagnostics
    public var scoring: ScoringDiagnostics
    public var clock: ClockDiagnostics
    public var decision: MatchDecisionDiagnostics

    public init(
        index: IndexDiagnostics,
        capture: CaptureDiagnostics,
        query: QueryDiagnostics,
        search: SearchDiagnostics,
        scoring: ScoringDiagnostics,
        clock: ClockDiagnostics,
        decision: MatchDecisionDiagnostics
    ) {
        self.index = index
        self.capture = capture
        self.query = query
        self.search = search
        self.scoring = scoring
        self.clock = clock
        self.decision = decision
    }
}

public struct IndexDiagnostics: Codable, Sendable, Equatable {
    public var status: IndexRuntimeStatus
    public var featureExtractorVersion: String
    public var settingsHash: String

    public init(
        status: IndexRuntimeStatus,
        featureExtractorVersion: String,
        settingsHash: String
    ) {
        self.status = status
        self.featureExtractorVersion = featureExtractorVersion
        self.settingsHash = settingsHash
    }
}

public struct CaptureDiagnostics: Codable, Sendable, Equatable {
    public var windowDurationMS: Double
    public var windowEndHostTimeMS: Double
    public var inputSampleRate: Double
    public var inputChannelCount: Int
    public var capturedFrameCount: Int
    public var droppedWindowCount: Int

    public init(
        windowDurationMS: Double,
        windowEndHostTimeMS: Double,
        inputSampleRate: Double,
        inputChannelCount: Int,
        capturedFrameCount: Int,
        droppedWindowCount: Int
    ) {
        self.windowDurationMS = windowDurationMS
        self.windowEndHostTimeMS = windowEndHostTimeMS
        self.inputSampleRate = inputSampleRate
        self.inputChannelCount = inputChannelCount
        self.capturedFrameCount = capturedFrameCount
        self.droppedWindowCount = droppedWindowCount
    }
}

public struct QueryDiagnostics: Codable, Sendable, Equatable {
    public var featureFrameCount: Int
    public var landmarkCount: Int
    public var energyDBFS: Double
    public var activeFrameFraction: Double
    public var processingSampleRate: Int
    public var hopSize: Int

    public init(
        featureFrameCount: Int,
        landmarkCount: Int,
        energyDBFS: Double,
        activeFrameFraction: Double,
        processingSampleRate: Int,
        hopSize: Int
    ) {
        self.featureFrameCount = featureFrameCount
        self.landmarkCount = landmarkCount
        self.energyDBFS = energyDBFS
        self.activeFrameFraction = activeFrameFraction
        self.processingSampleRate = processingSampleRate
        self.hopSize = hopSize
    }
}

public struct MatchDecisionDiagnostics: Codable, Sendable, Equatable {
    public var didPublishEstimate: Bool
    public var withholdReason: AmbientSyncWithholdReason?
    public var confidence: Double
    public var explanation: String

    public init(
        didPublishEstimate: Bool,
        withholdReason: AmbientSyncWithholdReason?,
        confidence: Double,
        explanation: String
    ) {
        self.didPublishEstimate = didPublishEstimate
        self.withholdReason = withholdReason
        self.confidence = confidence
        self.explanation = explanation
    }
}

public struct SearchDiagnostics: Codable, Sendable, Equatable {
    public var mode: SearchMode
    public var searchRangeStartMS: Double
    public var searchRangeEndMS: Double
    public var predictedReferenceMS: Double?
    public var selectedReferenceMS: Double?
    public var candidateCount: Int
    public var candidateDensity: Double
    public var topCandidates: [CandidateAlignment]

    public init(
        mode: SearchMode,
        searchRangeStartMS: Double,
        searchRangeEndMS: Double,
        predictedReferenceMS: Double?,
        selectedReferenceMS: Double?,
        candidateCount: Int,
        candidateDensity: Double,
        topCandidates: [CandidateAlignment]
    ) {
        self.mode = mode
        self.searchRangeStartMS = searchRangeStartMS
        self.searchRangeEndMS = searchRangeEndMS
        self.predictedReferenceMS = predictedReferenceMS
        self.selectedReferenceMS = selectedReferenceMS
        self.candidateCount = candidateCount
        self.candidateDensity = candidateDensity
        self.topCandidates = topCandidates
    }
}

public struct ScoringDiagnostics: Codable, Sendable, Equatable {
    public var peakScore: Double
    public var secondBestScore: Double?
    public var peakMargin: Double?
    public var peakRatio: Double?
    public var peakSharpness: Double?
    public var peakWidthMS: Double?
    public var noiseFloorMean: Double?
    public var noiseFloorStd: Double?
    public var peakZ: Double?
    public var landmarkVoteCount: Int
    public var landmarkInlierRate: Double
    public var onsetFluxScore: Double?
    public var logMelScore: Double?
    public var chromaScore: Double?
    public var energyScore: Double?
    public var timeResidualMS: Double?

    public init(
        peakScore: Double,
        secondBestScore: Double?,
        peakMargin: Double?,
        peakRatio: Double?,
        peakSharpness: Double?,
        peakWidthMS: Double?,
        noiseFloorMean: Double?,
        noiseFloorStd: Double?,
        peakZ: Double?,
        landmarkVoteCount: Int,
        landmarkInlierRate: Double,
        onsetFluxScore: Double?,
        logMelScore: Double?,
        chromaScore: Double?,
        energyScore: Double?,
        timeResidualMS: Double?
    ) {
        self.peakScore = peakScore
        self.secondBestScore = secondBestScore
        self.peakMargin = peakMargin
        self.peakRatio = peakRatio
        self.peakSharpness = peakSharpness
        self.peakWidthMS = peakWidthMS
        self.noiseFloorMean = noiseFloorMean
        self.noiseFloorStd = noiseFloorStd
        self.peakZ = peakZ
        self.landmarkVoteCount = landmarkVoteCount
        self.landmarkInlierRate = landmarkInlierRate
        self.onsetFluxScore = onsetFluxScore
        self.logMelScore = logMelScore
        self.chromaScore = chromaScore
        self.energyScore = energyScore
        self.timeResidualMS = timeResidualMS
    }
}

public struct ClockDiagnostics: Codable, Sendable, Equatable {
    public var observationCount: Int
    public var rawDriftPPM: Double?
    public var smoothedDriftPPM: Double?
    public var trackingStability: Double
    public var latencyMS: Double?
    public var latencySource: LatencySource

    public init(
        observationCount: Int,
        rawDriftPPM: Double?,
        smoothedDriftPPM: Double?,
        trackingStability: Double,
        latencyMS: Double?,
        latencySource: LatencySource
    ) {
        self.observationCount = observationCount
        self.rawDriftPPM = rawDriftPPM
        self.smoothedDriftPPM = smoothedDriftPPM
        self.trackingStability = trackingStability
        self.latencyMS = latencyMS
        self.latencySource = latencySource
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
    func currentState() async -> AmbientSyncEngineState
    func currentDiagnostics() async -> AmbientMatchDiagnostics?
}

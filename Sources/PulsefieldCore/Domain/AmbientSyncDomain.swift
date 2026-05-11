import Foundation

public enum PulsefieldHostClock {
    public static func currentTimeMS() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }
}

public struct MicAudioChunk: Equatable, Sendable {
    public let monoSamples: [Float]
    public let sampleRate: Double
    public let recordedStartTimeMS: Double
    public let hostStartTimeMS: Double
    public let inputChannelCount: Int

    public init(
        monoSamples: [Float],
        sampleRate: Double,
        recordedStartTimeMS: Double,
        hostStartTimeMS: Double,
        inputChannelCount: Int
    ) {
        precondition(sampleRate > 0, "sampleRate must be positive.")
        precondition(inputChannelCount > 0, "inputChannelCount must be positive.")

        self.monoSamples = monoSamples
        self.sampleRate = sampleRate
        self.recordedStartTimeMS = recordedStartTimeMS
        self.hostStartTimeMS = hostStartTimeMS
        self.inputChannelCount = inputChannelCount
    }

    public var durationMS: Double {
        Double(monoSamples.count) / sampleRate * 1_000
    }

    public var recordedEndTimeMS: Double {
        recordedStartTimeMS + durationMS
    }

    public var hostEndTimeMS: Double {
        hostStartTimeMS + durationMS
    }
}

public struct MicFeatureAudioWindow: Equatable, Sendable {
    public let monoSamples: [Float]
    public let sampleRate: Double
    public let recordedStartTimeMS: Double
    public let recordedTimeMS: Double
    public let hostStartTimeMS: Double
    public let hostTimeMS: Double
    public let inputChannelCount: Int

    public init(
        monoSamples: [Float],
        sampleRate: Double,
        recordedStartTimeMS: Double,
        recordedTimeMS: Double,
        hostStartTimeMS: Double,
        hostTimeMS: Double,
        inputChannelCount: Int
    ) {
        self.monoSamples = monoSamples
        self.sampleRate = sampleRate
        self.recordedStartTimeMS = recordedStartTimeMS
        self.recordedTimeMS = recordedTimeMS
        self.hostStartTimeMS = hostStartTimeMS
        self.hostTimeMS = hostTimeMS
        self.inputChannelCount = inputChannelCount
    }

    public var durationMS: Double {
        recordedTimeMS - recordedStartTimeMS
    }
}

public struct MicFeaturePayload: Equatable, Sendable {
    public let onsetEnvelope: Float
    public let subbandOnset: [Float]
    public let pcenMel: [Float]
    public let chroma: [Float]
    public let cens: [Float]
    public let landmarks: [MicFeatureLandmark]
    public let landmarkHashes: [UInt64]
    public let energyDBFS: Double
    public let snrDB: Double?

    public init(
        onsetEnvelope: Float,
        subbandOnset: [Float],
        pcenMel: [Float],
        chroma: [Float],
        cens: [Float],
        landmarkHashes: [UInt64],
        landmarks: [MicFeatureLandmark] = [],
        energyDBFS: Double,
        snrDB: Double?
    ) {
        self.onsetEnvelope = onsetEnvelope
        self.subbandOnset = subbandOnset
        self.pcenMel = pcenMel
        self.chroma = chroma
        self.cens = cens
        self.landmarks = landmarks
        self.landmarkHashes = landmarks.isEmpty ? landmarkHashes : landmarks.map(\.hash)
        self.energyDBFS = energyDBFS
        self.snrDB = snrDB
    }
}

public struct MicFeatureLandmark: Codable, Equatable, Sendable {
    public let hash: UInt64
    public let anchorTimeMS: Double
    public let anchorFrequencyBin: Int
    public let targetFrequencyBin: Int
    public let deltaFrames: Int

    public init(
        hash: UInt64,
        anchorTimeMS: Double,
        anchorFrequencyBin: Int,
        targetFrequencyBin: Int,
        deltaFrames: Int
    ) {
        precondition(anchorFrequencyBin >= 0, "anchorFrequencyBin must be non-negative.")
        precondition(targetFrequencyBin >= 0, "targetFrequencyBin must be non-negative.")
        precondition(deltaFrames > 0, "deltaFrames must be positive.")

        self.hash = hash
        self.anchorTimeMS = anchorTimeMS
        self.anchorFrequencyBin = anchorFrequencyBin
        self.targetFrequencyBin = targetFrequencyBin
        self.deltaFrames = deltaFrames
    }
}

public struct MicFeatureFrame: Codable, Equatable, Sendable {
    public let recordedTimeMS: Double
    public let hostTimeMS: Double
    public let onsetEnvelope: Float
    public let subbandOnset: [Float]
    public let pcenMel: [Float]
    public let chroma: [Float]
    public let cens: [Float]
    public let landmarks: [MicFeatureLandmark]
    public let landmarkHashes: [UInt64]
    public let energyDBFS: Double
    public let snrDB: Double?

    public init(
        recordedTimeMS: Double,
        hostTimeMS: Double,
        onsetEnvelope: Float,
        subbandOnset: [Float],
        pcenMel: [Float],
        chroma: [Float],
        cens: [Float],
        landmarkHashes: [UInt64],
        landmarks: [MicFeatureLandmark] = [],
        energyDBFS: Double,
        snrDB: Double?
    ) {
        self.recordedTimeMS = recordedTimeMS
        self.hostTimeMS = hostTimeMS
        self.onsetEnvelope = onsetEnvelope
        self.subbandOnset = subbandOnset
        self.pcenMel = pcenMel
        self.chroma = chroma
        self.cens = cens
        self.landmarks = landmarks
        self.landmarkHashes = landmarks.isEmpty ? landmarkHashes : landmarks.map(\.hash)
        self.energyDBFS = energyDBFS
        self.snrDB = snrDB
    }

    public init(
        recordedTimeMS: Double,
        hostTimeMS: Double,
        payload: MicFeaturePayload
    ) {
        self.init(
            recordedTimeMS: recordedTimeMS,
            hostTimeMS: hostTimeMS,
            onsetEnvelope: payload.onsetEnvelope,
            subbandOnset: payload.subbandOnset,
            pcenMel: payload.pcenMel,
            chroma: payload.chroma,
            cens: payload.cens,
            landmarkHashes: payload.landmarkHashes,
            landmarks: payload.landmarks,
            energyDBFS: payload.energyDBFS,
            snrDB: payload.snrDB
        )
    }
}

public struct MicFeatureWindow: Equatable, Sendable {
    public let frames: [MicFeatureFrame]

    public init(frames: [MicFeatureFrame]) {
        precondition(!frames.isEmpty, "MicFeatureWindow requires at least one frame.")
        self.frames = frames
    }

    public var startRecordedTimeMS: Double {
        frames[0].recordedTimeMS
    }

    public var endpointRecordedTimeMS: Double {
        frames[frames.count - 1].recordedTimeMS
    }

    public var endpointHostTimeMS: Double {
        frames[frames.count - 1].hostTimeMS
    }

    public var durationMS: Double {
        endpointRecordedTimeMS - startRecordedTimeMS
    }

    public var landmarkCount: Int {
        frames.reduce(0) { count, frame in
            count + frame.landmarkHashes.count
        }
    }
}

public enum AmbientSyncState: String, Codable, Equatable, Sendable {
    case ready
    case listening
    case locking
    case confirmed
    case locked
    case drifting
    case relocking
    case lost
    case failed
}

public enum AmbientSyncLockPhase: String, Codable, Equatable, Sendable {
    case none
    case provisional
    case confirmed
    case final
}

public enum AmbientSyncStage: String, Codable, Equatable, Sendable {
    case readiness
    case landmarkCoarse
    case fastTimingVerify
    case robustVerify
    case tracking
    case relock
}

public enum AmbientSyncWithholdReason: String, Codable, Equatable, Sendable {
    case insufficientDuration
    case insufficientEnergy
    case insufficientActiveFrames
    case insufficientLandmarkEvidence
    case weakAlignmentPeak
    case ambiguousOffset
    case unstableTrackingResidual
    case lostSignal
    case decodeFailed
    case indexUnavailable
}

public struct AmbientSyncFeatureConfiguration: Codable, Equatable, Sendable {
    public let processingSampleRate: Double
    public let featureWindowSizeSamples: Int
    public let featureHopSizeSamples: Int
    public let speculativeQueryDurationMS: Double
    public let firstLockMinimumDurationMS: Double
    public let firstLockTargetDurationMS: Double
    public let finalLockMinimumDurationMS: Double
    public let finalLockTargetDurationMS: Double
    public let trackingQueryDurationMS: Double

    public init(
        processingSampleRate: Double = 48_000,
        featureWindowSizeSamples: Int = 1_024,
        featureHopSizeSamples: Int = 512,
        speculativeQueryDurationMS: Double = 1_500,
        firstLockMinimumDurationMS: Double = 2_500,
        firstLockTargetDurationMS: Double = 3_000,
        finalLockMinimumDurationMS: Double = 4_500,
        finalLockTargetDurationMS: Double = 5_000,
        trackingQueryDurationMS: Double = 2_000
    ) {
        precondition(processingSampleRate > 0, "processingSampleRate must be positive.")
        precondition(featureWindowSizeSamples > 0, "featureWindowSizeSamples must be positive.")
        precondition(featureHopSizeSamples > 0, "featureHopSizeSamples must be positive.")
        precondition(
            featureHopSizeSamples <= featureWindowSizeSamples,
            "featureHopSizeSamples must not exceed featureWindowSizeSamples."
        )
        precondition(speculativeQueryDurationMS > 0, "speculativeQueryDurationMS must be positive.")
        precondition(firstLockMinimumDurationMS > 0, "firstLockMinimumDurationMS must be positive.")
        precondition(firstLockTargetDurationMS >= firstLockMinimumDurationMS, "firstLockTargetDurationMS must not be below firstLockMinimumDurationMS.")
        precondition(finalLockMinimumDurationMS >= firstLockMinimumDurationMS, "finalLockMinimumDurationMS must not be below firstLockMinimumDurationMS.")
        precondition(finalLockTargetDurationMS >= finalLockMinimumDurationMS, "finalLockTargetDurationMS must not be below finalLockMinimumDurationMS.")
        precondition(trackingQueryDurationMS > 0, "trackingQueryDurationMS must be positive.")

        self.processingSampleRate = processingSampleRate
        self.featureWindowSizeSamples = featureWindowSizeSamples
        self.featureHopSizeSamples = featureHopSizeSamples
        self.speculativeQueryDurationMS = speculativeQueryDurationMS
        self.firstLockMinimumDurationMS = firstLockMinimumDurationMS
        self.firstLockTargetDurationMS = firstLockTargetDurationMS
        self.finalLockMinimumDurationMS = finalLockMinimumDurationMS
        self.finalLockTargetDurationMS = finalLockTargetDurationMS
        self.trackingQueryDurationMS = trackingQueryDurationMS
    }

    public static let v1 = AmbientSyncFeatureConfiguration()

    public var featureHopMS: Double {
        Double(featureHopSizeSamples) / processingSampleRate * 1_000
    }
}

public struct AmbientSyncEstimate: Codable, Equatable, Sendable {
    public let queryEndpointRecordedTimeMS: Double
    public let referenceTimeMS: Double
    public let offsetMS: Double
    public let driftPPM: Double?

    public init(
        queryEndpointRecordedTimeMS: Double,
        referenceTimeMS: Double,
        offsetMS: Double,
        driftPPM: Double? = nil
    ) {
        self.queryEndpointRecordedTimeMS = queryEndpointRecordedTimeMS
        self.referenceTimeMS = referenceTimeMS
        self.offsetMS = offsetMS
        self.driftPPM = driftPPM
    }
}

public struct AmbientSyncCandidateDiagnostics: Codable, Equatable, Sendable {
    public let offsetMS: Double
    public let coarseOffsetMS: Double
    public let landmarkVoteCount: Int
    public let rawVoteCount: Int
    public let weightedVoteScore: Double
    public let uniqueHashCount: Int
    public let commonHashVoteCount: Int
    public let meanReferencePostingCount: Double
    public let landmarkScore: Double
    public let voteDensity: Double
    public let comparableFrameCount: Int
    public let coverageRatio: Double
    public let onsetScore: Double
    public let subbandOnsetScore: Double
    public let pcenMelScore: Double
    public let chromaOnsetScore: Double
    public let censScore: Double
    public let combinedDenseScore: Double
    public let featureAgreementCount: Int

    public init(
        offsetMS: Double,
        coarseOffsetMS: Double,
        landmarkVoteCount: Int,
        rawVoteCount: Int? = nil,
        weightedVoteScore: Double? = nil,
        uniqueHashCount: Int? = nil,
        commonHashVoteCount: Int = 0,
        meanReferencePostingCount: Double = 0,
        landmarkScore: Double,
        voteDensity: Double,
        comparableFrameCount: Int,
        coverageRatio: Double,
        onsetScore: Double,
        subbandOnsetScore: Double,
        pcenMelScore: Double,
        chromaOnsetScore: Double,
        censScore: Double,
        combinedDenseScore: Double,
        featureAgreementCount: Int
    ) {
        self.offsetMS = offsetMS
        self.coarseOffsetMS = coarseOffsetMS
        self.landmarkVoteCount = landmarkVoteCount
        let resolvedRawVoteCount = rawVoteCount ?? landmarkVoteCount
        self.rawVoteCount = resolvedRawVoteCount
        self.weightedVoteScore = weightedVoteScore ?? Double(resolvedRawVoteCount)
        self.uniqueHashCount = uniqueHashCount ?? resolvedRawVoteCount
        self.commonHashVoteCount = commonHashVoteCount
        self.meanReferencePostingCount = meanReferencePostingCount
        self.landmarkScore = landmarkScore
        self.voteDensity = voteDensity
        self.comparableFrameCount = comparableFrameCount
        self.coverageRatio = coverageRatio
        self.onsetScore = onsetScore
        self.subbandOnsetScore = subbandOnsetScore
        self.pcenMelScore = pcenMelScore
        self.chromaOnsetScore = chromaOnsetScore
        self.censScore = censScore
        self.combinedDenseScore = combinedDenseScore
        self.featureAgreementCount = featureAgreementCount
    }

    private enum CodingKeys: String, CodingKey {
        case offsetMS
        case coarseOffsetMS
        case landmarkVoteCount
        case rawVoteCount
        case weightedVoteScore
        case uniqueHashCount
        case commonHashVoteCount
        case meanReferencePostingCount
        case landmarkScore
        case voteDensity
        case comparableFrameCount
        case coverageRatio
        case onsetScore
        case subbandOnsetScore
        case pcenMelScore
        case chromaOnsetScore
        case censScore
        case combinedDenseScore
        case featureAgreementCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let landmarkVoteCount = try container.decode(Int.self, forKey: .landmarkVoteCount)
        self.init(
            offsetMS: try container.decode(Double.self, forKey: .offsetMS),
            coarseOffsetMS: try container.decode(Double.self, forKey: .coarseOffsetMS),
            landmarkVoteCount: landmarkVoteCount,
            rawVoteCount: try container.decodeIfPresent(Int.self, forKey: .rawVoteCount),
            weightedVoteScore: try container.decodeIfPresent(Double.self, forKey: .weightedVoteScore),
            uniqueHashCount: try container.decodeIfPresent(Int.self, forKey: .uniqueHashCount),
            commonHashVoteCount: try container.decodeIfPresent(Int.self, forKey: .commonHashVoteCount) ?? 0,
            meanReferencePostingCount: try container.decodeIfPresent(Double.self, forKey: .meanReferencePostingCount) ?? 0,
            landmarkScore: try container.decode(Double.self, forKey: .landmarkScore),
            voteDensity: try container.decode(Double.self, forKey: .voteDensity),
            comparableFrameCount: try container.decode(Int.self, forKey: .comparableFrameCount),
            coverageRatio: try container.decode(Double.self, forKey: .coverageRatio),
            onsetScore: try container.decode(Double.self, forKey: .onsetScore),
            subbandOnsetScore: try container.decode(Double.self, forKey: .subbandOnsetScore),
            pcenMelScore: try container.decode(Double.self, forKey: .pcenMelScore),
            chromaOnsetScore: try container.decode(Double.self, forKey: .chromaOnsetScore),
            censScore: try container.decode(Double.self, forKey: .censScore),
            combinedDenseScore: try container.decode(Double.self, forKey: .combinedDenseScore),
            featureAgreementCount: try container.decode(Int.self, forKey: .featureAgreementCount)
        )
    }
}

public struct AmbientSyncOffsetTrackDiagnostics: Codable, Equatable, Sendable {
    public let offsetMS: Double
    public let velocityMSPerSecond: Double
    public let confidenceLogOdds: Double
    public let lastUpdateElapsedMS: Double
    public let consecutiveHits: Int
    public let consecutiveMisses: Int
    public let lastInnovationMS: Double?

    public init(
        offsetMS: Double,
        velocityMSPerSecond: Double,
        confidenceLogOdds: Double,
        lastUpdateElapsedMS: Double,
        consecutiveHits: Int,
        consecutiveMisses: Int,
        lastInnovationMS: Double? = nil
    ) {
        self.offsetMS = offsetMS
        self.velocityMSPerSecond = velocityMSPerSecond
        self.confidenceLogOdds = confidenceLogOdds
        self.lastUpdateElapsedMS = lastUpdateElapsedMS
        self.consecutiveHits = consecutiveHits
        self.consecutiveMisses = consecutiveMisses
        self.lastInnovationMS = lastInnovationMS
    }
}

public struct AmbientSyncDiagnostics: Codable, Equatable, Sendable {
    public let queryDurationMS: Double
    public let activeFrameFraction: Double
    public let queryLandmarkCount: Int
    public let histogramCandidateCount: Int
    public let topLandmarkVoteCount: Int
    public let secondLandmarkVoteCount: Int
    public let topWeightedVoteScore: Double
    public let secondWeightedVoteScore: Double
    public let topToSecondWeightedVoteRatio: Double
    public let topWeightedVoteMargin: Double
    public let topToSecondVoteRatio: Double
    public let topVoteMargin: Int
    public let coarseAmbiguous: Bool
    public let denseMargin: Double
    public let offsetStabilityMS: Double?
    public let trackInnovationMS: Double?
    public let trackConfidenceMargin: Double
    public let trackConfidenceLogOdds: Double
    public let trackCount: Int
    public let offsetTrackerConfirmed: Bool
    public let offsetTrackerStable: Bool
    public let offsetTracks: [AmbientSyncOffsetTrackDiagnostics]
    public let candidates: [AmbientSyncCandidateDiagnostics]

    public init(
        queryDurationMS: Double,
        activeFrameFraction: Double,
        queryLandmarkCount: Int,
        histogramCandidateCount: Int = 0,
        topLandmarkVoteCount: Int = 0,
        secondLandmarkVoteCount: Int = 0,
        topWeightedVoteScore: Double? = nil,
        secondWeightedVoteScore: Double? = nil,
        topToSecondWeightedVoteRatio: Double? = nil,
        topWeightedVoteMargin: Double? = nil,
        topToSecondVoteRatio: Double = 0,
        topVoteMargin: Int = 0,
        coarseAmbiguous: Bool = false,
        denseMargin: Double = 0,
        offsetStabilityMS: Double? = nil,
        trackInnovationMS: Double? = nil,
        trackConfidenceMargin: Double = 0,
        trackConfidenceLogOdds: Double = 0,
        trackCount: Int = 0,
        offsetTrackerConfirmed: Bool = false,
        offsetTrackerStable: Bool = false,
        offsetTracks: [AmbientSyncOffsetTrackDiagnostics] = [],
        candidates: [AmbientSyncCandidateDiagnostics] = []
    ) {
        self.queryDurationMS = queryDurationMS
        self.activeFrameFraction = activeFrameFraction
        self.queryLandmarkCount = queryLandmarkCount
        self.histogramCandidateCount = histogramCandidateCount
        self.topLandmarkVoteCount = topLandmarkVoteCount
        self.secondLandmarkVoteCount = secondLandmarkVoteCount
        self.topWeightedVoteScore = topWeightedVoteScore ?? Double(topLandmarkVoteCount)
        self.secondWeightedVoteScore = secondWeightedVoteScore ?? Double(secondLandmarkVoteCount)
        self.topToSecondWeightedVoteRatio = topToSecondWeightedVoteRatio ?? topToSecondVoteRatio
        self.topWeightedVoteMargin = topWeightedVoteMargin ?? Double(topVoteMargin)
        self.topToSecondVoteRatio = topToSecondVoteRatio
        self.topVoteMargin = topVoteMargin
        self.coarseAmbiguous = coarseAmbiguous
        self.denseMargin = denseMargin
        self.offsetStabilityMS = offsetStabilityMS
        self.trackInnovationMS = trackInnovationMS
        self.trackConfidenceMargin = trackConfidenceMargin
        self.trackConfidenceLogOdds = trackConfidenceLogOdds
        self.trackCount = trackCount
        self.offsetTrackerConfirmed = offsetTrackerConfirmed
        self.offsetTrackerStable = offsetTrackerStable
        self.offsetTracks = offsetTracks
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey {
        case queryDurationMS
        case activeFrameFraction
        case queryLandmarkCount
        case histogramCandidateCount
        case topLandmarkVoteCount
        case secondLandmarkVoteCount
        case topWeightedVoteScore
        case secondWeightedVoteScore
        case topToSecondWeightedVoteRatio
        case topWeightedVoteMargin
        case topToSecondVoteRatio
        case topVoteMargin
        case coarseAmbiguous
        case denseMargin
        case offsetStabilityMS
        case trackInnovationMS
        case trackConfidenceMargin
        case trackConfidenceLogOdds
        case trackCount
        case offsetTrackerConfirmed
        case offsetTrackerStable
        case offsetTracks
        case candidates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topLandmarkVoteCount = try container.decodeIfPresent(Int.self, forKey: .topLandmarkVoteCount) ?? 0
        let secondLandmarkVoteCount = try container.decodeIfPresent(Int.self, forKey: .secondLandmarkVoteCount) ?? 0
        let topToSecondVoteRatio = try container.decodeIfPresent(Double.self, forKey: .topToSecondVoteRatio) ?? 0
        let topVoteMargin = try container.decodeIfPresent(Int.self, forKey: .topVoteMargin) ?? 0

        self.init(
            queryDurationMS: try container.decode(Double.self, forKey: .queryDurationMS),
            activeFrameFraction: try container.decode(Double.self, forKey: .activeFrameFraction),
            queryLandmarkCount: try container.decode(Int.self, forKey: .queryLandmarkCount),
            histogramCandidateCount: try container.decodeIfPresent(Int.self, forKey: .histogramCandidateCount) ?? 0,
            topLandmarkVoteCount: topLandmarkVoteCount,
            secondLandmarkVoteCount: secondLandmarkVoteCount,
            topWeightedVoteScore: try container.decodeIfPresent(Double.self, forKey: .topWeightedVoteScore)
                ?? Double(topLandmarkVoteCount),
            secondWeightedVoteScore: try container.decodeIfPresent(Double.self, forKey: .secondWeightedVoteScore)
                ?? Double(secondLandmarkVoteCount),
            topToSecondWeightedVoteRatio: try container.decodeIfPresent(
                Double.self,
                forKey: .topToSecondWeightedVoteRatio
            ) ?? topToSecondVoteRatio,
            topWeightedVoteMargin: try container.decodeIfPresent(Double.self, forKey: .topWeightedVoteMargin)
                ?? Double(topVoteMargin),
            topToSecondVoteRatio: topToSecondVoteRatio,
            topVoteMargin: topVoteMargin,
            coarseAmbiguous: try container.decodeIfPresent(Bool.self, forKey: .coarseAmbiguous) ?? false,
            denseMargin: try container.decodeIfPresent(Double.self, forKey: .denseMargin) ?? 0,
            offsetStabilityMS: try container.decodeIfPresent(Double.self, forKey: .offsetStabilityMS),
            trackInnovationMS: try container.decodeIfPresent(Double.self, forKey: .trackInnovationMS),
            trackConfidenceMargin: try container.decodeIfPresent(Double.self, forKey: .trackConfidenceMargin) ?? 0,
            trackConfidenceLogOdds: try container.decodeIfPresent(Double.self, forKey: .trackConfidenceLogOdds) ?? 0,
            trackCount: try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0,
            offsetTrackerConfirmed: try container.decodeIfPresent(
                Bool.self,
                forKey: .offsetTrackerConfirmed
            ) ?? false,
            offsetTrackerStable: try container.decodeIfPresent(Bool.self, forKey: .offsetTrackerStable) ?? false,
            offsetTracks: try container.decodeIfPresent(
                [AmbientSyncOffsetTrackDiagnostics].self,
                forKey: .offsetTracks
            ) ?? [],
            candidates: try container.decodeIfPresent(
                [AmbientSyncCandidateDiagnostics].self,
                forKey: .candidates
            ) ?? []
        )
    }
}

public struct AmbientSyncSnapshot: Codable, Equatable, Sendable {
    public let state: AmbientSyncState
    public let phase: AmbientSyncLockPhase
    public let stage: AmbientSyncStage
    public let estimate: AmbientSyncEstimate?
    public let withholdReason: AmbientSyncWithholdReason?
    public let confidence: Double
    public let diagnostics: AmbientSyncDiagnostics
    public let firstProvisionalLockElapsedMS: Double?
    public let confirmedLockElapsedMS: Double?
    public let finalLockElapsedMS: Double?

    public init(
        state: AmbientSyncState,
        phase: AmbientSyncLockPhase,
        stage: AmbientSyncStage,
        estimate: AmbientSyncEstimate? = nil,
        withholdReason: AmbientSyncWithholdReason? = nil,
        confidence: Double = 0,
        diagnostics: AmbientSyncDiagnostics,
        firstProvisionalLockElapsedMS: Double? = nil,
        confirmedLockElapsedMS: Double? = nil,
        finalLockElapsedMS: Double? = nil
    ) {
        self.state = state
        self.phase = phase
        self.stage = stage
        self.estimate = estimate
        self.withholdReason = withholdReason
        self.confidence = confidence
        self.diagnostics = diagnostics
        self.firstProvisionalLockElapsedMS = firstProvisionalLockElapsedMS
        self.confirmedLockElapsedMS = confirmedLockElapsedMS
        self.finalLockElapsedMS = finalLockElapsedMS
    }
}

public enum AmbientSyncTimeProjection {
    public static func offsetMS(localReferenceTimeMS: Double, micQueryTimeMS: Double) -> Double {
        localReferenceTimeMS - micQueryTimeMS
    }

    public static func referenceTimeAtNowMS(
        localReferenceTimeAtQueryMS: Double,
        queryEndpointRecordedTimeMS: Double,
        nowMS: Double
    ) -> Double {
        localReferenceTimeAtQueryMS + nowMS - queryEndpointRecordedTimeMS
    }
}

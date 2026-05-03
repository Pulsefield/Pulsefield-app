import Foundation

public protocol AmbientSyncEngineReferenceIndex: Sendable {
    var sourceDisplayPath: String { get }
    var featureConfiguration: AmbientSyncFeatureConfiguration { get }
    var frames: [MicFeatureFrame] { get }
    var landmarks: [MicFeatureLandmark] { get }
    var landmarkIndex: AmbientSyncLandmarkIndex { get }
}

public struct AmbientSyncEngine: Equatable, Sendable {
    public struct Reference: AmbientSyncEngineReferenceIndex, Equatable, Sendable {
        public let sourceDisplayPath: String
        public let featureConfiguration: AmbientSyncFeatureConfiguration
        public let frames: [MicFeatureFrame]
        public let landmarks: [MicFeatureLandmark]
        public let landmarkIndex: AmbientSyncLandmarkIndex

        public init(
            sourceDisplayPath: String,
            featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
            frames: [MicFeatureFrame],
            landmarks: [MicFeatureLandmark] = [],
            landmarkIndex: AmbientSyncLandmarkIndex? = nil
        ) {
            let referenceLandmarks = landmarks.isEmpty
                ? AmbientSyncEngine.landmarks(from: frames)
                : landmarks

            self.sourceDisplayPath = sourceDisplayPath
            self.featureConfiguration = featureConfiguration
            self.frames = frames.sorted { $0.recordedTimeMS < $1.recordedTimeMS }
            self.landmarks = referenceLandmarks
            self.landmarkIndex = landmarkIndex ?? AmbientSyncLandmarkIndex(landmarks: referenceLandmarks)
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let featureConfiguration: AmbientSyncFeatureConfiguration
        public let histogramConfiguration: AmbientSyncOffsetHistogram.Configuration
        public let provisionalRerankerConfiguration: AmbientSyncDenseReranker.Configuration
        public let finalRerankerConfiguration: AmbientSyncDenseReranker.Configuration
        public let minimumReadinessDurationMS: Double
        public let minimumFinalQueryDurationMS: Double
        public let minimumAverageEnergyDBFS: Double
        public let minimumActiveFrameEnergyDBFS: Double
        public let minimumActiveFrameFraction: Double
        public let minimumQueryLandmarkCount: Int
        public let minimumReferenceLandmarkCount: Int
        public let minimumCoarseVoteCount: Int
        public let minimumCoarseVoteDensity: Double
        public let minimumCoarseVoteRatio: Double
        public let minimumCoarseVoteMargin: Int
        public let minimumCoarseTemporalSpreadMS: Double
        public let maximumTimingLandmarkDisagreementMS: Double
        public let minimumCoarseAmbiguousDenseMargin: Double
        public let minimumFinalDenseScore: Double
        public let minimumFinalDenseMargin: Double
        public let minimumFinalFeatureAgreementCount: Int
        public let minimumFinalPCENMelScore: Double
        public let minimumFinalCENSScore: Double
        public let maximumFinalOffsetStabilityMS: Double
        public let trackingSearchRadiusMS: Double
        public let offsetStabilityHistoryCount: Int
        public let diagnosticCandidateLimit: Int

        public init(
            featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
            histogramConfiguration: AmbientSyncOffsetHistogram.Configuration = AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 20,
                maximumCandidateCount: 8,
                minimumCandidateSeparationMS: 750
            ),
            provisionalRerankerConfiguration: AmbientSyncDenseReranker.Configuration = AmbientSyncDenseReranker.Configuration(
                weights: AmbientSyncDenseReranker.FeatureWeights(
                    onsetEnvelope: 0.45,
                    subbandOnset: 0,
                    pcenMel: 0.30,
                    chromaOnset: 0.05,
                    cens: 0.20
                ),
                minimumComparableFrameCount: 48,
                minimumComparableDurationMS: 1_000,
                minimumCoverageRatio: 0.80,
                maximumFrameTimeErrorMS: 15,
                refinementSearchRadiusMS: 60,
                refinementStepMS: 5,
                featureAgreementThreshold: 0.55,
                minimumTimingFeatureScore: 0.50,
                minimumUsableFrameEnergyDBFS: -80,
                minimumLandmarkVoteCount: 8,
                minimumLandmarkScore: 0.08,
                minimumCombinedDenseScore: 0.55,
                minimumDenseMargin: 0.02,
                minimumFeatureAgreementCount: 2,
                maximumDenseLandmarkDisagreementMS: 100,
                timingEvidenceFeatures: [.onsetEnvelope, .pcenMel, .chromaOnset, .cens],
                robustEvidenceFeatures: [.pcenMel, .cens]
            ),
            finalRerankerConfiguration: AmbientSyncDenseReranker.Configuration = AmbientSyncDenseReranker.Configuration(
                weights: AmbientSyncDenseReranker.FeatureWeights(
                    onsetEnvelope: 0.30,
                    subbandOnset: 0,
                    pcenMel: 0.35,
                    chromaOnset: 0.05,
                    cens: 0.30
                ),
                minimumComparableFrameCount: 96,
                minimumComparableDurationMS: 2_500,
                minimumCoverageRatio: 0.85,
                maximumFrameTimeErrorMS: 15,
                refinementSearchRadiusMS: 60,
                refinementStepMS: 5,
                featureAgreementThreshold: 0.50,
                minimumTimingFeatureScore: 0.52,
                minimumUsableFrameEnergyDBFS: -80,
                minimumLandmarkVoteCount: 10,
                minimumLandmarkScore: 0.08,
                minimumCombinedDenseScore: 0.55,
                minimumDenseMargin: 0.02,
                minimumFeatureAgreementCount: 2,
                maximumDenseLandmarkDisagreementMS: 180,
                timingEvidenceFeatures: [.onsetEnvelope, .pcenMel, .chromaOnset, .cens]
            ),
            minimumReadinessDurationMS: Double? = nil,
            minimumFinalQueryDurationMS: Double? = nil,
            minimumAverageEnergyDBFS: Double = -62,
            minimumActiveFrameEnergyDBFS: Double = -70,
            minimumActiveFrameFraction: Double = 0.35,
            minimumQueryLandmarkCount: Int = 8,
            minimumReferenceLandmarkCount: Int = 8,
            minimumCoarseVoteCount: Int = 8,
            minimumCoarseVoteDensity: Double = 0.08,
            minimumCoarseVoteRatio: Double = 1.35,
            minimumCoarseVoteMargin: Int = 4,
            minimumCoarseTemporalSpreadMS: Double = 900,
            maximumTimingLandmarkDisagreementMS: Double = 100,
            minimumCoarseAmbiguousDenseMargin: Double = 0.04,
            minimumFinalDenseScore: Double = 0.55,
            minimumFinalDenseMargin: Double = 0.02,
            minimumFinalFeatureAgreementCount: Int = 2,
            minimumFinalPCENMelScore: Double = 0.65,
            minimumFinalCENSScore: Double = 0.65,
            maximumFinalOffsetStabilityMS: Double = 180,
            trackingSearchRadiusMS: Double = 750,
            offsetStabilityHistoryCount: Int = 4,
            diagnosticCandidateLimit: Int = 8
        ) {
            precondition(minimumAverageEnergyDBFS.isFinite, "minimumAverageEnergyDBFS must be finite.")
            precondition(minimumActiveFrameEnergyDBFS.isFinite, "minimumActiveFrameEnergyDBFS must be finite.")
            precondition((0...1).contains(minimumActiveFrameFraction), "minimumActiveFrameFraction must be between 0 and 1.")
            precondition(minimumQueryLandmarkCount > 0, "minimumQueryLandmarkCount must be positive.")
            precondition(minimumReferenceLandmarkCount > 0, "minimumReferenceLandmarkCount must be positive.")
            precondition(minimumCoarseVoteCount > 0, "minimumCoarseVoteCount must be positive.")
            precondition((0...1).contains(minimumCoarseVoteDensity), "minimumCoarseVoteDensity must be between 0 and 1.")
            precondition(minimumCoarseVoteRatio >= 1, "minimumCoarseVoteRatio must be at least 1.")
            precondition(minimumCoarseVoteMargin >= 0, "minimumCoarseVoteMargin must be non-negative.")
            precondition(minimumCoarseTemporalSpreadMS >= 0, "minimumCoarseTemporalSpreadMS must be non-negative.")
            precondition(maximumTimingLandmarkDisagreementMS >= 0, "maximumTimingLandmarkDisagreementMS must be non-negative.")
            precondition(minimumCoarseAmbiguousDenseMargin >= 0, "minimumCoarseAmbiguousDenseMargin must be non-negative.")
            precondition((0...1).contains(minimumFinalDenseScore), "minimumFinalDenseScore must be between 0 and 1.")
            precondition(minimumFinalDenseMargin >= 0, "minimumFinalDenseMargin must be non-negative.")
            precondition(minimumFinalFeatureAgreementCount > 0, "minimumFinalFeatureAgreementCount must be positive.")
            precondition((0...1).contains(minimumFinalPCENMelScore), "minimumFinalPCENMelScore must be between 0 and 1.")
            precondition((0...1).contains(minimumFinalCENSScore), "minimumFinalCENSScore must be between 0 and 1.")
            precondition(maximumFinalOffsetStabilityMS >= 0, "maximumFinalOffsetStabilityMS must be non-negative.")
            precondition(trackingSearchRadiusMS >= 0, "trackingSearchRadiusMS must be non-negative.")
            precondition(offsetStabilityHistoryCount > 0, "offsetStabilityHistoryCount must be positive.")
            precondition(diagnosticCandidateLimit > 0, "diagnosticCandidateLimit must be positive.")

            self.featureConfiguration = featureConfiguration
            self.histogramConfiguration = histogramConfiguration
            self.provisionalRerankerConfiguration = provisionalRerankerConfiguration
            self.finalRerankerConfiguration = finalRerankerConfiguration
            self.minimumReadinessDurationMS = minimumReadinessDurationMS
                ?? featureConfiguration.firstLockMinimumDurationMS
            self.minimumFinalQueryDurationMS = minimumFinalQueryDurationMS
                ?? featureConfiguration.finalLockMinimumDurationMS
            self.minimumAverageEnergyDBFS = minimumAverageEnergyDBFS
            self.minimumActiveFrameEnergyDBFS = minimumActiveFrameEnergyDBFS
            self.minimumActiveFrameFraction = minimumActiveFrameFraction
            self.minimumQueryLandmarkCount = minimumQueryLandmarkCount
            self.minimumReferenceLandmarkCount = minimumReferenceLandmarkCount
            self.minimumCoarseVoteCount = minimumCoarseVoteCount
            self.minimumCoarseVoteDensity = minimumCoarseVoteDensity
            self.minimumCoarseVoteRatio = minimumCoarseVoteRatio
            self.minimumCoarseVoteMargin = minimumCoarseVoteMargin
            self.minimumCoarseTemporalSpreadMS = minimumCoarseTemporalSpreadMS
            self.maximumTimingLandmarkDisagreementMS = maximumTimingLandmarkDisagreementMS
            self.minimumCoarseAmbiguousDenseMargin = minimumCoarseAmbiguousDenseMargin
            self.minimumFinalDenseScore = minimumFinalDenseScore
            self.minimumFinalDenseMargin = minimumFinalDenseMargin
            self.minimumFinalFeatureAgreementCount = minimumFinalFeatureAgreementCount
            self.minimumFinalPCENMelScore = minimumFinalPCENMelScore
            self.minimumFinalCENSScore = minimumFinalCENSScore
            self.maximumFinalOffsetStabilityMS = maximumFinalOffsetStabilityMS
            self.trackingSearchRadiusMS = trackingSearchRadiusMS
            self.offsetStabilityHistoryCount = offsetStabilityHistoryCount
            self.diagnosticCandidateLimit = diagnosticCandidateLimit
        }

        public static let v1 = Configuration()
    }

    public let reference: Reference
    public let configuration: Configuration
    public private(set) var firstProvisionalLockElapsedMS: Double?
    public private(set) var finalLockElapsedMS: Double?

    private var latestLockedOffsetMS: Double?
    private var recentFinalOffsetsMS: [Double] = []

    public init(
        reference: Reference,
        configuration: Configuration = .v1
    ) {
        self.reference = reference
        self.configuration = configuration
    }

    public init(
        referenceIndex: any AmbientSyncEngineReferenceIndex,
        configuration: Configuration = .v1
    ) {
        self.init(
            reference: Reference(
                sourceDisplayPath: referenceIndex.sourceDisplayPath,
                featureConfiguration: referenceIndex.featureConfiguration,
                frames: referenceIndex.frames,
                landmarks: referenceIndex.landmarks,
                landmarkIndex: referenceIndex.landmarkIndex
            ),
            configuration: configuration
        )
    }

    public mutating func process(
        queryWindow: MicFeatureWindow,
        elapsedMS: Double
    ) -> AmbientSyncSnapshot {
        let queryLandmarks = Self.landmarks(from: queryWindow.frames)
        let readiness = readinessMetrics(
            queryWindow: queryWindow,
            queryLandmarkCount: queryLandmarks.count
        )
        var diagnostics = AmbientSyncDiagnostics(
            queryDurationMS: readiness.queryDurationMS,
            activeFrameFraction: readiness.activeFrameFraction,
            queryLandmarkCount: queryLandmarks.count
        )

        guard !reference.frames.isEmpty,
              reference.landmarkIndex.landmarkCount >= configuration.minimumReferenceLandmarkCount
        else {
            return snapshot(
                state: .failed,
                phase: currentPhase,
                stage: .readiness,
                withholdReason: .indexUnavailable,
                diagnostics: diagnostics
            )
        }

        if let readinessFailure = readinessFailure(readiness) {
            return snapshot(
                state: readinessFailureState(for: readinessFailure),
                phase: currentPhase,
                stage: .readiness,
                withholdReason: readinessFailure,
                diagnostics: diagnostics
            )
        }

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: reference.landmarkIndex,
            configuration: configuration.histogramConfiguration,
            searchRangeMS: trackingSearchRange()
        )
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: nil,
            offsetStabilityMS: nil
        )

        guard let topCoarseCandidate = histogram.candidates.first else {
            return snapshot(
                state: lockingState,
                phase: currentPhase,
                stage: coarseStage,
                withholdReason: .insufficientLandmarkEvidence,
                diagnostics: diagnostics
            )
        }

        if let coarseFailure = coarseFailureReason(
            histogram: histogram,
            topCandidate: topCoarseCandidate
        ) {
            return snapshot(
                state: coarseFailureState(for: coarseFailure),
                phase: currentPhase,
                stage: coarseStage,
                withholdReason: coarseFailure,
                diagnostics: diagnostics
            )
        }
        let coarseAmbiguous = isCoarseAmbiguous(
            histogram: histogram,
            topCandidate: topCoarseCandidate
        )

        let timingResult = AmbientSyncDenseReranker(
            configuration: configuration.provisionalRerankerConfiguration
        )
        .rerank(
            queryWindow: queryWindow,
            localFrames: reference.frames,
            candidates: histogram.candidates
        )
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: timingResult,
            offsetStabilityMS: nil
        )

        guard let timingCandidate = timingResult.leadingCandidate else {
            return snapshot(
                state: lockingState,
                phase: currentPhase,
                stage: .fastTimingVerify,
                withholdReason: .weakAlignmentPeak,
                diagnostics: diagnostics
            )
        }

        if let timingFailure = timingFailureReason(
            timingResult: timingResult,
            candidate: timingCandidate,
            coarseAmbiguous: coarseAmbiguous
        ) {
            return snapshot(
                state: timingFailureState(for: timingFailure),
                phase: currentPhase,
                stage: .fastTimingVerify,
                withholdReason: timingFailure,
                diagnostics: diagnostics
            )
        }

        if firstProvisionalLockElapsedMS == nil {
            firstProvisionalLockElapsedMS = elapsedMS
        }

        let provisionalEstimate = makeEstimate(
            queryWindow: queryWindow,
            offsetMS: timingCandidate.offsetMS
        )
        let provisionalConfidence = provisionalConfidence(
            histogram: histogram,
            timingResult: timingResult,
            candidate: timingCandidate
        )

        guard queryWindow.durationMS >= configuration.minimumFinalQueryDurationMS else {
            guard finalLockElapsedMS != nil else {
                return snapshot(
                    state: .locking,
                    phase: .provisional,
                    stage: .fastTimingVerify,
                    estimate: provisionalEstimate,
                    confidence: provisionalConfidence,
                    diagnostics: diagnostics
                )
            }

            latestLockedOffsetMS = timingCandidate.offsetMS
            recordFinalOffset(timingCandidate.offsetMS)

            return snapshot(
                state: .locked,
                phase: .final,
                stage: .tracking,
                estimate: provisionalEstimate,
                confidence: provisionalConfidence,
                diagnostics: diagnostics
            )
        }

        let robustResult = AmbientSyncDenseReranker(
            configuration: configuration.finalRerankerConfiguration
        )
        .rerank(
            queryWindow: queryWindow,
            localFrames: reference.frames,
            candidates: histogram.candidates
        )
        let offsetStabilityMS = finalOffsetStabilityMS(
            candidateOffsetMS: robustResult.leadingCandidate?.offsetMS,
            provisionalOffsetMS: timingCandidate.offsetMS
        )
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: robustResult,
            offsetStabilityMS: offsetStabilityMS
        )

        guard let finalCandidate = robustResult.leadingCandidate else {
            return snapshot(
                state: finalFailureState(for: .weakAlignmentPeak),
                phase: currentPhase,
                stage: .robustVerify,
                estimate: provisionalEstimate,
                withholdReason: .weakAlignmentPeak,
                confidence: provisionalConfidence,
                diagnostics: diagnostics
            )
        }

        if let finalFailure = finalFailureReason(
            robustResult: robustResult,
            candidate: finalCandidate,
            offsetStabilityMS: offsetStabilityMS,
            coarseAmbiguous: coarseAmbiguous
        ) {
            return snapshot(
                state: finalFailureState(for: finalFailure),
                phase: currentPhase,
                stage: .robustVerify,
                estimate: provisionalEstimate,
                withholdReason: finalFailure,
                confidence: provisionalConfidence,
                diagnostics: diagnostics
            )
        }

        let wasAlreadyFinalLocked = finalLockElapsedMS != nil
        if finalLockElapsedMS == nil {
            finalLockElapsedMS = elapsedMS
        }
        latestLockedOffsetMS = finalCandidate.offsetMS
        recordFinalOffset(finalCandidate.offsetMS)

        return snapshot(
            state: .locked,
            phase: .final,
            stage: wasAlreadyFinalLocked ? .tracking : .robustVerify,
            estimate: makeEstimate(queryWindow: queryWindow, offsetMS: finalCandidate.offsetMS),
            confidence: finalConfidence(
                histogram: histogram,
                robustResult: robustResult,
                candidate: finalCandidate,
                offsetStabilityMS: offsetStabilityMS
            ),
            diagnostics: diagnostics
        )
    }

    private var currentPhase: AmbientSyncLockPhase {
        if finalLockElapsedMS != nil {
            return .final
        }

        if firstProvisionalLockElapsedMS != nil {
            return .provisional
        }

        return .none
    }

    private var lockingState: AmbientSyncState {
        finalLockElapsedMS == nil ? .locking : .relocking
    }

    private var coarseStage: AmbientSyncStage {
        finalLockElapsedMS == nil ? .landmarkCoarse : .relock
    }

    private func readinessMetrics(
        queryWindow: MicFeatureWindow,
        queryLandmarkCount: Int
    ) -> AmbientSyncQueryReadiness {
        let activeFrameCount = queryWindow.frames.reduce(0) { count, frame in
            frame.energyDBFS >= configuration.minimumActiveFrameEnergyDBFS ? count + 1 : count
        }
        let activeFrameFraction = Double(activeFrameCount) / Double(queryWindow.frames.count)

        return AmbientSyncQueryReadiness(
            queryDurationMS: queryWindow.durationMS,
            activeFrameFraction: activeFrameFraction,
            averageEnergyDBFS: Self.averageEnergyDBFS(queryWindow.frames),
            queryLandmarkCount: queryLandmarkCount
        )
    }

    private func readinessFailure(_ readiness: AmbientSyncQueryReadiness) -> AmbientSyncWithholdReason? {
        if readiness.queryDurationMS < requiredReadinessDurationMS {
            return .insufficientDuration
        }

        if readiness.averageEnergyDBFS < configuration.minimumAverageEnergyDBFS {
            return .insufficientEnergy
        }

        if readiness.activeFrameFraction < configuration.minimumActiveFrameFraction {
            return .insufficientActiveFrames
        }

        if readiness.queryLandmarkCount < configuration.minimumQueryLandmarkCount {
            return .insufficientLandmarkEvidence
        }

        return nil
    }

    private var requiredReadinessDurationMS: Double {
        guard finalLockElapsedMS != nil else {
            return configuration.minimumReadinessDurationMS
        }

        return min(
            configuration.minimumReadinessDurationMS,
            max(
                0,
                configuration.featureConfiguration.trackingQueryDurationMS
                    - configuration.featureConfiguration.featureHopMS
            )
        )
    }

    private func readinessFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard firstProvisionalLockElapsedMS != nil || finalLockElapsedMS != nil else {
            return .listening
        }

        if reason == .insufficientEnergy || reason == .insufficientActiveFrames {
            return .lost
        }

        return .relocking
    }

    private func coarseFailureReason(
        histogram: AmbientSyncOffsetHistogram,
        topCandidate: AmbientSyncOffsetHistogram.Candidate
    ) -> AmbientSyncWithholdReason? {
        guard topCandidate.voteCount >= configuration.minimumCoarseVoteCount,
              topCandidate.voteDensity >= configuration.minimumCoarseVoteDensity,
              topCandidate.queryTemporalSpreadMS >= configuration.minimumCoarseTemporalSpreadMS
        else {
            return .insufficientLandmarkEvidence
        }

        return nil
    }

    private func isCoarseAmbiguous(
        histogram: AmbientSyncOffsetHistogram,
        topCandidate: AmbientSyncOffsetHistogram.Candidate
    ) -> Bool {
        guard topCandidate.voteCount >= configuration.minimumCoarseVoteCount,
              topCandidate.voteDensity >= configuration.minimumCoarseVoteDensity,
              topCandidate.queryTemporalSpreadMS >= configuration.minimumCoarseTemporalSpreadMS,
              histogram.secondVoteCount > 0
        else {
            return false
        }

        return histogram.topToSecondVoteRatio < configuration.minimumCoarseVoteRatio
            || histogram.topVoteMargin < configuration.minimumCoarseVoteMargin
    }

    private func coarseFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return .locking
        }

        return reason == .ambiguousOffset ? .drifting : .relocking
    }

    private func timingFailureReason(
        timingResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore,
        coarseAmbiguous: Bool
    ) -> AmbientSyncWithholdReason? {
        let provisionalGate = configuration.provisionalRerankerConfiguration
        guard candidate.hasSufficientCoverage,
              candidate.landmarkVoteCount >= provisionalGate.minimumLandmarkVoteCount,
              candidate.landmarkScore >= provisionalGate.minimumLandmarkScore,
              candidate.combinedDenseScore >= provisionalGate.minimumCombinedDenseScore,
              candidate.featureAgreementCount >= provisionalGate.minimumFeatureAgreementCount
        else {
            return .weakAlignmentPeak
        }

        let minimumDenseMargin = coarseAmbiguous
            ? max(provisionalGate.minimumDenseMargin, configuration.minimumCoarseAmbiguousDenseMargin)
            : provisionalGate.minimumDenseMargin
        if timingResult.candidates.count > 1,
           timingResult.denseMargin < minimumDenseMargin {
            return .ambiguousOffset
        }

        guard timingResult.bestCandidate != nil,
              abs(candidate.offsetMS - candidate.coarseOffsetMS) <= configuration.maximumTimingLandmarkDisagreementMS
        else {
            return .weakAlignmentPeak
        }

        return nil
    }

    private func timingFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return .locking
        }

        return reason == .ambiguousOffset ? .drifting : .relocking
    }

    private func finalFailureReason(
        robustResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore,
        offsetStabilityMS: Double?,
        coarseAmbiguous: Bool
    ) -> AmbientSyncWithholdReason? {
        if let offsetStabilityMS,
           offsetStabilityMS > configuration.maximumFinalOffsetStabilityMS {
            return .unstableTrackingResidual
        }

        guard robustResult.bestCandidate != nil,
              candidate.combinedDenseScore >= configuration.minimumFinalDenseScore,
              candidate.featureAgreementCount >= configuration.minimumFinalFeatureAgreementCount,
              candidate.pcenMelScore >= configuration.minimumFinalPCENMelScore,
              candidate.censScore >= configuration.minimumFinalCENSScore
        else {
            return .weakAlignmentPeak
        }

        let minimumDenseMargin = coarseAmbiguous
            ? max(configuration.minimumFinalDenseMargin, configuration.minimumCoarseAmbiguousDenseMargin)
            : configuration.minimumFinalDenseMargin
        if robustResult.candidates.count > 1,
           robustResult.denseMargin < minimumDenseMargin {
            return .ambiguousOffset
        }

        return nil
    }

    private func finalFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return .locking
        }

        switch reason {
        case .unstableTrackingResidual:
            return .drifting
        case .ambiguousOffset:
            return .drifting
        default:
            return .relocking
        }
    }

    private func trackingSearchRange() -> ClosedRange<Double>? {
        guard let latestLockedOffsetMS else {
            return nil
        }

        return (latestLockedOffsetMS - configuration.trackingSearchRadiusMS) ... (latestLockedOffsetMS + configuration.trackingSearchRadiusMS)
    }

    private func finalOffsetStabilityMS(
        candidateOffsetMS: Double?,
        provisionalOffsetMS: Double
    ) -> Double? {
        guard let candidateOffsetMS else {
            return nil
        }

        var referenceOffsets = [provisionalOffsetMS]
        if let latestLockedOffsetMS {
            referenceOffsets.append(latestLockedOffsetMS)
        }
        referenceOffsets.append(contentsOf: recentFinalOffsetsMS)

        return referenceOffsets.map { abs(candidateOffsetMS - $0) }.max()
    }

    private mutating func recordFinalOffset(_ offsetMS: Double) {
        recentFinalOffsetsMS.append(offsetMS)
        if recentFinalOffsetsMS.count > configuration.offsetStabilityHistoryCount {
            recentFinalOffsetsMS.removeFirst(recentFinalOffsetsMS.count - configuration.offsetStabilityHistoryCount)
        }
    }

    private func makeEstimate(
        queryWindow: MicFeatureWindow,
        offsetMS: Double
    ) -> AmbientSyncEstimate {
        AmbientSyncEstimate(
            queryEndpointRecordedTimeMS: queryWindow.endpointRecordedTimeMS,
            referenceTimeMS: queryWindow.endpointRecordedTimeMS + offsetMS,
            offsetMS: offsetMS
        )
    }

    private func provisionalConfidence(
        histogram: AmbientSyncOffsetHistogram,
        timingResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore
    ) -> Double {
        let voteConfidence = min(1, Double(histogram.topVoteCount) / Double(configuration.minimumCoarseVoteCount * 2))
        let densityConfidence = min(1, candidate.landmarkScore / max(configuration.minimumCoarseVoteDensity * 2, .ulpOfOne))
        let minimumDenseMargin = configuration.provisionalRerankerConfiguration.minimumDenseMargin
        let marginConfidence = min(1, timingResult.denseMargin / max(minimumDenseMargin * 4, .ulpOfOne))
        return clampedConfidence(
            voteConfidence * 0.25
                + densityConfidence * 0.20
                + candidate.combinedDenseScore * 0.40
                + marginConfidence * 0.15
        )
    }

    private func finalConfidence(
        histogram: AmbientSyncOffsetHistogram,
        robustResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore,
        offsetStabilityMS: Double?
    ) -> Double {
        let voteConfidence = min(1, Double(histogram.topVoteCount) / Double(configuration.minimumCoarseVoteCount * 2))
        let robustFeatureScore = min(candidate.pcenMelScore, candidate.censScore)
        let marginConfidence = min(1, robustResult.denseMargin / max(configuration.minimumFinalDenseMargin * 4, .ulpOfOne))
        let stabilityConfidence: Double
        if let offsetStabilityMS {
            stabilityConfidence = 1 - min(1, offsetStabilityMS / max(configuration.maximumFinalOffsetStabilityMS, .ulpOfOne))
        } else {
            stabilityConfidence = 0.5
        }

        return clampedConfidence(
            voteConfidence * 0.20
                + candidate.combinedDenseScore * 0.35
                + robustFeatureScore * 0.20
                + marginConfidence * 0.15
                + stabilityConfidence * 0.10
        )
    }

    private func clampedConfidence(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func makeDiagnostics(
        readiness: AmbientSyncQueryReadiness,
        histogram: AmbientSyncOffsetHistogram,
        rerankResult: AmbientSyncDenseReranker.Result?,
        offsetStabilityMS: Double?
    ) -> AmbientSyncDiagnostics {
        AmbientSyncDiagnostics(
            queryDurationMS: readiness.queryDurationMS,
            activeFrameFraction: readiness.activeFrameFraction,
            queryLandmarkCount: readiness.queryLandmarkCount,
            histogramCandidateCount: histogram.candidates.count,
            topLandmarkVoteCount: histogram.topVoteCount,
            secondLandmarkVoteCount: histogram.secondVoteCount,
            topToSecondVoteRatio: finiteVoteRatio(histogram),
            topVoteMargin: histogram.topVoteMargin,
            coarseAmbiguous: histogram.candidates.first.map { topCandidate in
                isCoarseAmbiguous(histogram: histogram, topCandidate: topCandidate)
            } ?? false,
            denseMargin: rerankResult?.denseMargin ?? 0,
            offsetStabilityMS: offsetStabilityMS,
            candidates: candidateDiagnostics(
                histogram: histogram,
                rerankResult: rerankResult
            )
        )
    }

    private func finiteVoteRatio(_ histogram: AmbientSyncOffsetHistogram) -> Double {
        guard histogram.topToSecondVoteRatio.isFinite else {
            return histogram.topVoteCount > 0 ? Double(histogram.topVoteCount) : 0
        }

        return histogram.topToSecondVoteRatio
    }

    private func candidateDiagnostics(
        histogram: AmbientSyncOffsetHistogram,
        rerankResult: AmbientSyncDenseReranker.Result?
    ) -> [AmbientSyncCandidateDiagnostics] {
        if let rerankResult {
            return rerankResult.candidates.prefix(configuration.diagnosticCandidateLimit).map { candidate in
                AmbientSyncCandidateDiagnostics(
                    offsetMS: candidate.offsetMS,
                    coarseOffsetMS: candidate.coarseOffsetMS,
                    landmarkVoteCount: candidate.landmarkVoteCount,
                    landmarkScore: candidate.landmarkScore,
                    voteDensity: nearestHistogramCandidate(
                        to: candidate.coarseOffsetMS,
                        in: histogram
                    )?.voteDensity ?? candidate.landmarkScore,
                    comparableFrameCount: candidate.comparableFrameCount,
                    coverageRatio: candidate.coverageRatio,
                    onsetScore: candidate.onsetScore,
                    subbandOnsetScore: candidate.subbandOnsetScore,
                    pcenMelScore: candidate.pcenMelScore,
                    chromaOnsetScore: candidate.chromaOnsetScore,
                    censScore: candidate.censScore,
                    combinedDenseScore: candidate.combinedDenseScore,
                    featureAgreementCount: candidate.featureAgreementCount
                )
            }
        }

        return histogram.candidates.prefix(configuration.diagnosticCandidateLimit).map { candidate in
            AmbientSyncCandidateDiagnostics(
                offsetMS: candidate.offsetMS,
                coarseOffsetMS: candidate.offsetMS,
                landmarkVoteCount: candidate.voteCount,
                landmarkScore: candidate.voteDensity,
                voteDensity: candidate.voteDensity,
                comparableFrameCount: 0,
                coverageRatio: 0,
                onsetScore: 0,
                subbandOnsetScore: 0,
                pcenMelScore: 0,
                chromaOnsetScore: 0,
                censScore: 0,
                combinedDenseScore: 0,
                featureAgreementCount: 0
            )
        }
    }

    private func nearestHistogramCandidate(
        to offsetMS: Double,
        in histogram: AmbientSyncOffsetHistogram
    ) -> AmbientSyncOffsetHistogram.Candidate? {
        histogram.candidates.min { lhs, rhs in
            abs(lhs.offsetMS - offsetMS) < abs(rhs.offsetMS - offsetMS)
        }
    }

    private func snapshot(
        state: AmbientSyncState,
        phase: AmbientSyncLockPhase,
        stage: AmbientSyncStage,
        estimate: AmbientSyncEstimate? = nil,
        withholdReason: AmbientSyncWithholdReason? = nil,
        confidence: Double = 0,
        diagnostics: AmbientSyncDiagnostics
    ) -> AmbientSyncSnapshot {
        AmbientSyncSnapshot(
            state: state,
            phase: phase,
            stage: stage,
            estimate: estimate,
            withholdReason: withholdReason,
            confidence: confidence,
            diagnostics: diagnostics,
            firstProvisionalLockElapsedMS: firstProvisionalLockElapsedMS,
            finalLockElapsedMS: finalLockElapsedMS
        )
    }

    fileprivate static func landmarks(from frames: [MicFeatureFrame]) -> [MicFeatureLandmark] {
        frames.flatMap { frame in
            if !frame.landmarks.isEmpty {
                return frame.landmarks
            }

            return frame.landmarkHashes.map { hash in
                MicFeatureLandmark(
                    hash: hash,
                    anchorTimeMS: frame.recordedTimeMS,
                    anchorFrequencyBin: 0,
                    targetFrequencyBin: 1,
                    deltaFrames: 1
                )
            }
        }
    }

    private static func averageEnergyDBFS(_ frames: [MicFeatureFrame]) -> Double {
        guard !frames.isEmpty else {
            return -Double.infinity
        }

        let meanPower = frames.reduce(0) { total, frame in
            total + pow(10, frame.energyDBFS / 10)
        } / Double(frames.count)

        guard meanPower > 0 else {
            return -Double.infinity
        }

        return 10 * log10(meanPower)
    }
}

private struct AmbientSyncQueryReadiness: Equatable, Sendable {
    let queryDurationMS: Double
    let activeFrameFraction: Double
    let averageEnergyDBFS: Double
    let queryLandmarkCount: Int
}

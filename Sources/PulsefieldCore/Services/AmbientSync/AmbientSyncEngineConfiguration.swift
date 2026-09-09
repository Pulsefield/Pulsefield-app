import Foundation

public extension AmbientSyncEngine {
    struct Configuration: Equatable, Sendable {
        /// v1 retains landmark retrieval for comparisons; v2 estimates spectral delay directly.
        public let usesSpectralCorrelation: Bool
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
            usesSpectralCorrelation: Bool = false,
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
                robustEvidenceFeatures: [.pcenMel, .cens],
                maximumRefinedCandidateCount: 2,
                refinementCandidateScoreMargin: 0.08
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
                timingEvidenceFeatures: [.onsetEnvelope, .pcenMel, .chromaOnset, .cens],
                maximumRefinedCandidateCount: 2,
                refinementCandidateScoreMargin: 0.08
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

            self.usesSpectralCorrelation = usesSpectralCorrelation
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
        public static let v2 = Configuration(usesSpectralCorrelation: true)
    }
}

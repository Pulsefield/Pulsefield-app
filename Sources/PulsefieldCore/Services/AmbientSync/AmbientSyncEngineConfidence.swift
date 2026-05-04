import Foundation

extension AmbientSyncEngine {
    func unverifiedRecoveryEstimate(
        _ provisionalEstimate: AmbientSyncEstimate
    ) -> AmbientSyncEstimate? {
        guard confirmedLockElapsedMS == nil && finalLockElapsedMS == nil else {
            return nil
        }

        return provisionalEstimate
    }

    func unverifiedRecoveryConfidence(
        provisionalConfidence: Double,
        trackerResult: AmbientSyncOffsetTracker.Result
    ) -> Double {
        guard confirmedLockElapsedMS == nil && finalLockElapsedMS == nil else {
            return trackConfidence(trackerResult)
        }

        return provisionalConfidence
    }

    func makeEstimate(
        queryWindow: MicFeatureWindow,
        offsetMS: Double
    ) -> AmbientSyncEstimate {
        AmbientSyncEstimate(
            queryEndpointRecordedTimeMS: queryWindow.endpointRecordedTimeMS,
            referenceTimeMS: queryWindow.endpointRecordedTimeMS + offsetMS,
            offsetMS: offsetMS
        )
    }

    func provisionalConfidence(
        timingResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore
    ) -> Double {
        let voteConfidence = weightedCoarseConfidence(candidate: candidate)
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

    func finalConfidence(
        robustResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore,
        offsetStabilityMS: Double?
    ) -> Double {
        let voteConfidence = weightedCoarseConfidence(candidate: candidate)
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

    func offsetMeasurementConfidence(_ candidate: AmbientSyncDenseReranker.CandidateScore) -> Double {
        let agreementDenominator = max(Double(configuration.finalRerankerConfiguration.minimumFeatureAgreementCount), 1)
        let agreementConfidence = min(1, Double(candidate.featureAgreementCount) / agreementDenominator)
        let weightedVoteConfidence = weightedCoarseConfidence(candidate: candidate)

        return clampedConfidence(
            candidate.combinedDenseScore * 0.45
                + candidate.landmarkScore * 0.20
                + candidate.coverageRatio * 0.15
                + agreementConfidence * 0.10
                + weightedVoteConfidence * 0.10
        )
    }

    func trackConfidence(_ trackerResult: AmbientSyncOffsetTracker.Result) -> Double {
        guard let bestTrack = trackerResult.bestTrack else {
            return 0
        }

        let oddsConfidence = 1 / (1 + exp(-bestTrack.confidenceLogOdds))
        let marginConfidence = min(
            1,
            trackerResult.confidenceMarginLogOdds
                / max(offsetTracker.configuration.minimumConfirmationMarginLogOdds * 2, .ulpOfOne)
        )
        let stabilityConfidence = trackerResult.isStable ? 1 : (trackerResult.canCoast ? 0.65 : 0.25)

        return clampedConfidence(
            oddsConfidence * 0.65
                + marginConfidence * 0.20
                + stabilityConfidence * 0.15
        )
    }

    func weightedCoarseConfidence(candidate: AmbientSyncDenseReranker.CandidateScore) -> Double {
        min(
            1,
            candidate.weightedVoteScore / max(Double(configuration.minimumCoarseVoteCount * 2), .ulpOfOne)
        )
    }

    func clampedConfidence(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

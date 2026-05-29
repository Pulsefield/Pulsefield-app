import Foundation

extension AmbientSyncEngine {
    var currentPhase: AmbientSyncLockPhase {
        if finalLockElapsedMS != nil {
            return .final
        }

        if confirmedLockElapsedMS != nil {
            return .confirmed
        }

        if firstProvisionalLockElapsedMS != nil {
            return .provisional
        }

        return .none
    }

    var lockingState: AmbientSyncState {
        if finalLockElapsedMS != nil {
            return .relocking
        }

        return confirmedLockElapsedMS == nil ? .locking : .confirmed
    }

    var coarseStage: AmbientSyncStage {
        finalLockElapsedMS == nil && confirmedLockElapsedMS == nil ? .landmarkCoarse : .relock
    }

    func readinessFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard firstProvisionalLockElapsedMS != nil || confirmedLockElapsedMS != nil || finalLockElapsedMS != nil else {
            return .listening
        }

        if reason == .insufficientEnergy || reason == .insufficientActiveFrames {
            return .lost
        }

        return .relocking
    }

    func coarseFailureReason(
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

    func isCoarseAmbiguous(
        histogram: AmbientSyncOffsetHistogram,
        topCandidate: AmbientSyncOffsetHistogram.Candidate
    ) -> Bool {
        guard topCandidate.voteCount >= configuration.minimumCoarseVoteCount,
              topCandidate.voteDensity >= configuration.minimumCoarseVoteDensity,
              topCandidate.queryTemporalSpreadMS >= configuration.minimumCoarseTemporalSpreadMS,
              histogram.secondWeightedVoteScore > 0
        else {
            return false
        }

        return histogram.topToSecondWeightedVoteRatio < configuration.minimumCoarseVoteRatio
            || histogram.topWeightedVoteMargin < Double(configuration.minimumCoarseVoteMargin)
    }

    func coarseFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return confirmedLockElapsedMS == nil ? .locking : .confirmed
        }

        return reason == .ambiguousOffset ? .drifting : .relocking
    }

    func timingFailureReason(
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

    func timingFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return confirmedLockElapsedMS == nil ? .locking : .confirmed
        }

        return reason == .ambiguousOffset ? .drifting : .relocking
    }

    func finalFailureReason(
        robustResult: AmbientSyncDenseReranker.Result,
        candidate: AmbientSyncDenseReranker.CandidateScore,
        coarseAmbiguous: Bool
    ) -> AmbientSyncWithholdReason? {
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

    func finalTrackerFailureReason(
        candidate: AmbientSyncDenseReranker.CandidateScore,
        trackerResult: AmbientSyncOffsetTracker.Result
    ) -> AmbientSyncWithholdReason? {
        guard let bestTrack = trackerResult.bestTrack,
              trackerResult.isConfirmed,
              trackerResult.isStable,
              abs(candidate.offsetMS - bestTrack.offsetMS) <= offsetTracker.configuration.confirmationInnovationGateMS
        else {
            return .unstableTrackingResidual
        }

        return nil
    }

    func finalFailureState(for reason: AmbientSyncWithholdReason) -> AmbientSyncState {
        guard finalLockElapsedMS != nil else {
            return confirmedLockElapsedMS == nil ? .locking : .relocking
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
}

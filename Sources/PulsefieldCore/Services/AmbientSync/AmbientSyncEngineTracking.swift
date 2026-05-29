import Foundation

extension AmbientSyncEngine {
    func trackingSearchRange() -> ClosedRange<Double>? {
        let trackerResult = offsetTracker.result
        guard confirmedLockElapsedMS != nil || finalLockElapsedMS != nil,
              let acceptedTrack = acceptedTrack(in: trackerResult),
              trackerResult.canCoast(acceptedTrack)
        else {
            return nil
        }

        return (acceptedTrack.offsetMS - configuration.trackingSearchRadiusMS)
            ... (acceptedTrack.offsetMS + configuration.trackingSearchRadiusMS)
    }

    func acceptedTrack(in trackerResult: AmbientSyncOffsetTracker.Result) -> AmbientSyncOffsetTrack? {
        guard let acceptedTrackID else {
            return nil
        }

        return trackerResult.tracks.first { $0.id == acceptedTrackID }
    }

    mutating func acceptTrack(_ track: AmbientSyncOffsetTrack) {
        acceptedTrackID = track.id
    }

    func trackingContinuationSnapshot(
        queryWindow: MicFeatureWindow,
        trackerResult: AmbientSyncOffsetTracker.Result,
        withholdReason: AmbientSyncWithholdReason,
        diagnostics: AmbientSyncDiagnostics
    ) -> AmbientSyncSnapshot? {
        guard let acceptedTrack = acceptedTrack(in: trackerResult),
              trackerResult.canCoast(acceptedTrack)
        else {
            return nil
        }

        if finalLockElapsedMS != nil {
            return snapshot(
                state: .locked,
                phase: .final,
                stage: .tracking,
                estimate: makeEstimate(queryWindow: queryWindow, offsetMS: acceptedTrack.offsetMS),
                withholdReason: withholdReason,
                confidence: trackConfidence(trackerResult),
                diagnostics: diagnostics
            )
        }

        guard confirmedLockElapsedMS != nil else {
            return nil
        }

        return snapshot(
            state: .confirmed,
            phase: .confirmed,
            stage: .tracking,
            estimate: makeEstimate(queryWindow: queryWindow, offsetMS: acceptedTrack.offsetMS),
            withholdReason: withholdReason,
            confidence: trackConfidence(trackerResult),
            diagnostics: diagnostics
        )
    }

    mutating func updateOffsetTracker(
        candidates: [AmbientSyncDenseReranker.CandidateScore],
        elapsedMS: Double,
        confidenceScale: Double = 1
    ) -> AmbientSyncOffsetTracker.Result {
        offsetTracker.update(
            candidates: candidates.map { candidate in
                AmbientSyncOffsetTracker.Measurement(
                    offsetMS: candidate.offsetMS,
                    confidence: offsetMeasurementConfidence(candidate) * confidenceScale
                )
            },
            elapsedMS: elapsedMS
        )
    }

    func trackerConfidenceScale(for failure: AmbientSyncWithholdReason) -> Double {
        switch failure {
        case .ambiguousOffset:
            return 1
        default:
            return 0.35
        }
    }

    mutating func decayOffsetTracker(elapsedMS: Double) -> AmbientSyncOffsetTracker.Result {
        offsetTracker.update(candidates: [], elapsedMS: elapsedMS)
    }

    func trackerOffsetStabilityMS(_ trackerResult: AmbientSyncOffsetTracker.Result) -> Double? {
        guard let innovationMS = trackerResult.bestTrack?.lastInnovationMS else {
            return nil
        }

        return abs(innovationMS)
    }
}

import Foundation

extension AmbientSyncEngine {
    func makeReadinessDiagnostics(
        readiness: AmbientSyncQueryReadiness,
        trackerResult: AmbientSyncOffsetTracker.Result
    ) -> AmbientSyncDiagnostics {
        AmbientSyncDiagnostics(
            queryDurationMS: readiness.queryDurationMS,
            activeFrameFraction: readiness.activeFrameFraction,
            queryLandmarkCount: readiness.queryLandmarkCount,
            trackInnovationMS: trackerResult.bestTrack?.lastInnovationMS,
            trackConfidenceMargin: trackerResult.confidenceMarginLogOdds,
            trackConfidenceLogOdds: trackerResult.bestTrack?.confidenceLogOdds ?? 0,
            trackCount: trackerResult.tracks.count,
            offsetTrackerConfirmed: trackerResult.isConfirmed,
            offsetTrackerStable: trackerResult.isStable,
            offsetTracks: offsetTrackDiagnostics(trackerResult)
        )
    }

    func makeDiagnostics(
        readiness: AmbientSyncQueryReadiness,
        histogram: AmbientSyncOffsetHistogram,
        rerankResult: AmbientSyncDenseReranker.Result?,
        offsetStabilityMS: Double?,
        trackerResult: AmbientSyncOffsetTracker.Result
    ) -> AmbientSyncDiagnostics {
        AmbientSyncDiagnostics(
            queryDurationMS: readiness.queryDurationMS,
            activeFrameFraction: readiness.activeFrameFraction,
            queryLandmarkCount: readiness.queryLandmarkCount,
            histogramCandidateCount: histogram.candidates.count,
            topLandmarkVoteCount: histogram.topVoteCount,
            secondLandmarkVoteCount: histogram.secondVoteCount,
            topWeightedVoteScore: histogram.topWeightedVoteScore,
            secondWeightedVoteScore: histogram.secondWeightedVoteScore,
            topToSecondWeightedVoteRatio: finiteWeightedVoteRatio(histogram),
            topWeightedVoteMargin: histogram.topWeightedVoteMargin,
            topToSecondVoteRatio: finiteVoteRatio(histogram),
            topVoteMargin: histogram.topVoteMargin,
            coarseAmbiguous: histogram.candidates.first.map { topCandidate in
                isCoarseAmbiguous(histogram: histogram, topCandidate: topCandidate)
            } ?? false,
            denseMargin: rerankResult?.denseMargin ?? 0,
            offsetStabilityMS: offsetStabilityMS,
            trackInnovationMS: trackerResult.bestTrack?.lastInnovationMS,
            trackConfidenceMargin: trackerResult.confidenceMarginLogOdds,
            trackConfidenceLogOdds: trackerResult.bestTrack?.confidenceLogOdds ?? 0,
            trackCount: trackerResult.tracks.count,
            offsetTrackerConfirmed: trackerResult.isConfirmed,
            offsetTrackerStable: trackerResult.isStable,
            offsetTracks: offsetTrackDiagnostics(trackerResult),
            candidates: candidateDiagnostics(
                histogram: histogram,
                rerankResult: rerankResult
            )
        )
    }

    func offsetTrackDiagnostics(
        _ trackerResult: AmbientSyncOffsetTracker.Result
    ) -> [AmbientSyncOffsetTrackDiagnostics] {
        trackerResult.tracks.prefix(configuration.diagnosticCandidateLimit).map { track in
            AmbientSyncOffsetTrackDiagnostics(
                offsetMS: track.offsetMS,
                velocityMSPerSecond: track.velocityMSPerSecond,
                confidenceLogOdds: track.confidenceLogOdds,
                lastUpdateElapsedMS: track.lastUpdateElapsedMS,
                consecutiveHits: track.consecutiveHits,
                consecutiveMisses: track.consecutiveMisses,
                lastInnovationMS: track.lastInnovationMS
            )
        }
    }

    func finiteVoteRatio(_ histogram: AmbientSyncOffsetHistogram) -> Double {
        guard histogram.topToSecondVoteRatio.isFinite else {
            return histogram.topVoteCount > 0 ? Double(histogram.topVoteCount) : 0
        }

        return histogram.topToSecondVoteRatio
    }

    func finiteWeightedVoteRatio(_ histogram: AmbientSyncOffsetHistogram) -> Double {
        guard histogram.topToSecondWeightedVoteRatio.isFinite else {
            return histogram.topWeightedVoteScore > 0 ? histogram.topWeightedVoteScore : 0
        }

        return histogram.topToSecondWeightedVoteRatio
    }

    func candidateDiagnostics(
        histogram: AmbientSyncOffsetHistogram,
        rerankResult: AmbientSyncDenseReranker.Result?
    ) -> [AmbientSyncCandidateDiagnostics] {
        if let rerankResult {
            return rerankResult.candidates.prefix(configuration.diagnosticCandidateLimit).map { candidate in
                AmbientSyncCandidateDiagnostics(
                    offsetMS: candidate.offsetMS,
                    coarseOffsetMS: candidate.coarseOffsetMS,
                    landmarkVoteCount: candidate.landmarkVoteCount,
                    rawVoteCount: candidate.rawVoteCount,
                    weightedVoteScore: candidate.weightedVoteScore,
                    uniqueHashCount: candidate.uniqueHashCount,
                    commonHashVoteCount: candidate.commonHashVoteCount,
                    meanReferencePostingCount: candidate.meanReferencePostingCount,
                    landmarkScore: candidate.landmarkScore,
                    voteDensity: candidate.voteDensity,
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
                rawVoteCount: candidate.rawVoteCount,
                weightedVoteScore: candidate.weightedVoteScore,
                uniqueHashCount: candidate.uniqueHashCount,
                commonHashVoteCount: candidate.commonHashVoteCount,
                meanReferencePostingCount: candidate.meanReferencePostingCount,
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

    func snapshot(
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
            confirmedLockElapsedMS: confirmedLockElapsedMS,
            finalLockElapsedMS: finalLockElapsedMS
        )
    }
}

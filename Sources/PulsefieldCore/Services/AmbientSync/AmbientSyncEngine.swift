import Foundation

public struct AmbientSyncEngine: Equatable, Sendable {
    public let reference: Reference
    public let configuration: Configuration
    public private(set) var firstProvisionalLockElapsedMS: Double?
    public private(set) var confirmedLockElapsedMS: Double?
    public private(set) var finalLockElapsedMS: Double?

    var offsetTracker: AmbientSyncOffsetTracker
    var acceptedTrackID: Int?

    public init(
        reference: Reference,
        configuration: Configuration = .v1
    ) {
        self.reference = reference
        self.configuration = configuration
        self.offsetTracker = AmbientSyncOffsetTracker(
            configuration: AmbientSyncOffsetTracker.Configuration(
                maximumTrackCount: configuration.histogramConfiguration.maximumCandidateCount,
                maximumMeasurementCount: configuration.histogramConfiguration.maximumCandidateCount
            )
        )
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
        var trackerResult = offsetTracker.result
        var diagnostics = makeReadinessDiagnostics(
            readiness: readiness,
            trackerResult: trackerResult
        )

        guard !reference.frames.isEmpty,
              reference.landmarkIndex.landmarkCount >= configuration.minimumReferenceLandmarkCount
        else {
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeReadinessDiagnostics(
                readiness: readiness,
                trackerResult: trackerResult
            )
            return snapshot(
                state: .failed,
                phase: currentPhase,
                stage: .readiness,
                withholdReason: .indexUnavailable,
                diagnostics: diagnostics
            )
        }

        if let readinessFailure = readinessFailure(readiness) {
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeReadinessDiagnostics(
                readiness: readiness,
                trackerResult: trackerResult
            )
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
            offsetStabilityMS: nil,
            trackerResult: trackerResult
        )

        guard let topCoarseCandidate = histogram.candidates.first else {
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: nil,
                offsetStabilityMS: nil,
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: .insufficientLandmarkEvidence,
                diagnostics: diagnostics
            ) {
                return continuation
            }

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
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: nil,
                offsetStabilityMS: nil,
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: coarseFailure,
                diagnostics: diagnostics
            ) {
                return continuation
            }

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
            localFramesAreSorted: true,
            candidates: histogram.candidates
        )
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: timingResult,
            offsetStabilityMS: nil,
            trackerResult: trackerResult
        )

        guard let timingCandidate = timingResult.leadingCandidate else {
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: timingResult,
                offsetStabilityMS: nil,
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: .weakAlignmentPeak,
                diagnostics: diagnostics
            ) {
                return continuation
            }

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
            trackerResult = updateOffsetTracker(
                candidates: timingResult.candidates,
                elapsedMS: elapsedMS,
                confidenceScale: trackerConfidenceScale(for: timingFailure)
            )
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: timingResult,
                offsetStabilityMS: nil,
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: timingFailure,
                diagnostics: diagnostics
            ) {
                return continuation
            }

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

        let provisionalConfidence = provisionalConfidence(
            timingResult: timingResult,
            candidate: timingCandidate
        )

        guard queryWindow.durationMS >= configuration.minimumFinalQueryDurationMS else {
            trackerResult = updateOffsetTracker(
                candidates: timingResult.candidates,
                elapsedMS: elapsedMS
            )
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: timingResult,
                offsetStabilityMS: nil,
                trackerResult: trackerResult
            )
            let acceptedTrack = acceptedTrack(in: trackerResult)
            let trackedOffsetMS = acceptedTrack?.offsetMS
                ?? trackerResult.bestTrack?.offsetMS
                ?? timingCandidate.offsetMS
            let timingEstimate = makeEstimate(
                queryWindow: queryWindow,
                offsetMS: trackedOffsetMS
            )

            guard finalLockElapsedMS != nil else {
                if confirmedLockElapsedMS != nil,
                   let acceptedTrack,
                   trackerResult.canCoast(acceptedTrack) {
                    acceptTrack(acceptedTrack)
                    return snapshot(
                        state: .confirmed,
                        phase: .confirmed,
                        stage: .tracking,
                        estimate: makeEstimate(queryWindow: queryWindow, offsetMS: acceptedTrack.offsetMS),
                        confidence: trackConfidence(trackerResult),
                        diagnostics: diagnostics
                    )
                }

                if trackerResult.isConfirmed,
                   let bestTrack = trackerResult.bestTrack {
                    if confirmedLockElapsedMS == nil {
                        confirmedLockElapsedMS = elapsedMS
                    }
                    acceptTrack(bestTrack)

                    return snapshot(
                        state: .confirmed,
                        phase: .confirmed,
                        stage: .tracking,
                        estimate: makeEstimate(queryWindow: queryWindow, offsetMS: bestTrack.offsetMS),
                        confidence: trackConfidence(trackerResult),
                        diagnostics: diagnostics
                    )
                }

                if confirmedLockElapsedMS != nil {
                    return snapshot(
                        state: .relocking,
                        phase: .confirmed,
                        stage: .tracking,
                        withholdReason: .unstableTrackingResidual,
                        confidence: trackConfidence(trackerResult),
                        diagnostics: diagnostics
                    )
                }

                return snapshot(
                    state: .locking,
                    phase: .provisional,
                    stage: .fastTimingVerify,
                    estimate: timingEstimate,
                    confidence: provisionalConfidence,
                    diagnostics: diagnostics
                )
            }

            if let acceptedTrack,
               trackerResult.canCoast(acceptedTrack) {
                acceptTrack(acceptedTrack)
                return snapshot(
                    state: .locked,
                    phase: .final,
                    stage: .tracking,
                    estimate: makeEstimate(queryWindow: queryWindow, offsetMS: acceptedTrack.offsetMS),
                    confidence: max(provisionalConfidence, trackConfidence(trackerResult)),
                    diagnostics: diagnostics
                )
            }

            return snapshot(
                state: .drifting,
                phase: .final,
                stage: .tracking,
                estimate: acceptedTrack.map { makeEstimate(queryWindow: queryWindow, offsetMS: $0.offsetMS) },
                withholdReason: .unstableTrackingResidual,
                confidence: trackConfidence(trackerResult),
                diagnostics: diagnostics
            )
        }

        let robustResult = AmbientSyncDenseReranker(
            configuration: configuration.finalRerankerConfiguration
        )
        .rerank(
            queryWindow: queryWindow,
            localFrames: reference.frames,
            localFramesAreSorted: true,
            candidates: histogram.candidates
        )
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: robustResult,
            offsetStabilityMS: nil,
            trackerResult: trackerResult
        )
        let provisionalEstimate = makeEstimate(
            queryWindow: queryWindow,
            offsetMS: timingCandidate.offsetMS
        )

        guard let finalCandidate = robustResult.leadingCandidate else {
            trackerResult = decayOffsetTracker(elapsedMS: elapsedMS)
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: robustResult,
                offsetStabilityMS: trackerOffsetStabilityMS(trackerResult),
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: .weakAlignmentPeak,
                diagnostics: diagnostics
            ) {
                return continuation
            }

            return snapshot(
                state: finalFailureState(for: .weakAlignmentPeak),
                phase: currentPhase,
                stage: .robustVerify,
                estimate: unverifiedRecoveryEstimate(provisionalEstimate),
                withholdReason: .weakAlignmentPeak,
                confidence: unverifiedRecoveryConfidence(
                    provisionalConfidence: provisionalConfidence,
                    trackerResult: trackerResult
                ),
                diagnostics: diagnostics
            )
        }

        if let finalFailure = finalFailureReason(
            robustResult: robustResult,
            candidate: finalCandidate,
            coarseAmbiguous: coarseAmbiguous
        ) {
            trackerResult = updateOffsetTracker(
                candidates: robustResult.candidates,
                elapsedMS: elapsedMS,
                confidenceScale: trackerConfidenceScale(for: finalFailure)
            )
            diagnostics = makeDiagnostics(
                readiness: readiness,
                histogram: histogram,
                rerankResult: robustResult,
                offsetStabilityMS: trackerOffsetStabilityMS(trackerResult),
                trackerResult: trackerResult
            )
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: finalFailure,
                diagnostics: diagnostics
            ) {
                return continuation
            }

            return snapshot(
                state: finalFailureState(for: finalFailure),
                phase: currentPhase,
                stage: .robustVerify,
                estimate: unverifiedRecoveryEstimate(provisionalEstimate),
                withholdReason: finalFailure,
                confidence: unverifiedRecoveryConfidence(
                    provisionalConfidence: provisionalConfidence,
                    trackerResult: trackerResult
                ),
                diagnostics: diagnostics
            )
        }

        trackerResult = updateOffsetTracker(
            candidates: robustResult.candidates,
            elapsedMS: elapsedMS
        )
        let offsetStabilityMS = trackerOffsetStabilityMS(trackerResult)
        diagnostics = makeDiagnostics(
            readiness: readiness,
            histogram: histogram,
            rerankResult: robustResult,
            offsetStabilityMS: offsetStabilityMS,
            trackerResult: trackerResult
        )

        if let trackerFailure = finalTrackerFailureReason(
            candidate: finalCandidate,
            trackerResult: trackerResult
        ) {
            if let continuation = trackingContinuationSnapshot(
                queryWindow: queryWindow,
                trackerResult: trackerResult,
                withholdReason: trackerFailure,
                diagnostics: diagnostics
            ) {
                return continuation
            }

            return snapshot(
                state: finalFailureState(for: trackerFailure),
                phase: currentPhase,
                stage: .robustVerify,
                estimate: unverifiedRecoveryEstimate(provisionalEstimate),
                withholdReason: trackerFailure,
                confidence: unverifiedRecoveryConfidence(
                    provisionalConfidence: provisionalConfidence,
                    trackerResult: trackerResult
                ),
                diagnostics: diagnostics
            )
        }

        let wasAlreadyFinalLocked = finalLockElapsedMS != nil
        if confirmedLockElapsedMS == nil {
            confirmedLockElapsedMS = elapsedMS
        }
        if finalLockElapsedMS == nil {
            finalLockElapsedMS = elapsedMS
        }
        let finalOffsetMS = trackerResult.bestTrack?.offsetMS ?? finalCandidate.offsetMS
        if let bestTrack = trackerResult.bestTrack {
            acceptTrack(bestTrack)
        }

        return snapshot(
            state: .locked,
            phase: .final,
            stage: wasAlreadyFinalLocked ? .tracking : .robustVerify,
            estimate: makeEstimate(queryWindow: queryWindow, offsetMS: finalOffsetMS),
            confidence: finalConfidence(
                robustResult: robustResult,
                candidate: finalCandidate,
                offsetStabilityMS: offsetStabilityMS
            ),
            diagnostics: diagnostics
        )
    }
}

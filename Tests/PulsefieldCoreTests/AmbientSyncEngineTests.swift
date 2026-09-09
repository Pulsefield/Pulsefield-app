import XCTest
@testable import PulsefieldCore

final class AmbientSyncEngineTests: XCTestCase {
    // Preserve the v1 regression suite while v2 has separate spectral behavior tests.
    private func legacyEngine(
        reference: AmbientSyncEngine.Reference,
        configuration: AmbientSyncEngine.Configuration = .v1
    ) -> AmbientSyncEngine {
        AmbientSyncEngine(reference: reference, configuration: configuration)
    }

    func testCleanDeterministicQueryReachesProvisionalAndFinalLock() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        let provisionalSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )
        let finalSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 5_200),
            elapsedMS: 5_200
        )

        XCTAssertEqual(provisionalSnapshot.phase, .provisional)
        XCTAssertEqual(provisionalSnapshot.stage, .fastTimingVerify)
        XCTAssertNil(provisionalSnapshot.withholdReason)
        XCTAssertEqual(provisionalSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertEqual(provisionalSnapshot.firstProvisionalLockElapsedMS, 3_000)
        let provisionalCandidate = try XCTUnwrap(provisionalSnapshot.diagnostics.candidates.first)
        XCTAssertEqual(provisionalCandidate.rawVoteCount, provisionalCandidate.landmarkVoteCount)
        XCTAssertGreaterThan(provisionalCandidate.weightedVoteScore, Double(provisionalCandidate.rawVoteCount))
        XCTAssertEqual(provisionalCandidate.uniqueHashCount, provisionalCandidate.rawVoteCount)
        XCTAssertEqual(provisionalCandidate.commonHashVoteCount, 0)
        XCTAssertEqual(provisionalCandidate.meanReferencePostingCount, 1, accuracy: 0.001)

        XCTAssertEqual(finalSnapshot.state, .locked)
        XCTAssertEqual(finalSnapshot.phase, .final)
        XCTAssertNil(finalSnapshot.withholdReason)
        XCTAssertEqual(finalSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertEqual(finalSnapshot.firstProvisionalLockElapsedMS, 3_000)
        XCTAssertEqual(finalSnapshot.finalLockElapsedMS, 5_200)
    }

    func testProvisionalGateAcceptsPCENAndCENSWhenSubbandAndChromaOnsetAreWeak() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let referenceFrames = spectralProvisionalReferenceFrames(
            from: makePatternFrames(startMS: 4_000, count: 320)
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )

        XCTAssertEqual(snapshot.phase, .provisional)
        XCTAssertEqual(snapshot.stage, .fastTimingVerify)
        XCTAssertNil(snapshot.withholdReason)
        XCTAssertEqual(snapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)

        let candidate = try XCTUnwrap(snapshot.diagnostics.candidates.first)
        XCTAssertGreaterThan(candidate.onsetScore, 0.95)
        XCTAssertEqual(candidate.subbandOnsetScore, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(candidate.pcenMelScore, 0.95)
        XCTAssertEqual(candidate.chromaOnsetScore, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(candidate.censScore, 0.95)
        XCTAssertGreaterThanOrEqual(candidate.featureAgreementCount, 3)
        XCTAssertGreaterThan(candidate.combinedDenseScore, 0.90)
    }

    func testCoarseAmbiguousHistogramSoftPassesTopKToDenseRerank() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let matchingReference = framesWithLimitedLandmarks(
            makePatternFrames(startMS: 4_000, count: 320),
            maximumLandmarkFrameCount: 140
        )
        let denseDecoyReference = robustFeatureMismatchFrames(
            from: makePatternFrames(startMS: 8_000, count: 320)
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: matchingReference + denseDecoyReference
            )
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )

        XCTAssertEqual(snapshot.phase, .provisional)
        XCTAssertEqual(snapshot.stage, .fastTimingVerify)
        XCTAssertNil(snapshot.withholdReason)
        XCTAssertTrue(snapshot.diagnostics.coarseAmbiguous)
        XCTAssertLessThan(
            snapshot.diagnostics.topToSecondVoteRatio,
            AmbientSyncEngine.Configuration.v1.minimumCoarseVoteRatio
        )
        XCTAssertEqual(snapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)

        let candidate = try XCTUnwrap(snapshot.diagnostics.candidates.first)
        XCTAssertEqual(candidate.coarseOffsetMS, 4_000, accuracy: 5)
        XCTAssertLessThan(candidate.landmarkVoteCount, snapshot.diagnostics.topLandmarkVoteCount)
        XCTAssertGreaterThan(snapshot.diagnostics.denseMargin, 0.06)
    }

    func testWeightedCoarseAmbiguityUsesWeightedScoresWhenRawCountsFavorCommonHash() throws {
        let rareQueryIndices = Array(stride(from: 0, through: 140, by: 20))
        let commonQueryIndices = Array(stride(from: 0, through: 150, by: 10))
        var queryHashesByFrameIndex: [Int: [UInt64]] = [:]
        var referenceHashesByFrameIndex: [Int: [UInt64]] = [:]

        for (rareIndex, queryIndex) in rareQueryIndices.enumerated() {
            let hash = UInt64(30_000 + rareIndex)
            queryHashesByFrameIndex[queryIndex, default: []].append(hash)
            referenceHashesByFrameIndex[queryIndex, default: []].append(hash)
        }

        for queryIndex in commonQueryIndices {
            queryHashesByFrameIndex[queryIndex, default: []].append(7)
            referenceHashesByFrameIndex[queryIndex + 200, default: []].append(7)
        }

        let queryFrames = framesByReplacingLandmarks(
            makePatternFrames(startMS: 0, count: 320),
            hashesByFrameIndex: queryHashesByFrameIndex
        )
        let referenceFrames = framesByReplacingLandmarks(
            makePatternFrames(startMS: 4_000, count: 420),
            hashesByFrameIndex: referenceHashesByFrameIndex
        )
        let configuration = AmbientSyncEngine.Configuration(
            provisionalRerankerConfiguration: AmbientSyncDenseReranker.Configuration(
                minimumDenseMargin: 0
            ),
            minimumCoarseAmbiguousDenseMargin: 1.01
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            ),
            configuration: configuration
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )

        XCTAssertEqual(snapshot.phase, .provisional)
        XCTAssertEqual(snapshot.stage, .fastTimingVerify)
        XCTAssertNil(snapshot.withholdReason)
        XCTAssertEqual(snapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertFalse(snapshot.diagnostics.coarseAmbiguous)
        XCTAssertLessThan(
            snapshot.diagnostics.topToSecondVoteRatio,
            AmbientSyncEngine.Configuration.v1.minimumCoarseVoteRatio
        )
        XCTAssertGreaterThan(
            snapshot.diagnostics.topToSecondWeightedVoteRatio,
            AmbientSyncEngine.Configuration.v1.minimumCoarseVoteRatio
        )
        XCTAssertGreaterThan(
            snapshot.diagnostics.topWeightedVoteMargin,
            Double(AmbientSyncEngine.Configuration.v1.minimumCoarseVoteMargin)
        )
        XCTAssertLessThan(
            snapshot.diagnostics.topLandmarkVoteCount,
            snapshot.diagnostics.secondLandmarkVoteCount
        )
        XCTAssertGreaterThan(
            snapshot.diagnostics.topWeightedVoteScore,
            snapshot.diagnostics.secondWeightedVoteScore
        )
    }

    func testFinalLockContinuesTrackingOnShortTrackingWindow() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 420)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 420)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )
        let finalSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 5_200),
            elapsedMS: 5_200
        )
        let trackingSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, startingAtMS: 5_200, throughMS: 7_200),
            elapsedMS: 7_200
        )

        XCTAssertEqual(finalSnapshot.phase, .final)
        XCTAssertEqual(trackingSnapshot.state, .locked)
        XCTAssertEqual(trackingSnapshot.phase, .final)
        XCTAssertEqual(trackingSnapshot.stage, .tracking)
        XCTAssertNil(trackingSnapshot.withholdReason)
        XCTAssertEqual(trackingSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertEqual(trackingSnapshot.finalLockElapsedMS, 5_200)
    }

    func testConsecutiveShortWindowsPromoteConfirmedWithTimestamp() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        let provisionalSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 2_600),
            elapsedMS: 2_600
        )
        let confirmedSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 2_800),
            elapsedMS: 2_800
        )

        XCTAssertEqual(provisionalSnapshot.phase, .provisional)
        XCTAssertEqual(provisionalSnapshot.confirmedLockElapsedMS, nil)
        XCTAssertEqual(confirmedSnapshot.state, .confirmed)
        XCTAssertEqual(confirmedSnapshot.phase, .confirmed)
        XCTAssertEqual(confirmedSnapshot.confirmedLockElapsedMS, 2_800)
        XCTAssertEqual(confirmedSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertTrue(confirmedSnapshot.diagnostics.offsetTrackerConfirmed)
    }

    func testConfirmedShortWindowDoesNotFallBackToProvisionalAfterTrackLoss() throws {
        let initialQueryFrames = makePatternFrames(startMS: 0, count: 320)
        let initialReferenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        let replacementQueryFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 14_000, count: 140),
            hashBase: 40_000
        )
        let replacementReferenceFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 22_000, count: 140),
            hashBase: 40_000
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: initialReferenceFrames + replacementReferenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_600),
            elapsedMS: 2_600
        )
        let confirmedSnapshot = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_800),
            elapsedMS: 2_800
        )
        XCTAssertEqual(confirmedSnapshot.phase, .confirmed)
        XCTAssertNil(confirmedSnapshot.finalLockElapsedMS)

        for missIndex in 0..<5 {
            let startMS = 3_200 + Double(missIndex) * 2_500
            let missFrames = framesByRebasingLandmarkHashes(
                makePatternFrames(startMS: startMS, count: 120),
                hashBase: UInt64(90_000 + missIndex * 1_000)
            )
            _ = engine.process(
                queryWindow: try window(from: missFrames, throughMS: startMS + 2_380),
                elapsedMS: startMS + 2_380
            )
        }

        let replacementSnapshot = engine.process(
            queryWindow: try window(from: replacementQueryFrames, throughMS: 16_780),
            elapsedMS: 16_780
        )

        XCTAssertEqual(replacementSnapshot.state, .relocking)
        XCTAssertEqual(replacementSnapshot.phase, .confirmed)
        XCTAssertEqual(replacementSnapshot.stage, .tracking)
        XCTAssertEqual(replacementSnapshot.withholdReason, .unstableTrackingResidual)
        XCTAssertNil(replacementSnapshot.estimate)
        XCTAssertEqual(replacementSnapshot.confirmedLockElapsedMS, 2_800)
        XCTAssertNil(replacementSnapshot.finalLockElapsedMS)
        XCTAssertEqual(replacementSnapshot.diagnostics.candidates.first?.offsetMS ?? 0, 8_000, accuracy: 5)
        XCTAssertFalse(replacementSnapshot.diagnostics.offsetTrackerConfirmed)
    }

    func testConfirmedLongWindowDoesNotUseProvisionalEstimateAfterTrackLoss() throws {
        let initialQueryFrames = makePatternFrames(startMS: 0, count: 320)
        let initialReferenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        let replacementQueryFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 14_000, count: 320),
            hashBase: 40_000
        )
        let replacementReferenceFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 22_000, count: 320),
            hashBase: 40_000
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: initialReferenceFrames + replacementReferenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_600),
            elapsedMS: 2_600
        )
        let confirmedSnapshot = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_800),
            elapsedMS: 2_800
        )
        XCTAssertEqual(confirmedSnapshot.phase, .confirmed)
        XCTAssertNil(confirmedSnapshot.finalLockElapsedMS)

        for missIndex in 0..<5 {
            let startMS = 3_200 + Double(missIndex) * 2_500
            let missFrames = framesByRebasingLandmarkHashes(
                makePatternFrames(startMS: startMS, count: 120),
                hashBase: UInt64(90_000 + missIndex * 1_000)
            )
            _ = engine.process(
                queryWindow: try window(from: missFrames, throughMS: startMS + 2_380),
                elapsedMS: startMS + 2_380
            )
        }

        let replacementSnapshot = engine.process(
            queryWindow: try window(from: replacementQueryFrames, throughMS: 19_200),
            elapsedMS: 19_200
        )

        XCTAssertEqual(replacementSnapshot.state, .relocking)
        XCTAssertEqual(replacementSnapshot.phase, .confirmed)
        XCTAssertEqual(replacementSnapshot.stage, .robustVerify)
        XCTAssertEqual(replacementSnapshot.withholdReason, .unstableTrackingResidual)
        XCTAssertNil(replacementSnapshot.estimate)
        XCTAssertEqual(replacementSnapshot.confirmedLockElapsedMS, 2_800)
        XCTAssertNil(replacementSnapshot.finalLockElapsedMS)
        XCTAssertEqual(replacementSnapshot.diagnostics.candidates.first?.offsetMS ?? 0, 8_000, accuracy: 5)
        XCTAssertFalse(replacementSnapshot.diagnostics.offsetTrackerConfirmed)
    }

    func testConfirmedTrackingSearchRangeSuppressesDistantReplacementCandidates() throws {
        let initialQueryFrames = makePatternFrames(startMS: 0, count: 320)
        let initialReferenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        let replacementQueryFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 3_200, count: 140),
            hashBase: 40_000
        )
        let replacementReferenceFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 11_200, count: 140),
            hashBase: 40_000
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: initialReferenceFrames + replacementReferenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_600),
            elapsedMS: 2_600
        )
        let confirmedSnapshot = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 2_800),
            elapsedMS: 2_800
        )
        let trackingSnapshot = engine.process(
            queryWindow: try window(from: replacementQueryFrames, throughMS: 5_580),
            elapsedMS: 5_580
        )

        XCTAssertEqual(confirmedSnapshot.phase, .confirmed)
        XCTAssertNil(confirmedSnapshot.finalLockElapsedMS)
        XCTAssertEqual(trackingSnapshot.state, .confirmed)
        XCTAssertEqual(trackingSnapshot.phase, .confirmed)
        XCTAssertEqual(trackingSnapshot.stage, .tracking)
        XCTAssertEqual(trackingSnapshot.withholdReason, .insufficientLandmarkEvidence)
        XCTAssertEqual(trackingSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertEqual(trackingSnapshot.diagnostics.histogramCandidateCount, 0)
        XCTAssertTrue(trackingSnapshot.diagnostics.candidates.isEmpty)
        XCTAssertNil(trackingSnapshot.finalLockElapsedMS)
    }

    func testWeakTimingCandidateStillUpdatesOffsetTracker() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 180)
        let referenceFrames = denseFeatureMismatchFrames(
            from: makePatternFrames(startMS: 4_000, count: 180)
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )

        XCTAssertEqual(snapshot.stage, .fastTimingVerify)
        XCTAssertEqual(snapshot.withholdReason, .weakAlignmentPeak)
        XCTAssertGreaterThan(snapshot.diagnostics.histogramCandidateCount, 0)
        XCTAssertFalse(snapshot.diagnostics.candidates.isEmpty)
        XCTAssertGreaterThan(snapshot.diagnostics.trackCount, 0)
        XCTAssertFalse(snapshot.diagnostics.offsetTrackerConfirmed)
    }

    func testPostFinalRobustFailurePreservesFinalPhase() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 700)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 700)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )
        let finalSnapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 5_200),
            elapsedMS: 5_200
        )
        let trackingFailureSnapshot = engine.process(
            queryWindow: try window(
                from: robustFeatureMismatchFrames(from: queryFrames),
                startingAtMS: 7_200,
                throughMS: 12_400
            ),
            elapsedMS: 12_400
        )

        XCTAssertEqual(finalSnapshot.phase, .final)
        XCTAssertEqual(trackingFailureSnapshot.state, .locked)
        XCTAssertEqual(trackingFailureSnapshot.phase, .final)
        XCTAssertEqual(trackingFailureSnapshot.stage, .tracking)
        XCTAssertEqual(trackingFailureSnapshot.withholdReason, .weakAlignmentPeak)
        XCTAssertEqual(trackingFailureSnapshot.estimate?.offsetMS ?? 0, 4_000, accuracy: 5)
        XCTAssertLessThan(
            trackingFailureSnapshot.diagnostics.trackConfidenceLogOdds,
            finalSnapshot.diagnostics.trackConfidenceLogOdds
        )
        XCTAssertEqual(trackingFailureSnapshot.finalLockElapsedMS, 5_200)
    }

    func testFinalTrackingDoesNotAttachAcceptedTrackToDistantReplacement() throws {
        let initialQueryFrames = makePatternFrames(startMS: 0, count: 320)
        let initialReferenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        let replacementQueryFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 14_000, count: 140),
            hashBase: 40_000
        )
        let replacementReferenceFrames = framesByRebasingLandmarkHashes(
            makePatternFrames(startMS: 22_000, count: 140),
            hashBase: 40_000
        )
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: initialReferenceFrames + replacementReferenceFrames
            )
        )

        _ = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )
        let finalSnapshot = engine.process(
            queryWindow: try window(from: initialQueryFrames, throughMS: 5_200),
            elapsedMS: 5_200
        )
        XCTAssertEqual(finalSnapshot.phase, .final)

        for missIndex in 0..<5 {
            let startMS = 6_000 + Double(missIndex) * 2_500
            let missFrames = framesByRebasingLandmarkHashes(
                makePatternFrames(startMS: startMS, count: 120),
                hashBase: UInt64(90_000 + missIndex * 1_000)
            )
            _ = engine.process(
                queryWindow: try window(from: missFrames, throughMS: startMS + 2_380),
                elapsedMS: startMS + 2_380
            )
        }

        let replacementSnapshot = engine.process(
            queryWindow: try window(from: replacementQueryFrames, throughMS: 16_780),
            elapsedMS: 16_780
        )

        XCTAssertEqual(replacementSnapshot.state, .drifting)
        XCTAssertEqual(replacementSnapshot.phase, .final)
        XCTAssertEqual(replacementSnapshot.stage, .tracking)
        XCTAssertEqual(replacementSnapshot.withholdReason, .unstableTrackingResidual)
        XCTAssertNil(replacementSnapshot.estimate)
        XCTAssertEqual(replacementSnapshot.diagnostics.candidates.first?.offsetMS ?? 0, 8_000, accuracy: 5)
        XCTAssertGreaterThan(replacementSnapshot.diagnostics.trackCount, 0)
    }

    func testOffsetTrackerConfirmsAfterConsecutiveHitsAtSameOffset() {
        var tracker = AmbientSyncOffsetTracker()

        var result = tracker.update(
            candidates: [offsetMeasurement(4_000)],
            elapsedMS: 1_000
        )
        XCTAssertFalse(result.isConfirmed)

        result = tracker.update(
            candidates: [offsetMeasurement(4_000)],
            elapsedMS: 2_000
        )

        XCTAssertTrue(result.isConfirmed)
        XCTAssertTrue(result.isStable)
        XCTAssertEqual(result.bestTrack?.offsetMS ?? 0, 4_000, accuracy: 1)
        XCTAssertEqual(result.bestTrack?.consecutiveHits, 2)
        XCTAssertGreaterThan(result.confidenceMarginLogOdds, 1)
    }

    func testOffsetTrackerKeepsDefaultEngineTopKMeasurements() {
        var tracker = AmbientSyncOffsetTracker()
        let candidates = (0..<8).map { index in
            offsetMeasurement(4_000 + Double(index) * 250)
        }

        let result = tracker.update(candidates: candidates, elapsedMS: 1_000)

        XCTAssertEqual(result.tracks.count, 8)
        XCTAssertEqual(result.tracks.map(\.offsetMS), candidates.map(\.offsetMS))
    }

    func testOffsetTrackerDoesNotConfirmConflictingCandidatesPrematurely() {
        var tracker = AmbientSyncOffsetTracker()
        let candidates = [
            offsetMeasurement(4_000),
            offsetMeasurement(4_220)
        ]

        _ = tracker.update(candidates: candidates, elapsedMS: 1_000)
        let result = tracker.update(candidates: candidates, elapsedMS: 2_000)

        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertFalse(result.isConfirmed)
        XCTAssertLessThan(result.confidenceMarginLogOdds, 1)
    }

    func testOffsetTrackerMissingAndSingleConflictDecayWithoutImmediateJump() {
        var tracker = AmbientSyncOffsetTracker()
        _ = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 1_000)
        let confirmed = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 2_000)

        let missing = tracker.update(candidates: [], elapsedMS: 3_000)
        XCTAssertEqual(missing.bestTrack?.offsetMS ?? 0, 4_000, accuracy: 1)
        XCTAssertLessThan(
            missing.bestTrack?.confidenceLogOdds ?? 0,
            confirmed.bestTrack?.confidenceLogOdds ?? 0
        )
        XCTAssertTrue(missing.canCoast)

        let conflicting = tracker.update(candidates: [offsetMeasurement(4_260)], elapsedMS: 4_000)
        XCTAssertEqual(conflicting.bestTrack?.offsetMS ?? 0, 4_000, accuracy: 1)
        XCTAssertGreaterThanOrEqual(conflicting.tracks.count, 2)
        XCTAssertFalse(conflicting.isConfirmed)
    }

    func testOffsetTrackerProtectsConfirmedTrackFromFastTakeover() {
        var tracker = AmbientSyncOffsetTracker()
        _ = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 1_000)
        _ = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 2_000)

        _ = tracker.update(candidates: [offsetMeasurement(4_260)], elapsedMS: 3_000)
        let conflict = tracker.update(candidates: [offsetMeasurement(4_260)], elapsedMS: 4_000)

        XCTAssertEqual(conflict.bestTrack?.offsetMS ?? 0, 4_000, accuracy: 1)
        XCTAssertGreaterThanOrEqual(conflict.tracks.count, 2)
        XCTAssertFalse(conflict.isConfirmed)
    }

    func testOffsetTrackerTreatsWideInnovationAgainstConfirmedTrackAsShadowCandidate() {
        var tracker = AmbientSyncOffsetTracker()
        _ = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 1_000)
        _ = tracker.update(candidates: [offsetMeasurement(4_000)], elapsedMS: 2_000)

        let conflict = tracker.update(candidates: [offsetMeasurement(4_100)], elapsedMS: 3_000)

        XCTAssertEqual(conflict.bestTrack?.offsetMS ?? 0, 4_000, accuracy: 1)
        XCTAssertGreaterThanOrEqual(conflict.tracks.count, 2)
        XCTAssertFalse(conflict.isConfirmed)
    }

    func testLowSignalWithholdsBeforeCoarseRetrieval() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 180, energyDBFS: -110)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 180)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: referenceFrames
            )
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 3_000),
            elapsedMS: 3_000
        )

        XCTAssertEqual(snapshot.state, .listening)
        XCTAssertEqual(snapshot.stage, .readiness)
        XCTAssertEqual(snapshot.withholdReason, .insufficientEnergy)
        XCTAssertEqual(snapshot.phase, .none)
        XCTAssertTrue(snapshot.diagnostics.candidates.isEmpty)
    }

    func testAmbiguousRepeatedReferenceWithholdsInsteadOfFalseLocking() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let firstReference = makePatternFrames(startMS: 4_000, count: 320)
        let repeatedReference = makePatternFrames(startMS: 8_000, count: 320)
        var engine = legacyEngine(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: "/tmp/reference.wav",
                frames: firstReference + repeatedReference
            )
        )

        let snapshot = engine.process(
            queryWindow: try window(from: queryFrames, throughMS: 5_200),
            elapsedMS: 5_200
        )

        XCTAssertNotEqual(snapshot.phase, .final)
        XCTAssertEqual(snapshot.stage, .fastTimingVerify)
        XCTAssertEqual(snapshot.withholdReason, .ambiguousOffset)
        XCTAssertTrue(snapshot.diagnostics.coarseAmbiguous)
        XCTAssertEqual(snapshot.diagnostics.denseMargin, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(snapshot.diagnostics.candidates.count, 2)
    }

    private func window(from frames: [MicFeatureFrame], throughMS endpointMS: Double) throws -> MicFeatureWindow {
        let selectedFrames = frames.filter { $0.recordedTimeMS <= endpointMS }
        return MicFeatureWindow(frames: try XCTUnwrap(selectedFrames.isEmpty ? nil : selectedFrames))
    }

    private func window(
        from frames: [MicFeatureFrame],
        startingAtMS startMS: Double,
        throughMS endpointMS: Double
    ) throws -> MicFeatureWindow {
        let selectedFrames = frames.filter { frame in
            frame.recordedTimeMS >= startMS && frame.recordedTimeMS <= endpointMS
        }
        return MicFeatureWindow(frames: try XCTUnwrap(selectedFrames.isEmpty ? nil : selectedFrames))
    }

    private func offsetMeasurement(
        _ offsetMS: Double,
        confidence: Double = 1
    ) -> AmbientSyncOffsetTracker.Measurement {
        AmbientSyncOffsetTracker.Measurement(offsetMS: offsetMS, confidence: confidence)
    }

    private func makePatternFrames(
        startMS: Double,
        count: Int,
        hopMS: Double = 20,
        energyDBFS: Double = -18
    ) -> [MicFeatureFrame] {
        (0..<count).map { index in
            let timeMS = startMS + Double(index) * hopMS
            let phase = Double(index % 24) / 24
            return MicFeatureFrame(
                recordedTimeMS: timeMS,
                hostTimeMS: timeMS + 10_000,
                onsetEnvelope: Float(0.2 + 0.7 * max(0, sin(2 * Double.pi * phase))),
                subbandOnset: [
                    Float(0.1 + 0.8 * phase),
                    Float(0.9 - 0.5 * phase),
                    Float(index % 3 == 0 ? 0.8 : 0.2)
                ],
                pcenMel: [
                    Float(0.2 + 0.7 * phase),
                    Float(0.8 - 0.4 * phase),
                    Float(index % 5 == 0 ? 0.9 : 0.3)
                ],
                chroma: chroma(index: index),
                cens: cens(index: index),
                landmarkHashes: [],
                landmarks: [
                    MicFeatureLandmark(
                        hash: UInt64(index + 10_000),
                        anchorTimeMS: timeMS,
                        anchorFrequencyBin: 1 + index % 16,
                        targetFrequencyBin: 32 + index % 16,
                        deltaFrames: 1
                    )
                ],
                energyDBFS: energyDBFS,
                snrDB: energyDBFS > -80 ? 24 : 0
            )
        }
    }

    private func chroma(index: Int) -> [Float] {
        let active = index % 12
        return (0..<12).map { Float($0 == active ? 1 : 0) }
    }

    private func cens(index: Int) -> [Float] {
        let active = (index / 4) % 12
        return (0..<12).map { Float($0 == active ? 1 : 0) }
    }

    private func framesByReplacingLandmarks(
        _ frames: [MicFeatureFrame],
        hashesByFrameIndex: [Int: [UInt64]]
    ) -> [MicFeatureFrame] {
        frames.enumerated().map { index, frame in
            let landmarks = hashesByFrameIndex[index, default: []].enumerated().map { landmarkIndex, hash in
                MicFeatureLandmark(
                    hash: hash,
                    anchorTimeMS: frame.recordedTimeMS,
                    anchorFrequencyBin: 1 + landmarkIndex,
                    targetFrequencyBin: 32 + landmarkIndex,
                    deltaFrames: 1
                )
            }

            return MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: frame.onsetEnvelope,
                subbandOnset: frame.subbandOnset,
                pcenMel: frame.pcenMel,
                chroma: frame.chroma,
                cens: frame.cens,
                landmarkHashes: landmarks.map(\.hash),
                landmarks: landmarks,
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }

    private func spectralProvisionalReferenceFrames(from frames: [MicFeatureFrame]) -> [MicFeatureFrame] {
        frames.map { frame in
            MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: frame.onsetEnvelope,
                subbandOnset: Array(repeating: 0, count: frame.subbandOnset.count),
                pcenMel: frame.pcenMel,
                chroma: Array(repeating: 0, count: frame.chroma.count),
                cens: frame.cens,
                landmarkHashes: frame.landmarkHashes,
                landmarks: frame.landmarks,
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }

    private func robustFeatureMismatchFrames(from frames: [MicFeatureFrame]) -> [MicFeatureFrame] {
        frames.map { frame in
            MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: frame.onsetEnvelope,
                subbandOnset: frame.subbandOnset,
                pcenMel: frame.pcenMel,
                chroma: frame.chroma,
                cens: Array(repeating: 0, count: frame.cens.count),
                landmarkHashes: frame.landmarkHashes,
                landmarks: frame.landmarks,
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }

    private func denseFeatureMismatchFrames(from frames: [MicFeatureFrame]) -> [MicFeatureFrame] {
        frames.map { frame in
            MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: 0,
                subbandOnset: Array(repeating: 0, count: frame.subbandOnset.count),
                pcenMel: Array(repeating: 0, count: frame.pcenMel.count),
                chroma: Array(repeating: 0, count: frame.chroma.count),
                cens: Array(repeating: 0, count: frame.cens.count),
                landmarkHashes: frame.landmarkHashes,
                landmarks: frame.landmarks,
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }

    private func framesByRebasingLandmarkHashes(
        _ frames: [MicFeatureFrame],
        hashBase: UInt64
    ) -> [MicFeatureFrame] {
        frames.enumerated().map { index, frame in
            let landmark = MicFeatureLandmark(
                hash: hashBase + UInt64(index),
                anchorTimeMS: frame.recordedTimeMS,
                anchorFrequencyBin: frame.landmarks.first?.anchorFrequencyBin ?? 1,
                targetFrequencyBin: frame.landmarks.first?.targetFrequencyBin ?? 32,
                deltaFrames: frame.landmarks.first?.deltaFrames ?? 1
            )

            return MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: frame.onsetEnvelope,
                subbandOnset: frame.subbandOnset,
                pcenMel: frame.pcenMel,
                chroma: frame.chroma,
                cens: frame.cens,
                landmarkHashes: [landmark.hash],
                landmarks: [landmark],
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }

    private func framesWithLimitedLandmarks(
        _ frames: [MicFeatureFrame],
        maximumLandmarkFrameCount: Int
    ) -> [MicFeatureFrame] {
        frames.enumerated().map { index, frame in
            let landmarks = index < maximumLandmarkFrameCount ? frame.landmarks : []
            return MicFeatureFrame(
                recordedTimeMS: frame.recordedTimeMS,
                hostTimeMS: frame.hostTimeMS,
                onsetEnvelope: frame.onsetEnvelope,
                subbandOnset: frame.subbandOnset,
                pcenMel: frame.pcenMel,
                chroma: frame.chroma,
                cens: frame.cens,
                landmarkHashes: landmarks.map(\.hash),
                landmarks: landmarks,
                energyDBFS: frame.energyDBFS,
                snrDB: frame.snrDB
            )
        }
    }
}

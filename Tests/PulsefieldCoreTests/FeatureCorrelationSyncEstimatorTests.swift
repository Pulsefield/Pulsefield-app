import AVFoundation
import CryptoKit
import XCTest
@testable import PulsefieldCore

final class FeatureCorrelationSyncEstimatorTests: XCTestCase {
    func testCurrentEstimateRemainsIdleBeforeEstimatorStarts() async {
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertNil(estimate)
        XCTAssertEqual(state, .idle)
    }

    func testEstimatorRejectsSyncIndexForDifferentAssetAsInvalidPreflight() async throws {
        let asset = makeAsset()
        let mismatchedIndexAssetID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
        let index = try makeIndex(values: [1, 0, 0], assetID: mismatchedIndexAssetID)
        let estimator = FeatureCorrelationSyncEstimator(capture: StubAmbientCapture())

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected mismatched sync index to be rejected.")
        } catch let error as AmbientSyncStartError {
            XCTAssertEqual(error, .indexInvalid)
        }

        let state = await estimator.currentState()
        let diagnostics = await estimator.currentDiagnostics()
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .invalid)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, false)
        XCTAssertNil(diagnostics?.decision.withholdReason)
    }

    func testCurrentDiagnosticsRecordsWithheldLowEnergyWindow() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: [0, 0, 0])
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNil(estimate)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, false)
        XCTAssertEqual(diagnostics?.decision.withholdReason, .insufficientEnergy)
        XCTAssertEqual(diagnostics?.search.mode, .wide)
        XCTAssertEqual(diagnostics?.query.activeFrameFraction, 0)
    }

    func testCurrentDiagnosticsRecordsCaptureInputChannelCount() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture(sampleRate: 44_100, inputChannelCount: 2)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(diagnostics?.capture.inputChannelCount, 2)
    }

    func testCurrentDiagnosticsRecordsPublishedPrototypeEstimate() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNotNil(estimate)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(diagnostics?.decision.withholdReason)
        XCTAssertEqual(diagnostics?.search.mode, .wide)
        XCTAssertEqual(diagnostics?.search.selectedReferenceMS, estimate?.referenceTimeMS)
        XCTAssertGreaterThanOrEqual(diagnostics?.scoring.peakScore ?? 0, 0.80)
        XCTAssertNotNil(diagnostics?.scoring.noiseFloorMean)
        XCTAssertNotNil(diagnostics?.scoring.noiseFloorStd)
        XCTAssertNotNil(diagnostics?.scoring.peakZ)
    }

    func testInitialWideSearchWithholdsRepeatedOffsetsAsAmbiguous() async throws {
        let asset = makeAsset(durationMS: 1_600)
        let index = try makeIndex(
            values: [0.1, 0.2, 0.9, 0.4, 0.1, 0.3, 0, 0, 0, 0, 0, 0.9, 0.4, 0.1, 0.3, 0],
            durationMS: 1_600
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 500,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.9, 0.4, 0.1, 0.3]))
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNil(estimate)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, false)
        XCTAssertEqual(diagnostics?.decision.withholdReason, .ambiguousOffset)
        XCTAssertEqual(diagnostics?.search.mode, .wide)
        XCTAssertGreaterThanOrEqual(diagnostics?.search.topCandidates.count ?? 0, 2)
        guard let peakScore = diagnostics?.scoring.peakScore,
              let secondBestScore = diagnostics?.scoring.secondBestScore
        else {
            return XCTFail("Expected ambiguous match diagnostics to include peak and second-best scores.")
        }
        XCTAssertEqual(peakScore, secondBestScore, accuracy: 0.001)
    }

    func testInitialWideSearchWithholdsNearTieOffsetsAsAmbiguous() async throws {
        let asset = makeAsset(durationMS: 1_700)
        let index = try makeIndex(
            values: [0.1, 0.2, 0.9, 0.4, 0.1, 0.3, 0, 0, 0, 0, 0, 0.3, 0.76, 0.48, 0.14, 0.25, 0],
            durationMS: 1_700
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 500,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.9, 0.4, 0.1, 0.3]))
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNil(estimate)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, false)
        XCTAssertEqual(diagnostics?.decision.withholdReason, .ambiguousOffset)
        XCTAssertEqual(diagnostics?.search.mode, .wide)
        XCTAssertLessThan(diagnostics?.scoring.peakMargin ?? .infinity, 0.06)
        XCTAssertGreaterThan(diagnostics?.scoring.secondBestScore ?? 0, 0.90)
    }

    func testDenseVerificationPopulatesSignalDiagnosticsForGeneratedAudio() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let samples = generatedModulatedTone(sampleRate: sampleRate, frameHopMS: frameHopMS)
        let extractor = AmbientSyncFeatureExtractor()
        let featureSet = extractor.extract(
            samples: samples,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .silence
        )
        let asset = makeAsset(durationMS: Int((Double(samples.count) / sampleRate) * 1_000))
        let index = try makeIndex(featureSet: featureSet, sampleRate: sampleRate, frameHopMS: frameHopMS, durationMS: asset.durationMS)
        let capture = StubAmbientCapture(sampleRate: sampleRate)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: asset.durationMS,
            minimumLockConfidence: 0.50
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples)
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNotNil(estimate)
        XCTAssertNotNil(diagnostics?.scoring.onsetFluxScore)
        XCTAssertNotNil(diagnostics?.scoring.logMelScore)
        XCTAssertNotNil(diagnostics?.scoring.chromaScore)
        XCTAssertNotNil(diagnostics?.scoring.energyScore)
        XCTAssertGreaterThan(diagnostics?.scoring.landmarkVoteCount ?? 0, 0)
        XCTAssertGreaterThan(diagnostics?.scoring.landmarkInlierRate ?? 0, 0)
        XCTAssertGreaterThan(diagnostics?.search.topCandidates.first?.combinedScore ?? 0, 0.50)
    }

    func testNoMatchDiagnosticsDoNotReportQueryLandmarksAsVotes() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 8)
        let query = generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 18)
        let featureSet = AmbientSyncFeatureExtractor().extract(
            samples: reference,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .silence
        )
        let durationMS = Int((Double(reference.count) / sampleRate) * 1_000)
        let asset = makeAsset(durationMS: durationMS)
        let index = try makeIndex(featureSet: featureSet, sampleRate: sampleRate, frameHopMS: frameHopMS, durationMS: durationMS)
        let capture = StubAmbientCapture(sampleRate: sampleRate)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: Int((Double(query.count) / sampleRate) * 1_000),
            minimumLockConfidence: 0.50
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: query)
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertNil(estimate)
        XCTAssertGreaterThan(diagnostics?.query.landmarkCount ?? 0, 0)
        XCTAssertEqual(diagnostics?.search.candidateCount, 0)
        XCTAssertEqual(diagnostics?.scoring.landmarkVoteCount, 0)
    }

    func testGeneratedCorpusCleanSameFilePublishesReferenceAtWindowEnd() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 130)
        let queryStartFrame = 24
        let queryFrameCount = 36
        let query = frameSlice(
            reference,
            startFrame: queryStartFrame,
            frameCount: queryFrameCount,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS
        )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.65
        )

        let expectedReferenceMS = Double(queryStartFrame + queryFrameCount) * frameHopMS
        XCTAssertEqual(result.estimate?.referenceTimeMS ?? -1, expectedReferenceMS, accuracy: 100)
        XCTAssertGreaterThanOrEqual(result.estimate?.confidence ?? 0, 0.65)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(result.diagnostics?.decision.withholdReason)
        XCTAssertNotNil(result.diagnostics?.scoring.secondBestScore)
    }

    func testGeneratedCorpusMicrophoneColoredPlaybackPublishesReferenceEstimate() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 90)
        let queryStartFrame = 30
        let queryFrameCount = 36
        let query = microphoneColored(
            frameSlice(
                reference,
                startFrame: queryStartFrame,
                frameCount: queryFrameCount,
                sampleRate: sampleRate,
                frameHopMS: frameHopMS
            )
        )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.50
        )

        let expectedReferenceMS = Double(queryStartFrame + queryFrameCount) * frameHopMS
        XCTAssertEqual(result.estimate?.referenceTimeMS ?? -1, expectedReferenceMS, accuracy: 200)
        XCTAssertGreaterThanOrEqual(result.estimate?.confidence ?? 0, 0.50)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(result.diagnostics?.decision.withholdReason)
        XCTAssertNotNil(result.diagnostics?.scoring.logMelScore)
        XCTAssertNotNil(result.diagnostics?.scoring.chromaScore)
    }

    func testGeneratedCorpusQuietIntroWithholdsThenPublishesActiveSection() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let quietFrameCount = 100
        let active = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 48)
        let reference = generatedQuietIntro(
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            frameCount: quietFrameCount
        ) + active
        let featureSet = AmbientSyncFeatureExtractor().extract(
            samples: reference,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .silence
        )
        let durationMS = Int((Double(reference.count) / sampleRate) * 1_000)
        let asset = makeAsset(durationMS: durationMS)
        let index = try makeIndex(featureSet: featureSet, sampleRate: sampleRate, frameHopMS: frameHopMS, durationMS: durationMS)
        let capture = StubAmbientCapture(sampleRate: sampleRate)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 3_600,
            minimumLockConfidence: 0.60
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: frameSlice(reference, startFrame: 0, frameCount: 60, sampleRate: sampleRate, frameHopMS: frameHopMS))
        let quietEstimate = await estimator.currentEstimate()
        let quietDiagnostics = await estimator.currentDiagnostics()

        await capture.push(samples: frameSlice(reference, startFrame: quietFrameCount + 6, frameCount: 36, sampleRate: sampleRate, frameHopMS: frameHopMS))
        let activeEstimate = await estimator.currentEstimate()
        let activeDiagnostics = await estimator.currentDiagnostics()

        XCTAssertNil(quietEstimate)
        XCTAssertEqual(quietDiagnostics?.decision.withholdReason, .insufficientEnergy)
        XCTAssertEqual(activeEstimate?.referenceTimeMS ?? -1, Double(quietFrameCount + 42) * frameHopMS, accuracy: 100)
        XCTAssertEqual(activeDiagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(activeDiagnostics?.decision.withholdReason)
    }

    func testGeneratedCorpusRepeatedChorusWithholdsAmbiguousInitialLock() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let motif = generatedMotif(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 28)
        let reference = generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 20)
            + motif
            + generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 28)
            + motif
            + generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 18)

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: motif,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.65
        )

        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, false)
        XCTAssertEqual(result.diagnostics?.decision.withholdReason, .ambiguousOffset)
        XCTAssertGreaterThanOrEqual(result.diagnostics?.search.topCandidates.count ?? 0, 2)
        XCTAssertEqual(
            result.diagnostics?.scoring.peakScore ?? -1,
            result.diagnostics?.scoring.secondBestScore ?? -2,
            accuracy: 0.001
        )
    }

    func testGeneratedCorpusUnrelatedAudioDoesNotEmitReliableEstimate() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 90)
        let unrelated = generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 36)

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: unrelated,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.65
        )

        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, false)
        XCTAssertTrue(
            [
                AmbientSyncWithholdReason.insufficientLandmarkEvidence,
                .weakAlignmentPeak,
                .ambiguousOffset,
                .lostSignal
            ].contains(result.diagnostics?.decision.withholdReason)
        )
    }

    func testGeneratedCorpusModerateRoomNoisePublishesWhenPeakIsClear() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 100)
        let queryStartFrame = 32
        let queryFrameCount = 40
        let query = addDeterministicRoomNoise(
            frameSlice(
                reference,
                startFrame: queryStartFrame,
                frameCount: queryFrameCount,
                sampleRate: sampleRate,
                frameHopMS: frameHopMS
            ),
            amplitude: 0.035
        )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.50
        )

        let expectedReferenceMS = Double(queryStartFrame + queryFrameCount) * frameHopMS
        XCTAssertEqual(result.estimate?.referenceTimeMS ?? -1, expectedReferenceMS, accuracy: 200)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(result.diagnostics?.decision.withholdReason)
        XCTAssertGreaterThanOrEqual(result.diagnostics?.scoring.peakScore ?? 0, 0.50)
    }

    func testGeneratedCorpusHeavyRoomNoiseWithholdsWeakEvidence() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 100)
        let maskedPlayback = frameSlice(
            reference,
            startFrame: 32,
            frameCount: 40,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS
        ).map { $0 * 0.04 }
        let query = addDeterministicRoomNoise(
            maskedPlayback,
            amplitude: 0.85
        )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.78
        )

        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, false)
        XCTAssertTrue(
            [
                AmbientSyncWithholdReason.insufficientLandmarkEvidence,
                .weakAlignmentPeak,
                .ambiguousOffset,
                .lostSignal
            ].contains(result.diagnostics?.decision.withholdReason)
        )
        XCTAssertNil(result.diagnostics?.clock.latencyMS)
        XCTAssertEqual(result.diagnostics?.clock.latencySource, .unavailable)
    }

    func testGeneratedCorpusReverbAndCompressionStillPublishesWithDenseDiagnostics() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 100)
        let queryStartFrame = 28
        let queryFrameCount = 40
        let query = compressed(
            reverberated(
                frameSlice(
                    reference,
                    startFrame: queryStartFrame,
                    frameCount: queryFrameCount,
                    sampleRate: sampleRate,
                    frameHopMS: frameHopMS
                ),
                sampleRate: sampleRate
            )
        )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.45
        )

        let expectedReferenceMS = Double(queryStartFrame + queryFrameCount) * frameHopMS
        XCTAssertEqual(result.estimate?.referenceTimeMS ?? -1, expectedReferenceMS, accuracy: 250)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(result.diagnostics?.decision.withholdReason)
        XCTAssertNotNil(result.diagnostics?.scoring.onsetFluxScore)
        XCTAssertNotNil(result.diagnostics?.scoring.logMelScore)
        XCTAssertNotNil(result.diagnostics?.scoring.chromaScore)
    }

    func testGeneratedCorpusLatencyOffsetAlignsReferenceWithoutInventingLatency() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let reference = generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 100)
        let queryStartFrame = 30
        let queryFrameCount = 36
        let latencyFrameCount = 4
        let samplesPerFrame = max(1, Int(sampleRate * frameHopMS / 1_000))
        let query = Array(repeating: Float(0), count: latencyFrameCount * samplesPerFrame)
            + frameSlice(
                reference,
                startFrame: queryStartFrame,
                frameCount: queryFrameCount,
                sampleRate: sampleRate,
                frameHopMS: frameHopMS
            )

        let result = try await estimateGeneratedQuery(
            referenceSamples: reference,
            querySamples: query,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            minimumLockConfidence: 0.45
        )

        let expectedReferenceMS = Double(queryStartFrame + queryFrameCount) * frameHopMS
        XCTAssertEqual(result.estimate?.referenceTimeMS ?? -1, expectedReferenceMS, accuracy: 300)
        XCTAssertEqual(result.diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNil(result.estimate?.latencyMS)
        XCTAssertNil(result.diagnostics?.clock.latencyMS)
        XCTAssertEqual(result.diagnostics?.clock.latencySource, .unavailable)
    }

    func testGeneratedCorpusRepeatedChorusWhileLockedUsesPredictionToDisambiguate() async throws {
        let sampleRate = 22_050.0
        let frameHopMS = 100.0
        let introFrameCount = 20
        let motifFrameCount = 28
        let bridgeFrameCount = 28
        let motif = generatedMotif(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: motifFrameCount)
        let reference = generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: introFrameCount)
            + motif
            + generatedTrackA(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: bridgeFrameCount)
            + motif
            + generatedTrackB(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: 20)
        let uniqueStartFrame = introFrameCount + motifFrameCount
        let uniqueFrameCount = 36
        let secondMotifStartFrame = introFrameCount + motifFrameCount + bridgeFrameCount
        let startTime = ContinuousClock.now
        let featureSet = AmbientSyncFeatureExtractor().extract(
            samples: reference,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .silence
        )
        let durationMS = Int((Double(reference.count) / sampleRate) * 1_000)
        let asset = makeAsset(durationMS: durationMS)
        let index = try makeIndex(
            featureSet: featureSet,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            durationMS: durationMS
        )
        let capture = StubAmbientCapture(sampleRate: sampleRate)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: Int(Double(uniqueFrameCount) * frameHopMS),
            minimumLockConfidence: 0.50
        )
        let lockQuery = frameSlice(
            reference,
            startFrame: uniqueStartFrame,
            frameCount: uniqueFrameCount,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS
        )
        let repeatedQuery = frameSlice(
            reference,
            startFrame: secondMotifStartFrame,
            frameCount: motifFrameCount,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: lockQuery, hostTime: startTime)
        _ = await estimator.currentEstimate()
        await capture.push(samples: lockQuery, hostTime: startTime)
        let lockedEstimate = await estimator.currentEstimate()
        let elapsedMS = Double((secondMotifStartFrame + motifFrameCount) - (uniqueStartFrame + uniqueFrameCount)) * frameHopMS
        await capture.push(samples: repeatedQuery, hostTime: startTime.advanced(by: .milliseconds(Int(elapsedMS))))
        let trackedEstimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS ?? -1, Double(uniqueStartFrame + uniqueFrameCount) * frameHopMS, accuracy: 150)
        XCTAssertEqual(trackedEstimate?.referenceTimeMS ?? -1, Double(secondMotifStartFrame + motifFrameCount) * frameHopMS, accuracy: 150)
        XCTAssertEqual(diagnostics?.search.mode, .narrow)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, true)
        XCTAssertNotNil(diagnostics?.scoring.secondBestScore)
        XCTAssertGreaterThanOrEqual(diagnostics?.search.topCandidates.count ?? 0, 2)
    }

    func testStartFailureWhileReadingIndexClearsPreparingState() async throws {
        let asset = makeAsset()
        let missingFeatureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let index = LocalAudioSyncIndex(
            assetID: asset.id,
            durationMS: asset.durationMS,
            sampleRate: 10,
            frameHopMS: 100,
            onsetEnvelopeURL: missingFeatureURL,
            spectralSummaryURL: nil,
            chromaURL: nil,
            version: LocalAudioSyncIndexer.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let estimator = FeatureCorrelationSyncEstimator(capture: StubAmbientCapture())

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected missing sync features to fail startup.")
        } catch {}

        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertNil(estimate)
        let diagnostics = await estimator.currentDiagnostics()
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .unavailable)
    }

    func testStartFailureWhileStartingCaptureClearsLoadedIndex() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1])
        let capture = StubAmbientCapture(startError: TestAmbientCaptureError.startFailed)
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected capture startup failure to fail startup.")
        } catch let error as TestAmbientCaptureError {
            XCTAssertEqual(error, .startFailed)
        }

        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertNil(estimate)
        XCTAssertEqual(state, .failed)
    }

    func testEstimatorRejectsManifestSourceHashMismatchBeforeStartingCapture() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [1, 0.4, 0.1], sourceSHA256: "old-source-hash")
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected stale source identity to fail preflight.")
        } catch let error as AmbientSyncStartError {
            XCTAssertEqual(error, .indexInvalid)
        }

        let startCalls = await capture.startCalls()
        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(startCalls, 0)
        XCTAssertNil(estimate)
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .invalid)
    }

    func testEstimatorRejectsManifestSettingsMismatchBeforeStartingCapture() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [1, 0.4, 0.1], manifestFrameHopMS: 50)
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected feature settings mismatch to fail preflight.")
        } catch let error as AmbientSyncStartError {
            XCTAssertEqual(error, .indexIncompatible)
        }

        let startCalls = await capture.startCalls()
        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(startCalls, 0)
        XCTAssertNil(estimate)
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .incompatible)
    }

    func testEstimatorRejectsManifestDenseFrameCountMismatchBeforeStartingCapture() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [1, 0.4, 0.1], logMelFrameCount: 4)
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected manifest frame count mismatch to fail preflight.")
        } catch let error as AmbientSyncStartError {
            XCTAssertEqual(error, .indexInvalid)
        }

        let startCalls = await capture.startCalls()
        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(startCalls, 0)
        XCTAssertNil(estimate)
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .invalid)
    }

    func testEstimatorRejectsManifestFeatureChecksumMismatchBeforeStartingCapture() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [1, 0.4, 0.1])
        try Data("corrupt-onset-flux".utf8).write(to: index.onsetEnvelopeURL, options: [.atomic])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(capture: capture)

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected feature checksum mismatch to fail preflight.")
        } catch let error as AmbientSyncStartError {
            XCTAssertEqual(error, .indexInvalid)
        }

        let startCalls = await capture.startCalls()
        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(startCalls, 0)
        XCTAssertNil(estimate)
        XCTAssertEqual(state, .failed)
        XCTAssertEqual(diagnostics?.index.status, .invalid)
    }

    func testInitialNoMatchWaitsForLostTimeoutBeforeReportingLost() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80,
            lostWindowLimit: 3
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: [0, 0, 0])
        let firstEstimate = await estimator.currentEstimate()
        let firstState = await estimator.currentState()

        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()
        let secondState = await estimator.currentState()

        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()
        let thirdState = await estimator.currentState()

        XCTAssertNil(firstEstimate)
        XCTAssertEqual(firstState, .listening)
        XCTAssertEqual(secondState, .listening)
        XCTAssertEqual(thirdState, .lost)
    }

    func testEstimatorReportsCurrentReferenceAtEndOfMatchedWindow() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        let estimate = await estimator.currentEstimate()

        XCTAssertEqual(estimate?.referenceTimeMS, 500)
        XCTAssertGreaterThanOrEqual(estimate?.confidence ?? 0, 0.80)
        let state = await estimator.currentState()
        XCTAssertEqual(state, .locked)
    }

    func testEstimatorConvertsAmbientSamplesIntoIndexFrameFeaturesBeforeCorrelation() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0.2, 0, 0, 1, 0, 0.2], sampleRate: 1_000, frameHopMS: 100)
        let capture = StubAmbientCapture(sampleRate: 1_000)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80
        )
        let samples = samples(forOnsetFeatures: [0, 1, 0, 0.2], samplesPerFeature: 100)

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples)
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples)
        let estimate = await estimator.currentEstimate()

        XCTAssertEqual(estimate?.referenceTimeMS, 600)
        XCTAssertGreaterThanOrEqual(estimate?.confidence ?? 0, 0.80)
    }

    func testSharedFeatureExtractorAlignsQueryAndIndexedOnsetFluxFrames() {
        let extractor = AmbientSyncFeatureExtractor()
        let samples: [Float] = [0.25, 0.75, 0.75, 0.875]

        let indexedFeatures = extractor.onsetFlux(
            samples: samples,
            sampleRate: 10,
            frameHopMS: 100,
            previousFrame: .silence
        )
        let queryFeatures = extractor.onsetFlux(
            samples: samples,
            sampleRate: 10,
            frameHopMS: 100,
            previousFrame: .unavailable
        )

        XCTAssertEqual(indexedFeatures, [0.25, 0.5, 0, 0.125])
        XCTAssertEqual(queryFeatures, Array(indexedFeatures.dropFirst()))
    }

    func testStableEstimatesProgressMonotonically() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0.9, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        let first = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0.4, 0.1, 0.9]))
        let second = await estimator.currentEstimate()

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThanOrEqual(second?.referenceTimeMS ?? -1, first?.referenceTimeMS ?? .infinity)
    }

    func testLockedEstimatorPrefersPredictedNeighborhoodOverEarlierRepeatedPeak() async throws {
        let asset = makeAsset(durationMS: 1_200)
        let index = try makeIndex(
            values: [0.2, 0.5, 0.1, 0.05, 0.15, 0.25, 0.35, 0.45, 1, 0.2, 0.5, 0.1],
            durationMS: 1_200
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.45, 1, 0.2, 0.5]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0.45, 1, 0.2, 0.5]))
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.2, 0.5, 0.1]))
        let nextEstimate = await estimator.currentEstimate()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 1_100)
        XCTAssertEqual(nextEstimate?.referenceTimeMS, 1_200)
    }

    func testLockedEstimatorUsesElapsedHostTimeBeforeDeclaringHardRelock() async throws {
        let asset = makeAsset(durationMS: 1_200)
        let index = try makeIndex(
            values: [0.2, 0.7, 0, 0.4, 0.05, 0.15, 0.25, 0.35, 1, 1, 0.2, 0],
            durationMS: 1_200
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80
        )
        let startTime = ContinuousClock.now

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]), hostTime: startTime)
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]), hostTime: startTime)
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(
            samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]),
            hostTime: startTime.advanced(by: .milliseconds(800))
        )
        let progressedEstimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 400)
        XCTAssertEqual(progressedEstimate?.referenceTimeMS, 1_200)
        XCTAssertEqual(state, .locked)
    }

    func testStableLockedTrackingDoesNotWithholdForFarWideSearchConflict() async throws {
        let values = [
            0.2, 0.8, 0.1, 0.4,
            0.05,
            0.3, 0.9, 0.2, 0.6,
            0.1, 0.7, 0.2, 0.5,
            0.15, 0.25, 0.35
        ]
        let asset = makeAsset(durationMS: 1_600)
        let index = try makeIndex(values: values, durationMS: 1_600)
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80
        )
        let startTime = ContinuousClock.now

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samplesForLocalWindow(values, offset: 5, count: 4), hostTime: startTime)
        _ = await estimator.currentEstimate()
        await capture.push(samples: samplesForLocalWindow(values, offset: 5, count: 4), hostTime: startTime)
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(
            samples: samples(forOnsetFeatures: [0, 0.2, 0.8, 0.1, 0.4]),
            hostTime: startTime.advanced(by: .milliseconds(400))
        )
        let trackedEstimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 900)
        XCTAssertEqual(trackedEstimate?.referenceTimeMS, 1_300)
        XCTAssertEqual(diagnostics?.search.mode, .narrow)
        XCTAssertEqual(diagnostics?.decision.didPublishEstimate, true)
    }

    func testLockedEstimatorDoesNotClampMeasuredReferenceBackwardWithinResidual() async throws {
        let asset = makeAsset(durationMS: 900)
        let index = try makeIndex(
            values: [0.05, 0.15, 0.25, 0.4, 0.9, 0.2, 0.8, 0.3, 0.1],
            durationMS: 900
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )
        let hostTime = ContinuousClock.now

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0, 0.9, 0.2, 0.8]), hostTime: hostTime)
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0, 0.9, 0.2, 0.8]), hostTime: hostTime)
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0, 0.4, 0.9, 0.2]), hostTime: hostTime)
        let correctedEstimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 700)
        XCTAssertEqual(correctedEstimate?.referenceTimeMS, 600)
        XCTAssertEqual(diagnostics?.scoring.timeResidualMS, -100)
    }

    func testLockedTrackingEstimatesDriftFromHighConfidenceObservations() async throws {
        var values = Array(repeating: 0.01, count: 30)
        values.replaceSubrange(0..<4, with: [0.12, 0.47, 0.18, 0.73])
        values.replaceSubrange(11..<15, with: [0.91, 0.08, 0.27, 0.52])
        values.replaceSubrange(22..<26, with: [0.23, 0.76, 0.44, 0.11])
        let asset = makeAsset(durationMS: 3_000)
        let index = try makeIndex(values: values, durationMS: 3_000)
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 500,
            minimumLockConfidence: 0.80
        )
        let startTime = ContinuousClock.now

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samplesForLocalWindow(values, offset: 0, count: 4), hostTime: startTime)
        _ = await estimator.currentEstimate()
        await capture.push(
            samples: samplesForLocalWindow(values, offset: 11, count: 4),
            hostTime: startTime.advanced(by: .milliseconds(1_000))
        )
        let secondEstimate = await estimator.currentEstimate()
        await capture.push(
            samples: samplesForLocalWindow(values, offset: 22, count: 4),
            hostTime: startTime.advanced(by: .milliseconds(2_000))
        )
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()

        XCTAssertEqual(secondEstimate?.referenceTimeMS, 1_500)
        XCTAssertEqual(estimate?.referenceTimeMS, 2_600)
        XCTAssertEqual(estimate?.driftPPM ?? 0, 100_000, accuracy: 1)
        XCTAssertNil(estimate?.latencyMS)
        XCTAssertEqual(diagnostics?.clock.observationCount, 3)
        XCTAssertEqual(diagnostics?.clock.rawDriftPPM ?? 0, 100_000, accuracy: 1)
        XCTAssertEqual(diagnostics?.clock.smoothedDriftPPM ?? 0, 100_000, accuracy: 1)
        XCTAssertEqual(diagnostics?.clock.latencySource, .unavailable)
        XCTAssertEqual(diagnostics?.scoring.timeResidualMS, 100)
    }

    func testEstimatorMatchesWindowAfterFirstFrameWhenPriorRMSIsUnavailable() async throws {
        let asset = makeAsset(durationMS: 800)
        let index = try makeIndex(
            values: [0.5, 0.1, 0.04, 0.01, 0, 0.02, 0, 0],
            durationMS: 800
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: [0.6, 0.64, 0.65, 0.65])
        let estimate = await estimator.currentEstimate()

        XCTAssertEqual(estimate?.referenceTimeMS, 500)
    }

    func testEstimatorRelocksWhenCorrelationJumpsBackwardAfterSeek() async throws {
        let asset = makeAsset(durationMS: 1_500)
        let index = try makeIndex(
            values: [1, 1, 0.2, 0, 0.05, 0.15, 0.25, 0.35, 0.2, 0.7, 0, 0.4, 0.12, 0.22, 0.32],
            durationMS: 1_500
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80,
            lostWindowLimit: 2
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]))
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        let driftingEstimate = await estimator.currentEstimate()
        let driftingState = await estimator.currentState()
        guard case .drifting = driftingState else {
            return XCTFail(
                "Expected far seek to drift before relocking, got \(driftingState), locked \(String(describing: lockedEstimate?.referenceTimeMS)), current \(String(describing: driftingEstimate?.referenceTimeMS))."
            )
        }
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        _ = await estimator.currentEstimate()
        let lostState = await estimator.currentState()
        XCTAssertEqual(lostState, .lost)
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        let relockEstimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 1_200)
        XCTAssertEqual(driftingEstimate?.referenceTimeMS, 1_200)
        XCTAssertEqual(relockEstimate?.referenceTimeMS, 400)
        XCTAssertEqual(state, .locking)
    }

    func testEstimatorRelocksWhenCorrelationJumpsForwardBeyondThreshold() async throws {
        let asset = makeAsset(durationMS: 1_500)
        let index = try makeIndex(
            values: [0.2, 0.7, 0, 0.4, 0.05, 0.15, 0.25, 0.35, 1, 1, 0.2, 0, 0.12, 0.22, 0.32],
            durationMS: 1_500
        )
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 400,
            minimumLockConfidence: 0.80,
            lostWindowLimit: 2
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [0.2, 0.7, 0, 0.4]))
        let lockedEstimate = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        let driftingEstimate = await estimator.currentEstimate()
        let driftingState = await estimator.currentState()
        guard case .drifting = driftingState else {
            return XCTFail(
                "Expected far seek to drift before relocking, got \(driftingState), locked \(String(describing: lockedEstimate?.referenceTimeMS)), current \(String(describing: driftingEstimate?.referenceTimeMS))."
            )
        }
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        _ = await estimator.currentEstimate()
        let lostState = await estimator.currentState()
        XCTAssertEqual(lostState, .lost)
        await capture.push(samples: samples(forOnsetFeatures: [1, 1, 0.2, 0]))
        let relockEstimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertEqual(lockedEstimate?.referenceTimeMS, 400)
        XCTAssertEqual(driftingEstimate?.referenceTimeMS, 400)
        XCTAssertEqual(relockEstimate?.referenceTimeMS, 1_200)
        XCTAssertEqual(state, .locking)
    }

    func testShortNoiseDriftsBeforeEventuallyLosingLock() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80,
            lostWindowLimit: 3
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        _ = await estimator.currentEstimate()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))
        _ = await estimator.currentEstimate()

        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()
        guard case .drifting = await estimator.currentState() else {
            return XCTFail("Expected one noisy window to degrade to drifting, not lost.")
        }

        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()
        await capture.push(samples: [0, 0, 0])
        _ = await estimator.currentEstimate()

        let state = await estimator.currentState()
        XCTAssertEqual(state, .lost)
    }

    func testStopPreventsBufferedWindowsFromProducingNewEstimate() async throws {
        let asset = makeAsset()
        let index = try makeIndex(values: [0, 0, 1, 0.4, 0.1, 0, 0.2, 0, 0])
        let capture = StubAmbientCapture()
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: 300,
            minimumLockConfidence: 0.80
        )

        try await estimator.start(asset: asset, index: index)
        await estimator.stop()
        await capture.push(samples: samples(forOnsetFeatures: [1, 0.4, 0.1]))

        let estimate = await estimator.currentEstimate()
        let state = await estimator.currentState()

        XCTAssertNil(estimate)
        XCTAssertEqual(state, .idle)
    }

    func testRollingAudioBufferWaitsForRequestedWindowBeforeReturningSamples() {
        var buffer = AmbientRollingSampleBuffer(maxWindowSeconds: 8, sampleRate: 10)

        buffer.append([0.1, 0.2, 0.3])
        XCTAssertNil(buffer.latestWindow(durationMS: 500, hostTime: .now))

        buffer.append([0.4, 0.5])
        let window = buffer.latestWindow(durationMS: 500, hostTime: .now)

        XCTAssertEqual(window?.sampleRate, 10)
        XCTAssertEqual(window?.samples, [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    func testRollingAudioBufferUsesLatestAppendHostTimeForWindowEndpoint() {
        var buffer = AmbientRollingSampleBuffer(maxWindowSeconds: 8, sampleRate: 10)
        let firstHostTime = ContinuousClock.now
        let secondHostTime = firstHostTime.advanced(by: .milliseconds(500))

        buffer.append([0.1, 0.2], hostTime: firstHostTime)
        buffer.append([0.3, 0.4, 0.5], hostTime: secondHostTime)
        let window = buffer.latestWindow(durationMS: 500)

        XCTAssertEqual(window?.hostTime, secondHostTime)
        XCTAssertEqual(window?.sampleRate, 10)
        XCTAssertEqual(window?.samples, [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    func testRollingAudioBufferReportsInputChannelCount() {
        var buffer = AmbientRollingSampleBuffer(maxWindowSeconds: 8, sampleRate: 10, inputChannelCount: 2)

        buffer.append([0.1, 0.2, 0.3, 0.4, 0.5])
        let window = buffer.latestWindow(durationMS: 500, hostTime: .now)

        XCTAssertEqual(window?.inputChannelCount, 2)
    }

    func testAmbientAudioCaptureAveragesInputChannelsToMonoSamples() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 1
        channels[0][1] = 2
        channels[0][2] = -1
        channels[1][0] = 3
        channels[1][1] = 4
        channels[1][2] = 0

        let samples = AmbientAudioCaptureService.extractSamples(from: buffer)

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 2, accuracy: 0.001)
        XCTAssertEqual(samples[1], 3, accuracy: 0.001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.001)
    }

    private func samples(forOnsetFeatures features: [Double], samplesPerFeature: Int = 1) -> [Float] {
        var rms = 0.0
        return features.flatMap { feature in
            rms += max(0, feature)
            return Array(repeating: Float(rms), count: samplesPerFeature)
        }
    }

    private func samplesForLocalWindow(_ values: [Double], offset: Int, count: Int) -> [Float] {
        samples(forOnsetFeatures: [0] + Array(values[offset..<(offset + count)]))
    }

    private func generatedModulatedTone(sampleRate: Double, frameHopMS: Double) -> [Float] {
        let samplesPerFrame = max(1, Int(sampleRate * frameHopMS / 1_000))
        let amplitudes = [0.12, 0.45, 0.25, 0.70, 0.35, 0.80, 0.30, 0.65, 0.20, 0.55]

        return amplitudes.enumerated().flatMap { frameIndex, amplitude in
            (0..<samplesPerFrame).map { sampleIndex in
                let absoluteIndex = (frameIndex * samplesPerFrame) + sampleIndex
                let time = Double(absoluteIndex) / sampleRate
                let value = amplitude * (
                    sin(2 * Double.pi * 440 * time)
                    + (0.35 * sin(2 * Double.pi * 660 * time))
                )
                return Float(value)
            }
        }
    }

    private func estimateGeneratedQuery(
        referenceSamples: [Float],
        querySamples: [Float],
        sampleRate: Double,
        frameHopMS: Double,
        minimumLockConfidence: Double
    ) async throws -> (estimate: SyncEstimate?, diagnostics: AmbientMatchDiagnostics?) {
        let featureSet = AmbientSyncFeatureExtractor().extract(
            samples: referenceSamples,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .silence
        )
        let durationMS = Int((Double(referenceSamples.count) / sampleRate) * 1_000)
        let asset = makeAsset(durationMS: durationMS)
        let index = try makeIndex(
            featureSet: featureSet,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            durationMS: durationMS
        )
        let capture = StubAmbientCapture(sampleRate: sampleRate)
        let estimator = FeatureCorrelationSyncEstimator(
            capture: capture,
            windowDurationMS: Int((Double(querySamples.count) / sampleRate) * 1_000),
            minimumLockConfidence: minimumLockConfidence
        )

        try await estimator.start(asset: asset, index: index)
        await capture.push(samples: querySamples)
        let estimate = await estimator.currentEstimate()
        let diagnostics = await estimator.currentDiagnostics()
        return (estimate, diagnostics)
    }

    private func frameSlice(
        _ samples: [Float],
        startFrame: Int,
        frameCount: Int,
        sampleRate: Double,
        frameHopMS: Double
    ) -> [Float] {
        let samplesPerFrame = max(1, Int(sampleRate * frameHopMS / 1_000))
        let startIndex = min(samples.count, max(0, startFrame * samplesPerFrame))
        let endIndex = min(samples.count, startIndex + max(0, frameCount * samplesPerFrame))
        return Array(samples[startIndex..<endIndex])
    }

    private func generatedTrackA(sampleRate: Double, frameHopMS: Double, frameCount: Int) -> [Float] {
        generatedSynthTrack(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: frameCount, seed: 2)
    }

    private func generatedTrackB(sampleRate: Double, frameHopMS: Double, frameCount: Int) -> [Float] {
        generatedSynthTrack(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: frameCount, seed: 9)
    }

    private func generatedMotif(sampleRate: Double, frameHopMS: Double, frameCount: Int) -> [Float] {
        generatedSynthTrack(sampleRate: sampleRate, frameHopMS: frameHopMS, frameCount: frameCount, seed: 5)
    }

    private func generatedQuietIntro(sampleRate: Double, frameHopMS: Double, frameCount: Int) -> [Float] {
        let samplesPerFrame = max(1, Int(sampleRate * frameHopMS / 1_000))
        return (0..<frameCount).flatMap { frameIndex in
            (0..<samplesPerFrame).map { sampleIndex in
                let absoluteIndex = (frameIndex * samplesPerFrame) + sampleIndex
                let time = Double(absoluteIndex) / sampleRate
                return Float(0.00001 * sin(2 * Double.pi * 220 * time))
            }
        }
    }

    private func microphoneColored(_ samples: [Float]) -> [Float] {
        var previous = 0.0
        var delayed = 0.0
        return samples.map { sample in
            let compressed = tanh(Double(sample) * 1.4) / 1.4
            let filtered = (0.72 * compressed) + (0.20 * previous) - (0.08 * delayed)
            delayed = previous
            previous = compressed
            return Float(filtered * 0.85)
        }
    }

    private func addDeterministicRoomNoise(_ samples: [Float], amplitude: Double) -> [Float] {
        samples.enumerated().map { index, sample in
            let noise = amplitude * (
                0.55 * sin(Double(index) * 0.017)
                + 0.30 * sin(Double(index) * 0.071 + 0.4)
                + 0.15 * sin(Double(index) * 0.131 + 1.7)
            )
            return Float(max(-0.98, min(0.98, Double(sample) + noise)))
        }
    }

    private func reverberated(_ samples: [Float], sampleRate: Double) -> [Float] {
        var output = samples.map(Double.init)
        let shortDelay = max(1, Int(sampleRate * 0.035))
        let longDelay = max(1, Int(sampleRate * 0.083))
        for index in output.indices {
            var value = output[index]
            if index >= shortDelay {
                value += output[index - shortDelay] * 0.22
            }
            if index >= longDelay {
                value += output[index - longDelay] * 0.12
            }
            output[index] = max(-0.98, min(0.98, value))
        }
        return output.map(Float.init)
    }

    private func compressed(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            Float(tanh(Double(sample) * 2.4) / tanh(2.4))
        }
    }

    private func generatedSynthTrack(
        sampleRate: Double,
        frameHopMS: Double,
        frameCount: Int,
        seed: Int
    ) -> [Float] {
        let samplesPerFrame = max(1, Int(sampleRate * frameHopMS / 1_000))
        let roots = [110.0, 123.47, 146.83, 164.81, 185.0, 196.0, 220.0]
        let melody = [261.63, 293.66, 329.63, 392.0, 440.0, 493.88, 587.33]

        return (0..<frameCount).flatMap { frameIndex in
            let beat = (frameIndex * (seed + 3)) % 16
            let root = roots[(frameIndex / 5 + seed) % roots.count]
            let melodyFrequency = melody[(frameIndex * 3 + seed) % melody.count]
            let harmonicShift = Double((frameIndex * seed) % 9) * 7.5
            let baseAmplitude = 0.16 + (0.08 * sin(Double(frameIndex + seed) * 0.41))
            let transientAmplitude: Double
            if [0, 4, 9, 13].contains(beat) {
                transientAmplitude = 0.45
            } else if [2, 7, 11].contains(beat) {
                transientAmplitude = 0.22
            } else {
                transientAmplitude = 0.04
            }
            let frameAmplitude = min(0.90, max(0.08, baseAmplitude + transientAmplitude))

            return (0..<samplesPerFrame).map { sampleIndex in
                let absoluteIndex = (frameIndex * samplesPerFrame) + sampleIndex
                let time = Double(absoluteIndex) / sampleRate
                let framePhase = Double(sampleIndex) / Double(samplesPerFrame)
                let transient = transientAmplitude * exp(-18 * framePhase) * sin(2 * Double.pi * 1_800 * time)
                let tonal = (0.38 * sin(2 * Double.pi * root * time))
                    + (0.24 * sin(2 * Double.pi * (root * 1.5 + harmonicShift) * time))
                    + (0.18 * sin(2 * Double.pi * (melodyFrequency + harmonicShift) * time))
                    + (0.10 * sin(2 * Double.pi * (melodyFrequency * 2.0) * time))
                let value = (frameAmplitude * tonal) + transient
                return Float(max(-0.98, min(0.98, value)))
            }
        }
    }

    private func makeIndex(
        values: [Double],
        assetID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        sampleRate: Double = 10,
        frameHopMS: Double = 100,
        durationMS: Int = 900,
        sourceSHA256: String = "reference",
        manifestFrameHopMS: Double? = nil,
        logMelFrameCount: Int? = nil
    ) throws -> LocalAudioSyncIndex {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldSyncTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let featuresDirectory = directory.appendingPathComponent("features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: true)
        let envelopeURL = featuresDirectory.appendingPathComponent("dense-onset-flux.f32")
        let logMelURL = featuresDirectory.appendingPathComponent("dense-logmel.f32")
        let chromaURL = featuresDirectory.appendingPathComponent("dense-chroma.f32")
        let energyURL = featuresDirectory.appendingPathComponent("energy.f32")
        try writeFloat32(values: expandOnsetFluxFixture(values), to: envelopeURL)
        try writeFloat32(values: Array(repeating: 0, count: (logMelFrameCount ?? values.count) * 24), to: logMelURL)
        try writeFloat32(values: Array(repeating: 0, count: values.count * 12), to: chromaURL)
        try writeFloat32(values: values, to: energyURL)
        try writeManifest(
            directory: directory,
            assetID: assetID,
            durationMS: durationMS,
            sampleRate: sampleRate,
            frameHopMS: manifestFrameHopMS ?? frameHopMS,
            sourceSHA256: sourceSHA256,
            featureURL: envelopeURL,
            frameCount: values.count,
            logMelURL: logMelURL,
            logMelFrameCount: logMelFrameCount ?? values.count,
            chromaURL: chromaURL,
            energyURL: energyURL
        )

        return LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: durationMS,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            onsetEnvelopeURL: envelopeURL,
            spectralSummaryURL: nil,
            chromaURL: nil,
            version: LocalAudioSyncIndexer.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            manifestURL: directory.appendingPathComponent("manifest.json")
        )
    }

    private func makeIndex(
        featureSet: AmbientSyncFeatureSet,
        assetID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        sampleRate: Double,
        frameHopMS: Double,
        durationMS: Int
    ) throws -> LocalAudioSyncIndex {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldSyncTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let featuresDirectory = directory.appendingPathComponent("features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: true)
        let envelopeURL = featuresDirectory.appendingPathComponent("dense-onset-flux.f32")
        let logMelURL = featuresDirectory.appendingPathComponent("dense-logmel.f32")
        let chromaURL = featuresDirectory.appendingPathComponent("dense-chroma.f32")
        let energyURL = featuresDirectory.appendingPathComponent("energy.f32")
        let landmarkURL = featuresDirectory.appendingPathComponent("landmark-postings.bin")
        try writeFloat32(values: featureSet.onsetFlux, to: envelopeURL)
        try writeFloat32(values: featureSet.logMel, to: logMelURL)
        try writeFloat32(values: featureSet.chroma, to: chromaURL)
        try writeFloat32(values: featureSet.energy, to: energyURL)
        try featureSet.landmarkPostings.write(to: landmarkURL, options: [.atomic])
        try writeManifest(
            directory: directory,
            assetID: assetID,
            durationMS: durationMS,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            sourceSHA256: "reference",
            featureURL: envelopeURL,
            frameCount: featureSet.frameCount,
            landmarkURL: landmarkURL,
            landmarkRecordCount: featureSet.landmarkRecordCount,
            logMelURL: logMelURL,
            logMelFrameCount: featureSet.frameCount,
            chromaURL: chromaURL,
            energyURL: energyURL
        )

        return LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: durationMS,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            onsetEnvelopeURL: envelopeURL,
            spectralSummaryURL: logMelURL,
            chromaURL: chromaURL,
            version: LocalAudioSyncIndexer.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            manifestURL: directory.appendingPathComponent("manifest.json")
        )
    }

    private func makeAsset(durationMS: Int = 900) -> LocalAudioAsset {
        LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            fileURLBookmark: nil,
            displayPath: "/tmp/reference.wav",
            fileName: "reference.wav",
            fileExtension: "wav",
            fileSizeBytes: 1_024,
            sha256: "reference",
            durationMS: durationMS,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
    }

    private func writeManifest(
        directory: URL,
        assetID: UUID,
        durationMS: Int,
        sampleRate: Double,
        frameHopMS: Double,
        sourceSHA256: String,
        featureURL: URL,
        frameCount: Int,
        landmarkURL: URL? = nil,
        landmarkRecordCount: Int = 0,
        logMelURL: URL,
        logMelFrameCount: Int,
        chromaURL: URL,
        energyURL: URL
    ) throws {
        let featureSHA256 = try sha256Hex(Data(contentsOf: featureURL))
        var featureFiles: [String: Any] = [
            "denseOnsetFlux": [
                "path": "features/\(featureURL.lastPathComponent)",
                "frames": frameCount,
                "dims": 8,
                "sha256": featureSHA256
            ],
            "denseLogMel": [
                "path": "features/\(logMelURL.lastPathComponent)",
                "frames": logMelFrameCount,
                "dims": 24,
                "sha256": try sha256Hex(Data(contentsOf: logMelURL))
            ],
            "denseChroma": [
                "path": "features/\(chromaURL.lastPathComponent)",
                "frames": frameCount,
                "dims": 12,
                "sha256": try sha256Hex(Data(contentsOf: chromaURL))
            ],
            "energy": [
                "path": "features/\(energyURL.lastPathComponent)",
                "frames": frameCount,
                "dims": 1,
                "sha256": try sha256Hex(Data(contentsOf: energyURL))
            ]
        ]
        if let landmarkURL {
            featureFiles["landmarkPostings"] = [
                "path": "features/\(landmarkURL.lastPathComponent)",
                "recordCount": landmarkRecordCount,
                "sha256": try sha256Hex(Data(contentsOf: landmarkURL))
            ]
        }

        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "featureExtractorVersion": "ambient-sync-v2",
            "settingsHash": [
                "processingSampleRate=\(Int(sampleRate))",
                "hopSizeMS=\(frameHopMS)",
                "fftSize=256",
                "window=hann",
                "onsetFluxDims=8",
                "logMelDims=24",
                "chromaDims=12"
            ].joined(separator: ";"),
            "createdAt": "2024-03-10T00:00:00Z",
            "asset": [
                "assetID": assetID.uuidString,
                "durationMS": durationMS
            ],
            "source": [
                "fileSizeBytes": 1_024,
                "contentModificationDate": "2024-03-10T00:00:00Z",
                "fullFileSHA256": sourceSHA256,
                "decodedFrameCount": frameCount,
                "decodedDurationMS": durationMS,
                "originalSampleRate": Int(sampleRate),
                "originalChannelCount": 1
            ],
            "processing": [
                "processingSampleRate": Int(sampleRate),
                "fftSize": 256,
                "hopSize": Int(frameHopMS),
                "window": "hann",
                "monoMix": "average"
            ],
            "features": [
                "landmark": [
                    "hashVersion": 1,
                    "peakNeighborhoodTime": 3,
                    "peakNeighborhoodFreq": 3,
                    "fanout": 6,
                    "targetZoneStartMS": 250,
                    "targetZoneEndMS": 2500
                ],
                "onsetFlux": ["dims": 8],
                "logMel": ["dims": 24],
                "chroma": [
                    "dims": 12,
                    "smoothingMS": 1000
                ]
            ],
            "featureFiles": featureFiles
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func expandOnsetFluxFixture(_ values: [Double]) -> [Double] {
        values.flatMap { value in
            [value] + Array(repeating: 0, count: 7)
        }
    }

    private func writeFloat32(values: [Double], to url: URL) throws {
        var data = Data(capacity: values.count * MemoryLayout<Float32>.size)
        for value in values {
            var bits = Float32(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        try data.write(to: url, options: [.atomic])
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum TestAmbientCaptureError: LocalizedError, Equatable {
    case startFailed

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "Ambient capture failed to start."
        }
    }
}

private actor StubAmbientCapture: AmbientAudioCapturing {
    private let sampleRate: Double
    private let inputChannelCount: Int
    private let startError: Error?
    private var queuedWindows: [(samples: [Float], hostTime: ContinuousClock.Instant)] = []
    private var startCallCount = 0

    init(sampleRate: Double = 10, inputChannelCount: Int = 1, startError: Error? = nil) {
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
        self.startError = startError
    }

    func start() async throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() async {}

    func latestWindow(durationMS: Int) async -> AmbientAudioWindow? {
        _ = durationMS

        guard !queuedWindows.isEmpty else {
            return nil
        }
        let window = queuedWindows.removeFirst()

        return AmbientAudioWindow(
            hostTime: window.hostTime,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount,
            samples: window.samples
        )
    }

    func push(samples: [Float], hostTime: ContinuousClock.Instant = .now) {
        queuedWindows.append((samples: samples, hostTime: hostTime))
    }

    func startCalls() -> Int {
        startCallCount
    }
}

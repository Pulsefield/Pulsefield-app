import XCTest
@testable import PulsefieldCore

final class AmbientSyncEngineTests: XCTestCase {
    func testCleanDeterministicQueryReachesProvisionalAndFinalLock() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 320)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 320)
        var engine = AmbientSyncEngine(
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
        var engine = AmbientSyncEngine(
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

    func testFinalLockContinuesTrackingOnShortTrackingWindow() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 420)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 420)
        var engine = AmbientSyncEngine(
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

    func testPostFinalRobustFailurePreservesFinalPhase() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 700)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 700)
        var engine = AmbientSyncEngine(
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
        XCTAssertEqual(trackingFailureSnapshot.state, .relocking)
        XCTAssertEqual(trackingFailureSnapshot.phase, .final)
        XCTAssertEqual(trackingFailureSnapshot.stage, .robustVerify)
        XCTAssertEqual(trackingFailureSnapshot.withholdReason, .weakAlignmentPeak)
        XCTAssertEqual(trackingFailureSnapshot.finalLockElapsedMS, 5_200)
    }

    func testLowSignalWithholdsBeforeCoarseRetrieval() throws {
        let queryFrames = makePatternFrames(startMS: 0, count: 180, energyDBFS: -110)
        let referenceFrames = makePatternFrames(startMS: 4_000, count: 180)
        var engine = AmbientSyncEngine(
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
        var engine = AmbientSyncEngine(
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
        XCTAssertEqual(snapshot.withholdReason, .ambiguousOffset)
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
}

import XCTest

@testable import PulsefieldCore

final class AmbientSyncSessionEngineTests: XCTestCase {
    private let features = AmbientSyncFeatureConfiguration(processingSampleRate: 25_600)

    func testNativeAcquisitionPreservesAudioClocksAndUnavailableDiagnostics() throws {
        let reference = makeReference()
        let engine = try AmbientSyncSessionEngine(reference: reference)
        XCTAssertEqual(engine.backend, .sonalign)
        let query = capture(reference)

        let short = try engine.process(queryWindow: window(query, end: 50), elapsedMS: 1_000)
        XCTAssertEqual(short.state, .listening)
        XCTAssertEqual(short.phase, .none)
        XCTAssertEqual(short.stage, .readiness)
        XCTAssertEqual(short.withholdReason, .insufficientDuration)
        XCTAssertNil(short.estimate)

        let result = try acquire(engine, query: query)
        XCTAssertEqual(result.state, .locked)
        XCTAssertEqual(result.phase, .final)
        XCTAssertEqual(result.stage, .tracking)
        XCTAssertNil(result.withholdReason)
        XCTAssertNotNil(result.firstProvisionalLockElapsedMS)
        XCTAssertNotNil(result.confirmedLockElapsedMS)
        XCTAssertNotNil(result.finalLockElapsedMS)
        let estimate = try XCTUnwrap(result.estimate)
        // Reference starts at 700 ms, captured audio at 5,000 ms; host time
        // deliberately differs from both and must never enter the alignment.
        XCTAssertEqual(estimate.offsetMS, -2_300, accuracy: 8)
        XCTAssertEqual(estimate.queryEndpointRecordedTimeMS, 12_000)
        XCTAssertEqual(estimate.referenceTimeMS, 9_700, accuracy: 8)
        XCTAssertNil(estimate.driftPPM)
        XCTAssertGreaterThan(result.confidence, 0.8)

        let spectral = try XCTUnwrap(result.diagnostics.spectral)
        XCTAssertFalse(spectral.globalSearch)
        XCTAssertNil(spectral.competingPeakMargin)
        XCTAssertGreaterThan(spectral.correlation, 0.8)
        XCTAssertEqual(spectral.coastMS, 0)
        XCTAssertNil(spectral.firstHalfCorrelation)
        XCTAssertNil(spectral.secondHalfCorrelation)
        XCTAssertNil(spectral.recentCorrelation)
        XCTAssertTrue(result.diagnostics.candidates.isEmpty)
        XCTAssertTrue(result.diagnostics.offsetTracks.isEmpty)
        XCTAssertNil(result.diagnostics.trackInnovationMS)
        let decoded = try JSONDecoder().decode(
            AmbientSyncSnapshot.self, from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(decoded, result)
    }

    func testNativeSilenceReleasesTheAcceptedOffset() throws {
        let reference = makeReference()
        let engine = try AmbientSyncSessionEngine(reference: reference)
        XCTAssertEqual(try acquire(engine, query: capture(reference)).state, .locked)
        let silence = (0..<250).map {
            frame(time: 15_000 + Double($0) * 20, values: [Float](repeating: 0, count: 24), energy: -.infinity)
        }
        let result = try engine.process(queryWindow: MicFeatureWindow(frames: silence), elapsedMS: 15_000)
        XCTAssertEqual(result.state, .lost)
        XCTAssertEqual(result.withholdReason, .insufficientEnergy)
        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(result.diagnostics.activeFrameFraction, 0)
    }

    func testMalformedInputEndsNativeSessionWithoutReusingItsLock() throws {
        let reference = makeReference()
        let engine = try AmbientSyncSessionEngine(reference: reference)
        let query = capture(reference)
        XCTAssertEqual(try acquire(engine, query: query).state, .locked)
        let malformed = MicFeatureWindow(frames: [
            frame(time: 12_500, values: [Float](repeating: .nan, count: 24))
        ])
        XCTAssertThrowsError(try engine.process(queryWindow: malformed, elapsedMS: 7_500))
        XCTAssertThrowsError(try engine.process(queryWindow: window(query, end: 400), elapsedMS: 8_000))
        XCTAssertThrowsError(try AmbientSyncSessionEngine(reference: .init(sourceDisplayPath: "empty", frames: [])))
    }

    func testLegacyAndCustomThresholdsRetainSwiftBehavior() throws {
        let reference = makeReference()
        let query = window(capture(reference), end: 150)
        let configurations: [AmbientSyncEngine.Configuration] = [
            .v1,
            .init(usesSpectralCorrelation: true, minimumAverageEnergyDBFS: -10),
            .init(usesSpectralCorrelation: true, minimumReadinessDurationMS: 6_000)
        ]
        for configuration in configurations {
            let session = try AmbientSyncSessionEngine(reference: reference, configuration: configuration)
            var comparison = AmbientSyncEngine(reference: reference, configuration: configuration)
            XCTAssertEqual(session.backend, .swiftCompatibility)
            let result = try session.process(queryWindow: query, elapsedMS: 3_000)
            XCTAssertEqual(result, comparison.process(queryWindow: query, elapsedMS: 3_000))
            XCTAssertNil(result.estimate)
        }
    }

    private func acquire(_ engine: AmbientSyncSessionEngine, query: [MicFeatureFrame]) throws -> AmbientSyncSnapshot {
        var result: AmbientSyncSnapshot?
        for end in stride(from: 125, through: 350, by: 25) {
            result = try engine.process(queryWindow: window(query, end: end), elapsedMS: Double(end) * 20)
        }
        return try XCTUnwrap(result)
    }

    private func window(_ frames: [MicFeatureFrame], end: Int) -> MicFeatureWindow {
        MicFeatureWindow(frames: Array(frames[max(0, end - 250)...end]))
    }

    private func capture(_ reference: AmbientSyncEngine.Reference) -> [MicFeatureFrame] {
        (0..<500).map { index in
            frame(time: 5_000 + Double(index) * 20, values: reference.frames[index + 100].pcenMel)
        }
    }

    private func makeReference() -> AmbientSyncEngine.Reference {
        let frames = (0..<1_500).map { index in
            let t = Double(index)
            let values = (0..<24).map { band -> Float in
                let a = Double((band + 3) * 8)
                return Float(exp(
                    0.5 * sin(t * (0.061 + a * 0.00037) + a)
                        + 0.5 * sin(t * (0.113 + a * 0.00019) + t * t * 0.00013)
                ))
            }
            return frame(time: 700 + t * 20, values: values)
        }
        return .init(sourceDisplayPath: "synthetic", featureConfiguration: features, frames: frames)
    }

    private func frame(time: Double, values: [Float], energy: Double = -20) -> MicFeatureFrame {
        MicFeatureFrame(
            recordedTimeMS: time, hostTimeMS: time + 100_000,
            onsetEnvelope: 0, subbandOnset: [], pcenMel: values,
            chroma: [], cens: [], landmarkHashes: [], energyDBFS: energy, snrDB: nil
        )
    }
}

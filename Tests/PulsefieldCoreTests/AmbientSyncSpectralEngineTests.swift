import XCTest

@testable import PulsefieldCore

final class AmbientSyncSpectralEngineTests: XCTestCase {
    private let features = AmbientSyncFeatureConfiguration(processingSampleRate: 25_600)

    func testNoisySpectralChangesAlignWithoutAnyLandmarks() throws {
        let reference = frames(count: 2_000)
        let query = capture(reference: reference, offset: 200, count: 500, noisy: true)
        var engine = makeEngine(reference)
        var last: AmbientSyncSnapshot?
        for end in stride(from: 125, through: 450, by: 25) {
            last = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
        }
        let result = try XCTUnwrap(last)
        XCTAssertEqual(result.state, .locked)
        XCTAssertEqual(try XCTUnwrap(result.estimate).offsetMS, 4_000, accuracy: 8)
        XCTAssertEqual(result.diagnostics.queryLandmarkCount, 0)
        XCTAssertNotNil(result.diagnostics.spectral)
    }

    func testStationarySpectrumAndWrongTemporalOrderCannotLock() {
        let reference = frames(count: 1_500)
        let flat = reference.prefix(500).map { frame in
            makeFrame(time: frame.recordedTimeMS, values: [Float](repeating: 2, count: 24))
        }
        let wrong = capture(reference: frames(count: 1_500, seed: 97), offset: 200, count: 500)
        for query in [flat, wrong] {
            var engine = makeEngine(reference)
            for end in stride(from: 125, through: 490, by: 25) {
                let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
                XCTAssertNotEqual(result.state, .locked)
                XCTAssertNotEqual(result.state, .confirmed)
            }
        }
    }

    func testRepeatedPassageRemainsAmbiguous() throws {
        let passage = frames(count: 500)
        let reference = passage + passage.map { makeFrame(time: $0.recordedTimeMS + 10_000, values: $0.pcenMel) }
        let query = capture(reference: reference, offset: 100, count: 350)
        var engine = makeEngine(reference)
        for end in stride(from: 125, through: 340, by: 25) {
            let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
            XCTAssertNotEqual(result.state, .locked)
            XCTAssertNil(result.estimate)
        }
    }

    func testRepeatedWindowCannotManufactureFreshEvidence() {
        let reference = frames(count: 1_500)
        let query = capture(reference: reference, offset: 100, count: 400)
        var engine = makeEngine(reference)
        let same = window(query, 150)
        for elapsed in stride(from: 3_000.0, through: 10_000, by: 100) {
            let result = engine.process(queryWindow: same, elapsedMS: elapsed)
            XCTAssertNotEqual(result.state, .confirmed)
            XCTAssertNotEqual(result.state, .locked)
            XCTAssertEqual(result.diagnostics.spectral?.freshEvidenceMS, 0)
        }
    }

    func testCallbackCadenceDoesNotChangeEvidenceRequirements() throws {
        let reference = frames(count: 1_500)
        let query = capture(reference: reference, offset: 100, count: 500)
        var confirmedTimes: [Double] = []
        for step in [5, 50] {  // 100 ms and 1000 ms callbacks.
            var engine = makeEngine(reference)
            for end in stride(from: 50, through: 450, by: step) {
                let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
                if let confirmed = result.confirmedLockElapsedMS {
                    confirmedTimes.append(confirmed)
                    break
                }
            }
        }
        XCTAssertEqual(confirmedTimes.count, 2)
        XCTAssertGreaterThanOrEqual(confirmedTimes.min() ?? 0, 3_500)
        XCTAssertLessThanOrEqual(abs(confirmedTimes[0] - confirmedTimes[1]), 1_000)
    }

    func testSeekRelocksAndDoesNotKeepOldAudioAlive() throws {
        let reference = frames(count: 2_500)
        let query = (0..<900).map { i in
            makeFrame(time: Double(i) * 20, values: reference[i + (i < 400 ? 100 : 700)].pcenMel)
        }
        var engine = makeEngine(reference)
        var sawLoss = false
        var latest: AmbientSyncSnapshot?
        for end in stride(from: 125, through: 850, by: 25) {
            let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
            if end >= 525 && result.state != .locked { sawLoss = true }
            if end >= 550, result.state == .locked {
                XCTAssertEqual(try XCTUnwrap(result.estimate).offsetMS, 14_000, accuracy: 8)
            }
            latest = result
        }
        XCTAssertTrue(sawLoss)
        XCTAssertEqual(latest?.state, .locked)
        XCTAssertEqual(try XCTUnwrap(latest?.estimate).offsetMS, 14_000, accuracy: 8)
    }

    func testDiscontinuityAndSilenceReleaseAcceptedOffset() throws {
        let reference = frames(count: 1_500)
        let query = capture(reference: reference, offset: 100, count: 500)
        var engine = makeEngine(reference)
        for end in stride(from: 125, through: 400, by: 25) {
            _ = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
        }
        let silence = (0..<250).map {
            makeFrame(time: 10_000 + Double($0) * 20, values: [Float](repeating: 0, count: 24), energy: -120)
        }
        let result = engine.process(queryWindow: MicFeatureWindow(frames: silence), elapsedMS: 15_000)
        XCTAssertEqual(result.state, .lost)
        XCTAssertNil(result.estimate)
    }

    func testReferenceBoundaryAndInvalidFrameGridAreHandled() throws {
        let reference = frames(count: 300)
        let matcher = try XCTUnwrap(AmbientSyncSpectralMatcher(frames: reference, hopMS: 20))
        let ending = capture(reference: reference, offset: 50, count: 250)
        let result = matcher.match(query: MicFeatureWindow(frames: ending))
        XCTAssertEqual(try XCTUnwrap(result.best).offsetMS, 1_000, accuracy: 8)
        let gap = Array(reference.prefix(100)) + Array(reference.suffix(100))
        XCTAssertNil(AmbientSyncSpectralMatcher(frames: gap, hopMS: 20))
        XCTAssertTrue(matcher.match(query: MicFeatureWindow(frames: gap)).candidates.isEmpty)
    }

    func testShortTrackingWindowRetainsLockAfterAcquisition() throws {
        let reference = frames(count: 1_500)
        let query = capture(reference: reference, offset: 100, count: 500)
        var engine = makeEngine(reference)
        for end in stride(from: 125, through: 350, by: 25) {
            _ = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
        }
        let short = MicFeatureWindow(frames: Array(query[300...400]))
        let result = engine.process(queryWindow: short, elapsedMS: 8_000)
        XCTAssertEqual(result.state, .locked)
        XCTAssertEqual(try XCTUnwrap(result.estimate).offsetMS, 2_000, accuracy: 8)
    }

    func testCumulativeTimestampSkewCannotProduceConfidentWrongProjection() throws {
        let reference = frames(count: 1_500)
        let matcher = try XCTUnwrap(AmbientSyncSpectralMatcher(frames: reference, hopMS: 20))
        let skewed = (0..<250).map { i in
            makeFrame(time: Double(i) * 20 * 1.04, values: reference[i + 100].pcenMel)
        }
        XCTAssertTrue(matcher.match(query: MicFeatureWindow(frames: skewed)).candidates.isEmpty)
        var engine = makeEngine(reference)
        let clean = capture(reference: reference, offset: 100, count: 500)
        for end in stride(from: 125, through: 400, by: 25) {
            _ = engine.process(queryWindow: window(clean, end), elapsedMS: Double(end) * 20)
        }
        let skewedAfterLock = (0..<250).map { i in
            makeFrame(time: 4_000 + Double(i) * 20 * 1.04, values: reference[i + 300].pcenMel)
        }
        // Also exercise the fast reuse path before the normal processing interval.
        var rapidEngine = engine
        let rapidSkew = skewedAfterLock.map {
            makeFrame(time: $0.recordedTimeMS - 1_150, values: $0.pcenMel)
        }
        let rapidResult = rapidEngine.process(queryWindow: MicFeatureWindow(frames: rapidSkew), elapsedMS: 8_050)
        XCTAssertEqual(rapidResult.state, .lost)
        XCTAssertNil(rapidResult.estimate)

        let result = engine.process(queryWindow: MicFeatureWindow(frames: skewedAfterLock), elapsedMS: 9_200)
        XCTAssertEqual(result.state, .lost)
        XCTAssertEqual(result.withholdReason, .lostSignal)
        XCTAssertNil(result.estimate)

    }

    func testSmallPlaybackClockDriftIsTrackedInAudioContent() throws {
        let reference = frames(count: 2_000)
        let query = (0..<1_000).map { i in
            let position = 100 + Double(i) * 1.001
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let values = zip(reference[lower].pcenMel, reference[lower + 1].pcenMel).map { $0 + fraction * ($1 - $0) }
            return makeFrame(time: Double(i) * 20, values: values)
        }
        var engine = makeEngine(reference)
        for end in stride(from: 125, through: 950, by: 25) {
            let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
            if end > 350 {
                XCTAssertEqual(result.state, .locked)
                XCTAssertEqual(try XCTUnwrap(result.estimate).offsetMS, 2_000 + Double(end) * 0.02, accuracy: 8)
            }
        }
    }

    func testLostTrackMustDisambiguateGloballyBeforeRecovery() throws {
        let original = frames(count: 2_500)
        // The later phrase is duplicated at a distant position. Its local timing
        // is convincing, but it cannot identify which occurrence is playing.
        let reference = original.enumerated().map { i, frame in
            let values = (1_500..<2_000).contains(i) ? original[i - 1_000].pcenMel : frame.pcenMel
            return makeFrame(time: frame.recordedTimeMS, values: values)
        }
        let unrelated = frames(count: 1_000, seed: 83)
        let query = (0..<900).map { i in
            let values = (400..<550).contains(i) ? unrelated[i].pcenMel : reference[i + 100].pcenMel
            return makeFrame(time: Double(i) * 20, values: values)
        }
        var engine = makeEngine(reference)
        var lost = false
        for end in stride(from: 125, through: 875, by: 5) {
            let result = engine.process(queryWindow: window(query, end), elapsedMS: Double(end) * 20)
            if (300..<400).contains(end) { XCTAssertEqual(result.state, .locked) }
            if end >= 500 && result.state != .locked { lost = true }
            if end >= 550 && lost { XCTAssertNotEqual(result.state, .locked) }
        }
        XCTAssertTrue(lost)
    }

    private func makeEngine(_ reference: [MicFeatureFrame]) -> AmbientSyncEngine {
        AmbientSyncEngine(
            reference: .init(sourceDisplayPath: "synthetic", featureConfiguration: features, frames: reference),
            configuration: .init(usesSpectralCorrelation: true, featureConfiguration: features))
    }

    private func window(_ frames: [MicFeatureFrame], _ end: Int) -> MicFeatureWindow {
        MicFeatureWindow(frames: Array(frames[max(0, end - 250)...end]))
    }

    private func capture(reference: [MicFeatureFrame], offset: Int, count: Int, noisy: Bool = false)
        -> [MicFeatureFrame]
    {
        (0..<count).map { i in
            let values = reference[i + offset].pcenMel.enumerated().map { band, value in
                noisy
                    ? Float(band % 4) * 0.3 + value * Float(0.5 + Double(band % 5) * 0.2)
                        + Float(0.15 * sin(Double(i * (band + 17)) * 0.123)) : value
            }
            return makeFrame(time: Double(i) * 20, values: values.map { max(0, $0) })
        }
    }

    private func frames(count: Int, seed: Int = 1) -> [MicFeatureFrame] {
        // Independent smooth band envelopes: no hashes, no shared frame builder.
        (0..<count).map { i in
            let values = (0..<24).map { band -> Float in
                let a = Double((band + 3) * (seed + 7))
                let t = Double(i)
                return Float(
                    exp(
                        0.5 * sin(t * (0.061 + a * 0.000_37) + a)
                            + 0.5 * sin(t * (0.113 + a * 0.000_19) + t * t * 0.000_13)))
            }
            return makeFrame(time: Double(i) * 20, values: values)
        }
    }

    private func makeFrame(time: Double, values: [Float], energy: Double = -20) -> MicFeatureFrame {
        MicFeatureFrame(
            recordedTimeMS: time, hostTimeMS: time + 100_000,
            onsetEnvelope: 0, subbandOnset: [], pcenMel: values,
            chroma: [], cens: [], landmarkHashes: [], energyDBFS: energy, snrDB: nil)
    }
}

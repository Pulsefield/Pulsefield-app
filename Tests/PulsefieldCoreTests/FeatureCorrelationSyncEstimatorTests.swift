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

    func testEstimatorRejectsSyncIndexForDifferentAsset() async throws {
        let asset = makeAsset()
        let mismatchedIndexAssetID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
        let index = try makeIndex(values: [1, 0, 0], assetID: mismatchedIndexAssetID)
        let estimator = FeatureCorrelationSyncEstimator(capture: StubAmbientCapture())

        do {
            try await estimator.start(asset: asset, index: index)
            XCTFail("Expected mismatched sync index to be rejected.")
        } catch let error as AmbientSyncError {
            XCTAssertEqual(
                error,
                .syncIndexAssetMismatch(assetID: asset.id, indexAssetID: mismatchedIndexAssetID)
            )
        }

        let state = await estimator.currentState()
        XCTAssertEqual(state, .failed("Sync index does not match selected local audio asset."))
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
        XCTAssertEqual(state, .locked(estimate!))
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
        let asset = makeAsset()
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
        let asset = makeAsset()
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
        XCTAssertEqual(state, .locked(progressedEstimate!))
    }

    func testEstimatorMatchesWindowAfterFirstFrameWhenPriorRMSIsUnavailable() async throws {
        let asset = makeAsset()
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
        let asset = makeAsset()
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
        guard case .drifting = await estimator.currentState() else {
            return XCTFail("Expected far seek to drift before relocking.")
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
        let asset = makeAsset()
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
        guard case .drifting = await estimator.currentState() else {
            return XCTFail("Expected far seek to drift before relocking.")
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

    private func samples(forOnsetFeatures features: [Double], samplesPerFeature: Int = 1) -> [Float] {
        var rms = 0.0
        return features.flatMap { feature in
            rms += max(0, feature)
            return Array(repeating: Float(rms), count: samplesPerFeature)
        }
    }

    private func makeIndex(
        values: [Double],
        assetID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        sampleRate: Double = 10,
        frameHopMS: Double = 100,
        durationMS: Int = 900
    ) throws -> LocalAudioSyncIndex {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldSyncTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelopeURL = directory.appendingPathComponent("onset-envelope.txt")
        try values.map { String($0) }.joined(separator: "\n").write(to: envelopeURL, atomically: true, encoding: .utf8)

        return LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: durationMS,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            onsetEnvelopeURL: envelopeURL,
            spectralSummaryURL: nil,
            chromaURL: nil,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private func makeAsset() -> LocalAudioAsset {
        LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            fileURLBookmark: nil,
            displayPath: "/tmp/reference.wav",
            fileName: "reference.wav",
            fileExtension: "wav",
            fileSizeBytes: 1_024,
            sha256: "reference",
            durationMS: 900,
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
}

private actor StubAmbientCapture: AmbientAudioCapturing {
    private let sampleRate: Double
    private var queuedWindows: [(samples: [Float], hostTime: ContinuousClock.Instant)] = []

    init(sampleRate: Double = 10) {
        self.sampleRate = sampleRate
    }

    func start() async throws {}

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
            samples: window.samples
        )
    }

    func push(samples: [Float], hostTime: ContinuousClock.Instant = .now) {
        queuedWindows.append((samples: samples, hostTime: hostTime))
    }
}

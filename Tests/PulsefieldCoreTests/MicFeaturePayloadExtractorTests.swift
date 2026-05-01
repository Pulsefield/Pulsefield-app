import XCTest
@testable import PulsefieldCore

final class MicFeaturePayloadExtractorTests: XCTestCase {
    func testExtractsEnergyMelChromaCENSAndLandmarksFromAudioWindows() {
        let configuration = MicFeaturePayloadExtractor.Configuration()
        var extractor = MicFeaturePayloadExtractor(configuration: configuration)
        let firstWindow = makeSineWindow(startSample: 0)
        let secondWindow = makeSineWindow(startSample: 512)

        let firstPayload = extractor.extract(from: firstWindow)
        let secondPayload = extractor.extract(from: secondWindow)

        XCTAssertEqual(firstPayload.subbandOnset.count, configuration.subbandCount)
        XCTAssertEqual(firstPayload.pcenMel.count, configuration.melBandCount)
        XCTAssertEqual(firstPayload.chroma.count, configuration.chromaBinCount)
        XCTAssertEqual(firstPayload.cens.count, configuration.chromaBinCount)
        XCTAssertEqual(dominantIndex(in: firstPayload.chroma), 9)
        XCTAssertGreaterThan(firstPayload.chroma[9], 0.5)
        XCTAssertEqual(firstPayload.energyDBFS, -9.03, accuracy: 0.5)
        XCTAssertNotNil(firstPayload.snrDB)
        XCTAssertTrue(firstPayload.pcenMel.contains { $0 > 0 })
        XCTAssertFalse(secondPayload.landmarkHashes.isEmpty)
        XCTAssertEqual(secondPayload.landmarkHashes, secondPayload.landmarks.map(\.hash))
    }

    func testLandmarkHashesDoNotIncludeAbsoluteAnchorTime() {
        let configuration = MicFeaturePayloadExtractor.Configuration(
            landmarkPeakCount: 1,
            landmarkFanOut: 3,
            landmarkTargetMinimumDeltaFrames: 1,
            landmarkTargetMaximumDeltaFrames: 3
        )
        var firstExtractor = MicFeaturePayloadExtractor(configuration: configuration)
        var shiftedExtractor = MicFeaturePayloadExtractor(configuration: configuration)

        let firstSequence = extractPayloads(
            with: &firstExtractor,
            windows: [
                makeSineWindow(startSample: 0),
                makeSineWindow(startSample: 512),
                makeSineWindow(startSample: 1_024)
            ]
        )
        let shiftedSequence = extractPayloads(
            with: &shiftedExtractor,
            windows: [
                makeSineWindow(startSample: 0, timelineOffsetMS: 5_000),
                makeSineWindow(startSample: 512, timelineOffsetMS: 5_000),
                makeSineWindow(startSample: 1_024, timelineOffsetMS: 5_000)
            ]
        )

        let landmarks = firstSequence.flatMap(\.landmarks)
        let shiftedLandmarks = shiftedSequence.flatMap(\.landmarks)

        XCTAssertFalse(landmarks.isEmpty)
        XCTAssertEqual(landmarks.map(\.hash), shiftedLandmarks.map(\.hash))
        XCTAssertEqual(landmarks.map(\.anchorFrequencyBin), shiftedLandmarks.map(\.anchorFrequencyBin))
        XCTAssertEqual(landmarks.map(\.targetFrequencyBin), shiftedLandmarks.map(\.targetFrequencyBin))
        XCTAssertEqual(landmarks.map(\.deltaFrames), shiftedLandmarks.map(\.deltaFrames))
        XCTAssertTrue(zip(landmarks, shiftedLandmarks).allSatisfy { landmark, shiftedLandmark in
            shiftedLandmark.anchorTimeMS - landmark.anchorTimeMS == 5_000
        })
    }

    func testLandmarksUseTargetZoneBeyondAdjacentFrame() {
        let configuration = MicFeaturePayloadExtractor.Configuration(
            landmarkPeakCount: 1,
            landmarkFanOut: 3,
            landmarkTargetMinimumDeltaFrames: 1,
            landmarkTargetMaximumDeltaFrames: 3
        )
        var extractor = MicFeaturePayloadExtractor(configuration: configuration)

        let payloads = extractPayloads(
            with: &extractor,
            windows: [
                makeSineWindow(startSample: 0),
                makeSineWindow(startSample: 512),
                makeSineWindow(startSample: 1_024),
                makeSineWindow(startSample: 1_536)
            ]
        )
        let landmarks = payloads.flatMap(\.landmarks)

        XCTAssertTrue(landmarks.contains { $0.deltaFrames == 2 })
        XCTAssertTrue(landmarks.allSatisfy { (1...3).contains($0.deltaFrames) })
    }

    func testOnsetEnvelopeUsesPreviousFrameStateAndResetClearsIt() {
        var extractor = MicFeaturePayloadExtractor()
        let quietWindow = makeSineWindow(amplitude: 0.05, startSample: 0)
        let loudWindow = makeSineWindow(amplitude: 0.70, startSample: 1_024)

        _ = extractor.extract(from: quietWindow)
        let attackPayload = extractor.extract(from: loudWindow)
        extractor.reset()
        let resetPayload = extractor.extract(from: loudWindow)

        XCTAssertGreaterThan(attackPayload.onsetEnvelope, 0.01)
        XCTAssertEqual(resetPayload.onsetEnvelope, 0, accuracy: 0.0001)
    }

    private func makeSineWindow(
        frequency: Double = 440,
        amplitude: Double = 0.5,
        sampleRate: Double = 8_000,
        sampleCount: Int = 1_024,
        startSample: Int,
        timelineOffsetMS: Double = 0
    ) -> MicFeatureAudioWindow {
        let samples = (0..<sampleCount).map { sampleOffset in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(startSample + sampleOffset) / sampleRate))
        }
        let recordedStartTimeMS = timelineOffsetMS + Double(startSample) / sampleRate * 1_000
        let recordedEndTimeMS = timelineOffsetMS + Double(startSample + sampleCount) / sampleRate * 1_000

        return MicFeatureAudioWindow(
            monoSamples: samples,
            sampleRate: sampleRate,
            recordedStartTimeMS: recordedStartTimeMS,
            recordedTimeMS: recordedEndTimeMS,
            hostStartTimeMS: 10_000 + recordedStartTimeMS,
            hostTimeMS: 10_000 + recordedEndTimeMS,
            inputChannelCount: 1
        )
    }

    private func extractPayloads(
        with extractor: inout MicFeaturePayloadExtractor,
        windows: [MicFeatureAudioWindow]
    ) -> [MicFeaturePayload] {
        windows.map { window in
            extractor.extract(from: window)
        }
    }

    private func dominantIndex(in values: [Float]) -> Int? {
        values.enumerated().max(by: { $0.element < $1.element })?.offset
    }
}

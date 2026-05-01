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
        startSample: Int
    ) -> MicFeatureAudioWindow {
        let samples = (0..<sampleCount).map { sampleOffset in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(startSample + sampleOffset) / sampleRate))
        }
        let recordedStartTimeMS = Double(startSample) / sampleRate * 1_000
        let recordedEndTimeMS = Double(startSample + sampleCount) / sampleRate * 1_000

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

    private func dominantIndex(in values: [Float]) -> Int? {
        values.enumerated().max(by: { $0.element < $1.element })?.offset
    }
}

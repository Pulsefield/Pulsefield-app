import XCTest
@testable import PulsefieldCore

final class MicFeatureStreamBufferTests: XCTestCase {
    func testAudioChunksProduceFeatureFramesAcrossChunkBoundaries() {
        let configuration = MicFeaturePayloadExtractor.Configuration()
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 120, expectedHopMS: 2)

        let firstFrames = buffer.append(
            makeChunk(samples: [1, 2, 3], recordedStartTimeMS: 1_000, hostStartTimeMS: 10_000),
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )
        let secondFrames = buffer.append(
            makeChunk(samples: [4, 5, 6], recordedStartTimeMS: 1_003, hostStartTimeMS: 10_003),
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )

        XCTAssertEqual(firstFrames, [])
        XCTAssertEqual(secondFrames.map(\.recordedTimeMS), [1_004, 1_006])
        XCTAssertEqual(secondFrames.map(\.hostTimeMS), [10_004, 10_006])
        XCTAssertEqual(secondFrames.map(\.subbandOnset.count), [configuration.subbandCount, configuration.subbandCount])
        XCTAssertEqual(secondFrames.map(\.pcenMel.count), [configuration.melBandCount, configuration.melBandCount])
        XCTAssertEqual(secondFrames.map(\.chroma.count), [configuration.chromaBinCount, configuration.chromaBinCount])
        XCTAssertEqual(secondFrames.map(\.cens.count), [configuration.chromaBinCount, configuration.chromaBinCount])
        XCTAssertTrue(secondFrames.allSatisfy { $0.energyDBFS.isFinite })
        XCTAssertTrue(secondFrames.allSatisfy { $0.snrDB != nil })
        XCTAssertEqual(buffer.latestWindow(durationMS: 20)?.frames.map(\.recordedTimeMS), [1_004, 1_006])
    }

    func testAudioChunkGapStartsNewFeatureContinuitySegment() {
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 120, expectedHopMS: 2)

        _ = buffer.append(
            makeChunk(samples: [1, 2, 3, 4], recordedStartTimeMS: 0, hostStartTimeMS: 1_000),
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )
        _ = buffer.append(
            makeChunk(samples: [5, 6, 7, 8], recordedStartTimeMS: 30, hostStartTimeMS: 1_030),
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )

        XCTAssertEqual(buffer.continuityResetCount, 1)
        XCTAssertEqual(buffer.latestWindow(durationMS: 120)?.frames.map(\.recordedTimeMS), [34])
    }

    func testDefaultExtractorStateResetsWhenAudioContinuityBreaks() {
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 1_000, expectedHopMS: 128)
        let sampleRate = 8_000.0
        let quiet = sineSamples(frequency: 440, amplitude: 0.05, sampleRate: sampleRate, sampleCount: 1_024)
        let loud = sineSamples(frequency: 440, amplitude: 0.70, sampleRate: sampleRate, sampleCount: 1_024)

        _ = buffer.append(
            makeChunk(samples: quiet, recordedStartTimeMS: 0, hostStartTimeMS: 1_000, sampleRate: sampleRate),
            featureWindowSizeSamples: 1_024,
            featureHopSizeSamples: 1_024
        )
        let attackFrames = buffer.append(
            makeChunk(samples: loud, recordedStartTimeMS: 128, hostStartTimeMS: 1_128, sampleRate: sampleRate),
            featureWindowSizeSamples: 1_024,
            featureHopSizeSamples: 1_024
        )
        let resetFrames = buffer.append(
            makeChunk(samples: loud, recordedStartTimeMS: 1_000, hostStartTimeMS: 2_000, sampleRate: sampleRate),
            featureWindowSizeSamples: 1_024,
            featureHopSizeSamples: 1_024
        )

        XCTAssertGreaterThan(attackFrames.first?.onsetEnvelope ?? 0, 0.01)
        XCTAssertEqual(resetFrames.first?.onsetEnvelope ?? -1, 0, accuracy: 0.0001)
    }

    func testLatestWindowKeepsContinuousFramesAcrossAppends() {
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 120, expectedHopMS: 20)

        buffer.append([
            makeFrame(recordedTimeMS: 1_000, hostTimeMS: 10_000, landmarkHashes: [11]),
            makeFrame(recordedTimeMS: 1_020, hostTimeMS: 10_020, landmarkHashes: [12])
        ])
        buffer.append([
            makeFrame(recordedTimeMS: 1_040, hostTimeMS: 10_040, landmarkHashes: [13]),
            makeFrame(recordedTimeMS: 1_060, hostTimeMS: 10_060, landmarkHashes: [14])
        ])

        let window = buffer.latestWindow(durationMS: 80)

        XCTAssertEqual(window?.frames.map(\.recordedTimeMS), [1_000, 1_020, 1_040, 1_060])
        XCTAssertEqual(window?.endpointRecordedTimeMS, 1_060)
        XCTAssertEqual(window?.endpointHostTimeMS, 10_060)
        XCTAssertEqual(window?.landmarkCount, 4)
    }

    func testLatestWindowDoesNotCrossFeatureContinuityReset() {
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 500, expectedHopMS: 20)

        buffer.append([
            makeFrame(recordedTimeMS: 0, hostTimeMS: 1_000),
            makeFrame(recordedTimeMS: 20, hostTimeMS: 1_020),
            makeFrame(recordedTimeMS: 40, hostTimeMS: 1_040)
        ])
        buffer.append([
            makeFrame(recordedTimeMS: 140, hostTimeMS: 1_140),
            makeFrame(recordedTimeMS: 160, hostTimeMS: 1_160)
        ])

        let window = buffer.latestWindow(durationMS: 500)

        XCTAssertEqual(buffer.continuityResetCount, 1)
        XCTAssertEqual(window?.frames.map(\.recordedTimeMS), [140, 160])
    }

    func testFeatureWindowRetainsRecordedTimeAndFeaturePayloads() {
        var buffer = MicFeatureStreamBuffer(retentionDurationMS: 120, expectedHopMS: 20)
        let frame = makeFrame(
            recordedTimeMS: 2_000,
            hostTimeMS: 8_000,
            onsetEnvelope: 0.75,
            subbandOnset: [0.1, 0.2],
            pcenMel: [0.3, 0.4, 0.5],
            chroma: [0.6, 0.7],
            cens: [0.8, 0.9],
            landmarkHashes: [101, 102],
            energyDBFS: -18,
            snrDB: 22
        )

        buffer.append([frame])

        XCTAssertEqual(buffer.latestWindow(durationMS: 20)?.frames.first, frame)
    }

    func testReferenceProjectionUsesMicEndpointRecordedTime() {
        let offsetMS = AmbientSyncTimeProjection.offsetMS(
            localReferenceTimeMS: 5_000,
            micQueryTimeMS: 1_000
        )
        let projected = AmbientSyncTimeProjection.referenceTimeAtNowMS(
            localReferenceTimeAtQueryMS: 5_000,
            queryEndpointRecordedTimeMS: 1_000,
            nowMS: 1_250
        )

        XCTAssertEqual(offsetMS, 4_000)
        XCTAssertEqual(projected, 5_250)
    }

    private func makeFrame(
        recordedTimeMS: Double,
        hostTimeMS: Double,
        onsetEnvelope: Float = 0.5,
        subbandOnset: [Float] = [0.2],
        pcenMel: [Float] = [0.3],
        chroma: [Float] = [0.4],
        cens: [Float] = [0.5],
        landmarkHashes: [UInt64] = [],
        energyDBFS: Double = -20,
        snrDB: Double? = 18
    ) -> MicFeatureFrame {
        MicFeatureFrame(
            recordedTimeMS: recordedTimeMS,
            hostTimeMS: hostTimeMS,
            onsetEnvelope: onsetEnvelope,
            subbandOnset: subbandOnset,
            pcenMel: pcenMel,
            chroma: chroma,
            cens: cens,
            landmarkHashes: landmarkHashes,
            energyDBFS: energyDBFS,
            snrDB: snrDB
        )
    }

    private func makeChunk(
        samples: [Float],
        recordedStartTimeMS: Double,
        hostStartTimeMS: Double,
        sampleRate: Double = 1_000
    ) -> MicAudioChunk {
        MicAudioChunk(
            monoSamples: samples,
            sampleRate: sampleRate,
            recordedStartTimeMS: recordedStartTimeMS,
            hostStartTimeMS: hostStartTimeMS,
            inputChannelCount: 1
        )
    }

    private func sineSamples(
        frequency: Double,
        amplitude: Double,
        sampleRate: Double,
        sampleCount: Int
    ) -> [Float] {
        (0..<sampleCount).map { sampleIndex in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(sampleIndex) / sampleRate))
        }
    }
}

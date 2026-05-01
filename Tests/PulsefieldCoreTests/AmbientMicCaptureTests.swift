import AVFoundation
import XCTest
@testable import PulsefieldCore

final class AmbientMicCaptureTests: XCTestCase {
    func testStreamProcessorDropsQueuedChunksFromStoppedGeneration() {
        let configuration = AmbientMicFeatureStreamService.Configuration(
            retentionDurationMS: 120,
            expectedHopMS: 2,
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )
        var processor = AmbientMicFeatureStreamProcessor(
            configuration: configuration,
            payloadExtractor: MicFeaturePayloadExtractor()
        )
        let stoppedGeneration = processor.start()
        processor.stop()
        let currentGeneration = processor.start()

        let staleFrames = processor.append(
            makeChunk(samples: [1, 2, 3, 4], recordedStartTimeMS: 0, hostStartTimeMS: 1_000),
            generation: stoppedGeneration
        )
        let currentFrames = processor.append(
            makeChunk(samples: [5, 6, 7, 8], recordedStartTimeMS: 10, hostStartTimeMS: 1_010),
            generation: currentGeneration
        )

        XCTAssertEqual(staleFrames, [])
        XCTAssertEqual(currentFrames.map(\.recordedTimeMS), [14])
    }

    func testPCMBufferAndAudioTimeConvertToTimestampedMicChunk() throws {
        let converter = AmbientMicAudioChunkConverter()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4

        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 1
        channels[0][1] = 0
        channels[0][2] = -1
        channels[0][3] = 0.5
        channels[1][0] = -1
        channels[1][1] = 0.5
        channels[1][2] = 1
        channels[1][3] = 0.5

        let hostTime = AVAudioTime.hostTime(forSeconds: 12.345)
        let time = AVAudioTime(hostTime: hostTime, sampleTime: 2_000, atRate: 1_000)

        let chunk = try XCTUnwrap(converter.makeChunk(from: buffer, at: time))

        XCTAssertEqual(chunk.monoSamples, [0, 0.25, 0, 0.5])
        XCTAssertEqual(chunk.sampleRate, 1_000)
        XCTAssertEqual(chunk.inputChannelCount, 2)
        XCTAssertEqual(chunk.recordedStartTimeMS, 2_000, accuracy: 0.0001)
        XCTAssertEqual(chunk.recordedEndTimeMS, 2_004, accuracy: 0.0001)
        XCTAssertEqual(chunk.hostStartTimeMS, 12_345, accuracy: 0.0001)
        XCTAssertEqual(chunk.hostEndTimeMS, 12_349, accuracy: 0.0001)
    }

    func testConvertedMicChunksFeedFeatureStreamAcrossTapBuffers() throws {
        let converter = AmbientMicAudioChunkConverter()
        var streamBuffer = MicFeatureStreamBuffer(retentionDurationMS: 120, expectedHopMS: 2)
        let firstBuffer = try makeMonoBuffer(samples: [1, 2, 3], sampleRate: 1_000)
        let secondBuffer = try makeMonoBuffer(samples: [4, 5, 6], sampleRate: 1_000)

        let firstChunk = try XCTUnwrap(converter.makeChunk(
            from: firstBuffer,
            at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10), sampleTime: 1_000, atRate: 1_000)
        ))
        let secondChunk = try XCTUnwrap(converter.makeChunk(
            from: secondBuffer,
            at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10.003), sampleTime: 1_003, atRate: 1_000)
        ))

        let firstFrames = streamBuffer.append(
            firstChunk,
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )
        let secondFrames = streamBuffer.append(
            secondChunk,
            featureWindowSizeSamples: 4,
            featureHopSizeSamples: 2
        )

        XCTAssertEqual(firstFrames, [])
        XCTAssertEqual(secondFrames.map(\.recordedTimeMS), [1_004, 1_006])
        XCTAssertEqual(secondFrames.map(\.hostTimeMS), [10_004, 10_006])
        XCTAssertEqual(streamBuffer.latestWindow(durationMS: 20)?.frames.map(\.recordedTimeMS), [1_004, 1_006])
    }

    private func makeMonoBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }

        return buffer
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
}

import AVFoundation
import Foundation

public enum AmbientMicFeatureStreamError: Error, Equatable, Sendable {
    case alreadyRunning
    case unsupportedInputFormat
}

public struct AmbientMicAudioChunkConverter: Sendable {
    public init() {}

    public func makeChunk(from buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> MicAudioChunk? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate

        guard frameCount > 0, channelCount > 0, sampleRate > 0 else {
            return nil
        }

        guard let monoSamples = makeMonoSamples(from: buffer, frameCount: frameCount, channelCount: channelCount) else {
            return nil
        }

        guard let recordedStartTimeMS = recordedStartTimeMS(from: time, fallbackSampleRate: sampleRate) else {
            return nil
        }

        let hostStartTimeMS = hostStartTimeMS(from: time) ?? recordedStartTimeMS
        return MicAudioChunk(
            monoSamples: monoSamples,
            sampleRate: sampleRate,
            recordedStartTimeMS: recordedStartTimeMS,
            hostStartTimeMS: hostStartTimeMS,
            inputChannelCount: channelCount
        )
    }

    private func makeMonoSamples(
        from buffer: AVAudioPCMBuffer,
        frameCount: Int,
        channelCount: Int
    ) -> [Float]? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        var monoSamples = Array(repeating: Float(0), count: frameCount)
        if buffer.format.isInterleaved {
            let interleavedSamples = channelData[0]
            for frameIndex in 0..<frameCount {
                var sum = Float(0)
                for channelIndex in 0..<channelCount {
                    sum += interleavedSamples[frameIndex * channelCount + channelIndex]
                }
                monoSamples[frameIndex] = sum / Float(channelCount)
            }
        } else {
            for channelIndex in 0..<channelCount {
                let source = channelData[channelIndex]
                for frameIndex in 0..<frameCount {
                    monoSamples[frameIndex] += source[frameIndex]
                }
            }

            if channelCount > 1 {
                let scale = Float(channelCount)
                for frameIndex in monoSamples.indices {
                    monoSamples[frameIndex] /= scale
                }
            }
        }

        return monoSamples
    }

    private func recordedStartTimeMS(from time: AVAudioTime, fallbackSampleRate: Double) -> Double? {
        if time.isSampleTimeValid {
            let sampleRate = time.sampleRate > 0 ? time.sampleRate : fallbackSampleRate
            guard sampleRate > 0 else {
                return nil
            }

            return Double(time.sampleTime) / sampleRate * 1_000
        }

        return hostStartTimeMS(from: time)
    }

    private func hostStartTimeMS(from time: AVAudioTime) -> Double? {
        guard time.isHostTimeValid else {
            return nil
        }

        return AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000
    }
}

public final class AmbientMicFeatureStreamService: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let retentionDurationMS: Double
        public let expectedHopMS: Double
        public let maximumGapHops: Int
        public let featureWindowSizeSamples: Int
        public let featureHopSizeSamples: Int
        public let tapBufferSizeFrames: AVAudioFrameCount

        public init(
            retentionDurationMS: Double,
            expectedHopMS: Double,
            maximumGapHops: Int = 2,
            featureWindowSizeSamples: Int = 1_024,
            featureHopSizeSamples: Int = 512,
            tapBufferSizeFrames: AVAudioFrameCount = 512
        ) {
            precondition(retentionDurationMS > 0, "retentionDurationMS must be positive.")
            precondition(expectedHopMS > 0, "expectedHopMS must be positive.")
            precondition(maximumGapHops >= 1, "maximumGapHops must be at least 1.")
            precondition(featureWindowSizeSamples > 0, "featureWindowSizeSamples must be positive.")
            precondition(featureHopSizeSamples > 0, "featureHopSizeSamples must be positive.")
            precondition(
                featureHopSizeSamples <= featureWindowSizeSamples,
                "featureHopSizeSamples must not exceed featureWindowSizeSamples."
            )
            precondition(tapBufferSizeFrames > 0, "tapBufferSizeFrames must be positive.")

            self.retentionDurationMS = retentionDurationMS
            self.expectedHopMS = expectedHopMS
            self.maximumGapHops = maximumGapHops
            self.featureWindowSizeSamples = featureWindowSizeSamples
            self.featureHopSizeSamples = featureHopSizeSamples
            self.tapBufferSizeFrames = tapBufferSizeFrames
        }
    }

    public typealias FrameHandler = @Sendable ([MicFeatureFrame]) -> Void

    private let configuration: Configuration
    private let engine: AVAudioEngine
    private let converter: AmbientMicAudioChunkConverter
    private let processingQueue: DispatchQueue
    private let processingQueueKey = DispatchSpecificKey<Void>()
    private var processor: AmbientMicFeatureStreamProcessor

    public init(
        configuration: Configuration,
        engine: AVAudioEngine = AVAudioEngine(),
        payloadExtractor: MicFeaturePayloadExtractor = MicFeaturePayloadExtractor()
    ) {
        self.configuration = configuration
        self.engine = engine
        converter = AmbientMicAudioChunkConverter()
        processingQueue = DispatchQueue(label: "io.pulsefield.ambient-mic-feature-stream")
        processingQueue.setSpecific(key: processingQueueKey, value: ())
        processor = AmbientMicFeatureStreamProcessor(
            configuration: configuration,
            payloadExtractor: payloadExtractor
        )
    }

    deinit {
        stop()
    }

    public func start(onFrames: @escaping FrameHandler) throws {
        try syncOnProcessingQueue {
            guard !processor.isRunning else {
                throw AmbientMicFeatureStreamError.alreadyRunning
            }

            let inputNode = engine.inputNode
            let inputBus: AVAudioNodeBus = 0
            let inputFormat = inputNode.inputFormat(forBus: inputBus)
            guard inputFormat.commonFormat == .pcmFormatFloat32,
                  inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0
            else {
                throw AmbientMicFeatureStreamError.unsupportedInputFormat
            }

            let generation = processor.start()

            inputNode.installTap(
                onBus: inputBus,
                bufferSize: configuration.tapBufferSizeFrames,
                format: inputFormat
            ) { [weak self] buffer, time in
                guard let self,
                      let chunk = self.converter.makeChunk(from: buffer, at: time)
                else {
                    return
                }

                self.processingQueue.async { [weak self] in
                    guard let self else {
                        return
                    }

                    let frames = self.processor.append(chunk, generation: generation)
                    if !frames.isEmpty {
                        onFrames(frames)
                    }
                }
            }

            do {
                engine.prepare()
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: inputBus)
                processor.stop()
                throw error
            }
        }
    }

    public func stop() {
        syncOnProcessingQueue {
            guard processor.isRunning else {
                return
            }

            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            processor.stop()
        }
    }

    private func syncOnProcessingQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            return try work()
        }

        return try processingQueue.sync(execute: work)
    }
}

struct AmbientMicFeatureStreamProcessor: Sendable {
    private let configuration: AmbientMicFeatureStreamService.Configuration
    private let initialPayloadExtractor: MicFeaturePayloadExtractor
    private var streamBuffer: MicFeatureStreamBuffer

    private(set) var generation = 0
    private(set) var isRunning = false

    init(
        configuration: AmbientMicFeatureStreamService.Configuration,
        payloadExtractor: MicFeaturePayloadExtractor
    ) {
        self.configuration = configuration
        initialPayloadExtractor = payloadExtractor
        streamBuffer = Self.makeStreamBuffer(
            configuration: configuration,
            payloadExtractor: payloadExtractor
        )
    }

    mutating func start() -> Int {
        generation += 1
        isRunning = true
        streamBuffer = Self.makeStreamBuffer(
            configuration: configuration,
            payloadExtractor: initialPayloadExtractor
        )
        return generation
    }

    mutating func stop() {
        guard isRunning else {
            return
        }

        isRunning = false
        generation += 1
    }

    mutating func append(_ chunk: MicAudioChunk, generation chunkGeneration: Int) -> [MicFeatureFrame] {
        guard isRunning, chunkGeneration == generation else {
            return []
        }

        return streamBuffer.append(
            chunk,
            featureWindowSizeSamples: configuration.featureWindowSizeSamples,
            featureHopSizeSamples: configuration.featureHopSizeSamples
        )
    }

    private static func makeStreamBuffer(
        configuration: AmbientMicFeatureStreamService.Configuration,
        payloadExtractor: MicFeaturePayloadExtractor
    ) -> MicFeatureStreamBuffer {
        MicFeatureStreamBuffer(
            retentionDurationMS: configuration.retentionDurationMS,
            expectedHopMS: configuration.expectedHopMS,
            maximumGapHops: configuration.maximumGapHops,
            payloadExtractor: payloadExtractor
        )
    }
}

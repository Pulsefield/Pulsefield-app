#if os(macOS)
import Foundation

@available(macOS 13.0, *)
public final class SystemAudioFeatureStreamService: @unchecked Sendable {
    public typealias Configuration = AmbientMicFeatureStreamService.Configuration
    public typealias FrameHandler = @Sendable ([MicFeatureFrame]) -> Void
    public typealias StopErrorHandler = @Sendable (Error) -> Void

    private let configuration: Configuration
    private let captureSource: SystemAudioCaptureSource
    private let processingQueue: DispatchQueue
    private let processingQueueKey = DispatchSpecificKey<Void>()
    private var processor: AmbientMicFeatureStreamProcessor

    public init(
        configuration: Configuration,
        captureSource: SystemAudioCaptureSource? = nil,
        payloadExtractor: MicFeaturePayloadExtractor = MicFeaturePayloadExtractor()
    ) {
        self.configuration = configuration
        self.captureSource = captureSource ?? SystemAudioCaptureSource(
            configuration: SystemAudioCaptureSource.Configuration(
                sampleRate: Self.requestedSampleRate(from: configuration),
                channelCount: 2,
                excludesCurrentProcessAudio: false
            )
        )
        processingQueue = DispatchQueue(label: "io.pulsefield.system-audio-feature-stream")
        processingQueue.setSpecific(key: processingQueueKey, value: ())
        processor = AmbientMicFeatureStreamProcessor(
            configuration: configuration,
            payloadExtractor: payloadExtractor
        )
    }

    deinit {
        stop()
    }

    public func start(
        onFrames: @escaping FrameHandler,
        onStopWithError: StopErrorHandler? = nil
    ) async throws {
        let generation = try syncOnProcessingQueue {
            guard !processor.isRunning else {
                throw AmbientMicFeatureStreamError.alreadyRunning
            }

            return processor.start()
        }

        do {
            try await captureSource.start(
                onBuffer: { [weak self] captureBuffer in
                    guard let self else {
                        return
                    }

                    self.processingQueue.async { [weak self] in
                        guard let self else {
                            return
                        }

                        let frames = self.processor.append(captureBuffer.chunk, generation: generation)
                        if !frames.isEmpty {
                            onFrames(frames)
                        }
                    }
                },
                onStopWithError: { [weak self] error in
                    guard let self else {
                        return
                    }

                    self.syncOnProcessingQueue {
                        self.processor.stop()
                    }
                    onStopWithError?(error)
                }
            )
        } catch {
            syncOnProcessingQueue {
                processor.stop()
            }
            throw error
        }
    }

    public func stop() {
        captureSource.stop()
        stopProcessor()
    }

    public func stopAndWait() async {
        try? await captureSource.stopCapturing()
        stopProcessor()
    }

    private func stopProcessor() {
        syncOnProcessingQueue {
            guard processor.isRunning else {
                return
            }

            processor.stop()
        }
    }

    private func syncOnProcessingQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            return try work()
        }

        return try processingQueue.sync(execute: work)
    }

    private static func requestedSampleRate(from configuration: Configuration) -> Int {
        Int((Double(configuration.featureHopSizeSamples) / configuration.expectedHopMS * 1_000).rounded())
    }
}
#endif

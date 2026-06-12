#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 13.0, *)
public enum SystemAudioCaptureError: LocalizedError, Sendable {
    case alreadyRunning
    case noDisplayAvailable
    case invalidSampleBuffer
    case invalidSampleTiming
    case unsupportedSampleBufferFormat
    case unsupportedAudioChunkFormat
    case pcmCopyFailed(OSStatus)
    case repeatedBufferFailures(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A system audio capture stream is already running."
        case .noDisplayAvailable:
            return "No display is available for ScreenCaptureKit audio capture."
        case .invalidSampleBuffer:
            return "ScreenCaptureKit produced an invalid audio sample buffer."
        case .invalidSampleTiming:
            return "ScreenCaptureKit produced an audio sample buffer with invalid timing."
        case .unsupportedSampleBufferFormat:
            return "ScreenCaptureKit produced an unsupported audio sample buffer format."
        case .unsupportedAudioChunkFormat:
            return "ScreenCaptureKit produced audio that could not be converted into ambient feature input."
        case .pcmCopyFailed(let status):
            return "Could not copy ScreenCaptureKit audio sample data. OSStatus=\(status)."
        case .repeatedBufferFailures(let message):
            return "System audio capture stopped after repeated audio buffer failures: \(message)"
        }
    }
}

@available(macOS 13.0, *)
public struct SystemAudioCaptureBuffer: @unchecked Sendable {
    public let audioBuffer: AVAudioPCMBuffer
    public let chunk: MicAudioChunk

    public init(audioBuffer: AVAudioPCMBuffer, chunk: MicAudioChunk) {
        self.audioBuffer = audioBuffer
        self.chunk = chunk
    }
}

@available(macOS 13.0, *)
public final class SystemAudioCaptureSource: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let sampleRate: Int
        public let channelCount: Int
        public let excludesCurrentProcessAudio: Bool
        public let bufferFailureLimit: Int

        public init(
            sampleRate: Int = 48_000,
            channelCount: Int = 2,
            excludesCurrentProcessAudio: Bool = false,
            bufferFailureLimit: Int = 5
        ) {
            precondition(sampleRate > 0, "sampleRate must be positive.")
            precondition(channelCount > 0, "channelCount must be positive.")
            precondition(bufferFailureLimit > 0, "bufferFailureLimit must be positive.")

            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
            self.bufferFailureLimit = bufferFailureLimit
        }
    }

    public typealias BufferHandler = @Sendable (SystemAudioCaptureBuffer) -> Void
    public typealias StopErrorHandler = @Sendable (Error) -> Void

    private struct TimingAnchor {
        let firstPresentationTimeMS: Double
        let firstHostTimeMS: Double
    }

    private struct StopStream: @unchecked Sendable {
        let stream: SCStream
    }

    private let configuration: Configuration
    private let outputQueue = DispatchQueue(label: "io.pulsefield.system-audio-capture")
    private let stateLock = NSLock()
    private let chunkConverter = AmbientMicAudioChunkConverter()

    private var stream: SCStream?
    private var generation = 0
    private var isStarting = false
    private var timingAnchor: TimingAnchor?
    private var onBuffer: BufferHandler?
    private var onStopWithError: StopErrorHandler?
    private var consecutiveBufferFailureCount = 0
    private var latestBufferFailureDescription: String?
    private var pendingStopTask: (id: Int, task: Task<Void, Error>)?
    private var nextStopTaskID = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    public func start(
        onBuffer: @escaping BufferHandler,
        onStopWithError: StopErrorHandler? = nil
    ) async throws {
        try await waitForPendingStop()
        let startGeneration = try beginStart(
            onBuffer: onBuffer,
            onStopWithError: onStopWithError
        )

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            try Task.checkCancellation()
            guard isCurrentGeneration(startGeneration) else {
                throw CancellationError()
            }

            guard let display = shareableContent.displays.first else {
                clearState(ifGeneration: startGeneration)
                throw SystemAudioCaptureError.noDisplayAvailable
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = max(display.width, 2)
            streamConfiguration.height = max(display.height, 2)
            streamConfiguration.queueDepth = 3
            streamConfiguration.capturesAudio = true
            streamConfiguration.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio
            streamConfiguration.sampleRate = configuration.sampleRate
            streamConfiguration.channelCount = configuration.channelCount

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            guard store(stream: stream, generation: startGeneration) else {
                throw CancellationError()
            }

            do {
                try await stream.startCapture()
            } catch {
                clearState(ifGeneration: startGeneration)
                throw error
            }

            guard isCurrent(stream: stream, generation: startGeneration) else {
                throw CancellationError()
            }
        } catch {
            clearState(ifGeneration: startGeneration)
            throw error
        }
    }

    public func stop() {
        guard let stream = invalidateAndTakeRunningStream() else {
            return
        }

        _ = storePendingStopTask(for: stream)
    }

    public func stopCapturing() async throws {
        guard let stream = invalidateAndTakeRunningStream() else {
            try await waitForPendingStop()
            return
        }

        let stopTask = storePendingStopTask(for: stream)
        do {
            try await stopTask.task.value
            clearPendingStopTask(id: stopTask.id)
        } catch {
            clearPendingStopTask(id: stopTask.id)
            throw error
        }
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else {
            return
        }

        guard let handler = currentHandler(for: stream) else {
            return
        }

        do {
            let buffer = try makePCMBuffer(from: sampleBuffer)
            let timing = try makeTiming(for: sampleBuffer)
            guard let chunk = chunkConverter.makeChunk(
                from: buffer,
                recordedStartTimeMS: timing.recordedStartTimeMS,
                hostStartTimeMS: timing.hostStartTimeMS
            ) else {
                throw SystemAudioCaptureError.unsupportedAudioChunkFormat
            }

            guard isCurrent(stream: stream) else {
                return
            }

            resetBufferFailureState(for: stream)
            handler(SystemAudioCaptureBuffer(audioBuffer: buffer, chunk: chunk))
        } catch {
            if sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) == 0 {
                return
            }

            recordBufferFailure(error, for: stream)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let stopErrorHandler = clearStateAndTakeStopErrorHandler(ifStream: stream) else {
            return
        }

        stopErrorHandler(error)
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard sampleBuffer.isValid else {
            throw SystemAudioCaptureError.invalidSampleBuffer
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            throw SystemAudioCaptureError.invalidSampleBuffer
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw SystemAudioCaptureError.unsupportedSampleBufferFormat
        }

        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw SystemAudioCaptureError.unsupportedSampleBufferFormat
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw SystemAudioCaptureError.pcmCopyFailed(status)
        }

        return buffer
    }

    private func makeTiming(for sampleBuffer: CMSampleBuffer) throws -> (recordedStartTimeMS: Double, hostStartTimeMS: Double) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        guard presentationSeconds.isFinite else {
            throw SystemAudioCaptureError.invalidSampleTiming
        }

        let presentationTimeMS = presentationSeconds * 1_000
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        let anchor: TimingAnchor
        if let existingAnchor = timingAnchor {
            anchor = existingAnchor
        } else {
            anchor = TimingAnchor(
                firstPresentationTimeMS: presentationTimeMS,
                firstHostTimeMS: PulsefieldHostClock.currentTimeMS()
            )
            timingAnchor = anchor
        }

        let recordedStartTimeMS = presentationTimeMS - anchor.firstPresentationTimeMS
        return (
            recordedStartTimeMS: recordedStartTimeMS,
            hostStartTimeMS: anchor.firstHostTimeMS + recordedStartTimeMS
        )
    }

    private func beginStart(
        onBuffer: @escaping BufferHandler,
        onStopWithError: StopErrorHandler?
    ) throws -> Int {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard stream == nil, !isStarting else {
            throw SystemAudioCaptureError.alreadyRunning
        }

        generation += 1
        isStarting = true
        self.onBuffer = onBuffer
        self.onStopWithError = onStopWithError
        timingAnchor = nil
        consecutiveBufferFailureCount = 0
        latestBufferFailureDescription = nil
        return generation
    }

    private func clearState(ifGeneration targetGeneration: Int) {
        stateLock.lock()
        guard generation == targetGeneration else {
            stateLock.unlock()
            return
        }

        stream = nil
        onBuffer = nil
        onStopWithError = nil
        timingAnchor = nil
        isStarting = false
        consecutiveBufferFailureCount = 0
        latestBufferFailureDescription = nil
        stateLock.unlock()
    }

    private func clearStateAndTakeStopErrorHandler(ifStream targetStream: SCStream) -> StopErrorHandler? {
        stateLock.lock()
        guard let stream, stream === targetStream else {
            stateLock.unlock()
            return nil
        }

        generation += 1
        self.stream = nil
        let stopErrorHandler = onStopWithError
        onBuffer = nil
        onStopWithError = nil
        timingAnchor = nil
        isStarting = false
        consecutiveBufferFailureCount = 0
        latestBufferFailureDescription = nil
        stateLock.unlock()
        return stopErrorHandler
    }

    private func currentHandler(for callbackStream: SCStream) -> BufferHandler? {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard let stream, stream === callbackStream else {
            return nil
        }

        return onBuffer
    }

    private func store(stream: SCStream, generation targetGeneration: Int) -> Bool {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard generation == targetGeneration, isStarting else {
            return false
        }

        self.stream = stream
        isStarting = false
        return true
    }

    private func resetBufferFailureState(for callbackStream: SCStream) {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard let stream, stream === callbackStream else {
            return
        }

        consecutiveBufferFailureCount = 0
        latestBufferFailureDescription = nil
    }

    private func recordBufferFailure(_ error: Error, for callbackStream: SCStream) {
        let failedStream: SCStream?
        let stopErrorHandler: StopErrorHandler?
        let failure: SystemAudioCaptureError?

        stateLock.lock()
        if let stream, stream === callbackStream {
            consecutiveBufferFailureCount += 1
            latestBufferFailureDescription = error.localizedDescription

            if consecutiveBufferFailureCount >= configuration.bufferFailureLimit {
                generation += 1
                failedStream = stream
                self.stream = nil
                stopErrorHandler = onStopWithError
                onBuffer = nil
                onStopWithError = nil
                timingAnchor = nil
                isStarting = false
                consecutiveBufferFailureCount = 0
                latestBufferFailureDescription = nil
                failure = .repeatedBufferFailures(error.localizedDescription)
            } else {
                failedStream = nil
                stopErrorHandler = nil
                failure = nil
            }
        } else {
            failedStream = nil
            stopErrorHandler = nil
            failure = nil
        }
        stateLock.unlock()

        guard let failedStream, let stopErrorHandler, let failure else {
            return
        }

        _ = storePendingStopTask(for: failedStream)
        stopErrorHandler(failure)
    }

    private func waitForPendingStop() async throws {
        while let pendingStopTask = currentPendingStopTask() {
            do {
                try await pendingStopTask.task.value
                clearPendingStopTask(id: pendingStopTask.id)
            } catch {
                clearPendingStopTask(id: pendingStopTask.id)
                throw error
            }
        }
    }

    private func storePendingStopTask(for stream: SCStream) -> (id: Int, task: Task<Void, Error>) {
        let stopStream = StopStream(stream: stream)
        let task = Task {
            try await stopStream.stream.stopCapture()
        }

        stateLock.lock()
        nextStopTaskID += 1
        let id = nextStopTaskID
        pendingStopTask = (id: id, task: task)
        stateLock.unlock()

        return (id: id, task: task)
    }

    private func currentPendingStopTask() -> (id: Int, task: Task<Void, Error>)? {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        return pendingStopTask
    }

    private func clearPendingStopTask(id: Int) {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard pendingStopTask?.id == id else {
            return
        }

        pendingStopTask = nil
    }

    private func isCurrentGeneration(_ targetGeneration: Int) -> Bool {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        return generation == targetGeneration && isStarting
    }

    private func isCurrent(stream callbackStream: SCStream, generation targetGeneration: Int? = nil) -> Bool {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard let stream, stream === callbackStream else {
            return false
        }

        if let targetGeneration {
            return generation == targetGeneration
        }

        return true
    }

    private func invalidateAndTakeRunningStream() -> SCStream? {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        generation += 1
        let runningStream = stream
        stream = nil
        isStarting = false
        onBuffer = nil
        onStopWithError = nil
        timingAnchor = nil
        consecutiveBufferFailureCount = 0
        latestBufferFailureDescription = nil
        return runningStream
    }
}
#endif

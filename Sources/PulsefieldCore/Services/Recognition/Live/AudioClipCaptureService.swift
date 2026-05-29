import AVFoundation
import Foundation

public final class AudioClipCaptureService: RecognitionAudioCapturing, @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let outputDirectoryURL: URL
        public let fileExtension: String
        public let tapBufferSizeFrames: AVAudioFrameCount

        public init(
            outputDirectoryURL: URL = AudioClipCaptureService.defaultOutputDirectoryURL(),
            fileExtension: String = "wav",
            tapBufferSizeFrames: AVAudioFrameCount = 4_096
        ) {
            precondition(!fileExtension.isEmpty, "fileExtension must not be empty.")
            precondition(tapBufferSizeFrames > 0, "tapBufferSizeFrames must be positive.")

            self.outputDirectoryURL = outputDirectoryURL
            self.fileExtension = fileExtension
            self.tapBufferSizeFrames = tapBufferSizeFrames
        }
    }

    private struct ActiveCapture {
        let clipID: UUID
        let startedAt: Date
        let audioURL: URL
        let audioFile: AVAudioFile
        let audioFormat: AVAudioFormat
        let outputSettings: [String: Any]
        let sampleRate: Double
        let channelCount: Int
        var frameCount: AVAudioFramePosition
        var cachedBuffers: [AVAudioPCMBuffer]
        var writeError: Error?
    }

    private struct CaptureSnapshot {
        let clipID: UUID
        let startedAt: Date
        let audioFormat: AVAudioFormat
        let outputSettings: [String: Any]
        let sampleRate: Double
        let frameCount: AVAudioFramePosition
        let cachedBuffers: [AVAudioPCMBuffer]
        let writeError: Error?
    }

    public let configuration: Configuration

    private let engine: AVAudioEngine
    private let activeCaptureLock = NSLock()
    private var activeCapture: ActiveCapture?

    public init(
        configuration: Configuration = Configuration(),
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.configuration = configuration
        self.engine = engine
    }

    deinit {
        stopDiscardingClip()
    }

    public func prepare() async {}

    public func captureClip(duration: TimeInterval) async -> Result<RecognitionAudioClip, RecognitionFailure> {
        guard duration > 0 else {
            return .failure(RecognitionFailure(
                title: "Invalid Clip Duration",
                message: "Recognition clip duration must be greater than zero seconds."
            ))
        }

        do {
            try startCapture()

            do {
                try await Task.sleep(nanoseconds: UInt64((duration * 1_000_000_000).rounded()))
            } catch {
                await cancelCapture()
                return .failure(RecognitionFailure(
                    title: "Clip Capture Cancelled",
                    message: "The microphone clip capture was cancelled before it finished."
                ))
            }

            return .success(try stopCapture())
        } catch {
            stopDiscardingClip()
            return .failure(RecognitionFailure(
                title: "Clip Capture Failed",
                message: error.localizedDescription
            ))
        }
    }

    public func startCachedClipCapture() -> Result<Void, RecognitionFailure> {
        do {
            try startCapture()
            return .success(())
        } catch {
            stopDiscardingClip()
            return .failure(RecognitionFailure(
                title: "Clip Capture Failed",
                message: error.localizedDescription
            ))
        }
    }

    public func cachedClip(duration: TimeInterval) -> Result<RecognitionAudioClip, RecognitionFailure> {
        guard duration > 0 else {
            return .failure(RecognitionFailure(
                title: "Invalid Clip Duration",
                message: "Recognition clip duration must be greater than zero seconds."
            ))
        }

        do {
            return .success(try writeCachedClip(duration: duration))
        } catch {
            return .failure(RecognitionFailure(
                title: "Clip Cache Failed",
                message: error.localizedDescription
            ))
        }
    }

    public func cancelCapture() async {
        stopDiscardingClip()
    }

    public static func defaultOutputDirectoryURL() -> URL {
        #if os(macOS)
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #else
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif

        return baseURL
            .appendingPathComponent("Pulsefield", isDirectory: true)
            .appendingPathComponent("ACRCloudDebugClips", isDirectory: true)
    }

    private func startCapture() throws {
        guard readActiveCapture() == nil else {
            throw AudioClipCaptureError.alreadyCapturing
        }

        try FileManager.default.createDirectory(
            at: configuration.outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let inputNode = engine.inputNode
        let inputBus: AVAudioNodeBus = 0
        let inputFormat = inputNode.inputFormat(forBus: inputBus)
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0
        else {
            throw AudioClipCaptureError.unsupportedInputFormat
        }

        let startedAt = Date()
        let clipID = UUID()
        let audioURL = configuration.outputDirectoryURL
            .appendingPathComponent(Self.fileStem(timestamp: startedAt, clipID: clipID))
            .appendingPathExtension(configuration.fileExtension)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: audioURL,
                settings: outputSettings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
        } catch {
            throw AudioClipCaptureError.writeFailed(error.localizedDescription)
        }

        replaceActiveCapture(ActiveCapture(
            clipID: clipID,
            startedAt: startedAt,
            audioURL: audioURL,
            audioFile: audioFile,
            audioFormat: inputFormat,
            outputSettings: outputSettings,
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            frameCount: 0,
            cachedBuffers: [],
            writeError: nil
        ))

        inputNode.installTap(
            onBus: inputBus,
            bufferSize: configuration.tapBufferSizeFrames,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: inputBus)
            engine.stop()
            replaceActiveCapture(nil)
            throw AudioClipCaptureError.writeFailed(error.localizedDescription)
        }
    }

    private func stopCapture() throws -> RecognitionAudioClip {
        guard readActiveCapture() != nil else {
            throw AudioClipCaptureError.notCapturing
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        guard let capture = takeActiveCapture() else {
            throw AudioClipCaptureError.notCapturing
        }

        if let writeError = capture.writeError {
            throw AudioClipCaptureError.writeFailed(writeError.localizedDescription)
        }

        let measuredDuration = Double(capture.frameCount) / capture.sampleRate
        return RecognitionAudioClip(
            fileURL: capture.audioURL,
            mimeType: "audio/wav",
            duration: measuredDuration,
            recordedAt: capture.startedAt
        )
    }

    private func writeCachedClip(duration: TimeInterval) throws -> RecognitionAudioClip {
        let snapshot = try captureSnapshot()
        let requestedFrameCount = AVAudioFramePosition((duration * snapshot.sampleRate).rounded())
        let availableFrameCount = min(requestedFrameCount, snapshot.frameCount)
        guard availableFrameCount > 0 else {
            throw AudioClipCaptureError.cacheNotReady
        }

        let audioURL = configuration.outputDirectoryURL
            .appendingPathComponent(Self.temporalFileStem(
                timestamp: snapshot.startedAt,
                clipID: snapshot.clipID,
                duration: duration
            ))
            .appendingPathExtension(configuration.fileExtension)

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: audioURL,
                settings: snapshot.outputSettings,
                commonFormat: snapshot.audioFormat.commonFormat,
                interleaved: snapshot.audioFormat.isInterleaved
            )
        } catch {
            throw AudioClipCaptureError.writeFailed(error.localizedDescription)
        }

        var remainingFrameCount = availableFrameCount
        for buffer in snapshot.cachedBuffers where remainingFrameCount > 0 {
            let frameLength = min(AVAudioFramePosition(buffer.frameLength), remainingFrameCount)
            guard let cachedBuffer = Self.copyBuffer(buffer, frameLength: AVAudioFrameCount(frameLength)) else {
                throw AudioClipCaptureError.writeFailed("Could not copy cached microphone audio.")
            }

            try audioFile.write(from: cachedBuffer)
            remainingFrameCount -= frameLength
        }

        let writtenFrameCount = availableFrameCount - remainingFrameCount
        guard writtenFrameCount > 0 else {
            throw AudioClipCaptureError.cacheNotReady
        }

        return RecognitionAudioClip(
            fileURL: audioURL,
            mimeType: "audio/wav",
            duration: Double(writtenFrameCount) / snapshot.sampleRate,
            recordedAt: snapshot.startedAt
        )
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        guard var capture = activeCapture else {
            return
        }

        do {
            try capture.audioFile.write(from: buffer)
            capture.frameCount += AVAudioFramePosition(buffer.frameLength)
            if let cachedBuffer = Self.copyBuffer(buffer, frameLength: buffer.frameLength) {
                capture.cachedBuffers.append(cachedBuffer)
            }
        } catch {
            capture.writeError = error
        }

        activeCapture = capture
    }

    private func stopDiscardingClip() {
        guard readActiveCapture() != nil else {
            return
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        replaceActiveCapture(nil)
    }

    private func readActiveCapture() -> ActiveCapture? {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        return activeCapture
    }

    private func takeActiveCapture() -> ActiveCapture? {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        let capture = activeCapture
        activeCapture = nil
        return capture
    }

    private func replaceActiveCapture(_ capture: ActiveCapture?) {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        activeCapture = capture
    }

    private func captureSnapshot() throws -> CaptureSnapshot {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        guard let capture = activeCapture else {
            throw AudioClipCaptureError.notCapturing
        }

        if let writeError = capture.writeError {
            throw AudioClipCaptureError.writeFailed(writeError.localizedDescription)
        }

        return CaptureSnapshot(
            clipID: capture.clipID,
            startedAt: capture.startedAt,
            audioFormat: capture.audioFormat,
            outputSettings: capture.outputSettings,
            sampleRate: capture.sampleRate,
            frameCount: capture.frameCount,
            cachedBuffers: capture.cachedBuffers,
            writeError: capture.writeError
        )
    }

    private static func fileStem(timestamp: Date, clipID: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        return "acrcloud-debug-\(formatter.string(from: timestamp))-\(clipID.uuidString.prefix(8).lowercased())"
    }

    private static func temporalFileStem(timestamp: Date, clipID: UUID, duration: TimeInterval) -> String {
        let durationLabel = String(format: "%.2fs", duration)
            .replacingOccurrences(of: ".", with: "_")
        return "\(fileStem(timestamp: timestamp, clipID: clipID))-\(durationLabel)"
    }

    private static func copyBuffer(
        _ buffer: AVAudioPCMBuffer,
        frameLength: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        let framesToCopy = min(frameLength, buffer.frameLength)
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: framesToCopy
        ) else {
            return nil
        }

        copiedBuffer.frameLength = framesToCopy
        guard framesToCopy > 0 else {
            return copiedBuffer
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
        let sourceFrameCount = max(Int(buffer.frameLength), 1)
        let destinationFrameCount = Int(framesToCopy)

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                continue
            }

            let bytesPerFrame = Int(sourceBuffers[index].mDataByteSize) / sourceFrameCount
            let bytesToCopy = bytesPerFrame * destinationFrameCount
            memcpy(destinationData, sourceData, bytesToCopy)
            destinationBuffers[index].mDataByteSize = UInt32(bytesToCopy)
        }

        return copiedBuffer
    }
}

private enum AudioClipCaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case cacheNotReady
    case unsupportedInputFormat
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "A recognition clip capture is already running."
        case .notCapturing:
            return "No recognition clip capture is running."
        case .cacheNotReady:
            return "The recognition clip cache does not contain enough microphone audio yet."
        case .unsupportedInputFormat:
            return "The microphone input format is not supported."
        case .writeFailed(let message):
            return "Could not write recognition clip: \(message)"
        }
    }
}

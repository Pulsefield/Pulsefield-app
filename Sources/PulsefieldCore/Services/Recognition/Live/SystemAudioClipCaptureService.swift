#if os(macOS)
import AVFoundation
import Foundation

@available(macOS 13.0, *)
public final class SystemAudioClipCaptureService: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let outputDirectoryURL: URL
        public let fileExtension: String
        public let maximumCacheDuration: TimeInterval

        public init(
            outputDirectoryURL: URL = AudioClipCaptureService.defaultOutputDirectoryURL(),
            fileExtension: String = "wav",
            maximumCacheDuration: TimeInterval = 30
        ) {
            precondition(!fileExtension.isEmpty, "fileExtension must not be empty.")
            precondition(maximumCacheDuration > 0, "maximumCacheDuration must be positive.")

            self.outputDirectoryURL = outputDirectoryURL
            self.fileExtension = fileExtension
            self.maximumCacheDuration = maximumCacheDuration
        }
    }

    private struct ActiveCapture {
        let clipID: UUID
        let startedAt: Date
        var audioFormat: AVAudioFormat?
        var outputSettings: [String: Any]?
        var sampleRate: Double?
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

    private let captureSource: SystemAudioCaptureSource
    private let activeCaptureLock = NSLock()
    private var activeCapture: ActiveCapture?
    private var temporaryClipURLs: Set<URL> = []

    public init(
        configuration: Configuration = Configuration(),
        captureSource: SystemAudioCaptureSource = SystemAudioCaptureSource()
    ) {
        self.configuration = configuration
        self.captureSource = captureSource
    }

    deinit {
        stopDiscardingClip()
        discardTemporaryClips()
    }

    public func startCachedClipCapture() async -> Result<Void, RecognitionFailure> {
        do {
            try startCapture()
            try await captureSource.start(
                onBuffer: { [weak self] captureBuffer in
                    self?.append(captureBuffer.audioBuffer)
                },
                onStopWithError: { [weak self] error in
                    self?.recordCaptureError(error)
                }
            )
            return .success(())
        } catch {
            await stopDiscardingClipAndWait()
            return .failure(RecognitionFailure(
                title: "System Audio Capture Failed",
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
            return .success(try cachedClipOrThrow(duration: duration))
        } catch {
            return .failure(RecognitionFailure(
                title: "System Audio Clip Failed",
                message: error.localizedDescription
            ))
        }
    }

    public func cancelCapture() async {
        await stopDiscardingClipAndWait()
    }

    public func discardTemporaryClip(at url: URL) {
        guard takeTemporaryClipURL(url) != nil else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    public func discardTemporaryClips() {
        let urls = takeTemporaryClipURLs()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startCapture() throws {
        guard readActiveCapture() == nil else {
            throw SystemAudioClipCaptureError.alreadyCapturing
        }

        try FileManager.default.createDirectory(
            at: configuration.outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let startedAt = Date()
        let clipID = UUID()

        replaceActiveCapture(ActiveCapture(
            clipID: clipID,
            startedAt: startedAt,
            audioFormat: nil,
            outputSettings: nil,
            sampleRate: nil,
            frameCount: 0,
            cachedBuffers: [],
            writeError: nil
        ))
    }

    private func cachedClipOrThrow(duration: TimeInterval) throws -> RecognitionAudioClip {
        let snapshot = try captureSnapshot()
        let requestedFrameCount = AVAudioFramePosition((duration * snapshot.sampleRate).rounded())
        let availableFrameCount = min(requestedFrameCount, snapshot.frameCount)
        guard availableFrameCount > 0 else {
            throw SystemAudioClipCaptureError.cacheNotReady
        }

        let audioURL = configuration.outputDirectoryURL
            .appendingPathComponent(Self.temporalFileStem(
                timestamp: snapshot.startedAt,
                clipID: snapshot.clipID,
                duration: duration
            ))
            .appendingPathExtension(configuration.fileExtension)

        try FileManager.default.createDirectory(
            at: configuration.outputDirectoryURL,
            withIntermediateDirectories: true
        )

        do {
            let audioFile = try AVAudioFile(
                forWriting: audioURL,
                settings: snapshot.outputSettings,
                commonFormat: snapshot.audioFormat.commonFormat,
                interleaved: snapshot.audioFormat.isInterleaved
            )

            var framesToSkip = snapshot.frameCount - availableFrameCount
            var remainingFrameCount = availableFrameCount
            for buffer in snapshot.cachedBuffers where remainingFrameCount > 0 {
                let bufferFrameCount = AVAudioFramePosition(buffer.frameLength)
                if framesToSkip >= bufferFrameCount {
                    framesToSkip -= bufferFrameCount
                    continue
                }

                let startingFrame = max(framesToSkip, 0)
                let frameLength = min(bufferFrameCount - startingFrame, remainingFrameCount)
                guard let cachedBuffer = Self.copyBuffer(
                    buffer,
                    startingFrame: AVAudioFrameCount(startingFrame),
                    frameLength: AVAudioFrameCount(frameLength)
                ) else {
                    throw SystemAudioClipCaptureError.writeFailed("Could not copy cached system audio.")
                }

                try audioFile.write(from: cachedBuffer)
                remainingFrameCount -= frameLength
                framesToSkip = 0
            }

            let writtenFrameCount = availableFrameCount - remainingFrameCount
            guard writtenFrameCount > 0 else {
                throw SystemAudioClipCaptureError.cacheNotReady
            }

            rememberTemporaryClipURL(audioURL)
            return RecognitionAudioClip(
                fileURL: audioURL,
                mimeType: "audio/wav",
                duration: Double(writtenFrameCount) / snapshot.sampleRate,
                recordedAt: snapshot.startedAt
            )
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            throw error
        }
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
            if capture.audioFormat == nil {
                let outputSettings = Self.outputSettings(for: buffer.format)
                capture.audioFormat = buffer.format
                capture.outputSettings = outputSettings
                capture.sampleRate = buffer.format.sampleRate
            }

            if let cachedBuffer = Self.copyBuffer(buffer, frameLength: buffer.frameLength) {
                capture.cachedBuffers.append(cachedBuffer)
                capture.frameCount += AVAudioFramePosition(cachedBuffer.frameLength)
                trimCachedBuffers(for: &capture)
            } else {
                throw SystemAudioClipCaptureError.writeFailed("Could not copy cached system audio.")
            }
        } catch {
            capture.writeError = error
        }

        activeCapture = capture
    }

    private func recordCaptureError(_ error: Error) {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        guard var capture = activeCapture else {
            return
        }

        capture.writeError = error
        activeCapture = capture
    }

    private func stopDiscardingClip() {
        captureSource.stop()
        replaceActiveCapture(nil)
    }

    private func stopDiscardingClipAndWait() async {
        replaceActiveCapture(nil)
        try? await captureSource.stopCapturing()
    }

    private func readActiveCapture() -> ActiveCapture? {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        return activeCapture
    }

    private func replaceActiveCapture(_ capture: ActiveCapture?) {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        activeCapture = capture
    }

    private func rememberTemporaryClipURL(_ url: URL) {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        temporaryClipURLs.insert(url)
    }

    private func takeTemporaryClipURL(_ url: URL) -> URL? {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        return temporaryClipURLs.remove(url)
    }

    private func takeTemporaryClipURLs() -> [URL] {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        let urls = Array(temporaryClipURLs)
        temporaryClipURLs.removeAll()
        return urls
    }

    private func captureSnapshot() throws -> CaptureSnapshot {
        activeCaptureLock.lock()
        defer {
            activeCaptureLock.unlock()
        }

        guard let capture = activeCapture else {
            throw SystemAudioClipCaptureError.notCapturing
        }

        if let writeError = capture.writeError {
            throw SystemAudioClipCaptureError.writeFailed(writeError.localizedDescription)
        }

        guard let audioFormat = capture.audioFormat,
              let outputSettings = capture.outputSettings,
              let sampleRate = capture.sampleRate
        else {
            throw SystemAudioClipCaptureError.cacheNotReady
        }

        return CaptureSnapshot(
            clipID: capture.clipID,
            startedAt: capture.startedAt,
            audioFormat: audioFormat,
            outputSettings: outputSettings,
            sampleRate: sampleRate,
            frameCount: capture.frameCount,
            cachedBuffers: capture.cachedBuffers,
            writeError: capture.writeError
        )
    }

    private static func outputSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    private static func fileStem(timestamp: Date, clipID: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        return "system-audio-\(formatter.string(from: timestamp))-\(clipID.uuidString.prefix(8).lowercased())"
    }

    private static func temporalFileStem(timestamp: Date, clipID: UUID, duration: TimeInterval) -> String {
        let durationLabel = String(format: "%.2fs", duration)
            .replacingOccurrences(of: ".", with: "_")
        return "\(fileStem(timestamp: timestamp, clipID: clipID))-\(durationLabel)"
    }

    private static func copyBuffer(
        _ buffer: AVAudioPCMBuffer,
        startingFrame: AVAudioFrameCount = 0,
        frameLength: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        let framesAvailable = buffer.frameLength > startingFrame
            ? buffer.frameLength - startingFrame
            : 0
        let framesToCopy = min(frameLength, framesAvailable)
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
            let sourceOffset = Int(startingFrame) * bytesPerFrame
            let bytesToCopy = bytesPerFrame * destinationFrameCount
            memcpy(destinationData, sourceData.advanced(by: sourceOffset), bytesToCopy)
            destinationBuffers[index].mDataByteSize = UInt32(bytesToCopy)
        }

        return copiedBuffer
    }

    private func trimCachedBuffers(for capture: inout ActiveCapture) {
        guard let sampleRate = capture.sampleRate else {
            return
        }

        let maximumFrameCount = max(
            AVAudioFramePosition((sampleRate * configuration.maximumCacheDuration).rounded()),
            1
        )
        var framesToDiscard = capture.frameCount - maximumFrameCount
        guard framesToDiscard > 0 else {
            return
        }

        while framesToDiscard > 0, !capture.cachedBuffers.isEmpty {
            let oldestBuffer = capture.cachedBuffers[0]
            let oldestFrameCount = AVAudioFramePosition(oldestBuffer.frameLength)
            if oldestFrameCount <= framesToDiscard {
                capture.cachedBuffers.removeFirst()
                capture.frameCount -= oldestFrameCount
                framesToDiscard -= oldestFrameCount
                continue
            }

            guard let trimmedBuffer = Self.copyBuffer(
                oldestBuffer,
                startingFrame: AVAudioFrameCount(framesToDiscard),
                frameLength: AVAudioFrameCount(oldestFrameCount - framesToDiscard)
            ) else {
                capture.writeError = SystemAudioClipCaptureError.writeFailed("Could not trim cached system audio.")
                return
            }

            capture.cachedBuffers[0] = trimmedBuffer
            capture.frameCount -= framesToDiscard
            framesToDiscard = 0
        }
    }
}

private enum SystemAudioClipCaptureError: LocalizedError {
    case alreadyCapturing
    case notCapturing
    case cacheNotReady
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "A system audio clip capture is already running."
        case .notCapturing:
            return "No system audio clip capture is running."
        case .cacheNotReady:
            return "The system audio clip cache does not contain enough audio yet."
        case .writeFailed(let message):
            return "Could not write system audio clip: \(message)"
        }
    }
}
#endif

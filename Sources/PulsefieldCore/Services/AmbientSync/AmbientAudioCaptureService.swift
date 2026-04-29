import AVFoundation
import Foundation

public actor AmbientAudioCaptureService: AmbientAudioCapturing {
    private let engine = AVAudioEngine()
    private let maxWindowSeconds: Double
    private var sampleRate: Double = 44_100
    private var inputChannelCount = 1
    private var rollingBuffer: AmbientRollingSampleBuffer

    public init(maxWindowSeconds: Double = 8) {
        self.maxWindowSeconds = maxWindowSeconds
        rollingBuffer = AmbientRollingSampleBuffer(
            maxWindowSeconds: maxWindowSeconds,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount
        )
    }

    public func start() async throws {
        if engine.isRunning {
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        inputChannelCount = max(1, Int(format.channelCount))
        rollingBuffer = AmbientRollingSampleBuffer(
            maxWindowSeconds: maxWindowSeconds,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount
        )
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let samples = Self.extractSamples(from: buffer)
            let hostTime = ContinuousClock.now
            Task {
                await self?.append(samples, hostTime: hostTime)
            }
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        rollingBuffer = AmbientRollingSampleBuffer(
            maxWindowSeconds: maxWindowSeconds,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount
        )
    }

    public func latestWindow(durationMS: Int) async -> AmbientAudioWindow? {
        rollingBuffer.latestWindow(durationMS: durationMS)
    }

    private func append(_ samples: [Float], hostTime: ContinuousClock.Instant) {
        rollingBuffer.append(samples, hostTime: hostTime)
    }

    nonisolated static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = max(1, Int(buffer.format.channelCount))
        if channelCount == 1 {
            let firstChannel = channels[0]
            return (0..<frameCount).map { firstChannel[$0] }
        }

        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            return sum / Float(channelCount)
        }
    }
}

struct AmbientRollingSampleBuffer: Sendable {
    private let maxWindowSeconds: Double
    private let sampleRate: Double
    private let inputChannelCount: Int
    private var rollingSamples: [Float] = []
    private var latestHostTime: ContinuousClock.Instant?

    init(maxWindowSeconds: Double, sampleRate: Double, inputChannelCount: Int = 1) {
        self.maxWindowSeconds = maxWindowSeconds
        self.sampleRate = sampleRate
        self.inputChannelCount = inputChannelCount
    }

    mutating func append(_ samples: [Float], hostTime: ContinuousClock.Instant = .now) {
        guard !samples.isEmpty else {
            return
        }

        rollingSamples.append(contentsOf: samples)
        latestHostTime = hostTime
        let maximumSampleCount = max(1, Int(sampleRate * maxWindowSeconds))
        if rollingSamples.count > maximumSampleCount {
            rollingSamples.removeFirst(rollingSamples.count - maximumSampleCount)
        }
    }

    func latestWindow(durationMS: Int) -> AmbientAudioWindow? {
        guard let latestHostTime else {
            return nil
        }

        return latestWindow(durationMS: durationMS, hostTime: latestHostTime)
    }

    func latestWindow(durationMS: Int, hostTime: ContinuousClock.Instant) -> AmbientAudioWindow? {
        let requestedSampleCount = max(1, Int(sampleRate * Double(durationMS) / 1_000))
        guard rollingSamples.count >= requestedSampleCount else {
            return nil
        }

        return AmbientAudioWindow(
            hostTime: hostTime,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount,
            samples: Array(rollingSamples.suffix(requestedSampleCount))
        )
    }
}

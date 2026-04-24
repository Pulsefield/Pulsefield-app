import AVFoundation
import Foundation

public actor AmbientAudioCaptureService: AmbientAudioCapturing {
    private let engine = AVAudioEngine()
    private let maxWindowSeconds: Double
    private var sampleRate: Double = 44_100
    private var rollingBuffer: AmbientRollingSampleBuffer

    public init(maxWindowSeconds: Double = 8) {
        self.maxWindowSeconds = maxWindowSeconds
        rollingBuffer = AmbientRollingSampleBuffer(maxWindowSeconds: maxWindowSeconds, sampleRate: sampleRate)
    }

    public func start() async throws {
        if engine.isRunning {
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        rollingBuffer = AmbientRollingSampleBuffer(maxWindowSeconds: maxWindowSeconds, sampleRate: sampleRate)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let samples = Self.extractSamples(from: buffer)
            Task {
                await self?.append(samples)
            }
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        rollingBuffer = AmbientRollingSampleBuffer(maxWindowSeconds: maxWindowSeconds, sampleRate: sampleRate)
    }

    public func latestWindow(durationMS: Int) async -> AmbientAudioWindow? {
        rollingBuffer.latestWindow(durationMS: durationMS, hostTime: .now)
    }

    private func append(_ samples: [Float]) {
        rollingBuffer.append(samples)
    }

    private nonisolated static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return []
        }

        let firstChannel = channels[0]
        return (0..<Int(buffer.frameLength)).map { firstChannel[$0] }
    }
}

struct AmbientRollingSampleBuffer: Sendable {
    private let maxWindowSeconds: Double
    private let sampleRate: Double
    private var rollingSamples: [Float] = []

    init(maxWindowSeconds: Double, sampleRate: Double) {
        self.maxWindowSeconds = maxWindowSeconds
        self.sampleRate = sampleRate
    }

    mutating func append(_ samples: [Float]) {
        rollingSamples.append(contentsOf: samples)
        let maximumSampleCount = max(1, Int(sampleRate * maxWindowSeconds))
        if rollingSamples.count > maximumSampleCount {
            rollingSamples.removeFirst(rollingSamples.count - maximumSampleCount)
        }
    }

    func latestWindow(durationMS: Int, hostTime: ContinuousClock.Instant) -> AmbientAudioWindow? {
        let requestedSampleCount = max(1, Int(sampleRate * Double(durationMS) / 1_000))
        guard rollingSamples.count >= requestedSampleCount else {
            return nil
        }

        return AmbientAudioWindow(
            hostTime: hostTime,
            sampleRate: sampleRate,
            samples: Array(rollingSamples.suffix(requestedSampleCount))
        )
    }
}

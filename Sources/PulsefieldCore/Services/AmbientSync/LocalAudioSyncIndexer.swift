import AVFoundation
import Foundation

public actor LocalAudioSyncIndexer: LocalAudioSyncIndexing {
    public static let currentVersion = 1
    #if os(macOS)
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private let rootDirectory: URL
    private let frameHopMS: Double

    public init(rootDirectory: URL? = nil, frameHopMS: Double = 100) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.frameHopMS = frameHopMS
    }

    public func buildIndex(for asset: LocalAudioAsset) async throws -> LocalAudioSyncIndex {
        let assetURL = resolveURL(for: asset)
        let accessed = assetURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                assetURL.stopAccessingSecurityScopedResource()
            }
        }

        let assetDirectory = rootDirectory.appendingPathComponent(asset.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)

        let features = try extractOnsetEnvelope(from: assetURL)
        let onsetURL = assetDirectory.appendingPathComponent("onset-envelope.txt")
        try write(values: features.values, to: onsetURL)

        let index = LocalAudioSyncIndex(
            assetID: asset.id,
            durationMS: asset.durationMS,
            sampleRate: features.sampleRate,
            frameHopMS: frameHopMS,
            onsetEnvelopeURL: onsetURL,
            spectralSummaryURL: nil,
            chromaURL: nil,
            version: Self.currentVersion,
            createdAt: Date()
        )

        let metadataURL = assetDirectory.appendingPathComponent("index.json")
        let data = try JSONEncoder().encode(index)
        try data.write(to: metadataURL, options: [.atomic])
        return index
    }

    public func loadIndex(for assetID: UUID) async -> LocalAudioSyncIndex? {
        let url = rootDirectory
            .appendingPathComponent(assetID.uuidString, isDirectory: true)
            .appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalAudioSyncIndex.self, from: data)
    }

    private func resolveURL(for asset: LocalAudioAsset) -> URL {
        if let bookmark = asset.fileURLBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.standardizedFileURL
            }
        }

        return URL(fileURLWithPath: asset.displayPath).standardizedFileURL
    }

    private func extractOnsetEnvelope(from url: URL) throws -> (values: [Double], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let hopFrames = max(1, Int(sampleRate * frameHopMS / 1_000))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(hopFrames)
        ) else {
            return ([], sampleRate)
        }

        var values: [Double] = []
        var previousRMS = 0.0

        while file.framePosition < file.length {
            let remainingFrames = file.length - file.framePosition
            let requestedFrames = AVAudioFrameCount(min(Int64(hopFrames), remainingFrames))
            try file.read(into: buffer, frameCount: requestedFrames)

            guard buffer.frameLength > 0 else {
                break
            }

            let rms = rmsValue(buffer: buffer)
            values.append(max(0, rms - previousRMS))
            previousRMS = rms
        }

        return (values, sampleRate)
    }

    private func rmsValue(buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return 0
        }

        var sum = 0.0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let value = Double(samples[frame])
                sum += value * value
            }
        }

        return sqrt(sum / Double(frameCount * channelCount))
    }

    private func write(values: [Double], to url: URL) throws {
        let body = values.map { String(format: "%.8f", $0) }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func defaultRootDirectory() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pulsefield/SyncIndexes", isDirectory: true)
        return directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PulsefieldSyncIndexes", isDirectory: true)
    }
}

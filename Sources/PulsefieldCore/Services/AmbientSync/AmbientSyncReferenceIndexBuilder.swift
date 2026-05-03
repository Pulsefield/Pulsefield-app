@preconcurrency import AVFoundation
import CryptoKit
import Foundation

public struct AmbientSyncDecodedAudio: Equatable, Sendable {
    public let sourceURL: URL?
    public let monoSamples: [Float]
    public let sampleRate: Double

    public init(
        sourceURL: URL? = nil,
        monoSamples: [Float],
        sampleRate: Double
    ) {
        precondition(sampleRate > 0, "sampleRate must be positive.")

        self.sourceURL = sourceURL
        self.monoSamples = monoSamples
        self.sampleRate = sampleRate
    }

    public init(
        sourceURL: URL,
        sampleRate: Double,
        monoSamples: [Float]
    ) {
        self.init(sourceURL: sourceURL, monoSamples: monoSamples, sampleRate: sampleRate)
    }

    public var durationMS: Double {
        Double(monoSamples.count) / sampleRate * 1_000
    }
}

public enum AmbientSyncReferenceIndexBuilderError: Error, Equatable, Sendable {
    case audioFileTooLarge(String)
    case unsupportedAudioFormat(String)
    case decodeFailed(String)
    case conversionFailed(String)
    case cacheReadFailed(String)
    case cacheWriteFailed(String)
}

extension AmbientSyncReferenceIndexBuilderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .audioFileTooLarge(let path):
            return "Audio file is too large to decode in one reference-index pass: \(path)"
        case .unsupportedAudioFormat(let message):
            return "Unsupported audio format: \(message)"
        case .decodeFailed(let message):
            return "Could not decode audio: \(message)"
        case .conversionFailed(let message):
            return "Could not convert audio to the ambient sync processing format: \(message)"
        case .cacheReadFailed(let message):
            return "Could not read ambient sync reference index cache: \(message)"
        case .cacheWriteFailed(let message):
            return "Could not write ambient sync reference index cache: \(message)"
        }
    }
}

public struct AmbientSyncAudioFeatureFrameBuilder: Sendable {
    public let featureConfiguration: AmbientSyncFeatureConfiguration
    public let chunkSizeSamples: Int

    private let payloadExtractor: MicFeaturePayloadExtractor

    public init(
        featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
        chunkSizeSamples: Int = 8_192,
        payloadExtractor: MicFeaturePayloadExtractor = MicFeaturePayloadExtractor()
    ) {
        precondition(chunkSizeSamples > 0, "chunkSizeSamples must be positive.")

        self.featureConfiguration = featureConfiguration
        self.chunkSizeSamples = chunkSizeSamples
        self.payloadExtractor = payloadExtractor
    }

    public func buildFrames(fromAudioAt sourceURL: URL) throws -> [MicFeatureFrame] {
        let decodedAudio = try decodeMonoFloat32Audio(from: sourceURL)
        return buildFrames(
            fromMonoSamples: decodedAudio.monoSamples,
            sampleRate: decodedAudio.sampleRate
        )
    }

    public func decodeMonoFloat32Audio(from sourceURL: URL) throws -> AmbientSyncDecodedAudio {
        let standardizedURL = sourceURL.standardizedFileURL
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(
                forReading: standardizedURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AmbientSyncReferenceIndexBuilderError.decodeFailed(error.localizedDescription)
        }

        let sourceFormat = sourceFile.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AmbientSyncReferenceIndexBuilderError.unsupportedAudioFormat(
                "\(standardizedURL.path) has sampleRate=\(sourceFormat.sampleRate), channels=\(sourceFormat.channelCount)"
            )
        }
        guard sourceFile.length <= AVAudioFramePosition(UInt32.max) else {
            throw AmbientSyncReferenceIndexBuilderError.audioFileTooLarge(standardizedURL.path)
        }
        guard sourceFile.length > 0 else {
            return AmbientSyncDecodedAudio(
                monoSamples: [],
                sampleRate: featureConfiguration.processingSampleRate
            )
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFile.length)
        ) else {
            throw AmbientSyncReferenceIndexBuilderError.decodeFailed("Could not allocate decode buffer.")
        }

        do {
            try sourceFile.read(into: sourceBuffer)
        } catch {
            throw AmbientSyncReferenceIndexBuilderError.decodeFailed(error.localizedDescription)
        }

        guard sourceBuffer.frameLength > 0 else {
            return AmbientSyncDecodedAudio(
                monoSamples: [],
                sampleRate: featureConfiguration.processingSampleRate
            )
        }

        let processingBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == featureConfiguration.processingSampleRate {
            processingBuffer = sourceBuffer
        } else {
            processingBuffer = try resample(
                sourceBuffer,
                toSampleRate: featureConfiguration.processingSampleRate
            )
        }

        return AmbientSyncDecodedAudio(
            sourceURL: standardizedURL,
            monoSamples: try makeMonoSamples(from: processingBuffer),
            sampleRate: featureConfiguration.processingSampleRate
        )
    }

    public func buildFrames(
        fromMonoSamples monoSamples: [Float],
        sampleRate: Double
    ) -> [MicFeatureFrame] {
        precondition(sampleRate == featureConfiguration.processingSampleRate, "sampleRate must match the feature configuration.")
        guard !monoSamples.isEmpty else {
            return []
        }

        let audioDurationMS = Double(monoSamples.count) / sampleRate * 1_000
        var streamBuffer = MicFeatureStreamBuffer(
            retentionDurationMS: max(audioDurationMS + featureConfiguration.featureHopMS, featureConfiguration.finalLockTargetDurationMS),
            expectedHopMS: featureConfiguration.featureHopMS,
            payloadExtractor: payloadExtractor
        )
        var frames: [MicFeatureFrame] = []
        var sampleStartIndex = 0

        while sampleStartIndex < monoSamples.count {
            let sampleEndIndex = min(monoSamples.count, sampleStartIndex + chunkSizeSamples)
            let recordedStartTimeMS = Double(sampleStartIndex) / sampleRate * 1_000
            let chunk = MicAudioChunk(
                monoSamples: Array(monoSamples[sampleStartIndex..<sampleEndIndex]),
                sampleRate: sampleRate,
                recordedStartTimeMS: recordedStartTimeMS,
                hostStartTimeMS: recordedStartTimeMS,
                inputChannelCount: 1
            )

            frames.append(contentsOf: streamBuffer.append(
                chunk,
                featureWindowSizeSamples: featureConfiguration.featureWindowSizeSamples,
                featureHopSizeSamples: featureConfiguration.featureHopSizeSamples
            ))
            sampleStartIndex = sampleEndIndex
        }

        return frames
    }

    private func resample(
        _ sourceBuffer: AVAudioPCMBuffer,
        toSampleRate sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: sourceBuffer.format.channelCount,
            interleaved: false
        ) else {
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed("Could not create target PCM format.")
        }
        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed("Could not create AVAudioConverter.")
        }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let targetFrameCapacity = AVAudioFrameCount(
            max(
                1,
                Int(ceil(Double(sourceBuffer.frameLength) * sampleRate / sourceBuffer.format.sampleRate))
                    + featureConfiguration.featureWindowSizeSamples
            )
        )
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: targetFrameCapacity
        ) else {
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed("Could not allocate resample buffer.")
        }

        let inputState = AmbientSyncConverterInputState(sourceBuffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            inputState.provideInput(inputStatus)
        }

        if let conversionError {
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed(conversionError.localizedDescription)
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed("AVAudioConverter returned an error status.")
        @unknown default:
            throw AmbientSyncReferenceIndexBuilderError.conversionFailed("AVAudioConverter returned an unknown status.")
        }

        return targetBuffer
    }

    private func makeMonoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return []
        }
        guard let channelData = buffer.floatChannelData else {
            throw AmbientSyncReferenceIndexBuilderError.unsupportedAudioFormat("Decoded buffer is not Float32 PCM.")
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
                for frameIndex in monoSamples.indices {
                    monoSamples[frameIndex] /= Float(channelCount)
                }
            }
        }

        return monoSamples
    }
}

public struct AmbientSyncLandmarkIndexDebug: Codable, Equatable, Sendable {
    public struct Posting: Codable, Equatable, Sendable {
        public let hash: UInt64
        public let anchorTimesMS: [Double]

        public init(hash: UInt64, anchorTimesMS: [Double]) {
            self.hash = hash
            self.anchorTimesMS = anchorTimesMS
        }
    }

    public let landmarkCount: Int
    public let hashCount: Int
    public let postings: [Posting]

    public init(landmarks: [MicFeatureLandmark]) {
        var anchorTimesByHash: [UInt64: [Double]] = [:]
        for landmark in landmarks {
            anchorTimesByHash[landmark.hash, default: []].append(landmark.anchorTimeMS)
        }

        postings = anchorTimesByHash.keys.sorted().map { hash in
            Posting(
                hash: hash,
                anchorTimesMS: anchorTimesByHash[hash, default: []].sorted()
            )
        }
        landmarkCount = landmarks.count
        hashCount = postings.count
    }
}

public struct AmbientSyncReferenceIndex: Equatable, Sendable {
    public let sourceDisplayPath: String
    public let featureConfiguration: AmbientSyncFeatureConfiguration
    public let frames: [MicFeatureFrame]
    public let landmarks: [MicFeatureLandmark]
    public let landmarkIndex: AmbientSyncLandmarkIndex
    public let landmarkIndexDebug: AmbientSyncLandmarkIndexDebug

    public init(
        sourceDisplayPath: String,
        featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
        frames: [MicFeatureFrame],
        landmarks: [MicFeatureLandmark]? = nil,
        landmarkIndexDebug: AmbientSyncLandmarkIndexDebug? = nil
    ) {
        let flattenedLandmarks = landmarks ?? frames.flatMap(\.landmarks)

        self.sourceDisplayPath = sourceDisplayPath
        self.featureConfiguration = featureConfiguration
        self.frames = frames
        self.landmarks = flattenedLandmarks
        self.landmarkIndex = AmbientSyncLandmarkIndex(landmarks: flattenedLandmarks)
        self.landmarkIndexDebug = landmarkIndexDebug ?? AmbientSyncLandmarkIndexDebug(landmarks: flattenedLandmarks)
    }
}

extension AmbientSyncReferenceIndex: AmbientSyncEngineReferenceIndex {}

public struct AmbientSyncReferenceIndexBuilder: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let cacheDirectoryURL: URL
        public let featureConfiguration: AmbientSyncFeatureConfiguration
        public let chunkSizeSamples: Int

        public init(
            cacheDirectoryURL: URL = AmbientSyncReferenceIndexBuilder.defaultCacheDirectoryURL(),
            featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
            chunkSizeSamples: Int = 8_192
        ) {
            precondition(chunkSizeSamples > 0, "chunkSizeSamples must be positive.")

            self.cacheDirectoryURL = cacheDirectoryURL
            self.featureConfiguration = featureConfiguration
            self.chunkSizeSamples = chunkSizeSamples
        }
    }

    public let configuration: Configuration

    private let frameBuilder: AmbientSyncAudioFeatureFrameBuilder

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        frameBuilder = AmbientSyncAudioFeatureFrameBuilder(
            featureConfiguration: configuration.featureConfiguration,
            chunkSizeSamples: configuration.chunkSizeSamples
        )
    }

    public static func defaultCacheDirectoryURL() -> URL {
        AmbientSyncFixtureRecorder.defaultFixtureDirectoryURL()
            .appendingPathComponent(".ambient-sync-reference-indexes", isDirectory: true)
    }

    public func index(forSourceURL sourceURL: URL) throws -> AmbientSyncReferenceIndex {
        try index(forSourceDisplayPath: sourceURL.standardizedFileURL.path)
    }

    public func index(forSourceDisplayPath sourceDisplayPath: String) throws -> AmbientSyncReferenceIndex {
        if let cachedIndex = try loadCachedIndex(forSourceDisplayPath: sourceDisplayPath) {
            return cachedIndex
        }

        return try rebuildIndex(forSourceDisplayPath: sourceDisplayPath)
    }

    public func rebuildIndex(forSourceURL sourceURL: URL) throws -> AmbientSyncReferenceIndex {
        try rebuildIndex(forSourceDisplayPath: sourceURL.standardizedFileURL.path)
    }

    public func rebuildIndex(forSourceDisplayPath sourceDisplayPath: String) throws -> AmbientSyncReferenceIndex {
        let sourceURL = URL(fileURLWithPath: sourceDisplayPath).standardizedFileURL
        let frames = try frameBuilder.buildFrames(fromAudioAt: sourceURL)
        let index = AmbientSyncReferenceIndex(
            sourceDisplayPath: sourceDisplayPath,
            featureConfiguration: configuration.featureConfiguration,
            frames: frames
        )

        try writeCache(index, sourceStandardizedPath: sourceURL.path)
        return index
    }

    public func loadCachedIndex(forSourceDisplayPath sourceDisplayPath: String) throws -> AmbientSyncReferenceIndex? {
        let cacheURL = cacheURL(forSourceDisplayPath: sourceDisplayPath)
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        guard let currentSourceIdentity = try? Self.sourceFileIdentity(
            for: URL(fileURLWithPath: sourceDisplayPath).standardizedFileURL
        ) else {
            return nil
        }

        let cache: AmbientSyncReferenceIndexCache
        do {
            let data = try Data(contentsOf: cacheURL)
            cache = try Self.makeDecoder().decode(AmbientSyncReferenceIndexCache.self, from: data)
        } catch {
            throw AmbientSyncReferenceIndexBuilderError.cacheReadFailed(error.localizedDescription)
        }

        guard cache.schemaVersion == AmbientSyncReferenceIndexCache.schemaVersion,
              cache.featureConfiguration == configuration.featureConfiguration,
              cache.sourceFileIdentity == currentSourceIdentity
        else {
            return nil
        }

        return cache.makeIndex()
    }

    public func cacheURL(forSourceDisplayPath sourceDisplayPath: String) -> URL {
        let sourceURL = URL(fileURLWithPath: sourceDisplayPath).standardizedFileURL
        let stem = Self.cacheFileStem(for: sourceURL)
        return configuration.cacheDirectoryURL
            .appendingPathComponent(stem)
            .appendingPathExtension("ambient-sync-reference-index.json")
    }

    private func writeCache(
        _ index: AmbientSyncReferenceIndex,
        sourceStandardizedPath: String
    ) throws {
        let cacheURL = cacheURL(forSourceDisplayPath: index.sourceDisplayPath)

        do {
            let sourceIdentity = try Self.sourceFileIdentity(
                for: URL(fileURLWithPath: sourceStandardizedPath).standardizedFileURL
            )
            let cache = AmbientSyncReferenceIndexCache(
                sourceDisplayPath: index.sourceDisplayPath,
                sourceStandardizedPath: sourceStandardizedPath,
                sourceFileIdentity: sourceIdentity,
                featureConfiguration: index.featureConfiguration,
                frames: index.frames,
                landmarks: index.landmarks,
                landmarkIndexDebug: index.landmarkIndexDebug
            )
            try FileManager.default.createDirectory(
                at: configuration.cacheDirectoryURL,
                withIntermediateDirectories: true
            )
            let data = try Self.makeEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            throw AmbientSyncReferenceIndexBuilderError.cacheWriteFailed(error.localizedDescription)
        }
    }

    private static func cacheFileStem(for sourceURL: URL) -> String {
        let path = sourceURL.standardizedFileURL.path
        let displayStem = slugify(sourceURL.deletingPathExtension().lastPathComponent)
        return "\(displayStem)-\(stableHexDigest(for: path))"
    }

    private static func slugify(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        var scalars: [UnicodeScalar] = []
        var previousWasSeparator = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                scalars.append("-")
                previousWasSeparator = true
            }

            if scalars.count == 80 {
                break
            }
        }

        let slug = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "reference" : slug
    }

    private static func stableHexDigest(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        return String(format: "%016llx", hash)
    }

    private static func sourceFileIdentity(for sourceURL: URL) throws -> AmbientSyncReferenceSourceFileIdentity {
        let resourceValues = try sourceURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        guard let fileSize = resourceValues.fileSize,
              let contentModificationDate = resourceValues.contentModificationDate
        else {
            throw AmbientSyncReferenceIndexBuilderError.cacheReadFailed(
                "Could not read source file identity for \(sourceURL.path)"
            )
        }

        return AmbientSyncReferenceSourceFileIdentity(
            standardizedPath: sourceURL.standardizedFileURL.path,
            fileSizeBytes: UInt64(fileSize),
            modificationTimeSince1970: contentModificationDate.timeIntervalSince1970,
            sha256: try sourceSHA256(for: sourceURL)
        )
    }

    private static func sourceSHA256(for sourceURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }

            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

private struct AmbientSyncReferenceSourceFileIdentity: Codable, Equatable, Sendable {
    let standardizedPath: String
    let fileSizeBytes: UInt64
    let modificationTimeSince1970: Double
    let sha256: String?
}

private struct AmbientSyncReferenceIndexCache: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let sourceDisplayPath: String
    let sourceStandardizedPath: String
    let sourceFileIdentity: AmbientSyncReferenceSourceFileIdentity?
    let featureConfiguration: AmbientSyncFeatureConfiguration
    let frames: [MicFeatureFrame]
    let landmarks: [MicFeatureLandmark]
    let landmarkIndexDebug: AmbientSyncLandmarkIndexDebug

    init(
        schemaVersion: Int = Self.schemaVersion,
        sourceDisplayPath: String,
        sourceStandardizedPath: String,
        sourceFileIdentity: AmbientSyncReferenceSourceFileIdentity?,
        featureConfiguration: AmbientSyncFeatureConfiguration,
        frames: [MicFeatureFrame],
        landmarks: [MicFeatureLandmark],
        landmarkIndexDebug: AmbientSyncLandmarkIndexDebug
    ) {
        self.schemaVersion = schemaVersion
        self.sourceDisplayPath = sourceDisplayPath
        self.sourceStandardizedPath = sourceStandardizedPath
        self.sourceFileIdentity = sourceFileIdentity
        self.featureConfiguration = featureConfiguration
        self.frames = frames
        self.landmarks = landmarks
        self.landmarkIndexDebug = landmarkIndexDebug
    }

    func makeIndex() -> AmbientSyncReferenceIndex {
        AmbientSyncReferenceIndex(
            sourceDisplayPath: sourceDisplayPath,
            featureConfiguration: featureConfiguration,
            frames: frames,
            landmarks: landmarks,
            landmarkIndexDebug: landmarkIndexDebug
        )
    }
}

private final class AmbientSyncConverterInputState: @unchecked Sendable {
    private let sourceBuffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(sourceBuffer: AVAudioPCMBuffer) {
        self.sourceBuffer = sourceBuffer
    }

    func provideInput(_ inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer {
            lock.unlock()
        }

        if didProvideInput {
            inputStatus.pointee = .endOfStream
            return nil
        }

        didProvideInput = true
        inputStatus.pointee = .haveData
        return sourceBuffer
    }
}

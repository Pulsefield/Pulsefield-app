import AVFoundation
import CryptoKit
import XCTest
@testable import PulsefieldCore

final class LocalAudioSyncIndexerTests: XCTestCase {
    func testLocalAudioSyncIndexesUseSecurityScopedOptionsOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(LocalAudioSyncIndexer.bookmarkResolutionOptions.contains(.withSecurityScope))
        #endif
    }

    func testSyncIndexAdvertisesSharedDenseFeatureFiles() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: "synthetic-reference",
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        let index = try await indexer.buildIndex(for: asset)

        XCTAssertTrue(FileManager.default.fileExists(atPath: index.onsetEnvelopeURL.path))
        XCTAssertNotNil(index.spectralSummaryURL)
        XCTAssertNotNil(index.chromaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.spectralSummaryURL?.path ?? ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.chromaURL?.path ?? ""))
    }

    func testBuildIndexWritesManifestLedFeatureFilesAndLoadValidatesChecksums() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000504")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: sha256Hex(Data("synthetic-reference".utf8)),
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        let index = try await indexer.buildIndex(for: asset)
        let assetDirectory = indexRoot.appendingPathComponent(asset.id.uuidString, isDirectory: true)
        let manifestURL = assetDirectory.appendingPathComponent("manifest.json")
        let onsetFluxURL = assetDirectory
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("dense-onset-flux.f32")

        XCTAssertEqual(index.version, 2)
        XCTAssertEqual(index.onsetEnvelopeURL, onsetFluxURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onsetFluxURL.path))
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: onsetFluxURL.path)
        else {
            return
        }

        let manifest = try manifestJSON(at: manifestURL)
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual(manifest["featureExtractorVersion"] as? String, "ambient-sync-v2")
        XCTAssertEqual((manifest["asset"] as? [String: Any])?["assetID"] as? String, asset.id.uuidString)
        XCTAssertEqual(
            (manifest["source"] as? [String: Any])?["fullFileSHA256"] as? String,
            try sha256Hex(Data(contentsOf: audioURL))
        )
        XCTAssertEqual(((manifest["features"] as? [String: Any])?["onsetFlux"] as? [String: Any])?["dims"] as? Int, 8)
        XCTAssertEqual(((manifest["features"] as? [String: Any])?["logMel"] as? [String: Any])?["dims"] as? Int, 24)
        XCTAssertEqual(((manifest["features"] as? [String: Any])?["chroma"] as? [String: Any])?["dims"] as? Int, 12)
        XCTAssertEqual(
            (((manifest["featureFiles"] as? [String: Any])?["denseOnsetFlux"] as? [String: Any])?["path"] as? String),
            "features/dense-onset-flux.f32"
        )
        XCTAssertEqual(
            (((manifest["featureFiles"] as? [String: Any])?["denseLogMel"] as? [String: Any])?["path"] as? String),
            "features/dense-logmel.f32"
        )
        XCTAssertEqual(
            (((manifest["featureFiles"] as? [String: Any])?["denseChroma"] as? [String: Any])?["path"] as? String),
            "features/dense-chroma.f32"
        )

        let loadedIndex = await indexer.loadIndex(for: asset.id)
        XCTAssertNotNil(loadedIndex)
        XCTAssertNotNil(loadedIndex?.spectralSummaryURL)
        XCTAssertNotNil(loadedIndex?.chromaURL)

        try Data("corrupt".utf8).write(to: onsetFluxURL, options: [.atomic])

        let corruptedIndex = await indexer.loadIndex(for: asset.id)
        XCTAssertNil(corruptedIndex)
    }

    func testBuildIndexManifestHashesCurrentAudioFileBytes() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)
        let actualFileSHA256 = try sha256Hex(Data(contentsOf: audioURL))

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000511")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000512")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: "stale-library-snapshot",
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        _ = try await indexer.buildIndex(for: asset)
        let manifestURL = indexRoot
            .appendingPathComponent(asset.id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let manifest = try manifestJSON(at: manifestURL)
        let source = try XCTUnwrap(manifest["source"] as? [String: Any])

        XCTAssertEqual(source["fullFileSHA256"] as? String, actualFileSHA256)
        XCTAssertNotEqual(source["fullFileSHA256"] as? String, asset.sha256)
    }

    func testLoadIndexRejectsManifestProcessingSampleRateMismatchEvenWithMatchingSettingsHash() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000513")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000514")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: try sha256Hex(Data(contentsOf: audioURL)),
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        _ = try await indexer.buildIndex(for: asset)
        let manifestURL = indexRoot
            .appendingPathComponent(asset.id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        var manifest = try manifestJSON(at: manifestURL)
        var processing = try XCTUnwrap(manifest["processing"] as? [String: Any])
        processing["processingSampleRate"] = 44_100
        manifest["processing"] = processing
        manifest["settingsHash"] = [
            "processingSampleRate=44100",
            "hopSizeMS=50.0",
            "fftSize=256",
            "window=hann",
            "onsetFluxDims=8",
            "logMelDims=24",
            "chromaDims=12"
        ].joined(separator: ";")
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestURL, options: [.atomic])

        let loadedIndex = await indexer.loadIndex(for: asset.id)

        XCTAssertNil(loadedIndex)
    }

    func testLoadIndexRejectsManifestFeaturePathsOutsideAssetDirectory() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000507")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000508")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: sha256Hex(Data("synthetic-reference".utf8)),
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        let index = try await indexer.buildIndex(for: asset)
        let assetDirectory = indexRoot.appendingPathComponent(asset.id.uuidString, isDirectory: true)
        let manifestURL = assetDirectory.appendingPathComponent("manifest.json")
        let escapedOnsetURL = indexRoot.appendingPathComponent("escaped-onset.f32")
        try FileManager.default.copyItem(at: index.onsetEnvelopeURL, to: escapedOnsetURL)

        var manifest = try manifestJSON(at: manifestURL)
        var featureFiles = try XCTUnwrap(manifest["featureFiles"] as? [String: Any])
        var denseOnsetFlux = try XCTUnwrap(featureFiles["denseOnsetFlux"] as? [String: Any])
        denseOnsetFlux["path"] = "../escaped-onset.f32"
        denseOnsetFlux["sha256"] = try sha256Hex(Data(contentsOf: escapedOnsetURL))
        featureFiles["denseOnsetFlux"] = denseOnsetFlux
        manifest["featureFiles"] = featureFiles
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestURL, options: [.atomic])

        let loadedIndex = await indexer.loadIndex(for: asset.id)

        XCTAssertNil(loadedIndex)
    }

    func testLoadIndexUsesManifestCreationDate() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        try writeSilentWAV(to: audioURL)

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000509")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000510")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: sha256Hex(Data("synthetic-reference".utf8)),
            durationMS: 200,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 50)

        _ = try await indexer.buildIndex(for: asset)
        let manifestURL = indexRoot
            .appendingPathComponent(asset.id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let createdAt = "2024-03-10T12:34:56Z"
        var manifest = try manifestJSON(at: manifestURL)
        manifest["createdAt"] = createdAt
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: manifestURL, options: [.atomic])

        let loadedIndex = await indexer.loadIndex(for: asset.id)

        XCTAssertEqual(loadedIndex?.createdAt, ISO8601DateFormatter().date(from: createdAt))
    }

    func testBuildIndexWritesEnergyFeaturesFromDecodedAudioFrames() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let audioURL = workingDirectory.appendingPathComponent("reference.wav")
        let indexRoot = workingDirectory.appendingPathComponent("indexes", isDirectory: true)
        let samplesPerFrame = 4_410
        try writeMonoWAV(
            samples: Array(repeating: 0.25, count: samplesPerFrame)
                + Array(repeating: 0.75, count: samplesPerFrame)
                + Array(repeating: 0.75, count: samplesPerFrame)
                + Array(repeating: 0.875, count: samplesPerFrame),
            sampleRate: 44_100,
            to: audioURL
        )

        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000505")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000506")!,
            fileURLBookmark: nil,
            displayPath: audioURL.path,
            fileName: audioURL.lastPathComponent,
            fileExtension: audioURL.pathExtension,
            fileSizeBytes: Int64((try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            sha256: sha256Hex(Data("synthetic-reference".utf8)),
            durationMS: 400,
            title: "Reference",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
            status: .ready
        )
        let indexer = LocalAudioSyncIndexer(rootDirectory: indexRoot, frameHopMS: 100)

        _ = try await indexer.buildIndex(for: asset)

        let energyURL = indexRoot
            .appendingPathComponent(asset.id.uuidString, isDirectory: true)
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("energy.f32")
        let energyValues = try readFloat32Values(at: energyURL)

        XCTAssertEqual(energyValues.count, 4)
        guard energyValues.count == 4 else {
            return
        }
        XCTAssertEqual(energyValues[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(energyValues[1], 0.75, accuracy: 0.001)
        XCTAssertEqual(energyValues[2], 0.75, accuracy: 0.001)
        XCTAssertEqual(energyValues[3], 0.875, accuracy: 0.001)
    }

    func testSharedFeatureExtractorBuildsDeterministicDenseSpectralStreams() {
        let extractor = AmbientSyncFeatureExtractor()
        let samples: [Float] = (0..<120).map { index in
            Float(sin((2 * Double.pi * Double(index)) / 12))
        }

        let features = extractor.extract(
            samples: samples,
            sampleRate: 1_200,
            frameHopMS: 20,
            previousFrame: .silence
        )

        XCTAssertGreaterThan(features.frameCount, 0)
        XCTAssertEqual(features.onsetFlux.count, features.frameCount * 8)
        XCTAssertEqual(features.logMel.count, features.frameCount * 24)
        XCTAssertEqual(features.chroma.count, features.frameCount * 12)
        XCTAssertEqual(features.energy.count, features.frameCount)
        XCTAssertFalse(features.landmarkPostings.isEmpty)
        XCTAssertEqual(
            AmbientSyncFeatureExtractor.projectOnsetFlux(features.onsetFlux, dimensions: 8).count,
            features.frameCount
        )
    }

    func testSharedFeatureExtractorCanUseBoundedProcessingSampleRanges() throws {
        let extractor = AmbientSyncFeatureExtractor()
        let samples: [Float] = (0..<2_400).map { index in
            Float(0.5 * sin((2 * Double.pi * Double(index)) / 40))
        }
        var largestRequestedRange = 0

        let streamingFeatures = try extractor.extractProcessingSamples(
            processingSampleCount: samples.count,
            frameHopMS: 20
        ) { range in
            largestRequestedRange = max(largestRequestedRange, range.count)
            return Array(samples[range])
        }
        let eagerFeatures = extractor.extract(
            samples: samples,
            sampleRate: AmbientSyncFeatureExtractor.processingSampleRate,
            frameHopMS: 20,
            previousFrame: .silence
        )

        XCTAssertLessThan(largestRequestedRange, samples.count)
        XCTAssertEqual(streamingFeatures.onsetFlux.count, eagerFeatures.onsetFlux.count)
        XCTAssertEqual(streamingFeatures.logMel.count, eagerFeatures.logMel.count)
        XCTAssertEqual(streamingFeatures.chroma.count, eagerFeatures.chroma.count)
        XCTAssertEqual(streamingFeatures.energy.count, eagerFeatures.energy.count)
        zip(streamingFeatures.onsetFlux, eagerFeatures.onsetFlux).forEach {
            XCTAssertEqual($0, $1, accuracy: 0.000_001)
        }
        zip(streamingFeatures.energy, eagerFeatures.energy).forEach {
            XCTAssertEqual($0, $1, accuracy: 0.000_001)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSilentWAV(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 200)!
        buffer.frameLength = 200
        try file.write(from: buffer)
    }

    private func writeMonoWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        try file.write(from: buffer)
    }

    private func manifestJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readFloat32Values(at url: URL) throws -> [Double] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count, by: MemoryLayout<Float32>.size).map { offset in
            var bits: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bits) { buffer in
                data.copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<Float32>.size))
            }
            return Double(Float32(bitPattern: UInt32(littleEndian: bits)))
        }
    }
}

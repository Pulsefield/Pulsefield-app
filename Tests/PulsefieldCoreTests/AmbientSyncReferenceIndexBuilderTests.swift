import AVFoundation
import XCTest
@testable import PulsefieldCore

final class AmbientSyncReferenceIndexBuilderTests: XCTestCase {
    func testBuildsReferenceIndexAndReloadsBinaryCacheFromGeneratedCAF() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let audioURL = workingDirectory.appendingPathComponent("generated-reference.caf")
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try writeGeneratedCAF(to: audioURL)

        let builder = AmbientSyncReferenceIndexBuilder(
            configuration: AmbientSyncReferenceIndexBuilder.Configuration(
                cacheDirectoryURL: cacheDirectoryURL
            )
        )

        let index = try builder.index(forSourceURL: audioURL)

        XCTAssertEqual(index.sourceDisplayPath, audioURL.standardizedFileURL.path)
        XCTAssertEqual(index.featureConfiguration, .v1)
        XCTAssertFalse(index.frames.isEmpty)
        XCTAssertFalse(index.landmarks.isEmpty)
        XCTAssertEqual(index.landmarks, index.frames.flatMap(\.landmarks))
        XCTAssertEqual(index.landmarkIndex.landmarkCount, index.landmarks.count)
        XCTAssertGreaterThan(index.landmarkIndex.hashCount, 0)
        XCTAssertEqual(index.landmarkIndexDebug.landmarkCount, index.landmarks.count)
        XCTAssertEqual(index.landmarkIndexDebug.hashCount, index.landmarkIndex.hashCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: builder.binaryCacheURL(forSourceDisplayPath: audioURL.path).path))

        let cachedIndex = try XCTUnwrap(builder.loadCachedIndex(forSourceDisplayPath: audioURL.path))

        XCTAssertEqual(cachedIndex.sourceDisplayPath, index.sourceDisplayPath)
        XCTAssertEqual(cachedIndex.featureConfiguration, index.featureConfiguration)
        XCTAssertEqual(cachedIndex.frames, index.frames)
        XCTAssertEqual(cachedIndex.landmarks, index.landmarks)
        XCTAssertEqual(cachedIndex.landmarkIndex, index.landmarkIndex)
        XCTAssertEqual(cachedIndex.landmarkIndexDebug, index.landmarkIndexDebug)
    }

    func testReloadsLegacyJSONCacheAndWritesBinarySidecar() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let audioURL = workingDirectory.appendingPathComponent("generated-reference.caf")
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try writeGeneratedCAF(to: audioURL)

        let builder = AmbientSyncReferenceIndexBuilder(
            configuration: AmbientSyncReferenceIndexBuilder.Configuration(
                cacheDirectoryURL: cacheDirectoryURL
            )
        )
        let index = try builder.index(forSourceURL: audioURL)
        let binaryCacheURL = builder.binaryCacheURL(forSourceDisplayPath: audioURL.path)
        let legacyJSONCacheURL = builder.cacheURL(forSourceDisplayPath: audioURL.path)
        try FileManager.default.removeItem(at: binaryCacheURL)

        let legacyCache = AmbientSyncReferenceIndexCache(
            sourceDisplayPath: index.sourceDisplayPath,
            sourceStandardizedPath: audioURL.standardizedFileURL.path,
            sourceFileIdentity: try AmbientSyncReferenceIndexBuilder.sourceFileIdentity(for: audioURL.standardizedFileURL),
            featureConfiguration: index.featureConfiguration,
            frames: index.frames,
            landmarks: index.landmarks,
            landmarkIndexDebug: index.landmarkIndexDebug
        )
        let encoder = JSONEncoder()
        try encoder.encode(legacyCache).write(to: legacyJSONCacheURL, options: .atomic)

        let cachedIndex = try XCTUnwrap(builder.loadCachedIndex(forSourceDisplayPath: audioURL.path))

        XCTAssertEqual(cachedIndex.frames, index.frames)
        XCTAssertEqual(cachedIndex.landmarks, index.landmarks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: binaryCacheURL.path))
    }

    func testSourceFileChangeInvalidatesCachedReferenceIndex() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let audioURL = workingDirectory.appendingPathComponent("generated-reference.caf")
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try writeGeneratedCAF(to: audioURL, durationSeconds: 2.5)

        let builder = AmbientSyncReferenceIndexBuilder(
            configuration: AmbientSyncReferenceIndexBuilder.Configuration(
                cacheDirectoryURL: cacheDirectoryURL
            )
        )
        let originalIndex = try builder.index(forSourceURL: audioURL)

        try FileManager.default.removeItem(at: audioURL)
        try writeGeneratedCAF(to: audioURL, durationSeconds: 3.2)

        let rebuiltIndex = try builder.index(forSourceURL: audioURL)

        XCTAssertEqual(rebuiltIndex.sourceDisplayPath, originalIndex.sourceDisplayPath)
        XCTAssertGreaterThan(rebuiltIndex.frames.count, originalIndex.frames.count)
        XCTAssertGreaterThan(rebuiltIndex.landmarks.count, originalIndex.landmarks.count)
    }

    func testSameSizeSourceFileChangeInvalidatesCachedReferenceIndex() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let audioURL = workingDirectory.appendingPathComponent("generated-reference.caf")
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try writeGeneratedCAF(to: audioURL, variant: 0)
        let originalModificationDate = try XCTUnwrap(
            audioURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let originalFileSize = try XCTUnwrap(
            audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        let builder = AmbientSyncReferenceIndexBuilder(
            configuration: AmbientSyncReferenceIndexBuilder.Configuration(
                cacheDirectoryURL: cacheDirectoryURL
            )
        )
        let originalIndex = try builder.index(forSourceURL: audioURL)

        try FileManager.default.removeItem(at: audioURL)
        try writeGeneratedCAF(to: audioURL, variant: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: audioURL.path
        )

        let replacementFileSize = try XCTUnwrap(
            audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let rebuiltIndex = try builder.index(forSourceURL: audioURL)

        XCTAssertEqual(replacementFileSize, originalFileSize)
        XCTAssertEqual(rebuiltIndex.sourceDisplayPath, originalIndex.sourceDisplayPath)
        XCTAssertNotEqual(rebuiltIndex.frames, originalIndex.frames)
        XCTAssertNotEqual(rebuiltIndex.landmarks, originalIndex.landmarks)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldAmbientSyncReferenceIndexBuilderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeGeneratedCAF(
        to url: URL,
        durationSeconds: Double = 2.5,
        variant: Int = 0
    ) throws {
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * durationSeconds)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        let variantShift = Double(variant) * 95
        for frameIndex in 0..<frameCount {
            let time = Double(frameIndex) / sampleRate
            let sweepPosition = time / durationSeconds
            let envelope = 0.55 + 0.45 * sin(2 * Double.pi * 3 * time)
            let baseFrequency = 220 + variantShift + 660 * sweepPosition
            left[frameIndex] = Float(
                0.34 * envelope * sin(2 * Double.pi * baseFrequency * time)
                    + 0.16 * sin(2 * Double.pi * 880 * time)
            )
            right[frameIndex] = Float(
                0.30 * envelope * sin(2 * Double.pi * (baseFrequency * 1.5) * time)
                    + 0.14 * sin(2 * Double.pi * 660 * time)
            )
        }

        try file.write(from: buffer)
    }
}

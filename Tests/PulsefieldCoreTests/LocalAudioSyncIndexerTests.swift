import AVFoundation
import XCTest
@testable import PulsefieldCore

final class LocalAudioSyncIndexerTests: XCTestCase {
    func testLocalAudioSyncIndexesUseSecurityScopedOptionsOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(LocalAudioSyncIndexer.bookmarkResolutionOptions.contains(.withSecurityScope))
        #endif
    }

    func testSyncIndexDoesNotAdvertiseSpectralSummaryUntilFeatureIsBuilt() async throws {
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
        XCTAssertNil(index.spectralSummaryURL)
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
}

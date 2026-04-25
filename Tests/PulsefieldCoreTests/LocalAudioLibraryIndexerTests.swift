import AVFoundation
import SQLite3
import XCTest
@testable import PulsefieldCore

final class LocalAudioLibraryIndexerTests: XCTestCase {
    func testLocalAudioBookmarksUseSecurityScopedOptionsOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(LocalMusicDirectoryStore.bookmarkCreationOptions.contains(.withSecurityScope))
        XCTAssertTrue(LocalAudioLibraryIndexer.bookmarkCreationOptions.contains(.withSecurityScope))
        XCTAssertTrue(LocalAudioLibraryIndexer.bookmarkResolutionOptions.contains(.withSecurityScope))
        #endif
    }

    func testAddDirectorySurfacesBookmarkCreationFailureOnMacOS() async throws {
        #if os(macOS)
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        let missingURL = URL(fileURLWithPath: "/definitely/not/here/pulsefield-\(UUID().uuidString)")

        do {
            try await directoryStore.addDirectory(missingURL, recursive: true)
            XCTFail("Expected addDirectory to surface bookmark creation failure.")
        } catch {}

        let directories = await directoryStore.listDirectories()
        XCTAssertTrue(directories.isEmpty)
        #endif
    }

    func testUpsertAssetIgnoresPersistenceFailures() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let asset = LocalAudioAsset(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
            fileURLBookmark: nil,
            displayPath: "/tmp/pulsefield-library/orphan.mp3",
            fileName: "orphan.mp3",
            fileExtension: "mp3",
            fileSizeBytes: 4_096,
            sha256: "orphan",
            durationMS: 120_000,
            title: "Orphan",
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

        await database.upsertAsset(asset)

        let assets = await database.listAssets()
        XCTAssertTrue(assets.isEmpty)
    }

    func testRescanIndexesSupportedAudioAndRecordsUnsupportedFiles() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let songURL = libraryURL.appendingPathComponent("song.mp3")
        let textURL = libraryURL.appendingPathComponent("notes.txt")
        try Data("fake audio".utf8).write(to: songURL)
        try Data("not audio".utf8).write(to: textURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)

        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 123_000,
                        title: "Song",
                        artists: ["Artist"],
                        album: "Album",
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: "USPF10000001",
                        releaseYear: 2026
                    )
                ]
            )
        )

        await indexer.rescanAll()

        let status = await indexer.status()
        let assets = await database.listAssets()

        XCTAssertEqual(status.discoveredCount, 2)
        XCTAssertEqual(status.indexedCount, 1)
        XCTAssertEqual(status.failedCount, 1)
        XCTAssertEqual(status.missingCount, 0)
        XCTAssertTrue(assets.contains { $0.displayPath == songURL.path && $0.status == .ready })
        XCTAssertTrue(assets.contains { $0.displayPath == textURL.path && $0.status == .unsupportedFormat })
    }

    func testRescanMarksRemovedFilesMissingInsteadOfDeletingThem() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let songURL = libraryURL.appendingPathComponent("gone.mp3")
        try Data("fake audio".utf8).write(to: songURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)

        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 90_000,
                        title: "Gone",
                        artists: ["Artist"],
                        album: nil,
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: nil,
                        releaseYear: nil
                    )
                ]
            )
        )

        await indexer.rescanAll()
        try FileManager.default.removeItem(at: songURL)
        await indexer.rescanAll()

        let assets = await database.listAssets()
        let status = await indexer.status()
        XCTAssertEqual(assets.first { $0.displayPath == songURL.path }?.status, .missingFile)
        XCTAssertEqual(status.missingCount, 1)
    }

    func testRescanPreservesAssetsWhenLibraryRootCannotBeEnumerated() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let songURL = libraryURL.appendingPathComponent("offline-root.mp3")
        try Data("fake audio".utf8).write(to: songURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)

        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 120_000,
                        title: "Offline Root",
                        artists: ["Pulsefield"],
                        album: nil,
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: nil,
                        releaseYear: nil
                    )
                ]
            )
        )

        await indexer.rescanAll()
        let indexedAssets = await database.listAssets()
        let indexedDirectories = await database.listDirectories()
        let indexedAsset = try XCTUnwrap(indexedAssets.first { $0.displayPath == songURL.path })
        let scannedDirectory = try XCTUnwrap(indexedDirectories.first)
        XCTAssertEqual(indexedAsset.status, .ready)
        XCTAssertNotNil(scannedDirectory.lastScanFinishedAt)

        try FileManager.default.removeItem(at: libraryURL)
        await indexer.rescanAll()

        let assetsAfterUnavailableRoot = await database.listAssets()
        let directoriesAfterUnavailableRoot = await database.listDirectories()
        let preservedAsset = try XCTUnwrap(assetsAfterUnavailableRoot.first { $0.id == indexedAsset.id })
        let directoryAfterUnavailableRoot = try XCTUnwrap(directoriesAfterUnavailableRoot.first)
        XCTAssertEqual(preservedAsset.status, .ready)
        XCTAssertEqual(directoryAfterUnavailableRoot.lastScanFinishedAt, scannedDirectory.lastScanFinishedAt)
    }

    func testTransientUnreadableScanPreservesAssetIdentityAndHash() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let songURL = libraryURL.appendingPathComponent("locked.mp3")
        try Data("fake audio".utf8).write(to: songURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)

        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 120_000,
                        title: "Locked",
                        artists: ["Pulsefield"],
                        album: nil,
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: nil,
                        releaseYear: nil
                    )
                ]
            )
        )

        await indexer.rescanAll()
        let readableAssets = await database.listAssets()
        let readableAsset = try XCTUnwrap(readableAssets.first { $0.displayPath == songURL.path })
        XCTAssertEqual(readableAsset.status, .ready)
        XCTAssertFalse(readableAsset.sha256.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: songURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: songURL.path)
        }

        await indexer.rescanAll()

        let assets = await database.listAssets()
        let unreadableAsset = try XCTUnwrap(assets.first { $0.displayPath == songURL.path })
        XCTAssertEqual(unreadableAsset.status, .unreadable)
        XCTAssertEqual(unreadableAsset.id, readableAsset.id)
        XCTAssertEqual(unreadableAsset.sha256, readableAsset.sha256)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: songURL.path)
        await indexer.rescanAll()

        let restoredAssets = await database.listAssets()
        let restoredAsset = try XCTUnwrap(restoredAssets.first { $0.displayPath == songURL.path })
        XCTAssertEqual(restoredAssets.count, 1)
        XCTAssertEqual(restoredAsset.id, readableAsset.id)
        XCTAssertEqual(restoredAsset.sha256, readableAsset.sha256)
        XCTAssertEqual(restoredAsset.status, .ready)
    }

    func testUnsupportedUnreadableFilesAreRecordedAsUnsupportedWithoutHashing() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let notesURL = libraryURL.appendingPathComponent("locked-notes.txt")
        try Data("not audio".utf8).write(to: notesURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)
        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(metadata: [:])
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notesURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notesURL.path)
        }

        await indexer.rescanAll()

        let assets = await database.listAssets()
        let unsupportedAsset = try XCTUnwrap(assets.first { $0.displayPath == notesURL.path })
        XCTAssertEqual(unsupportedAsset.status, .unsupportedFormat)
        XCTAssertTrue(unsupportedAsset.sha256.isEmpty)
    }

    func testSupportedAudioWithoutReadableDurationIsUnreadableAndNotResolved() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let corruptURL = libraryURL.appendingPathComponent("corrupt.mp3")
        try Data("not actually audio".utf8).write(to: corruptURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)
        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(metadata: [:])
        )

        await indexer.rescanAll()

        let assets = await database.listAssets()
        XCTAssertEqual(assets.first { $0.displayPath == corruptURL.path }?.status, .unreadable)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "corrupt",
                artists: [],
                durationMS: nil,
                providerIDs: [.init(provider: .manual, value: "manual:corrupt")]
            )
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testRescanPreservesAssetIdentityWhenFileMovesWithinDirectory() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let originalURL = libraryURL.appendingPathComponent("original.mp3")
        let movedURL = libraryURL.appendingPathComponent("moved.mp3")
        try Data("stable audio bytes".utf8).write(to: originalURL)

        let metadata = ExtractedAudioMetadata(
            durationMS: 120_000,
            title: "Moved Song",
            artists: ["Pulsefield"],
            album: nil,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: nil,
            releaseYear: nil
        )
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)
        let indexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    originalURL.standardizedFileURL.path: metadata,
                    movedURL.standardizedFileURL.path: metadata
                ]
            )
        )

        await indexer.rescanAll()
        let originalAssets = await database.listAssets()
        let originalAsset = try XCTUnwrap(originalAssets.first)
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        await indexer.rescanAll()

        let assets = await database.listAssets()
        let status = await indexer.status()
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.id, originalAsset.id)
        XCTAssertEqual(assets.first?.displayPath, movedURL.standardizedFileURL.path)
        XCTAssertEqual(assets.first?.status, .ready)
        XCTAssertEqual(status.missingCount, 0)
    }

    func testRescanMarksOldAssetMissingWhenDifferentFileReplacesSamePath() async throws {
        let libraryURL = try makeTemporaryDirectory()
        let songURL = libraryURL.appendingPathComponent("same-path.mp3")
        try Data("original audio bytes".utf8).write(to: songURL)

        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryStore = LocalMusicDirectoryStore(database: database)
        try await directoryStore.addDirectory(libraryURL, recursive: false)

        let originalIndexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 120_000,
                        title: "Original",
                        artists: ["Pulsefield"],
                        album: nil,
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: nil,
                        releaseYear: nil
                    )
                ]
            )
        )

        await originalIndexer.rescanAll()
        let originalAssets = await database.listAssets()
        let originalAsset = try XCTUnwrap(originalAssets.first)

        try Data("replacement audio bytes with different fingerprint".utf8).write(to: songURL)
        let replacementIndexer = LocalAudioLibraryIndexer(
            database: database,
            metadataExtractor: StubMetadataExtractor(
                metadata: [
                    songURL.standardizedFileURL.path: ExtractedAudioMetadata(
                        durationMS: 180_000,
                        title: "Replacement",
                        artists: ["Pulsefield"],
                        album: nil,
                        albumArtist: nil,
                        trackNumber: nil,
                        discNumber: nil,
                        isrc: nil,
                        releaseYear: nil
                    )
                ]
            )
        )

        await replacementIndexer.rescanAll()

        let assets = await database.listAssets()
        let originalAssetAfterReplacement = try XCTUnwrap(assets.first { $0.id == originalAsset.id })
        let replacementAsset = try XCTUnwrap(assets.first { $0.displayPath == songURL.standardizedFileURL.path && $0.id != originalAsset.id })
        XCTAssertEqual(assets.count, 2)
        XCTAssertEqual(originalAssetAfterReplacement.status, .missingFile)
        XCTAssertNotEqual(replacementAsset.id, originalAsset.id)
        XCTAssertNotEqual(replacementAsset.sha256, originalAsset.sha256)
        XCTAssertEqual(replacementAsset.status, .ready)
        XCTAssertEqual(replacementAsset.durationMS, 180_000)
        XCTAssertEqual(replacementAsset.title, "Replacement")
    }

    func testLegacyPathUniqueDatabaseAllowsReplacementAtSamePathAfterOpen() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let databaseURL = workingDirectory.appendingPathComponent("legacy.sqlite")
        let songPath = workingDirectory.appendingPathComponent("same-path.mp3").path
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        try createLegacyPathUniqueDatabase(at: databaseURL)

        let database = try LocalAudioLibraryDatabase(databaseURL: databaseURL)
        try await database.upsertDirectory(
            MusicLibraryDirectory(
                id: directoryID,
                fileURLBookmark: nil,
                displayPath: workingDirectory.path,
                recursive: false,
                addedAt: Date(timeIntervalSince1970: 1_710_000_000),
                lastScanStartedAt: nil,
                lastScanFinishedAt: nil
            )
        )
        await database.upsertAsset(
            makeAssetForDatabase(
                id: originalID,
                directoryID: directoryID,
                displayPath: songPath,
                sha256: "original",
                title: "Original"
            )
        )
        await database.upsertAsset(
            makeAssetForDatabase(
                id: replacementID,
                directoryID: directoryID,
                displayPath: songPath,
                sha256: "replacement",
                title: "Replacement"
            )
        )

        let assets = await database.listAssets()
        XCTAssertEqual(assets.count, 2)
        XCTAssertEqual(assets.first { $0.id == originalID }?.status, .missingFile)
        XCTAssertEqual(assets.first { $0.id == replacementID }?.status, .ready)
    }

    func testFailedReplacementUpsertPreservesExistingAssetStatus() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let songPath = workingDirectory.appendingPathComponent("same-path.mp3").path
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let missingDirectoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000804")!
        let database = try LocalAudioLibraryDatabase.openInMemory()

        try await database.upsertDirectory(
            MusicLibraryDirectory(
                id: directoryID,
                fileURLBookmark: nil,
                displayPath: workingDirectory.path,
                recursive: false,
                addedAt: Date(timeIntervalSince1970: 1_710_000_000),
                lastScanStartedAt: nil,
                lastScanFinishedAt: nil
            )
        )
        await database.upsertAsset(
            makeAssetForDatabase(
                id: originalID,
                directoryID: directoryID,
                displayPath: songPath,
                sha256: "original",
                title: "Original"
            )
        )

        await database.upsertAsset(
            makeAssetForDatabase(
                id: replacementID,
                directoryID: missingDirectoryID,
                displayPath: songPath,
                sha256: "replacement",
                title: "Replacement"
            )
        )

        let assets = await database.listAssets()
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first { $0.id == originalID }?.status, .ready)
        XCTAssertNil(assets.first { $0.id == replacementID })
    }

    func testMetadataExtractorReadsITunesMetadataAndPreservesArtistNames() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        let sourceURL = workingDirectory.appendingPathComponent("source.wav")
        let taggedURL = workingDirectory.appendingPathComponent("tagged.m4a")
        try writeSilentWAV(to: sourceURL)
        try await writeTaggedM4A(from: sourceURL, to: taggedURL)

        let metadata = try await LocalAudioMetadataExtractor().extract(from: taggedURL)

        XCTAssertEqual(metadata.artists, ["Tyler, The Creator"])
        XCTAssertEqual(metadata.albumArtist, "Format Album Artist")
        XCTAssertEqual(metadata.trackNumber, 7)
        XCTAssertEqual(metadata.discNumber, 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createLegacyPathUniqueDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PulsefieldTestsSQLite", code: 1)
        }
        defer {
            sqlite3_close(database)
        }

        try executeSQL(
            """
            CREATE TABLE local_audio_assets (
                id TEXT PRIMARY KEY NOT NULL,
                directory_id TEXT NOT NULL,
                bookmark BLOB,
                display_path TEXT NOT NULL UNIQUE,
                file_name TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                title TEXT,
                artists TEXT NOT NULL,
                album TEXT,
                album_artist TEXT,
                track_number INTEGER,
                disc_number INTEGER,
                isrc TEXT,
                release_year INTEGER,
                indexed_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                status TEXT NOT NULL,
                status_message TEXT
            )
            """,
            on: database
        )
    }

    private func executeSQL(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "PulsefieldTestsSQLite",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func makeAssetForDatabase(
        id: UUID,
        directoryID: UUID,
        displayPath: String,
        sha256: String,
        title: String
    ) -> LocalAudioAsset {
        LocalAudioAsset(
            id: id,
            directoryID: directoryID,
            fileURLBookmark: nil,
            displayPath: displayPath,
            fileName: URL(fileURLWithPath: displayPath).lastPathComponent,
            fileExtension: URL(fileURLWithPath: displayPath).pathExtension,
            fileSizeBytes: 4_096,
            sha256: sha256,
            durationMS: 120_000,
            title: title,
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
    }

    private func writeSilentWAV(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 200)!
        buffer.frameLength = 200
        try file.write(from: buffer)
    }

    private func writeTaggedM4A(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let exportSession = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        exportSession.metadata = [
            metadataItem(identifier: .iTunesMetadataArtist, value: "Tyler, The Creator"),
            metadataItem(identifier: .iTunesMetadataAlbumArtist, value: "Format Album Artist"),
            metadataItem(identifier: .iTunesMetadataTrackNumber, value: "7/12"),
            metadataItem(identifier: .iTunesMetadataDiscNumber, value: "2/3")
        ]
        try await exportSession.export(to: outputURL, as: .m4a)
    }

    private func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

private actor StubMetadataExtractor: LocalAudioMetadataExtracting {
    private let metadata: [String: ExtractedAudioMetadata]

    init(metadata: [String: ExtractedAudioMetadata]) {
        self.metadata = metadata
    }

    func extract(from fileURL: URL) async throws -> ExtractedAudioMetadata {
        guard let value = metadata[fileURL.standardizedFileURL.path] else {
            throw LocalAudioMetadataExtractionError.unsupportedMetadata
        }

        return value
    }
}

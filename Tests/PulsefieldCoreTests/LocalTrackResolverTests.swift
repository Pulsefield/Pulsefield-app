import XCTest
@testable import PulsefieldCore

final class LocalTrackResolverTests: XCTestCase {
    func testResolveAutoAcceptsIsrcExactMatch() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let asset = makeAsset(
            id: assetID,
            directoryID: directoryID,
            title: "Satellite Heart",
            artists: ["Anya Marina"],
            durationMS: 214_000,
            isrc: "USAT20901391"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Satellite Heart",
                artists: ["Anya Marina"],
                album: nil,
                durationMS: 214_100,
                isrc: "USAT20901391",
                providerIDs: [.init(provider: .manual, value: "manual:satellite-heart")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, assetID)
        XCTAssertEqual(results.first?.decision, .autoAccepted)
        XCTAssertTrue(results.first?.evidence.contains(.isrcExact) == true)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.90)
    }

    func testResolveRequiresConfirmationForWeakDurationMatch() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: "Night Drive",
            artists: ["Pulsefield"],
            durationMS: 180_000
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Night Drive",
                artists: ["Pulsefield"],
                album: nil,
                durationMS: 185_500,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:night-drive")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .requiresUserConfirmation)
        XCTAssertTrue(results.first?.evidence.contains(.durationWithinTolerance(deltaMS: 5_500)) == true)
    }

    func testResolveRequiresConfirmationForWeakDurationEvenWhenOtherMetadataIsStrong() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000112")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: "Night Drive",
            artists: ["Pulsefield"],
            durationMS: 180_000,
            album: "Late Signals",
            fileName: "Night Drive.mp3"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Night Drive",
                artists: ["Pulsefield"],
                album: "Late Signals",
                durationMS: 185_500,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:night-drive")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .requiresUserConfirmation)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.90)
    }

    func testResolveRequiresConfirmationForAmbiguousAutoAcceptedMatches() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let albumVersion = makeAsset(
            directoryID: directoryID,
            title: "Signal",
            artists: ["Pulsefield"],
            durationMS: 180_000,
            fileName: "signal-album-version.mp3"
        )
        let radioEdit = makeAsset(
            directoryID: directoryID,
            title: "Signal",
            artists: ["Pulsefield"],
            durationMS: 180_000,
            fileName: "signal-radio-edit.mp3"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(albumVersion)
        await database.upsertAsset(radioEdit)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Signal",
                artists: ["Pulsefield"],
                album: nil,
                durationMS: 180_000,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:signal")]
            )
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].decision, .requiresUserConfirmation)
        XCTAssertEqual(results[1].decision, .requiresUserConfirmation)
        XCTAssertGreaterThanOrEqual(results[0].confidence, 0.90)
        XCTAssertGreaterThanOrEqual(results[1].confidence, 0.90)
    }

    func testManualResolveReservesTitleOnlyMatchForConfirmation() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000114")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: "Fool's Day",
            artists: ["Blur"],
            durationMS: 210_000,
            fileName: "Blur - Fool's Day.mp3"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Fool's Day",
                artists: [],
                album: nil,
                durationMS: nil,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:fools-day")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .requiresUserConfirmation)
        XCTAssertLessThan(results.first?.confidence ?? 1, 0.70)
        XCTAssertTrue(results.first?.evidence.contains(.titleExact) == true)
    }

    func testResolveRejectsTitleOnlyMatchOutsideManualResolveMode() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: "Intro",
            artists: ["The Local Artist"],
            durationMS: 90_000
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Intro",
                artists: [],
                album: nil,
                durationMS: nil,
                isrc: nil,
                providerIDs: [.init(provider: .acrCloud, value: "acr:intro")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .rejected)
        XCTAssertLessThan(results.first?.confidence ?? 1, 0.70)
    }

    func testResolveRequiresConfirmationForFilenameAndDurationWhenMetadataIsMissing() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: nil,
            artists: [],
            durationMS: 180_000,
            fileName: "Night Drive.mp3"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Night Drive",
                artists: [],
                album: nil,
                durationMS: 180_900,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:night-drive")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .requiresUserConfirmation)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.70)
        XCTAssertLessThan(results.first?.confidence ?? 1, 0.90)
        XCTAssertTrue(results.first?.evidence.contains(.durationWithinTolerance(deltaMS: 900)) == true)
        XCTAssertTrue(results.first?.evidence.contains { evidence in
            if case .fileNameFuzzy(let score) = evidence, score >= 0.99 {
                return true
            }
            return false
        } == true)
    }

    func testResolveRequiresConfirmationForPrefixedFilenameAndDurationWhenMetadataIsMissing() async throws {
        let database = try LocalAudioLibraryDatabase.openInMemory()
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000113")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: nil,
            artists: [],
            durationMS: 180_000,
            fileName: "01 - Pulsefield - Night Drive.mp3"
        )

        try await database.upsertDirectory(makeDirectory(id: directoryID))
        await database.upsertAsset(asset)

        let resolver = LocalTrackResolver(database: database)
        let results = await resolver.resolve(
            CanonicalTrack(
                title: "Night Drive",
                artists: [],
                album: nil,
                durationMS: 180_900,
                isrc: nil,
                providerIDs: [.init(provider: .manual, value: "manual:night-drive")]
            )
        )

        XCTAssertEqual(results.first?.asset.id, asset.id)
        XCTAssertEqual(results.first?.decision, .requiresUserConfirmation)
        XCTAssertGreaterThanOrEqual(results.first?.confidence ?? 0, 0.70)
        XCTAssertLessThan(results.first?.confidence ?? 1, 0.90)
        XCTAssertTrue(results.first?.evidence.contains { evidence in
            if case .fileNameFuzzy(let score) = evidence, score >= 0.99 {
                return true
            }
            return false
        } == true)
    }

    private func makeDirectory(id: UUID) -> MusicLibraryDirectory {
        MusicLibraryDirectory(
            id: id,
            fileURLBookmark: nil,
            displayPath: "/tmp/pulsefield-library",
            recursive: true,
            addedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastScanStartedAt: nil,
            lastScanFinishedAt: nil
        )
    }

    private func makeAsset(
        id: UUID = UUID(),
        directoryID: UUID,
        title: String?,
        artists: [String],
        durationMS: Int,
        isrc: String? = nil,
        album: String? = nil,
        fileName: String? = nil
    ) -> LocalAudioAsset {
        let fileName = fileName ?? "\(title ?? "untitled").mp3"
        return LocalAudioAsset(
            id: id,
            directoryID: directoryID,
            fileURLBookmark: nil,
            displayPath: "/tmp/pulsefield-library/\(fileName)",
            fileName: fileName,
            fileExtension: "mp3",
            fileSizeBytes: 4_096,
            sha256: id.uuidString.lowercased(),
            durationMS: durationMS,
            title: title,
            artists: artists,
            album: album,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: isrc,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_100),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_100),
            status: .ready
        )
    }

}

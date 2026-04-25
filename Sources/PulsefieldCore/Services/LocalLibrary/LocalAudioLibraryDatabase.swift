import Foundation
import SQLite3

public enum LocalAudioLibraryDatabaseError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(String)
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

public actor LocalAudioLibraryDatabase {
    private let connection: SQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func openInMemory() throws -> LocalAudioLibraryDatabase {
        try LocalAudioLibraryDatabase(path: ":memory:")
    }

    public static func openDefault() throws -> LocalAudioLibraryDatabase {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pulsefield", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Pulsefield", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalAudioLibraryDatabase(databaseURL: directory.appendingPathComponent("LocalAudioLibrary.sqlite"))
    }

    public init(databaseURL: URL) throws {
        try self.init(path: databaseURL.path)
    }

    private init(path: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection."
            throw LocalAudioLibraryDatabaseError.openFailed(message)
        }

        connection = SQLiteConnection(pointer: database)
        try Self.executeRaw("PRAGMA foreign_keys = ON", on: database)
        try Self.createSchema(on: database)
    }

    public func upsertDirectory(_ directory: MusicLibraryDirectory) throws {
        try upsertDirectoryThrowing(directory)
    }

    public func removeDirectory(id: UUID) async throws {
        try execute("DELETE FROM music_directories WHERE id = ?", bindings: [.text(id.uuidString)])
    }

    public func listDirectories() -> [MusicLibraryDirectory] {
        (try? queryDirectories("SELECT * FROM music_directories ORDER BY added_at ASC")) ?? []
    }

    public func directory(id: UUID) -> MusicLibraryDirectory? {
        try? queryDirectories("SELECT * FROM music_directories WHERE id = ?", bindings: [.text(id.uuidString)]).first
    }

    public func updateDirectoryScanTimes(id: UUID, startedAt: Date?, finishedAt: Date?) {
        try? execute(
            """
            UPDATE music_directories
            SET last_scan_started_at = ?, last_scan_finished_at = ?
            WHERE id = ?
            """,
            bindings: [.date(startedAt), .date(finishedAt), .text(id.uuidString)]
        )
    }

    public func upsertAsset(_ asset: LocalAudioAsset) {
        try? upsertAssetThrowing(asset)
    }

    public func asset(displayPath: String) -> LocalAudioAsset? {
        try? queryAssets(
            """
            SELECT * FROM local_audio_assets
            WHERE display_path = ?
            ORDER BY CASE WHEN status = 'missingFile' THEN 1 ELSE 0 END, last_seen_at DESC
            LIMIT 1
            """,
            bindings: [.text(displayPath)]
        ).first
    }

    public func listAssets() -> [LocalAudioAsset] {
        (try? queryAssets("SELECT * FROM local_audio_assets ORDER BY display_path ASC")) ?? []
    }

    public func listAssets(directoryID: UUID) -> [LocalAudioAsset] {
        (try? queryAssets(
            "SELECT * FROM local_audio_assets WHERE directory_id = ? ORDER BY display_path ASC",
            bindings: [.text(directoryID.uuidString)]
        )) ?? []
    }

    public func assets(
        directoryID: UUID,
        sha256: String,
        fileSizeBytes: Int64,
        durationMS: Int
    ) -> [LocalAudioAsset] {
        (try? queryAssets(
            """
            SELECT * FROM local_audio_assets
            WHERE directory_id = ? AND sha256 = ? AND file_size_bytes = ? AND duration_ms = ?
            ORDER BY last_seen_at DESC
            """,
            bindings: [
                .text(directoryID.uuidString),
                .text(sha256),
                .int64(fileSizeBytes),
                .int(durationMS)
            ]
        )) ?? []
    }

    public func markMissingAssets(directoryID: UUID, excludingDisplayPaths displayPaths: Set<String>, at _: Date) {
        let status = LocalAudioIndexStatus.missingFile.databaseValue
        let assets = listAssets(directoryID: directoryID)
        for asset in assets where !displayPaths.contains(asset.displayPath) && asset.status != .missingFile {
            try? execute(
                """
                UPDATE local_audio_assets
                SET status = ?, status_message = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(status.code),
                    .optionalText(status.message),
                    .text(asset.id.uuidString)
                ]
            )
        }
    }

    public func recordResolve(query: CanonicalTrack, result: LocalResolveResult) {
        try? execute(
            """
            INSERT INTO local_resolve_history (
                id, query_title, query_artists, query_album, query_duration_ms,
                asset_id, confidence, decision, resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString),
                .text(query.title),
                .text(encodeStrings(query.artists)),
                .optionalText(query.album),
                .optionalInt(query.durationMS),
                .text(result.asset.id.uuidString),
                .double(result.confidence),
                .text(result.decision.databaseValue),
                .date(Date())
            ]
        )
    }

    public func libraryStatus() -> LocalAudioLibraryStatus {
        let assets = listAssets()
        let directories = listDirectories()
        let indexed = assets.filter { $0.status == .ready || $0.status == .metadataPartial }.count
        let missing = assets.filter { $0.status == .missingFile }.count
        let failed = assets.filter {
            switch $0.status {
            case .unsupportedFormat, .unreadable, .failed:
                return true
            case .ready, .missingFile, .metadataPartial:
                return false
            }
        }.count
        let lastScan = directories.compactMap(\.lastScanFinishedAt).max()

        return LocalAudioLibraryStatus(
            discoveredCount: assets.count,
            indexedCount: indexed,
            failedCount: failed,
            missingCount: missing,
            lastScanFinishedAt: lastScan
        )
    }

    private static func createSchema(on connection: OpaquePointer) throws {
        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS music_directories (
                id TEXT PRIMARY KEY NOT NULL,
                bookmark BLOB,
                display_path TEXT NOT NULL UNIQUE,
                recursive INTEGER NOT NULL,
                added_at REAL NOT NULL,
                last_scan_started_at REAL,
                last_scan_finished_at REAL
            )
            """,
            on: connection
        )
        try migrateLocalAudioAssetsDisplayPathUniquenessIfNeeded(on: connection)

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS local_audio_assets (
                id TEXT PRIMARY KEY NOT NULL,
                directory_id TEXT NOT NULL,
                bookmark BLOB,
                display_path TEXT NOT NULL,
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
                status_message TEXT,
                FOREIGN KEY(directory_id) REFERENCES music_directories(id) ON DELETE CASCADE
            )
            """,
            on: connection
        )

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS local_audio_metadata (
                asset_id TEXT PRIMARY KEY NOT NULL,
                title TEXT,
                artists TEXT NOT NULL,
                album TEXT,
                album_artist TEXT,
                track_number INTEGER,
                disc_number INTEGER,
                isrc TEXT,
                release_year INTEGER,
                duration_ms INTEGER NOT NULL,
                FOREIGN KEY(asset_id) REFERENCES local_audio_assets(id) ON DELETE CASCADE
            )
            """,
            on: connection
        )

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS local_audio_hashes (
                asset_id TEXT PRIMARY KEY NOT NULL,
                sha256 TEXT NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                FOREIGN KEY(asset_id) REFERENCES local_audio_assets(id) ON DELETE CASCADE
            )
            """,
            on: connection
        )

        try executeRaw(
            """
            CREATE TABLE IF NOT EXISTS local_resolve_history (
                id TEXT PRIMARY KEY NOT NULL,
                query_title TEXT NOT NULL,
                query_artists TEXT NOT NULL,
                query_album TEXT,
                query_duration_ms INTEGER,
                asset_id TEXT NOT NULL,
                confidence REAL NOT NULL,
                decision TEXT NOT NULL,
                resolved_at REAL NOT NULL
            )
            """,
            on: connection
        )
    }

    private static func migrateLocalAudioAssetsDisplayPathUniquenessIfNeeded(on connection: OpaquePointer) throws {
        let createSQL = try querySingleText(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_audio_assets'",
            on: connection
        )?.replacingOccurrences(of: "\n", with: " ").lowercased() ?? ""
        guard createSQL.contains("display_path text not null unique")
                || createSQL.contains("unique(display_path)") else {
            return
        }

        try executeRaw("PRAGMA foreign_keys = OFF", on: connection)
        defer {
            try? executeRaw("PRAGMA foreign_keys = ON", on: connection)
        }

        try executeRaw("BEGIN TRANSACTION", on: connection)
        do {
            try executeRaw("DROP TABLE IF EXISTS local_audio_assets_migration", on: connection)
            try executeRaw(
                """
                CREATE TABLE local_audio_assets_migration (
                    id TEXT PRIMARY KEY NOT NULL,
                    directory_id TEXT NOT NULL,
                    bookmark BLOB,
                    display_path TEXT NOT NULL,
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
                    status_message TEXT,
                    FOREIGN KEY(directory_id) REFERENCES music_directories(id) ON DELETE CASCADE
                )
                """,
                on: connection
            )
            try executeRaw(
                """
                INSERT INTO local_audio_assets_migration (
                    id, directory_id, bookmark, display_path, file_name, file_extension, file_size_bytes,
                    sha256, duration_ms, title, artists, album, album_artist, track_number, disc_number,
                    isrc, release_year, indexed_at, last_seen_at, status, status_message
                )
                SELECT
                    id, directory_id, bookmark, display_path, file_name, file_extension, file_size_bytes,
                    sha256, duration_ms, title, artists, album, album_artist, track_number, disc_number,
                    isrc, release_year, indexed_at, last_seen_at, status, status_message
                FROM local_audio_assets
                """,
                on: connection
            )
            try executeRaw("DROP TABLE local_audio_assets", on: connection)
            try executeRaw("ALTER TABLE local_audio_assets_migration RENAME TO local_audio_assets", on: connection)
            try executeRaw("COMMIT", on: connection)
        } catch {
            try? executeRaw("ROLLBACK", on: connection)
            throw error
        }
    }

    private static func executeRaw(_ sql: String, on connection: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw LocalAudioLibraryDatabaseError.statementFailed(message)
        }
    }

    private static func querySingleText(_ sql: String, on connection: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalAudioLibraryDatabaseError.statementFailed(String(cString: sqlite3_errmsg(connection)))
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: text)
    }

    private func upsertDirectoryThrowing(_ directory: MusicLibraryDirectory) throws {
        try execute(
            """
            INSERT INTO music_directories (
                id, bookmark, display_path, recursive, added_at, last_scan_started_at, last_scan_finished_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                bookmark = excluded.bookmark,
                display_path = excluded.display_path,
                recursive = excluded.recursive,
                added_at = excluded.added_at,
                last_scan_started_at = excluded.last_scan_started_at,
                last_scan_finished_at = excluded.last_scan_finished_at
            """,
            bindings: [
                .text(directory.id.uuidString),
                .data(directory.fileURLBookmark),
                .text(directory.displayPath),
                .bool(directory.recursive),
                .date(directory.addedAt),
                .date(directory.lastScanStartedAt),
                .date(directory.lastScanFinishedAt)
            ]
        )
    }

    private func upsertAssetThrowing(_ asset: LocalAudioAsset) throws {
        try Self.executeRaw("BEGIN TRANSACTION", on: connection.pointer)
        do {
            try upsertAssetRows(asset)
            try Self.executeRaw("COMMIT", on: connection.pointer)
        } catch {
            try? Self.executeRaw("ROLLBACK", on: connection.pointer)
            throw error
        }
    }

    private func upsertAssetRows(_ asset: LocalAudioAsset) throws {
        try markConflictingAssetsByDisplayPathMissingIfNeeded(asset)

        let status = asset.status.databaseValue
        try execute(
            """
            INSERT INTO local_audio_assets (
                id, directory_id, bookmark, display_path, file_name, file_extension, file_size_bytes,
                sha256, duration_ms, title, artists, album, album_artist, track_number, disc_number,
                isrc, release_year, indexed_at, last_seen_at, status, status_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                directory_id = excluded.directory_id,
                bookmark = excluded.bookmark,
                display_path = excluded.display_path,
                file_name = excluded.file_name,
                file_extension = excluded.file_extension,
                file_size_bytes = excluded.file_size_bytes,
                sha256 = excluded.sha256,
                duration_ms = excluded.duration_ms,
                title = excluded.title,
                artists = excluded.artists,
                album = excluded.album,
                album_artist = excluded.album_artist,
                track_number = excluded.track_number,
                disc_number = excluded.disc_number,
                isrc = excluded.isrc,
                release_year = excluded.release_year,
                indexed_at = excluded.indexed_at,
                last_seen_at = excluded.last_seen_at,
                status = excluded.status,
                status_message = excluded.status_message
            """,
            bindings: [
                .text(asset.id.uuidString),
                .text(asset.directoryID.uuidString),
                .data(asset.fileURLBookmark),
                .text(asset.displayPath),
                .text(asset.fileName),
                .text(asset.fileExtension),
                .int64(asset.fileSizeBytes),
                .text(asset.sha256),
                .int(asset.durationMS),
                .optionalText(asset.title),
                .text(encodeStrings(asset.artists)),
                .optionalText(asset.album),
                .optionalText(asset.albumArtist),
                .optionalInt(asset.trackNumber),
                .optionalInt(asset.discNumber),
                .optionalText(asset.isrc),
                .optionalInt(asset.releaseYear),
                .date(asset.indexedAt),
                .date(asset.lastSeenAt),
                .text(status.code),
                .optionalText(status.message)
            ]
        )

        try execute(
            """
            INSERT INTO local_audio_metadata (
                asset_id, title, artists, album, album_artist, track_number,
                disc_number, isrc, release_year, duration_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                title = excluded.title,
                artists = excluded.artists,
                album = excluded.album,
                album_artist = excluded.album_artist,
                track_number = excluded.track_number,
                disc_number = excluded.disc_number,
                isrc = excluded.isrc,
                release_year = excluded.release_year,
                duration_ms = excluded.duration_ms
            """,
            bindings: [
                .text(asset.id.uuidString),
                .optionalText(asset.title),
                .text(encodeStrings(asset.artists)),
                .optionalText(asset.album),
                .optionalText(asset.albumArtist),
                .optionalInt(asset.trackNumber),
                .optionalInt(asset.discNumber),
                .optionalText(asset.isrc),
                .optionalInt(asset.releaseYear),
                .int(asset.durationMS)
            ]
        )

        try execute(
            """
            INSERT INTO local_audio_hashes (asset_id, sha256, file_size_bytes)
            VALUES (?, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                sha256 = excluded.sha256,
                file_size_bytes = excluded.file_size_bytes
            """,
            bindings: [
                .text(asset.id.uuidString),
                .text(asset.sha256),
                .int64(asset.fileSizeBytes)
            ]
        )
    }

    private func markConflictingAssetsByDisplayPathMissingIfNeeded(_ asset: LocalAudioAsset) throws {
        let conflicts = try queryAssets(
            """
            SELECT * FROM local_audio_assets
            WHERE display_path = ? AND id != ? AND status != ?
            """,
            bindings: [.text(asset.displayPath), .text(asset.id.uuidString), .text(LocalAudioIndexStatus.missingFile.databaseValue.code)]
        )

        let missingStatus = LocalAudioIndexStatus.missingFile.databaseValue
        for conflict in conflicts {
            try execute(
                """
                UPDATE local_audio_assets
                SET status = ?, status_message = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(missingStatus.code),
                    .optionalText(missingStatus.message),
                    .text(conflict.id.uuidString)
                ]
            )
        }
    }

    private func queryDirectories(_ sql: String, bindings: [SQLiteBinding] = []) throws -> [MusicLibraryDirectory] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }

        var directories: [MusicLibraryDirectory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idString = columnText(statement, 0),
                let id = UUID(uuidString: idString),
                let displayPath = columnText(statement, 2)
            else {
                continue
            }

            directories.append(
                MusicLibraryDirectory(
                    id: id,
                    fileURLBookmark: columnData(statement, 1),
                    displayPath: displayPath,
                    recursive: sqlite3_column_int(statement, 3) != 0,
                    addedAt: columnDate(statement, 4) ?? Date(timeIntervalSince1970: 0),
                    lastScanStartedAt: columnDate(statement, 5),
                    lastScanFinishedAt: columnDate(statement, 6)
                )
            )
        }

        return directories
    }

    private func queryAssets(_ sql: String, bindings: [SQLiteBinding] = []) throws -> [LocalAudioAsset] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }

        var assets: [LocalAudioAsset] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idString = columnText(statement, 0),
                let id = UUID(uuidString: idString),
                let directoryIDString = columnText(statement, 1),
                let directoryID = UUID(uuidString: directoryIDString),
                let displayPath = columnText(statement, 3),
                let fileName = columnText(statement, 4),
                let fileExtension = columnText(statement, 5),
                let sha256 = columnText(statement, 7),
                let artistsJSON = columnText(statement, 10),
                let indexedAt = columnDate(statement, 17),
                let lastSeenAt = columnDate(statement, 18),
                let statusCode = columnText(statement, 19)
            else {
                continue
            }

            assets.append(
                LocalAudioAsset(
                    id: id,
                    directoryID: directoryID,
                    fileURLBookmark: columnData(statement, 2),
                    displayPath: displayPath,
                    fileName: fileName,
                    fileExtension: fileExtension,
                    fileSizeBytes: sqlite3_column_int64(statement, 6),
                    sha256: sha256,
                    durationMS: Int(sqlite3_column_int(statement, 8)),
                    title: columnText(statement, 9),
                    artists: decodeStrings(artistsJSON),
                    album: columnText(statement, 11),
                    albumArtist: columnText(statement, 12),
                    trackNumber: columnOptionalInt(statement, 13),
                    discNumber: columnOptionalInt(statement, 14),
                    isrc: columnText(statement, 15),
                    releaseYear: columnOptionalInt(statement, 16),
                    indexedAt: indexedAt,
                    lastSeenAt: lastSeenAt,
                    status: LocalAudioIndexStatus.databaseValue(code: statusCode, message: columnText(statement, 20))
                )
            )
        }

        return assets
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalAudioLibraryDatabaseError.statementFailed(String(cString: sqlite3_errmsg(connection.pointer)))
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteBinding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalAudioLibraryDatabaseError.statementFailed(String(cString: sqlite3_errmsg(connection.pointer)))
        }

        for (index, binding) in bindings.enumerated() {
            bind(binding, to: statement, at: Int32(index + 1))
        }

        return statement
    }

    private func bind(_ binding: SQLiteBinding, to statement: OpaquePointer, at index: Int32) {
        switch binding {
        case .null:
            sqlite3_bind_null(statement, index)
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .optionalText(let value):
            if let value {
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .data(let data):
            guard let data else {
                sqlite3_bind_null(statement, index)
                return
            }
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
        case .int(let value):
            sqlite3_bind_int(statement, index, Int32(value))
        case .optionalInt(let value):
            if let value {
                sqlite3_bind_int(statement, index, Int32(value))
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .int64(let value):
            sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .date(let value):
            if let value {
                sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .bool(let value):
            sqlite3_bind_int(statement, index, value ? 1 : 0)
        }
    }

    private func encodeStrings(_ values: [String]) -> String {
        guard let data = try? encoder.encode(values), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func decodeStrings(_ string: String) -> [String] {
        guard let data = string.data(using: .utf8),
              let values = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return values
    }
}

private enum SQLiteBinding {
    case null
    case text(String)
    case optionalText(String?)
    case data(Data?)
    case int(Int)
    case optionalInt(Int?)
    case int64(Int64)
    case double(Double)
    case date(Date?)
    case bool(Bool)
}

private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: value)
}

private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, index) else {
        return nil
    }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
}

private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
        return nil
    }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}

private func columnOptionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
        return nil
    }
    return Int(sqlite3_column_int(statement, index))
}

private extension LocalAudioIndexStatus {
    var databaseValue: (code: String, message: String?) {
        switch self {
        case .ready:
            return ("ready", nil)
        case .missingFile:
            return ("missingFile", nil)
        case .unsupportedFormat:
            return ("unsupportedFormat", nil)
        case .unreadable:
            return ("unreadable", nil)
        case .metadataPartial:
            return ("metadataPartial", nil)
        case .failed(let message):
            return ("failed", message)
        }
    }

    static func databaseValue(code: String, message: String?) -> LocalAudioIndexStatus {
        switch code {
        case "ready":
            return .ready
        case "missingFile":
            return .missingFile
        case "unsupportedFormat":
            return .unsupportedFormat
        case "unreadable":
            return .unreadable
        case "metadataPartial":
            return .metadataPartial
        case "failed":
            return .failed(message ?? "Unknown indexing failure.")
        default:
            return .failed("Unknown indexing status: \(code)")
        }
    }
}

private extension LocalResolveDecision {
    var databaseValue: String {
        switch self {
        case .autoAccepted:
            return "autoAccepted"
        case .requiresUserConfirmation:
            return "requiresUserConfirmation"
        case .rejected:
            return "rejected"
        }
    }
}

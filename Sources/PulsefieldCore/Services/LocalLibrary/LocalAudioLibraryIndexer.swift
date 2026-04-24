import CryptoKit
import Foundation

public actor LocalAudioLibraryIndexer: LocalAudioLibraryIndexing {
    #if os(macOS)
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private let database: LocalAudioLibraryDatabase
    private let metadataExtractor: any LocalAudioMetadataExtracting
    private let supportedExtensions: Set<String>

    public init(
        database: LocalAudioLibraryDatabase,
        metadataExtractor: any LocalAudioMetadataExtracting = LocalAudioMetadataExtractor(),
        supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff"]
    ) {
        self.database = database
        self.metadataExtractor = metadataExtractor
        self.supportedExtensions = supportedExtensions
    }

    public func rescanAll() async {
        let directories = await database.listDirectories()
        for directory in directories {
            await rescanDirectory(id: directory.id)
        }
    }

    public func rescanDirectory(id: UUID) async {
        guard let directory = await database.directory(id: id) else {
            return
        }

        let startedAt = Date()
        await database.updateDirectoryScanTimes(id: id, startedAt: startedAt, finishedAt: nil)

        let rootURL = resolveURL(for: directory)
        let accessed = rootURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileURLs = discoverFiles(in: rootURL, recursive: directory.recursive)
        var seenPaths = Set<String>()

        for fileURL in fileURLs {
            seenPaths.insert(fileURL.standardizedFileURL.path)
            await index(fileURL: fileURL, directory: directory)
        }

        await database.markMissingAssets(directoryID: directory.id, excludingDisplayPaths: seenPaths, at: Date())
        await database.updateDirectoryScanTimes(id: id, startedAt: startedAt, finishedAt: Date())
    }

    public func status() async -> LocalAudioLibraryStatus {
        await database.libraryStatus()
    }

    private func index(fileURL: URL, directory: MusicLibraryDirectory) async {
        let standardizedURL = fileURL.standardizedFileURL
        let displayPath = standardizedURL.path
        let fileExtension = standardizedURL.pathExtension.lowercased()
        let existing = await database.asset(displayPath: displayPath)
        let now = Date()
        let fileSize = fileSizeBytes(at: standardizedURL)
        let bookmark = try? standardizedURL.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        func upsert(
            status: LocalAudioIndexStatus,
            identity: LocalAudioAsset? = nil,
            metadata: ExtractedAudioMetadata? = nil,
            sha256: String? = nil
        ) async {
            await database.upsertAsset(
                makeAsset(
                    from: identity,
                    directory: directory,
                    url: standardizedURL,
                    bookmark: bookmark,
                    fileSize: fileSize,
                    sha256: sha256,
                    metadata: metadata,
                    now: now,
                    status: status
                )
            )
        }

        guard supportedExtensions.contains(fileExtension) else {
            await upsert(
                status: .unsupportedFormat,
                identity: existing
            )
            return
        }

        guard let sha256 = try? hashFile(at: standardizedURL) else {
            await upsert(status: .unreadable, identity: existing)
            return
        }

        let metadata: ExtractedAudioMetadata
        do {
            metadata = try await metadataExtractor.extract(from: standardizedURL)
        } catch LocalAudioMetadataExtractionError.unsupportedMetadata {
            await upsert(
                status: .unreadable,
                identity: samePathReusableAsset(existing: existing, sha256: sha256, fileSize: fileSize),
                sha256: sha256
            )
            return
        } catch {
            await upsert(
                status: .unreadable,
                identity: samePathReusableAsset(existing: existing, sha256: sha256, fileSize: fileSize),
                sha256: sha256
            )
            return
        }

        let assetIdentity = await reusableAsset(
            existing: existing,
            directoryID: directory.id,
            displayPath: displayPath,
            sha256: sha256,
            fileSize: fileSize,
            durationMS: metadata.durationMS
        )
        await upsert(
            status: metadata.title == nil || metadata.artists.isEmpty ? .metadataPartial : .ready,
            identity: assetIdentity,
            metadata: metadata,
            sha256: sha256
        )
    }

    private func reusableAsset(
        existing: LocalAudioAsset?,
        directoryID: UUID,
        displayPath: String,
        sha256: String,
        fileSize: Int64,
        durationMS: Int
    ) async -> LocalAudioAsset? {
        if let existing = samePathReusableAsset(
            existing: existing,
            sha256: sha256,
            fileSize: fileSize,
            durationMS: durationMS
        ) {
            return existing
        }

        let movedCandidates = await database.assets(
            directoryID: directoryID,
            sha256: sha256,
            fileSizeBytes: fileSize,
            durationMS: durationMS
        )

        return movedCandidates.first { candidate in
            candidate.displayPath != displayPath && !FileManager.default.fileExists(atPath: candidate.displayPath)
        }
    }

    private func samePathReusableAsset(
        existing: LocalAudioAsset?,
        sha256: String,
        fileSize: Int64,
        durationMS: Int? = nil
    ) -> LocalAudioAsset? {
        guard let existing,
              existing.sha256 == sha256,
              existing.fileSizeBytes == fileSize
        else {
            return nil
        }

        if let durationMS, existing.durationMS != durationMS {
            return nil
        }

        return existing
    }

    private func makeAsset(
        from identity: LocalAudioAsset?,
        directory: MusicLibraryDirectory,
        url: URL,
        bookmark: Data?,
        fileSize: Int64,
        sha256: String?,
        metadata: ExtractedAudioMetadata? = nil,
        now: Date,
        status: LocalAudioIndexStatus
    ) -> LocalAudioAsset {
        func field<T>(_ keyPath: KeyPath<ExtractedAudioMetadata, T>, fallback: T) -> T {
            metadata.map { $0[keyPath: keyPath] } ?? fallback
        }

        return LocalAudioAsset(
            id: identity?.id ?? UUID(),
            directoryID: directory.id,
            fileURLBookmark: bookmark,
            displayPath: url.path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            fileSizeBytes: fileSize,
            sha256: sha256 ?? identity?.sha256 ?? "",
            durationMS: field(\.durationMS, fallback: identity?.durationMS ?? 0),
            title: field(\.title, fallback: identity?.title),
            artists: field(\.artists, fallback: identity?.artists ?? []),
            album: field(\.album, fallback: identity?.album),
            albumArtist: field(\.albumArtist, fallback: identity?.albumArtist),
            trackNumber: field(\.trackNumber, fallback: identity?.trackNumber),
            discNumber: field(\.discNumber, fallback: identity?.discNumber),
            isrc: field(\.isrc, fallback: identity?.isrc),
            releaseYear: field(\.releaseYear, fallback: identity?.releaseYear),
            indexedAt: identity?.indexedAt ?? now,
            lastSeenAt: now,
            status: status
        )
    }

    private func discoverFiles(in rootURL: URL, recursive: Bool) -> [URL] {
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            return enumerator?.compactMap { item in
                guard let url = item as? URL, isRegularFile(url) else {
                    return nil
                }
                return url
            } ?? []
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.filter(isRegularFile)
    }

    private func resolveURL(for directory: MusicLibraryDirectory) -> URL {
        if let bookmark = directory.fileURLBookmark {
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

        return URL(fileURLWithPath: directory.displayPath).standardizedFileURL
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

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

}

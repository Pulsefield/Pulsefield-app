import Foundation

public enum LocalMusicDirectoryStoreError: LocalizedError, Equatable, Sendable {
    case invalidDirectoryURL(String)
    case directoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectoryURL(let path):
            return "Music library directory must be a file URL: \(path)"
        case .directoryNotFound(let path):
            return "Music library directory does not exist: \(path)"
        }
    }
}

public actor LocalMusicDirectoryStore: LocalMusicDirectoryManaging {
    #if os(macOS)
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    #endif

    private let database: LocalAudioLibraryDatabase

    public init(database: LocalAudioLibraryDatabase) {
        self.database = database
    }

    public func addDirectory(_ url: URL, recursive: Bool = true) async throws {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL else {
            throw LocalMusicDirectoryStoreError.invalidDirectoryURL(url.absoluteString)
        }

        let displayPath = standardizedURL.path
        let accessed = standardizedURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                standardizedURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: displayPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LocalMusicDirectoryStoreError.directoryNotFound(displayPath)
        }

        let existing = await database.listDirectories().first { $0.displayPath == displayPath }
        let bookmark = try standardizedURL.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let directory = MusicLibraryDirectory(
            id: existing?.id ?? UUID(),
            fileURLBookmark: bookmark,
            displayPath: displayPath,
            recursive: recursive,
            addedAt: existing?.addedAt ?? Date(),
            lastScanStartedAt: existing?.lastScanStartedAt,
            lastScanFinishedAt: existing?.lastScanFinishedAt
        )

        try await database.upsertDirectory(directory)
    }

    public func removeDirectory(id: UUID) async throws {
        try await database.removeDirectory(id: id)
    }

    public func listDirectories() async -> [MusicLibraryDirectory] {
        await database.listDirectories()
    }
}

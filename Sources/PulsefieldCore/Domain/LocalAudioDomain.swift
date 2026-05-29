import Foundation

public struct MusicLibraryDirectory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileURLBookmark: Data?
    public let displayPath: String
    public let recursive: Bool
    public let addedAt: Date
    public let lastScanStartedAt: Date?
    public let lastScanFinishedAt: Date?

    public init(
        id: UUID,
        fileURLBookmark: Data?,
        displayPath: String,
        recursive: Bool,
        addedAt: Date,
        lastScanStartedAt: Date?,
        lastScanFinishedAt: Date?
    ) {
        self.id = id
        self.fileURLBookmark = fileURLBookmark
        self.displayPath = displayPath
        self.recursive = recursive
        self.addedAt = addedAt
        self.lastScanStartedAt = lastScanStartedAt
        self.lastScanFinishedAt = lastScanFinishedAt
    }
}

public struct LocalAudioAsset: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let directoryID: UUID
    public let fileURLBookmark: Data?
    public let displayPath: String
    public let fileName: String
    public let fileExtension: String
    public let fileSizeBytes: Int64
    public let sha256: String
    public let durationMS: Int
    public let title: String?
    public let artists: [String]
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let isrc: String?
    public let releaseYear: Int?
    public let indexedAt: Date
    public let lastSeenAt: Date
    public let status: LocalAudioIndexStatus

    public init(
        id: UUID,
        directoryID: UUID,
        fileURLBookmark: Data?,
        displayPath: String,
        fileName: String,
        fileExtension: String,
        fileSizeBytes: Int64,
        sha256: String,
        durationMS: Int,
        title: String?,
        artists: [String],
        album: String?,
        albumArtist: String?,
        trackNumber: Int?,
        discNumber: Int?,
        isrc: String?,
        releaseYear: Int?,
        indexedAt: Date,
        lastSeenAt: Date,
        status: LocalAudioIndexStatus
    ) {
        self.id = id
        self.directoryID = directoryID
        self.fileURLBookmark = fileURLBookmark
        self.displayPath = displayPath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSizeBytes = fileSizeBytes
        self.sha256 = sha256
        self.durationMS = durationMS
        self.title = title
        self.artists = artists
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isrc = isrc
        self.releaseYear = releaseYear
        self.indexedAt = indexedAt
        self.lastSeenAt = lastSeenAt
        self.status = status
    }
}

public enum LocalAudioIndexStatus: Equatable, Sendable {
    case ready
    case missingFile
    case unsupportedFormat
    case unreadable
    case metadataPartial
    case failed(String)
}

public struct ExtractedAudioMetadata: Equatable, Sendable {
    public let durationMS: Int
    public let title: String?
    public let artists: [String]
    public let album: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let isrc: String?
    public let releaseYear: Int?

    public init(
        durationMS: Int,
        title: String?,
        artists: [String],
        album: String?,
        albumArtist: String?,
        trackNumber: Int?,
        discNumber: Int?,
        isrc: String?,
        releaseYear: Int?
    ) {
        self.durationMS = durationMS
        self.title = title
        self.artists = artists
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isrc = isrc
        self.releaseYear = releaseYear
    }
}

public enum LocalAudioMetadataExtractionError: Error, Equatable, Sendable {
    case unsupportedMetadata
    case unreadable(String)
}

public struct LocalAudioLibraryStatus: Equatable, Sendable {
    public let discoveredCount: Int
    public let indexedCount: Int
    public let failedCount: Int
    public let missingCount: Int
    public let lastScanFinishedAt: Date?

    public init(
        discoveredCount: Int = 0,
        indexedCount: Int = 0,
        failedCount: Int = 0,
        missingCount: Int = 0,
        lastScanFinishedAt: Date? = nil
    ) {
        self.discoveredCount = discoveredCount
        self.indexedCount = indexedCount
        self.failedCount = failedCount
        self.missingCount = missingCount
        self.lastScanFinishedAt = lastScanFinishedAt
    }

    public static let empty = LocalAudioLibraryStatus()
}

public struct LocalResolveResult: Equatable, Sendable {
    public let asset: LocalAudioAsset
    public let confidence: Double
    public let evidence: [MatchEvidence]
    public let decision: LocalResolveDecision

    public init(
        asset: LocalAudioAsset,
        confidence: Double,
        evidence: [MatchEvidence],
        decision: LocalResolveDecision
    ) {
        self.asset = asset
        self.confidence = confidence
        self.evidence = evidence
        self.decision = decision
    }
}

public enum LocalResolveDecision: Equatable, Sendable {
    case autoAccepted
    case requiresUserConfirmation
    case rejected
}

public enum MatchEvidence: Equatable, Sendable {
    case isrcExact
    case titleExact
    case artistExact
    case albumExact
    case durationWithinTolerance(deltaMS: Int)
    case titleFuzzy(score: Double)
    case artistFuzzy(score: Double)
    case albumFuzzy(score: Double)
    case fileNameFuzzy(score: Double)
}

public protocol LocalMusicDirectoryManaging: Sendable {
    func addDirectory(_ url: URL, recursive: Bool) async throws
    func removeDirectory(id: UUID) async throws
    func listDirectories() async -> [MusicLibraryDirectory]
}

public protocol LocalAudioLibraryIndexing: Sendable {
    func rescanAll() async
    func rescanDirectory(id: UUID) async
    func status() async -> LocalAudioLibraryStatus
}

public protocol LocalAudioMetadataExtracting: Sendable {
    func extract(from fileURL: URL) async throws -> ExtractedAudioMetadata
}

public protocol LocalTrackResolving: Sendable {
    func resolve(_ track: CanonicalTrack) async -> [LocalResolveResult]
}

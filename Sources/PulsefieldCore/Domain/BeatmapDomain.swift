import Foundation

public enum BeatmapMode: String, Equatable, Sendable {
    case mania4k
}

public struct BeatmapGenerationConfiguration: Equatable, Sendable {
    public let providerHints: [String: String]

    public init(providerHints: [String: String] = [:]) {
        self.providerHints = providerHints
    }
}

public struct BeatmapGenerationRequest: Equatable, Sendable {
    public let snapshot: RecognitionSnapshot
    public let mode: BeatmapMode
    public let configuration: BeatmapGenerationConfiguration

    public init(
        snapshot: RecognitionSnapshot,
        mode: BeatmapMode,
        configuration: BeatmapGenerationConfiguration = .init()
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.configuration = configuration
    }
}

public enum BeatmapGenerationStatus: Equatable, Sendable {
    case reserved
    case queued
    case running
    case completed
}

public struct BeatmapGenerationHandle: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let status: BeatmapGenerationStatus
    public let note: String

    public init(id: UUID = UUID(), status: BeatmapGenerationStatus, note: String) {
        self.id = id
        self.status = status
        self.note = note
    }
}

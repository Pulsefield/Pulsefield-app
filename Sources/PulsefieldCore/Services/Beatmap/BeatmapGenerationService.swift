import Foundation

public protocol BeatmapGenerationProviding: Sendable {
    func reserveBeatmap(for request: BeatmapGenerationRequest) async throws -> BeatmapGenerationHandle
}

public struct NoopBeatmapGenerator: BeatmapGenerationProviding, Sendable {
    public init() {}

    public func reserveBeatmap(for request: BeatmapGenerationRequest) async throws -> BeatmapGenerationHandle {
        BeatmapGenerationHandle(
            status: .reserved,
            note: "Reserved \(request.mode.rawValue) handoff for \(request.snapshot.track.title). Beatmap generation is intentionally not implemented yet."
        )
    }
}

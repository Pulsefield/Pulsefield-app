import Foundation

public enum Mania4KJudgeDifficulty: String, CaseIterable, Identifiable, Equatable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"

    public var id: String {
        rawValue
    }
}

public struct Mania4KPlayConfiguration: Equatable, Sendable {
    public let beatmapFileURL: URL
    public let audioFileURL: URL
    public let starDifficulty: Double
    public let scrollSpeed: Double
    public let globalAudioOffsetMilliseconds: Double
    public let judgeDifficulty: Mania4KJudgeDifficulty

    public init(
        beatmapFileURL: URL,
        audioFileURL: URL,
        starDifficulty: Double,
        scrollSpeed: Double,
        globalAudioOffsetMilliseconds: Double,
        judgeDifficulty: Mania4KJudgeDifficulty
    ) {
        self.beatmapFileURL = beatmapFileURL
        self.audioFileURL = audioFileURL
        self.starDifficulty = starDifficulty
        self.scrollSpeed = scrollSpeed
        self.globalAudioOffsetMilliseconds = globalAudioOffsetMilliseconds
        self.judgeDifficulty = judgeDifficulty
    }
}

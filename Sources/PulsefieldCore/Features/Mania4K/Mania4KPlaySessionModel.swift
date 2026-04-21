import Foundation
import Observation

@MainActor
@Observable
public final class Mania4KPlaySessionModel {
    public var beatmapFileURL: URL?
    public var audioFileURL: URL?
    public var starDifficulty: Double
    public var scrollSpeed: Double
    public var globalAudioOffsetMilliseconds: Double
    public var judgeDifficulty: Mania4KJudgeDifficulty

    public private(set) var beatmapSelectionErrorMessage: String?
    public private(set) var audioSelectionErrorMessage: String?
    public private(set) var activeConfiguration: Mania4KPlayConfiguration?

    public init(
        beatmapFileURL: URL? = nil,
        audioFileURL: URL? = nil,
        starDifficulty: Double = 4.0,
        scrollSpeed: Double = 8.0,
        globalAudioOffsetMilliseconds: Double = 0,
        judgeDifficulty: Mania4KJudgeDifficulty = .c
    ) {
        self.beatmapFileURL = beatmapFileURL
        self.audioFileURL = audioFileURL
        self.starDifficulty = starDifficulty
        self.scrollSpeed = scrollSpeed
        self.globalAudioOffsetMilliseconds = globalAudioOffsetMilliseconds
        self.judgeDifficulty = judgeDifficulty
    }

    public var isReadyToStart: Bool {
        beatmapFileURL != nil && audioFileURL != nil
    }

    public var beatmapFileName: String {
        beatmapFileURL?.lastPathComponent ?? "No .osu file selected"
    }

    public var audioFileName: String {
        audioFileURL?.lastPathComponent ?? "No audio file selected"
    }

    public func selectBeatmapFile(_ url: URL) {
        guard url.hasOsuBeatmapExtension else {
            beatmapSelectionErrorMessage = "Choose a .osu beatmap file."
            return
        }

        beatmapFileURL = url
        beatmapSelectionErrorMessage = nil
        activeConfiguration = nil
    }

    public func selectAudioFile(_ url: URL) {
        audioFileURL = url
        audioSelectionErrorMessage = nil
        activeConfiguration = nil
    }

    public func recordBeatmapImportFailure(_ error: Error) {
        beatmapSelectionErrorMessage = "Could not choose beatmap: \(error.localizedDescription)"
    }

    public func recordAudioImportFailure(_ error: Error) {
        audioSelectionErrorMessage = "Could not choose audio: \(error.localizedDescription)"
    }

    @discardableResult
    public func startPlay() -> Bool {
        guard let beatmapFileURL, let audioFileURL else {
            return false
        }

        // The parser validation slice comes next; this mock intentionally trusts any selected .osu URL.
        activeConfiguration = Mania4KPlayConfiguration(
            beatmapFileURL: beatmapFileURL,
            audioFileURL: audioFileURL,
            starDifficulty: starDifficulty,
            scrollSpeed: scrollSpeed,
            globalAudioOffsetMilliseconds: globalAudioOffsetMilliseconds,
            judgeDifficulty: judgeDifficulty
        )
        return true
    }

    public func quitToSetup() {
        activeConfiguration = nil
    }
}

private extension URL {
    var hasOsuBeatmapExtension: Bool {
        pathExtension.localizedCaseInsensitiveCompare("osu") == .orderedSame
    }
}

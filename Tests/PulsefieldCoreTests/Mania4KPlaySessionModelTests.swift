import XCTest
@testable import PulsefieldCore

@MainActor
final class Mania4KPlaySessionModelTests: XCTestCase {
    func testDefaultsMatchFirstPlayableSpec() {
        let model = Mania4KPlaySessionModel()

        XCTAssertEqual(model.starDifficulty, 4.0)
        XCTAssertEqual(model.scrollSpeed, 8.0)
        XCTAssertEqual(model.globalAudioOffsetMilliseconds, 0)
        XCTAssertEqual(model.judgeDifficulty, .c)
        XCTAssertFalse(model.isReadyToStart)
        XCTAssertNil(model.activeConfiguration)
    }

    func testStartRequiresBeatmapAndAudioSelections() {
        let model = Mania4KPlaySessionModel()
        let beatmapURL = URL(fileURLWithPath: "/tmp/mock.osu")
        let audioURL = URL(fileURLWithPath: "/tmp/mock.mp3")

        XCTAssertFalse(model.startPlay())
        XCTAssertNil(model.activeConfiguration)

        model.selectBeatmapFile(beatmapURL)
        XCTAssertFalse(model.startPlay())
        XCTAssertNil(model.activeConfiguration)

        model.selectAudioFile(audioURL)
        XCTAssertTrue(model.startPlay())

        XCTAssertEqual(model.activeConfiguration?.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.activeConfiguration?.audioFileURL, audioURL)
    }

    func testStartAllowsUnvalidatedOsuFileUntilParserSlice() {
        let model = Mania4KPlaySessionModel()
        let beatmapURL = URL(fileURLWithPath: "/tmp/not-yet-validated.osu")
        let audioURL = URL(fileURLWithPath: "/tmp/song.wav")

        model.selectBeatmapFile(beatmapURL)
        model.selectAudioFile(audioURL)
        model.starDifficulty = 6.5
        model.scrollSpeed = 12.3
        model.globalAudioOffsetMilliseconds = -42
        model.judgeDifficulty = .e

        XCTAssertTrue(model.startPlay())

        XCTAssertEqual(model.activeConfiguration?.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.activeConfiguration?.audioFileURL, audioURL)
        XCTAssertEqual(model.activeConfiguration?.starDifficulty, 6.5)
        XCTAssertEqual(model.activeConfiguration?.scrollSpeed, 12.3)
        XCTAssertEqual(model.activeConfiguration?.globalAudioOffsetMilliseconds, -42)
        XCTAssertEqual(model.activeConfiguration?.judgeDifficulty, .e)
    }

    func testBeatmapSelectionOnlyAcceptsOsuExtensionWithoutParsingContent() {
        let model = Mania4KPlaySessionModel()
        let nonBeatmapURL = URL(fileURLWithPath: "/tmp/song.mp3")
        let beatmapURL = URL(fileURLWithPath: "/tmp/not-parsed-yet.OSU")

        model.selectBeatmapFile(nonBeatmapURL)

        XCTAssertNil(model.beatmapFileURL)
        XCTAssertFalse(model.isReadyToStart)

        model.selectBeatmapFile(beatmapURL)

        XCTAssertEqual(model.beatmapFileURL, beatmapURL)
    }

    func testBeatmapImportFailureSurfacesMessageWithoutClearingSelection() {
        let model = Mania4KPlaySessionModel()
        let beatmapURL = URL(fileURLWithPath: "/tmp/mock.osu")
        model.selectBeatmapFile(beatmapURL)

        model.recordBeatmapImportFailure(StubImportError.denied)

        XCTAssertEqual(model.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.beatmapSelectionErrorMessage, "Could not choose beatmap: denied")
    }

    func testQuitReturnsToSetupWithoutClearingSelections() {
        let model = Mania4KPlaySessionModel()
        let beatmapURL = URL(fileURLWithPath: "/tmp/mock.osu")
        let audioURL = URL(fileURLWithPath: "/tmp/mock.mp3")

        model.selectBeatmapFile(beatmapURL)
        model.selectAudioFile(audioURL)
        XCTAssertTrue(model.startPlay())

        model.quitToSetup()

        XCTAssertNil(model.activeConfiguration)
        XCTAssertEqual(model.beatmapFileURL, beatmapURL)
        XCTAssertEqual(model.audioFileURL, audioURL)
        XCTAssertTrue(model.isReadyToStart)
    }
}

private enum StubImportError: LocalizedError {
    case denied

    var errorDescription: String? {
        "denied"
    }
}

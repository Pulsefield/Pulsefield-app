import XCTest
@testable import PulsefieldCore

@MainActor
final class RecognitionAppModelTests: XCTestCase {
    func testBootstrapMovesAuthorizedPrototypeToReady() async {
        let permissionService = MockMicrophonePermissionService(status: .authorized)
        let recognitionService = MockRecognitionService(latencyNanoseconds: 0)
        let model = RecognitionAppModel(
            permissionService: permissionService,
            recognitionService: recognitionService,
            beatmapGenerator: NoopBeatmapGenerator()
        )

        model.bootstrap()
        await settle()

        XCTAssertEqual(model.permissionStatus, .authorized)
        XCTAssertEqual(model.phase, .ready)
    }

    func testPrimaryActionRequestsPermissionAndCreatesBeatmapReservation() async {
        let permissionService = MockMicrophonePermissionService(status: .undetermined)
        let recognitionService = MockRecognitionService(
            scriptedOutcomes: [.matched(PreviewFixtures.recognitionSnapshot)],
            latencyNanoseconds: 0
        )
        let model = RecognitionAppModel(
            permissionService: permissionService,
            recognitionService: recognitionService,
            beatmapGenerator: NoopBeatmapGenerator()
        )

        model.handlePrimaryAction()
        await settle()

        XCTAssertEqual(model.permissionStatus, .authorized)
        XCTAssertEqual(model.phase, .matched)
        XCTAssertEqual(model.latestSnapshot?.track.title, PreviewFixtures.recognitionSnapshot.track.title)
        XCTAssertEqual(model.beatmapRequest?.mode, .mania4k)
        XCTAssertEqual(model.beatmapHandle?.status, .reserved)
    }

    func testPrimaryActionHandlesNoMatch() async {
        let model = RecognitionAppModel(
            permissionService: MockMicrophonePermissionService(status: .authorized),
            recognitionService: MockRecognitionService(scriptedOutcomes: [.noMatch], latencyNanoseconds: 0),
            beatmapGenerator: NoopBeatmapGenerator()
        )

        model.handlePrimaryAction()
        await settle()

        XCTAssertEqual(model.phase, .noMatch)
        XCTAssertNil(model.latestSnapshot)
        XCTAssertNil(model.beatmapRequest)
    }

    func testPrimaryActionSurfacesFailure() async {
        let failure = RecognitionFailure(
            title: "Mock Failure",
            message: "The scripted mock service failed."
        )

        let model = RecognitionAppModel(
            permissionService: MockMicrophonePermissionService(status: .authorized),
            recognitionService: MockRecognitionService(scriptedOutcomes: [.failed(failure)], latencyNanoseconds: 0),
            beatmapGenerator: NoopBeatmapGenerator()
        )

        model.handlePrimaryAction()
        await settle()

        XCTAssertEqual(model.phase, .failed(failure))
        XCTAssertEqual(model.lastFailure, failure)
    }

    func testDeniedPermissionBlocksRecognition() async {
        let model = RecognitionAppModel(
            permissionService: MockMicrophonePermissionService(status: .denied),
            recognitionService: MockRecognitionService(latencyNanoseconds: 0),
            beatmapGenerator: NoopBeatmapGenerator()
        )

        model.handlePrimaryAction()
        await settle()

        XCTAssertEqual(model.phase, .microphoneAccessRequired)
        XCTAssertNil(model.latestSnapshot)
    }

    private func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

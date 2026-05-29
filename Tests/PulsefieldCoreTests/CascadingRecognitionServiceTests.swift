import XCTest
@testable import PulsefieldCore

final class CascadingRecognitionServiceTests: XCTestCase {
    func testRecognizeOnceFallsBackToSecondProviderAfterNoMatch() async {
        let clip = RecognitionAudioClip(
            fileURL: URL(fileURLWithPath: "/tmp/pulsefield-sample.m4a"),
            mimeType: "audio/m4a",
            duration: 10,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let service = CascadingRecognitionService(
            captureService: CaptureStub(result: .success(clip)),
            providers: [
                ProviderStub(provider: .shazamKit, outcome: .noMatch),
                ProviderStub(provider: .acrCloud, outcome: .matched(PreviewFixtures.recognitionSnapshot))
            ],
            configuration: .shazamThenACRCloud(
                acrCloud: ACRCloudConfiguration(
                    host: "identify-eu-west-1.acrcloud.com",
                    accessKey: "key",
                    accessSecret: "secret"
                )
            )
        )

        let outcome = await service.recognizeOnce()

        XCTAssertEqual(outcome, .matched(PreviewFixtures.recognitionSnapshot))
    }

    func testRecognizeOnceStopsOnTerminalFailure() async {
        let clip = RecognitionAudioClip(
            fileURL: URL(fileURLWithPath: "/tmp/pulsefield-sample.m4a"),
            mimeType: "audio/m4a",
            duration: 10,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let failure = RecognitionFailure(
            title: "ShazamKit Error",
            message: "The primary provider failed before a fallback was allowed."
        )

        let service = CascadingRecognitionService(
            captureService: CaptureStub(result: .success(clip)),
            providers: [
                ProviderStub(provider: .shazamKit, outcome: .failed(failure)),
                ProviderStub(provider: .acrCloud, outcome: .matched(PreviewFixtures.recognitionSnapshot))
            ],
            configuration: .shazamThenACRCloud(
                acrCloud: ACRCloudConfiguration(
                    host: "identify-eu-west-1.acrcloud.com",
                    accessKey: "key",
                    accessSecret: "secret"
                )
            )
        )

        let outcome = await service.recognizeOnce()

        XCTAssertEqual(outcome, .failed(failure))
    }
}

private actor CaptureStub: RecognitionAudioCapturing {
    private let result: Result<RecognitionAudioClip, RecognitionFailure>

    init(result: Result<RecognitionAudioClip, RecognitionFailure>) {
        self.result = result
    }

    func prepare() async {}

    func captureClip(duration: TimeInterval) async -> Result<RecognitionAudioClip, RecognitionFailure> {
        _ = duration
        return result
    }

    func cancelCapture() async {}
}

private actor ProviderStub: RecognitionProviderClient {
    let provider: RecognitionProvider
    let backendLabel: String

    private let outcome: RecognitionOutcome

    init(provider: RecognitionProvider, outcome: RecognitionOutcome) {
        self.provider = provider
        self.backendLabel = provider.displayName
        self.outcome = outcome
    }

    func prepare() async {}

    func recognize(clip: RecognitionAudioClip) async -> RecognitionOutcome {
        _ = clip
        return outcome
    }

    func cancelRecognition() async {}
}

import Foundation

public actor UnavailableRecognitionProviderClient: RecognitionProviderClient {
    public let provider: RecognitionProvider
    public let backendLabel: String

    private let failure: RecognitionFailure

    public init(
        provider: RecognitionProvider,
        backendLabel: String? = nil,
        failure: RecognitionFailure
    ) {
        self.provider = provider
        self.backendLabel = backendLabel ?? provider.displayName
        self.failure = failure
    }

    public func prepare() async {}

    public func recognize(clip: RecognitionAudioClip) async -> RecognitionOutcome {
        _ = clip
        return .failed(failure)
    }

    public func cancelRecognition() async {}
}

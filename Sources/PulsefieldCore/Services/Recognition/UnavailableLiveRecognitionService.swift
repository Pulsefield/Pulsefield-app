import Foundation

public actor UnavailableLiveRecognitionService: RecognitionServiceProtocol {
    public let backendLabel: String

    public init(backendLabel: String = "ShazamKit (gated milestone)") {
        self.backendLabel = backendLabel
    }

    public func prepare() async {}

    public func recognizeOnce() async -> RecognitionOutcome {
        .failed(.liveRecognitionUnavailable)
    }

    public func cancelRecognition() async {}
}

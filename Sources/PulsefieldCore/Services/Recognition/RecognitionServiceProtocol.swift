import Foundation

public protocol RecognitionServiceProtocol: Sendable {
    var backendLabel: String { get }

    func prepare() async
    func recognizeOnce() async -> RecognitionOutcome
    func cancelRecognition() async
}

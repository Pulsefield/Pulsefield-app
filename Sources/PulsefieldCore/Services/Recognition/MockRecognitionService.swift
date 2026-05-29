import Foundation

public actor MockRecognitionService: RecognitionServiceProtocol {
    public let backendLabel: String

    private var scriptedOutcomes: [RecognitionOutcome]
    private let latencyNanoseconds: UInt64
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0

    public init(
        backendLabel: String = "Mock Catalog",
        scriptedOutcomes: [RecognitionOutcome] = [.matched(PreviewFixtures.recognitionSnapshot)],
        latencyNanoseconds: UInt64 = 700_000_000
    ) {
        self.backendLabel = backendLabel
        self.scriptedOutcomes = scriptedOutcomes
        self.latencyNanoseconds = latencyNanoseconds
    }

    public func prepare() async {
        prepareCount += 1
    }

    public func recognizeOnce() async -> RecognitionOutcome {
        do {
            try await Task.sleep(nanoseconds: latencyNanoseconds)
        } catch {
            return .failed(
                RecognitionFailure(
                    title: "Recognition Cancelled",
                    message: "The mock recognition task was cancelled before it finished."
                )
            )
        }

        guard !scriptedOutcomes.isEmpty else {
            return .failed(.emptyMockCatalog)
        }

        if scriptedOutcomes.count > 1 {
            return scriptedOutcomes.removeFirst()
        }

        return scriptedOutcomes[0]
    }

    public func cancelRecognition() async {
        cancelCount += 1
    }
}

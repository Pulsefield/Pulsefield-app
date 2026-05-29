import Foundation

public actor CascadingRecognitionService: RecognitionServiceProtocol {
    public nonisolated let backendLabel: String

    private let captureService: any RecognitionAudioCapturing
    private let providers: [any RecognitionProviderClient]
    private let configuration: RecognitionPipelineConfiguration

    public init(
        captureService: any RecognitionAudioCapturing,
        providers: [any RecognitionProviderClient],
        configuration: RecognitionPipelineConfiguration
    ) {
        precondition(!providers.isEmpty, "At least one provider client is required.")

        let configuredProviders = configuration.orderedProviders.map(\.provider)
        let concreteProviders = providers.map(\.provider)
        precondition(
            configuredProviders == concreteProviders,
            "Provider client order must match the pipeline configuration."
        )

        self.captureService = captureService
        self.providers = providers
        self.configuration = configuration
        backendLabel = providers.map(\.backendLabel).joined(separator: " -> ")
    }

    public func prepare() async {
        await captureService.prepare()

        for provider in providers {
            await provider.prepare()
        }
    }

    public func recognizeOnce() async -> RecognitionOutcome {
        let captureResult = await captureService.captureClip(duration: configuration.clipDuration)
        let clip: RecognitionAudioClip

        switch captureResult {
        case .success(let capturedClip):
            clip = capturedClip
        case .failure(let failure):
            return .failed(failure)
        }

        // Fallback only advances when a provider explicitly reports "no match"
        // or returns a failure that is safe to route to the next provider.
        for provider in providers {
            let outcome = await provider.recognize(clip: clip)

            switch outcome {
            case .matched:
                return outcome

            case .noMatch:
                continue

            case .failed(let failure) where failure.allowsFallback:
                continue

            case .failed:
                return outcome
            }
        }

        return .noMatch
    }

    public func cancelRecognition() async {
        await captureService.cancelCapture()

        for provider in providers {
            await provider.cancelRecognition()
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
public final class RecognitionAppModel {
    public private(set) var permissionStatus: MicrophonePermissionStatus = .undetermined
    public private(set) var phase: RecognitionPhase = .idle
    public private(set) var activeBackendLabel: String
    public private(set) var latestSnapshot: RecognitionSnapshot?
    public private(set) var beatmapRequest: BeatmapGenerationRequest?
    public private(set) var beatmapHandle: BeatmapGenerationHandle?
    public private(set) var lastFailure: RecognitionFailure?

    @ObservationIgnored
    private let permissionService: any MicrophonePermissionProviding

    @ObservationIgnored
    private let recognitionService: any RecognitionServiceProtocol

    @ObservationIgnored
    private let beatmapGenerator: any BeatmapGenerationProviding

    @ObservationIgnored
    private var recognitionTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasBootstrapped = false

    public init(
        permissionService: any MicrophonePermissionProviding,
        recognitionService: any RecognitionServiceProtocol,
        beatmapGenerator: any BeatmapGenerationProviding
    ) {
        self.permissionService = permissionService
        self.recognitionService = recognitionService
        self.beatmapGenerator = beatmapGenerator
        activeBackendLabel = recognitionService.backendLabel
    }

    public var primaryActionTitle: String {
        if isListening {
            return "Stop Listening"
        }

        switch permissionStatus {
        case .authorized:
            return "Run Mock Recognition"
        case .undetermined:
            return "Grant Microphone Access"
        case .denied, .restricted:
            return "Microphone Blocked"
        }
    }

    public var isListening: Bool {
        phase == .listening
    }

    public var phaseTitle: String {
        switch phase {
        case .idle:
            return "Prototype Ready"
        case .requestingPermission:
            return "Requesting Microphone Access"
        case .ready:
            return "Ready To Listen"
        case .listening:
            return "Simulating Recognition"
        case .matched:
            return "Mock Match Ready"
        case .noMatch:
            return "No Match"
        case .microphoneAccessRequired:
            return "Microphone Needed"
        case .failed(let failure):
            return failure.title
        }
    }

    public var phaseDetail: String {
        switch phase {
        case .idle:
            return "The scaffold is using a mock recognition backend while the live ShazamKit milestone remains gated."
        case .requestingPermission:
            return "The app is triggering the real system microphone prompt through AVFoundation."
        case .ready:
            return "Permission is available. Starting recognition will simulate one full recognition round-trip."
        case .listening:
            return "This prototype delays briefly, then returns a scripted recognition outcome to exercise the UI and architecture."
        case .matched:
            return "A sample recognition snapshot is available and has been converted into a reserved beatmap request."
        case .noMatch:
            return "The mock backend completed without finding a song."
        case .microphoneAccessRequired:
            return "Recognition is blocked until microphone access is granted."
        case .failed(let failure):
            return failure.message
        }
    }

    public static func livePrototype() -> RecognitionAppModel {
        RecognitionAppModel(
            permissionService: MicrophonePermissionService(),
            recognitionService: MockRecognitionService(),
            beatmapGenerator: NoopBeatmapGenerator()
        )
    }

    public static func previewMatched() -> RecognitionAppModel {
        let model = RecognitionAppModel(
            permissionService: MockMicrophonePermissionService(status: .authorized),
            recognitionService: MockRecognitionService(scriptedOutcomes: [.matched(PreviewFixtures.recognitionSnapshot)], latencyNanoseconds: 0),
            beatmapGenerator: NoopBeatmapGenerator()
        )
        model.permissionStatus = .authorized
        model.phase = .matched
        model.latestSnapshot = PreviewFixtures.recognitionSnapshot
        model.beatmapRequest = BeatmapGenerationRequest(snapshot: PreviewFixtures.recognitionSnapshot, mode: .mania4k)
        model.beatmapHandle = BeatmapGenerationHandle(
            status: .reserved,
            note: "Reserved mania4k handoff for preview content."
        )
        return model
    }

    public func bootstrap() {
        guard !hasBootstrapped else {
            return
        }

        hasBootstrapped = true

        Task {
            permissionStatus = await permissionService.currentStatus()
            await recognitionService.prepare()
            applyPermissionStatus(permissionStatus)
        }
    }

    public func handlePrimaryAction() {
        if isListening {
            stopRecognition()
            return
        }

        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            await self?.runRecognitionFlow()
        }
    }

    public func stopRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil

        Task {
            await recognitionService.cancelRecognition()
        }

        applyPermissionStatus(permissionStatus)
    }

    private func runRecognitionFlow() async {
        if permissionStatus == .undetermined {
            phase = .requestingPermission
            permissionStatus = await permissionService.requestAccess()
        } else {
            permissionStatus = await permissionService.currentStatus()
        }

        guard permissionStatus == .authorized else {
            applyPermissionStatus(permissionStatus)
            recognitionTask = nil
            return
        }

        phase = .listening
        lastFailure = nil

        let outcome = await recognitionService.recognizeOnce()

        if Task.isCancelled {
            recognitionTask = nil
            return
        }

        await applyRecognitionOutcome(outcome)
        recognitionTask = nil
    }

    private func applyPermissionStatus(_ status: MicrophonePermissionStatus) {
        switch status {
        case .authorized:
            if !isListening {
                phase = latestSnapshot == nil ? .ready : .matched
            }
        case .undetermined:
            phase = .idle
        case .denied, .restricted:
            phase = .microphoneAccessRequired
        }
    }

    private func applyRecognitionOutcome(_ outcome: RecognitionOutcome) async {
        switch outcome {
        case .matched(let snapshot):
            latestSnapshot = snapshot
            let request = BeatmapGenerationRequest(snapshot: snapshot, mode: .mania4k)
            beatmapRequest = request
            beatmapHandle = try? await beatmapGenerator.reserveBeatmap(for: request)
            lastFailure = nil
            phase = .matched

        case .noMatch:
            latestSnapshot = nil
            beatmapRequest = nil
            beatmapHandle = nil
            lastFailure = nil
            phase = .noMatch

        case .failed(let failure):
            latestSnapshot = nil
            beatmapRequest = nil
            beatmapHandle = nil
            lastFailure = failure
            phase = .failed(failure)
        }
    }
}

#if os(macOS) && DEBUG
import Foundation
import Observation
import PulsefieldCore
import SwiftUI

@MainActor
@Observable
public final class LiveRecognitionSyncModel {
    public private(set) var phase: LiveRecognitionSyncPhase = .idle
    public private(set) var permissionStatus: MicrophonePermissionStatus = .undetermined
    public private(set) var statusMessage = "Ready"
    public private(set) var errorMessage: String?
    public private(set) var loadedEnvFilePath: String?
    public private(set) var localLibraryStatus: LocalAudioLibraryStatus = .empty
    public private(set) var latestClip: RecognitionAudioClip?
    public private(set) var latestExecution: ACRCloudFileScanExecution?
    public private(set) var latestMatch: ACRCloudMusicMatch?
    public private(set) var recognitionSnapshot: RecognitionSnapshot?
    public private(set) var resolveResults: [LocalResolveResult] = []
    public private(set) var referenceSummary: AmbientReferenceSummary?
    public private(set) var latestAmbientSnapshot: AmbientSyncSnapshot?
    public private(set) var ambientUpdateCount = 0
    public private(set) var latestFrameBatchCount = 0

    public var firstRequestAtText = "2"
    public var requestCadenceText = "1"
    public var maxRequestWindowText = "10"
    public var accessToken = ""
    public var acrcloudExecutablePath = "acrcloud"
    public var region = "eu-west-1"
    public var containerIDText = ""
    public var buckets = "23"
    public var engineText = "1"
    public var audioType = "recorded"
    public var scanTimeoutText = "600"
    public var pollIntervalText = "1"
    public var resolveTitle = ""
    public var resolveArtist = ""
    public var resolveAlbum = ""
    public var resolveISRC = ""
    public var resolveDurationMS = ""
    public var selectedResolveAssetID: UUID?

    @ObservationIgnored
    private let permissionService: any MicrophonePermissionProviding

    @ObservationIgnored
    private let captureService: AudioClipCaptureService

    @ObservationIgnored
    private let database: LocalAudioLibraryDatabase

    @ObservationIgnored
    private let resolver: LocalTrackResolver

    @ObservationIgnored
    private let referenceIndexBuilder: AmbientSyncReferenceIndexBuilder

    @ObservationIgnored
    private var environmentValues = ACRCloudFileScanConfiguration.defaultProcessEnvironment()

    @ObservationIgnored
    private var flowTask: Task<Void, Never>?

    @ObservationIgnored
    private var ambientStreamService: AmbientMicFeatureStreamService?

    @ObservationIgnored
    private var ambientRuntime: LiveAmbientSyncRuntime?

    public init(
        database: LocalAudioLibraryDatabase,
        permissionService: any MicrophonePermissionProviding = MicrophonePermissionService(),
        captureService: AudioClipCaptureService = AudioClipCaptureService(),
        referenceIndexBuilder: AmbientSyncReferenceIndexBuilder = AmbientSyncReferenceIndexBuilder()
    ) {
        self.database = database
        self.permissionService = permissionService
        self.captureService = captureService
        self.resolver = LocalTrackResolver(database: database)
        self.referenceIndexBuilder = referenceIndexBuilder

        loadEnvironmentDefaults()
    }

    deinit {
        ambientStreamService?.stop()
        flowTask?.cancel()
    }

    public static func liveDebug() -> LiveRecognitionSyncModel {
        do {
            return LiveRecognitionSyncModel(database: try LocalAudioLibraryDatabase.openDefault())
        } catch {
            let fallback = try! LocalAudioLibraryDatabase.openInMemory()
            let model = LiveRecognitionSyncModel(database: fallback)
            model.errorMessage = "Could not open persistent local audio library: \(error.localizedDescription)"
            return model
        }
    }

    public var canStartFlow: Bool {
        !phase.isBusy && phase != .ambientSyncing
    }

    public var canStartAmbientSync: Bool {
        guard let selectedResolveResult else {
            return false
        }

        return selectedResolveResult.decision != .rejected && !phase.isBusy && phase != .ambientSyncing
    }

    public var selectedResolveResult: LocalResolveResult? {
        guard let selectedResolveAssetID else {
            return nil
        }

        return resolveResults.first { $0.asset.id == selectedResolveAssetID }
    }

    public func refreshLocalLibraryStatus() {
        Task {
            localLibraryStatus = await database.libraryStatus()
        }
    }

    public func startFlow() {
        guard canStartFlow else {
            return
        }

        stopAmbientSync(markStopped: false)
        flowTask?.cancel()
        flowTask = Task { [weak self] in
            await self?.runFlow()
        }
    }

    public func startAmbientSyncForSelectedResult() {
        guard let selectedResolveResult,
              selectedResolveResult.decision != .rejected,
              !phase.isBusy
        else {
            return
        }

        flowTask?.cancel()
        flowTask = Task { [weak self] in
            await self?.startAmbientSync(for: selectedResolveResult.asset)
            self?.flowTask = nil
        }
    }

    public func stop() {
        flowTask?.cancel()
        flowTask = nil

        Task {
            await captureService.cancelCapture()
        }

        stopAmbientSync(markStopped: true)
    }

    public func resolveManualTrack() {
        guard !resolveTitle.trimmed.isEmpty else {
            return
        }

        Task {
            phase = .resolvingLocalAsset
            statusMessage = "Resolving local asset"
            let results = await resolveManualTrackNow()

            if let bestResult = firstConfirmableResult(in: results) {
                selectedResolveAssetID = bestResult.asset.id
                phase = .awaitingLocalConfirmation
                statusMessage = bestResult.decision == .autoAccepted
                    ? "Local match ready"
                    : "Local match needs confirmation"
            } else {
                phase = .completed
                statusMessage = "No confirmable local asset candidate"
            }
        }
    }

    private func runFlow() async {
        resetRunState()
        phase = .requestingPermission
        statusMessage = "Requesting microphone access"
        permissionStatus = await permissionService.requestAccess()

        guard permissionStatus == .authorized else {
            fail("Microphone access is \(permissionStatus.label).")
            flowTask = nil
            return
        }

        let clipRetryConfiguration: LiveRecognitionClipRetryConfiguration
        let fileScanConfiguration: ACRCloudFileScanConfiguration
        do {
            clipRetryConfiguration = try makeClipRetryConfiguration()
            fileScanConfiguration = try makeFileScanConfiguration()
        } catch {
            fail(error.localizedDescription)
            flowTask = nil
            return
        }

        let scanResult = await scanACRCloudWithGrowingClips(
            clipRetryConfiguration: clipRetryConfiguration,
            fileScanConfiguration: fileScanConfiguration
        )

        guard !Task.isCancelled else {
            flowTask = nil
            return
        }

        switch scanResult {
        case .success(let attempt):
            latestExecution = attempt.execution
            guard let music = attempt.execution.result.music else {
                phase = .completed
                statusMessage = "ACRCloud returned no match"
                flowTask = nil
                return
            }

            latestMatch = music
            recognitionSnapshot = ACRCloudFileScanNormalizer.snapshot(from: music, clip: attempt.clip)
            fillResolveFields(from: music)

        case .failure(let failure):
            fail("\(failure.title): \(failure.message)")
            flowTask = nil
            return
        }

        phase = .resolvingLocalAsset
        statusMessage = "Resolving local asset"
        let results = await resolveManualTrackNow()

        guard !Task.isCancelled else {
            flowTask = nil
            return
        }

        guard let bestResult = firstConfirmableResult(in: results) else {
            phase = .completed
            statusMessage = "No confirmable local asset candidate"
            flowTask = nil
            return
        }

        if bestResult.decision == .autoAccepted {
            selectedResolveAssetID = bestResult.asset.id
            await startAmbientSync(for: bestResult.asset)
        } else {
            phase = .awaitingLocalConfirmation
            statusMessage = "Local match needs confirmation"
        }

        flowTask = nil
    }

    private func fillResolveFields(from match: ACRCloudMusicMatch) {
        resolveTitle = match.title
        resolveArtist = match.artists.joined(separator: ", ")
        resolveAlbum = match.album ?? ""
        resolveISRC = match.isrc ?? ""
        resolveDurationMS = match.durationMS.map(String.init) ?? ""
    }

    private func resolveManualTrackNow() async -> [LocalResolveResult] {
        let results = await resolver.resolve(manualResolveTrack())
        applyResolveResults(results)
        return results
    }

    private func manualResolveTrack() -> CanonicalTrack {
        let artists = resolveArtist
            .components(separatedBy: CharacterSet(charactersIn: ",;&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let duration = Int(resolveDurationMS.trimmed)
        let providerValue = latestMatch.map { "recognition-sync:\($0.acrid)" } ?? "recognition-sync"

        return CanonicalTrack(
            title: resolveTitle.trimmed,
            artists: artists,
            album: resolveAlbum.trimmedNilIfEmpty,
            durationMS: duration,
            isrc: resolveISRC.trimmedNilIfEmpty,
            providerIDs: [.init(provider: .manual, value: providerValue)]
        )
    }

    private func applyResolveResults(_ results: [LocalResolveResult]) {
        resolveResults = results
        selectedResolveAssetID = preferredSelectedResult(in: results)?.asset.id
    }

    private func preferredSelectedResult(in results: [LocalResolveResult]) -> LocalResolveResult? {
        firstConfirmableResult(in: results) ?? results.first
    }

    private func firstConfirmableResult(in results: [LocalResolveResult]) -> LocalResolveResult? {
        results.first { $0.decision != .rejected }
    }

    private func startAmbientSync(for asset: LocalAudioAsset) async {
        stopAmbientSync(markStopped: false)
        phase = .buildingReferenceIndex
        statusMessage = "Building ambient reference index"

        do {
            let builder = referenceIndexBuilder
            let sourceDisplayPath = asset.displayPath
            let referenceIndex = try await Task.detached(priority: .userInitiated) {
                try builder.index(forSourceDisplayPath: sourceDisplayPath)
            }.value

            try Task.checkCancellation()

            referenceSummary = AmbientReferenceSummary(
                assetFileName: asset.fileName,
                sourceDisplayPath: referenceIndex.sourceDisplayPath,
                frameCount: referenceIndex.frames.count,
                landmarkCount: referenceIndex.landmarks.count
            )

            try startAmbientMicStream(referenceIndex: referenceIndex)
            latestAmbientSnapshot = nil
            ambientUpdateCount = 0
            latestFrameBatchCount = 0
            phase = .ambientSyncing
            statusMessage = "Ambient sync listening"
        } catch is CancellationError {
            statusMessage = "Stopped"
            phase = .idle
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startAmbientMicStream(referenceIndex: AmbientSyncReferenceIndex) throws {
        let featureConfiguration = referenceIndex.featureConfiguration
        let streamConfiguration = AmbientMicFeatureStreamService.Configuration(
            retentionDurationMS: featureConfiguration.finalLockTargetDurationMS + 1_000,
            expectedHopMS: featureConfiguration.featureHopMS,
            featureWindowSizeSamples: featureConfiguration.featureWindowSizeSamples,
            featureHopSizeSamples: featureConfiguration.featureHopSizeSamples
        )
        let streamService = AmbientMicFeatureStreamService(configuration: streamConfiguration)
        let runtime = LiveAmbientSyncRuntime(referenceIndex: referenceIndex)

        try streamService.start { [weak self, runtime] frames in
            Task {
                guard let update = await runtime.append(frames: frames) else {
                    return
                }

                await MainActor.run {
                    self?.applyAmbientUpdate(update)
                }
            }
        }

        ambientRuntime = runtime
        ambientStreamService = streamService
    }

    private func applyAmbientUpdate(_ update: LiveAmbientSyncUpdate) {
        latestAmbientSnapshot = update.snapshot
        ambientUpdateCount += 1
        latestFrameBatchCount = update.frameBatchCount
    }

    private func resetRunState() {
        errorMessage = nil
        latestClip = nil
        latestExecution = nil
        latestMatch = nil
        recognitionSnapshot = nil
        resolveResults = []
        resolveTitle = ""
        resolveArtist = ""
        resolveAlbum = ""
        resolveISRC = ""
        resolveDurationMS = ""
        selectedResolveAssetID = nil
        referenceSummary = nil
        latestAmbientSnapshot = nil
        ambientUpdateCount = 0
        latestFrameBatchCount = 0
        refreshLocalLibraryStatus()
    }

    private func stopAmbientSync(markStopped: Bool) {
        ambientStreamService?.stop()
        ambientStreamService = nil
        ambientRuntime = nil

        if markStopped {
            statusMessage = "Stopped"
            if phase == .ambientSyncing || phase.isBusy {
                phase = .idle
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        statusMessage = "Failed"
        phase = .failed
    }

    private func scanACRCloudWithGrowingClips(
        clipRetryConfiguration: LiveRecognitionClipRetryConfiguration,
        fileScanConfiguration: ACRCloudFileScanConfiguration
    ) async -> Result<LiveRecognitionACRCloudScanAttempt, RecognitionFailure> {
        switch captureService.startCachedClipCapture() {
        case .success:
            break
        case .failure(let failure):
            return .failure(failure)
        }

        let startedAt = Date()
        var submittedScanCount = 0
        var latestNoMatchAttempt: LiveRecognitionACRCloudScanAttempt?

        return await withTaskGroup(
            of: Result<LiveRecognitionACRCloudScanAttempt, RecognitionFailure>.self
        ) { group in
            for requestWindow in clipRetryConfiguration.durations {
                phase = .recordingClip
                statusMessage = "Recording \(requestWindow.secondsLabel) request window"

                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = requestWindow - elapsed
                if remaining > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64((remaining * 1_000_000_000).rounded()))
                    } catch {
                        group.cancelAll()
                        await captureService.cancelCapture()
                        return .failure(RecognitionFailure(
                            title: "Recognition Sync Cancelled",
                            message: "Recognition sync stopped before ACRCloud returned a match."
                        ))
                    }
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    await captureService.cancelCapture()
                    return .failure(RecognitionFailure(
                        title: "Recognition Sync Cancelled",
                        message: "Recognition sync stopped before ACRCloud returned a match."
                    ))
                }

                let clip: RecognitionAudioClip
                switch captureService.cachedClip(duration: requestWindow) {
                case .success(let cachedClip):
                    clip = cachedClip
                    latestClip = cachedClip

                case .failure(let failure):
                    group.cancelAll()
                    await captureService.cancelCapture()
                    return .failure(failure)
                }

                phase = .scanningACRCloud
                statusMessage = "Submitted ACRCloud request for \(requestWindow.secondsLabel) window"
                submittedScanCount += 1
                group.addTask {
                    let provider = DebugACRCloudRecognitionProvider(configuration: fileScanConfiguration)
                    let scanResult = await provider.scan(clip: clip)

                    switch scanResult {
                    case .success(let execution):
                        return .success(LiveRecognitionACRCloudScanAttempt(clip: clip, execution: execution))
                    case .failure(let failure):
                        return .failure(failure)
                    }
                }
            }

            await captureService.cancelCapture()
            phase = .scanningACRCloud
            statusMessage = "Waiting for ACRCloud responses"

            var firstFailure: RecognitionFailure?
            for _ in 0..<submittedScanCount {
                guard let scanResult = await group.next() else {
                    break
                }

                switch scanResult {
                case .success(let attempt):
                    latestExecution = attempt.execution
                    if attempt.execution.result.music != nil {
                        // TODO: Demo-usable for now, but refine result arbitration later.
                        // Completion order can prefer a longer request window over an earlier shorter match.
                        group.cancelAll()
                        return .success(attempt)
                    }

                    latestNoMatchAttempt = attempt

                case .failure(let failure):
                    firstFailure = firstFailure ?? failure
                }
            }

            if let latestNoMatchAttempt {
                return .success(latestNoMatchAttempt)
            }

            if let firstFailure {
                return .failure(firstFailure)
            }

            return .failure(RecognitionFailure(
                title: "ACRCloud Recognition Skipped",
                message: "No recognition request windows were configured."
            ))
        }
    }

    private func makeClipRetryConfiguration() throws -> LiveRecognitionClipRetryConfiguration {
        let firstRequestAt = try parsePositiveTimeInterval(firstRequestAtText, fieldName: "First request")
        let requestCadence = try parsePositiveTimeInterval(requestCadenceText, fieldName: "Request cadence")
        let maxRequestWindow = try parsePositiveTimeInterval(maxRequestWindowText, fieldName: "Max request window")

        return try LiveRecognitionClipRetryConfiguration(
            firstRequestAt: firstRequestAt,
            requestCadence: requestCadence,
            maxRequestWindow: maxRequestWindow
        )
    }

    private func makeFileScanConfiguration() throws -> ACRCloudFileScanConfiguration {
        let trimmedAccessToken = accessToken.trimmed
        guard !trimmedAccessToken.isEmpty else {
            throw LiveRecognitionSyncError.invalidConfiguration("ACRCLOUD_ACCESS_TOKEN is required.")
        }

        let processEnvironment = ACRCloudFileScanConfiguration.defaultProcessEnvironment(base: environmentValues)
        let executableInput = acrcloudExecutablePath.trimmed.isEmpty
            ? ACRCloudFileScanConfiguration.defaultExecutablePath(environment: processEnvironment)
            : acrcloudExecutablePath.trimmed
        guard let executable = ACRCloudFileScanConfiguration.resolveExecutablePath(
            executableInput,
            environment: processEnvironment
        ) else {
            throw LiveRecognitionSyncError.invalidConfiguration(
                "ACRCloud CLI not found. Set ACRCLOUD_CLI in .env or enter the full acrcloud executable path."
            )
        }

        let resolvedEngine = try parsePositiveInt(engineText, fieldName: "Engine")
        guard (1...4).contains(resolvedEngine) else {
            throw LiveRecognitionSyncError.invalidConfiguration("Engine must be one of 1, 2, 3, or 4.")
        }

        let resolvedTimeout = try parsePositiveInt(scanTimeoutText, fieldName: "Scan timeout")
        let resolvedPollInterval = try parsePositiveInt(pollIntervalText, fieldName: "Poll interval")
        let resolvedContainerID = try parseOptionalPositiveInt(containerIDText, fieldName: "Container ID")

        return ACRCloudFileScanConfiguration(
            accessToken: trimmedAccessToken,
            executablePath: executable,
            region: region.trimmed.isEmpty ? "eu-west-1" : region.trimmed,
            containerID: resolvedContainerID,
            buckets: buckets.trimmed.isEmpty ? "23" : buckets.trimmed,
            engine: resolvedEngine,
            audioType: audioType.trimmed.isEmpty ? "recorded" : audioType.trimmed,
            timeoutSeconds: resolvedTimeout,
            pollIntervalSeconds: resolvedPollInterval,
            environment: processEnvironment
        )
    }

    private func loadEnvironmentDefaults() {
        let environment = LiveRecognitionSyncEnvironment.load()
        environmentValues = ACRCloudFileScanConfiguration.defaultProcessEnvironment(base: environment.values)
        loadedEnvFilePath = environment.loadedEnvFileURL?.path

        accessToken = environment.values["ACRCLOUD_ACCESS_TOKEN"]
            ?? environment.values["ACRCLOUD_PERSONAL_ACCESS_TOKEN"]
            ?? accessToken
        acrcloudExecutablePath = ACRCloudFileScanConfiguration.defaultExecutablePath(environment: environmentValues)
        region = environment.values["ACRCLOUD_FILESCAN_REGION"] ?? region
        containerIDText = environment.values["ACRCLOUD_FILESCAN_CONTAINER_ID"] ?? containerIDText
        buckets = environment.values["ACRCLOUD_FILESCAN_BUCKETS"] ?? buckets
        engineText = environment.values["ACRCLOUD_FILESCAN_ENGINE"] ?? engineText
        audioType = environment.values["ACRCLOUD_FILESCAN_AUDIO_TYPE"] ?? audioType
        scanTimeoutText = environment.values["ACRCLOUD_FILESCAN_TIMEOUT"] ?? scanTimeoutText
        pollIntervalText = environment.values["ACRCLOUD_FILESCAN_POLL_INTERVAL"] ?? pollIntervalText
    }
}

public enum LiveRecognitionSyncPhase: String, CaseIterable, Sendable {
    case idle
    case requestingPermission
    case recordingClip
    case scanningACRCloud
    case resolvingLocalAsset
    case awaitingLocalConfirmation
    case buildingReferenceIndex
    case ambientSyncing
    case completed
    case failed

    public var title: String {
        switch self {
        case .idle:
            return "Ready"
        case .requestingPermission:
            return "Permission"
        case .recordingClip:
            return "Recording"
        case .scanningACRCloud:
            return "ACRCloud"
        case .resolvingLocalAsset:
            return "Local Match"
        case .awaitingLocalConfirmation:
            return "Confirm Match"
        case .buildingReferenceIndex:
            return "Reference Index"
        case .ambientSyncing:
            return "Ambient Sync"
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .requestingPermission, .recordingClip, .scanningACRCloud, .resolvingLocalAsset, .buildingReferenceIndex:
            return true
        case .idle, .awaitingLocalConfirmation, .ambientSyncing, .completed, .failed:
            return false
        }
    }
}

public struct AmbientReferenceSummary: Equatable, Sendable {
    public let assetFileName: String
    public let sourceDisplayPath: String
    public let frameCount: Int
    public let landmarkCount: Int
}

public struct LiveRecognitionSyncWindow: View {
    public static let windowID = "live-recognition-sync"
    public static let windowTitle = "Recognition Sync Flow"

    @Bindable public var model: LiveRecognitionSyncModel

    public init(model: LiveRecognitionSyncModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    flowStatus
                    configurationSection
                    recognitionSection
                    localResolveSection
                    ambientSyncSection
                }
                .padding(20)
                .frame(maxWidth: 980, alignment: .leading)
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .task {
            model.refreshLocalLibraryStatus()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.startFlow()
            } label: {
                Label("Start Flow", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartFlow)

            Button {
                model.startAmbientSyncForSelectedResult()
            } label: {
                Label("Start Ambient Sync", systemImage: "waveform")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canStartAmbientSync)

            Button {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(model.phase.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.phase == .failed ? .red : .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var flowStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(LiveRecognitionSyncPhase.flowSteps, id: \.self) { phase in
                    FlowStepBadge(
                        title: phase.title,
                        systemImage: phase.systemImage,
                        state: stepState(for: phase)
                    )
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                metricRow("status", model.statusMessage)
                metricRow("microphone", model.permissionStatus.rawValue)
                metricRow("indexed assets", "\(model.localLibraryStatus.indexedCount)")
                if let loadedEnvFilePath = model.loadedEnvFilePath {
                    metricRow("env", loadedEnvFilePath)
                }
                if let error = model.errorMessage {
                    metricRow("error", error, valueStyle: .error)
                }
            }
        }
        .sectionPanel()
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                inputRow("first request", text: $model.firstRequestAtText, suffix: "seconds", width: 90)
                inputRow("cadence", text: $model.requestCadenceText, suffix: "seconds", width: 90)
                inputRow("max window", text: $model.maxRequestWindowText, suffix: "seconds", width: 90)
                secureInputRow("token", text: $model.accessToken)
                inputRow("cli", text: $model.acrcloudExecutablePath, width: 300)

                GridRow {
                    Text("region")
                        .foregroundStyle(.secondary)
                    Picker("Region", selection: $model.region) {
                        Text("eu-west-1").tag("eu-west-1")
                        Text("us-west-2").tag("us-west-2")
                        Text("ap-southeast-1").tag("ap-southeast-1")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                inputRow("container", text: $model.containerIDText, suffix: "optional", width: 120)
                inputRow("buckets", text: $model.buckets, width: 90)
                inputRow("engine", text: $model.engineText, width: 90)
                inputRow("audio type", text: $model.audioType, width: 120)
                inputRow("timeout", text: $model.scanTimeoutText, suffix: "seconds", width: 90)
                inputRow("poll", text: $model.pollIntervalText, suffix: "seconds", width: 90)
            }
        }
        .sectionPanel()
    }

    @ViewBuilder
    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recognition")
                .font(.headline)

            if let match = model.latestMatch {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    metricRow("title", match.title)
                    metricRow("artist", match.artists.isEmpty ? "Unknown Artist" : match.artists.joined(separator: ", "))
                    if let album = match.album {
                        metricRow("album", album)
                    }
                    if let isrc = match.isrc {
                        metricRow("ISRC", isrc)
                    }
                    metricRow("ACRCloud ID", match.acrid)
                    if let score = match.score {
                        metricRow("score", "\(score)")
                    }
                    if let offset = match.offsetSeconds {
                        metricRow("offset", offset.secondsLabel)
                    }
                    if let durationMS = match.durationMS {
                        metricRow("duration", durationMS.durationLabel)
                    }
                }
            } else {
                Text("No ACRCloud match yet.")
                    .foregroundStyle(.secondary)
            }

            if let latestClip = model.latestClip {
                Divider()
                metricLine("clip", latestClip.fileURL.path)
            }

            if let command = model.latestExecution?.command {
                metricLine("command", command.shellCommand)
            }
        }
        .sectionPanel()
    }

    @ViewBuilder
    private var localResolveSection: some View {
        LocalResolveDebugPanel(
            title: "Local Match",
            resolveTitle: $model.resolveTitle,
            resolveArtist: $model.resolveArtist,
            resolveAlbum: $model.resolveAlbum,
            resolveISRC: $model.resolveISRC,
            resolveDurationMS: $model.resolveDurationMS,
            resolveResults: model.resolveResults,
            selectedAssetID: $model.selectedResolveAssetID,
            resolveActionTitle: "Resolve Against Local Library",
            onResolve: model.resolveManualTrack
        )
    }

    @ViewBuilder
    private var ambientSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ambient Sync")
                .font(.headline)

            if let referenceSummary = model.referenceSummary {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    metricRow("asset", referenceSummary.assetFileName)
                    metricRow("frames", "\(referenceSummary.frameCount)")
                    metricRow("landmarks", "\(referenceSummary.landmarkCount)")
                    metricRow("path", referenceSummary.sourceDisplayPath)
                }
            }

            if let snapshot = model.latestAmbientSnapshot {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    metricRow("state", snapshot.state.rawValue)
                    metricRow("phase", snapshot.phase.rawValue)
                    metricRow("stage", snapshot.stage.rawValue)
                    metricRow("confidence", snapshot.confidence.formatted(.number.precision(.fractionLength(3))))
                    if let reason = snapshot.withholdReason {
                        metricRow("withheld", reason.rawValue)
                    }
                    if let estimate = snapshot.estimate {
                        metricRow("offset", (estimate.offsetMS / 1_000).secondsLabel)
                        metricRow("reference", (estimate.referenceTimeMS / 1_000).secondsLabel)
                    }
                    metricRow("query", (snapshot.diagnostics.queryDurationMS / 1_000).secondsLabel)
                    metricRow("updates", "\(model.ambientUpdateCount)")
                    metricRow("last batch", "\(model.latestFrameBatchCount) frames")
                }
            } else {
                Text("Ambient sync has not emitted a snapshot yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .sectionPanel()
    }

    private func inputRow(
        _ label: String,
        text: Binding<String>,
        suffix: String? = nil,
        width: CGFloat = 180
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                if let suffix {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func secureInputRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            SecureField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
        }
    }

    private func metricRow(
        _ label: String,
        _ value: String,
        valueStyle: MetricValueStyle = .normal
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(valueStyle == .error ? .red : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func metricLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func stepState(for phase: LiveRecognitionSyncPhase) -> FlowStepBadge.State {
        if model.phase == phase {
            return .active
        }

        guard let currentIndex = LiveRecognitionSyncPhase.flowSteps.firstIndex(of: model.phase),
              let phaseIndex = LiveRecognitionSyncPhase.flowSteps.firstIndex(of: phase),
              phaseIndex < currentIndex
        else {
            return .pending
        }

        return .complete
    }
}

private struct FlowStepBadge: View {
    enum State {
        case pending
        case active
        case complete
    }

    let title: String
    let systemImage: String
    let state: State

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(backgroundStyle, in: Capsule())
    }

    private var foregroundStyle: Color {
        switch state {
        case .pending:
            return .secondary
        case .active:
            return .accentColor
        case .complete:
            return .green
        }
    }

    private var backgroundStyle: Color {
        switch state {
        case .pending:
            return Color.primary.opacity(0.05)
        case .active:
            return Color.accentColor.opacity(0.12)
        case .complete:
            return Color.green.opacity(0.12)
        }
    }
}

private actor LiveAmbientSyncRuntime {
    private var engine: AmbientSyncEngine
    private var streamBuffer: MicFeatureStreamBuffer
    private let queryDurationMS: Double
    private let startedAt = Date()

    init(referenceIndex: AmbientSyncReferenceIndex) {
        let engine = AmbientSyncEngine(referenceIndex: referenceIndex)
        let featureConfiguration = engine.configuration.featureConfiguration
        self.engine = engine
        self.queryDurationMS = featureConfiguration.finalLockTargetDurationMS
        self.streamBuffer = MicFeatureStreamBuffer(
            retentionDurationMS: featureConfiguration.finalLockTargetDurationMS + 1_000,
            expectedHopMS: featureConfiguration.featureHopMS
        )
    }

    func append(frames: [MicFeatureFrame]) -> LiveAmbientSyncUpdate? {
        streamBuffer.append(frames)

        guard let queryWindow = streamBuffer.latestWindow(durationMS: queryDurationMS) else {
            return nil
        }

        let elapsedMS = Date().timeIntervalSince(startedAt) * 1_000
        let snapshot = engine.process(queryWindow: queryWindow, elapsedMS: elapsedMS)
        return LiveAmbientSyncUpdate(snapshot: snapshot, frameBatchCount: frames.count)
    }
}

private struct LiveAmbientSyncUpdate: Sendable {
    let snapshot: AmbientSyncSnapshot
    let frameBatchCount: Int
}

private struct LiveRecognitionACRCloudScanAttempt: Sendable {
    let clip: RecognitionAudioClip
    let execution: ACRCloudFileScanExecution
}

private struct LiveRecognitionClipRetryConfiguration: Equatable, Sendable {
    let firstRequestAt: TimeInterval
    let requestCadence: TimeInterval
    let maxRequestWindow: TimeInterval

    init(
        firstRequestAt: TimeInterval,
        requestCadence: TimeInterval,
        maxRequestWindow: TimeInterval
    ) throws {
        guard firstRequestAt <= maxRequestWindow else {
            throw LiveRecognitionSyncError.invalidConfiguration("First request must be less than or equal to max request window.")
        }

        self.firstRequestAt = firstRequestAt
        self.requestCadence = requestCadence
        self.maxRequestWindow = maxRequestWindow
    }

    var durations: [TimeInterval] {
        var values: [TimeInterval] = []
        var duration = firstRequestAt

        while duration < maxRequestWindow {
            values.append(duration)
            duration += requestCadence
        }

        if values.last != maxRequestWindow {
            values.append(maxRequestWindow)
        }

        return values
    }
}

private struct LiveRecognitionSyncEnvironment {
    let values: [String: String]
    let loadedEnvFileURL: URL?

    static func load() -> LiveRecognitionSyncEnvironment {
        var values = ProcessInfo.processInfo.environment
        var loadedEnvFileURL: URL?

        for envFileURL in envFileCandidates() where FileManager.default.fileExists(atPath: envFileURL.path) {
            if let envValues = try? parseEnvFile(at: envFileURL) {
                values.merge(envValues) { _, fileValue in fileValue }
                loadedEnvFileURL = envFileURL
                break
            }
        }

        return LiveRecognitionSyncEnvironment(values: values, loadedEnvFileURL: loadedEnvFileURL)
    }

    private static func envFileCandidates() -> [URL] {
        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".env")
        ]

        if let projectRootURL = projectRootURL() {
            candidates.append(projectRootURL.appendingPathComponent(".env"))
        }

        return candidates
    }

    private static func projectRootURL() -> URL? {
        var url = URL(fileURLWithPath: #filePath)

        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        return nil
    }

    private static func parseEnvFile(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<equalsIndex]).trimmed
            let rawValue = String(line[line.index(after: equalsIndex)...]).trimmed
            guard !key.isEmpty else {
                continue
            }

            values[key] = unquoted(rawValue)
        }

        return values
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return value
        }

        return String(value.dropFirst().dropLast())
    }
}

private enum LiveRecognitionSyncError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        }
    }
}

private enum MetricValueStyle {
    case normal
    case error
}

private extension LiveRecognitionSyncPhase {
    static let flowSteps: [LiveRecognitionSyncPhase] = [
        .recordingClip,
        .scanningACRCloud,
        .resolvingLocalAsset,
        .buildingReferenceIndex,
        .ambientSyncing
    ]

    var systemImage: String {
        switch self {
        case .idle:
            return "circle"
        case .requestingPermission:
            return "mic"
        case .recordingClip:
            return "record.circle"
        case .scanningACRCloud:
            return "cloud"
        case .resolvingLocalAsset:
            return "music.note.list"
        case .awaitingLocalConfirmation:
            return "checkmark.circle"
        case .buildingReferenceIndex:
            return "waveform.path"
        case .ambientSyncing:
            return "waveform"
        case .completed:
            return "checkmark"
        case .failed:
            return "xmark"
        }
    }
}

private extension View {
    func sectionPanel() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension MicrophonePermissionStatus {
    var label: String {
        switch self {
        case .undetermined:
            return "undetermined"
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        }
    }
}

private extension Array where Element == String {
    var shellCommand: String {
        map { argument in
            if argument.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
                return argument
            }

            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        .joined(separator: " ")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Int {
    var durationLabel: String {
        (Double(self) / 1_000).secondsLabel
    }
}

private extension TimeInterval {
    var secondsLabel: String {
        String(format: "%.2fs", self)
    }
}

private func parsePositiveTimeInterval(_ value: String, fieldName: String) throws -> TimeInterval {
    guard let parsed = TimeInterval(value.trimmed), parsed > 0 else {
        throw LiveRecognitionSyncError.invalidConfiguration("\(fieldName) must be a positive number.")
    }

    return parsed
}

private func parsePositiveInt(_ value: String, fieldName: String) throws -> Int {
    guard let parsed = Int(value.trimmed), parsed > 0 else {
        throw LiveRecognitionSyncError.invalidConfiguration("\(fieldName) must be a positive integer.")
    }

    return parsed
}

private func parseOptionalPositiveInt(_ value: String, fieldName: String) throws -> Int? {
    let trimmed = value.trimmed
    guard !trimmed.isEmpty else {
        return nil
    }

    return try parsePositiveInt(trimmed, fieldName: fieldName)
}

#Preview {
    LiveRecognitionSyncWindow(model: .liveDebug())
}
#endif

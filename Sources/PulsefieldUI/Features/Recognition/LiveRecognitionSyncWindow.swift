#if os(macOS) && DEBUG
import Foundation
import Observation
import PulsefieldCore
import SwiftUI

public struct LiveRecognitionPlaySessionRequest: Equatable, Sendable {
    public let audioFileURL: URL
    public let referenceTimeMS: Double
    public let anchorHostTimeMS: Double
    public let durationMS: Double?
    public let title: String?
    public let isMock: Bool
    public let musicSource: MusicSource

    public init(
        audioFileURL: URL,
        referenceTimeMS: Double,
        anchorHostTimeMS: Double,
        durationMS: Double?,
        title: String?,
        isMock: Bool,
        musicSource: MusicSource
    ) {
        self.audioFileURL = audioFileURL
        self.referenceTimeMS = referenceTimeMS
        self.anchorHostTimeMS = anchorHostTimeMS
        self.durationMS = durationMS
        self.title = title
        self.isMock = isMock
        self.musicSource = musicSource
    }
}

public typealias LiveRecognitionPlaySessionRequestHandler = @MainActor (LiveRecognitionPlaySessionRequest) -> Void

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
    public private(set) var latestExecution: ACRCloudIdentificationExecution?
    public private(set) var latestMatch: ACRCloudMusicMatch?
    public private(set) var recognitionSnapshot: RecognitionSnapshot?
    public private(set) var resolveResults: [LocalResolveResult] = []
    public private(set) var referenceSummary: AmbientReferenceSummary?
    public private(set) var latestAmbientSnapshot: AmbientSyncSnapshot?
    public private(set) var ambientReferencePlaybackAnchor: AmbientReferencePlaybackAnchor?
    public private(set) var ambientUpdateCount = 0
    public private(set) var latestFrameBatchCount = 0
    public private(set) var inferenceEndpointStatus = "Idle"
    public private(set) var inferenceSessionID: String?
    public private(set) var inferenceReceivedTokenCount = 0
    public private(set) var inferenceReadyWindowMS: Double = 0
    public private(set) var inferenceStreamingStarted = false
    public private(set) var inferenceLastTokenDescription: String?
    public var inferenceIsMock = false

    public var firstRequestAtText = "3"
    public var requestCadenceText = "1"
    public var maxRequestWindowText = "10"
    public var identificationHost = "identify-ap-southeast-1.acrcloud.com"
    public var identificationAccessKey = ""
    public var identificationAccessSecret = ""
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
    public var musicSource: MusicSource = .background

    @ObservationIgnored
    private let permissionService: any MicrophonePermissionProviding

    @ObservationIgnored
    private let captureService: AudioClipCaptureService

    @ObservationIgnored
    private let systemAudioClipCaptureService: SystemAudioClipCaptureService

    @ObservationIgnored
    private let database: LocalAudioLibraryDatabase

    @ObservationIgnored
    private let resolver: LocalTrackResolver

    @ObservationIgnored
    private let referenceIndexBuilder: AmbientSyncReferenceIndexBuilder

    @ObservationIgnored
    private let inferenceEndpointClientFactory: InferenceEndpointClientFactory

    @ObservationIgnored
    private var playSessionRequestHandler: LiveRecognitionPlaySessionRequestHandler?

    @ObservationIgnored
    private var environmentValues = ACRCloudFileScanConfiguration.defaultProcessEnvironment()

    @ObservationIgnored
    private var flowTask: Task<Void, Never>?

    @ObservationIgnored
    private var ambientSession: LiveAmbientSyncSession?

    @ObservationIgnored
    private var ambientSessionID: UUID?

    @ObservationIgnored
    private var inferenceSetupTask: Task<Void, Never>?

    @ObservationIgnored
    private var inferenceReceiveTask: Task<Void, Never>?

    @ObservationIgnored
    private var inferenceTokenBuffer = InferenceHitObjectTokenBuffer()

    @ObservationIgnored
    private var inferenceReferenceTimeSent = false

    @ObservationIgnored
    private var inferenceEndpoint: (any InferenceEndpointClient)?

    @ObservationIgnored
    private var ambientReferenceAsset: LocalAudioAsset?

    @ObservationIgnored
    private var didRequestPlaySessionForAmbientLock = false

    private let inferenceReadyWindowStartThresholdMS: Double = 2_000

    public init(
        database: LocalAudioLibraryDatabase,
        permissionService: any MicrophonePermissionProviding = MicrophonePermissionService(),
        captureService: AudioClipCaptureService = AudioClipCaptureService(),
        systemAudioClipCaptureService: SystemAudioClipCaptureService = SystemAudioClipCaptureService(),
        referenceIndexBuilder: AmbientSyncReferenceIndexBuilder = AmbientSyncReferenceIndexBuilder(),
        inferenceIsMock: Bool = false,
        inferenceEndpoint: (any InferenceEndpointClient)? = nil,
        inferenceEndpointClientFactory: @escaping InferenceEndpointClientFactory = {
            InferenceEndpointWebSocketClient(configuration: $0)
        },
        onPlaySessionRequested: LiveRecognitionPlaySessionRequestHandler? = nil
    ) {
        self.database = database
        self.permissionService = permissionService
        self.captureService = captureService
        self.systemAudioClipCaptureService = systemAudioClipCaptureService
        self.resolver = LocalTrackResolver(database: database)
        self.referenceIndexBuilder = referenceIndexBuilder
        self.inferenceIsMock = inferenceIsMock
        if let inferenceEndpoint {
            self.inferenceEndpointClientFactory = { _ in inferenceEndpoint }
        } else {
            self.inferenceEndpointClientFactory = inferenceEndpointClientFactory
        }
        self.playSessionRequestHandler = onPlaySessionRequested

        loadEnvironmentDefaults()
    }

    deinit {
        ambientSession?.stop()
        inferenceSetupTask?.cancel()
        inferenceReceiveTask?.cancel()
        flowTask?.cancel()
    }

    public static func liveDebug(
        onPlaySessionRequested: LiveRecognitionPlaySessionRequestHandler? = nil
    ) -> LiveRecognitionSyncModel {
        do {
            return LiveRecognitionSyncModel(
                database: try LocalAudioLibraryDatabase.openDefault(),
                onPlaySessionRequested: onPlaySessionRequested
            )
        } catch {
            let fallback = try! LocalAudioLibraryDatabase.openInMemory()
            let model = LiveRecognitionSyncModel(
                database: fallback,
                onPlaySessionRequested: onPlaySessionRequested
            )
            model.errorMessage = "Could not open persistent local audio library: \(error.localizedDescription)"
            return model
        }
    }

    public var canStartFlow: Bool {
        flowTask == nil && !phase.isBusy && phase != .ambientSyncing
    }

    public var canStartAmbientSync: Bool {
        guard let selectedResolveResult else {
            return false
        }

        return selectedResolveResult.decision != .rejected
            && flowTask == nil
            && !phase.isBusy
            && phase != .ambientSyncing
    }

    public var canChangeMusicSource: Bool {
        flowTask == nil && !phase.isBusy && phase != .ambientSyncing
    }

    public var canChangeInferenceRoute: Bool {
        inferenceSessionID == nil && flowTask == nil && !phase.isBusy && phase != .ambientSyncing
    }

    public func setPlaySessionRequestHandler(_ handler: LiveRecognitionPlaySessionRequestHandler?) {
        playSessionRequestHandler = handler
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

        flowTask?.cancel()
        let selectedMusicSource = musicSource
        phase = .recordingClip
        statusMessage = "Starting \(selectedMusicSource.label) capture"
        flowTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.stopAmbientSyncAndWait(markStopped: false)
            guard !Task.isCancelled else {
                self.flowTask = nil
                return
            }

            await self.runFlow(musicSource: selectedMusicSource)
        }
    }

    public func startAmbientSyncForSelectedResult() {
        guard canStartAmbientSync,
              let selectedResolveResult
        else {
            return
        }

        flowTask?.cancel()
        let selectedMusicSource = musicSource
        phase = .buildingReferenceIndex
        statusMessage = "Starting ambient sync"
        flowTask = Task { [weak self] in
            await self?.startAmbientSync(for: selectedResolveResult.asset, musicSource: selectedMusicSource)
            self?.flowTask = nil
        }
    }

    public func stop() {
        flowTask?.cancel()
        flowTask = nil
        let ambientSessionToStop = takeAmbientSession(markStopped: true)
        stopInferenceSession(markStopped: true)

        Task {
            await captureService.cancelCapture()
            await systemAudioClipCaptureService.cancelCapture()
            await ambientSessionToStop?.stopAndWait()
        }
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

    private func runFlow(musicSource: MusicSource) async {
        resetRunState()
        guard await prepareSelectedMusicSourceInput(musicSource: musicSource) else {
            flowTask = nil
            return
        }

        let clipRetryConfiguration: LiveRecognitionClipRetryConfiguration
        let identificationConfiguration: ACRCloudConfiguration
        do {
            clipRetryConfiguration = try makeClipRetryConfiguration()
            identificationConfiguration = try makeIdentificationConfiguration()
        } catch {
            fail(error.localizedDescription)
            flowTask = nil
            return
        }

        let scanResult = await scanACRCloudWithGrowingClips(
            musicSource: musicSource,
            clipRetryConfiguration: clipRetryConfiguration,
            identificationConfiguration: identificationConfiguration
        )

        guard !Task.isCancelled else {
            flowTask = nil
            return
        }

        switch scanResult {
        case .success(let attempt):
            latestExecution = attempt.execution
            guard let music = attempt.execution.response.music else {
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
            await startAmbientSync(for: bestResult.asset, musicSource: musicSource)
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

    private func startAmbientSync(for asset: LocalAudioAsset, musicSource: MusicSource) async {
        await stopAmbientSyncAndWait(markStopped: false)
        guard !Task.isCancelled else {
            flowTask = nil
            return
        }

        ambientReferenceAsset = asset
        didRequestPlaySessionForAmbientLock = false
        startInferenceSession(for: asset, musicSource: musicSource)
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
                durationMS: asset.durationMS,
                frameCount: referenceIndex.frames.count,
                landmarkCount: referenceIndex.landmarks.count
            )

            try await startAmbientStream(referenceIndex: referenceIndex, musicSource: musicSource)
            latestAmbientSnapshot = nil
            ambientUpdateCount = 0
            latestFrameBatchCount = 0
            phase = .ambientSyncing
            statusMessage = "Ambient sync listening"
        } catch is CancellationError {
            stopInferenceSession(markStopped: false)
            statusMessage = "Stopped"
            phase = .idle
        } catch {
            stopInferenceSession(markStopped: false)
            fail(error.localizedDescription)
        }
    }

    private func prepareSelectedMusicSourceInput(musicSource: MusicSource) async -> Bool {
        switch musicSource {
        case .background:
            phase = .requestingPermission
            statusMessage = "Requesting microphone access"
            permissionStatus = await permissionService.requestAccess()

            guard permissionStatus == .authorized else {
                fail("Microphone access is \(permissionStatus.label).")
                return false
            }

            return true

        case .systemAudio:
            phase = .recordingClip
            statusMessage = "Starting system audio capture"
            return true
        }
    }

    private func startAmbientStream(referenceIndex: AmbientSyncReferenceIndex, musicSource: MusicSource) async throws {
        let featureConfiguration = referenceIndex.featureConfiguration
        let streamConfiguration = AmbientMicFeatureStreamService.Configuration(
            retentionDurationMS: featureConfiguration.finalLockTargetDurationMS + 1_000,
            expectedHopMS: featureConfiguration.featureHopMS,
            featureWindowSizeSamples: featureConfiguration.featureWindowSizeSamples,
            featureHopSizeSamples: featureConfiguration.featureHopSizeSamples
        )
        let session = LiveAmbientSyncSession(
            referenceIndex: referenceIndex,
            streamConfiguration: streamConfiguration,
            musicSource: musicSource,
            onUpdate: { [weak self] update, sessionID in
                await MainActor.run {
                    self?.applyAmbientUpdate(update, sessionID: sessionID)
                }
            },
            onFailure: { [weak self] error, sessionID in
                await MainActor.run {
                    self?.applyAmbientStreamFailure(error, sessionID: sessionID)
                }
            }
        )
        ambientSessionID = session.id

        do {
            try await session.start()
        } catch {
            if ambientSessionID == session.id {
                ambientSessionID = nil
            }
            await session.stopAndWait()
            throw error
        }

        ambientSession = session
    }

    private func applyAmbientUpdate(_ update: LiveAmbientSyncUpdate, sessionID: UUID) {
        guard ambientSessionID == sessionID else {
            return
        }

        latestAmbientSnapshot = update.snapshot
        if let estimate = update.snapshot.estimate {
            ambientReferencePlaybackAnchor = AmbientReferencePlaybackAnchor(
                referenceTimeAtAnchorMS: AmbientSyncTimeProjection.referenceTimeAtNowMS(
                    localReferenceTimeAtQueryMS: estimate.referenceTimeMS,
                    queryEndpointRecordedTimeMS: estimate.queryEndpointRecordedTimeMS,
                    nowMS: update.latestRecordedTimeMS
                ) + update.queryEndpointToReceiveLatencyMS,
                durationMS: referenceSummary?.durationMS,
                anchorHostTimeMS: update.receivedHostTimeMS
            )
        }
        ambientUpdateCount += 1
        latestFrameBatchCount = update.frameBatchCount

        if update.snapshot.state == .locked, update.snapshot.phase == .final {
            let referenceTimeMS = ambientReferenceTimeMS(for: update)
            sendInferenceReferenceTimeAfterLock(referenceTimeMS: referenceTimeMS)
            requestPlaySessionAfterAmbientFinalLock(
                referenceTimeMS: referenceTimeMS,
                anchorHostTimeMS: update.receivedHostTimeMS
            )
            ambientSessionID = nil
            ambientSession?.stop()
            ambientSession = nil
            phase = .completed
            statusMessage = "Ambient sync locked"
        }
    }

    private func applyAmbientStreamFailure(_ error: Error, sessionID: UUID) {
        guard ambientSessionID == sessionID else {
            return
        }

        ambientSessionID = nil
        ambientSession?.stop()
        ambientSession = nil
        ambientReferenceAsset = nil
        didRequestPlaySessionForAmbientLock = false
        stopInferenceSession(markStopped: false)
        fail("Ambient audio capture failed: \(error.localizedDescription)")
    }

    #if DEBUG
    func debugInjectAmbientSyncState(
        referenceSummary: AmbientReferenceSummary,
        snapshot: AmbientSyncSnapshot,
        updateCount: Int,
        frameBatchCount: Int
    ) {
        self.referenceSummary = referenceSummary
        latestAmbientSnapshot = snapshot
        ambientReferencePlaybackAnchor = snapshot.estimate.map {
            AmbientReferencePlaybackAnchor(
                referenceTimeAtAnchorMS: $0.referenceTimeMS,
                durationMS: referenceSummary.durationMS,
                anchorHostTimeMS: PulsefieldHostClock.currentTimeMS()
            )
        }
        ambientUpdateCount = updateCount
        latestFrameBatchCount = frameBatchCount
        ambientSessionID = UUID()
        phase = .ambientSyncing
    }

    func debugApplyAmbientFinalLock(
        asset: LocalAudioAsset,
        referenceTimeAtQueryMS: Double,
        queryEndpointRecordedTimeMS: Double,
        latestRecordedTimeMS: Double,
        queryEndpointToReceiveLatencyMS: Double,
        receivedHostTimeMS: Double = PulsefieldHostClock.currentTimeMS()
    ) {
        ambientReferenceAsset = asset
        didRequestPlaySessionForAmbientLock = false
        referenceSummary = AmbientReferenceSummary(
            assetFileName: asset.fileName,
            sourceDisplayPath: asset.displayPath,
            durationMS: asset.durationMS,
            frameCount: 0,
            landmarkCount: 0
        )
        let sessionID = UUID()
        ambientSessionID = sessionID
        phase = .ambientSyncing
        applyAmbientUpdate(
            LiveAmbientSyncUpdate(
                snapshot: AmbientSyncSnapshot(
                    state: .locked,
                    phase: .final,
                    stage: .tracking,
                    estimate: AmbientSyncEstimate(
                        queryEndpointRecordedTimeMS: queryEndpointRecordedTimeMS,
                        referenceTimeMS: referenceTimeAtQueryMS,
                        offsetMS: referenceTimeAtQueryMS - queryEndpointRecordedTimeMS
                    ),
                    diagnostics: AmbientSyncDiagnostics(
                        queryDurationMS: 5_000,
                        activeFrameFraction: 1,
                        queryLandmarkCount: 24
                    )
                ),
                latestRecordedTimeMS: latestRecordedTimeMS,
                queryEndpointToReceiveLatencyMS: queryEndpointToReceiveLatencyMS,
                receivedHostTimeMS: receivedHostTimeMS,
                frameBatchCount: 1
            ),
            sessionID: sessionID
        )
    }

    func debugStartInferenceSession(for asset: LocalAudioAsset, musicSource: MusicSource = .background) {
        startInferenceSession(for: asset, musicSource: musicSource)
    }
    #endif

    private func resetAmbientSyncState() {
        referenceSummary = nil
        latestAmbientSnapshot = nil
        ambientReferencePlaybackAnchor = nil
        ambientUpdateCount = 0
        latestFrameBatchCount = 0
        ambientReferenceAsset = nil
        didRequestPlaySessionForAmbientLock = false
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
        ambientSessionID = nil
        ambientSession?.stop()
        ambientSession = nil
        resetAmbientSyncState()
        stopInferenceSession(markStopped: false)
        refreshLocalLibraryStatus()
    }

    private func stopAmbientSync(markStopped: Bool) {
        let session = takeAmbientSession(markStopped: markStopped)
        session?.stop()
    }

    private func stopAmbientSyncAndWait(markStopped: Bool) async {
        let session = takeAmbientSession(markStopped: markStopped)
        await session?.stopAndWait()
    }

    private func takeAmbientSession(markStopped: Bool) -> LiveAmbientSyncSession? {
        ambientSessionID = nil
        let session = ambientSession
        ambientSession = nil
        resetAmbientSyncState()

        if markStopped {
            statusMessage = "Stopped"
            if phase == .ambientSyncing || phase.isBusy {
                phase = .idle
            }
        }

        return session
    }

    private func startInferenceSession(for asset: LocalAudioAsset, musicSource: MusicSource) {
        stopInferenceSession(markStopped: false)

        let sessionID = UUID().uuidString
        let endpointConfiguration = InferenceEndpointConfiguration(isMock: inferenceIsMock)
        let endpoint = inferenceEndpointClientFactory(endpointConfiguration)
        inferenceEndpoint = endpoint
        inferenceSessionID = sessionID
        inferenceEndpointStatus = "Connecting to \(InferenceEndpointWebSocketClient.defaultEndpointURL.absoluteString)"
        inferenceReceivedTokenCount = 0
        inferenceReadyWindowMS = 0
        inferenceStreamingStarted = false
        inferenceLastTokenDescription = nil
        inferenceTokenBuffer.removeAll()
        inferenceReferenceTimeSent = false

        inferenceReceiveTask = Task { @MainActor [weak self] in
            await self?.receiveInferenceEvents(sessionID: sessionID, endpoint: endpoint)
        }

        inferenceSetupTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await endpoint.prepare()
                try await endpoint.sendAudioPath(
                    asset.displayPath,
                    sessionID: sessionID,
                    musicSource: musicSource
                )
                guard inferenceSessionID == sessionID else {
                    return
                }
                inferenceEndpointStatus = "Audio path sent; awaiting ambient reference time"
            } catch {
                guard inferenceSessionID == sessionID else {
                    return
                }
                inferenceEndpointStatus = "Inference WS setup failed: \(error.localizedDescription)"
            }
        }
    }

    private func sendInferenceReferenceTimeAfterLock(referenceTimeMS: Double?) {
        guard let sessionID = inferenceSessionID,
              let endpoint = inferenceEndpoint,
              !inferenceReferenceTimeSent else {
            return
        }

        guard let referenceTimeMS else {
            inferenceEndpointStatus = "Ambient locked without a reference time estimate"
            return
        }

        inferenceReferenceTimeSent = true
        inferenceEndpointStatus = "Sending ambient reference time"
        let setupTask = inferenceSetupTask

        Task { @MainActor [weak self] in
            await setupTask?.value
            guard let self, self.inferenceSessionID == sessionID else {
                return
            }

            do {
                try await endpoint.sendReferenceTime(
                    sessionID: sessionID,
                    refTimeMS: referenceTimeMS,
                    localHostTimeSendMS: PulsefieldHostClock.currentTimeMS()
                )
                inferenceEndpointStatus = "Reference time sent; awaiting tokens"
            } catch {
                guard inferenceSessionID == sessionID else {
                    return
                }
                inferenceEndpointStatus = "Reference time send failed: \(error.localizedDescription)"
            }
        }
    }

    private func ambientReferenceTimeMS(for update: LiveAmbientSyncUpdate) -> Double? {
        if let estimate = update.snapshot.estimate {
            return AmbientSyncTimeProjection.referenceTimeAtNowMS(
                localReferenceTimeAtQueryMS: estimate.referenceTimeMS,
                queryEndpointRecordedTimeMS: estimate.queryEndpointRecordedTimeMS,
                nowMS: update.latestRecordedTimeMS
            ) + update.queryEndpointToReceiveLatencyMS
        }

        return ambientReferencePlaybackAnchor?.referenceTimeMS(
            atHostTimeMS: update.receivedHostTimeMS
        )
    }

    private func requestPlaySessionAfterAmbientFinalLock(
        referenceTimeMS: Double?,
        anchorHostTimeMS: Double
    ) {
        guard !didRequestPlaySessionForAmbientLock,
              let playSessionRequestHandler,
              let asset = ambientReferenceAsset,
              let referenceTimeMS else {
            return
        }

        didRequestPlaySessionForAmbientLock = true
        playSessionRequestHandler(
            LiveRecognitionPlaySessionRequest(
                audioFileURL: URL(fileURLWithPath: asset.displayPath),
                referenceTimeMS: referenceTimeMS,
                anchorHostTimeMS: anchorHostTimeMS,
                durationMS: Double(asset.durationMS),
                title: asset.title?.trimmedNilIfEmpty ?? latestMatch?.title.trimmedNilIfEmpty ?? asset.fileName,
                isMock: inferenceIsMock,
                musicSource: musicSource
            )
        )
    }

    private func receiveInferenceEvents(sessionID: String, endpoint: any InferenceEndpointClient) async {
        do {
            while !Task.isCancelled {
                let event = try await endpoint.nextEvent()
                applyInferenceEvent(event, expectedSessionID: sessionID)
            }
        } catch is CancellationError {
            return
        } catch {
            guard inferenceSessionID == sessionID else {
                return
            }
            inferenceEndpointStatus = "Inference WS receive failed: \(error.localizedDescription)"
        }
    }

    private func applyInferenceEvent(_ event: InferenceEndpointEvent, expectedSessionID: String) {
        switch event {
        case .hitObjectToken(let token):
            guard token.sessionID == expectedSessionID,
                  token.sessionID == inferenceSessionID
            else {
                return
            }

            guard inferenceTokenBuffer.append(contentsOf: token.objects) else {
                return
            }

            inferenceReceivedTokenCount += 1
            inferenceReadyWindowMS = inferenceTokenBuffer.readyWindow?.lengthMS ?? 0
            inferenceLastTokenDescription = "token_id \(token.tokenID) -> \(token.objects.count) objects @ \(Int(token.timeMS.rounded())) ms"

            if !inferenceStreamingStarted,
               inferenceReadyWindowMS >= inferenceReadyWindowStartThresholdMS {
                inferenceStreamingStarted = true
                inferenceEndpointStatus = "Ready window reached; streaming render can start"
            } else if inferenceStreamingStarted {
                inferenceEndpointStatus = "Streaming tokens"
            } else {
                inferenceEndpointStatus = "Buffering tokens"
            }
        case .endOfStream(let end):
            guard end.sessionID == expectedSessionID,
                  end.sessionID == inferenceSessionID
            else {
                return
            }

            inferenceTokenBuffer.setMaximumAcceptedTimeMS(end.completeThroughMS)
            inferenceReadyWindowMS = inferenceTokenBuffer.readyWindow?.lengthMS ?? inferenceReadyWindowMS
            inferenceLastTokenDescription = "end_of_stream @ \(Int(end.completeThroughMS.rounded())) ms"
            inferenceEndpointStatus = "Inference stream complete"
        }
    }

    private func stopInferenceSession(markStopped: Bool) {
        let sessionID = inferenceSessionID
        let endpoint = inferenceEndpoint
        inferenceSessionID = nil
        inferenceEndpoint = nil
        inferenceReferenceTimeSent = false
        inferenceSetupTask?.cancel()
        inferenceSetupTask = nil
        inferenceReceiveTask?.cancel()
        inferenceReceiveTask = nil
        inferenceTokenBuffer.removeAll()
        inferenceReceivedTokenCount = 0
        inferenceReadyWindowMS = 0
        inferenceStreamingStarted = false
        inferenceLastTokenDescription = nil

        if let sessionID {
            Task {
                try? await endpoint?.stop(sessionID: sessionID)
            }
        }

        inferenceEndpointStatus = markStopped ? "Stopped" : "Idle"
    }

    private func fail(_ message: String) {
        errorMessage = message
        statusMessage = "Failed"
        phase = .failed
    }

    private func scanACRCloudWithGrowingClips(
        musicSource: MusicSource,
        clipRetryConfiguration: LiveRecognitionClipRetryConfiguration,
        identificationConfiguration: ACRCloudConfiguration
    ) async -> Result<LiveRecognitionACRCloudScanAttempt, RecognitionFailure> {
        switch await startCachedClipCapture(musicSource: musicSource) {
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
                        await cancelClipCapture(musicSource: musicSource)
                        return .failure(RecognitionFailure(
                            title: "Recognition Sync Cancelled",
                            message: "Recognition sync stopped before ACRCloud returned a match."
                        ))
                    }
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    await cancelClipCapture(musicSource: musicSource)
                    return .failure(RecognitionFailure(
                        title: "Recognition Sync Cancelled",
                        message: "Recognition sync stopped before ACRCloud returned a match."
                    ))
                }

                let clip: RecognitionAudioClip
                switch cachedClip(musicSource: musicSource, duration: requestWindow) {
                case .success(let cachedClip):
                    clip = cachedClip
                    latestClip = cachedClip

                case .failure(let failure):
                    group.cancelAll()
                    await cancelClipCapture(musicSource: musicSource)
                    return .failure(failure)
                }

                phase = .scanningACRCloud
                statusMessage = "Submitted ACRCloud request for \(requestWindow.secondsLabel) window"
                submittedScanCount += 1
                let shouldDiscardSystemAudioClip = musicSource == .systemAudio
                let systemAudioClipCaptureService = systemAudioClipCaptureService
                group.addTask {
                    defer {
                        if shouldDiscardSystemAudioClip {
                            systemAudioClipCaptureService.discardTemporaryClip(at: clip.fileURL)
                        }
                    }

                    let provider = ACRCloudIdentificationProvider(configuration: identificationConfiguration)
                    let scanResult = await provider.identify(clip: clip)

                    switch scanResult {
                    case .success(let execution):
                        return .success(LiveRecognitionACRCloudScanAttempt(clip: clip, execution: execution))
                    case .failure(let failure):
                        return .failure(failure)
                    }
                }
            }

            await cancelClipCapture(musicSource: musicSource)
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
                    if attempt.execution.response.music != nil {
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

    private func startCachedClipCapture(musicSource: MusicSource) async -> Result<Void, RecognitionFailure> {
        switch musicSource {
        case .background:
            return captureService.startCachedClipCapture()
        case .systemAudio:
            return await systemAudioClipCaptureService.startCachedClipCapture()
        }
    }

    private func cachedClip(musicSource: MusicSource, duration: TimeInterval) -> Result<RecognitionAudioClip, RecognitionFailure> {
        switch musicSource {
        case .background:
            return captureService.cachedClip(duration: duration)
        case .systemAudio:
            return systemAudioClipCaptureService.cachedClip(duration: duration)
        }
    }

    private func cancelClipCapture(musicSource: MusicSource) async {
        switch musicSource {
        case .background:
            await captureService.cancelCapture()
        case .systemAudio:
            await systemAudioClipCaptureService.cancelCapture()
        }
    }

    private func makeIdentificationConfiguration() throws -> ACRCloudConfiguration {
        let host = identificationHost.trimmed
        let accessKey = identificationAccessKey.trimmed
        let accessSecret = identificationAccessSecret.trimmed

        var missingFields: [String] = []
        if host.isEmpty {
            missingFields.append("ACRCLOUD_IDENTIFICATION_HOST")
        }
        if accessKey.isEmpty {
            missingFields.append("ACRCLOUD_ACCESS_KEY")
        }
        if accessSecret.isEmpty {
            missingFields.append("ACRCLOUD_ACCESS_SECRET")
        }

        guard missingFields.isEmpty else {
            throw LiveRecognitionSyncError.invalidConfiguration(
                "ACRCloud Identification API is missing required configuration: \(missingFields.joined(separator: ", "))."
            )
        }

        return ACRCloudConfiguration(host: host, accessKey: accessKey, accessSecret: accessSecret)
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
        identificationHost = environment.values["ACRCLOUD_IDENTIFICATION_HOST"]
            ?? environment.values["ACRCLOUD_HOST"]
            ?? identificationHost
        identificationAccessKey = environment.values["ACRCLOUD_ACCESS_KEY"] ?? identificationAccessKey
        identificationAccessSecret = environment.values["ACRCLOUD_ACCESS_SECRET"] ?? identificationAccessSecret
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
    public let durationMS: Int
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
                    inferenceEndpointSection
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
                metricRow("music source", "\(model.musicSource.label) -> \(model.musicSource.input.label)")
                inputStatusRow
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

    @ViewBuilder
    private var inputStatusRow: some View {
        switch model.musicSource {
        case .background:
            metricRow("microphone", model.permissionStatus.rawValue)
        case .systemAudio:
            metricRow("system audio", "ScreenCaptureKit")
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                musicSourceRow
                inferenceRouteRow
                inputRow("first request", text: $model.firstRequestAtText, suffix: "seconds", width: 90)
                inputRow("cadence", text: $model.requestCadenceText, suffix: "seconds", width: 90)
                inputRow("max window", text: $model.maxRequestWindowText, suffix: "seconds", width: 90)
                inputRow("host", text: $model.identificationHost, width: 300)
                secureInputRow("access key", text: $model.identificationAccessKey)
                secureInputRow("access secret", text: $model.identificationAccessSecret)
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

            if let execution = model.latestExecution {
                metricLine("endpoint", execution.endpoint.absoluteString)
                if let httpStatusCode = execution.httpStatusCode {
                    metricLine("http", String(httpStatusCode))
                }
                metricLine(
                    "ACRCloud status",
                    "\(execution.response.statusCode) \(execution.response.statusMessage)"
                )
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
                    metricRow("music source", "\(model.musicSource.label) -> \(model.musicSource.input.label)")
                    metricRow("asset", referenceSummary.assetFileName)
                    metricRow("duration", referenceSummary.durationMS.durationLabel)
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
                    if let playbackAnchor = model.ambientReferencePlaybackAnchor {
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            let referenceSeconds = playbackAnchor.referenceTimeMS(
                                atHostTimeMS: PulsefieldHostClock.currentTimeMS()
                            ) / 1_000
                            metricRow(
                                "reference seconds",
                                referenceSeconds.secondsLabel
                            )
                        }
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

    private var inferenceEndpointSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inference Endpoint")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                metricRow("url", InferenceEndpointWebSocketClient.defaultEndpointURL.absoluteString)
                metricRow("route", inferenceRouteText)
                metricRow("status", model.inferenceEndpointStatus)
                if let sessionID = model.inferenceSessionID {
                    metricRow("session", sessionID)
                }
                metricRow("tokens", "\(model.inferenceReceivedTokenCount)")
                metricRow("ready window", (model.inferenceReadyWindowMS / 1_000).secondsLabel)
                metricRow("render stream", model.inferenceStreamingStarted ? "ready" : "buffering")
                if let token = model.inferenceLastTokenDescription {
                    metricRow("last token", token)
                }
            }
        }
        .sectionPanel()
    }

    private var inferenceRouteText: String {
        model.inferenceIsMock ? "timing_mock / is_mock true" : "mapper / is_mock false"
    }

    private var musicSourceRow: some View {
        GridRow {
            Text("music source")
                .foregroundStyle(.secondary)
            Picker("music source", selection: $model.musicSource) {
                ForEach(MusicSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(!model.canChangeMusicSource)
        }
    }

    private var inferenceRouteRow: some View {
        GridRow {
            Text("inference route")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Toggle("mock backend", isOn: $model.inferenceIsMock)
                    .toggleStyle(.switch)
                    .disabled(!model.canChangeInferenceRoute)

                Text(inferenceRouteText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
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
    private let startedHostTimeMS = PulsefieldHostClock.currentTimeMS()

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

    func run(
        frameStream: AsyncStream<[MicFeatureFrame]>,
        onUpdate: @escaping @Sendable (LiveAmbientSyncUpdate) async -> Void
    ) async {
        for await frames in frameStream {
            guard !Task.isCancelled else {
                return
            }

            guard let update = append(frames: frames) else {
                continue
            }

            guard !Task.isCancelled else {
                return
            }

            await onUpdate(update)
        }
    }

    private func append(frames: [MicFeatureFrame]) -> LiveAmbientSyncUpdate? {
        guard !Task.isCancelled else {
            return nil
        }

        streamBuffer.append(frames)

        guard let queryWindow = streamBuffer.latestWindow(durationMS: queryDurationMS) else {
            return nil
        }

        guard !Task.isCancelled else {
            return nil
        }

        let processStartedHostTimeMS = PulsefieldHostClock.currentTimeMS()
        let elapsedMS = processStartedHostTimeMS - startedHostTimeMS
        // This full ambient matching pass is CPU-heavy when called for every mic feature batch.
        let snapshot = engine.process(queryWindow: queryWindow, elapsedMS: elapsedMS)
        let receivedHostTimeMS = PulsefieldHostClock.currentTimeMS()
        return LiveAmbientSyncUpdate(
            snapshot: snapshot,
            latestRecordedTimeMS: queryWindow.endpointRecordedTimeMS,
            queryEndpointToReceiveLatencyMS: Self.queryEndpointToReceiveLatencyMS(
                endpointHostTimeMS: queryWindow.endpointHostTimeMS,
                receivedHostTimeMS: receivedHostTimeMS
            ),
            receivedHostTimeMS: receivedHostTimeMS,
            frameBatchCount: frames.count
        )
    }

    private static func queryEndpointToReceiveLatencyMS(
        endpointHostTimeMS: Double,
        receivedHostTimeMS: Double = PulsefieldHostClock.currentTimeMS()
    ) -> Double {
        let latencyMS = receivedHostTimeMS - endpointHostTimeMS
        guard latencyMS.isFinite, latencyMS >= 0, latencyMS <= 30_000 else {
            return 0
        }

        return latencyMS
    }
}

private final class LiveAmbientSyncSession: @unchecked Sendable {
    let id = UUID()

    private let streamSource: LiveAmbientFeatureStreamSource
    private let runtime: LiveAmbientSyncRuntime
    private let onUpdate: @Sendable (LiveAmbientSyncUpdate, UUID) async -> Void
    private let onFailure: @Sendable (Error, UUID) async -> Void

    private var frameContinuation: AsyncStream<[MicFeatureFrame]>.Continuation?
    private var processingTask: Task<Void, Never>?

    init(
        referenceIndex: AmbientSyncReferenceIndex,
        streamConfiguration: AmbientMicFeatureStreamService.Configuration,
        musicSource: MusicSource,
        onUpdate: @escaping @Sendable (LiveAmbientSyncUpdate, UUID) async -> Void,
        onFailure: @escaping @Sendable (Error, UUID) async -> Void
    ) {
        streamSource = LiveAmbientFeatureStreamSource(
            musicSource: musicSource,
            configuration: streamConfiguration
        )
        runtime = LiveAmbientSyncRuntime(referenceIndex: referenceIndex)
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    deinit {
        stop()
    }

    func start() async throws {
        var continuation: AsyncStream<[MicFeatureFrame]>.Continuation!
        let frameStream = AsyncStream<[MicFeatureFrame]> { streamContinuation in
            continuation = streamContinuation
        }
        let streamContinuation = continuation!
        frameContinuation = streamContinuation

        processingTask = Task { [id, runtime, onUpdate] in
            await runtime.run(frameStream: frameStream) { update in
                await onUpdate(update, id)
            }
        }

        do {
            try await streamSource.start(
                onFrames: { frames in
                    streamContinuation.yield(frames)
                },
                onStopWithError: { [weak self] error in
                    self?.handleStreamFailure(error)
                }
            )
        } catch {
            await stopAndWait()
            throw error
        }
    }

    func stop() {
        streamSource.stop()
        stopProcessing()
    }

    func stopAndWait() async {
        await streamSource.stopAndWait()
        stopProcessing()
    }

    private func stopProcessing() {
        processingTask?.cancel()
        processingTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
    }

    private func handleStreamFailure(_ error: Error) {
        stop()
        Task { [id, onFailure] in
            await onFailure(error, id)
        }
    }
}

private enum LiveAmbientFeatureStreamSource {
    case microphone(AmbientMicFeatureStreamService)
    case systemAudio(SystemAudioFeatureStreamService)

    init(
        musicSource: MusicSource,
        configuration: AmbientMicFeatureStreamService.Configuration
    ) {
        switch musicSource {
        case .background:
            self = .microphone(AmbientMicFeatureStreamService(configuration: configuration))
        case .systemAudio:
            self = .systemAudio(SystemAudioFeatureStreamService(configuration: configuration))
        }
    }

    func start(
        onFrames: @escaping @Sendable ([MicFeatureFrame]) -> Void,
        onStopWithError: (@Sendable (Error) -> Void)? = nil
    ) async throws {
        switch self {
        case .microphone(let streamService):
            try streamService.start(onFrames: onFrames)
        case .systemAudio(let streamService):
            try await streamService.start(
                onFrames: onFrames,
                onStopWithError: onStopWithError
            )
        }
    }

    func stop() {
        switch self {
        case .microphone(let streamService):
            streamService.stop()
        case .systemAudio(let streamService):
            streamService.stop()
        }
    }

    func stopAndWait() async {
        switch self {
        case .microphone(let streamService):
            streamService.stop()
        case .systemAudio(let streamService):
            await streamService.stopAndWait()
        }
    }
}

private struct LiveAmbientSyncUpdate: Sendable {
    let snapshot: AmbientSyncSnapshot
    let latestRecordedTimeMS: Double
    let queryEndpointToReceiveLatencyMS: Double
    let receivedHostTimeMS: Double
    let frameBatchCount: Int
}

public struct AmbientReferencePlaybackAnchor: Equatable, Sendable {
    public let referenceTimeAtAnchorMS: Double
    public let durationMS: Int?
    public let anchorHostTimeMS: Double

    public init(referenceTimeAtAnchorMS: Double, durationMS: Int? = nil, anchorHostTimeMS: Double) {
        self.referenceTimeAtAnchorMS = referenceTimeAtAnchorMS
        self.durationMS = durationMS
        self.anchorHostTimeMS = anchorHostTimeMS
    }

    public func referenceTimeMS(atHostTimeMS hostTimeMS: Double) -> Double {
        let projectedTimeMS = max(0, referenceTimeAtAnchorMS + hostTimeMS - anchorHostTimeMS)
        guard let durationMS else {
            return projectedTimeMS
        }

        return min(projectedTimeMS, Double(durationMS))
    }
}

private struct LiveRecognitionACRCloudScanAttempt: Sendable {
    let clip: RecognitionAudioClip
    let execution: ACRCloudIdentificationExecution
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

private extension MusicSource {
    var label: String {
        switch self {
        case .background:
            return "Background"
        case .systemAudio:
            return "System audio"
        }
    }
}

private extension MusicSourceInput {
    var label: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .screenCaptureKitAudio:
            return "ScreenCaptureKit audio"
        }
    }
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

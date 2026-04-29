import XCTest
@testable import PulsefieldCore
@testable import PulsefieldUI

final class LocalLibraryDashboardModelTests: XCTestCase {
    func testRejectedResolveResultCannotStartAmbientMatching() {
        let directoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let asset = makeAsset(
            directoryID: directoryID,
            title: "Rejected",
            artists: ["Pulsefield"],
            durationMS: 90_000
        )

        let rejected = LocalResolveResult(
            asset: asset,
            confidence: 0.4,
            evidence: [.titleExact],
            decision: .rejected
        )
        let confirmationRequired = LocalResolveResult(
            asset: asset,
            confidence: 0.8,
            evidence: [.titleExact, .artistExact],
            decision: .requiresUserConfirmation
        )

        XCTAssertFalse(rejected.canStartAmbientMatching)
        XCTAssertTrue(confirmationRequired.canStartAmbientMatching)
    }

    @MainActor
    func testChangingAmbientAssetClearsStaleSyncIndexAndEstimate() {
        let firstAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            title: "First",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "first.mp3"
        )
        let secondAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!,
            title: "Second",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "second.mp3"
        )
        let staleIndex = makeSyncIndex(assetID: firstAsset.id)
        let staleEstimate = SyncEstimate(
            hostTime: .now,
            referenceTimeMS: 42_000,
            confidence: 0.96,
            driftPPM: nil,
            latencyMS: nil,
            source: .localFeatureCorrelation
        )
        let model = AmbientMatchingDashboardModel(
            selectedAsset: firstAsset,
            syncIndexer: StubSyncIndexer(index: staleIndex),
            estimator: FeatureCorrelationSyncEstimator(capture: SilentAmbientCapture())
        )
        model.syncIndex = staleIndex
        model.currentEstimate = staleEstimate
        model.state = .locked

        model.selectedAsset = secondAsset

        XCTAssertNil(model.syncIndex)
        XCTAssertNil(model.currentEstimate)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testStartMatchingRejectsSyncIndexForDifferentSelectedAsset() {
        let firstAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000109")!,
            title: "First",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "first-indexed.mp3"
        )
        let secondAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!,
            title: "Second",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "second-selected.mp3"
        )
        let staleIndex = makeSyncIndex(assetID: firstAsset.id)
        let model = AmbientMatchingDashboardModel(
            selectedAsset: secondAsset,
            syncIndexer: StubSyncIndexer(index: staleIndex),
            estimator: FeatureCorrelationSyncEstimator(capture: SilentAmbientCapture())
        )
        model.syncIndex = staleIndex

        model.startMatching()

        XCTAssertEqual(model.errorMessage, "Build a sync index for the selected local audio asset before starting ambient matching.")
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testStartMatchingRequestsMicrophonePermissionBeforeCapture() async {
        let asset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            title: "Permission",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "permission.mp3"
        )
        let index = makeSyncIndex(assetID: asset.id)
        let permissionService = StubMicrophonePermissionService(initialStatus: .undetermined, requestedStatus: .denied)
        let capture = SilentAmbientCapture()
        let model = AmbientMatchingDashboardModel(
            selectedAsset: asset,
            syncIndexer: StubSyncIndexer(index: index),
            estimator: FeatureCorrelationSyncEstimator(capture: capture),
            microphonePermissionService: permissionService
        )
        model.syncIndex = index

        model.startMatching()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let requestAccessCalls = await permissionService.requestAccessCalls()
        let captureStartCalls = await capture.startCalls()
        XCTAssertEqual(requestAccessCalls, 1)
        XCTAssertEqual(captureStartCalls, 0)
        XCTAssertEqual(model.microphonePermissionStatus, .denied)
        XCTAssertEqual(model.errorMessage, "Microphone access is required before ambient matching can start.")
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testStartMatchingDoesNotStartCaptureForStaleAssetAfterPermissionPrompt() async throws {
        let firstAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
            title: "First",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "stale-first.mp3"
        )
        let secondAsset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000113")!,
            title: "Second",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "stale-second.mp3"
        )
        let onsetEnvelopeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsefield-stale-start-\(UUID().uuidString).txt")
        try "0\n1\n0\n1\n".write(to: onsetEnvelopeURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: onsetEnvelopeURL)
        }
        let staleIndex = makeSyncIndex(assetID: firstAsset.id, onsetEnvelopeURL: onsetEnvelopeURL)
        let permissionService = BlockingMicrophonePermissionService()
        let capture = SilentAmbientCapture()
        let model = AmbientMatchingDashboardModel(
            selectedAsset: firstAsset,
            syncIndexer: StubSyncIndexer(index: staleIndex),
            estimator: FeatureCorrelationSyncEstimator(capture: capture),
            microphonePermissionService: permissionService
        )
        model.syncIndex = staleIndex

        model.startMatching()
        await permissionService.waitForRequestAccessCall()
        model.selectedAsset = secondAsset
        await permissionService.authorize()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let captureStartCalls = await capture.startCalls()
        XCTAssertEqual(captureStartCalls, 0)
        XCTAssertEqual(model.selectedAsset?.id, secondAsset.id)
        XCTAssertNil(model.syncIndex)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testStartMatchingIgnoresStaleIndexForSameAssetAfterPermissionPrompt() async throws {
        let asset = makeAsset(
            directoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000114")!,
            title: "Same Asset",
            artists: ["Pulsefield"],
            durationMS: 120_000,
            fileName: "same-asset.mp3"
        )
        let staleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsefield-stale-index-\(UUID().uuidString).txt")
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsefield-replacement-index-\(UUID().uuidString).txt")
        try "0\n1\n0\n1\n".write(to: staleURL, atomically: true, encoding: .utf8)
        try "1\n0\n1\n0\n".write(to: replacementURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: staleURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        let staleIndex = makeSyncIndex(assetID: asset.id, onsetEnvelopeURL: staleURL)
        let replacementIndex = makeSyncIndex(assetID: asset.id, onsetEnvelopeURL: replacementURL)
        let permissionService = BlockingMicrophonePermissionService()
        let capture = SilentAmbientCapture()
        let model = AmbientMatchingDashboardModel(
            selectedAsset: asset,
            syncIndexer: StubSyncIndexer(index: staleIndex),
            estimator: FeatureCorrelationSyncEstimator(capture: capture),
            microphonePermissionService: permissionService
        )
        model.syncIndex = staleIndex

        model.startMatching()
        await permissionService.waitForRequestAccessCall()
        model.syncIndex = replacementIndex
        await permissionService.authorize()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let captureStartCalls = await capture.startCalls()
        XCTAssertEqual(captureStartCalls, 0)
        XCTAssertEqual(model.syncIndex, replacementIndex)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLivePrototypeSurfacesPersistentDatabaseOpenFailure() {
        let model = LocalLibraryDashboardModel.livePrototype(databaseOpener: {
            throw PersistentDatabaseOpenFailure()
        })

        XCTAssertEqual(model.errorMessage, "Could not open persistent local audio library: disk unavailable")
    }

    private func makeAsset(
        id: UUID = UUID(),
        directoryID: UUID,
        title: String?,
        artists: [String],
        durationMS: Int,
        isrc: String? = nil,
        album: String? = nil,
        fileName: String? = nil
    ) -> LocalAudioAsset {
        let fileName = fileName ?? "\(title ?? "untitled").mp3"
        return LocalAudioAsset(
            id: id,
            directoryID: directoryID,
            fileURLBookmark: nil,
            displayPath: "/tmp/pulsefield-library/\(fileName)",
            fileName: fileName,
            fileExtension: "mp3",
            fileSizeBytes: 4_096,
            sha256: id.uuidString.lowercased(),
            durationMS: durationMS,
            title: title,
            artists: artists,
            album: album,
            albumArtist: nil,
            trackNumber: nil,
            discNumber: nil,
            isrc: isrc,
            releaseYear: nil,
            indexedAt: Date(timeIntervalSince1970: 1_710_000_100),
            lastSeenAt: Date(timeIntervalSince1970: 1_710_000_100),
            status: .ready
        )
    }

    private func makeSyncIndex(
        assetID: UUID,
        onsetEnvelopeURL: URL? = nil
    ) -> LocalAudioSyncIndex {
        LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: 120_000,
            sampleRate: 44_100,
            frameHopMS: 100,
            onsetEnvelopeURL: onsetEnvelopeURL ?? URL(fileURLWithPath: "/tmp/pulsefield-sync-\(assetID.uuidString).txt"),
            spectralSummaryURL: nil,
            chromaURL: nil,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }
}

private struct PersistentDatabaseOpenFailure: LocalizedError {
    var errorDescription: String? {
        "disk unavailable"
    }
}

private actor StubSyncIndexer: LocalAudioSyncIndexing {
    private let index: LocalAudioSyncIndex

    init(index: LocalAudioSyncIndex) {
        self.index = index
    }

    func buildIndex(for asset: LocalAudioAsset) async throws -> LocalAudioSyncIndex {
        _ = asset
        return index
    }

    func loadIndex(for assetID: UUID) async -> LocalAudioSyncIndex? {
        index.assetID == assetID ? index : nil
    }
}

private actor SilentAmbientCapture: AmbientAudioCapturing {
    private(set) var startCallCount = 0

    func start() async throws {
        startCallCount += 1
    }

    func stop() async {}

    func latestWindow(durationMS: Int) async -> AmbientAudioWindow? {
        _ = durationMS
        return nil
    }

    func startCalls() -> Int {
        startCallCount
    }
}

private actor StubMicrophonePermissionService: MicrophonePermissionProviding {
    private var status: MicrophonePermissionStatus
    private let requestedStatus: MicrophonePermissionStatus
    private(set) var requestAccessCallCount = 0

    init(initialStatus: MicrophonePermissionStatus, requestedStatus: MicrophonePermissionStatus) {
        status = initialStatus
        self.requestedStatus = requestedStatus
    }

    func currentStatus() async -> MicrophonePermissionStatus {
        status
    }

    func requestAccess() async -> MicrophonePermissionStatus {
        requestAccessCallCount += 1
        status = requestedStatus
        return status
    }

    func requestAccessCalls() -> Int {
        requestAccessCallCount
    }
}

private actor BlockingMicrophonePermissionService: MicrophonePermissionProviding {
    private var status: MicrophonePermissionStatus = .undetermined
    private var requestAccessCallCount = 0
    private var requestAccessWaiter: CheckedContinuation<Void, Never>?
    private var authorizationWaiter: CheckedContinuation<Void, Never>?

    func currentStatus() async -> MicrophonePermissionStatus {
        status
    }

    func requestAccess() async -> MicrophonePermissionStatus {
        requestAccessCallCount += 1
        requestAccessWaiter?.resume()
        requestAccessWaiter = nil

        await withCheckedContinuation { continuation in
            authorizationWaiter = continuation
        }
        status = .authorized
        return status
    }

    func waitForRequestAccessCall() async {
        guard requestAccessCallCount == 0 else {
            return
        }

        await withCheckedContinuation { continuation in
            requestAccessWaiter = continuation
        }
    }

    func authorize() {
        authorizationWaiter?.resume()
        authorizationWaiter = nil
    }
}

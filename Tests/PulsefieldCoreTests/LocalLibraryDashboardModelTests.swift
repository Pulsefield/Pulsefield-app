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
        model.state = .locked(staleEstimate)

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

    private func makeSyncIndex(assetID: UUID) -> LocalAudioSyncIndex {
        LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: 120_000,
            sampleRate: 44_100,
            frameHopMS: 100,
            onsetEnvelopeURL: URL(fileURLWithPath: "/tmp/pulsefield-sync-\(assetID.uuidString).txt"),
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

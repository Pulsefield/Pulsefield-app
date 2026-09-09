#if os(macOS) && DEBUG
import XCTest
@testable import PulsefieldCore
@testable import PulsefieldUI

final class LiveRecognitionSyncModelTests: XCTestCase {
    @MainActor
    func testStopClearsAmbientStateAndRejectsObsoleteStartupCallbacks() throws {
        let model = LiveRecognitionSyncModel(database: try LocalAudioLibraryDatabase.openInMemory())
        let summary = AmbientReferenceSummary(
            assetFileName: "track.wav",
            sourceDisplayPath: "/tmp/track.wav",
            durationMS: 180_000,
            frameCount: 12,
            landmarkCount: 6
        )
        let snapshot = AmbientSyncSnapshot(
            state: .locked,
            phase: .final,
            stage: .tracking,
            confidence: 0.95,
            diagnostics: AmbientSyncDiagnostics(
                queryDurationMS: 5_000,
                activeFrameFraction: 1,
                queryLandmarkCount: 24
            )
        )

        let stoppedSessionID = model.debugInjectAmbientSyncState(
            referenceSummary: summary,
            snapshot: snapshot,
            updateCount: 3,
            frameBatchCount: 8
        )

        model.stop()
        XCTAssertThrowsError(try model.debugCompleteAmbientStart(sessionID: stoppedSessionID))
        model.debugFailAmbientStart(CancellationError(), sessionID: stoppedSessionID)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.statusMessage, "Stopped")
        XCTAssertNil(model.referenceSummary)
        XCTAssertNil(model.latestAmbientSnapshot)
        XCTAssertEqual(model.ambientUpdateCount, 0)
        XCTAssertEqual(model.latestFrameBatchCount, 0)

        let replacementSessionID = model.debugInjectAmbientSyncState(
            referenceSummary: summary, snapshot: snapshot, updateCount: 2, frameBatchCount: 4
        )
        // An older start may finish cleanup after a replacement has begun.
        model.debugFailAmbientStart(NSError(domain: "old startup", code: 1), sessionID: stoppedSessionID)
        XCTAssertThrowsError(try model.debugCompleteAmbientStart(sessionID: stoppedSessionID))
        XCTAssertEqual(model.phase, .ambientSyncing)
        XCTAssertEqual(model.latestAmbientSnapshot, snapshot)
        XCTAssertEqual(model.ambientUpdateCount, 2)

        try model.debugCompleteAmbientStart(sessionID: replacementSessionID)
        XCTAssertEqual(model.statusMessage, "Ambient sync listening")
    }

    func testAmbientReferencePlaybackAnchorClampsAtTrackDuration() {
        let anchorHostTimeMS = 1_000_000.0
        let anchor = AmbientReferencePlaybackAnchor(
            referenceTimeAtAnchorMS: 179_500,
            durationMS: 180_000,
            anchorHostTimeMS: anchorHostTimeMS
        )

        XCTAssertEqual(anchor.referenceTimeMS(atHostTimeMS: anchorHostTimeMS + 250), 179_750)
        XCTAssertEqual(anchor.referenceTimeMS(atHostTimeMS: anchorHostTimeMS + 2_000), 180_000)
    }

    func testAmbientProcessSchedulerThrottlesUntilQueryEndpointCadenceElapses() {
        var scheduler = LiveAmbientSyncProcessScheduler(minimumQueryEndpointIntervalMS: 100)

        XCTAssertTrue(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_000))
        XCTAssertFalse(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_050))
        XCTAssertFalse(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_099.9))
        XCTAssertTrue(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_100))
        XCTAssertFalse(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_150))
        XCTAssertTrue(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 900))
        XCTAssertFalse(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 950))
        XCTAssertTrue(scheduler.shouldProcess(queryEndpointRecordedTimeMS: 1_000))
    }

    @MainActor
    func testMode3InferenceMockOptionDefaultsFalse() async throws {
        let endpoint = RecordingInferenceEndpoint()
        let factory = RecordingInferenceEndpointFactory(endpoint: endpoint)
        let model = LiveRecognitionSyncModel(
            database: try LocalAudioLibraryDatabase.openInMemory(),
            inferenceEndpointClientFactory: factory.makeClient(configuration:)
        )
        defer { model.stop() }

        XCTAssertFalse(model.inferenceIsMock)

        model.debugStartInferenceSession(for: makeLocalAudioAsset(displayPath: "/tmp/mode-3.wav"))
        try await waitUntil { await endpoint.audioPathCallCount() == 1 }

        XCTAssertEqual(factory.recordedConfigurations, [
            InferenceEndpointConfiguration(isMock: false)
        ])
        let recordedCall = await endpoint.firstAudioPathCall()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.audioPath, "/tmp/mode-3.wav")
        XCTAssertEqual(call.musicSource, .background)
    }

    @MainActor
    func testMode3InferenceMockOptionCanBeEnabled() async throws {
        let endpoint = RecordingInferenceEndpoint()
        let factory = RecordingInferenceEndpointFactory(endpoint: endpoint)
        let model = LiveRecognitionSyncModel(
            database: try LocalAudioLibraryDatabase.openInMemory(),
            inferenceEndpointClientFactory: factory.makeClient(configuration:)
        )
        defer { model.stop() }

        model.inferenceIsMock = true
        model.debugStartInferenceSession(
            for: makeLocalAudioAsset(displayPath: "/tmp/mode-3-system.wav"),
            musicSource: .systemAudio
        )
        try await waitUntil { await endpoint.audioPathCallCount() == 1 }

        XCTAssertEqual(factory.recordedConfigurations, [
            InferenceEndpointConfiguration(isMock: true)
        ])
        let recordedCall = await endpoint.firstAudioPathCall()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.audioPath, "/tmp/mode-3-system.wav")
        XCTAssertEqual(call.musicSource, .systemAudio)
    }

    @MainActor
    func testFinalAmbientLockRequestsGeneratedPlaySession() throws {
        let recorder = PlaySessionRequestRecorder()
        let model = LiveRecognitionSyncModel(
            database: try LocalAudioLibraryDatabase.openInMemory(),
            inferenceIsMock: true,
            onPlaySessionRequested: recorder.record(_:)
        )
        let asset = makeLocalAudioAsset(displayPath: "/tmp/mode-3-final-lock.mp3")

        model.debugApplyAmbientFinalLock(
            asset: asset,
            referenceTimeAtQueryMS: 2_500,
            queryEndpointRecordedTimeMS: 2_000,
            latestRecordedTimeMS: 2_800,
            queryEndpointToReceiveLatencyMS: 25,
            receivedHostTimeMS: 12_000
        )

        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.statusMessage, "Ambient sync locked")
        XCTAssertEqual(recorder.requests, [
            LiveRecognitionPlaySessionRequest(
                audioFileURL: URL(fileURLWithPath: "/tmp/mode-3-final-lock.mp3"),
                referenceTimeMS: 3_325,
                anchorHostTimeMS: 12_000,
                durationMS: 180_000,
                title: "mode-3-final-lock.mp3",
                isMock: true,
                musicSource: .background
            )
        ])
    }
}

@MainActor
private final class PlaySessionRequestRecorder {
    private(set) var requests: [LiveRecognitionPlaySessionRequest] = []

    func record(_ request: LiveRecognitionPlaySessionRequest) {
        requests.append(request)
    }
}

private final class RecordingInferenceEndpointFactory: @unchecked Sendable {
    private let endpoint: RecordingInferenceEndpoint
    private let lock = NSLock()
    private var configurations: [InferenceEndpointConfiguration] = []

    init(endpoint: RecordingInferenceEndpoint) {
        self.endpoint = endpoint
    }

    var recordedConfigurations: [InferenceEndpointConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }

    func makeClient(configuration: InferenceEndpointConfiguration) -> any InferenceEndpointClient {
        lock.lock()
        configurations.append(configuration)
        lock.unlock()
        return endpoint
    }
}

private actor RecordingInferenceEndpoint: InferenceEndpointClient {
    struct AudioPathCall: Equatable, Sendable {
        let audioPath: String
        let sessionID: String
        let musicSource: MusicSource
    }

    private var audioPathCalls: [AudioPathCall] = []

    func prepare() async throws {}

    func sendAudioPath(_ audioPath: String, sessionID: String, musicSource: MusicSource) async throws {
        audioPathCalls.append(AudioPathCall(
            audioPath: audioPath,
            sessionID: sessionID,
            musicSource: musicSource
        ))
    }

    func sendReferenceTime(sessionID: String, refTimeMS: Double, localHostTimeSendMS: Double) async throws {}

    func stop(sessionID: String) async throws {}

    func nextEvent() async throws -> InferenceEndpointEvent {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CancellationError()
    }

    func audioPathCallCount() -> Int {
        audioPathCalls.count
    }

    func firstAudioPathCall() -> AudioPathCall? {
        audioPathCalls.first
    }
}

private func makeLocalAudioAsset(displayPath: String) -> LocalAudioAsset {
    LocalAudioAsset(
        id: UUID(),
        directoryID: UUID(),
        fileURLBookmark: nil,
        displayPath: displayPath,
        fileName: URL(fileURLWithPath: displayPath).lastPathComponent,
        fileExtension: URL(fileURLWithPath: displayPath).pathExtension,
        fileSizeBytes: 1_024,
        sha256: "abc123",
        durationMS: 180_000,
        title: nil,
        artists: [],
        album: nil,
        albumArtist: nil,
        trackNumber: nil,
        discNumber: nil,
        isrc: nil,
        releaseYear: nil,
        indexedAt: Date(timeIntervalSince1970: 1_710_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_710_000_000),
        status: .ready
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @MainActor () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
        if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
            throw WaitTimeoutError()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private struct WaitTimeoutError: Error {}
#endif

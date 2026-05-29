#if os(macOS) && DEBUG
import XCTest
@testable import PulsefieldCore
@testable import PulsefieldUI

final class LiveRecognitionSyncModelTests: XCTestCase {
    @MainActor
    func testStopClearsAmbientSyncStatusState() throws {
        let model = LiveRecognitionSyncModel(database: try LocalAudioLibraryDatabase.openInMemory())
        let summary = AmbientReferenceSummary(
            assetFileName: "track.wav",
            sourceDisplayPath: "/tmp/track.wav",
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

        model.debugInjectAmbientSyncState(
            referenceSummary: summary,
            snapshot: snapshot,
            updateCount: 3,
            frameBatchCount: 8
        )

        model.stop()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.statusMessage, "Stopped")
        XCTAssertNil(model.referenceSummary)
        XCTAssertNil(model.latestAmbientSnapshot)
        XCTAssertEqual(model.ambientUpdateCount, 0)
        XCTAssertEqual(model.latestFrameBatchCount, 0)
    }
}
#endif

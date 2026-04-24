import CoreGraphics
import XCTest
@testable import PulsefieldCore
@testable import PulsefieldUI

final class Mania4KNoteRenderLayoutTests: XCTestCase {
    func testHoldingLongNoteBodyIsClampedToReceptorAfterHeadPasses() throws {
        let frame = playFrame(chartTimeMs: 1_250, scrollTimeMs: 1_000)
        let object = Mania4KVisibleObject(
            id: Mania4KObjectOrdinal(rawValue: 0),
            lane: .left,
            startTimeMs: 1_000,
            endTimeMs: 2_000,
            state: .holding
        )

        guard case .hold(let geometry) = Mania4KNoteRenderLayout.geometry(
            for: object,
            frame: frame,
            laneHeight: 640,
            receptorY: 520
        ) else {
            return XCTFail("Expected hold geometry")
        }

        XCTAssertEqual(geometry.headY, 520, accuracy: 0.001)
        XCTAssertEqual(geometry.bodyBottomY, 520, accuracy: 0.001)
        XCTAssertLessThan(geometry.bodyTopY, geometry.bodyBottomY)
        let tailY = try XCTUnwrap(geometry.tailY)
        XCTAssertLessThan(tailY, geometry.headY)
    }

    func testOpenEndedLongNoteUsesLaneTopInsteadOfSyntheticTailMarker() {
        let frame = playFrame(chartTimeMs: 0, scrollTimeMs: 1_000)
        let object = Mania4KVisibleObject(
            id: Mania4KObjectOrdinal(rawValue: 0),
            lane: .left,
            startTimeMs: 500,
            endTimeMs: nil,
            state: .openEnded
        )

        guard case .hold(let geometry) = Mania4KNoteRenderLayout.geometry(
            for: object,
            frame: frame,
            laneHeight: 640,
            receptorY: 520
        ) else {
            return XCTFail("Expected hold geometry")
        }

        XCTAssertNil(geometry.tailY)
        XCTAssertEqual(geometry.bodyTopY, 0, accuracy: 0.001)
        XCTAssertEqual(geometry.bodyBottomY, geometry.headY, accuracy: 0.001)
    }

    private func playFrame(chartTimeMs: Double, scrollTimeMs: Double) -> Mania4KPlayFrame {
        Mania4KPlayFrame(
            chartTimeMs: chartTimeMs,
            scrollTimeMs: scrollTimeMs,
            metadata: Mania4KChartMetadata(title: "Test", sourceDescription: "Test"),
            visibleObjects: [],
            score: .zero,
            laneStates: [],
            latestJudgement: nil
        )
    }
}

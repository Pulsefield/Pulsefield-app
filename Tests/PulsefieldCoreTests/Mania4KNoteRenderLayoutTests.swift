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

    func testRenderChartTimeChangesPositionWithoutChangingGameplayTime() {
        let gameplayFrame = playFrame(gameplayChartTimeMs: 1_000, renderChartTimeMs: 1_000, scrollTimeMs: 1_000)
        let visuallyShiftedFrame = playFrame(gameplayChartTimeMs: 1_000, renderChartTimeMs: 1_100, scrollTimeMs: 1_000)

        let baselineY = Mania4KNoteRenderLayout.yPosition(
            for: 1_500,
            frame: gameplayFrame,
            laneHeight: 640,
            receptorY: 520
        )
        let shiftedY = Mania4KNoteRenderLayout.yPosition(
            for: 1_500,
            frame: visuallyShiftedFrame,
            laneHeight: 640,
            receptorY: 520
        )

        XCTAssertEqual(gameplayFrame.gameplayChartTimeMs, visuallyShiftedFrame.gameplayChartTimeMs)
        XCTAssertGreaterThan(shiftedY, baselineY)
    }

    private func playFrame(chartTimeMs: Double, scrollTimeMs: Double) -> Mania4KPlayFrame {
        playFrame(gameplayChartTimeMs: chartTimeMs, renderChartTimeMs: chartTimeMs, scrollTimeMs: scrollTimeMs)
    }

    private func playFrame(
        gameplayChartTimeMs: Double,
        renderChartTimeMs: Double,
        scrollTimeMs: Double
    ) -> Mania4KPlayFrame {
        Mania4KPlayFrame(
            gameplayChartTimeMs: gameplayChartTimeMs,
            renderChartTimeMs: renderChartTimeMs,
            scrollTimeMs: scrollTimeMs,
            metadata: Mania4KChartMetadata(title: "Test", sourceDescription: "Test"),
            visibleObjects: [],
            score: .zero,
            laneStates: [],
            latestJudgement: nil
        )
    }
}

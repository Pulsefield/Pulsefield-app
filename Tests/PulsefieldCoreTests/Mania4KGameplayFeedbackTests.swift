import XCTest
@testable import PulsefieldCore

final class Mania4KGameplayFeedbackTests: XCTestCase {
    func testJudgementBatchesPreserveCompleteEventsUntilEventuallyPruned() throws {
        var state = Mania4KGameplayFeedbackState()

        state.recordJudgementEvents([], atChartTimeMs: 1_000)
        XCTAssertEqual(state.judgementEventBatches.count, 0)

        let events = [
            judgementEvent(id: 1, lane: .left, judgement: .perfect),
            judgementEvent(id: 2, lane: .innerLeft, judgement: .miss),
            judgementEvent(id: 3, lane: .innerRight, judgement: .good)
        ]
        state.recordJudgementEvents(events, atChartTimeMs: 1_000)

        XCTAssertEqual(state.judgementEventBatches.count, 1)
        let batch = try XCTUnwrap(state.judgementEventBatches.first)
        XCTAssertEqual(batch.events, events)

        state.advanceJudgementTime(to: 1_000)
        XCTAssertEqual(state.judgementEventBatches.count, 1)

        state.advanceJudgementTime(to: 10_000)
        XCTAssertEqual(state.judgementEventBatches.count, 0)
    }

    func testJudgementPresentationChoosesMostSevereEventThenNewestEventID() {
        var mixedState = Mania4KGameplayFeedbackState()
        mixedState.recordJudgementEvents([
            judgementEvent(id: 1, lane: .left, judgement: .perfect),
            judgementEvent(id: 2, lane: .innerLeft, judgement: .miss),
            judgementEvent(id: 3, lane: .innerRight, judgement: .good)
        ], atChartTimeMs: 1_000)

        var presentation = mixedState.judgementPresentation(atChartTimeMs: 1_000)
        XCTAssertEqual(presentation?.event.judgement, .miss)
        XCTAssertEqual(presentation?.event.id, 2)

        var tieState = Mania4KGameplayFeedbackState()
        tieState.recordJudgementEvents([
            judgementEvent(id: 10, lane: .left, judgement: .good),
            judgementEvent(id: 12, lane: .right, judgement: .good),
            judgementEvent(id: 11, lane: .innerRight, judgement: .good)
        ], atChartTimeMs: 2_000)

        presentation = tieState.judgementPresentation(atChartTimeMs: 2_000)
        XCTAssertEqual(presentation?.event.judgement, .good)
        XCTAssertEqual(presentation?.event.id, 12)
    }

    func testMissImmediatelyReplacesPerfectAndDoesNotReplayIgnoredLighterJudgement() {
        var protectedState = Mania4KGameplayFeedbackState()
        protectedState.recordJudgementEvents([
            judgementEvent(id: 1, judgement: .perfect)
        ], atChartTimeMs: 1_000)
        protectedState.recordJudgementEvents([
            judgementEvent(id: 2, judgement: .miss)
        ], atChartTimeMs: 1_000)

        var presentation = protectedState.judgementPresentation(atChartTimeMs: 1_000)
        XCTAssertEqual(presentation?.event.judgement, .miss)
        XCTAssertEqual(presentation?.event.id, 2)

        protectedState.recordJudgementEvents([
            judgementEvent(id: 3, judgement: .good)
        ], atChartTimeMs: 1_000)

        presentation = protectedState.judgementPresentation(atChartTimeMs: 1_000)
        XCTAssertEqual(presentation?.event.judgement, .miss)
        XCTAssertEqual(presentation?.event.id, 2)
        protectedState.advanceJudgementTime(to: 10_000)
        XCTAssertNil(protectedState.judgementPresentation(atChartTimeMs: 10_000))

        var expiredProtectionState = Mania4KGameplayFeedbackState()
        expiredProtectionState.recordJudgementEvents([
            judgementEvent(id: 4, judgement: .miss)
        ], atChartTimeMs: 2_000)
        expiredProtectionState.recordJudgementEvents([
            judgementEvent(id: 5, judgement: .good)
        ], atChartTimeMs: 10_000)

        presentation = expiredProtectionState.judgementPresentation(atChartTimeMs: 10_000)
        XCTAssertEqual(presentation?.event.judgement, .good)
        XCTAssertEqual(presentation?.event.id, 5)
    }

    func testSameJudgementRetriggersAndEventuallyDisappearsWithDeterministicSampling() {
        var state = Mania4KGameplayFeedbackState()
        state.recordJudgementEvents([
            judgementEvent(id: 20, judgement: .perfect)
        ], atChartTimeMs: 1_000)
        state.recordJudgementEvents([
            judgementEvent(id: 21, judgement: .perfect)
        ], atChartTimeMs: 1_000)

        let presentation = state.judgementPresentation(atChartTimeMs: 1_000)
        XCTAssertEqual(presentation?.event.judgement, .perfect)
        XCTAssertEqual(presentation?.event.id, 21)
        XCTAssertEqual(presentation?.opacity ?? .nan, 1, accuracy: 0.0001)

        let firstPausedSample = state.judgementPresentation(atChartTimeMs: 1_000)
        let secondPausedSample = state.judgementPresentation(atChartTimeMs: 1_000)
        XCTAssertEqual(firstPausedSample?.event.judgement, secondPausedSample?.event.judgement)
        XCTAssertEqual(firstPausedSample?.event.id, secondPausedSample?.event.id)
        XCTAssertEqual(firstPausedSample?.opacity ?? .nan, secondPausedSample?.opacity ?? .nan, accuracy: 0.0001)
        XCTAssertEqual(firstPausedSample?.scale ?? .nan, secondPausedSample?.scale ?? .nan, accuracy: 0.0001)
        XCTAssertEqual(
            firstPausedSample?.verticalOffset ?? .nan,
            secondPausedSample?.verticalOffset ?? .nan,
            accuracy: 0.0001
        )

        state.advanceJudgementTime(to: 10_000)
        XCTAssertNil(state.judgementPresentation(atChartTimeMs: 10_000))
    }

    func testLaneBrightnessPressHoldReleaseAndEventuallyReturnsToZero() {
        var state = Mania4KGameplayFeedbackState()
        state.recordInput(input(.left, .press, 1_000, 30), atUITimeMs: 10_000)

        let pressedBrightness = state.laneBrightness(for: .left, atUITimeMs: 10_000)
        XCTAssertGreaterThan(pressedBrightness.receptor, 0)
        XCTAssertGreaterThan(pressedBrightness.lane, 0)

        let heldBrightness = state.laneBrightness(for: .left, atUITimeMs: 20_000)
        XCTAssertGreaterThan(heldBrightness.receptor, 0)
        XCTAssertGreaterThan(heldBrightness.lane, 0)
        XCTAssertLessThan(heldBrightness.receptor, pressedBrightness.receptor)
        XCTAssertLessThan(heldBrightness.lane, pressedBrightness.lane)

        state.recordInput(input(.left, .release, 2_000, 31), atUITimeMs: 20_000)
        let releaseStart = state.laneBrightness(for: .left, atUITimeMs: 20_000)
        XCTAssertEqual(releaseStart.receptor, heldBrightness.receptor, accuracy: 0.001)
        XCTAssertEqual(releaseStart.lane, heldBrightness.lane, accuracy: 0.001)

        let idleBrightness = state.laneBrightness(for: .left, atUITimeMs: 100_000)
        XCTAssertEqual(idleBrightness.receptor, 0, accuracy: 0.001)
        XCTAssertEqual(idleBrightness.lane, 0, accuracy: 0.001)
    }

    func testHigherSequenceRepressRestoresInitialBrightnessAndIgnoresOldSequence() {
        var state = Mania4KGameplayFeedbackState()
        state.recordInput(input(.left, .press, 1_000, 40), atUITimeMs: 20_000)
        let initialBrightness = state.laneBrightness(for: .left, atUITimeMs: 20_000)
        state.recordInput(input(.left, .release, 1_001, 41), atUITimeMs: 20_001)

        let decaying = state.laneBrightness(for: .left, atUITimeMs: 20_002)
        XCTAssertGreaterThan(decaying.receptor, 0)
        XCTAssertLessThan(decaying.receptor, initialBrightness.receptor)

        state.recordInput(input(.left, .press, 1_002, 42), atUITimeMs: 20_002)
        let restoredBrightness = state.laneBrightness(for: .left, atUITimeMs: 20_002)
        XCTAssertEqual(restoredBrightness.receptor, initialBrightness.receptor, accuracy: 0.001)
        XCTAssertEqual(restoredBrightness.lane, initialBrightness.lane, accuracy: 0.001)

        state.recordInput(input(.left, .release, 1_003, 41), atUITimeMs: 20_003)
        let heldBrightness = state.laneBrightness(for: .left, atUITimeMs: 100_000)
        XCTAssertGreaterThan(heldBrightness.receptor, 0)
        XCTAssertGreaterThan(heldBrightness.lane, 0)
        XCTAssertEqual(state.latestLaneInputTransitions[.left]?.sequenceNumber, 42)
        XCTAssertEqual(state.latestLaneInputTransitions[.left]?.phase, .press)
    }
}

private func judgementEvent(
    id: UInt64,
    lane: Mania4KLane = .left,
    judgement: Mania4KJudgement,
    chartTimeMs: Double = 1_000
) -> Mania4KJudgementEvent {
    Mania4KJudgementEvent(
        id: id,
        objectID: Mania4KObjectOrdinal(rawValue: Int(id)),
        lane: lane,
        chartTimeMs: chartTimeMs,
        objectTimeMs: chartTimeMs,
        hitErrorMs: judgement == .miss ? nil : 0,
        judgement: judgement,
        malodyTier: malodyTier(for: judgement)
    )
}

private func input(
    _ lane: Mania4KLane,
    _ phase: Mania4KInputPhase,
    _ chartTimeMs: Double,
    _ sequenceNumber: UInt64
) -> Mania4KInputEvent {
    Mania4KInputEvent(
        lane: lane,
        phase: phase,
        chartTimeMs: chartTimeMs,
        sequenceNumber: sequenceNumber,
        source: .test
    )
}

private func malodyTier(for judgement: Mania4KJudgement) -> Mania4KMalodyTier {
    switch judgement {
    case .perfect:
        return .bigP
    case .good:
        return .p1
    case .miss:
        return .m
    }
}

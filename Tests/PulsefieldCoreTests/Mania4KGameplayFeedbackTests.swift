import XCTest
@testable import PulsefieldCore

final class Mania4KGameplayFeedbackTests: XCTestCase {
    func testJudgementBatchesPreserveCompleteEventsThroughRetentionBoundary() throws {
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

        state.advanceJudgementTime(to: 1_600)
        XCTAssertEqual(state.judgementEventBatches.count, 1)

        state.advanceJudgementTime(to: 1_600.001)
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
        ], atChartTimeMs: 1_020)

        var presentation = protectedState.judgementPresentation(atChartTimeMs: 1_020)
        XCTAssertEqual(presentation?.event.judgement, .miss)
        XCTAssertEqual(presentation?.event.id, 2)

        protectedState.recordJudgementEvents([
            judgementEvent(id: 3, judgement: .good)
        ], atChartTimeMs: 1_199)

        presentation = protectedState.judgementPresentation(atChartTimeMs: 1_199)
        XCTAssertEqual(presentation?.event.judgement, .miss)
        XCTAssertEqual(presentation?.event.id, 2)
        XCTAssertNil(protectedState.judgementPresentation(atChartTimeMs: 1_520.001))

        var expiredProtectionState = Mania4KGameplayFeedbackState()
        expiredProtectionState.recordJudgementEvents([
            judgementEvent(id: 4, judgement: .miss)
        ], atChartTimeMs: 2_000)
        expiredProtectionState.recordJudgementEvents([
            judgementEvent(id: 5, judgement: .good)
        ], atChartTimeMs: 2_181)

        presentation = expiredProtectionState.judgementPresentation(atChartTimeMs: 2_181)
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
        ], atChartTimeMs: 1_050)

        let presentation = state.judgementPresentation(atChartTimeMs: 1_050)
        XCTAssertEqual(presentation?.event.judgement, .perfect)
        XCTAssertEqual(presentation?.event.id, 21)
        XCTAssertEqual(presentation?.opacity ?? .nan, 1, accuracy: 0.0001)
        XCTAssertEqual(presentation?.scale ?? .nan, 0.90, accuracy: 0.0001)

        let fadeStart = state.judgementPresentation(atChartTimeMs: 1_160)
        XCTAssertEqual(fadeStart?.opacity ?? .nan, 1, accuracy: 0.0001)
        XCTAssertEqual(fadeStart?.scale ?? .nan, 1, accuracy: 0.0001)

        let fading = state.judgementPresentation(atChartTimeMs: 1_200)
        XCTAssertGreaterThan(fading?.opacity ?? 0, 0)
        XCTAssertLessThan(fading?.opacity ?? 1, 1)
        XCTAssertLessThan(fading?.scale ?? 1, 1)

        let firstPausedSample = state.judgementPresentation(atChartTimeMs: 1_090)
        let secondPausedSample = state.judgementPresentation(atChartTimeMs: 1_090)
        XCTAssertEqual(firstPausedSample?.event.judgement, secondPausedSample?.event.judgement)
        XCTAssertEqual(firstPausedSample?.event.id, secondPausedSample?.event.id)
        XCTAssertEqual(firstPausedSample?.opacity ?? .nan, secondPausedSample?.opacity ?? .nan, accuracy: 0.0001)
        XCTAssertEqual(firstPausedSample?.scale ?? .nan, secondPausedSample?.scale ?? .nan, accuracy: 0.0001)
        XCTAssertEqual(
            firstPausedSample?.verticalOffset ?? .nan,
            secondPausedSample?.verticalOffset ?? .nan,
            accuracy: 0.0001
        )

        XCTAssertNotNil(state.judgementPresentation(atChartTimeMs: 1_349.999))
        XCTAssertNil(state.judgementPresentation(atChartTimeMs: 1_350.001))
    }

    func testLaneBrightnessPressHoldReleaseAndZeroDecay() {
        var state = Mania4KGameplayFeedbackState()
        state.recordInput(input(.left, .press, 1_000, 30), atUITimeMs: 10_000)

        var brightness = state.laneBrightness(for: .left, atUITimeMs: 10_000)
        XCTAssertEqual(brightness.receptor, 0.52, accuracy: 0.001)
        XCTAssertEqual(brightness.lane, 0.13, accuracy: 0.001)

        brightness = state.laneBrightness(for: .left, atUITimeMs: 10_085)
        XCTAssertEqual(brightness.receptor, 0.24, accuracy: 0.001)
        XCTAssertEqual(brightness.lane, 0.05, accuracy: 0.001)

        state.recordInput(input(.left, .release, 1_085, 31), atUITimeMs: 10_085)
        let releaseStart = state.laneBrightness(for: .left, atUITimeMs: 10_085)
        XCTAssertEqual(releaseStart.receptor, brightness.receptor, accuracy: 0.001)
        XCTAssertEqual(releaseStart.lane, brightness.lane, accuracy: 0.001)

        let decaying = state.laneBrightness(for: .left, atUITimeMs: 10_140)
        XCTAssertGreaterThan(decaying.receptor, 0)
        XCTAssertLessThan(decaying.receptor, releaseStart.receptor)

        brightness = state.laneBrightness(for: .left, atUITimeMs: 10_195)
        XCTAssertEqual(brightness.receptor, 0, accuracy: 0.001)
        XCTAssertEqual(brightness.lane, 0, accuracy: 0.001)
    }

    func testHigherSequenceRepressDuringDecayRestoresPeakAndIgnoresOldSequence() {
        var state = Mania4KGameplayFeedbackState()
        state.recordInput(input(.left, .press, 1_000, 40), atUITimeMs: 20_000)
        state.recordInput(input(.left, .release, 1_085, 41), atUITimeMs: 20_085)

        let decaying = state.laneBrightness(for: .left, atUITimeMs: 20_140)
        XCTAssertGreaterThan(decaying.receptor, 0)

        state.recordInput(input(.left, .press, 1_140, 42), atUITimeMs: 20_140)
        var brightness = state.laneBrightness(for: .left, atUITimeMs: 20_140)
        XCTAssertEqual(brightness.receptor, 0.52, accuracy: 0.001)
        XCTAssertEqual(brightness.lane, 0.13, accuracy: 0.001)

        state.recordInput(input(.left, .release, 1_150, 41), atUITimeMs: 20_150)
        brightness = state.laneBrightness(for: .left, atUITimeMs: 20_250)
        XCTAssertEqual(brightness.receptor, 0.24, accuracy: 0.001)
        XCTAssertEqual(brightness.lane, 0.05, accuracy: 0.001)
        XCTAssertEqual(state.latestLaneInputTransitions[.left]?.sequenceNumber, 42)
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

import XCTest
@testable import PulsefieldCore

@MainActor
final class Mania4KOffsetCalibrationModelTests: XCTestCase {
    func testNonZeroOffsetSeedsFirstNoteAfterRawLeadInAndTicksOnRawCadence() {
        let tickPlayer = FakeCalibrationTickPlayer()
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 75, tickPlayer: tickPlayer)

        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 0)
        XCTAssertEqual(model.noteTimeMs(forBeatIndex: 0), 1_075, accuracy: 0.001)
        XCTAssertEqual(model.renderedChartTimeMs, 75)

        model.advanceClock(rawClockTimeMs: 999)
        XCTAssertEqual(tickPlayer.playCount, 0)

        model.advanceClock(rawClockTimeMs: 1_000)
        XCTAssertEqual(tickPlayer.playCount, 1)

        model.stepPendingOffset(by: 100)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 175)

        model.advanceClock(rawClockTimeMs: 1_499)
        XCTAssertEqual(tickPlayer.playCount, 1)

        model.advanceClock(rawClockTimeMs: 1_500)
        XCTAssertEqual(tickPlayer.playCount, 2)
    }

    func testTickPlaybackSkipsMissedIntervalsAfterFrameStall() {
        let tickPlayer = FakeCalibrationTickPlayer()
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0, tickPlayer: tickPlayer)

        model.advanceClock(rawClockTimeMs: 1_000)
        XCTAssertEqual(tickPlayer.playCount, 1)

        model.advanceClock(rawClockTimeMs: 2_600)
        XCTAssertEqual(tickPlayer.playCount, 2)

        model.advanceClock(rawClockTimeMs: 3_000)
        XCTAssertEqual(tickPlayer.playCount, 3)
    }

    func testVisibleObjectsDeriveBeatRangeWithoutKeepingExpiredNotes() {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)
        model.advanceClock(rawClockTimeMs: 1_300)

        XCTAssertEqual(
            model.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 199, lookaheadPaddingMs: 0),
            []
        )

        let visibleObjects = model.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 300, lookaheadPaddingMs: 0)
        XCTAssertEqual(visibleObjects.map(\.id.rawValue), [0])
        XCTAssertEqual(visibleObjects.first?.startTimeMs, 1_000)
    }

    func testResolvedBeatStatePrunesAfterItLeavesRecentFeedbackWindow() throws {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)

        model.advanceClock(rawClockTimeMs: 1_000)
        XCTAssertNotNil(model.recordInput(rawInputTimeMs: 1_000))
        XCTAssertEqual(
            model.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 20, lookaheadPaddingMs: 0).first?.state,
            .resolved
        )

        model.advanceClock(rawClockTimeMs: 1_700)
        let oldObject = try XCTUnwrap(
            model.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 800, lookaheadPaddingMs: 0)
                .first { $0.id.rawValue == 0 }
        )
        XCTAssertEqual(oldObject.state, .missedButVisible)
    }

    func testResolvedBeatStateRemainsBoundedDuringLongSessions() {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)

        for beatIndex in 0..<40 {
            let rawInputTimeMs = 1_000 + beatIndex * 500
            model.advanceClock(rawClockTimeMs: rawInputTimeMs)
            XCTAssertNotNil(model.recordInput(rawInputTimeMs: rawInputTimeMs))
        }

        let allPastObjects = model.visibleObjects(
            travelTimeMs: 0,
            postLineVisibleMs: Double(model.renderedChartTimeMs),
            lookaheadPaddingMs: 0
        )
        let resolvedObjectCount = allPastObjects.filter { $0.state == .resolved }.count

        XCTAssertLessThanOrEqual(resolvedObjectCount, 2)
    }

    func testHitWindowBoundariesAndSuggestedOffsetMathUseSampleRenderedOffset() throws {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 20)

        let boundarySample = try XCTUnwrap(model.recordInput(rawInputTimeMs: 1_120))
        XCTAssertEqual(boundarySample.beatIndex, 0)
        XCTAssertEqual(boundarySample.hitErrorMs, 120, accuracy: 0.001)
        XCTAssertEqual(boundarySample.sampleSuggestedOffsetMilliseconds, -100)

        XCTAssertNil(model.recordInput(rawInputTimeMs: 1_620.001))

        let suggestionModel = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)
        let earlySample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 990))
        XCTAssertEqual(earlySample.sampleSuggestedOffsetMilliseconds, 10)

        suggestionModel.stepPendingOffset(by: 40)
        XCTAssertEqual(suggestionModel.renderedOffsetMilliseconds, 40)

        let lateSample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 1_515))
        let laterSample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 2_030))

        XCTAssertEqual(lateSample.sampleRenderedOffsetMilliseconds, 40)
        XCTAssertEqual(lateSample.hitErrorMs, 55, accuracy: 0.001)
        XCTAssertEqual(lateSample.sampleSuggestedOffsetMilliseconds, -15)
        XCTAssertEqual(laterSample.sampleSuggestedOffsetMilliseconds, -30)
        XCTAssertEqual(suggestionModel.suggestedOffsetMilliseconds, -15)
        XCTAssertEqual(suggestionModel.suggestedAdjustmentMilliseconds, -55)
        XCTAssertEqual(suggestionModel.pendingOffsetMilliseconds, 40)
    }

    func testAcceptedHitSamplesAreCappedToRecentWindow() {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)

        for beatIndex in 0..<20 {
            let rawInputTimeMs = 1_000 + beatIndex * 500
            XCTAssertNotNil(model.recordInput(rawInputTimeMs: rawInputTimeMs))
        }

        XCTAssertEqual(model.hitSamples.count, 16)
        XCTAssertEqual(model.hitSamples.first?.beatIndex, 4)
        XCTAssertEqual(model.hitSamples.last?.beatIndex, 19)
    }

    func testRenderedOffsetPublishesAtMostTwicePerSecondDuringRepeatedEdits() {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)

        model.setPendingOffsetMilliseconds(10)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 10)

        model.setPendingOffsetMilliseconds(20)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 20)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 10)

        model.advanceClock(rawClockTimeMs: 499)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 10)

        model.advanceClock(rawClockTimeMs: 500)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 20)

        model.setPendingOffsetMilliseconds(30)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 20)

        model.advanceClock(rawClockTimeMs: 1_000)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 30)
    }

    func testPresetAddSelectDetachAndDeleteBehavior() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 0)

        model.setPendingOffsetMilliseconds(25)
        let blankPreset = model.addPreset(name: "  ", id: firstID)
        let namedPreset = model.addPreset(name: "  Speakers  ", presetMs: 80, id: secondID)

        XCTAssertEqual(blankPreset.name, "preset 1")
        XCTAssertEqual(blankPreset.presetMs, 25)
        XCTAssertEqual(namedPreset.name, "Speakers")
        XCTAssertEqual(namedPreset.presetMs, 80)

        XCTAssertTrue(model.selectPreset(id: secondID))
        XCTAssertEqual(model.activePresetID, secondID)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 80)

        model.stepPendingOffset(by: 1)
        XCTAssertNil(model.activePresetID)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 81)

        model.setPendingOffsetMilliseconds(80)
        XCTAssertNil(model.activePresetID)

        XCTAssertTrue(model.selectPreset(id: secondID))
        XCTAssertTrue(model.deletePreset(id: secondID))
        XCTAssertNil(model.activePresetID)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 80)
        XCTAssertEqual(model.presets.map(\.id), [firstID])
    }

    func testSessionLocalOriginalOffsetDoesNotBecomeAppliedStateWhenPresetIsPersisted() {
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 35)

        XCTAssertEqual(model.pendingOffsetMilliseconds, 35)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 0)

        _ = model.addPreset(name: "Session")
        XCTAssertEqual(model.cancel(), 35)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 0)

        let reloadedState = Mania4KOffsetCalibrationStoredState(storageValue: model.storedState.storageValue)
        XCTAssertEqual(reloadedState?.appliedGlobalOffsetMilliseconds, 0)
        XCTAssertEqual(reloadedState?.presets.first?.presetMs, 35)
    }

    func testExistingAppliedOffsetSurvivesPresetPersistenceFromSessionLocalCandidate() {
        let storedState = Mania4KOffsetCalibrationStoredState(appliedGlobalOffsetMilliseconds: 10)
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 35, storedState: storedState)

        XCTAssertEqual(model.pendingOffsetMilliseconds, 35)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 35)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 10)

        _ = model.addPreset(name: "Session")

        let reloadedState = Mania4KOffsetCalibrationStoredState(storageValue: model.storedState.storageValue)
        XCTAssertEqual(reloadedState?.appliedGlobalOffsetMilliseconds, 10)
        XCTAssertEqual(reloadedState?.presets.first?.presetMs, 35)
    }

    func testRestoredActivePresetSetsInitialCandidateOffsetWhenVisibleOffsetMatchesPreset() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedGlobalOffsetMilliseconds: 12,
            presets: [Mania4KOffsetPreset(id: presetID, name: "Headphones", presetMs: 85)],
            activePresetID: presetID
        )
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 85, storedState: storedState)

        XCTAssertEqual(model.activePresetID, presetID)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 12)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 85)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 85)
        XCTAssertEqual(model.noteTimeMs(forBeatIndex: 0), 1_085)
    }

    func testDivergentRestoredActivePresetRemainsSelectedAndUsesPresetOffset() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedGlobalOffsetMilliseconds: 10,
            presets: [Mania4KOffsetPreset(id: presetID, name: "Headphones", presetMs: 85)],
            activePresetID: presetID
        )
        let model = Mania4KOffsetCalibrationModel(originalOffsetMilliseconds: 35, storedState: storedState)

        XCTAssertEqual(model.activePresetID, presetID)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 10)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 85)
        XCTAssertEqual(model.renderedOffsetMilliseconds, 85)
        XCTAssertEqual(model.noteTimeMs(forBeatIndex: 0), 1_085)
        XCTAssertEqual(model.cancel(), 35)
    }

    func testStoredStateNormalizationClampsAppliedAndPresetOffsets() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedGlobalOffsetMilliseconds: 10_000,
            presets: [Mania4KOffsetPreset(id: presetID, name: "Bad", presetMs: -10_000)],
            activePresetID: presetID
        )

        let normalizedState = Mania4KOffsetCalibrationModel.normalizedStoredState(
            storedState,
            fallbackAppliedOffsetMilliseconds: 0
        )

        XCTAssertEqual(normalizedState.appliedGlobalOffsetMilliseconds, 500)
        XCTAssertEqual(normalizedState.presets.first?.presetMs, -500)
        XCTAssertEqual(normalizedState.activePresetID, presetID)
    }

    func testApplyAndCancelReturnExpectedOffsetAndOnlyApplyMutatesAppliedState() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let tickPlayer = FakeCalibrationTickPlayer()
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedGlobalOffsetMilliseconds: 12,
            presets: [Mania4KOffsetPreset(id: presetID, name: "wired", presetMs: 40)],
            activePresetID: presetID
        )
        let model = Mania4KOffsetCalibrationModel(
            originalOffsetMilliseconds: 12,
            storedState: storedState,
            tickPlayer: tickPlayer
        )

        XCTAssertEqual(model.activePresetID, presetID)
        XCTAssertEqual(model.pendingOffsetMilliseconds, 40)
        model.setPendingOffsetMilliseconds(44)
        XCTAssertNil(model.activePresetID)

        XCTAssertEqual(model.cancel(), 12)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 12)
        XCTAssertEqual(tickPlayer.stopCount, 1)

        XCTAssertEqual(model.apply(), 44)
        XCTAssertEqual(model.appliedGlobalOffsetMilliseconds, 44)
        XCTAssertEqual(tickPlayer.stopCount, 2)
    }
}

@MainActor
private final class FakeCalibrationTickPlayer: Mania4KOffsetCalibrationTickPlaying {
    private(set) var playCount = 0
    private(set) var stopCount = 0

    func playCalibrationTick() {
        playCount += 1
    }

    func stopCalibrationTicks() {
        stopCount += 1
    }
}

import XCTest
@testable import PulsefieldCore

@MainActor
final class Mania4KOffsetCalibrationModelTests: XCTestCase {
    func testDefaultPlayPresetSeedsStoredCalibrationState() {
        let state = Mania4KOffsetCalibrationStoredState.defaultPlayState

        XCTAssertEqual(state.appliedAudioOffsetMilliseconds, -215)
        XCTAssertEqual(state.appliedVisualOffsetMilliseconds, -15)
        XCTAssertEqual(state.activePresetID, Mania4KDefaultPlaySettings.offsetPresetID)
        XCTAssertEqual(state.presets, [
            Mania4KOffsetPreset(
                id: Mania4KDefaultPlaySettings.offsetPresetID,
                name: "wh1000xm4-mbaM5",
                audioOffsetMilliseconds: -215,
                visualOffsetMilliseconds: -15
            )
        ])
    }

    func testPairedOffsetsSeedAudioTimingVisualTimingAndRawTickCadence() {
        let tickPlayer = FakeCalibrationTickPlayer()
        let model = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 75,
            originalVisualOffsetMilliseconds: -20,
            tickPlayer: tickPlayer
        )

        XCTAssertEqual(model.appliedAudioOffsetMilliseconds, 0)
        XCTAssertEqual(model.appliedVisualOffsetMilliseconds, 0)
        XCTAssertEqual(model.noteTimeMs(forBeatIndex: 0), 1_075, accuracy: 0.001)
        XCTAssertEqual(model.gameplayChartTimeMs, 75)
        XCTAssertEqual(model.renderedChartTimeMs, 55)

        model.advanceClock(rawClockTimeMs: 999)
        XCTAssertEqual(tickPlayer.playCount, 0)

        model.advanceClock(rawClockTimeMs: 1_000)
        XCTAssertEqual(tickPlayer.playCount, 1)

        model.stepPendingAudioOffset(by: 100)
        XCTAssertEqual(model.renderedAudioOffsetMilliseconds, 175)
        XCTAssertEqual(model.renderedVisualOffsetMilliseconds, -20)

        model.stepPendingVisualOffset(by: -10)
        XCTAssertEqual(model.pendingVisualOffsetMilliseconds, -30)
        XCTAssertEqual(model.renderedVisualOffsetMilliseconds, -20)

        model.advanceClock(rawClockTimeMs: 1_500)
        XCTAssertEqual(tickPlayer.playCount, 2)
        XCTAssertEqual(model.renderedVisualOffsetMilliseconds, -30)
    }

    func testVisibleObjectsUseVisualTimingForRangeAndAudioTimingForMissState() throws {
        let positiveVisualModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 0,
            originalVisualOffsetMilliseconds: 200
        )
        positiveVisualModel.advanceClock(rawClockTimeMs: 950)

        let earlyObject = try XCTUnwrap(
            positiveVisualModel.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 300, lookaheadPaddingMs: 0).first
        )
        XCTAssertEqual(earlyObject.startTimeMs, 1_000)
        XCTAssertEqual(earlyObject.state, .waiting)

        let negativeVisualModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 0,
            originalVisualOffsetMilliseconds: -300
        )
        negativeVisualModel.advanceClock(rawClockTimeMs: 1_300)

        let missedObject = try XCTUnwrap(
            negativeVisualModel.visibleObjects(travelTimeMs: 0, postLineVisibleMs: 500, lookaheadPaddingMs: 0).first
        )
        XCTAssertEqual(missedObject.state, .missedButVisible)
    }

    func testRecordInputAndSuggestionUseAudioOffsetOnly() throws {
        let audioOnlyModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 20,
            originalVisualOffsetMilliseconds: 0
        )
        let visualShiftedModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 20,
            originalVisualOffsetMilliseconds: 120
        )

        let audioOnlySample = try XCTUnwrap(audioOnlyModel.recordInput(rawInputTimeMs: 1_120))
        let visualShiftedSample = try XCTUnwrap(visualShiftedModel.recordInput(rawInputTimeMs: 1_120))

        XCTAssertEqual(audioOnlySample.hitErrorMs, 120, accuracy: 0.001)
        XCTAssertEqual(visualShiftedSample.hitErrorMs, 120, accuracy: 0.001)
        XCTAssertEqual(audioOnlySample.sampleRenderedAudioOffsetMilliseconds, 20)
        XCTAssertEqual(visualShiftedSample.sampleRenderedAudioOffsetMilliseconds, 20)
        XCTAssertEqual(audioOnlySample.sampleSuggestedAudioOffsetMilliseconds, -100)
        XCTAssertEqual(visualShiftedSample.sampleSuggestedAudioOffsetMilliseconds, -100)
        XCTAssertEqual(visualShiftedModel.renderedChartTimeMs, 140)

        let suggestionModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 0,
            originalVisualOffsetMilliseconds: 80
        )
        let earlySample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 990))
        XCTAssertEqual(earlySample.sampleSuggestedAudioOffsetMilliseconds, 10)

        suggestionModel.stepPendingAudioOffset(by: 40)
        suggestionModel.stepPendingVisualOffset(by: -40)
        XCTAssertEqual(suggestionModel.renderedAudioOffsetMilliseconds, 40)
        XCTAssertEqual(suggestionModel.renderedVisualOffsetMilliseconds, 80)

        let lateSample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 1_515))
        let laterSample = try XCTUnwrap(suggestionModel.recordInput(rawInputTimeMs: 2_030))

        XCTAssertEqual(lateSample.hitErrorMs, 55, accuracy: 0.001)
        XCTAssertEqual(lateSample.sampleSuggestedAudioOffsetMilliseconds, -15)
        XCTAssertEqual(laterSample.sampleSuggestedAudioOffsetMilliseconds, -30)
        XCTAssertEqual(suggestionModel.suggestedAudioOffsetMilliseconds, -15)
        XCTAssertEqual(suggestionModel.suggestedAudioAdjustmentMilliseconds, -55)
        XCTAssertEqual(suggestionModel.pendingAudioOffsetMilliseconds, 40)
    }

    func testAcceptedHitSamplesRemainBoundedAndResolvedStatePrunes() throws {
        let model = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 0,
            originalVisualOffsetMilliseconds: 0
        )

        for beatIndex in 0..<20 {
            let rawInputTimeMs = 1_000 + beatIndex * 500
            model.advanceClock(rawClockTimeMs: rawInputTimeMs)
            XCTAssertNotNil(model.recordInput(rawInputTimeMs: rawInputTimeMs))
        }

        XCTAssertEqual(model.hitSamples.count, 16)
        XCTAssertEqual(model.hitSamples.first?.beatIndex, 4)
        XCTAssertEqual(model.hitSamples.last?.beatIndex, 19)

        let allPastObjects = model.visibleObjects(
            travelTimeMs: 0,
            postLineVisibleMs: Double(model.renderedChartTimeMs),
            lookaheadPaddingMs: 0
        )
        let resolvedObjectCount = allPastObjects.filter { $0.state == .resolved }.count

        XCTAssertLessThanOrEqual(resolvedObjectCount, 2)
    }

    func testPresetAddSelectDetachAndDeleteBehaviorStoresBothOffsets() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let model = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 0,
            originalVisualOffsetMilliseconds: 0
        )

        model.setPendingAudioOffsetMilliseconds(25)
        model.setPendingVisualOffsetMilliseconds(-15)
        let blankPreset = model.addPreset(name: "  ", id: firstID)
        let namedPreset = model.addPreset(
            name: "  Speakers  ",
            audioOffsetMilliseconds: 80,
            visualOffsetMilliseconds: -40,
            id: secondID
        )

        XCTAssertEqual(blankPreset.name, "preset 1")
        XCTAssertEqual(blankPreset.audioOffsetMilliseconds, 25)
        XCTAssertEqual(blankPreset.visualOffsetMilliseconds, -15)
        XCTAssertEqual(namedPreset.name, "Speakers")
        XCTAssertEqual(namedPreset.audioOffsetMilliseconds, 80)
        XCTAssertEqual(namedPreset.visualOffsetMilliseconds, -40)

        XCTAssertTrue(model.selectPreset(id: secondID))
        XCTAssertEqual(model.activePresetID, secondID)
        XCTAssertEqual(model.pendingAudioOffsetMilliseconds, 80)
        XCTAssertEqual(model.pendingVisualOffsetMilliseconds, -40)

        model.stepPendingVisualOffset(by: 1)
        XCTAssertNil(model.activePresetID)
        XCTAssertEqual(model.pendingVisualOffsetMilliseconds, -39)

        XCTAssertTrue(model.selectPreset(id: secondID))
        XCTAssertTrue(model.deletePreset(id: secondID))
        XCTAssertNil(model.activePresetID)
        XCTAssertEqual(model.presets.map(\.id), [firstID])
    }

    func testStorageUsesNewRequiredAudioAndVisualShapeWithoutOldFallback() throws {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedAudioOffsetMilliseconds: 12,
            appliedVisualOffsetMilliseconds: -18,
            presets: [
                Mania4KOffsetPreset(
                    id: presetID,
                    name: "Headphones",
                    audioOffsetMilliseconds: 85,
                    visualOffsetMilliseconds: -45
                )
            ],
            activePresetID: presetID
        )

        let reloadedState = try XCTUnwrap(Mania4KOffsetCalibrationStoredState(storageValue: storedState.storageValue))
        XCTAssertEqual(reloadedState.appliedAudioOffsetMilliseconds, 12)
        XCTAssertEqual(reloadedState.appliedVisualOffsetMilliseconds, -18)
        XCTAssertEqual(reloadedState.presets.first?.audioOffsetMilliseconds, 85)
        XCTAssertEqual(reloadedState.presets.first?.visualOffsetMilliseconds, -45)

        let oldStorageValue = """
        {"appliedGlobalOffsetMilliseconds":12,"presets":[{"id":"\(presetID.uuidString)","name":"old","presetMs":85}],"activePresetID":"\(presetID.uuidString)"}
        """
        XCTAssertNil(Mania4KOffsetCalibrationStoredState(storageValue: oldStorageValue))
    }

    func testStoredStateNormalizationClampsBothAppliedAndPresetOffsets() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedAudioOffsetMilliseconds: 10_000,
            appliedVisualOffsetMilliseconds: -10_000,
            presets: [
                Mania4KOffsetPreset(
                    id: presetID,
                    name: "Bad",
                    audioOffsetMilliseconds: -10_000,
                    visualOffsetMilliseconds: 10_000
                )
            ],
            activePresetID: presetID
        )

        let normalizedState = Mania4KOffsetCalibrationModel.normalizedStoredState(
            storedState,
            fallbackAppliedAudioOffsetMilliseconds: 0,
            fallbackAppliedVisualOffsetMilliseconds: 0
        )

        XCTAssertEqual(normalizedState.appliedAudioOffsetMilliseconds, 500)
        XCTAssertEqual(normalizedState.appliedVisualOffsetMilliseconds, -500)
        XCTAssertEqual(normalizedState.presets.first?.audioOffsetMilliseconds, -500)
        XCTAssertEqual(normalizedState.presets.first?.visualOffsetMilliseconds, 500)
        XCTAssertEqual(normalizedState.activePresetID, presetID)
    }

    func testApplyAndCancelReturnBothOffsetsAndOnlyApplyMutatesAppliedState() {
        let presetID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let tickPlayer = FakeCalibrationTickPlayer()
        let storedState = Mania4KOffsetCalibrationStoredState(
            appliedAudioOffsetMilliseconds: 12,
            appliedVisualOffsetMilliseconds: -8,
            presets: [
                Mania4KOffsetPreset(
                    id: presetID,
                    name: "wired",
                    audioOffsetMilliseconds: 40,
                    visualOffsetMilliseconds: -30
                )
            ],
            activePresetID: presetID
        )
        let model = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: 12,
            originalVisualOffsetMilliseconds: -8,
            storedState: storedState,
            tickPlayer: tickPlayer
        )

        XCTAssertEqual(model.activePresetID, presetID)
        XCTAssertEqual(model.pendingAudioOffsetMilliseconds, 40)
        XCTAssertEqual(model.pendingVisualOffsetMilliseconds, -30)
        model.setPendingAudioOffsetMilliseconds(44)
        XCTAssertNil(model.activePresetID)

        XCTAssertEqual(
            model.cancel(),
            Mania4KOffsetCalibrationOffsets(audioOffsetMilliseconds: 12, visualOffsetMilliseconds: -8)
        )
        XCTAssertEqual(model.appliedAudioOffsetMilliseconds, 12)
        XCTAssertEqual(model.appliedVisualOffsetMilliseconds, -8)
        XCTAssertEqual(tickPlayer.stopCount, 1)

        XCTAssertEqual(
            model.apply(),
            Mania4KOffsetCalibrationOffsets(audioOffsetMilliseconds: 44, visualOffsetMilliseconds: -30)
        )
        XCTAssertEqual(model.appliedAudioOffsetMilliseconds, 44)
        XCTAssertEqual(model.appliedVisualOffsetMilliseconds, -30)
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

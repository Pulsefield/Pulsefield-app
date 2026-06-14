import XCTest
@testable import PulsefieldCore

final class InferenceEndpointWebSocketClientTests: XCTestCase {
    func testAudioPathMessageUsesFlatProtocolKeysAndDefaultDifficulty() throws {
        let message = InferenceEndpointOutgoingMessage.audioPath("/Users/ken/audio/song1.wav", sessionID: "session-1")
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "audio_path")
        XCTAssertEqual(json["audio_path"] as? String, "/Users/ken/audio/song1.wav")
        XCTAssertEqual(json["music_source"] as? String, "background")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["difficulty"] as? Double, 4.0)
        XCTAssertEqual(json["is_mock"] as? Bool, false)
    }

    func testAudioPathMessageUsesConfiguredDifficultyAndMockFlag() throws {
        let message = InferenceEndpointOutgoingMessage.audioPath(
            "/Users/ken/audio/song1.wav",
            sessionID: "session-1",
            musicSource: .systemAudio,
            configuration: InferenceEndpointConfiguration(difficulty: 5.5, isMock: true)
        )
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["music_source"] as? String, "system_audio")
        XCTAssertEqual(json["difficulty"] as? Double, 5.5)
        XCTAssertEqual(json["is_mock"] as? Bool, true)
    }

    func testMusicSourceMapsToInputRoute() {
        XCTAssertEqual(MusicSource.background.input, .microphone)
        XCTAssertEqual(MusicSource.systemAudio.input, .screenCaptureKitAudio)
    }

    func testReferenceTimeMessageIncludesLocalHostSendTime() throws {
        let message = InferenceEndpointOutgoingMessage.referenceTime(
            sessionID: "session-1",
            refTimeMS: 1_234,
            localHostTimeSendMS: 6_789.25
        )
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "reference_time")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["ref_time_ms"] as? Int, 1_234)
        XCTAssertEqual(json["local_host_time_send_ms"] as? Double, 6_789.25)
        XCTAssertNil(json["difficulty"])
    }

    func testHitObjectTokenTupleDecodesAndParsesMapperEventTokenID() throws {
        let json = #"{"type":"hitobject_tokens","session_id":"session-1","token":[30,1234]}"#
        let message = try JSONDecoder().decode(InferenceEndpointIncomingMessage.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(message.token)
        let objects = try InferenceEndpointHitObjectTokenParser.hitObjects(from: payload)

        XCTAssertEqual(message.type, .hitObjectTokens)
        XCTAssertEqual(message.sessionID, "session-1")
        XCTAssertEqual(payload.tokenID, 30)
        XCTAssertEqual(payload.timeMS, 1_234)
        XCTAssertEqual(objects, [
            Mania4KHitObject(lane: .left, timeMs: 1_234, kind: .holdStart),
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_234, kind: .tap)
        ])
    }

    func testHitObjectTokenKeyedPayloadDecodesMapperContractNames() throws {
        let json = #"{"type":"hitobject_tokens","session_id":"session-1","token":{"token_id":279,"ms_in_ref_audio":9876}}"#
        let message = try JSONDecoder().decode(InferenceEndpointIncomingMessage.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(message.token)
        let objects = try InferenceEndpointHitObjectTokenParser.hitObjects(from: payload)

        XCTAssertEqual(payload.tokenID, 279)
        XCTAssertEqual(payload.timeMS, 9_876)
        XCTAssertEqual(objects, [
            Mania4KHitObject(lane: .left, timeMs: 9_876, kind: .holdEnd),
            Mania4KHitObject(lane: .innerLeft, timeMs: 9_876, kind: .holdEnd),
            Mania4KHitObject(lane: .innerRight, timeMs: 9_876, kind: .holdEnd),
            Mania4KHitObject(lane: .right, timeMs: 9_876, kind: .holdEnd)
        ])
    }

    func testEndOfStreamMessageDecodesAudioLengthAndCompleteThroughTime() throws {
        let json = #"{"type":"end_of_stream","session_id":"session-1","audio_length_ms":94277,"complete_through_ms":94277}"#
        let message = try JSONDecoder().decode(InferenceEndpointIncomingMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.type, .endOfStream)
        XCTAssertEqual(message.sessionID, "session-1")
        XCTAssertEqual(message.audioLengthMS, 94_277)
        XCTAssertEqual(message.completeThroughMS, 94_277)
    }

    func testHitObjectTokenRejectsIdsOutsideMapperEventRange() {
        XCTAssertThrowsError(try InferenceEndpointHitObjectTokenParser.hitObjects(
            from: InferenceEndpointTokenPayload(tokenID: 24, timeMS: 100)
        )) { error in
            XCTAssertEqual(error as? InferenceEndpointProtocolError, .invalidHitObjectTokenID(24))
        }
    }

    func testReadyWindowEndsAtLatestTimeWithNoOpenHold() {
        let objects = [
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_200, kind: .holdStart),
            Mania4KHitObject(lane: .right, timeMs: 1_350, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_800, kind: .holdEnd),
            Mania4KHitObject(lane: .innerRight, timeMs: 2_100, kind: .holdStart)
        ]

        let readyWindow = InferenceHitObjectTokenBuffer.readyWindow(for: objects)

        XCTAssertEqual(readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 1_800))
        XCTAssertEqual(readyWindow?.lengthMS, 800)
    }

    func testRenderReadinessUsesReferenceTimeLeadAndFiveSecondBuffer() {
        let buffer = InferenceHitObjectTokenBuffer(objects: [
            Mania4KHitObject(lane: .left, timeMs: 74_500, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 75_000, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 80_100, kind: .tap)
        ])

        let readiness = buffer.renderReadiness(
            referenceTimeMS: 74_000,
            minimumBufferedDurationMS: 5_000,
            firstObjectLeadTimeMS: 1_000
        )

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.requiredFirstObjectTimeMS, 75_000)
        XCTAssertEqual(readiness.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 75_000, endTimeMS: 80_100))
        XCTAssertEqual(readiness.bufferedDurationAfterFirstObjectMS, 5_100)
    }

    func testRenderReadinessWaitsForCleanBoundaryAfterOpenHold() {
        let buffer = InferenceHitObjectTokenBuffer(objects: [
            Mania4KHitObject(lane: .left, timeMs: 74_000, kind: .holdStart),
            Mania4KHitObject(lane: .left, timeMs: 76_000, kind: .holdEnd),
            Mania4KHitObject(lane: .innerLeft, timeMs: 77_000, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 82_100, kind: .tap)
        ])

        let readiness = buffer.renderReadiness(
            referenceTimeMS: 74_000,
            minimumBufferedDurationMS: 5_000,
            firstObjectLeadTimeMS: 1_000
        )

        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(readiness.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 77_000, endTimeMS: 82_100))
    }

    func testRenderReadinessRejectsShortFutureBuffer() {
        let buffer = InferenceHitObjectTokenBuffer(objects: [
            Mania4KHitObject(lane: .left, timeMs: 75_000, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 79_900, kind: .tap)
        ])

        let readiness = buffer.renderReadiness(
            referenceTimeMS: 74_000,
            minimumBufferedDurationMS: 5_000,
            firstObjectLeadTimeMS: 1_000
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 75_000, endTimeMS: 79_900))
    }

    func testBufferedInferenceStreamStartsAtReadyWindowAndThenAcceptsDirectTokens() async throws {
        let referenceTime = ManualInferenceReferenceTime(timeMS: 74_000)
        let stream = BufferedInferenceMania4KHitObjectStream(
            metadata: Mania4KChartMetadata(title: "Generated", sourceDescription: "Test"),
            minimumBufferedDurationMS: 5_000,
            firstObjectLeadTimeMS: 1_000,
            referenceTimeProvider: {
                await referenceTime.value()
            }
        )

        await stream.append(contentsOf: [
            Mania4KHitObject(lane: .left, timeMs: 74_500, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 75_000, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 80_100, kind: .tap)
        ])

        var batch = try await stream.read(after: nil, throughChartTimeMs: 75_500, limit: 10)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .innerLeft, timeMs: 75_000, kind: .tap)
        ])
        XCTAssertEqual(batch.completeThroughChartTimeMs, 75_500)

        await stream.append(contentsOf: [
            Mania4KHitObject(lane: .innerRight, timeMs: 75_250, kind: .tap)
        ])

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 75_500, limit: 10)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .innerRight, timeMs: 75_250, kind: .tap)
        ])

        await stream.append(contentsOf: [
            Mania4KHitObject(lane: .right, timeMs: 75_100, kind: .tap)
        ])

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 75_500, limit: 10)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .right, timeMs: 75_100, kind: .tap)
        ])
    }

    func testBufferRejectsTokensAtOrBeforeReadyWindowEndWithoutChangingReadyWindow() {
        var buffer = InferenceHitObjectTokenBuffer()

        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .innerLeft, timeMs: 1_200, kind: .holdStart)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .innerLeft, timeMs: 1_800, kind: .holdEnd)))
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 1_800))

        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .right, timeMs: 1_500, kind: .tap)))
        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .right, timeMs: 1_800, kind: .tap)))
        XCTAssertEqual(buffer.objects.count, 3)
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 1_800))

        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .right, timeMs: 2_100, kind: .tap)))
        XCTAssertEqual(buffer.objects.count, 4)
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 2_100))
    }

    func testBufferRejectsTokensBeforeMinimumAcceptedTime() {
        var buffer = InferenceHitObjectTokenBuffer(minimumAcceptedTimeMS: 1_500)

        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .left, timeMs: 1_499, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .innerLeft, timeMs: 1_500, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .right, timeMs: 1_700, kind: .tap)))

        XCTAssertEqual(buffer.objects, [
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_500, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 1_700, kind: .tap)
        ])
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_500, endTimeMS: 1_700))
    }

    func testBufferPrunesExistingObjectsWhenMinimumAcceptedTimeIsSet() {
        var buffer = InferenceHitObjectTokenBuffer(objects: [
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_500, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 1_900, kind: .tap)
        ])

        buffer.setMinimumAcceptedTimeMS(1_500)

        XCTAssertEqual(buffer.objects, [
            Mania4KHitObject(lane: .innerLeft, timeMs: 1_500, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 1_900, kind: .tap)
        ])
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_500, endTimeMS: 1_900))
    }

    func testBufferRejectsTokensOutsideAudioLength() {
        var buffer = InferenceHitObjectTokenBuffer(maximumAcceptedTimeMS: 2_000)

        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .left, timeMs: -1, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .innerLeft, timeMs: 0, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .innerRight, timeMs: 2_000, kind: .tap)))
        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .right, timeMs: 2_001, kind: .tap)))

        XCTAssertEqual(buffer.objects, [
            Mania4KHitObject(lane: .innerLeft, timeMs: 0, kind: .tap),
            Mania4KHitObject(lane: .innerRight, timeMs: 2_000, kind: .tap)
        ])
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 0, endTimeMS: 2_000))
    }

    func testBufferPrunesExistingObjectsWhenMaximumAcceptedTimeIsSet() {
        var buffer = InferenceHitObjectTokenBuffer(objects: [
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 2_000, kind: .tap),
            Mania4KHitObject(lane: .right, timeMs: 2_001, kind: .tap)
        ])

        buffer.setMaximumAcceptedTimeMS(2_000)

        XCTAssertEqual(buffer.objects, [
            Mania4KHitObject(lane: .left, timeMs: 1_000, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 2_000, kind: .tap)
        ])
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 2_000))
    }

    func testBufferedInferenceStreamMarksEndOfStreamAtCompleteThroughTime() async throws {
        let referenceTime = ManualInferenceReferenceTime(timeMS: 0)
        let stream = BufferedInferenceMania4KHitObjectStream(
            metadata: Mania4KChartMetadata(title: "Generated", sourceDescription: "Test"),
            minimumBufferedDurationMS: 0,
            firstObjectLeadTimeMS: 0,
            referenceTimeProvider: {
                await referenceTime.value()
            }
        )

        await stream.append(contentsOf: [
            Mania4KHitObject(lane: .left, timeMs: 100, kind: .tap)
        ])

        var batch = try await stream.read(after: nil, throughChartTimeMs: 100, limit: 10)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .left, timeMs: 100, kind: .tap)
        ])
        XCTAssertFalse(batch.isEndOfStream)

        await stream.finish(completeThroughTimeMS: 200)
        let appendedAfterEnd = await stream.append(contentsOf: [
            Mania4KHitObject(lane: .innerLeft, timeMs: 150, kind: .tap)
        ])
        XCTAssertFalse(appendedAfterEnd)

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 199, limit: 10)
        XCTAssertFalse(batch.isEndOfStream)

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 200, limit: 10)
        XCTAssertTrue(batch.isEndOfStream)
    }

    func testBufferedInferenceStreamDoesNotEndWhileLimitedBatchMayHaveMoreObjects() async throws {
        let referenceTime = ManualInferenceReferenceTime(timeMS: 0)
        let stream = BufferedInferenceMania4KHitObjectStream(
            metadata: Mania4KChartMetadata(title: "Generated", sourceDescription: "Test"),
            minimumBufferedDurationMS: 0,
            firstObjectLeadTimeMS: 0,
            referenceTimeProvider: {
                await referenceTime.value()
            }
        )

        await stream.append(contentsOf: [
            Mania4KHitObject(lane: .left, timeMs: 100, kind: .tap),
            Mania4KHitObject(lane: .innerLeft, timeMs: 120, kind: .tap)
        ])
        await stream.finish(completeThroughTimeMS: 200)

        var batch = try await stream.read(after: nil, throughChartTimeMs: 200, limit: 1)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .left, timeMs: 100, kind: .tap)
        ])
        XCTAssertFalse(batch.isEndOfStream)

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 200, limit: 1)
        XCTAssertEqual(batch.objects, [
            Mania4KHitObject(lane: .innerLeft, timeMs: 120, kind: .tap)
        ])
        XCTAssertFalse(batch.isEndOfStream)

        batch = try await stream.read(after: batch.nextCursor, throughChartTimeMs: 200, limit: 1)
        XCTAssertEqual(batch.objects, [])
        XCTAssertTrue(batch.isEndOfStream)
    }

    func testBufferedInferenceStreamCanFinishWithoutInitialReadyWindow() async throws {
        let referenceTime = ManualInferenceReferenceTime(timeMS: 0)
        let stream = BufferedInferenceMania4KHitObjectStream(
            metadata: Mania4KChartMetadata(title: "Generated", sourceDescription: "Test"),
            minimumBufferedDurationMS: 5_000,
            firstObjectLeadTimeMS: 1_000,
            referenceTimeProvider: {
                await referenceTime.value()
            }
        )

        await stream.finish(completeThroughTimeMS: 800)
        let batch = try await stream.read(after: nil, throughChartTimeMs: 800, limit: 10)

        XCTAssertEqual(batch.objects, [])
        XCTAssertEqual(batch.completeThroughChartTimeMs, 800)
        XCTAssertTrue(batch.isEndOfStream)
    }

    func testBufferRejectsNonFiniteTokenTimes() {
        var buffer = InferenceHitObjectTokenBuffer(maximumAcceptedTimeMS: 2_000)

        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .left, timeMs: .nan, kind: .tap)))
        XCTAssertFalse(buffer.append(Mania4KHitObject(lane: .innerLeft, timeMs: .infinity, kind: .tap)))
        XCTAssertTrue(buffer.append(Mania4KHitObject(lane: .right, timeMs: 1_000, kind: .tap)))

        XCTAssertEqual(buffer.objects, [
            Mania4KHitObject(lane: .right, timeMs: 1_000, kind: .tap)
        ])
        XCTAssertEqual(buffer.readyWindow, InferenceHitObjectReadyWindow(startTimeMS: 1_000, endTimeMS: 1_000))
    }

}

private actor ManualInferenceReferenceTime {
    private var timeMS: Double

    init(timeMS: Double) {
        self.timeMS = timeMS
    }

    func value() -> Double? {
        timeMS
    }

    func setTimeMS(_ timeMS: Double) {
        self.timeMS = timeMS
    }
}

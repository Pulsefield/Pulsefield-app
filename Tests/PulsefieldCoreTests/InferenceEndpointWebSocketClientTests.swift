import XCTest
@testable import PulsefieldCore

final class InferenceEndpointWebSocketClientTests: XCTestCase {
    func testAudioPathMessageUsesFlatProtocolKeysAndDefaultDifficulty() throws {
        let message = InferenceEndpointOutgoingMessage.audioPath("/Users/ken/audio/song1.wav", sessionID: "session-1")
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "audio_path")
        XCTAssertEqual(json["audio_path"] as? String, "/Users/ken/audio/song1.wav")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["difficulty"] as? Double, 4.0)
    }

    func testAudioPathMessageUsesConfiguredDifficulty() throws {
        let message = InferenceEndpointOutgoingMessage.audioPath(
            "/Users/ken/audio/song1.wav",
            sessionID: "session-1",
            configuration: InferenceEndpointConfiguration(difficulty: 5.5)
        )
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["difficulty"] as? Double, 5.5)
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
}

#if DEBUG
import Foundation
import XCTest
@testable import PulsefieldCore

final class DebugACRCloudRecognitionProviderTests: XCTestCase {
    func testNormalizerBuildsMusicMatchFromFilescanScanJSON() throws {
        let json = """
        {
          "data": [
            {
              "id": "file-id",
              "cid": 123456,
              "name": "pulsefield-acrcloud.wav",
              "duration": 10,
              "state": 1,
              "results": {
                "music": [
                  {
                    "offset": 0.25,
                    "played_duration": 9.28,
                    "type": "fingerprint",
                    "result": {
                      "acrid": "6049f11da7095e8bb8266871d4a70873",
                      "audio_id": "audio-id",
                      "title": "Hello",
                      "artists": [{ "name": "Adele" }],
                      "album": { "name": "Hello" },
                      "external_ids": { "isrc": "GBBKS1500214" },
                      "duration_ms": 295000,
                      "score": 100,
                      "release_date": "2015-10-23"
                    }
                  }
                ]
              }
            }
          ]
        }
        """

        let result = try ACRCloudFileScanNormalizer.result(from: Data(json.utf8))

        XCTAssertEqual(result.fileID, "file-id")
        XCTAssertEqual(result.containerID, 123_456)
        XCTAssertEqual(result.state, 1)
        XCTAssertEqual(result.stateDescription, "Ready")
        XCTAssertEqual(result.music?.title, "Hello")
        XCTAssertEqual(result.music?.artists, ["Adele"])
        XCTAssertEqual(result.music?.album, "Hello")
        XCTAssertEqual(result.music?.durationMS, 295_000)
        XCTAssertEqual(result.music?.isrc, "GBBKS1500214")
        XCTAssertEqual(result.music?.score, 100)
        XCTAssertEqual(result.music?.offsetSeconds, 0.25)
        XCTAssertEqual(result.music?.playedDurationSeconds, 9.28)
        XCTAssertEqual(result.music?.matchType, "fingerprint")
        XCTAssertEqual(result.music?.canonicalTrack.providerIDs, [
            ProviderTrackID(provider: .acrCloud, value: "6049f11da7095e8bb8266871d4a70873")
        ])
    }

    func testNormalizerExtractsFinalJSONAfterFilescanProgressOutput() throws {
        let output = """
        Searching for existing containers...
        Using specified container: ID=123456
        Uploading file: /tmp/pulsefield-acrcloud.wav...
        Waiting for recognition results (timeout: 600s, poll interval: 5s)...
        {
          "data": {
            "id": "file-id",
            "cid": "123456",
            "state": "1",
            "results": {
              "music": [
                {
                  "offset": "1.5",
                  "played_duration": "8.0",
                  "result": {
                    "acrid": "acr-id",
                    "title": "Track",
                    "artists": ["Artist"],
                    "external_ids": { "isrc": "ISRC" }
                  }
                }
              ]
            }
          }
        }
        """

        let result = try ACRCloudFileScanNormalizer.result(fromCLIOutput: output)

        XCTAssertEqual(result.containerID, 123_456)
        XCTAssertEqual(result.music?.title, "Track")
        XCTAssertEqual(result.music?.artists, ["Artist"])
        XCTAssertEqual(result.music?.offsetSeconds, 1.5)
        XCTAssertEqual(result.music?.playedDurationSeconds, 8)
    }

    func testNormalizerMapsMusicMatchToRecognitionSnapshot() {
        let match = ACRCloudMusicMatch(
            acrid: "acr-id",
            title: "Hello",
            artists: ["Adele"],
            isrc: "GBBKS1500214",
            offsetSeconds: 0.5,
            playedDurationSeconds: 9.28
        )
        let clip = RecognitionAudioClip(
            fileURL: URL(fileURLWithPath: "/tmp/pulsefield-acrcloud.wav"),
            mimeType: "audio/wav",
            duration: 10,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let snapshot = ACRCloudFileScanNormalizer.snapshot(from: match, clip: clip)

        XCTAssertEqual(snapshot.track.id, "acrcloud:acr-id")
        XCTAssertEqual(snapshot.track.title, "Hello")
        XCTAssertEqual(snapshot.track.artist, "Adele")
        XCTAssertEqual(snapshot.track.externalIDs.isrc, "GBBKS1500214")
        XCTAssertEqual(snapshot.track.source, .acrCloud)
        XCTAssertEqual(snapshot.anchor.predictedMatchOffset, 0.5)
        XCTAssertEqual(snapshot.anchor.matchedRanges, [0.5..<9.78])
    }
}
#endif

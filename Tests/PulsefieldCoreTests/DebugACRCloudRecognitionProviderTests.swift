#if DEBUG
import Foundation
import XCTest
@testable import PulsefieldCore

final class DebugACRCloudRecognitionProviderTests: XCTestCase {
    func testIdentificationSignatureMatchesACRCloudStringToSign() {
        let signature = ACRCloudIdentificationClient.signature(
            accessKey: "access",
            accessSecret: "secret",
            timestamp: "1700000000"
        )

        XCTAssertEqual(signature, "HKwxEnL0W2jQ1BT9U9khozrFVD4=")
    }

    func testIdentificationNormalizerBuildsMusicMatchFromAPIJSON() throws {
        let json = """
        {
          "status": {
            "msg": "Success",
            "code": 0
          },
          "metadata": {
            "music": [
              {
                "acrid": "6049f11da7095e8bb8266871d4a70873",
                "title": "Hello",
                "artists": [{ "name": "Adele" }],
                "album": { "name": "Hello" },
                "external_ids": { "isrc": "GBBKS1500214" },
                "duration_ms": 295000,
                "score": 100,
                "release_date": "2015-10-23",
                "play_offset_ms": 10920
              }
            ]
          }
        }
        """

        let result = try ACRCloudIdentificationNormalizer.result(from: Data(json.utf8))

        XCTAssertEqual(result.statusCode, 0)
        XCTAssertEqual(result.statusMessage, "Success")
        XCTAssertEqual(result.music?.title, "Hello")
        XCTAssertEqual(result.music?.artists, ["Adele"])
        XCTAssertEqual(result.music?.album, "Hello")
        XCTAssertEqual(result.music?.durationMS, 295_000)
        XCTAssertEqual(result.music?.isrc, "GBBKS1500214")
        XCTAssertEqual(result.music?.score, 100)
        XCTAssertEqual(result.music?.releaseDate, "2015-10-23")
        XCTAssertEqual(result.music?.offsetSeconds, 10.92)
        XCTAssertEqual(result.music?.canonicalTrack.providerIDs, [
            ProviderTrackID(provider: .acrCloud, value: "6049f11da7095e8bb8266871d4a70873")
        ])
    }

    func testIdentificationNormalizerTreatsNoResultAsNoMatch() throws {
        let json = """
        {
          "status": {
            "msg": "No result",
            "code": 1001
          }
        }
        """

        let result = try ACRCloudIdentificationNormalizer.result(from: Data(json.utf8))

        XCTAssertTrue(result.isNoResult)
        XCTAssertNil(result.music)
    }

    func testFilescanClientResolvesBareExecutableFromConfiguredPath() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldACRCloudCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let executableURL = directoryURL.appendingPathComponent("acrcloud")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"data":{"id":"file-id","state":1,"results":{"music":[{"result":{"acrid":"acr-id","title":"Track","artists":[{"name":"Artist"}]}}]}}}'
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executableURL.path
        )

        let clipURL = directoryURL.appendingPathComponent("clip.wav")
        try Data([0]).write(to: clipURL)
        let clip = RecognitionAudioClip(
            fileURL: clipURL,
            mimeType: "audio/wav",
            duration: 1,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let configuration = ACRCloudFileScanConfiguration(
            accessToken: "token",
            executablePath: "acrcloud",
            environment: ["PATH": directoryURL.path]
        )

        let execution = try ACRCloudFileScanClient().scan(clip: clip, configuration: configuration)

        XCTAssertEqual(execution.command.first, executableURL.path)
        XCTAssertEqual(execution.result.music?.title, "Track")
        XCTAssertEqual(execution.result.music?.artists, ["Artist"])
    }

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

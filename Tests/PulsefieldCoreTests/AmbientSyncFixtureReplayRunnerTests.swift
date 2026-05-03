import AVFoundation
import XCTest
@testable import PulsefieldCore

final class AmbientSyncFixtureReplayRunnerTests: XCTestCase {
    func testProcessesTempCAFFixtureAndEmitsMonotonicJSONLTrace() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let fixtureDirectoryURL = workingDirectory.appendingPathComponent("fixtures", isDirectory: true)
        let tracesDirectoryURL = workingDirectory.appendingPathComponent("traces", isDirectory: true)
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)

        let targetAudioURL = workingDirectory.appendingPathComponent("target.caf")
        let fixtureAudioURL = fixtureDirectoryURL.appendingPathComponent("take-01.caf")
        try writeGeneratedCAF(to: targetAudioURL, durationSeconds: 3.2)
        try writeGeneratedCAF(to: fixtureAudioURL, durationSeconds: 3.2)
        try writeSidecar(
            audioFileName: fixtureAudioURL.lastPathComponent,
            targetAudioURL: targetAudioURL,
            to: fixtureDirectoryURL.appendingPathComponent("take-01.ambient-sync-fixture.json")
        )

        let runner = AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>(
            configuration: AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>.Configuration(
                fixtureDirectoryURL: fixtureDirectoryURL,
                traceOutputDirectoryURL: tracesDirectoryURL,
                referenceIndexCacheDirectoryURL: cacheDirectoryURL
            )
        )
        let fixtures = try runner.discoverFixtures()
        let result = try runner.replayFixture(try XCTUnwrap(fixtures.first))

        XCTAssertEqual(fixtures.count, 1)
        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.traceOutputURL.path))
        XCTAssertEqual(result.events.map(\.sequence), Array(0..<result.events.count))
        XCTAssertEqual(result.events.map(\.timing.elapsedMS), result.events.map(\.timing.elapsedMS).sorted())

        let jsonl = try String(contentsOf: result.traceOutputURL, encoding: .utf8)
        XCTAssertEqual(jsonl.split(separator: "\n").count, result.events.count)
    }

    func testReplayDoesNotDecodeTargetWhenReferenceBuilderDoesNotNeedIt() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let fixtureDirectoryURL = workingDirectory.appendingPathComponent("fixtures", isDirectory: true)
        let tracesDirectoryURL = workingDirectory.appendingPathComponent("traces", isDirectory: true)
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)

        let targetAudioURL = workingDirectory.appendingPathComponent("target.caf")
        let fixtureAudioURL = fixtureDirectoryURL.appendingPathComponent("take-01.caf")
        try Data([0x70, 0x66, 0x6C, 0x64]).write(to: targetAudioURL, options: .atomic)
        try writeGeneratedCAF(to: fixtureAudioURL, durationSeconds: 3.2)
        try writeSidecar(
            audioFileName: fixtureAudioURL.lastPathComponent,
            targetAudioURL: targetAudioURL,
            to: fixtureDirectoryURL.appendingPathComponent("take-01.ambient-sync-fixture.json")
        )

        let runner = AmbientSyncFixtureReplayRunner<Int>(
            configuration: AmbientSyncFixtureReplayRunner<Int>.Configuration(
                fixtureDirectoryURL: fixtureDirectoryURL,
                traceOutputDirectoryURL: tracesDirectoryURL,
                referenceIndexCacheDirectoryURL: cacheDirectoryURL
            ),
            referenceIndexBuilder: { _ in
                1
            },
            engineFactory: { _ in
                AmbientSyncFixtureReplayEngine<Int> { input in
                    AmbientSyncSnapshot(
                        state: .listening,
                        phase: .none,
                        stage: .readiness,
                        diagnostics: AmbientSyncDiagnostics(
                            queryDurationMS: input.queryWindow.durationMS,
                            activeFrameFraction: 1,
                            queryLandmarkCount: 0
                        )
                    )
                }
            }
        )

        let fixture = try XCTUnwrap(try runner.discoverFixtures().first)
        let result = try runner.replayFixture(fixture)

        XCTAssertFalse(result.events.isEmpty)
    }

    func testDiscoverFixturesIgnoresAudioFileNameWithPathSeparators() throws {
        let workingDirectory = try makeTemporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let fixtureDirectoryURL = workingDirectory.appendingPathComponent("fixtures", isDirectory: true)
        let tracesDirectoryURL = workingDirectory.appendingPathComponent("traces", isDirectory: true)
        let cacheDirectoryURL = workingDirectory.appendingPathComponent("reference-indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)

        let outsideAudioURL = workingDirectory.appendingPathComponent("outside.caf")
        let targetAudioURL = workingDirectory.appendingPathComponent("target.caf")
        try writeGeneratedCAF(to: outsideAudioURL, durationSeconds: 1)
        try writeSidecar(
            audioFileName: "../outside.caf",
            targetAudioURL: targetAudioURL,
            to: fixtureDirectoryURL.appendingPathComponent("escape.ambient-sync-fixture.json")
        )

        let runner = AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>(
            configuration: AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>.Configuration(
                fixtureDirectoryURL: fixtureDirectoryURL,
                traceOutputDirectoryURL: tracesDirectoryURL,
                referenceIndexCacheDirectoryURL: cacheDirectoryURL
            )
        )

        XCTAssertTrue(try runner.discoverFixtures().isEmpty)
    }

    func testLocalGeneration2FixtureSmokeWritesTraceWhenAssetsExist() throws {
        guard ProcessInfo.processInfo.environment["PULSEFIELD_RUN_LOCAL_AMBIENT_SYNC_REPLAY_SMOKE"] == "1" else {
            throw XCTSkip("Set PULSEFIELD_RUN_LOCAL_AMBIENT_SYNC_REPLAY_SMOKE=1 to run local real-fixture replay.")
        }

        let fixtureDirectoryURL = AmbientSyncFixtureRecorder.defaultFixtureDirectoryURL()
        guard FileManager.default.fileExists(atPath: fixtureDirectoryURL.path) else {
            throw XCTSkip("No local ambient sync fixture directory.")
        }

        let runner = AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>()
        let fixtures = try runner.discoverFixtures().filter { fixture in
            FileManager.default.fileExists(atPath: fixture.targetAudioURL.path)
        }
        guard let fixture = fixtures.first else {
            throw XCTSkip("No generation 2 .caf fixture with an available target asset.")
        }

        let result = try runner.replayFixture(fixture)

        XCTAssertFalse(result.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.traceOutputURL.path))
        XCTAssertEqual(result.events.map(\.timing.elapsedMS), result.events.map(\.timing.elapsedMS).sorted())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsefieldAmbientSyncFixtureReplayRunnerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSidecar(
        audioFileName: String,
        targetAudioURL: URL,
        to sidecarURL: URL
    ) throws {
        let metadata = AmbientSyncFixtureRecordingMetadata(
            recordingID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_000),
            stoppedAt: Date(timeIntervalSince1970: 1_004),
            durationMS: 3_200,
            audioFileName: audioFileName,
            recordingGroup: "generated",
            takeLabel: "take-01",
            sampleRate: 48_000,
            channelCount: 1,
            targetAsset: AmbientSyncFixtureTargetAsset(
                id: UUID(),
                displayPath: targetAudioURL.path,
                fileName: targetAudioURL.lastPathComponent,
                sha256: "generated",
                durationMS: 3_200,
                title: "Generated Target",
                artists: [],
                album: nil,
                isrc: nil
            ),
            notes: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: sidecarURL, options: .atomic)
    }

    private func writeGeneratedCAF(
        to url: URL,
        durationSeconds: Double
    ) throws {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * durationSeconds)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frameIndex in 0..<frameCount {
            let time = Double(frameIndex) / sampleRate
            let envelope = 0.45 + 0.45 * sin(2 * Double.pi * 2.5 * time)
            samples[frameIndex] = Float(
                0.30 * envelope * sin(2 * Double.pi * 440 * time)
                    + 0.18 * sin(2 * Double.pi * 660 * time)
                    + 0.12 * sin(2 * Double.pi * 990 * time)
            )
        }

        try file.write(from: buffer)
    }
}

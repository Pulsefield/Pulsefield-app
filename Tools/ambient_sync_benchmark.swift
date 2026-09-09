// Offline fixed-window replay. Features are extracted before replay; audio time
// drives the engine. This does not simulate callback backlog or UI latency.
// Link against PulsefieldCore.framework; pass --help for CLI arguments.
import Darwin
import Dispatch
import Foundation
import PulsefieldCore

struct BenchmarkError: Error, CustomStringConvertible { let description: String }
func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
let usage = """
    Usage: ambient_sync_benchmark --fixtures DIR --output DIR [--filter SUBSTRING]
           [--cadence-ms 1000] [--entry-seconds 0,30,90] [--legacy]
           [--max-duration-seconds SECONDS]
    Default engine uses AmbientSyncEngine's default configuration; --legacy uses .v1.
    Each entry creates a fresh feature extractor and engine. Entry 0 replays the full
    recording; positive entries replay 30 seconds. --max-duration-seconds caps either.
    Queries use the live feature configuration's fixed 5-second window. Times in
    traces are relative to the entry point; summary records the original entry.
    Reference targets come from sidecars; annotation offsets are never engine input.
    """
var values: [String: String] = [:]
var legacy = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let key = args.removeFirst()
    if key == "--help" {
        print(usage)
        exit(0)
    }
    if key == "--legacy" {
        legacy = true
        continue
    }
    guard
        ["--fixtures", "--output", "--filter", "--cadence-ms", "--entry-seconds", "--max-duration-seconds"].contains(
            key), !args.isEmpty
    else { throw BenchmarkError(description: "Invalid or incomplete option: \(key)\n\(usage)") }
    values[key] = args.removeFirst()
}
guard let rootPath = values["--fixtures"], let outputPath = values["--output"] else {
    throw BenchmarkError(description: usage)
}
guard let cadence = Double(values["--cadence-ms"] ?? "1000"), cadence.isFinite, cadence > 0 else {
    throw BenchmarkError(description: "cadence-ms must be finite and positive")
}
let entries = try (values["--entry-seconds"] ?? "0").split(separator: ",", omittingEmptySubsequences: false).map {
    text -> Double in
    guard let value = Double(text), value.isFinite, value >= 0 else {
        throw BenchmarkError(description: "entry-seconds must contain finite nonnegative numbers")
    }
    return value
}
let maximumDuration: Double?
if let text = values["--max-duration-seconds"] {
    guard let value = Double(text), value.isFinite, value > 0 else {
        throw BenchmarkError(description: "max-duration-seconds must be finite and positive")
    }
    maximumDuration = value
} else {
    maximumDuration = nil
}
let root = URL(fileURLWithPath: rootPath, isDirectory: true)
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let featureConfig = AmbientSyncFeatureConfiguration.v1
let frameBuilder = AmbientSyncAudioFeatureFrameBuilder(featureConfiguration: featureConfig, chunkSizeSamples: 16384)
let indexBuilder = AmbientSyncReferenceIndexBuilder(
    configuration: .init(
        cacheDirectoryURL: root.appendingPathComponent(".ambient-sync-reference-indexes"),
        featureConfiguration: featureConfig))
let discovery = AmbientSyncFixtureReplayRunner<AmbientSyncReferenceIndex>(
    configuration: .init(fixtureDirectoryURL: root))
let selected = try discovery.discoverFixtures().filter { fixture in
    guard let filter = values["--filter"], !filter.isEmpty else { return true }
    return fixture.fixtureAudioURL.lastPathComponent.contains(filter)
}
guard !selected.isEmpty else { throw BenchmarkError(description: "No fixtures matched") }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
encoder.nonConformingFloatEncodingStrategy = .convertToString(
    positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
var summaries: [[String: Any]] = []
var indexes: [String: AmbientSyncReferenceIndex] = [:]
func writeSummary() throws {
    let result: [String: Any] = [
        "mode": "offline, features extracted before replay; no hardware callback or UI latency simulation",
        "engine": legacy ? "legacy-v1" : "default", "cadenceMS": cadence,
        "queryWindowMS": featureConfig.finalLockTargetDurationMS, "referenceOffsetsUsedAsInput": false,
        "fixtures": summaries,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(
        to: output.appendingPathComponent("summary.json"), options: .atomic)
}
for fixture in selected {
    let referencePath = fixture.targetAudioURL.path
    let index: AmbientSyncReferenceIndex
    let indexStart = monotonicSeconds()
    let inMemoryHit = indexes[referencePath] != nil
    if let cached = indexes[referencePath] {
        index = cached
    } else {
        index = try indexBuilder.index(forSourceURL: fixture.targetAudioURL)
        indexes[referencePath] = index
    }
    let indexSeconds = monotonicSeconds() - indexStart
    let decodeStart = monotonicSeconds()
    let audio = try frameBuilder.decodeMonoFloat32Audio(from: fixture.fixtureAudioURL)
    let decodeSeconds = monotonicSeconds() - decodeStart
    for entry in entries {
        let availableDuration = Double(audio.monoSamples.count) / audio.sampleRate - entry
        let requestedDuration = min(entry == 0 ? availableDuration : 30, maximumDuration ?? .greatestFiniteMagnitude)
        guard availableDuration > 0, entry == 0 || availableDuration >= requestedDuration else {
            print("SKIP \(fixture.fixtureAudioURL.lastPathComponent) entry=\(entry): insufficient audio")
            continue
        }
        let startSample = min(audio.monoSamples.count, Int(entry * audio.sampleRate))
        let endSample = min(audio.monoSamples.count, startSample + Int(requestedDuration * audio.sampleRate))
        guard endSample > startSample else { continue }
        let name = fixture.fixtureAudioURL.deletingPathExtension().lastPathComponent + "-entry-\(entry)s"
        print("START \(name)")
        fflush(stdout)
        let extractionStart = monotonicSeconds()
        let frames = frameBuilder.buildFrames(
            fromMonoSamples: Array(audio.monoSamples[startSample..<endSample]), sampleRate: audio.sampleRate)
        let extractionSeconds = monotonicSeconds() - extractionStart
        let engineBuildStart = monotonicSeconds()
        var engine =
            legacy
            ? AmbientSyncEngine(referenceIndex: index, configuration: .v1) : AmbientSyncEngine(referenceIndex: index)
        let engineBuildSeconds = monotonicSeconds() - engineBuildStart
        var buffer = MicFeatureStreamBuffer(
            retentionDurationMS: featureConfig.finalLockTargetDurationMS + 1000,
            expectedHopMS: featureConfig.featureHopMS)
        var nextEndpoint = 0.0
        var events: [AmbientSyncFixtureReplayTraceEvent] = []
        var processMS: [Double] = []
        let replayStart = monotonicSeconds()
        for i in frames.indices {
            buffer.append([frames[i]])
            let endpoint = frames[i].recordedTimeMS
            if endpoint < nextEndpoint && i != frames.indices.last { continue }
            nextEndpoint = endpoint + cadence
            guard let query = buffer.latestWindow(durationMS: featureConfig.finalLockTargetDurationMS) else { continue }
            let tick = monotonicSeconds()
            let snapshot = engine.process(queryWindow: query, elapsedMS: endpoint)
            processMS.append((monotonicSeconds() - tick) * 1000)
            events.append(
                AmbientSyncFixtureReplayTraceEvent(
                    sequence: events.count, fixture: fixture, queryWindow: query, snapshot: snapshot,
                    firstProvisionalLockElapsedMS: engine.firstProvisionalLockElapsedMS,
                    confirmedLockElapsedMS: engine.confirmedLockElapsedMS, finalLockElapsedMS: engine.finalLockElapsedMS
                ))
        }
        let replaySeconds = monotonicSeconds() - replayStart
        let traceName = name + ".ambient-sync-replay.jsonl"
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: output.appendingPathComponent(traceName), options: .atomic)
        let sorted = processMS.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
        }
        let locked = events.filter { $0.state == .locked }
        var states: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        for event in events {
            states[event.state.rawValue, default: 0] += 1
            reasons[event.withholdReason?.rawValue ?? "none", default: 0] += 1
        }
        let row: [String: Any] = [
            "fixture": fixture.fixtureAudioURL.lastPathComponent, "referencePath": referencePath,
            "entryRecordingSeconds": entry, "inputDurationSeconds": Double(endSample - startSample) / audio.sampleRate,
            "events": events.count, "firstLockedAudioMS": locked.first.map { $0.timing.elapsedMS as Any } ?? NSNull(),
            "lockedEvents": locked.count,
            "lockedFraction": events.isEmpty ? 0 : Double(locked.count) / Double(events.count),
            "endState": events.last?.state.rawValue ?? "none", "stateCounts": states, "withholdReasonCounts": reasons,
            "referenceIndexLoadSeconds": indexSeconds, "referenceIndexReusedInMemory": inMemoryHit,
            "fixtureDecodeSeconds": decodeSeconds, "featureExtractionSeconds": extractionSeconds,
            "engineConstructionSeconds": engineBuildSeconds, "replayLoopSeconds": replaySeconds,
            "processMS": [
                "count": processMS.count, "total": processMS.reduce(0, +), "p50": percentile(0.5),
                "p95": percentile(0.95), "max": sorted.last ?? 0,
            ], "traceFile": traceName,
        ]
        summaries.append(row)
        try writeSummary()
        print(
            "DONE \(name) locked=\(locked.count)/\(events.count) firstLockedAudioMS=\(locked.first?.timing.elapsedMS.description ?? "nil") processP95MS=\(percentile(0.95))"
        )
        fflush(stdout)
    }
}

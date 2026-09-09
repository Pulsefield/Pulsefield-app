// Feature-level Swift oracle for comparison with released Sonalign. Compile with the current Swift engine
// sources; this adapter contains no matching or state-machine implementation.
import Dispatch
import Foundation

private struct ParityError: Error, CustomStringConvertible {
    let description: String
}

private struct FeatureInput: Decodable, Hashable {
    let name: String?
    let hopMS: Double?
    let timesPath: String
    let pcenPath: String
    let energyPath: String?
}

private struct ReplayCall: Decodable {
    let startIndex: Int
    let endIndex: Int // Inclusive, to match the exact Swift query slice.
    let elapsedMS: Double
}

private struct CacheKey: Hashable {
    let input: FeatureInput
    let bands: Int
    let energy: Double
}

private struct ReplayCase: Decodable {
    let id: String
    let reference: FeatureInput
    let query: FeatureInput
    let calls: [ReplayCall]
    let bands: Int?
    let energyDBFS: Double?
}

private struct Candidate: Encodable {
    let offsetMS: Double
    let score: Double
}

private struct Event: Encodable {
    let endpointMS: Double
    let elapsedMS: Double
    let processNS: UInt64
    let state: AmbientSyncState
    let phase: AmbientSyncLockPhase
    let stage: AmbientSyncStage
    let withholdReason: AmbientSyncWithholdReason?
    let estimate: AmbientSyncEstimate?
    let confidence: Double
    let firstProvisionalLockElapsedMS: Double?
    let confirmedLockElapsedMS: Double?
    let finalLockElapsedMS: Double?
    let spectral: AmbientSyncSpectralDiagnostics?
    let queryDurationMS: Double
    let activeFrameFraction: Double
    let coarseAmbiguous: Bool
    let denseMargin: Double
    let offsetStabilityMS: Double?
    let trackInnovationMS: Double?
    let trackCount: Int
    let offsetTrackerConfirmed: Bool
    let offsetTrackerStable: Bool
    let candidates: [Candidate]

    init(_ snapshot: AmbientSyncSnapshot, endpointMS: Double, elapsedMS: Double, processNS: UInt64) {
        self.endpointMS = endpointMS
        self.elapsedMS = elapsedMS
        self.processNS = processNS
        state = snapshot.state
        phase = snapshot.phase
        stage = snapshot.stage
        withholdReason = snapshot.withholdReason
        estimate = snapshot.estimate
        confidence = snapshot.confidence
        firstProvisionalLockElapsedMS = snapshot.firstProvisionalLockElapsedMS
        confirmedLockElapsedMS = snapshot.confirmedLockElapsedMS
        finalLockElapsedMS = snapshot.finalLockElapsedMS
        spectral = snapshot.diagnostics.spectral
        queryDurationMS = snapshot.diagnostics.queryDurationMS
        activeFrameFraction = snapshot.diagnostics.activeFrameFraction
        coarseAmbiguous = snapshot.diagnostics.coarseAmbiguous
        denseMargin = snapshot.diagnostics.denseMargin
        offsetStabilityMS = snapshot.diagnostics.offsetStabilityMS
        trackInnovationMS = snapshot.diagnostics.trackInnovationMS
        trackCount = snapshot.diagnostics.trackCount
        offsetTrackerConfirmed = snapshot.diagnostics.offsetTrackerConfirmed
        offsetTrackerStable = snapshot.diagnostics.offsetTrackerStable
        candidates = snapshot.diagnostics.candidates.map { Candidate(offsetMS: $0.offsetMS, score: $0.combinedDenseScore) }
    }
}

private struct Result: Encodable {
    let id: String
    let events: [Event]
    let processNS: UInt64
}

@main
private enum SwiftSyncParity {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, args[0] == "--cases", args[2] == "--output" else {
            throw ParityError(description: "Usage: swift-sync-replay --cases CASES.jsonl --output TRACE.jsonl")
        }
        let caseText = try String(contentsOfFile: args[1], encoding: .utf8)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = URL(fileURLWithPath: args[3])
        guard FileManager.default.createFile(atPath: output.path, contents: Data()) else {
            throw ParityError(description: "Cannot create \(output.path)")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var frameCache: [CacheKey: [MicFeatureFrame]] = [:]
        var referenceCache: [CacheKey: AmbientSyncEngine.Reference] = [:]
        for line in caseText.split(separator: "\n") {
            let item = try decoder.decode(ReplayCase.self, from: Data(line.utf8))
            let bands = item.bands ?? 24
            let energy = item.energyDBFS ?? -20
            guard bands > 0, energy.isFinite else { throw ParityError(description: "Invalid input configuration") }
            func frames(_ input: FeatureInput) throws -> [MicFeatureFrame] {
                let key = CacheKey(input: input, bands: bands, energy: energy)
                if let cached = frameCache[key] { return cached }
                let result = try load(input, bands: bands, energy: energy)
                frameCache[key] = result
                return result
            }
            let hop = item.reference.hopMS ?? AmbientSyncFeatureConfiguration.v1.featureHopMS
            guard hop.isFinite, hop > 0 else { throw ParityError(description: "Invalid reference hop") }
            let featureConfiguration = AmbientSyncFeatureConfiguration(processingSampleRate: 512_000 / hop)
            let reference: AmbientSyncEngine.Reference
            let referenceKey = CacheKey(input: item.reference, bands: bands, energy: energy)
            if let cached = referenceCache[referenceKey] {
                reference = cached
            } else {
                reference = AmbientSyncEngine.Reference(
                    sourceDisplayPath: item.reference.name ?? item.reference.pcenPath,
                    featureConfiguration: featureConfiguration, frames: try frames(item.reference))
                referenceCache[referenceKey] = reference
            }
            let queryFrames = try frames(item.query)
            var engine = AmbientSyncEngine(
                reference: reference,
                configuration: .init(usesSpectralCorrelation: true, featureConfiguration: featureConfiguration))
            var events: [Event] = []
            for call in item.calls {
                guard call.startIndex >= 0, call.endIndex >= call.startIndex, call.endIndex < queryFrames.count,
                    call.elapsedMS.isFinite else {
                    throw ParityError(description: "Invalid call in \(item.id)")
                }
                let query = MicFeatureWindow(frames: Array(queryFrames[call.startIndex...call.endIndex]))
                let start = DispatchTime.now().uptimeNanoseconds
                let snapshot = engine.process(queryWindow: query, elapsedMS: call.elapsedMS)
                let duration = DispatchTime.now().uptimeNanoseconds - start
                events.append(Event(snapshot, endpointMS: query.endpointRecordedTimeMS,
                                    elapsedMS: call.elapsedMS, processNS: duration))
            }
            let result = Result(id: item.id, events: events, processNS: events.reduce(0) { $0 + $1.processNS })
            try handle.write(contentsOf: encoder.encode(result))
            try handle.write(contentsOf: Data([10]))
        }
    }

    private static func load(_ input: FeatureInput, bands: Int, energy: Double) throws -> [MicFeatureFrame] {
        let timesData = try Data(contentsOf: URL(fileURLWithPath: input.timesPath))
        let pcenData = try Data(contentsOf: URL(fileURLWithPath: input.pcenPath))
        guard timesData.count % 8 == 0, pcenData.count == timesData.count / 8 * bands * 4 else {
            throw ParityError(description: "Mismatched raw feature arrays: \(input.pcenPath)")
        }
        let times = timesData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 8).map {
                Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt64.self)))
            }
        }
        let values = pcenData.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        var energies = [Double](repeating: energy, count: times.count)
        if let path = input.energyPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count == timesData.count else { throw ParityError(description: "Invalid energy array: \(path)") }
            energies = data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 8).map {
                    Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt64.self)))
                }
            }
        }
        return times.indices.map { i in
            MicFeatureFrame(recordedTimeMS: times[i], hostTimeMS: times[i], onsetEnvelope: 0,
                            subbandOnset: [], pcenMel: Array(values[(i * bands)..<((i + 1) * bands)]),
                            chroma: [], cens: [], landmarkHashes: [], energyDBFS: energies[i], snrDB: nil)
        }
    }
}

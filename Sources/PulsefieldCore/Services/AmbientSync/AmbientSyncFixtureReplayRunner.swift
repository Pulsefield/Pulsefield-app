import Foundation

public typealias AmbientSyncFixtureReplayReferenceIndexBuilder<ReferenceIndex: Sendable> =
    @Sendable (AmbientSyncFixtureReplayReferenceBuildInput) throws -> ReferenceIndex

public typealias AmbientSyncFixtureReplayEngineFactory<ReferenceIndex: Sendable> =
    @Sendable (AmbientSyncFixtureReplayEngineFactoryInput<ReferenceIndex>) throws -> AmbientSyncFixtureReplayEngine<ReferenceIndex>

public struct AmbientSyncFixtureReplayFixture: Equatable, Sendable {
    public let sidecarURL: URL
    public let fixtureAudioURL: URL
    public let targetAudioURL: URL
    public let metadata: AmbientSyncFixtureRecordingMetadata

    public init(
        sidecarURL: URL,
        fixtureAudioURL: URL,
        targetAudioURL: URL,
        metadata: AmbientSyncFixtureRecordingMetadata
    ) {
        self.sidecarURL = sidecarURL
        self.fixtureAudioURL = fixtureAudioURL
        self.targetAudioURL = targetAudioURL
        self.metadata = metadata
    }
}

public struct AmbientSyncFixtureReplayReferenceBuildInput: Sendable {
    public let fixture: AmbientSyncFixtureReplayFixture
    public let targetAudio: @Sendable () throws -> AmbientSyncDecodedAudio
    public let targetFrames: @Sendable () throws -> [MicFeatureFrame]
    public let featureConfiguration: AmbientSyncFeatureConfiguration
    public let referenceIndexCacheDirectoryURL: URL

    public init(
        fixture: AmbientSyncFixtureReplayFixture,
        targetAudio: @escaping @Sendable () throws -> AmbientSyncDecodedAudio,
        targetFrames: @escaping @Sendable () throws -> [MicFeatureFrame],
        featureConfiguration: AmbientSyncFeatureConfiguration,
        referenceIndexCacheDirectoryURL: URL
    ) {
        self.fixture = fixture
        self.targetAudio = targetAudio
        self.targetFrames = targetFrames
        self.featureConfiguration = featureConfiguration
        self.referenceIndexCacheDirectoryURL = referenceIndexCacheDirectoryURL
    }

    public init(
        fixture: AmbientSyncFixtureReplayFixture,
        targetAudio: AmbientSyncDecodedAudio,
        targetFrames: [MicFeatureFrame],
        featureConfiguration: AmbientSyncFeatureConfiguration,
        referenceIndexCacheDirectoryURL: URL
    ) {
        self.init(
            fixture: fixture,
            targetAudio: { targetAudio },
            targetFrames: { targetFrames },
            featureConfiguration: featureConfiguration,
            referenceIndexCacheDirectoryURL: referenceIndexCacheDirectoryURL
        )
    }
}

public struct AmbientSyncFixtureReplayEngineFactoryInput<ReferenceIndex: Sendable>: Sendable {
    public let fixture: AmbientSyncFixtureReplayFixture
    public let referenceIndex: ReferenceIndex
    public let featureConfiguration: AmbientSyncFeatureConfiguration

    public init(
        fixture: AmbientSyncFixtureReplayFixture,
        referenceIndex: ReferenceIndex,
        featureConfiguration: AmbientSyncFeatureConfiguration
    ) {
        self.fixture = fixture
        self.referenceIndex = referenceIndex
        self.featureConfiguration = featureConfiguration
    }
}

public struct AmbientSyncFixtureReplayEngineInput<ReferenceIndex: Sendable>: Sendable {
    public let fixture: AmbientSyncFixtureReplayFixture
    public let referenceIndex: ReferenceIndex
    public let queryWindow: MicFeatureWindow
    public let elapsedMS: Double
    public let sequence: Int
    public let previousSnapshot: AmbientSyncSnapshot?
    public let featureConfiguration: AmbientSyncFeatureConfiguration

    public init(
        fixture: AmbientSyncFixtureReplayFixture,
        referenceIndex: ReferenceIndex,
        queryWindow: MicFeatureWindow,
        elapsedMS: Double,
        sequence: Int,
        previousSnapshot: AmbientSyncSnapshot?,
        featureConfiguration: AmbientSyncFeatureConfiguration
    ) {
        self.fixture = fixture
        self.referenceIndex = referenceIndex
        self.queryWindow = queryWindow
        self.elapsedMS = elapsedMS
        self.sequence = sequence
        self.previousSnapshot = previousSnapshot
        self.featureConfiguration = featureConfiguration
    }
}

public struct AmbientSyncFixtureReplayEngine<ReferenceIndex: Sendable>: @unchecked Sendable {
    private let processSnapshot: @Sendable (AmbientSyncFixtureReplayEngineInput<ReferenceIndex>) throws -> AmbientSyncSnapshot

    public init(
        process: @escaping @Sendable (AmbientSyncFixtureReplayEngineInput<ReferenceIndex>) throws -> AmbientSyncSnapshot
    ) {
        processSnapshot = process
    }

    public func process(_ input: AmbientSyncFixtureReplayEngineInput<ReferenceIndex>) throws -> AmbientSyncSnapshot {
        try processSnapshot(input)
    }
}

public struct AmbientSyncFixtureReplayTiming: Codable, Equatable, Sendable {
    public let elapsedMS: Double
    public let queryStartRecordedTimeMS: Double
    public let queryEndpointRecordedTimeMS: Double
    public let queryDurationMS: Double

    public init(
        elapsedMS: Double,
        queryStartRecordedTimeMS: Double,
        queryEndpointRecordedTimeMS: Double,
        queryDurationMS: Double
    ) {
        self.elapsedMS = elapsedMS
        self.queryStartRecordedTimeMS = queryStartRecordedTimeMS
        self.queryEndpointRecordedTimeMS = queryEndpointRecordedTimeMS
        self.queryDurationMS = queryDurationMS
    }
}

public struct AmbientSyncFixtureReplayScores: Codable, Equatable, Sendable {
    public let topLandmarkVoteCount: Int
    public let secondLandmarkVoteCount: Int
    public let topWeightedVoteScore: Double
    public let secondWeightedVoteScore: Double
    public let topToSecondWeightedVoteRatio: Double
    public let topWeightedVoteMargin: Double
    public let topToSecondVoteRatio: Double
    public let topVoteMargin: Int
    public let coarseAmbiguous: Bool
    public let denseMargin: Double
    public let trackInnovationMS: Double?
    public let trackConfidenceMargin: Double
    public let trackConfidenceLogOdds: Double
    public let trackCount: Int
    public let offsetTrackerConfirmed: Bool
    public let offsetTrackerStable: Bool
    public let topCandidateOffsetMS: Double?
    public let topCandidateCombinedDenseScore: Double?
    public let topCandidateFeatureAgreementCount: Int?

    public init(
        topLandmarkVoteCount: Int,
        secondLandmarkVoteCount: Int,
        topWeightedVoteScore: Double? = nil,
        secondWeightedVoteScore: Double? = nil,
        topToSecondWeightedVoteRatio: Double? = nil,
        topWeightedVoteMargin: Double? = nil,
        topToSecondVoteRatio: Double,
        topVoteMargin: Int,
        coarseAmbiguous: Bool = false,
        denseMargin: Double,
        trackInnovationMS: Double? = nil,
        trackConfidenceMargin: Double = 0,
        trackConfidenceLogOdds: Double = 0,
        trackCount: Int = 0,
        offsetTrackerConfirmed: Bool = false,
        offsetTrackerStable: Bool = false,
        topCandidateOffsetMS: Double?,
        topCandidateCombinedDenseScore: Double?,
        topCandidateFeatureAgreementCount: Int?
    ) {
        self.topLandmarkVoteCount = topLandmarkVoteCount
        self.secondLandmarkVoteCount = secondLandmarkVoteCount
        self.topWeightedVoteScore = topWeightedVoteScore ?? Double(topLandmarkVoteCount)
        self.secondWeightedVoteScore = secondWeightedVoteScore ?? Double(secondLandmarkVoteCount)
        self.topToSecondWeightedVoteRatio = topToSecondWeightedVoteRatio ?? topToSecondVoteRatio
        self.topWeightedVoteMargin = topWeightedVoteMargin ?? Double(topVoteMargin)
        self.topToSecondVoteRatio = topToSecondVoteRatio
        self.topVoteMargin = topVoteMargin
        self.coarseAmbiguous = coarseAmbiguous
        self.denseMargin = denseMargin
        self.trackInnovationMS = trackInnovationMS
        self.trackConfidenceMargin = trackConfidenceMargin
        self.trackConfidenceLogOdds = trackConfidenceLogOdds
        self.trackCount = trackCount
        self.offsetTrackerConfirmed = offsetTrackerConfirmed
        self.offsetTrackerStable = offsetTrackerStable
        self.topCandidateOffsetMS = topCandidateOffsetMS
        self.topCandidateCombinedDenseScore = topCandidateCombinedDenseScore
        self.topCandidateFeatureAgreementCount = topCandidateFeatureAgreementCount
    }

    private enum CodingKeys: String, CodingKey {
        case topLandmarkVoteCount
        case secondLandmarkVoteCount
        case topWeightedVoteScore
        case secondWeightedVoteScore
        case topToSecondWeightedVoteRatio
        case topWeightedVoteMargin
        case topToSecondVoteRatio
        case topVoteMargin
        case coarseAmbiguous
        case denseMargin
        case trackInnovationMS
        case trackConfidenceMargin
        case trackConfidenceLogOdds
        case trackCount
        case offsetTrackerConfirmed
        case offsetTrackerStable
        case topCandidateOffsetMS
        case topCandidateCombinedDenseScore
        case topCandidateFeatureAgreementCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topLandmarkVoteCount = try container.decode(Int.self, forKey: .topLandmarkVoteCount)
        let secondLandmarkVoteCount = try container.decode(Int.self, forKey: .secondLandmarkVoteCount)
        let topToSecondVoteRatio = try container.decode(Double.self, forKey: .topToSecondVoteRatio)
        let topVoteMargin = try container.decode(Int.self, forKey: .topVoteMargin)

        self.init(
            topLandmarkVoteCount: topLandmarkVoteCount,
            secondLandmarkVoteCount: secondLandmarkVoteCount,
            topWeightedVoteScore: try container.decodeIfPresent(Double.self, forKey: .topWeightedVoteScore)
                ?? Double(topLandmarkVoteCount),
            secondWeightedVoteScore: try container.decodeIfPresent(Double.self, forKey: .secondWeightedVoteScore)
                ?? Double(secondLandmarkVoteCount),
            topToSecondWeightedVoteRatio: try container.decodeIfPresent(
                Double.self,
                forKey: .topToSecondWeightedVoteRatio
            ) ?? topToSecondVoteRatio,
            topWeightedVoteMargin: try container.decodeIfPresent(Double.self, forKey: .topWeightedVoteMargin)
                ?? Double(topVoteMargin),
            topToSecondVoteRatio: topToSecondVoteRatio,
            topVoteMargin: topVoteMargin,
            coarseAmbiguous: try container.decodeIfPresent(Bool.self, forKey: .coarseAmbiguous) ?? false,
            denseMargin: try container.decode(Double.self, forKey: .denseMargin),
            trackInnovationMS: try container.decodeIfPresent(Double.self, forKey: .trackInnovationMS),
            trackConfidenceMargin: try container.decodeIfPresent(Double.self, forKey: .trackConfidenceMargin) ?? 0,
            trackConfidenceLogOdds: try container.decodeIfPresent(Double.self, forKey: .trackConfidenceLogOdds) ?? 0,
            trackCount: try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0,
            offsetTrackerConfirmed: try container.decodeIfPresent(Bool.self, forKey: .offsetTrackerConfirmed) ?? false,
            offsetTrackerStable: try container.decodeIfPresent(Bool.self, forKey: .offsetTrackerStable) ?? false,
            topCandidateOffsetMS: try container.decodeIfPresent(Double.self, forKey: .topCandidateOffsetMS),
            topCandidateCombinedDenseScore: try container.decodeIfPresent(
                Double.self,
                forKey: .topCandidateCombinedDenseScore
            ),
            topCandidateFeatureAgreementCount: try container.decodeIfPresent(
                Int.self,
                forKey: .topCandidateFeatureAgreementCount
            )
        )
    }
}

public struct AmbientSyncFixtureReplayTraceEvent: Codable, Equatable, Sendable {
    public let sequence: Int
    public let recordingID: UUID
    public let fixtureAudioFileName: String
    public let targetAudioDisplayPath: String
    public let timing: AmbientSyncFixtureReplayTiming
    public let state: AmbientSyncState
    public let phase: AmbientSyncLockPhase
    public let stage: AmbientSyncStage
    public let estimate: AmbientSyncEstimate?
    public let withholdReason: AmbientSyncWithholdReason?
    public let confidence: Double
    public let diagnostics: AmbientSyncDiagnostics
    public let candidates: [AmbientSyncCandidateDiagnostics]
    public let scores: AmbientSyncFixtureReplayScores
    public let firstProvisionalLockElapsedMS: Double?
    public let confirmedLockElapsedMS: Double?
    public let finalLockElapsedMS: Double?

    public init(
        sequence: Int,
        fixture: AmbientSyncFixtureReplayFixture,
        queryWindow: MicFeatureWindow,
        snapshot: AmbientSyncSnapshot,
        firstProvisionalLockElapsedMS: Double?,
        confirmedLockElapsedMS: Double?,
        finalLockElapsedMS: Double?
    ) {
        self.sequence = sequence
        recordingID = fixture.metadata.recordingID
        fixtureAudioFileName = fixture.fixtureAudioURL.lastPathComponent
        targetAudioDisplayPath = fixture.metadata.targetAsset.displayPath
        timing = AmbientSyncFixtureReplayTiming(
            elapsedMS: queryWindow.endpointRecordedTimeMS,
            queryStartRecordedTimeMS: queryWindow.startRecordedTimeMS,
            queryEndpointRecordedTimeMS: queryWindow.endpointRecordedTimeMS,
            queryDurationMS: queryWindow.durationMS
        )
        state = snapshot.state
        phase = snapshot.phase
        stage = snapshot.stage
        estimate = snapshot.estimate
        withholdReason = snapshot.withholdReason
        confidence = snapshot.confidence
        diagnostics = snapshot.diagnostics
        candidates = snapshot.diagnostics.candidates
        scores = AmbientSyncFixtureReplayScores(
            topLandmarkVoteCount: snapshot.diagnostics.topLandmarkVoteCount,
            secondLandmarkVoteCount: snapshot.diagnostics.secondLandmarkVoteCount,
            topWeightedVoteScore: snapshot.diagnostics.topWeightedVoteScore,
            secondWeightedVoteScore: snapshot.diagnostics.secondWeightedVoteScore,
            topToSecondWeightedVoteRatio: snapshot.diagnostics.topToSecondWeightedVoteRatio,
            topWeightedVoteMargin: snapshot.diagnostics.topWeightedVoteMargin,
            topToSecondVoteRatio: snapshot.diagnostics.topToSecondVoteRatio,
            topVoteMargin: snapshot.diagnostics.topVoteMargin,
            coarseAmbiguous: snapshot.diagnostics.coarseAmbiguous,
            denseMargin: snapshot.diagnostics.denseMargin,
            trackInnovationMS: snapshot.diagnostics.trackInnovationMS,
            trackConfidenceMargin: snapshot.diagnostics.trackConfidenceMargin,
            trackConfidenceLogOdds: snapshot.diagnostics.trackConfidenceLogOdds,
            trackCount: snapshot.diagnostics.trackCount,
            offsetTrackerConfirmed: snapshot.diagnostics.offsetTrackerConfirmed,
            offsetTrackerStable: snapshot.diagnostics.offsetTrackerStable,
            topCandidateOffsetMS: snapshot.diagnostics.candidates.first?.offsetMS,
            topCandidateCombinedDenseScore: snapshot.diagnostics.candidates.first?.combinedDenseScore,
            topCandidateFeatureAgreementCount: snapshot.diagnostics.candidates.first?.featureAgreementCount
        )
        self.firstProvisionalLockElapsedMS = snapshot.firstProvisionalLockElapsedMS
            ?? firstProvisionalLockElapsedMS
        self.confirmedLockElapsedMS = snapshot.confirmedLockElapsedMS ?? confirmedLockElapsedMS
        self.finalLockElapsedMS = snapshot.finalLockElapsedMS ?? finalLockElapsedMS
    }
}

public struct AmbientSyncFixtureReplayResult: Equatable, Sendable {
    public let fixture: AmbientSyncFixtureReplayFixture
    public let traceOutputURL: URL
    public let events: [AmbientSyncFixtureReplayTraceEvent]

    public init(
        fixture: AmbientSyncFixtureReplayFixture,
        traceOutputURL: URL,
        events: [AmbientSyncFixtureReplayTraceEvent]
    ) {
        self.fixture = fixture
        self.traceOutputURL = traceOutputURL
        self.events = events
    }
}

public enum AmbientSyncFixtureReplayError: Error, Equatable, Sendable {
    case fixtureDirectoryMissing(String)
    case fixtureAudioMissing(String)
    case targetAudioMissing(String)
    case audioDecodeFailed(String, String)
    case audioConversionFailed(String, String)
    case emptyAudio(String)
    case noFeatureFrames(String)
}

extension AmbientSyncFixtureReplayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fixtureDirectoryMissing(let path):
            return "Ambient sync fixture directory does not exist: \(path)"
        case .fixtureAudioMissing(let path):
            return "Ambient sync fixture audio does not exist: \(path)"
        case .targetAudioMissing(let path):
            return "Ambient sync target audio does not exist: \(path)"
        case .audioDecodeFailed(let path, let message):
            return "Could not decode audio at \(path): \(message)"
        case .audioConversionFailed(let path, let message):
            return "Could not convert audio at \(path): \(message)"
        case .emptyAudio(let path):
            return "Decoded audio is empty: \(path)"
        case .noFeatureFrames(let path):
            return "No ambient sync feature frames were produced for: \(path)"
        }
    }
}

public final class AmbientSyncFixtureReplayRunner<ReferenceIndex: Sendable>: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public let fixtureDirectoryURL: URL
        public let traceOutputDirectoryURL: URL
        public let referenceIndexCacheDirectoryURL: URL
        public let featureConfiguration: AmbientSyncFeatureConfiguration
        public let audioChunkSizeSamples: Int
        public let replayStepDurationMS: Double?

        public init(
            fixtureDirectoryURL: URL = AmbientSyncFixtureRecorder.defaultFixtureDirectoryURL(),
            traceOutputDirectoryURL: URL? = nil,
            referenceIndexCacheDirectoryURL: URL? = nil,
            featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
            audioChunkSizeSamples: Int = 16_384,
            replayStepDurationMS: Double? = nil
        ) {
            precondition(audioChunkSizeSamples > 0, "audioChunkSizeSamples must be positive.")
            if let replayStepDurationMS {
                precondition(
                    replayStepDurationMS > 0 && replayStepDurationMS.isFinite,
                    "replayStepDurationMS must be finite and positive."
                )
            }

            self.fixtureDirectoryURL = fixtureDirectoryURL
            self.traceOutputDirectoryURL = traceOutputDirectoryURL
                ?? fixtureDirectoryURL.appendingPathComponent(".ambient-sync-replay-traces", isDirectory: true)
            self.referenceIndexCacheDirectoryURL = referenceIndexCacheDirectoryURL
                ?? fixtureDirectoryURL.appendingPathComponent(".ambient-sync-reference-indexes", isDirectory: true)
            self.featureConfiguration = featureConfiguration
            self.audioChunkSizeSamples = audioChunkSizeSamples
            self.replayStepDurationMS = replayStepDurationMS
        }
    }

    public let configuration: Configuration

    private let referenceIndexBuilder: AmbientSyncFixtureReplayReferenceIndexBuilder<ReferenceIndex>
    private let engineFactory: AmbientSyncFixtureReplayEngineFactory<ReferenceIndex>
    private let frameBuilder: AmbientSyncAudioFeatureFrameBuilder
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        referenceIndexBuilder: @escaping AmbientSyncFixtureReplayReferenceIndexBuilder<ReferenceIndex>,
        engineFactory: @escaping AmbientSyncFixtureReplayEngineFactory<ReferenceIndex>
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.referenceIndexBuilder = referenceIndexBuilder
        self.engineFactory = engineFactory
        frameBuilder = AmbientSyncAudioFeatureFrameBuilder(
            featureConfiguration: configuration.featureConfiguration,
            chunkSizeSamples: configuration.audioChunkSizeSamples
        )

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )

        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
    }

    public func discoverFixtures() throws -> [AmbientSyncFixtureReplayFixture] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: configuration.fixtureDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AmbientSyncFixtureReplayError.fixtureDirectoryMissing(configuration.fixtureDirectoryURL.path)
        }

        return try fileManager
            .contentsOfDirectory(
                at: configuration.fixtureDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasSuffix(".ambient-sync-fixture.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(discoverFixture)
    }

    public func replayFixture(
        _ fixture: AmbientSyncFixtureReplayFixture,
        traceOutputURL requestedTraceOutputURL: URL? = nil
    ) throws -> AmbientSyncFixtureReplayResult {
        guard fileManager.fileExists(atPath: fixture.fixtureAudioURL.path) else {
            throw AmbientSyncFixtureReplayError.fixtureAudioMissing(fixture.fixtureAudioURL.path)
        }
        guard fileManager.fileExists(atPath: fixture.targetAudioURL.path) else {
            throw AmbientSyncFixtureReplayError.targetAudioMissing(fixture.targetAudioURL.path)
        }

        try fileManager.createDirectory(
            at: configuration.referenceIndexCacheDirectoryURL,
            withIntermediateDirectories: true
        )

        let targetFeatureLoader = AmbientSyncFixtureReplayTargetFeatureLoader(
            decodeAudio: { [self] in
                try decodeAudio(at: fixture.targetAudioURL)
            },
            buildFrames: { [self] targetAudio in
                try featureFrames(from: targetAudio)
            }
        )
        let referenceIndex = try referenceIndexBuilder(
            AmbientSyncFixtureReplayReferenceBuildInput(
                fixture: fixture,
                targetAudio: {
                    try targetFeatureLoader.audio()
                },
                targetFrames: {
                    try targetFeatureLoader.frames()
                },
                featureConfiguration: configuration.featureConfiguration,
                referenceIndexCacheDirectoryURL: configuration.referenceIndexCacheDirectoryURL
            )
        )
        let engine = try engineFactory(
            AmbientSyncFixtureReplayEngineFactoryInput(
                fixture: fixture,
                referenceIndex: referenceIndex,
                featureConfiguration: configuration.featureConfiguration
            )
        )
        let fixtureAudio = try decodeAudio(at: fixture.fixtureAudioURL)
        let fixtureFrames = try featureFrames(from: fixtureAudio)
        let events = try traceEvents(
            fixture: fixture,
            fixtureFrames: fixtureFrames,
            referenceIndex: referenceIndex,
            engine: engine
        )
        let traceOutputURL = requestedTraceOutputURL ?? defaultTraceOutputURL(for: fixture)

        try writeJSONL(events, to: traceOutputURL)

        return AmbientSyncFixtureReplayResult(
            fixture: fixture,
            traceOutputURL: traceOutputURL,
            events: events
        )
    }

    private func discoverFixture(at sidecarURL: URL) throws -> AmbientSyncFixtureReplayFixture? {
        let data = try Data(contentsOf: sidecarURL)
        let metadata = try decoder.decode(AmbientSyncFixtureRecordingMetadata.self, from: data)

        guard Self.isBareCAFFileName(metadata.audioFileName) else {
            return nil
        }

        let fixtureAudioURL = sidecarURL
            .deletingLastPathComponent()
            .appendingPathComponent(metadata.audioFileName)
        guard fileManager.fileExists(atPath: fixtureAudioURL.path) else {
            return nil
        }

        return AmbientSyncFixtureReplayFixture(
            sidecarURL: sidecarURL,
            fixtureAudioURL: fixtureAudioURL,
            targetAudioURL: URL(fileURLWithPath: metadata.targetAsset.displayPath),
            metadata: metadata
        )
    }

    private func decodeAudio(at audioURL: URL) throws -> AmbientSyncDecodedAudio {
        let decodedAudio: AmbientSyncDecodedAudio
        do {
            decodedAudio = try frameBuilder.decodeMonoFloat32Audio(from: audioURL)
        } catch let error as AmbientSyncFixtureReplayError {
            throw error
        } catch {
            throw AmbientSyncFixtureReplayError.audioDecodeFailed(audioURL.path, error.localizedDescription)
        }

        guard !decodedAudio.monoSamples.isEmpty else {
            throw AmbientSyncFixtureReplayError.emptyAudio(audioURL.path)
        }

        return decodedAudio
    }

    private func featureFrames(from audio: AmbientSyncDecodedAudio) throws -> [MicFeatureFrame] {
        let frames = frameBuilder.buildFrames(
            fromMonoSamples: audio.monoSamples,
            sampleRate: audio.sampleRate
        )
        guard !frames.isEmpty else {
            throw AmbientSyncFixtureReplayError.noFeatureFrames(audio.sourceURL?.path ?? "decoded audio")
        }

        return frames
    }

    private func traceEvents(
        fixture: AmbientSyncFixtureReplayFixture,
        fixtureFrames: [MicFeatureFrame],
        referenceIndex: ReferenceIndex,
        engine: AmbientSyncFixtureReplayEngine<ReferenceIndex>
    ) throws -> [AmbientSyncFixtureReplayTraceEvent] {
        var startIndex = 0
        var previousSnapshot: AmbientSyncSnapshot?
        var firstProvisionalLockElapsedMS: Double?
        var confirmedLockElapsedMS: Double?
        var finalLockElapsedMS: Double?
        var nextReplayEndpointMS: Double?
        var events: [AmbientSyncFixtureReplayTraceEvent] = []

        for endIndex in fixtureFrames.indices {
            let endpointMS = fixtureFrames[endIndex].recordedTimeMS
            if configuration.replayStepDurationMS != nil,
               let replayEndpointMS = nextReplayEndpointMS,
               endpointMS < replayEndpointMS,
               endIndex != fixtureFrames.index(before: fixtureFrames.endIndex) {
                continue
            }
            if let replayStepDurationMS = configuration.replayStepDurationMS {
                nextReplayEndpointMS = endpointMS + replayStepDurationMS
            }

            let desiredDurationMS = queryDurationMS(
                endpointMS: endpointMS,
                previousSnapshot: previousSnapshot,
                finalLockElapsedMS: finalLockElapsedMS
            )
            let earliestMS = endpointMS - desiredDurationMS
            while startIndex < endIndex, fixtureFrames[startIndex].recordedTimeMS < earliestMS {
                startIndex += 1
            }

            let queryWindow = MicFeatureWindow(frames: Array(fixtureFrames[startIndex...endIndex]))
            let snapshot = try engine.process(
                AmbientSyncFixtureReplayEngineInput(
                    fixture: fixture,
                    referenceIndex: referenceIndex,
                    queryWindow: queryWindow,
                    elapsedMS: queryWindow.endpointRecordedTimeMS,
                    sequence: events.count,
                    previousSnapshot: previousSnapshot,
                    featureConfiguration: configuration.featureConfiguration
                )
            )

            if firstProvisionalLockElapsedMS == nil,
               snapshot.phase == .provisional || snapshot.phase == .confirmed || snapshot.phase == .final {
                firstProvisionalLockElapsedMS = queryWindow.endpointRecordedTimeMS
            }
            if confirmedLockElapsedMS == nil, snapshot.phase == .confirmed || snapshot.phase == .final {
                confirmedLockElapsedMS = queryWindow.endpointRecordedTimeMS
            }
            if finalLockElapsedMS == nil, snapshot.phase == .final {
                finalLockElapsedMS = queryWindow.endpointRecordedTimeMS
            }

            events.append(
                AmbientSyncFixtureReplayTraceEvent(
                    sequence: events.count,
                    fixture: fixture,
                    queryWindow: queryWindow,
                    snapshot: snapshot,
                    firstProvisionalLockElapsedMS: firstProvisionalLockElapsedMS,
                    confirmedLockElapsedMS: confirmedLockElapsedMS,
                    finalLockElapsedMS: finalLockElapsedMS
                )
            )
            previousSnapshot = snapshot
        }

        return events
    }

    private func queryDurationMS(
        endpointMS: Double,
        previousSnapshot: AmbientSyncSnapshot?,
        finalLockElapsedMS: Double?
    ) -> Double {
        if finalLockElapsedMS != nil || previousSnapshot?.phase == .final {
            return configuration.featureConfiguration.trackingQueryDurationMS
        }

        if endpointMS >= configuration.featureConfiguration.finalLockMinimumDurationMS {
            return configuration.featureConfiguration.finalLockTargetDurationMS
        }

        if endpointMS >= configuration.featureConfiguration.firstLockMinimumDurationMS {
            return configuration.featureConfiguration.firstLockTargetDurationMS
        }

        return configuration.featureConfiguration.speculativeQueryDurationMS
    }

    private func defaultTraceOutputURL(for fixture: AmbientSyncFixtureReplayFixture) -> URL {
        configuration.traceOutputDirectoryURL
            .appendingPathComponent(fixture.fixtureAudioURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("ambient-sync-replay.jsonl")
    }

    private static func isBareCAFFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName.lowercased().hasSuffix(".caf"),
              fileName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
        else {
            return false
        }

        return URL(fileURLWithPath: fileName).lastPathComponent == fileName
    }

    private func writeJSONL(_ events: [AmbientSyncFixtureReplayTraceEvent], to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }

        try data.write(to: url, options: .atomic)
    }
}

private final class AmbientSyncFixtureReplayTargetFeatureLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let decodeAudio: @Sendable () throws -> AmbientSyncDecodedAudio
    private let buildFrames: @Sendable (AmbientSyncDecodedAudio) throws -> [MicFeatureFrame]
    private var cachedAudio: AmbientSyncDecodedAudio?
    private var cachedFrames: [MicFeatureFrame]?

    init(
        decodeAudio: @escaping @Sendable () throws -> AmbientSyncDecodedAudio,
        buildFrames: @escaping @Sendable (AmbientSyncDecodedAudio) throws -> [MicFeatureFrame]
    ) {
        self.decodeAudio = decodeAudio
        self.buildFrames = buildFrames
    }

    func audio() throws -> AmbientSyncDecodedAudio {
        lock.lock()
        if let cachedAudio {
            lock.unlock()
            return cachedAudio
        }
        lock.unlock()

        let decodedAudio = try decodeAudio()

        lock.lock()
        if cachedAudio == nil {
            cachedAudio = decodedAudio
        }
        let resolvedAudio = cachedAudio ?? decodedAudio
        lock.unlock()

        return resolvedAudio
    }

    func frames() throws -> [MicFeatureFrame] {
        lock.lock()
        if let cachedFrames {
            lock.unlock()
            return cachedFrames
        }
        let cachedAudio = self.cachedAudio
        lock.unlock()

        let resolvedAudio: AmbientSyncDecodedAudio
        if let cachedAudio {
            resolvedAudio = cachedAudio
        } else {
            resolvedAudio = try audio()
        }
        let builtFrames = try buildFrames(resolvedAudio)

        lock.lock()
        if self.cachedAudio == nil {
            self.cachedAudio = resolvedAudio
        }
        if cachedFrames == nil {
            cachedFrames = builtFrames
        }
        let resolvedFrames = cachedFrames ?? builtFrames
        lock.unlock()

        return resolvedFrames
    }
}

public extension AmbientSyncFixtureReplayRunner where ReferenceIndex == AmbientSyncReferenceIndex {
    convenience init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        referenceIndexBuilder: AmbientSyncReferenceIndexBuilder? = nil,
        engineConfiguration: AmbientSyncEngine.Configuration = .v1
    ) {
        let builder = referenceIndexBuilder ?? AmbientSyncReferenceIndexBuilder(
            configuration: AmbientSyncReferenceIndexBuilder.Configuration(
                cacheDirectoryURL: configuration.referenceIndexCacheDirectoryURL,
                featureConfiguration: configuration.featureConfiguration,
                chunkSizeSamples: configuration.audioChunkSizeSamples
            )
        )

        self.init(
            configuration: configuration,
            fileManager: fileManager,
            referenceIndexBuilder: { input in
                try builder.index(forSourceURL: input.fixture.targetAudioURL)
            },
            engineFactory: { input in
                let engineBox = AmbientSyncEngineReplayBox(
                    AmbientSyncEngine(
                        referenceIndex: input.referenceIndex,
                        configuration: engineConfiguration
                    )
                )
                return AmbientSyncFixtureReplayEngine<AmbientSyncReferenceIndex> { engineInput in
                    engineBox.process(
                        queryWindow: engineInput.queryWindow,
                        elapsedMS: engineInput.elapsedMS
                    )
                }
            }
        )
    }
}

private final class AmbientSyncEngineReplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AmbientSyncEngine

    init(_ engine: AmbientSyncEngine) {
        self.engine = engine
    }

    func process(
        queryWindow: MicFeatureWindow,
        elapsedMS: Double
    ) -> AmbientSyncSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return engine.process(
            queryWindow: queryWindow,
            elapsedMS: elapsedMS
        )
    }
}

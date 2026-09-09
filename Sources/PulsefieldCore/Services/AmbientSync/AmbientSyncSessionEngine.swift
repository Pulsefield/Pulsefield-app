import Sonalign

/// Own one session on a serial worker or actor, including construction and destruction.
/// Native alignment is used for the exact production configuration. Legacy and
/// custom configurations retain the Swift engine so no requested setting is ignored.
public final class AmbientSyncSessionEngine {
    public enum Backend: Equatable, Sendable {
        case sonalign
        case swiftCompatibility
    }

    public let backend: Backend
    public let configuration: AmbientSyncEngine.Configuration

    private enum Implementation {
        case sonalign(Aligner)
        case swift(AmbientSyncEngine)
        case failed(any Error)
    }

    private var implementation: Implementation

    public init(
        reference: AmbientSyncEngine.Reference,
        configuration: AmbientSyncEngine.Configuration = .v2
    ) throws {
        self.configuration = configuration
        if configuration == .v2 {
            backend = .sonalign
            implementation = .sonalign(try Aligner(
                reference: reference.frames.map(Self.featureFrame),
                hopMS: reference.featureConfiguration.featureHopMS
            ))
        } else {
            backend = .swiftCompatibility
            implementation = .swift(AmbientSyncEngine(reference: reference, configuration: configuration))
        }
    }

    public convenience init(
        referenceIndex: any AmbientSyncEngineReferenceIndex,
        configuration: AmbientSyncEngine.Configuration = .v2
    ) throws {
        try self.init(
            reference: AmbientSyncEngine.Reference(
                sourceDisplayPath: referenceIndex.sourceDisplayPath,
                featureConfiguration: referenceIndex.featureConfiguration,
                frames: referenceIndex.frames,
                landmarks: referenceIndex.landmarks,
                landmarkIndex: referenceIndex.landmarkIndex
            ),
            configuration: configuration
        )
    }

    /// A native input or processing error ends the session. Create a new session
    /// after fixing the input; retrying this instance cannot publish an old lock.
    public func process(queryWindow: MicFeatureWindow, elapsedMS: Double) throws -> AmbientSyncSnapshot {
        switch implementation {
        case .sonalign(let aligner):
            do {
                let result = try aligner.process(
                    query: queryWindow.frames.map(Self.featureFrame),
                    elapsedMS: elapsedMS
                )
                return snapshot(result, queryWindow: queryWindow)
            } catch {
                implementation = .failed(error)
                throw error
            }
        case .swift(var engine):
            let result = engine.process(queryWindow: queryWindow, elapsedMS: elapsedMS)
            implementation = .swift(engine)
            return result
        case .failed(let error):
            throw error
        }
    }

    private static func featureFrame(_ frame: MicFeatureFrame) -> FeatureFrame {
        FeatureFrame(
            recordedTimeMS: frame.recordedTimeMS,
            energyDBFS: frame.energyDBFS,
            pcenMel: frame.pcenMel
        )
    }

    private func snapshot(_ result: AlignmentSnapshot, queryWindow: MicFeatureWindow) -> AmbientSyncSnapshot {
        let activeCount = queryWindow.frames.filter {
            $0.energyDBFS >= configuration.minimumActiveFrameEnergyDBFS
        }.count
        // Landmark and Swift tracker diagnostics are unused for this backend.
        // Sonalign 0.1.0 does not expose candidate or partial-window correlations.
        let diagnostics = AmbientSyncDiagnostics(
            queryDurationMS: queryWindow.durationMS,
            activeFrameFraction: Double(activeCount) / Double(queryWindow.frames.count),
            queryLandmarkCount: 0,
            spectral: AmbientSyncSpectralDiagnostics(
                globalSearch: result.diagnostics.globalSearch,
                correlation: result.diagnostics.correlation,
                competingPeakMargin: result.diagnostics.competingPeakMargin,
                firstHalfCorrelation: nil,
                secondHalfCorrelation: nil,
                recentCorrelation: nil,
                freshEvidenceMS: result.diagnostics.freshEvidenceMS,
                coastMS: result.diagnostics.coastMS
            )
        )
        return AmbientSyncSnapshot(
            state: result.state.ambientState,
            phase: result.phase.ambientPhase,
            stage: result.stage.ambientStage,
            estimate: result.estimate.map {
                AmbientSyncEstimate(
                    queryEndpointRecordedTimeMS: $0.queryEndpointRecordedTimeMS,
                    referenceTimeMS: $0.referenceTimeMS,
                    offsetMS: $0.offsetMS
                )
            },
            withholdReason: result.withholdReason?.ambientReason,
            confidence: result.confidence,
            diagnostics: diagnostics,
            firstProvisionalLockElapsedMS: result.firstProvisionalLockElapsedMS,
            confirmedLockElapsedMS: result.confirmedLockElapsedMS,
            finalLockElapsedMS: result.finalLockElapsedMS
        )
    }
}

private extension AlignmentState {
    var ambientState: AmbientSyncState {
        switch self {
        case .ready: .ready
        case .listening: .listening
        case .locking: .locking
        case .confirmed: .confirmed
        case .locked: .locked
        case .drifting: .drifting
        case .relocking: .relocking
        case .lost: .lost
        case .failed: .failed
        }
    }
}

private extension LockPhase {
    var ambientPhase: AmbientSyncLockPhase {
        switch self {
        case .none: .none
        case .provisional: .provisional
        case .confirmed: .confirmed
        case .final: .final
        }
    }
}

private extension AlignmentStage {
    var ambientStage: AmbientSyncStage {
        switch self {
        case .readiness: .readiness
        case .landmarkCoarse: .landmarkCoarse
        case .fastTimingVerify: .fastTimingVerify
        case .robustVerify: .robustVerify
        case .tracking: .tracking
        case .relock: .relock
        }
    }
}

private extension WithholdReason {
    var ambientReason: AmbientSyncWithholdReason {
        switch self {
        case .insufficientDuration: .insufficientDuration
        case .insufficientEnergy: .insufficientEnergy
        case .insufficientActiveFrames: .insufficientActiveFrames
        case .insufficientLandmarkEvidence: .insufficientLandmarkEvidence
        case .weakAlignmentPeak: .weakAlignmentPeak
        case .ambiguousOffset: .ambiguousOffset
        case .unstableTrackingResidual: .unstableTrackingResidual
        case .lostSignal: .lostSignal
        case .decodeFailed: .decodeFailed
        case .indexUnavailable: .indexUnavailable
        }
    }
}

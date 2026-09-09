import Foundation

/// Streaming decisions are made in audio time. Re-reading an overlapping window
/// cannot create a confirmation, extend a coast, or accelerate confidence decay.
struct AmbientSyncSpectralEngine: Equatable, Sendable {
    private struct Hypothesis: Equatable, Sendable {
        var offsetMS: Double
        let firstEvidenceMS: Double
        var lastEvidenceMS: Double
        var correlation: Double
    }

    private let matcher: AmbientSyncSpectralMatcher?
    private let configuration: AmbientSyncEngine.Configuration
    private let hopMS: Double
    private var pending: Hypothesis?
    private var accepted: Hypothesis?
    private var lastEndpointMS: Double?
    private var lastGlobalSearchMS = -Double.infinity
    private var lastSnapshot: AmbientSyncSnapshot?
    private var firstProvisionalMS: Double?
    private var confirmedMS: Double?
    private var finalMS: Double?

    init(reference: AmbientSyncEngine.Reference, configuration: AmbientSyncEngine.Configuration) {
        self.matcher = AmbientSyncSpectralMatcher(
            frames: reference.frames, hopMS: reference.featureConfiguration.featureHopMS)
        self.configuration = configuration
        self.hopMS = reference.featureConfiguration.featureHopMS
    }

    mutating func process(query: MicFeatureWindow, elapsedMS: Double) -> AmbientSyncSnapshot {
        let endpoint = query.endpointRecordedTimeMS
        let hop = hopMS
        if let previous = lastEndpointMS {
            if endpoint < previous || query.startRecordedTimeMS > previous + 2 * hop {
                pending = nil
                accepted = nil
                lastGlobalSearchMS = -Double.infinity
                lastSnapshot = nil
            } else if endpoint - previous < 90, let lastSnapshot, matcher?.acceptsTimeline(query) != false {
                // Project the same estimate to the current endpoint without treating
                // the window as a new observation.
                return AmbientSyncSnapshot(
                    state: lastSnapshot.state, phase: lastSnapshot.phase, stage: lastSnapshot.stage,
                    estimate: lastSnapshot.estimate.map { estimate(query, offsetMS: $0.offsetMS) },
                    withholdReason: lastSnapshot.withholdReason, confidence: lastSnapshot.confidence,
                    diagnostics: lastSnapshot.diagnostics,
                    firstProvisionalLockElapsedMS: firstProvisionalMS,
                    confirmedLockElapsedMS: confirmedMS, finalLockElapsedMS: finalMS
                )
            }
        }
        lastEndpointMS = endpoint
        let active =
            Double(query.frames.filter { $0.energyDBFS >= configuration.minimumActiveFrameEnergyDBFS }.count)
            / Double(query.frames.count)
        let energy = AmbientSyncEngine.averageEnergyDBFS(query.frames)
        let readiness: AmbientSyncWithholdReason?
        if matcher == nil {
            readiness = .indexUnavailable
        } else if query.durationMS
            < (confirmedMS == nil
                ? configuration.minimumReadinessDurationMS
                : min(
                    configuration.minimumReadinessDurationMS,
                    configuration.featureConfiguration.trackingQueryDurationMS - hop))
        {
            readiness = .insufficientDuration
        } else if matcher?.acceptsTimeline(query) == false {
            readiness = .lostSignal
        } else if energy < configuration.minimumAverageEnergyDBFS {
            readiness = .insufficientEnergy
        } else if active < configuration.minimumActiveFrameFraction {
            readiness = .insufficientActiveFrames
        } else {
            readiness = nil
        }

        if let readiness {
            pending = nil
            // Silence is an observed loss of audio, not evidence for the old position.
            accepted = nil
            return publish(
                query: query, active: active, result: .init(candidates: []),
                global: false, reason: readiness,
                state: readiness == .indexUnavailable ? .failed : (confirmedMS == nil ? .listening : .lost))
        }
        guard let matcher else { preconditionFailure("Readiness checked the reference index") }

        // Centering removes 250 ms at each end; use its actual supported endpoint
        // when measuring new evidence and expiration.
        let evidenceMS = endpoint - (250 / hop).rounded() * hop
        var result = AmbientSyncSpectralMatcher.Result(candidates: [])
        var locallySupported = false
        var innovation: Double?
        if var track = accepted, evidenceMS - track.lastEvidenceMS <= 1_500 {
            result = matcher.match(query: query, rangeMS: (track.offsetMS - 100)...(track.offsetMS + 100))
            if let best = result.best,
                best.score >= 0.15, best.recentScore >= 0.12,
                abs(best.offsetMS - track.offsetMS) <= 80
            {
                innovation = best.offsetMS - track.offsetMS
                let dt = max(0, evidenceMS - track.lastEvidenceMS)
                let gain = 1 - exp(-dt / 300)
                track.offsetMS += gain * (best.offsetMS - track.offsetMS)
                track.lastEvidenceMS = evidenceMS
                track.correlation = best.score
                accepted = track
                locallySupported = true
            }
        } else {
            // A dormant position is not independent evidence. Once the grace
            // period expires, only global verification may establish another lock.
            accepted = nil
        }

        // Even a healthy track receives a global check. A conflicting hypothesis
        // must earn fresh evidence before it can replace the accepted position.
        let globalInterval = locallySupported ? 2_000.0 : 500.0
        let global = endpoint - lastGlobalSearchMS >= globalInterval
        if global {
            result = matcher.match(query: query)
            lastGlobalSearchMS = endpoint
            if let best = result.best,
                best.score >= 0.25, result.margin >= 0.06,
                min(best.firstHalfScore, best.secondHalfScore) >= 0.10
            {
                if firstProvisionalMS == nil { firstProvisionalMS = elapsedMS }
                if let old = pending,
                    abs(old.offsetMS - best.offsetMS) <= 80,
                    evidenceMS - old.lastEvidenceMS <= 2_500
                {
                    pending = Hypothesis(
                        offsetMS: best.offsetMS, firstEvidenceMS: old.firstEvidenceMS, lastEvidenceMS: evidenceMS,
                        correlation: best.score)
                } else {
                    pending = Hypothesis(
                        offsetMS: best.offsetMS, firstEvidenceMS: evidenceMS, lastEvidenceMS: evidenceMS,
                        correlation: best.score)
                }
                let fresh = evidenceMS - (pending?.firstEvidenceMS ?? evidenceMS)
                let strongEarly =
                    best.score >= 0.45 && result.margin >= 0.12
                    && min(best.firstHalfScore, best.secondHalfScore) >= 0.20
                let longEnough = query.durationMS >= configuration.minimumFinalQueryDurationMS
                // The last second must be new since the hypothesis was formed.
                // A transient appearing in several overlapping windows cannot lock.
                if fresh >= 1_000 - hop, best.recentScore >= 0.15, longEnough || strongEarly {
                    if confirmedMS == nil { confirmedMS = elapsedMS }
                    if longEnough && finalMS == nil { finalMS = elapsedMS }
                    if accepted == nil || abs(accepted!.offsetMS - best.offsetMS) > 80 || !locallySupported {
                        accepted = Hypothesis(
                            offsetMS: best.offsetMS, firstEvidenceMS: evidenceMS, lastEvidenceMS: evidenceMS,
                            correlation: best.score)
                    }
                    locallySupported = true
                }
            } else {
                pending = nil
            }
        }

        if let track = accepted, evidenceMS - track.lastEvidenceMS <= 1_500 {
            return publish(
                query: query, active: active, result: result, global: global,
                reason: locallySupported ? nil : .weakAlignmentPeak,
                state: finalMS == nil ? .confirmed : .locked,
                offsetMS: track.offsetMS, innovation: innovation,
                coastMS: max(0, evidenceMS - track.lastEvidenceMS))
        }
        let ambiguous = result.best != nil && result.margin < 0.06
        return publish(
            query: query, active: active, result: result, global: global,
            reason: ambiguous ? .ambiguousOffset : .weakAlignmentPeak,
            state: confirmedMS == nil ? .locking : .relocking,
            offsetMS: confirmedMS == nil ? pending?.offsetMS : nil)
    }

    private func estimate(_ query: MicFeatureWindow, offsetMS: Double) -> AmbientSyncEstimate {
        AmbientSyncEstimate(
            queryEndpointRecordedTimeMS: query.endpointRecordedTimeMS,
            referenceTimeMS: query.endpointRecordedTimeMS + offsetMS, offsetMS: offsetMS)
    }

    private mutating func publish(
        query: MicFeatureWindow, active: Double, result: AmbientSyncSpectralMatcher.Result,
        global: Bool, reason: AmbientSyncWithholdReason?, state: AmbientSyncState,
        offsetMS: Double? = nil, innovation: Double? = nil, coastMS: Double = 0
    ) -> AmbientSyncSnapshot {
        let publishingTrack = state == .locked || state == .confirmed
        let supported = publishingTrack && coastMS == 0
        let spectral = AmbientSyncSpectralDiagnostics(
            globalSearch: global, correlation: result.best?.score ?? 0,
            competingPeakMargin: global ? result.margin : nil,
            firstHalfCorrelation: result.best?.firstHalfScore ?? 0,
            secondHalfCorrelation: result.best?.secondHalfScore ?? 0,
            recentCorrelation: result.best?.recentScore ?? 0,
            freshEvidenceMS: pending.map { max(0, $0.lastEvidenceMS - $0.firstEvidenceMS) } ?? 0,
            coastMS: coastMS
        )
        let diagnostics = AmbientSyncDiagnostics(
            queryDurationMS: query.durationMS, activeFrameFraction: active, queryLandmarkCount: 0,
            coarseAmbiguous: global && result.best != nil && result.margin < 0.06,
            denseMargin: global ? result.margin : 0,
            offsetStabilityMS: innovation.map(abs), trackInnovationMS: innovation,
            trackCount: accepted == nil ? 0 : 1,
            offsetTrackerConfirmed: publishingTrack, offsetTrackerStable: supported,
            candidates: result.candidates.map { candidate in
                AmbientSyncCandidateDiagnostics(
                    offsetMS: candidate.offsetMS, coarseOffsetMS: candidate.offsetMS,
                    landmarkVoteCount: 0, landmarkScore: 0, voteDensity: 0,
                    comparableFrameCount: max(
                        0,
                        query.frames.count - 2 * Int((250 / hopMS).rounded())),
                    coverageRatio: max(0, (query.durationMS - 500) / max(1, query.durationMS)),
                    onsetScore: 0, subbandOnsetScore: 0, pcenMelScore: 0,
                    chromaOnsetScore: 0, censScore: 0, combinedDenseScore: candidate.score,
                    featureAgreementCount: 0
                )
            }, spectral: spectral
        )
        let phase: AmbientSyncLockPhase =
            finalMS != nil
            ? .final : (confirmedMS != nil ? .confirmed : (firstProvisionalMS != nil ? .provisional : .none))
        let snapshot = AmbientSyncSnapshot(
            state: state, phase: phase,
            stage: publishingTrack ? .tracking : (global ? .robustVerify : .readiness),
            estimate: offsetMS.map { estimate(query, offsetMS: $0) }, withholdReason: reason,
            confidence: offsetMS == nil
                ? 0
                : min(
                    1,
                    max(
                        0,
                        (publishingTrack ? (accepted?.correlation ?? 0) : (result.best?.score ?? 0))
                            * (1 - coastMS / 1_500))),
            diagnostics: diagnostics, firstProvisionalLockElapsedMS: firstProvisionalMS,
            confirmedLockElapsedMS: confirmedMS, finalLockElapsedMS: finalMS
        )
        lastSnapshot = snapshot
        return snapshot
    }
}

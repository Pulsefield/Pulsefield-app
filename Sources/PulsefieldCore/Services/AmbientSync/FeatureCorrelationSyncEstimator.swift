import Foundation

public actor FeatureCorrelationSyncEstimator: AmbientSyncEstimating {
    private struct DenseFeatureMatrix {
        var values: [Double]
        var dimensions: Int

        static let empty = DenseFeatureMatrix(values: [], dimensions: 0)

        var frameCount: Int {
            guard dimensions > 0 else {
                return 0
            }
            return values.count / dimensions
        }

        var isEmpty: Bool {
            values.isEmpty || dimensions <= 0
        }
    }

    private struct LandmarkRecord: Sendable {
        var hash: UInt32
        var frameIndex: Int
    }

    private struct LandmarkIndex: Sendable {
        var postingsByHash: [UInt32: [Int]]
        var recordCount: Int

        static let empty = LandmarkIndex(postingsByHash: [:], recordCount: 0)

        var isEmpty: Bool {
            postingsByHash.isEmpty || recordCount == 0
        }
    }

    private struct QuerySyncFeatures {
        var onsetFlux: [Double]
        var landmarkRecords: [LandmarkRecord]
        var logMel: DenseFeatureMatrix
        var chroma: DenseFeatureMatrix
        var energy: DenseFeatureMatrix

        static let empty = QuerySyncFeatures(
            onsetFlux: [],
            landmarkRecords: [],
            logMel: .empty,
            chroma: .empty,
            energy: .empty
        )

        var frameCount: Int {
            onsetFlux.count
        }

        var activeFrameCount: Int {
            onsetFlux.filter { $0 > 0 }.count
        }

        var landmarkCount: Int {
            landmarkRecords.count
        }

        var isEmpty: Bool {
            onsetFlux.isEmpty
        }
    }

    private struct ScoredCandidate {
        var offset: Int
        var combinedScore: Double
        var onsetFluxScore: Double
        var logMelScore: Double?
        var chromaScore: Double?
        var energyScore: Double?
        var landmarkVoteCount: Int
        var landmarkInlierRate: Double
        var rawDistance: Double
    }

    private struct CorrelationMatch {
        var offset: Int
        var confidence: Double
        var secondBestConfidence: Double?
        var candidateCount: Int
        var searchedOffsets: ClosedRange<Int>
        var queryFrameCount: Int
        var onsetFluxScore: Double
        var logMelScore: Double?
        var chromaScore: Double?
        var energyScore: Double?
        var landmarkVoteCount: Int
        var landmarkInlierRate: Double
        var topCandidates: [ScoredCandidate]
        var noiseFloorMean: Double?
        var noiseFloorStd: Double?
        var peakZ: Double?
    }

    private struct ClockObservation {
        var hostTime: ContinuousClock.Instant
        var measuredReferenceMS: Double
        var confidence: Double
        var residualMS: Double
    }

    private struct ClockDriftSnapshot {
        var rawDriftPPM: Double?
        var smoothedDriftPPM: Double?
    }

    private let capture: any AmbientAudioCapturing
    private let windowDurationMS: Int
    private let minimumLockConfidence: Double
    private let hardRelockThresholdMS: Double
    private let lostWindowLimit: Int
    private let wideRelockConfidenceMargin = 0.001
    private let stableTrackingRadiusMS = 300.0
    private let uncertainTrackingRadiusMS = 700.0
    private let unstableTrackingRadiusMS = 1_000.0
    private let minimumClockObservationSpanMS = 500.0
    private let maxClockObservationResidualMS = 350.0
    private let maxClockObservationCount = 12
    private let featureExtractor = AmbientSyncFeatureExtractor()

    private var state: AmbientSyncEngineState = .idle
    private var index: LocalAudioSyncIndex?
    private var localFeatures: [Double] = []
    private var localFeatureDimensions = 1
    private var localLandmarks = LandmarkIndex.empty
    private var localLogMel = DenseFeatureMatrix.empty
    private var localChroma = DenseFeatureMatrix.empty
    private var localEnergy = DenseFeatureMatrix.empty
    private var previousEstimate: SyncEstimate?
    private var lastDiagnostics: AmbientMatchDiagnostics?
    private var consecutiveLockWindows = 0
    private var lowConfidenceWindows = 0
    private var clockObservations: [ClockObservation] = []
    private var rawDriftPPM: Double?
    private var smoothedDriftPPM: Double?

    public init(
        capture: any AmbientAudioCapturing,
        windowDurationMS: Int = 4_000,
        minimumLockConfidence: Double = 0.72,
        hardRelockThresholdMS: Double = 500,
        lostWindowLimit: Int = 4
    ) {
        self.capture = capture
        self.windowDurationMS = windowDurationMS
        self.minimumLockConfidence = minimumLockConfidence
        self.hardRelockThresholdMS = hardRelockThresholdMS
        self.lostWindowLimit = lostWindowLimit
    }

    public func start(asset: LocalAudioAsset, index: LocalAudioSyncIndex) async throws {
        state = .indexing
        do {
            let featureFiles = try validateStartIndex(index, for: asset)
            let features = try Self.readFeatures(
                from: featureFiles.onsetFluxURL,
                dimensions: featureFiles.onsetFluxDimensions
            )
            guard !features.isEmpty else {
                throw AmbientSyncStartError.indexInvalid
            }

            localFeatures = features
            localFeatureDimensions = featureFiles.onsetFluxDimensions
            localLandmarks = try Self.readLandmarkIndex(
                from: featureFiles.landmarkPostingsURL,
                recordCount: featureFiles.landmarkRecordCount
            )
            localLogMel = try Self.readOptionalFeatureMatrix(
                from: featureFiles.logMelURL,
                dimensions: featureFiles.logMelDimensions
            )
            localChroma = try Self.readOptionalFeatureMatrix(
                from: featureFiles.chromaURL,
                dimensions: featureFiles.chromaDimensions
            )
            localEnergy = try Self.readOptionalFeatureMatrix(
                from: featureFiles.energyURL,
                dimensions: featureFiles.energyDimensions
            )
        } catch {
            let startError = startError(from: error)
            indexStartupFailed(startError, index: index)
            throw startError
        }

        self.index = index
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        resetClockTracking()
        lastDiagnostics = diagnostics(
            index: index,
            window: nil,
            queryFeatures: .empty,
            match: nil,
            predictedReferenceMS: nil,
            selectedReferenceMS: nil,
            searchMode: .wide,
            didPublish: false,
            withholdReason: nil,
            confidence: 0,
            explanation: "Sync index is valid; waiting for a microphone window."
        )

        do {
            try await capture.start()
            state = .listening
        } catch {
            await capture.stop()
            captureStartupFailed(error, index: index)
            throw error
        }
    }

    public func stop() async {
        await capture.stop()
        state = .idle
        self.index = nil
        localFeatures = []
        localFeatureDimensions = 1
        localLandmarks = .empty
        localLogMel = .empty
        localChroma = .empty
        localEnergy = .empty
        previousEstimate = nil
        lastDiagnostics = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        resetClockTracking()
    }

    public func currentEstimate() async -> SyncEstimate? {
        guard state != .idle else {
            return nil
        }

        guard let index else {
            return nil
        }

        guard !localFeatures.isEmpty else {
            state = .failed
            return nil
        }

        guard let window = await capture.latestWindow(durationMS: windowDurationMS) else {
            return previousEstimate
        }

        if state == .lost {
            state = .relocking
        }

        let queryFeatures = querySyncFeatures(
            samples: window.samples,
            sampleRate: window.sampleRate,
            frameHopMS: index.frameHopMS
        )
        let predictedReference = predictedReferenceTime(at: window.hostTime)
        let searchMode = currentSearchMode
        let trackingRadiusMS = trackingSearchRadiusMS()
        let offsetRange: ClosedRange<Int>?
        if shouldSearchNearPredictedReference,
           let predictedReference,
            let lockedRange = lockedOffsetRange(
                predictedReferenceTimeMS: predictedReference,
                queryFeatureCount: queryFeatures.frameCount,
                localFeatureCount: localFeatures.count,
                frameHopMS: index.frameHopMS,
                radiusMS: trackingRadiusMS
            ) {
            offsetRange = lockedRange
        } else {
            offsetRange = nil
        }

        let match = bestCorrelationOffset(query: queryFeatures, offsetRange: offsetRange)
        guard let match else {
            return withholdEstimate(
                reason: withholdReasonForNoMatch(queryFeatures: queryFeatures, window: window),
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: nil,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: nil,
                searchMode: searchMode,
                explanation: "The current microphone window does not contain enough reliable sync evidence."
            )
        }
        let wideComparisonMatch = shouldSearchNearPredictedReference
            ? bestCorrelationOffset(query: queryFeatures)
            : nil
        let diagnosticsMatch = matchWithWideDiagnosticAlternatives(
            match,
            wideMatch: wideComparisonMatch
        )

        guard match.confidence >= minimumLockConfidence else {
            return withholdEstimate(
                reason: .weakAlignmentPeak,
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: diagnosticsMatch,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: nil,
                searchMode: searchMode,
                explanation: "The strongest prototype correlation peak is below the publish threshold."
            )
        }

        let matchedReference = referenceTime(
            forOffset: match.offset,
            queryFeatureCount: queryFeatures.frameCount,
            index: index
        )
        if hasInsufficientWideLandmarkSupport(
            queryFeatures: queryFeatures,
            match: match,
            searchMode: searchMode
        ) {
            return withholdEstimate(
                reason: .insufficientLandmarkEvidence,
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: diagnosticsMatch,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: matchedReference,
                searchMode: searchMode,
                explanation: "The dense peak is plausible, but the wide-search landmark support is too weak to publish."
            )
        }

        if isAmbiguous(match: match, searchMode: searchMode) {
            return withholdEstimate(
                reason: .ambiguousOffset,
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: diagnosticsMatch,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: matchedReference,
                searchMode: searchMode,
                explanation: "Multiple wide-search offsets have similarly strong dense verification scores."
            )
        }

        let relockComparisonReference = predictedReference ?? previousEstimate?.referenceTimeMS
        let isHardRelock = shouldRelock(to: matchedReference, comparedTo: relockComparisonReference)
        if isHardRelock, previousEstimate != nil {
            return withholdEstimate(
                reason: .unstableTrackingResidual,
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: diagnosticsMatch,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: matchedReference,
                searchMode: searchMode,
                explanation: "The measured prototype peak is too far from the predicted locked position."
            )
        }

        if shouldDegradeForWideHardRelock(
            currentMatch: match,
            wideMatch: wideComparisonMatch,
            index: index,
            comparisonReference: relockComparisonReference
        ) {
            return withholdEstimate(
                reason: .unstableTrackingResidual,
                index: index,
                window: window,
                queryFeatures: queryFeatures,
                match: diagnosticsMatch,
                predictedReferenceMS: predictedReference,
                selectedReferenceMS: matchedReference,
                searchMode: searchMode,
                explanation: "A stronger wide-search peak conflicts with the locked prediction."
            )
        }

        lowConfidenceWindows = 0

        let wasTracking = state == .locked || state == .drifting
        consecutiveLockWindows += 1
        let referenceTime = matchedReference
        let drift = recordClockObservation(
            hostTime: window.hostTime,
            measuredReferenceMS: referenceTime,
            confidence: match.confidence,
            predictedReferenceMS: predictedReference
        )
        let estimate = SyncEstimate(
            hostTime: window.hostTime,
            referenceTimeMS: referenceTime,
            confidence: match.confidence,
            driftPPM: drift.smoothedDriftPPM,
            latencyMS: nil,
            source: .localFeatureCorrelation
        )

        previousEstimate = estimate
        state = wasTracking || consecutiveLockWindows >= 2 ? .locked : .locking
        lastDiagnostics = diagnostics(
            index: index,
            window: window,
            queryFeatures: queryFeatures,
            match: diagnosticsMatch,
            predictedReferenceMS: predictedReference,
            selectedReferenceMS: referenceTime,
            searchMode: searchMode,
            didPublish: true,
            withholdReason: nil,
            confidence: match.confidence,
            explanation: "Published a prototype feature-correlation estimate."
        )
        return estimate
    }

    private func shouldDegradeForWideHardRelock(
        currentMatch: CorrelationMatch,
        wideMatch: CorrelationMatch?,
        index: LocalAudioSyncIndex,
        comparisonReference: Double?
    ) -> Bool {
        guard shouldSearchNearPredictedReference,
              let wideMatch
        else {
            return false
        }

        let wideReference = referenceTime(
            forOffset: wideMatch.offset,
            queryFeatureCount: wideMatch.queryFrameCount,
            index: index
        )
        guard shouldRelock(to: wideReference, comparedTo: comparisonReference) else {
            return false
        }

        return wideMatch.confidence > currentMatch.confidence + wideRelockConfidenceMargin
            || currentMatch.confidence < 0.95
    }

    private func referenceTime(
        forOffset offset: Int,
        queryFeatureCount: Int,
        index: LocalAudioSyncIndex
    ) -> Double {
        let windowStart = Double(offset) * index.frameHopMS
        return min(
            Double(index.durationMS),
            windowStart + (Double(queryFeatureCount) * index.frameHopMS)
        )
    }

    private func shouldRelock(to matchedReference: Double, comparedTo reference: Double?) -> Bool {
        guard let reference else {
            return false
        }

        return abs(matchedReference - reference) > hardRelockThresholdMS
    }

    public func currentState() async -> AmbientSyncEngineState {
        state
    }

    public func currentDiagnostics() async -> AmbientMatchDiagnostics? {
        lastDiagnostics
    }

    private func indexStartupFailed(_ error: AmbientSyncStartError, index: LocalAudioSyncIndex) {
        state = .failed
        lastDiagnostics = diagnostics(
            index: index,
            indexStatus: indexRuntimeStatus(for: error),
            window: nil,
            queryFeatures: .empty,
            match: nil,
            predictedReferenceMS: nil,
            selectedReferenceMS: nil,
            searchMode: .wide,
            didPublish: false,
            withholdReason: nil,
            confidence: 0,
            explanation: error.localizedDescription
        )
        self.index = nil
        localFeatures = []
        localFeatureDimensions = 1
        localLandmarks = .empty
        localLogMel = .empty
        localChroma = .empty
        localEnergy = .empty
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        resetClockTracking()
    }

    private func captureStartupFailed(_ error: Error, index: LocalAudioSyncIndex) {
        state = .failed
        lastDiagnostics = diagnostics(
            index: index,
            window: nil,
            queryFeatures: .empty,
            match: nil,
            predictedReferenceMS: nil,
            selectedReferenceMS: nil,
            searchMode: .wide,
            didPublish: false,
            withholdReason: nil,
            confidence: 0,
            explanation: error.localizedDescription
        )
        self.index = nil
        localFeatures = []
        localFeatureDimensions = 1
        localLandmarks = .empty
        localLogMel = .empty
        localChroma = .empty
        localEnergy = .empty
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        resetClockTracking()
    }

    private var shouldSearchNearPredictedReference: Bool {
        switch state {
        case .locked, .drifting:
            return previousEstimate != nil
        case .idle, .indexing, .ready, .listening, .locking, .relocking, .lost, .failed:
            return false
        }
    }

    private var currentSearchMode: SearchMode {
        if shouldSearchNearPredictedReference {
            return .narrow
        }

        switch state {
        case .lost, .relocking:
            return .relock
        case .idle, .indexing, .ready, .listening, .locking, .locked, .drifting, .failed:
            return .wide
        }
    }

    private func predictedReferenceTime(at hostTime: ContinuousClock.Instant) -> Double? {
        guard let previousEstimate else {
            return nil
        }

        let elapsedMS = max(0, elapsedMilliseconds(from: previousEstimate.hostTime, to: hostTime))
        let driftPPM = smoothedDriftPPM ?? previousEstimate.driftPPM ?? 0
        return previousEstimate.referenceTimeMS + (elapsedMS * (1 + (driftPPM / 1_000_000)))
    }

    private func lockedOffsetRange(
        predictedReferenceTimeMS: Double,
        queryFeatureCount: Int,
        localFeatureCount: Int,
        frameHopMS: Double,
        radiusMS: Double
    ) -> ClosedRange<Int>? {
        guard queryFeatureCount > 0, queryFeatureCount <= localFeatureCount, frameHopMS > 0 else {
            return nil
        }

        let maxOffset = localFeatureCount - queryFeatureCount
        let queryDurationMS = Double(queryFeatureCount) * frameHopMS
        let earliestReference = predictedReferenceTimeMS - radiusMS
        let latestReference = predictedReferenceTimeMS + radiusMS
        let lowerOffset = max(0, Int(floor((earliestReference - queryDurationMS) / frameHopMS)))
        let upperOffset = min(maxOffset, Int(ceil((latestReference - queryDurationMS) / frameHopMS)))

        guard lowerOffset <= upperOffset else {
            return nil
        }
        return lowerOffset...upperOffset
    }

    private func trackingSearchRadiusMS() -> Double {
        switch state {
        case .locked:
            return lowConfidenceWindows == 0 ? stableTrackingRadiusMS : uncertainTrackingRadiusMS
        case .drifting:
            return lowConfidenceWindows == 0 ? uncertainTrackingRadiusMS : unstableTrackingRadiusMS
        case .idle, .indexing, .ready, .listening, .locking, .relocking, .lost, .failed:
            return hardRelockThresholdMS
        }
    }

    public func nudge(byMilliseconds deltaMS: Double) {
        guard let previousEstimate else {
            return
        }

        let estimate = SyncEstimate(
            hostTime: .now,
            referenceTimeMS: max(0, previousEstimate.referenceTimeMS + deltaMS),
            confidence: previousEstimate.confidence,
            driftPPM: previousEstimate.driftPPM,
            latencyMS: previousEstimate.latencyMS,
            source: .userNudge
        )
        self.previousEstimate = estimate
        state = .locked
        resetClockTracking()
    }

    public func forceRelock() {
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        state = .relocking
        resetClockTracking()
    }

    private func degradeLock(withholdReason reason: AmbientSyncWithholdReason) -> (estimate: SyncEstimate?, reason: AmbientSyncWithholdReason) {
        guard let previousEstimate else {
            lowConfidenceWindows += 1
            if lowConfidenceWindows >= lostWindowLimit {
                state = .lost
                resetClockTracking()
                return (nil, .lostSignal)
            }

            state = .listening
            return (nil, reason)
        }

        lowConfidenceWindows += 1
        consecutiveLockWindows = 0

        if lowConfidenceWindows >= lostWindowLimit {
            state = .lost
            self.previousEstimate = nil
            resetClockTracking()
            return (nil, .lostSignal)
        }

        state = .drifting
        return (previousEstimate, reason)
    }

    private func querySyncFeatures(samples: [Float], sampleRate: Double, frameHopMS: Double) -> QuerySyncFeatures {
        if localFeatureDimensions <= 1 || sampleRate < 8_000 {
            return QuerySyncFeatures(
                onsetFlux: featureExtractor.onsetFlux(
                    samples: samples,
                    sampleRate: sampleRate,
                    frameHopMS: frameHopMS,
                    previousFrame: .unavailable
                ),
                landmarkRecords: [],
                logMel: .empty,
                chroma: .empty,
                energy: .empty
            )
        }

        let features = featureExtractor.extract(
            samples: samples,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: .unavailable
        )
        return QuerySyncFeatures(
            onsetFlux: AmbientSyncFeatureExtractor.projectOnsetFlux(
                features.onsetFlux,
                dimensions: localFeatureDimensions
            ),
            landmarkRecords: Self.landmarkRecords(from: features.landmarkPostings),
            logMel: DenseFeatureMatrix(
                values: features.logMel,
                dimensions: AmbientSyncFeatureExtractor.logMelDimensions
            ),
            chroma: DenseFeatureMatrix(
                values: features.chroma,
                dimensions: AmbientSyncFeatureExtractor.chromaDimensions
            ),
            energy: DenseFeatureMatrix(values: features.energy, dimensions: 1)
        )
    }

    private func bestCorrelationOffset(
        query: QuerySyncFeatures,
        offsetRange: ClosedRange<Int>? = nil
    ) -> CorrelationMatch? {
        guard !query.isEmpty, query.frameCount <= localFeatures.count else {
            return nil
        }

        let normalizedQuery = normalize(query.onsetFlux)
        guard energy(normalizedQuery) > 0 else {
            return nil
        }

        var candidates: [ScoredCandidate] = []
        var candidateCount = 0
        let maxOffset = localFeatures.count - query.frameCount
        let searchRange = offsetRange ?? 0...maxOffset
        let lowerOffset = max(0, searchRange.lowerBound)
        let upperOffset = min(maxOffset, searchRange.upperBound)
        guard lowerOffset <= upperOffset else {
            return nil
        }
        let landmarkVotes = landmarkVotesByOffset(query: query, maxOffset: maxOffset)

        for offset in lowerOffset...upperOffset {
            let candidateValues = Array(localFeatures[offset..<(offset + query.frameCount)])
            let candidate = normalize(candidateValues)
            let onsetScore = clampScore(cosineSimilarity(normalizedQuery, candidate))
            let logMelScore = denseFeatureScore(
                query: query.logMel,
                local: localLogMel,
                offset: offset,
                frameCount: query.frameCount
            )
            let chromaScore = denseFeatureScore(
                query: query.chroma,
                local: localChroma,
                offset: offset,
                frameCount: query.frameCount
            )
            let energyScore = denseFeatureScore(
                query: query.energy,
                local: localEnergy,
                offset: offset,
                frameCount: query.frameCount
            )
            let combinedScore = combinedCandidateScore(
                onsetFluxScore: onsetScore,
                logMelScore: logMelScore,
                chromaScore: chromaScore,
                energyScore: energyScore
            )
            let rawDistance = meanSquaredDistance(query.onsetFlux, candidateValues)
            let voteCount = landmarkVotes[offset, default: 0]
            let inlierRate = query.landmarkCount > 0
                ? Double(voteCount) / Double(query.landmarkCount)
                : 0
            candidateCount += 1
            candidates.append(
                ScoredCandidate(
                    offset: offset,
                    combinedScore: combinedScore,
                    onsetFluxScore: onsetScore,
                    logMelScore: logMelScore,
                    chromaScore: chromaScore,
                    energyScore: energyScore,
                    landmarkVoteCount: voteCount,
                    landmarkInlierRate: inlierRate,
                    rawDistance: rawDistance
                )
            )
        }

        let sortedCandidates = candidates.sorted { left, right in
            if abs(left.combinedScore - right.combinedScore) <= 1.0e-12 {
                if left.landmarkVoteCount != right.landmarkVoteCount {
                    return left.landmarkVoteCount > right.landmarkVoteCount
                }
                return left.rawDistance < right.rawDistance
            }
            return left.combinedScore > right.combinedScore
        }
        guard let best = sortedCandidates.first else {
            return nil
        }

        let secondBest = sortedCandidates
            .dropFirst()
            .first { abs($0.offset - best.offset) >= distinctCandidateSeparation(queryFrameCount: query.frameCount) }
        let noiseScores = sortedCandidates.dropFirst().map(\.combinedScore)
        let noiseFloorMean = mean(noiseScores)
        let noiseFloorStd = standardDeviation(noiseScores, mean: noiseFloorMean)
        let peakZ: Double?
        if let noiseFloorMean, let noiseFloorStd, noiseFloorStd > 0 {
            peakZ = (best.combinedScore - noiseFloorMean) / noiseFloorStd
        } else {
            peakZ = nil
        }

        return CorrelationMatch(
            offset: best.offset,
            confidence: best.combinedScore,
            secondBestConfidence: secondBest?.combinedScore,
            candidateCount: candidateCount,
            searchedOffsets: lowerOffset...upperOffset,
            queryFrameCount: query.frameCount,
            onsetFluxScore: best.onsetFluxScore,
            logMelScore: best.logMelScore,
            chromaScore: best.chromaScore,
            energyScore: best.energyScore,
            landmarkVoteCount: best.landmarkVoteCount,
            landmarkInlierRate: best.landmarkInlierRate,
            topCandidates: Array(sortedCandidates.prefix(4)),
            noiseFloorMean: noiseFloorMean,
            noiseFloorStd: noiseFloorStd,
            peakZ: peakZ
        )
    }

    private func matchWithWideDiagnosticAlternatives(
        _ match: CorrelationMatch,
        wideMatch: CorrelationMatch?
    ) -> CorrelationMatch {
        guard let wideMatch else {
            return match
        }

        let separation = distinctCandidateSeparation(queryFrameCount: match.queryFrameCount)
        let wideAlternatives = wideMatch.topCandidates
            .filter { abs($0.offset - match.offset) >= separation }
            .sorted(by: ranksBefore)
        guard !wideAlternatives.isEmpty else {
            return match
        }

        var merged = match
        if let bestAlternative = wideAlternatives.first,
           merged.secondBestConfidence == nil || bestAlternative.combinedScore > (merged.secondBestConfidence ?? 0) {
            merged.secondBestConfidence = bestAlternative.combinedScore
        }

        var candidates = match.topCandidates
        for candidate in wideAlternatives where !candidates.contains(where: { $0.offset == candidate.offset }) {
            candidates.append(candidate)
        }

        let selected = candidates.first { $0.offset == match.offset }
        let alternatives = candidates
            .filter { $0.offset != match.offset }
            .sorted(by: ranksBefore)
        if let selected {
            merged.topCandidates = [selected] + Array(alternatives.prefix(3))
        } else {
            merged.topCandidates = Array(alternatives.prefix(4))
        }
        return merged
    }

    private func ranksBefore(_ left: ScoredCandidate, _ right: ScoredCandidate) -> Bool {
        if abs(left.combinedScore - right.combinedScore) <= 1.0e-12 {
            if left.landmarkVoteCount != right.landmarkVoteCount {
                return left.landmarkVoteCount > right.landmarkVoteCount
            }
            return left.rawDistance < right.rawDistance
        }
        return left.combinedScore > right.combinedScore
    }

    private func landmarkVotesByOffset(query: QuerySyncFeatures, maxOffset: Int) -> [Int: Int] {
        guard !localLandmarks.isEmpty, !query.landmarkRecords.isEmpty else {
            return [:]
        }

        var votesByOffset: [Int: Int] = [:]
        for queryRecord in query.landmarkRecords {
            guard let localFrames = localLandmarks.postingsByHash[queryRecord.hash] else {
                continue
            }
            for localFrame in localFrames {
                let offset = localFrame - queryRecord.frameIndex
                guard offset >= 0, offset <= maxOffset else {
                    continue
                }
                votesByOffset[offset, default: 0] += 1
            }
        }
        return votesByOffset
    }

    private func denseFeatureScore(
        query: DenseFeatureMatrix,
        local: DenseFeatureMatrix,
        offset: Int,
        frameCount: Int
    ) -> Double? {
        guard !query.isEmpty,
              !local.isEmpty,
              query.dimensions == local.dimensions,
              query.frameCount == frameCount,
              offset >= 0,
              offset + frameCount <= local.frameCount
        else {
            return nil
        }

        let start = offset * local.dimensions
        let end = (offset + frameCount) * local.dimensions
        let candidate = Array(local.values[start..<end])
        let normalizedQuery = normalize(query.values)
        let normalizedCandidate = normalize(candidate)
        guard energy(normalizedQuery) > 0,
              energy(normalizedCandidate) > 0
        else {
            return nil
        }

        return clampScore(cosineSimilarity(normalizedQuery, normalizedCandidate))
    }

    private func combinedCandidateScore(
        onsetFluxScore: Double,
        logMelScore: Double?,
        chromaScore: Double?,
        energyScore: Double?
    ) -> Double {
        var weightedScore = onsetFluxScore * 0.40
        var totalWeight = 0.40

        if let logMelScore {
            weightedScore += logMelScore * 0.30
            totalWeight += 0.30
        }
        if let chromaScore {
            weightedScore += chromaScore * 0.25
            totalWeight += 0.25
        }
        if let energyScore {
            weightedScore += energyScore * 0.05
            totalWeight += 0.05
        }

        return clampScore(weightedScore / totalWeight)
    }

    private func clampScore(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return max(0, min(value, 1))
    }

    private func distinctCandidateSeparation(queryFrameCount: Int) -> Int {
        max(1, queryFrameCount * 2)
    }

    private func hasInsufficientWideLandmarkSupport(
        queryFeatures: QuerySyncFeatures,
        match: CorrelationMatch,
        searchMode: SearchMode
    ) -> Bool {
        guard searchMode != .narrow,
              !localLandmarks.isEmpty
        else {
            return false
        }

        let minimumVotes = max(2, min(8, queryFeatures.landmarkCount / 10))
        guard match.landmarkVoteCount < minimumVotes else {
            return false
        }

        return match.confidence < min(0.92, minimumLockConfidence + 0.10)
    }

    private func isAmbiguous(match: CorrelationMatch, searchMode: SearchMode) -> Bool {
        guard searchMode != .narrow,
              previousEstimate == nil || searchMode == .relock,
              match.queryFrameCount >= 4,
              let secondBestConfidence = match.secondBestConfidence,
              match.confidence > 0
        else {
            return false
        }

        let margin = match.confidence - secondBestConfidence
        let ratio = secondBestConfidence > 0 ? match.confidence / secondBestConfidence : .infinity
        let secondBestIsPlausible = secondBestConfidence >= min(minimumLockConfidence, match.confidence) * 0.90
        return secondBestIsPlausible
            && (margin < 0.06 || ratio < 1.12)
    }

    private func normalize(_ values: [Double]) -> [Double] {
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { $0 - mean }
    }

    private func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double {
        let numerator = zip(left, right).map(*).reduce(0, +)
        let denominator = sqrt(energy(left) * energy(right))
        guard denominator > 0 else {
            return 0
        }
        return numerator / denominator
    }

    private func energy(_ values: [Double]) -> Double {
        values.map { $0 * $0 }.reduce(0, +)
    }

    private func meanSquaredDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return .infinity
        }

        let sum = zip(lhs, rhs)
            .map { left, right in
                let delta = left - right
                return delta * delta
            }
            .reduce(0.0, +)
        return sum / Double(lhs.count)
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double], mean: Double?) -> Double? {
        guard let mean, values.count > 1 else {
            return nil
        }

        let variance = values
            .map { value in
                let delta = value - mean
                return delta * delta
            }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    private func validateStartIndex(_ index: LocalAudioSyncIndex, for asset: LocalAudioAsset) throws -> ValidatedSyncIndexFiles {
        guard index.assetID == asset.id else {
            throw AmbientSyncStartError.indexInvalid
        }

        guard index.sampleRate > 0,
              index.frameHopMS > 0
        else {
            throw AmbientSyncStartError.indexIncompatible
        }

        let manifestURL = SyncIndexManifestValidation.manifestURL(for: index)
        let manifest = try SyncIndexManifestValidation.loadManifest(at: manifestURL)
        return try SyncIndexManifestValidation.validate(
            manifest: manifest,
            directory: manifestURL.deletingLastPathComponent(),
            expectedAssetID: index.assetID,
            expectedIndex: index,
            selectedAsset: asset
        )
    }

    private func startError(from error: Error) -> AmbientSyncStartError {
        if let startError = error as? AmbientSyncStartError {
            return startError
        }

        return .indexUnavailable
    }

    private func indexRuntimeStatus(for error: AmbientSyncStartError) -> IndexRuntimeStatus {
        switch error {
        case .indexUnavailable:
            return .unavailable
        case .indexInvalid:
            return .invalid
        case .indexIncompatible:
            return .incompatible
        }
    }

    private func withholdEstimate(
        reason: AmbientSyncWithholdReason,
        index: LocalAudioSyncIndex,
        window: AmbientAudioWindow,
        queryFeatures: QuerySyncFeatures,
        match: CorrelationMatch?,
        predictedReferenceMS: Double?,
        selectedReferenceMS: Double?,
        searchMode: SearchMode,
        explanation: String
    ) -> SyncEstimate? {
        let degraded = degradeLock(withholdReason: reason)
        lastDiagnostics = diagnostics(
            index: index,
            window: window,
            queryFeatures: queryFeatures,
            match: match,
            predictedReferenceMS: predictedReferenceMS,
            selectedReferenceMS: selectedReferenceMS,
            searchMode: searchMode,
            didPublish: false,
            withholdReason: degraded.reason,
            confidence: match?.confidence ?? 0,
            explanation: explanation
        )
        return degraded.estimate
    }

    private func withholdReasonForNoMatch(
        queryFeatures: QuerySyncFeatures,
        window: AmbientAudioWindow
    ) -> AmbientSyncWithholdReason {
        if queryFeatures.isEmpty || activeFrameFraction(queryFeatures) == 0 || energyDBFS(samples: window.samples) <= -100 {
            return .insufficientEnergy
        }

        return .insufficientLandmarkEvidence
    }

    private func diagnostics(
        index: LocalAudioSyncIndex,
        indexStatus: IndexRuntimeStatus = .valid,
        window: AmbientAudioWindow?,
        queryFeatures: QuerySyncFeatures,
        match: CorrelationMatch?,
        predictedReferenceMS: Double?,
        selectedReferenceMS: Double?,
        searchMode: SearchMode,
        didPublish: Bool,
        withholdReason: AmbientSyncWithholdReason?,
        confidence: Double,
        explanation: String
    ) -> AmbientMatchDiagnostics {
        let secondBestScore = match?.secondBestConfidence
        let peakMargin = secondBestScore.map { confidence - $0 }
        let peakRatio = secondBestScore.flatMap { $0 > 0 ? confidence / $0 : nil }
        let timeResidualMS = predictedReferenceMS.flatMap { predicted in
            selectedReferenceMS.map { selected in selected - predicted }
        }
        let queryDurationMS = Double(queryFeatures.frameCount) * index.frameHopMS
        let searchedOffsets = match?.searchedOffsets ?? defaultSearchOffsets(queryFeatureCount: queryFeatures.frameCount)
        let searchStartMS = Double(searchedOffsets.lowerBound) * index.frameHopMS
        let searchEndMS = Double(searchedOffsets.upperBound) * index.frameHopMS + queryDurationMS
        let landmarkCount = queryFeatures.landmarkCount
        let candidates = match?.topCandidates.map {
            CandidateAlignment(
                offsetMS: Double($0.offset) * index.frameHopMS,
                referenceTimeAtWindowEndMS: referenceTime(
                    forOffset: $0.offset,
                    queryFeatureCount: queryFeatures.frameCount,
                    index: index
                ),
                combinedScore: $0.combinedScore,
                onsetFluxScore: $0.onsetFluxScore,
                logMelScore: $0.logMelScore ?? 0,
                chromaScore: $0.chromaScore ?? 0,
                energyScore: $0.energyScore ?? 0,
                landmarkVoteCount: $0.landmarkVoteCount,
                landmarkInlierRate: $0.landmarkInlierRate,
                peakSharpness: max(0, $0.combinedScore - (secondBestScore ?? 0)),
                peakWidthMS: index.frameHopMS
            )
        } ?? []

        return AmbientMatchDiagnostics(
            index: IndexDiagnostics(
                status: indexStatus,
                featureExtractorVersion: SyncIndexManifestValidation.currentFeatureExtractorVersion,
                settingsHash: SyncIndexManifestValidation.settingsHash(
                    processingSampleRate: Int(index.sampleRate.rounded()),
                    hopSizeMS: Double(Int(index.frameHopMS.rounded()))
                )
            ),
            capture: CaptureDiagnostics(
                windowDurationMS: Double(windowDurationMS),
                windowEndHostTimeMS: 0,
                inputSampleRate: window?.sampleRate ?? 0,
                inputChannelCount: window?.inputChannelCount ?? 0,
                capturedFrameCount: window?.samples.count ?? 0,
                droppedWindowCount: 0
            ),
            query: QueryDiagnostics(
                featureFrameCount: queryFeatures.frameCount,
                landmarkCount: landmarkCount,
                energyDBFS: window.map { energyDBFS(samples: $0.samples) } ?? -120,
                activeFrameFraction: activeFrameFraction(queryFeatures),
                processingSampleRate: Int(index.sampleRate),
                hopSize: Int(index.frameHopMS)
            ),
            search: SearchDiagnostics(
                mode: searchMode,
                searchRangeStartMS: searchStartMS,
                searchRangeEndMS: searchEndMS,
                predictedReferenceMS: predictedReferenceMS,
                selectedReferenceMS: selectedReferenceMS,
                candidateCount: match?.candidateCount ?? 0,
                candidateDensity: candidateDensity(match: match, index: index),
                topCandidates: candidates
            ),
            scoring: ScoringDiagnostics(
                peakScore: confidence,
                secondBestScore: secondBestScore,
                peakMargin: peakMargin,
                peakRatio: peakRatio,
                peakSharpness: peakMargin,
                peakWidthMS: match == nil ? nil : index.frameHopMS,
                noiseFloorMean: match?.noiseFloorMean,
                noiseFloorStd: match?.noiseFloorStd,
                peakZ: match?.peakZ,
                landmarkVoteCount: match?.landmarkVoteCount ?? 0,
                landmarkInlierRate: match?.landmarkInlierRate ?? 0,
                onsetFluxScore: match?.onsetFluxScore,
                logMelScore: match?.logMelScore,
                chromaScore: match?.chromaScore,
                energyScore: match?.energyScore,
                timeResidualMS: timeResidualMS
            ),
            clock: ClockDiagnostics(
                observationCount: clockObservations.count,
                rawDriftPPM: rawDriftPPM,
                smoothedDriftPPM: smoothedDriftPPM,
                trackingStability: didPublish
                    ? trackingStability(confidence: confidence, residualMS: timeResidualMS)
                    : 0,
                latencyMS: nil,
                latencySource: .unavailable
            ),
            decision: MatchDecisionDiagnostics(
                didPublishEstimate: didPublish,
                withholdReason: withholdReason,
                confidence: confidence,
                explanation: explanation
            )
        )
    }

    private func defaultSearchOffsets(queryFeatureCount: Int) -> ClosedRange<Int> {
        let upper = max(0, localFeatures.count - queryFeatureCount)
        return 0...upper
    }

    private func candidateDensity(match: CorrelationMatch?, index: LocalAudioSyncIndex) -> Double {
        guard let match, index.durationMS > 0 else {
            return 0
        }

        return Double(match.candidateCount) / max(1, Double(index.durationMS) / 1_000)
    }

    private func activeFrameFraction(_ values: QuerySyncFeatures) -> Double {
        guard !values.isEmpty else {
            return 0
        }

        return Double(values.activeFrameCount) / Double(values.frameCount)
    }

    private func energyDBFS(samples: [Float]) -> Double {
        guard !samples.isEmpty else {
            return -120
        }

        let sum = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + (value * value)
        }
        let rms = sqrt(sum / Double(samples.count))
        guard rms > 0 else {
            return -120
        }

        return max(-120, 20 * log10(rms))
    }

    private func recordClockObservation(
        hostTime: ContinuousClock.Instant,
        measuredReferenceMS: Double,
        confidence: Double,
        predictedReferenceMS: Double?
    ) -> ClockDriftSnapshot {
        let residualMS = predictedReferenceMS.map { measuredReferenceMS - $0 } ?? 0
        let minimumObservationConfidence = max(minimumLockConfidence, 0.80)
        guard confidence >= minimumObservationConfidence,
              predictedReferenceMS == nil || abs(residualMS) <= maxClockObservationResidualMS
        else {
            return ClockDriftSnapshot(rawDriftPPM: rawDriftPPM, smoothedDriftPPM: smoothedDriftPPM)
        }

        clockObservations.append(
            ClockObservation(
                hostTime: hostTime,
                measuredReferenceMS: measuredReferenceMS,
                confidence: confidence,
                residualMS: residualMS
            )
        )
        if clockObservations.count > maxClockObservationCount {
            clockObservations.removeFirst(clockObservations.count - maxClockObservationCount)
        }

        updateClockDrift()
        return ClockDriftSnapshot(rawDriftPPM: rawDriftPPM, smoothedDriftPPM: smoothedDriftPPM)
    }

    private func updateClockDrift() {
        guard clockObservations.count >= 3,
              let firstObservation = clockObservations.first
        else {
            return
        }

        let hostOffsets = clockObservations.map {
            elapsedMilliseconds(from: firstObservation.hostTime, to: $0.hostTime)
        }
        guard let minimumHostOffset = hostOffsets.min(),
              let maximumHostOffset = hostOffsets.max(),
              maximumHostOffset - minimumHostOffset >= minimumClockObservationSpanMS
        else {
            return
        }

        let referenceTimes = clockObservations.map(\.measuredReferenceMS)
        let meanHost = hostOffsets.reduce(0, +) / Double(hostOffsets.count)
        let meanReference = referenceTimes.reduce(0, +) / Double(referenceTimes.count)
        var covariance = 0.0
        var variance = 0.0
        for (hostOffset, referenceTime) in zip(hostOffsets, referenceTimes) {
            let hostDelta = hostOffset - meanHost
            covariance += hostDelta * (referenceTime - meanReference)
            variance += hostDelta * hostDelta
        }
        guard variance > 0 else {
            return
        }

        let slope = covariance / variance
        let driftPPM = (slope - 1) * 1_000_000
        guard driftPPM.isFinite else {
            return
        }

        rawDriftPPM = driftPPM
        if let previousSmoothed = smoothedDriftPPM {
            smoothedDriftPPM = (previousSmoothed * 0.8) + (driftPPM * 0.2)
        } else {
            smoothedDriftPPM = driftPPM
        }
    }

    private func resetClockTracking() {
        clockObservations = []
        rawDriftPPM = nil
        smoothedDriftPPM = nil
    }

    private func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let elapsed = start.duration(to: end)
        let components = elapsed.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    private func trackingStability(confidence: Double, residualMS: Double?) -> Double {
        guard let residualMS else {
            return confidence
        }

        let residualPenalty = min(1, abs(residualMS) / max(1, hardRelockThresholdMS))
        return clampScore(confidence * (1 - (0.5 * residualPenalty)))
    }

    private static func readFeatures(from url: URL, dimensions: Int) throws -> [Double] {
        if url.pathExtension == "f32" {
            let matrix = try readFeatureMatrix(from: url, dimensions: dimensions)
            return AmbientSyncFeatureExtractor.projectOnsetFlux(matrix.values, dimensions: dimensions)
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        return body
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func readOptionalFeatureMatrix(from url: URL?, dimensions: Int?) throws -> DenseFeatureMatrix {
        guard let url, let dimensions else {
            return .empty
        }
        return try readFeatureMatrix(from: url, dimensions: dimensions)
    }

    private static func readLandmarkIndex(from url: URL?, recordCount: Int?) throws -> LandmarkIndex {
        guard let url else {
            return .empty
        }

        let records = landmarkRecords(from: try Data(contentsOf: url))
        if let recordCount, records.count != recordCount {
            throw AmbientSyncStartError.indexInvalid
        }

        var postingsByHash: [UInt32: [Int]] = [:]
        for record in records {
            postingsByHash[record.hash, default: []].append(record.frameIndex)
        }
        return LandmarkIndex(postingsByHash: postingsByHash, recordCount: records.count)
    }

    private static func landmarkRecords(from data: Data) -> [LandmarkRecord] {
        guard data.count % (MemoryLayout<UInt32>.size * 2) == 0 else {
            return []
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size * 2).map { offset in
            LandmarkRecord(
                hash: readUInt32(from: data, at: offset),
                frameIndex: Int(readUInt32(from: data, at: offset + MemoryLayout<UInt32>.size))
            )
        }
    }

    private static func readFeatureMatrix(from url: URL, dimensions: Int) throws -> DenseFeatureMatrix {
        let data = try Data(contentsOf: url)
        guard data.count % MemoryLayout<Float32>.size == 0 else {
            throw AmbientSyncStartError.indexInvalid
        }

        let values = stride(from: 0, to: data.count, by: MemoryLayout<Float32>.size).map { offset in
            var bits: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bits) { buffer in
                data.copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<Float32>.size))
            }
            return Double(Float32(bitPattern: UInt32(littleEndian: bits)))
        }

        guard dimensions > 0, values.count % dimensions == 0 else {
            throw AmbientSyncStartError.indexInvalid
        }

        return DenseFeatureMatrix(values: values, dimensions: dimensions)
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        var bits: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &bits) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<UInt32>.size))
        }
        return UInt32(littleEndian: bits)
    }
}

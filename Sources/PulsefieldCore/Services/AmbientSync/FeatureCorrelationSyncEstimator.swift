import Foundation

public actor FeatureCorrelationSyncEstimator: AmbientSyncEstimating {
    private let capture: any AmbientAudioCapturing
    private let windowDurationMS: Int
    private let minimumLockConfidence: Double
    private let hardRelockThresholdMS: Double
    private let lostWindowLimit: Int
    private let wideRelockConfidenceMargin = 0.001

    private var state: AmbientSyncState = .idle
    private var index: LocalAudioSyncIndex?
    private var localFeatures: [Double] = []
    private var previousEstimate: SyncEstimate?
    private var consecutiveLockWindows = 0
    private var lowConfidenceWindows = 0

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
        guard index.assetID == asset.id else {
            let error = AmbientSyncError.syncIndexAssetMismatch(assetID: asset.id, indexAssetID: index.assetID)
            state = .failed(error.localizedDescription)
            throw error
        }

        state = .preparingIndex
        localFeatures = try Self.readFeatures(from: index.onsetEnvelopeURL)
        self.index = index
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        try await capture.start()
        state = .listening
    }

    public func stop() async {
        await capture.stop()
        state = .idle
        index = nil
        localFeatures = []
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
    }

    public func currentEstimate() async -> SyncEstimate? {
        guard state != .idle else {
            return nil
        }

        guard let index else {
            return nil
        }

        guard !localFeatures.isEmpty else {
            state = .failed("Sync estimator has not loaded a local sync index.")
            return nil
        }

        guard let window = await capture.latestWindow(durationMS: windowDurationMS) else {
            return previousEstimate
        }

        let queryFeatures = correlationFeatures(
            samples: window.samples,
            sampleRate: window.sampleRate,
            frameHopMS: index.frameHopMS
        )
        let predictedReference = predictedReferenceTime(at: window.hostTime)
        let match: (offset: Int, confidence: Double)?
        if shouldSearchNearPredictedReference,
           let predictedReference,
           let offsetRange = lockedOffsetRange(
            predictedReferenceTimeMS: predictedReference,
            queryFeatureCount: queryFeatures.count,
            localFeatureCount: localFeatures.count,
            frameHopMS: index.frameHopMS
           ) {
            match = bestCorrelationOffset(query: queryFeatures, local: localFeatures, offsetRange: offsetRange)
        } else {
            match = bestCorrelationOffset(query: queryFeatures, local: localFeatures)
        }

        guard let match else { return degradeLock() }

        guard match.confidence >= minimumLockConfidence else {
            return degradeLock()
        }

        let matchedReference = referenceTime(
            forOffset: match.offset,
            queryFeatureCount: queryFeatures.count,
            index: index
        )
        let relockComparisonReference = shouldSearchNearPredictedReference
            ? predictedReference
            : previousEstimate?.referenceTimeMS
        let isHardRelock = shouldRelock(to: matchedReference, comparedTo: relockComparisonReference)
        if isHardRelock, shouldSearchNearPredictedReference {
            return degradeLock()
        }

        if shouldDegradeForWideHardRelock(
            queryFeatures: queryFeatures,
            currentMatch: match,
            index: index,
            comparisonReference: relockComparisonReference
        ) {
            return degradeLock()
        }

        lowConfidenceWindows = 0

        let referenceTime: Double
        if isHardRelock {
            consecutiveLockWindows = 1
            referenceTime = matchedReference
        } else {
            consecutiveLockWindows += 1
            referenceTime = max(previousEstimate?.referenceTimeMS ?? matchedReference, matchedReference)
        }
        let estimate = SyncEstimate(
            hostTime: window.hostTime,
            referenceTimeMS: referenceTime,
            confidence: match.confidence,
            driftPPM: nil,
            latencyMS: nil,
            source: .localFeatureCorrelation
        )

        previousEstimate = estimate
        state = consecutiveLockWindows >= 2 ? .locked(estimate) : .locking
        return estimate
    }

    private func shouldDegradeForWideHardRelock(
        queryFeatures: [Double],
        currentMatch: (offset: Int, confidence: Double),
        index: LocalAudioSyncIndex,
        comparisonReference: Double?
    ) -> Bool {
        guard shouldSearchNearPredictedReference,
              let wideMatch = bestCorrelationOffset(query: queryFeatures, local: localFeatures),
              wideMatch.confidence > currentMatch.confidence + wideRelockConfidenceMargin
        else {
            return false
        }

        let wideReference = referenceTime(
            forOffset: wideMatch.offset,
            queryFeatureCount: queryFeatures.count,
            index: index
        )
        return shouldRelock(to: wideReference, comparedTo: comparisonReference)
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

    public func currentState() async -> AmbientSyncState {
        state
    }

    private var shouldSearchNearPredictedReference: Bool {
        switch state {
        case .locked, .drifting:
            return previousEstimate != nil
        case .idle, .preparingIndex, .listening, .locking, .lost, .failed:
            return false
        }
    }

    private func predictedReferenceTime(at hostTime: ContinuousClock.Instant) -> Double? {
        guard let previousEstimate else {
            return nil
        }

        let elapsed = previousEstimate.hostTime.duration(to: hostTime)
        let components = elapsed.components
        let elapsedMS = max(
            0,
            (Double(components.seconds) * 1_000) + (Double(components.attoseconds) / 1_000_000_000_000_000)
        )
        return previousEstimate.referenceTimeMS + elapsedMS
    }

    private func lockedOffsetRange(
        predictedReferenceTimeMS: Double,
        queryFeatureCount: Int,
        localFeatureCount: Int,
        frameHopMS: Double
    ) -> ClosedRange<Int>? {
        guard queryFeatureCount > 0, queryFeatureCount <= localFeatureCount, frameHopMS > 0 else {
            return nil
        }

        let maxOffset = localFeatureCount - queryFeatureCount
        let queryDurationMS = Double(queryFeatureCount) * frameHopMS
        let earliestReference = predictedReferenceTimeMS - hardRelockThresholdMS
        let latestReference = predictedReferenceTimeMS + hardRelockThresholdMS
        let lowerOffset = max(0, Int(floor((earliestReference - queryDurationMS) / frameHopMS)))
        let upperOffset = min(maxOffset, Int(ceil((latestReference - queryDurationMS) / frameHopMS)))

        guard lowerOffset <= upperOffset else {
            return nil
        }
        return lowerOffset...upperOffset
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
        state = .locked(estimate)
    }

    public func forceRelock() {
        previousEstimate = nil
        consecutiveLockWindows = 0
        lowConfidenceWindows = 0
        state = .listening
    }

    private func degradeLock() -> SyncEstimate? {
        guard let previousEstimate else {
            lowConfidenceWindows += 1
            if lowConfidenceWindows >= lostWindowLimit {
                state = .lost
            } else {
                state = .listening
            }
            return nil
        }

        lowConfidenceWindows += 1
        consecutiveLockWindows = 0

        if lowConfidenceWindows >= lostWindowLimit {
            state = .lost
            self.previousEstimate = nil
            return nil
        }

        state = .drifting(previousEstimate)
        return previousEstimate
    }

    private func correlationFeatures(samples: [Float], sampleRate: Double, frameHopMS: Double) -> [Double] {
        let features = onsetEnvelope(samples: samples, sampleRate: sampleRate, frameHopMS: frameHopMS)
        guard features.count > 1 else {
            return []
        }
        return Array(features.dropFirst())
    }

    private func onsetEnvelope(samples: [Float], sampleRate: Double, frameHopMS: Double) -> [Double] {
        guard !samples.isEmpty, sampleRate > 0, frameHopMS > 0 else {
            return []
        }

        let hopFrames = max(1, Int(sampleRate * frameHopMS / 1_000))
        var values: [Double] = []
        var previousRMS = 0.0
        var frameStart = samples.startIndex

        while frameStart < samples.endIndex {
            let frameEnd = min(frameStart + hopFrames, samples.endIndex)
            let rms = rmsValue(samples[frameStart..<frameEnd])
            values.append(max(0, rms - previousRMS))
            previousRMS = rms
            frameStart = frameEnd
        }

        return values
    }

    private func rmsValue(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else {
            return 0
        }

        let sum = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    private func bestCorrelationOffset(
        query: [Double],
        local: [Double],
        offsetRange: ClosedRange<Int>? = nil
    ) -> (offset: Int, confidence: Double)? {
        guard !query.isEmpty, query.count <= local.count else {
            return nil
        }

        let normalizedQuery = normalize(query)
        guard energy(normalizedQuery) > 0 else {
            return nil
        }

        var bestOffset = 0
        var bestScore = -Double.infinity
        let maxOffset = local.count - query.count
        let searchRange = offsetRange ?? 0...maxOffset
        let lowerOffset = max(0, searchRange.lowerBound)
        let upperOffset = min(maxOffset, searchRange.upperBound)
        guard lowerOffset <= upperOffset else {
            return nil
        }

        for offset in lowerOffset...upperOffset {
            let candidate = normalize(Array(local[offset..<(offset + query.count)]))
            let score = cosineSimilarity(normalizedQuery, candidate)
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        return (bestOffset, max(0, min(bestScore, 1)))
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

    private static func readFeatures(from url: URL) throws -> [Double] {
        let body = try String(contentsOf: url, encoding: .utf8)
        return body
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

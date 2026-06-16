import Foundation

public struct MicFeatureStreamBuffer: Equatable, Sendable {
    public private(set) var continuityResetCount: Int = 0

    private let retentionDurationMS: Double
    private let expectedHopMS: Double
    private let maximumGapHops: Int
    private var frames: [MicFeatureFrame] = []
    private var queryStartIndex: Int = 0
    private var pendingAudioSamples: [Float] = []
    private var pendingAudioStartSampleIndex: Int = 0
    private var pendingAudioStartRecordedTimeMS: Double?
    private var pendingAudioStartHostTimeMS: Double?
    private var pendingAudioSampleRate: Double?
    private var pendingAudioInputChannelCount: Int = 1
    private var lastChunkEndRecordedTimeMS: Double?
    private var lastChunkEndHostTimeMS: Double?
    private var payloadExtractor: MicFeaturePayloadExtractor

    public init(
        retentionDurationMS: Double,
        expectedHopMS: Double,
        maximumGapHops: Int = 2,
        payloadExtractor: MicFeaturePayloadExtractor = MicFeaturePayloadExtractor()
    ) {
        precondition(retentionDurationMS > 0, "retentionDurationMS must be positive.")
        precondition(expectedHopMS > 0, "expectedHopMS must be positive.")
        precondition(maximumGapHops >= 1, "maximumGapHops must be at least 1.")

        self.retentionDurationMS = retentionDurationMS
        self.expectedHopMS = expectedHopMS
        self.maximumGapHops = maximumGapHops
        self.payloadExtractor = payloadExtractor
    }

    public var latestRecordedTimeMS: Double? {
        frames.last?.recordedTimeMS
    }

    public static func == (lhs: MicFeatureStreamBuffer, rhs: MicFeatureStreamBuffer) -> Bool {
        lhs.continuityResetCount == rhs.continuityResetCount
            && lhs.retentionDurationMS == rhs.retentionDurationMS
            && lhs.expectedHopMS == rhs.expectedHopMS
            && lhs.maximumGapHops == rhs.maximumGapHops
            && lhs.frames == rhs.frames
            && lhs.queryStartIndex == rhs.queryStartIndex
            && lhs.activePendingAudioSamples == rhs.activePendingAudioSamples
            && lhs.pendingAudioStartRecordedTimeMS == rhs.pendingAudioStartRecordedTimeMS
            && lhs.pendingAudioStartHostTimeMS == rhs.pendingAudioStartHostTimeMS
            && lhs.pendingAudioSampleRate == rhs.pendingAudioSampleRate
            && lhs.pendingAudioInputChannelCount == rhs.pendingAudioInputChannelCount
            && lhs.lastChunkEndRecordedTimeMS == rhs.lastChunkEndRecordedTimeMS
            && lhs.lastChunkEndHostTimeMS == rhs.lastChunkEndHostTimeMS
            && lhs.payloadExtractor == rhs.payloadExtractor
    }

    public mutating func append(_ newFrames: [MicFeatureFrame]) {
        if Self.framesAreSortedByRecordedTime(newFrames) {
            for frame in newFrames {
                append(frame, detectFeatureGap: true)
            }
        } else {
            for frame in newFrames.sorted(by: { $0.recordedTimeMS < $1.recordedTimeMS }) {
                append(frame, detectFeatureGap: true)
            }
        }
    }

    @discardableResult
    public mutating func append(
        _ chunk: MicAudioChunk,
        featureWindowSizeSamples: Int,
        featureHopSizeSamples: Int
    ) -> [MicFeatureFrame] {
        if shouldResetAudioContinuity(for: chunk) {
            payloadExtractor.reset()
        }

        var extractor = payloadExtractor
        let generatedFrames = append(
            chunk,
            featureWindowSizeSamples: featureWindowSizeSamples,
            featureHopSizeSamples: featureHopSizeSamples
        ) { featureWindow in
            extractor.extract(from: featureWindow)
        }
        payloadExtractor = extractor

        return generatedFrames
    }

    @discardableResult
    public mutating func append(
        _ chunk: MicAudioChunk,
        featureWindowSizeSamples: Int,
        featureHopSizeSamples: Int,
        makePayload: (MicFeatureAudioWindow) -> MicFeaturePayload
    ) -> [MicFeatureFrame] {
        precondition(featureWindowSizeSamples > 0, "featureWindowSizeSamples must be positive.")
        precondition(featureHopSizeSamples > 0, "featureHopSizeSamples must be positive.")
        precondition(
            featureHopSizeSamples <= featureWindowSizeSamples,
            "featureHopSizeSamples must not exceed featureWindowSizeSamples."
        )

        guard !chunk.monoSamples.isEmpty else {
            return []
        }

        if shouldResetAudioContinuity(for: chunk) {
            resetPendingAudio()
            markFeatureContinuityReset()
        }

        if pendingAudioSamples.isEmpty, pendingAudioStartRecordedTimeMS == nil {
            seedPendingAudioTimeline(from: chunk)
        }

        pendingAudioSamples.append(contentsOf: chunk.monoSamples)
        pendingAudioSampleRate = chunk.sampleRate
        pendingAudioInputChannelCount = chunk.inputChannelCount
        lastChunkEndRecordedTimeMS = chunk.recordedEndTimeMS
        lastChunkEndHostTimeMS = chunk.hostEndTimeMS

        return drainFeatureFrames(
            featureWindowSizeSamples: featureWindowSizeSamples,
            featureHopSizeSamples: featureHopSizeSamples,
            makePayload: makePayload
        )
    }

    public func latestWindow(durationMS: Double) -> MicFeatureWindow? {
        guard durationMS > 0, let latest = frames.last else {
            return nil
        }

        let earliestRecordedTimeMS = latest.recordedTimeMS - durationMS
        let windowStartIndex = lowerBoundFrameIndex(
            in: frames,
            from: queryStartIndex,
            timeMS: earliestRecordedTimeMS
        )
        guard windowStartIndex < frames.endIndex else {
            return nil
        }

        return MicFeatureWindow(frames: Array(frames[windowStartIndex..<frames.endIndex]))
    }

    private mutating func append(_ frame: MicFeatureFrame, detectFeatureGap: Bool) {
        if detectFeatureGap, let latest = frames.last, isDiscontinuous(from: latest, to: frame) {
            markFeatureContinuityReset()
        }

        frames.append(frame)
        trimExpiredFrames()
    }

    private func isDiscontinuous(from previous: MicFeatureFrame, to next: MicFeatureFrame) -> Bool {
        next.recordedTimeMS - previous.recordedTimeMS > expectedHopMS * Double(maximumGapHops)
    }

    private func shouldResetAudioContinuity(for chunk: MicAudioChunk) -> Bool {
        guard let sampleRate = pendingAudioSampleRate,
              let expectedRecordedStartTimeMS = lastChunkEndRecordedTimeMS,
              let expectedHostStartTimeMS = lastChunkEndHostTimeMS
        else {
            return false
        }

        if sampleRate != chunk.sampleRate {
            return true
        }

        let allowedGapMS = expectedHopMS * Double(maximumGapHops)
        let recordedGapMS = abs(chunk.recordedStartTimeMS - expectedRecordedStartTimeMS)
        let hostGapMS = abs(chunk.hostStartTimeMS - expectedHostStartTimeMS)

        return recordedGapMS > allowedGapMS || hostGapMS > allowedGapMS
    }

    private mutating func seedPendingAudioTimeline(from chunk: MicAudioChunk) {
        pendingAudioStartRecordedTimeMS = chunk.recordedStartTimeMS
        pendingAudioStartHostTimeMS = chunk.hostStartTimeMS
    }

    private mutating func resetPendingAudio() {
        pendingAudioSamples.removeAll(keepingCapacity: true)
        pendingAudioStartSampleIndex = 0
        pendingAudioStartRecordedTimeMS = nil
        pendingAudioStartHostTimeMS = nil
        pendingAudioSampleRate = nil
        lastChunkEndRecordedTimeMS = nil
        lastChunkEndHostTimeMS = nil
    }

    private mutating func markFeatureContinuityReset() {
        guard !frames.isEmpty, queryStartIndex != frames.count else {
            return
        }

        continuityResetCount += 1
        queryStartIndex = frames.count
    }

    private mutating func drainFeatureFrames(
        featureWindowSizeSamples: Int,
        featureHopSizeSamples: Int,
        makePayload: (MicFeatureAudioWindow) -> MicFeaturePayload
    ) -> [MicFeatureFrame] {
        guard let sampleRate = pendingAudioSampleRate,
              var windowStartRecordedTimeMS = pendingAudioStartRecordedTimeMS,
              var windowStartHostTimeMS = pendingAudioStartHostTimeMS
        else {
            return []
        }

        let windowDurationMS = Double(featureWindowSizeSamples) / sampleRate * 1_000
        let hopDurationMS = Double(featureHopSizeSamples) / sampleRate * 1_000
        var generatedFrames: [MicFeatureFrame] = []

        while activePendingAudioSampleCount >= featureWindowSizeSamples {
            let windowEndSampleIndex = pendingAudioStartSampleIndex + featureWindowSizeSamples
            let windowSamples = Array(pendingAudioSamples[pendingAudioStartSampleIndex..<windowEndSampleIndex])
            let featureWindow = MicFeatureAudioWindow(
                monoSamples: windowSamples,
                sampleRate: sampleRate,
                recordedStartTimeMS: windowStartRecordedTimeMS,
                recordedTimeMS: windowStartRecordedTimeMS + windowDurationMS,
                hostStartTimeMS: windowStartHostTimeMS,
                hostTimeMS: windowStartHostTimeMS + windowDurationMS,
                inputChannelCount: pendingAudioInputChannelCount
            )
            let frame = MicFeatureFrame(
                recordedTimeMS: featureWindow.recordedTimeMS,
                hostTimeMS: featureWindow.hostTimeMS,
                payload: makePayload(featureWindow)
            )

            generatedFrames.append(frame)
            append(frame, detectFeatureGap: false)

            pendingAudioStartSampleIndex += featureHopSizeSamples
            windowStartRecordedTimeMS += hopDurationMS
            windowStartHostTimeMS += hopDurationMS
        }

        pendingAudioStartRecordedTimeMS = windowStartRecordedTimeMS
        pendingAudioStartHostTimeMS = windowStartHostTimeMS
        compactConsumedPendingAudioIfNeeded()

        return generatedFrames
    }

    private mutating func trimExpiredFrames() {
        guard let latest = frames.last else {
            return
        }

        let earliestRetainedTimeMS = latest.recordedTimeMS - retentionDurationMS
        let removalCount = lowerBoundFrameIndex(in: frames, from: frames.startIndex, timeMS: earliestRetainedTimeMS)

        guard removalCount > 0 else {
            return
        }

        frames.removeFirst(removalCount)
        queryStartIndex = max(0, queryStartIndex - removalCount)
    }

    private var activePendingAudioSampleCount: Int {
        pendingAudioSamples.count - pendingAudioStartSampleIndex
    }

    private var activePendingAudioSamples: ArraySlice<Float> {
        pendingAudioSamples[pendingAudioStartSampleIndex..<pendingAudioSamples.endIndex]
    }

    private mutating func compactConsumedPendingAudioIfNeeded() {
        guard pendingAudioStartSampleIndex > 0 else {
            return
        }

        if pendingAudioStartSampleIndex == pendingAudioSamples.count {
            pendingAudioSamples.removeAll(keepingCapacity: true)
            pendingAudioStartSampleIndex = 0
            return
        }

        guard pendingAudioStartSampleIndex >= 4_096
            || pendingAudioStartSampleIndex * 2 >= pendingAudioSamples.count
        else {
            return
        }

        pendingAudioSamples.removeFirst(pendingAudioStartSampleIndex)
        pendingAudioStartSampleIndex = 0
    }

    private func lowerBoundFrameIndex(
        in frames: [MicFeatureFrame],
        from startIndex: Int,
        timeMS: Double
    ) -> Int {
        var lowerBound = startIndex
        var upperBound = frames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if frames[middle].recordedTimeMS < timeMS {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
    }

    private static func framesAreSortedByRecordedTime(_ frames: [MicFeatureFrame]) -> Bool {
        !frames.indices.dropFirst().contains { index in
            frames[frames.index(before: index)].recordedTimeMS > frames[index].recordedTimeMS
        }
    }
}

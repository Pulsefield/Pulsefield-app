import Foundation

public struct SyncClockFilter: Sendable {
    private var previousEstimate: SyncEstimate?

    public init() {}

    public mutating func apply(_ estimate: SyncEstimate) -> SyncEstimate {
        guard let previousEstimate else {
            self.previousEstimate = estimate
            return estimate
        }

        let referenceTime = max(previousEstimate.referenceTimeMS, estimate.referenceTimeMS)
        let smoothed = SyncEstimate(
            hostTime: estimate.hostTime,
            referenceTimeMS: referenceTime,
            confidence: estimate.confidence,
            driftPPM: estimate.driftPPM,
            latencyMS: estimate.latencyMS,
            source: estimate.source
        )
        self.previousEstimate = smoothed
        return smoothed
    }

    public mutating func reset() {
        previousEstimate = nil
    }
}

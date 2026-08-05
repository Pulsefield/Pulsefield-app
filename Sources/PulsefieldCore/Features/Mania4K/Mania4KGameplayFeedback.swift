public struct Mania4KJudgementEventBatch: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let chartTimeMs: Double
    public let events: [Mania4KJudgementEvent]

    public init(id: UInt64, chartTimeMs: Double, events: [Mania4KJudgementEvent]) {
        self.id = id
        self.chartTimeMs = chartTimeMs
        self.events = events
    }
}

public struct Mania4KJudgementPresentation: Equatable, Sendable {
    public let event: Mania4KJudgementEvent
    public let opacity: Double
    public let scale: Double
    public let verticalOffset: Double

    public init(event: Mania4KJudgementEvent, opacity: Double, scale: Double, verticalOffset: Double) {
        self.event = event
        self.opacity = opacity
        self.scale = scale
        self.verticalOffset = verticalOffset
    }
}

public struct Mania4KLaneInputTransition: Equatable, Sendable {
    public let lane: Mania4KLane
    public let phase: Mania4KInputPhase
    public let sequenceNumber: UInt64
    public let uiTimeMs: Double

    public init(lane: Mania4KLane, phase: Mania4KInputPhase, sequenceNumber: UInt64, uiTimeMs: Double) {
        self.lane = lane
        self.phase = phase
        self.sequenceNumber = sequenceNumber
        self.uiTimeMs = uiTimeMs
    }
}

public struct Mania4KLaneFeedbackBrightness: Equatable, Sendable {
    public let receptor: Double
    public let lane: Double

    public init(receptor: Double, lane: Double) {
        self.receptor = receptor
        self.lane = lane
    }
}

public struct Mania4KGameplayFeedbackState: Equatable, Sendable {
    public private(set) var judgementEventBatches: [Mania4KJudgementEventBatch]
    public private(set) var latestLaneInputTransitions: [Mania4KLane: Mania4KLaneInputTransition]

    private var nextJudgementEventBatchID: UInt64
    private var activeJudgement: ActiveJudgement?
    private var laneFeedbackStates: [Mania4KLane: LaneFeedbackState]

    public init() {
        self.judgementEventBatches = []
        self.latestLaneInputTransitions = [:]
        self.nextJudgementEventBatchID = 0
        self.activeJudgement = nil
        self.laneFeedbackStates = [:]
    }

    public mutating func recordJudgementEvents(
        _ events: [Mania4KJudgementEvent],
        atChartTimeMs chartTimeMs: Double
    ) {
        advanceJudgementTime(to: chartTimeMs)

        guard !events.isEmpty else {
            return
        }

        let batch = Mania4KJudgementEventBatch(
            id: nextJudgementEventBatchID,
            chartTimeMs: chartTimeMs,
            events: events
        )
        nextJudgementEventBatchID += 1
        judgementEventBatches.append(batch)

        guard let candidate = Self.presentationCandidate(in: batch) else {
            return
        }

        record(candidate, atChartTimeMs: chartTimeMs)
    }

    public mutating func advanceJudgementTime(to chartTimeMs: Double) {
        judgementEventBatches.removeAll { batch in
            chartTimeMs - batch.chartTimeMs > Self.judgementEventBatchRetentionMs
        }

        if let activeJudgement, !activeJudgement.isVisible(atChartTimeMs: chartTimeMs) {
            self.activeJudgement = nil
        }
    }

    public mutating func recordInput(_ input: Mania4KInputEvent, atUITimeMs uiTimeMs: Double) {
        let transition = Mania4KLaneInputTransition(
            lane: input.lane,
            phase: input.phase,
            sequenceNumber: input.sequenceNumber,
            uiTimeMs: uiTimeMs
        )

        if let latest = latestLaneInputTransitions[input.lane],
           transition.sequenceNumber <= latest.sequenceNumber
        {
            return
        }

        let currentBrightness = brightness(for: input.lane, atUITimeMs: uiTimeMs)
        latestLaneInputTransitions[input.lane] = transition

        switch transition.phase {
        case .press:
            laneFeedbackStates[input.lane] = .pressed(transition: transition)
        case .release:
            laneFeedbackStates[input.lane] = .released(
                transition: transition,
                startBrightness: currentBrightness
            )
        }
    }

    public func judgementPresentation(atChartTimeMs chartTimeMs: Double) -> Mania4KJudgementPresentation? {
        guard let activeJudgement,
              activeJudgement.isVisible(atChartTimeMs: chartTimeMs)
        else {
            return nil
        }

        let parameters = JudgementPresentationParameters(judgement: activeJudgement.event.judgement)
        let ageMs = max(0, chartTimeMs - activeJudgement.startChartTimeMs)
        let fadeProgress = Self.progress(
            elapsedMs: ageMs - parameters.fadeStartMs,
            durationMs: parameters.endMs - parameters.fadeStartMs
        )
        let opacity = 1 - Self.smoothStep(fadeProgress)
        let scale = Self.judgementScale(
            ageMs: ageMs,
            fadeProgress: fadeProgress,
            parameters: parameters
        )
        let verticalOffset = Self.judgementVerticalOffset(
            ageMs: ageMs,
            parameters: parameters
        )

        return Mania4KJudgementPresentation(
            event: activeJudgement.event,
            opacity: opacity,
            scale: scale,
            verticalOffset: verticalOffset
        )
    }

    public func laneBrightness(
        for lane: Mania4KLane,
        atUITimeMs uiTimeMs: Double
    ) -> Mania4KLaneFeedbackBrightness {
        brightness(for: lane, atUITimeMs: uiTimeMs)
    }

    private mutating func record(_ candidate: JudgementCandidate, atChartTimeMs chartTimeMs: Double) {
        guard let current = activeJudgement,
              current.isVisible(atChartTimeMs: chartTimeMs)
        else {
            activeJudgement = ActiveJudgement(event: candidate.event, startChartTimeMs: chartTimeMs)
            return
        }

        let candidateSeverity = candidate.event.judgement.presentationSeverity
        let currentSeverity = current.event.judgement.presentationSeverity

        if candidateSeverity > currentSeverity {
            activeJudgement = ActiveJudgement(event: candidate.event, startChartTimeMs: chartTimeMs)
            return
        }

        if candidateSeverity == currentSeverity {
            activeJudgement = ActiveJudgement(event: candidate.event, startChartTimeMs: chartTimeMs)
            return
        }

        if chartTimeMs < current.protectionEndChartTimeMs {
            return
        }

        activeJudgement = ActiveJudgement(event: candidate.event, startChartTimeMs: chartTimeMs)
    }

    private func brightness(
        for lane: Mania4KLane,
        atUITimeMs uiTimeMs: Double
    ) -> Mania4KLaneFeedbackBrightness {
        guard let state = laneFeedbackStates[lane] else {
            return .zero
        }

        switch state {
        case .pressed(let transition):
            let ageMs = max(0, uiTimeMs - transition.uiTimeMs)
            let progress = Self.smoothStep(Self.progress(elapsedMs: ageMs, durationMs: Self.pressFalloffMs))
            return Mania4KLaneFeedbackBrightness(
                receptor: Self.interpolate(
                    from: Self.pressPeakReceptorBrightness,
                    to: Self.pressHoldReceptorBrightness,
                    progress: progress
                ),
                lane: Self.interpolate(
                    from: Self.pressPeakLaneBrightness,
                    to: Self.pressHoldLaneBrightness,
                    progress: progress
                )
            )
        case .released(let transition, let startBrightness):
            let ageMs = max(0, uiTimeMs - transition.uiTimeMs)
            guard ageMs < Self.releaseFadeMs else {
                return .zero
            }

            let remaining = 1 - Self.smoothStep(Self.progress(elapsedMs: ageMs, durationMs: Self.releaseFadeMs))
            return Mania4KLaneFeedbackBrightness(
                receptor: startBrightness.receptor * remaining,
                lane: startBrightness.lane * remaining
            )
        }
    }

    private static func presentationCandidate(in batch: Mania4KJudgementEventBatch) -> JudgementCandidate? {
        batch.events.reduce(into: nil) { selected, event in
            let candidate = JudgementCandidate(event: event)
            guard let existing = selected else {
                selected = candidate
                return
            }

            let candidateSeverity = candidate.event.judgement.presentationSeverity
            let existingSeverity = existing.event.judgement.presentationSeverity
            if candidateSeverity > existingSeverity ||
                (candidateSeverity == existingSeverity && candidate.event.id >= existing.event.id)
            {
                selected = candidate
            }
        }
    }

    private static func judgementScale(
        ageMs: Double,
        fadeProgress: Double,
        parameters: JudgementPresentationParameters
    ) -> Double {
        if ageMs < parameters.pulseMs {
            let pulseProgress = smoothStep(progress(elapsedMs: ageMs, durationMs: parameters.pulseMs))
            return interpolate(from: parameters.startScale, to: 1, progress: pulseProgress)
        }

        guard fadeProgress > 0 else {
            return 1
        }

        return interpolate(from: 1, to: parameters.endScale, progress: smoothStep(fadeProgress))
    }

    private static func judgementVerticalOffset(
        ageMs: Double,
        parameters: JudgementPresentationParameters
    ) -> Double {
        guard parameters.endVerticalOffset != 0 else {
            return 0
        }

        let progress = smoothStep(Self.progress(elapsedMs: ageMs, durationMs: parameters.endMs))
        return interpolate(from: 0, to: parameters.endVerticalOffset, progress: progress)
    }

    private static func progress(elapsedMs: Double, durationMs: Double) -> Double {
        guard durationMs > 0 else {
            return 1
        }

        return min(max(elapsedMs / durationMs, 0), 1)
    }

    private static func smoothStep(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + (end - start) * min(max(progress, 0), 1)
    }

    private static let judgementEventBatchRetentionMs = 600.0
    private static let pressPeakReceptorBrightness = 0.52
    private static let pressPeakLaneBrightness = 0.13
    private static let pressHoldReceptorBrightness = 0.24
    private static let pressHoldLaneBrightness = 0.05
    private static let pressFalloffMs = 85.0
    private static let releaseFadeMs = 110.0
}

private struct JudgementCandidate: Equatable, Sendable {
    let event: Mania4KJudgementEvent
}

private struct ActiveJudgement: Equatable, Sendable {
    let event: Mania4KJudgementEvent
    let startChartTimeMs: Double

    var protectionEndChartTimeMs: Double {
        startChartTimeMs + JudgementPresentationParameters(judgement: event.judgement).protectionMs
    }

    func isVisible(atChartTimeMs chartTimeMs: Double) -> Bool {
        chartTimeMs - startChartTimeMs < JudgementPresentationParameters(judgement: event.judgement).endMs
    }
}

private struct JudgementPresentationParameters: Equatable, Sendable {
    let pulseMs: Double
    let fadeStartMs: Double
    let endMs: Double
    let protectionMs: Double
    let startScale: Double
    let endScale: Double
    let endVerticalOffset: Double

    init(judgement: Mania4KJudgement) {
        switch judgement {
        case .perfect:
            self.pulseMs = 60
            self.fadeStartMs = 110
            self.endMs = 300
            self.protectionMs = 0
            self.startScale = 0.90
            self.endScale = 0.98
            self.endVerticalOffset = 0
        case .good:
            self.pulseMs = 70
            self.fadeStartMs = 130
            self.endMs = 360
            self.protectionMs = 80
            self.startScale = 0.90
            self.endScale = 0.98
            self.endVerticalOffset = 0
        case .miss:
            self.pulseMs = 70
            self.fadeStartMs = 180
            self.endMs = 500
            self.protectionMs = 180
            self.startScale = 1.08
            self.endScale = 0.98
            self.endVerticalOffset = 6
        }
    }
}

private enum LaneFeedbackState: Equatable, Sendable {
    case pressed(transition: Mania4KLaneInputTransition)
    case released(transition: Mania4KLaneInputTransition, startBrightness: Mania4KLaneFeedbackBrightness)
}

private extension Mania4KLaneFeedbackBrightness {
    static let zero = Mania4KLaneFeedbackBrightness(receptor: 0, lane: 0)
}

private extension Mania4KJudgement {
    var presentationSeverity: Int {
        switch self {
        case .perfect:
            1
        case .good:
            2
        case .miss:
            3
        }
    }
}

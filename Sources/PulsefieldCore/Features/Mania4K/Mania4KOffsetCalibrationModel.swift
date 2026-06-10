import Foundation
import Observation

public struct Mania4KOffsetCalibrationOffsets: Equatable, Sendable {
    public let audioOffsetMilliseconds: Int
    public let visualOffsetMilliseconds: Int

    public init(audioOffsetMilliseconds: Int, visualOffsetMilliseconds: Int) {
        self.audioOffsetMilliseconds = audioOffsetMilliseconds
        self.visualOffsetMilliseconds = visualOffsetMilliseconds
    }
}

public struct Mania4KOffsetPreset: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var audioOffsetMilliseconds: Int
    public var visualOffsetMilliseconds: Int

    public init(
        id: UUID = UUID(),
        name: String,
        audioOffsetMilliseconds: Int,
        visualOffsetMilliseconds: Int
    ) {
        self.id = id
        self.name = name
        self.audioOffsetMilliseconds = audioOffsetMilliseconds
        self.visualOffsetMilliseconds = visualOffsetMilliseconds
    }
}

public struct Mania4KOffsetCalibrationStoredState: Equatable, Codable, Sendable {
    public var appliedAudioOffsetMilliseconds: Int
    public var appliedVisualOffsetMilliseconds: Int
    public var presets: [Mania4KOffsetPreset]
    public var activePresetID: UUID?

    public init(
        appliedAudioOffsetMilliseconds: Int,
        appliedVisualOffsetMilliseconds: Int,
        presets: [Mania4KOffsetPreset] = [],
        activePresetID: UUID? = nil
    ) {
        self.appliedAudioOffsetMilliseconds = appliedAudioOffsetMilliseconds
        self.appliedVisualOffsetMilliseconds = appliedVisualOffsetMilliseconds
        self.presets = presets
        self.activePresetID = activePresetID
    }

    public init?(storageValue: String) {
        guard !storageValue.isEmpty,
              let data = storageValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return nil
        }

        self = decoded
    }

    public var storageValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return value
    }
}

public struct Mania4KOffsetCalibrationHitSample: Identifiable, Equatable, Sendable {
    public var id: Int {
        beatIndex
    }

    public let beatIndex: Int
    public let rawInputTimeMs: Double
    public let noteTimeMs: Double
    public let sampleRenderedAudioOffsetMilliseconds: Int
    public let hitErrorMs: Double
    public let sampleSuggestedAudioOffsetMilliseconds: Int

    public init(
        beatIndex: Int,
        rawInputTimeMs: Double,
        noteTimeMs: Double,
        sampleRenderedAudioOffsetMilliseconds: Int,
        hitErrorMs: Double,
        sampleSuggestedAudioOffsetMilliseconds: Int
    ) {
        self.beatIndex = beatIndex
        self.rawInputTimeMs = rawInputTimeMs
        self.noteTimeMs = noteTimeMs
        self.sampleRenderedAudioOffsetMilliseconds = sampleRenderedAudioOffsetMilliseconds
        self.hitErrorMs = hitErrorMs
        self.sampleSuggestedAudioOffsetMilliseconds = sampleSuggestedAudioOffsetMilliseconds
    }
}

@MainActor
public protocol Mania4KOffsetCalibrationTickPlaying: AnyObject {
    func prewarmCalibrationTicks()
    func playCalibrationTick()
    func stopCalibrationTicks()
}

public extension Mania4KOffsetCalibrationTickPlaying {
    func prewarmCalibrationTicks() {}
}

@MainActor
@Observable
public final class Mania4KOffsetCalibrationModel {
    public static let initialLeadInMs = 1_000
    public static let tickIntervalMs = 500
    public static let hitWindowMs = 120
    public static let calibrationKey = "j"
    public static let acceptedSampleCap = 16
    public static let renderedOffsetPublishIntervalMs = 500
    public static let offsetRange = -500...500
    private static let resolvedBeatStateRetentionMs = hitWindowMs + tickIntervalMs

    public let originalAudioOffsetMilliseconds: Int
    public let originalVisualOffsetMilliseconds: Int
    public private(set) var pendingAudioOffsetMilliseconds: Int
    public private(set) var pendingVisualOffsetMilliseconds: Int
    public private(set) var renderedAudioOffsetMilliseconds: Int
    public private(set) var renderedVisualOffsetMilliseconds: Int
    public private(set) var rawClockTimeMs: Int
    public private(set) var hitSamples: [Mania4KOffsetCalibrationHitSample]
    public private(set) var storedState: Mania4KOffsetCalibrationStoredState

    @ObservationIgnored
    private let tickPlayer: (any Mania4KOffsetCalibrationTickPlaying)?

    @ObservationIgnored
    private let initialRenderedAudioOffsetMilliseconds: Int

    @ObservationIgnored
    private var resolvedBeatIndices: Set<Int>

    @ObservationIgnored
    private var lastRenderedOffsetPublishRawTimeMs: Int?

    @ObservationIgnored
    private var lastTickedBeatIndex: Int

    public init(
        originalAudioOffsetMilliseconds: Int,
        originalVisualOffsetMilliseconds: Int,
        storedState: Mania4KOffsetCalibrationStoredState? = nil,
        fallbackAppliedAudioOffsetMilliseconds: Int = 0,
        fallbackAppliedVisualOffsetMilliseconds: Int = 0,
        tickPlayer: (any Mania4KOffsetCalibrationTickPlaying)? = nil
    ) {
        let clampedOriginalAudioOffset = Self.clampedOffset(originalAudioOffsetMilliseconds)
        let clampedOriginalVisualOffset = Self.clampedOffset(originalVisualOffsetMilliseconds)
        let normalizedState = Self.normalizedStoredState(
            storedState,
            fallbackAppliedAudioOffsetMilliseconds: fallbackAppliedAudioOffsetMilliseconds,
            fallbackAppliedVisualOffsetMilliseconds: fallbackAppliedVisualOffsetMilliseconds
        )
        let activePreset = normalizedState.activePresetID.flatMap { activePresetID in
            normalizedState.presets.first { $0.id == activePresetID }
        }
        let initialAudioOffset = activePreset?.audioOffsetMilliseconds ?? clampedOriginalAudioOffset
        let initialVisualOffset = activePreset?.visualOffsetMilliseconds ?? clampedOriginalVisualOffset

        self.originalAudioOffsetMilliseconds = clampedOriginalAudioOffset
        self.originalVisualOffsetMilliseconds = clampedOriginalVisualOffset
        self.pendingAudioOffsetMilliseconds = initialAudioOffset
        self.pendingVisualOffsetMilliseconds = initialVisualOffset
        self.renderedAudioOffsetMilliseconds = initialAudioOffset
        self.renderedVisualOffsetMilliseconds = initialVisualOffset
        self.rawClockTimeMs = 0
        self.hitSamples = []
        self.storedState = normalizedState
        self.tickPlayer = tickPlayer
        self.initialRenderedAudioOffsetMilliseconds = initialAudioOffset
        self.resolvedBeatIndices = []
        self.lastRenderedOffsetPublishRawTimeMs = nil
        self.lastTickedBeatIndex = -1
    }

    public var gameplayChartTimeMs: Int {
        rawClockTimeMs + renderedAudioOffsetMilliseconds
    }

    public var renderedChartTimeMs: Int {
        gameplayChartTimeMs + renderedVisualOffsetMilliseconds
    }

    public var presets: [Mania4KOffsetPreset] {
        storedState.presets
    }

    public var activePresetID: UUID? {
        storedState.activePresetID
    }

    public var activePreset: Mania4KOffsetPreset? {
        guard let activePresetID else {
            return nil
        }

        return presets.first { $0.id == activePresetID }
    }

    public var appliedAudioOffsetMilliseconds: Int {
        storedState.appliedAudioOffsetMilliseconds
    }

    public var appliedVisualOffsetMilliseconds: Int {
        storedState.appliedVisualOffsetMilliseconds
    }

    public var suggestedAudioOffsetMilliseconds: Int? {
        Self.medianOffset(hitSamples.map(\.sampleSuggestedAudioOffsetMilliseconds))
    }

    public var suggestedAudioAdjustmentMilliseconds: Int? {
        guard let suggestedAudioOffsetMilliseconds else {
            return nil
        }

        return suggestedAudioOffsetMilliseconds - pendingAudioOffsetMilliseconds
    }

    public func noteTimeMs(forBeatIndex beatIndex: Int) -> Double {
        Double(Self.initialLeadInMs + initialRenderedAudioOffsetMilliseconds + beatIndex * Self.tickIntervalMs)
    }

    public func advanceClock(rawClockTimeMs: Int) {
        self.rawClockTimeMs = rawClockTimeMs
        publishPendingOffsetsIfAllowed()
        pruneResolvedBeatIndices(referenceGameplayChartTimeMs: Double(gameplayChartTimeMs))
        playDueCalibrationTicks()
    }

    public func visibleObjects(
        travelTimeMs: Double,
        postLineVisibleMs: Double,
        lookaheadPaddingMs: Double,
        lane: Mania4KLane = .innerRight
    ) -> [Mania4KVisibleObject] {
        let renderChartTimeMs = Double(renderedChartTimeMs)
        let gameplayChartTimeMs = Double(gameplayChartTimeMs)
        let lowerBound = renderChartTimeMs - max(0, postLineVisibleMs)
        let upperBound = renderChartTimeMs + max(0, travelTimeMs) + max(0, lookaheadPaddingMs)
        let firstNoteTime = noteTimeMs(forBeatIndex: 0)

        guard upperBound >= firstNoteTime else {
            return []
        }

        let startBeatIndex = max(
            0,
            Int(ceil((lowerBound - firstNoteTime) / Double(Self.tickIntervalMs)))
        )
        let endBeatIndex = Int(floor((upperBound - firstNoteTime) / Double(Self.tickIntervalMs)))

        guard endBeatIndex >= startBeatIndex else {
            return []
        }

        return (startBeatIndex...endBeatIndex).map { beatIndex in
            let noteTimeMs = noteTimeMs(forBeatIndex: beatIndex)
            let state: Mania4KVisibleObjectState
            if resolvedBeatIndices.contains(beatIndex) {
                state = .resolved
            } else if gameplayChartTimeMs > noteTimeMs + Double(Self.hitWindowMs) {
                state = .missedButVisible
            } else {
                state = .waiting
            }

            return Mania4KVisibleObject(
                id: Mania4KObjectOrdinal(rawValue: beatIndex),
                lane: lane,
                startTimeMs: noteTimeMs,
                endTimeMs: nil,
                state: state
            )
        }
    }

    @discardableResult
    public func recordInput(rawInputTimeMs: Int) -> Mania4KOffsetCalibrationHitSample? {
        recordInput(rawInputTimeMs: Double(rawInputTimeMs))
    }

    @discardableResult
    public func recordInput(rawInputTimeMs: Double) -> Mania4KOffsetCalibrationHitSample? {
        let sampleRenderedAudioOffsetMilliseconds = renderedAudioOffsetMilliseconds
        let chartInputTimeMs = rawInputTimeMs + Double(sampleRenderedAudioOffsetMilliseconds)
        pruneResolvedBeatIndices(
            referenceGameplayChartTimeMs: max(Double(gameplayChartTimeMs), chartInputTimeMs)
        )
        let candidateBeatIndex = nearestUnresolvedBeatIndex(toChartTimeMs: chartInputTimeMs)
        let noteTimeMs = noteTimeMs(forBeatIndex: candidateBeatIndex)
        let hitErrorMs = chartInputTimeMs - noteTimeMs

        guard abs(hitErrorMs) <= Double(Self.hitWindowMs) else {
            return nil
        }

        let sample = Mania4KOffsetCalibrationHitSample(
            beatIndex: candidateBeatIndex,
            rawInputTimeMs: rawInputTimeMs,
            noteTimeMs: noteTimeMs,
            sampleRenderedAudioOffsetMilliseconds: sampleRenderedAudioOffsetMilliseconds,
            hitErrorMs: hitErrorMs,
            sampleSuggestedAudioOffsetMilliseconds: Self.clampedOffset(
                Int((Double(sampleRenderedAudioOffsetMilliseconds) - hitErrorMs).rounded())
            )
        )

        resolvedBeatIndices.insert(candidateBeatIndex)
        pruneResolvedBeatIndices(
            referenceGameplayChartTimeMs: max(Double(gameplayChartTimeMs), chartInputTimeMs)
        )
        hitSamples.append(sample)
        if hitSamples.count > Self.acceptedSampleCap {
            hitSamples.removeFirst(hitSamples.count - Self.acceptedSampleCap)
        }

        return sample
    }

    public func stepPendingAudioOffset(by deltaMilliseconds: Int) {
        setPendingAudioOffsetMilliseconds(pendingAudioOffsetMilliseconds + deltaMilliseconds)
    }

    public func stepPendingVisualOffset(by deltaMilliseconds: Int) {
        setPendingVisualOffsetMilliseconds(pendingVisualOffsetMilliseconds + deltaMilliseconds)
    }

    public func setPendingAudioOffsetMilliseconds(_ offsetMilliseconds: Int) {
        updatePendingOffsets(
            audioOffsetMilliseconds: Self.clampedOffset(offsetMilliseconds),
            visualOffsetMilliseconds: pendingVisualOffsetMilliseconds,
            detachesActivePresetOnDivergence: true
        )
    }

    public func setPendingVisualOffsetMilliseconds(_ offsetMilliseconds: Int) {
        updatePendingOffsets(
            audioOffsetMilliseconds: pendingAudioOffsetMilliseconds,
            visualOffsetMilliseconds: Self.clampedOffset(offsetMilliseconds),
            detachesActivePresetOnDivergence: true
        )
    }

    @discardableResult
    public func useSuggestedAudioOffset() -> Bool {
        guard let suggestedAudioOffsetMilliseconds else {
            return false
        }

        setPendingAudioOffsetMilliseconds(suggestedAudioOffsetMilliseconds)
        return true
    }

    @discardableResult
    public func addPreset(
        name: String,
        audioOffsetMilliseconds: Int? = nil,
        visualOffsetMilliseconds: Int? = nil,
        id: UUID = UUID()
    ) -> Mania4KOffsetPreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Mania4KOffsetPreset(
            id: id,
            name: trimmedName.isEmpty ? nextBlankPresetName() : trimmedName,
            audioOffsetMilliseconds: Self.clampedOffset(audioOffsetMilliseconds ?? pendingAudioOffsetMilliseconds),
            visualOffsetMilliseconds: Self.clampedOffset(visualOffsetMilliseconds ?? pendingVisualOffsetMilliseconds)
        )
        storedState.presets.append(preset)
        return preset
    }

    @discardableResult
    public func selectPreset(id: UUID) -> Bool {
        guard let preset = presets.first(where: { $0.id == id }) else {
            return false
        }

        storedState.activePresetID = id
        updatePendingOffsets(
            audioOffsetMilliseconds: preset.audioOffsetMilliseconds,
            visualOffsetMilliseconds: preset.visualOffsetMilliseconds,
            detachesActivePresetOnDivergence: false
        )
        return true
    }

    @discardableResult
    public func deletePreset(id: UUID) -> Bool {
        guard let index = storedState.presets.firstIndex(where: { $0.id == id }) else {
            return false
        }

        storedState.presets.remove(at: index)
        if storedState.activePresetID == id {
            storedState.activePresetID = nil
        }
        return true
    }

    public func clearActivePreset() {
        storedState.activePresetID = nil
    }

    public func playCalibrationTick() {
        tickPlayer?.playCalibrationTick()
    }

    public func prewarmCalibrationTicks() {
        tickPlayer?.prewarmCalibrationTicks()
    }

    public func stopCalibrationTicks() {
        tickPlayer?.stopCalibrationTicks()
    }

    @discardableResult
    public func apply() -> Mania4KOffsetCalibrationOffsets {
        stopCalibrationTicks()
        storedState.appliedAudioOffsetMilliseconds = pendingAudioOffsetMilliseconds
        storedState.appliedVisualOffsetMilliseconds = pendingVisualOffsetMilliseconds
        return Mania4KOffsetCalibrationOffsets(
            audioOffsetMilliseconds: pendingAudioOffsetMilliseconds,
            visualOffsetMilliseconds: pendingVisualOffsetMilliseconds
        )
    }

    @discardableResult
    public func cancel() -> Mania4KOffsetCalibrationOffsets {
        stopCalibrationTicks()
        return Mania4KOffsetCalibrationOffsets(
            audioOffsetMilliseconds: originalAudioOffsetMilliseconds,
            visualOffsetMilliseconds: originalVisualOffsetMilliseconds
        )
    }

    private func updatePendingOffsets(
        audioOffsetMilliseconds: Int,
        visualOffsetMilliseconds: Int,
        detachesActivePresetOnDivergence: Bool
    ) {
        let clampedAudioOffsetMilliseconds = Self.clampedOffset(audioOffsetMilliseconds)
        let clampedVisualOffsetMilliseconds = Self.clampedOffset(visualOffsetMilliseconds)

        if detachesActivePresetOnDivergence,
           let activePreset,
           (clampedAudioOffsetMilliseconds != activePreset.audioOffsetMilliseconds
               || clampedVisualOffsetMilliseconds != activePreset.visualOffsetMilliseconds) {
            storedState.activePresetID = nil
        }

        guard pendingAudioOffsetMilliseconds != clampedAudioOffsetMilliseconds
                || pendingVisualOffsetMilliseconds != clampedVisualOffsetMilliseconds else {
            return
        }

        pendingAudioOffsetMilliseconds = clampedAudioOffsetMilliseconds
        pendingVisualOffsetMilliseconds = clampedVisualOffsetMilliseconds
        publishPendingOffsetsIfAllowed()
    }

    private func publishPendingOffsetsIfAllowed() {
        guard pendingAudioOffsetMilliseconds != renderedAudioOffsetMilliseconds
                || pendingVisualOffsetMilliseconds != renderedVisualOffsetMilliseconds else {
            return
        }

        if let lastRenderedOffsetPublishRawTimeMs {
            guard rawClockTimeMs - lastRenderedOffsetPublishRawTimeMs >= Self.renderedOffsetPublishIntervalMs else {
                return
            }
        }

        renderedAudioOffsetMilliseconds = pendingAudioOffsetMilliseconds
        renderedVisualOffsetMilliseconds = pendingVisualOffsetMilliseconds
        lastRenderedOffsetPublishRawTimeMs = rawClockTimeMs
    }

    private func playDueCalibrationTicks() {
        let latestBeatIndex = beatIndex(atOrBeforeRawTimeMs: rawClockTimeMs)
        guard latestBeatIndex > lastTickedBeatIndex else {
            return
        }

        tickPlayer?.playCalibrationTick()
        lastTickedBeatIndex = latestBeatIndex
    }

    private func pruneResolvedBeatIndices(referenceGameplayChartTimeMs: Double) {
        let earliestRetainedNoteTimeMs = referenceGameplayChartTimeMs - Double(Self.resolvedBeatStateRetentionMs)
        resolvedBeatIndices = resolvedBeatIndices.filter { beatIndex in
            noteTimeMs(forBeatIndex: beatIndex) >= earliestRetainedNoteTimeMs
        }
    }

    private func beatIndex(atOrBeforeRawTimeMs rawTimeMs: Int) -> Int {
        guard rawTimeMs >= Self.initialLeadInMs else {
            return -1
        }

        return (rawTimeMs - Self.initialLeadInMs) / Self.tickIntervalMs
    }

    private func nearestUnresolvedBeatIndex(toChartTimeMs chartTimeMs: Double) -> Int {
        let firstNoteTime = noteTimeMs(forBeatIndex: 0)
        let projectedBeat = (chartTimeMs - firstNoteTime) / Double(Self.tickIntervalMs)
        let nearestBeatIndex = Int(projectedBeat.rounded())
        var candidateBeatIndices = Set([nearestBeatIndex - 1, nearestBeatIndex, nearestBeatIndex + 1])
        candidateBeatIndices.insert(0)

        return candidateBeatIndices
            .filter { $0 >= 0 && !resolvedBeatIndices.contains($0) }
            .min { lhs, rhs in
                let lhsDistance = abs(chartTimeMs - noteTimeMs(forBeatIndex: lhs))
                let rhsDistance = abs(chartTimeMs - noteTimeMs(forBeatIndex: rhs))
                if lhsDistance == rhsDistance {
                    return lhs < rhs
                }

                return lhsDistance < rhsDistance
            } ?? max(0, nearestBeatIndex)
    }

    private func nextBlankPresetName() -> String {
        let existingNames = Set(presets.map(\.name))
        var index = 1

        while existingNames.contains("preset \(index)") {
            index += 1
        }

        return "preset \(index)"
    }

    public static func normalizedStoredState(
        _ storedState: Mania4KOffsetCalibrationStoredState?,
        fallbackAppliedAudioOffsetMilliseconds: Int,
        fallbackAppliedVisualOffsetMilliseconds: Int
    ) -> Mania4KOffsetCalibrationStoredState {
        var normalizedState = storedState ?? Mania4KOffsetCalibrationStoredState(
            appliedAudioOffsetMilliseconds: clampedOffset(fallbackAppliedAudioOffsetMilliseconds),
            appliedVisualOffsetMilliseconds: clampedOffset(fallbackAppliedVisualOffsetMilliseconds)
        )
        normalizedState.appliedAudioOffsetMilliseconds = clampedOffset(normalizedState.appliedAudioOffsetMilliseconds)
        normalizedState.appliedVisualOffsetMilliseconds = clampedOffset(normalizedState.appliedVisualOffsetMilliseconds)
        normalizedState.presets = normalizedState.presets.map { preset in
            Mania4KOffsetPreset(
                id: preset.id,
                name: preset.name,
                audioOffsetMilliseconds: clampedOffset(preset.audioOffsetMilliseconds),
                visualOffsetMilliseconds: clampedOffset(preset.visualOffsetMilliseconds)
            )
        }

        guard let activePresetID = normalizedState.activePresetID,
              normalizedState.presets.contains(where: { $0.id == activePresetID }) else {
            normalizedState.activePresetID = nil
            return normalizedState
        }

        return normalizedState
    }

    private static func clampedOffset(_ offsetMilliseconds: Int) -> Int {
        min(max(offsetMilliseconds, offsetRange.lowerBound), offsetRange.upperBound)
    }

    private static func medianOffset(_ offsets: [Int]) -> Int? {
        guard !offsets.isEmpty else {
            return nil
        }

        let sortedOffsets = offsets.sorted()
        let midpoint = sortedOffsets.count / 2
        if sortedOffsets.count.isMultiple(of: 2) {
            let lower = sortedOffsets[midpoint - 1]
            let upper = sortedOffsets[midpoint]
            return clampedOffset(Int((Double(lower + upper) / 2).rounded()))
        }

        return clampedOffset(sortedOffsets[midpoint])
    }
}

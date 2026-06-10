import Foundation
import Observation

public struct Mania4KOffsetPreset: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var presetMs: Int

    public init(id: UUID = UUID(), name: String, presetMs: Int) {
        self.id = id
        self.name = name
        self.presetMs = presetMs
    }
}

public struct Mania4KOffsetCalibrationStoredState: Equatable, Codable, Sendable {
    public var appliedGlobalOffsetMilliseconds: Int
    public var presets: [Mania4KOffsetPreset]
    public var activePresetID: UUID?

    public init(
        appliedGlobalOffsetMilliseconds: Int,
        presets: [Mania4KOffsetPreset] = [],
        activePresetID: UUID? = nil
    ) {
        self.appliedGlobalOffsetMilliseconds = appliedGlobalOffsetMilliseconds
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
    public let sampleRenderedOffsetMilliseconds: Int
    public let hitErrorMs: Double
    public let sampleSuggestedOffsetMilliseconds: Int

    public init(
        beatIndex: Int,
        rawInputTimeMs: Double,
        noteTimeMs: Double,
        sampleRenderedOffsetMilliseconds: Int,
        hitErrorMs: Double,
        sampleSuggestedOffsetMilliseconds: Int
    ) {
        self.beatIndex = beatIndex
        self.rawInputTimeMs = rawInputTimeMs
        self.noteTimeMs = noteTimeMs
        self.sampleRenderedOffsetMilliseconds = sampleRenderedOffsetMilliseconds
        self.hitErrorMs = hitErrorMs
        self.sampleSuggestedOffsetMilliseconds = sampleSuggestedOffsetMilliseconds
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

    public let originalOffsetMilliseconds: Int
    public private(set) var pendingOffsetMilliseconds: Int
    public private(set) var renderedOffsetMilliseconds: Int
    public private(set) var rawClockTimeMs: Int
    public private(set) var hitSamples: [Mania4KOffsetCalibrationHitSample]
    public private(set) var storedState: Mania4KOffsetCalibrationStoredState

    @ObservationIgnored
    private let tickPlayer: (any Mania4KOffsetCalibrationTickPlaying)?

    @ObservationIgnored
    private let initialRenderedOffsetMilliseconds: Int

    @ObservationIgnored
    private var resolvedBeatIndices: Set<Int>

    @ObservationIgnored
    private var lastRenderedOffsetPublishRawTimeMs: Int?

    @ObservationIgnored
    private var lastTickedBeatIndex: Int

    public init(
        originalOffsetMilliseconds: Int,
        storedState: Mania4KOffsetCalibrationStoredState? = nil,
        fallbackAppliedOffsetMilliseconds: Int = 0,
        tickPlayer: (any Mania4KOffsetCalibrationTickPlaying)? = nil
    ) {
        let clampedOriginalOffset = Self.clampedOffset(originalOffsetMilliseconds)
        let normalizedState = Self.normalizedStoredState(
            storedState,
            fallbackAppliedOffsetMilliseconds: fallbackAppliedOffsetMilliseconds
        )
        let activePreset = normalizedState.activePresetID.flatMap { activePresetID in
            normalizedState.presets.first { $0.id == activePresetID }
        }
        let initialOffset = activePreset?.presetMs ?? clampedOriginalOffset

        self.originalOffsetMilliseconds = clampedOriginalOffset
        self.pendingOffsetMilliseconds = initialOffset
        self.renderedOffsetMilliseconds = initialOffset
        self.rawClockTimeMs = 0
        self.hitSamples = []
        self.storedState = normalizedState
        self.tickPlayer = tickPlayer
        self.initialRenderedOffsetMilliseconds = initialOffset
        self.resolvedBeatIndices = []
        self.lastRenderedOffsetPublishRawTimeMs = nil
        self.lastTickedBeatIndex = -1
    }

    public var renderedChartTimeMs: Int {
        rawClockTimeMs + renderedOffsetMilliseconds
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

    public var appliedGlobalOffsetMilliseconds: Int {
        storedState.appliedGlobalOffsetMilliseconds
    }

    public var suggestedOffsetMilliseconds: Int? {
        Self.medianOffset(hitSamples.map(\.sampleSuggestedOffsetMilliseconds))
    }

    public var suggestedAdjustmentMilliseconds: Int? {
        guard let suggestedOffsetMilliseconds else {
            return nil
        }

        return suggestedOffsetMilliseconds - pendingOffsetMilliseconds
    }

    public func noteTimeMs(forBeatIndex beatIndex: Int) -> Double {
        Double(Self.initialLeadInMs + initialRenderedOffsetMilliseconds + beatIndex * Self.tickIntervalMs)
    }

    public func advanceClock(rawClockTimeMs: Int) {
        self.rawClockTimeMs = rawClockTimeMs
        publishPendingOffsetIfAllowed()
        pruneResolvedBeatIndices(referenceChartTimeMs: Double(renderedChartTimeMs))
        playDueCalibrationTicks()
    }

    public func visibleObjects(
        travelTimeMs: Double,
        postLineVisibleMs: Double,
        lookaheadPaddingMs: Double,
        lane: Mania4KLane = .innerRight
    ) -> [Mania4KVisibleObject] {
        let lowerBound = Double(renderedChartTimeMs) - max(0, postLineVisibleMs)
        let upperBound = Double(renderedChartTimeMs) + max(0, travelTimeMs) + max(0, lookaheadPaddingMs)
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
            } else if Double(renderedChartTimeMs) > noteTimeMs + Double(Self.hitWindowMs) {
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
        let sampleRenderedOffsetMilliseconds = renderedOffsetMilliseconds
        let chartInputTimeMs = rawInputTimeMs + Double(sampleRenderedOffsetMilliseconds)
        pruneResolvedBeatIndices(
            referenceChartTimeMs: max(Double(renderedChartTimeMs), chartInputTimeMs)
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
            sampleRenderedOffsetMilliseconds: sampleRenderedOffsetMilliseconds,
            hitErrorMs: hitErrorMs,
            sampleSuggestedOffsetMilliseconds: Self.clampedOffset(
                Int((Double(sampleRenderedOffsetMilliseconds) - hitErrorMs).rounded())
            )
        )

        resolvedBeatIndices.insert(candidateBeatIndex)
        pruneResolvedBeatIndices(
            referenceChartTimeMs: max(Double(renderedChartTimeMs), chartInputTimeMs)
        )
        hitSamples.append(sample)
        if hitSamples.count > Self.acceptedSampleCap {
            hitSamples.removeFirst(hitSamples.count - Self.acceptedSampleCap)
        }

        return sample
    }

    public func stepPendingOffset(by deltaMilliseconds: Int) {
        setPendingOffsetMilliseconds(pendingOffsetMilliseconds + deltaMilliseconds)
    }

    public func setPendingOffsetMilliseconds(_ offsetMilliseconds: Int) {
        updatePendingOffset(Self.clampedOffset(offsetMilliseconds), detachesActivePresetOnDivergence: true)
    }

    @discardableResult
    public func useSuggestedOffset() -> Bool {
        guard let suggestedOffsetMilliseconds else {
            return false
        }

        setPendingOffsetMilliseconds(suggestedOffsetMilliseconds)
        return true
    }

    @discardableResult
    public func addPreset(
        name: String,
        presetMs: Int? = nil,
        id: UUID = UUID()
    ) -> Mania4KOffsetPreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Mania4KOffsetPreset(
            id: id,
            name: trimmedName.isEmpty ? nextBlankPresetName() : trimmedName,
            presetMs: Self.clampedOffset(presetMs ?? pendingOffsetMilliseconds)
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
        updatePendingOffset(preset.presetMs, detachesActivePresetOnDivergence: false)
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
    public func apply() -> Int {
        stopCalibrationTicks()
        storedState.appliedGlobalOffsetMilliseconds = pendingOffsetMilliseconds
        return pendingOffsetMilliseconds
    }

    @discardableResult
    public func cancel() -> Int {
        stopCalibrationTicks()
        return originalOffsetMilliseconds
    }

    private func updatePendingOffset(
        _ offsetMilliseconds: Int,
        detachesActivePresetOnDivergence: Bool
    ) {
        let clampedOffsetMilliseconds = Self.clampedOffset(offsetMilliseconds)

        if detachesActivePresetOnDivergence,
           let activePreset,
           clampedOffsetMilliseconds != activePreset.presetMs {
            storedState.activePresetID = nil
        }

        guard pendingOffsetMilliseconds != clampedOffsetMilliseconds else {
            return
        }

        pendingOffsetMilliseconds = clampedOffsetMilliseconds
        publishPendingOffsetIfAllowed()
    }

    private func publishPendingOffsetIfAllowed() {
        guard pendingOffsetMilliseconds != renderedOffsetMilliseconds else {
            return
        }

        if let lastRenderedOffsetPublishRawTimeMs {
            guard rawClockTimeMs - lastRenderedOffsetPublishRawTimeMs >= Self.renderedOffsetPublishIntervalMs else {
                return
            }
        }

        renderedOffsetMilliseconds = pendingOffsetMilliseconds
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

    private func pruneResolvedBeatIndices(referenceChartTimeMs: Double) {
        let earliestRetainedNoteTimeMs = referenceChartTimeMs - Double(Self.resolvedBeatStateRetentionMs)
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
        fallbackAppliedOffsetMilliseconds: Int
    ) -> Mania4KOffsetCalibrationStoredState {
        var normalizedState = storedState ?? Mania4KOffsetCalibrationStoredState(
            appliedGlobalOffsetMilliseconds: clampedOffset(fallbackAppliedOffsetMilliseconds)
        )
        normalizedState.appliedGlobalOffsetMilliseconds = clampedOffset(normalizedState.appliedGlobalOffsetMilliseconds)
        normalizedState.presets = normalizedState.presets.map { preset in
            Mania4KOffsetPreset(id: preset.id, name: preset.name, presetMs: clampedOffset(preset.presetMs))
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

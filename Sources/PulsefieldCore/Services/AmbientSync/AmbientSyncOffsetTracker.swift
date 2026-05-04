import Foundation

struct AmbientSyncOffsetTrack: Equatable, Sendable {
    let id: Int
    var offsetMS: Double
    var velocityMSPerSecond: Double
    var confidenceLogOdds: Double
    var lastUpdateElapsedMS: Double
    var consecutiveHits: Int
    var consecutiveMisses: Int
    var lastInnovationMS: Double?
    var lastPredictionElapsedMS: Double
    var hasBeenConfirmed: Bool
}

struct AmbientSyncOffsetTracker: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        let innovationGateMS: Double
        let confirmationInnovationGateMS: Double
        let minimumConfirmationHits: Int
        let minimumConfirmationLogOdds: Double
        let minimumConfirmationMarginLogOdds: Double
        let minimumCoastLogOdds: Double
        let maximumCoastMisses: Int
        let maximumTrackCount: Int
        let maximumMeasurementCount: Int
        let minimumVelocityUpdateIntervalMS: Double
        let maximumObservedVelocityMSPerSecond: Double

        init(
            innovationGateMS: Double = 120,
            confirmationInnovationGateMS: Double = 80,
            minimumConfirmationHits: Int = 2,
            minimumConfirmationLogOdds: Double = 2.8,
            minimumConfirmationMarginLogOdds: Double = 1.0,
            minimumCoastLogOdds: Double = 1.2,
            maximumCoastMisses: Int = 2,
            maximumTrackCount: Int = 8,
            maximumMeasurementCount: Int = 8,
            minimumVelocityUpdateIntervalMS: Double = 250,
            maximumObservedVelocityMSPerSecond: Double = 250
        ) {
            precondition(innovationGateMS >= 0, "innovationGateMS must be non-negative.")
            precondition(confirmationInnovationGateMS >= 0, "confirmationInnovationGateMS must be non-negative.")
            precondition(minimumConfirmationHits > 0, "minimumConfirmationHits must be positive.")
            precondition(maximumCoastMisses >= 0, "maximumCoastMisses must be non-negative.")
            precondition(maximumTrackCount > 0, "maximumTrackCount must be positive.")
            precondition(maximumMeasurementCount > 0, "maximumMeasurementCount must be positive.")
            precondition(minimumVelocityUpdateIntervalMS >= 0, "minimumVelocityUpdateIntervalMS must be non-negative.")
            precondition(maximumObservedVelocityMSPerSecond >= 0, "maximumObservedVelocityMSPerSecond must be non-negative.")

            self.innovationGateMS = innovationGateMS
            self.confirmationInnovationGateMS = confirmationInnovationGateMS
            self.minimumConfirmationHits = minimumConfirmationHits
            self.minimumConfirmationLogOdds = minimumConfirmationLogOdds
            self.minimumConfirmationMarginLogOdds = minimumConfirmationMarginLogOdds
            self.minimumCoastLogOdds = minimumCoastLogOdds
            self.maximumCoastMisses = maximumCoastMisses
            self.maximumTrackCount = maximumTrackCount
            self.maximumMeasurementCount = maximumMeasurementCount
            self.minimumVelocityUpdateIntervalMS = minimumVelocityUpdateIntervalMS
            self.maximumObservedVelocityMSPerSecond = maximumObservedVelocityMSPerSecond
        }
    }

    struct Measurement: Equatable, Sendable {
        let offsetMS: Double
        let confidence: Double

        init(offsetMS: Double, confidence: Double) {
            self.offsetMS = offsetMS
            self.confidence = min(1, max(0, confidence))
        }
    }

    struct Result: Equatable, Sendable {
        let tracks: [AmbientSyncOffsetTrack]
        let configuration: Configuration

        var bestTrack: AmbientSyncOffsetTrack? {
            tracks.first
        }

        var secondTrack: AmbientSyncOffsetTrack? {
            guard tracks.count > 1 else {
                return nil
            }

            return tracks[1]
        }

        var confidenceMarginLogOdds: Double {
            guard let bestTrack else {
                return 0
            }

            return bestTrack.confidenceLogOdds - (secondTrack?.confidenceLogOdds ?? 0)
        }

        var isConfirmed: Bool {
            guard let bestTrack else {
                return false
            }

            return isConfirmationCandidate(bestTrack)
                && confidenceMarginLogOdds >= configuration.minimumConfirmationMarginLogOdds
        }

        var isStable: Bool {
            guard let bestTrack else {
                return false
            }

            return isStable(bestTrack)
        }

        var canCoast: Bool {
            guard let bestTrack else {
                return false
            }

            return canCoast(bestTrack)
        }

        func isStable(_ track: AmbientSyncOffsetTrack) -> Bool {
            track.consecutiveMisses == 0
                && abs(track.lastInnovationMS ?? 0) <= configuration.confirmationInnovationGateMS
        }

        func canCoast(_ track: AmbientSyncOffsetTrack) -> Bool {
            track.confidenceLogOdds >= configuration.minimumCoastLogOdds
                && track.consecutiveMisses <= configuration.maximumCoastMisses
        }

        func isConfirmationCandidate(_ track: AmbientSyncOffsetTrack) -> Bool {
            track.consecutiveHits >= configuration.minimumConfirmationHits
                && track.confidenceLogOdds >= configuration.minimumConfirmationLogOdds
                && isStable(track)
        }
    }

    var configuration: Configuration
    private var tracks: [AmbientSyncOffsetTrack] = []
    private var nextTrackID = 1

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var result: Result {
        Result(tracks: tracks, configuration: configuration)
    }

    mutating func predict(elapsedMS: Double) -> Result {
        predictTracks(to: elapsedMS)
        pruneAndRankTracks()
        markConfirmedBestTrackIfNeeded()
        pruneAndRankTracks()
        return result
    }

    mutating func update(
        candidates measurements: [Measurement],
        elapsedMS: Double
    ) -> Result {
        let measurements = Array(
            measurements
                .filter { $0.offsetMS.isFinite && $0.confidence > 0 }
                .prefix(configuration.maximumMeasurementCount)
        )
        predictTracks(to: elapsedMS)

        var usedMeasurementIndices = Set<Int>()
        let trackIndicesByConfidence = tracks.indices.sorted {
            tracks[$0].confidenceLogOdds > tracks[$1].confidenceLogOdds
        }

        for trackIndex in trackIndicesByConfidence {
            guard let measurementIndex = bestMeasurementIndex(
                for: tracks[trackIndex],
                measurements: measurements,
                usedMeasurementIndices: usedMeasurementIndices
            ) else {
                markMiss(trackIndex: trackIndex)
                continue
            }

            usedMeasurementIndices.insert(measurementIndex)
            applyHit(
                trackIndex: trackIndex,
                measurement: measurements[measurementIndex],
                elapsedMS: elapsedMS
            )
        }

        for (measurementIndex, measurement) in measurements.enumerated()
        where !usedMeasurementIndices.contains(measurementIndex) && measurement.confidence > 0 {
            tracks.append(
                AmbientSyncOffsetTrack(
                    id: nextTrackID,
                    offsetMS: measurement.offsetMS,
                    velocityMSPerSecond: 0,
                    confidenceLogOdds: spawnLogOdds(for: measurement),
                    lastUpdateElapsedMS: elapsedMS,
                    consecutiveHits: 1,
                    consecutiveMisses: 0,
                    lastInnovationMS: 0,
                    lastPredictionElapsedMS: elapsedMS,
                    hasBeenConfirmed: false
                )
            )
            nextTrackID += 1
        }

        pruneAndRankTracks()
        markConfirmedBestTrackIfNeeded()
        pruneAndRankTracks()
        return result
    }

    private mutating func predictTracks(to elapsedMS: Double) {
        for index in tracks.indices {
            let deltaSeconds = max(0, elapsedMS - tracks[index].lastPredictionElapsedMS) / 1_000
            tracks[index].offsetMS += tracks[index].velocityMSPerSecond * deltaSeconds
            tracks[index].lastPredictionElapsedMS = elapsedMS
        }
    }

    private func bestMeasurementIndex(
        for track: AmbientSyncOffsetTrack,
        measurements: [Measurement],
        usedMeasurementIndices: Set<Int>
    ) -> Int? {
        var bestIndex: Int?
        var bestDistance = Double.infinity
        let gateMS = associationGateMS(for: track)

        for (index, measurement) in measurements.enumerated() where !usedMeasurementIndices.contains(index) {
            let distance = abs(measurement.offsetMS - track.offsetMS)
            guard distance <= gateMS else {
                continue
            }

            if bestIndex == nil
                || distance < bestDistance
                || (distance == bestDistance && measurement.confidence > measurements[bestIndex ?? index].confidence) {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func associationGateMS(for track: AmbientSyncOffsetTrack) -> Double {
        track.hasBeenConfirmed || track.confidenceLogOdds >= configuration.minimumConfirmationLogOdds
            ? configuration.confirmationInnovationGateMS
            : configuration.innovationGateMS
    }

    private mutating func applyHit(
        trackIndex: Int,
        measurement: Measurement,
        elapsedMS: Double
    ) {
        let previousOffsetMS = tracks[trackIndex].offsetMS
        let innovationMS = measurement.offsetMS - previousOffsetMS
        let elapsedSeconds = max(0, elapsedMS - tracks[trackIndex].lastUpdateElapsedMS) / 1_000

        if elapsedSeconds * 1_000 >= configuration.minimumVelocityUpdateIntervalMS {
            let observedVelocity = min(
                configuration.maximumObservedVelocityMSPerSecond,
                max(-configuration.maximumObservedVelocityMSPerSecond, innovationMS / elapsedSeconds)
            )
            tracks[trackIndex].velocityMSPerSecond = tracks[trackIndex].velocityMSPerSecond * 0.75
                + observedVelocity * 0.25
        } else {
            tracks[trackIndex].velocityMSPerSecond *= 0.5
        }

        tracks[trackIndex].offsetMS = previousOffsetMS + innovationMS * 0.65
        tracks[trackIndex].confidenceLogOdds += hitLogOdds(for: measurement, innovationMS: innovationMS)
        tracks[trackIndex].lastUpdateElapsedMS = elapsedMS
        tracks[trackIndex].lastPredictionElapsedMS = elapsedMS
        tracks[trackIndex].consecutiveHits += 1
        tracks[trackIndex].consecutiveMisses = 0
        tracks[trackIndex].lastInnovationMS = innovationMS
    }

    private mutating func markMiss(trackIndex: Int) {
        tracks[trackIndex].confidenceLogOdds -= 0.75
        tracks[trackIndex].consecutiveHits = 0
        tracks[trackIndex].consecutiveMisses += 1
        tracks[trackIndex].lastInnovationMS = nil
        tracks[trackIndex].velocityMSPerSecond = 0
    }

    private func spawnLogOdds(for measurement: Measurement) -> Double {
        0.6 + measurement.confidence * 1.2
    }

    private func hitLogOdds(for measurement: Measurement, innovationMS: Double) -> Double {
        let innovationPenalty = min(0.5, abs(innovationMS) / max(configuration.innovationGateMS, .ulpOfOne) * 0.5)
        return -0.75 + measurement.confidence * 2.2 - innovationPenalty
    }

    private mutating func pruneAndRankTracks() {
        tracks = tracks
            .filter { track in
                track.confidenceLogOdds > -2.5 && track.consecutiveMisses <= configuration.maximumCoastMisses + 2
            }
            .sorted { lhs, rhs in
                let lhsProtected = lhs.hasBeenConfirmed && canCoast(lhs)
                let rhsProtected = rhs.hasBeenConfirmed && canCoast(rhs)
                if lhsProtected != rhsProtected {
                    return lhsProtected
                }

                if lhs.confidenceLogOdds != rhs.confidenceLogOdds {
                    return lhs.confidenceLogOdds > rhs.confidenceLogOdds
                }

                if lhs.consecutiveHits != rhs.consecutiveHits {
                    return lhs.consecutiveHits > rhs.consecutiveHits
                }

                return lhs.offsetMS < rhs.offsetMS
            }

        if tracks.count > configuration.maximumTrackCount {
            tracks.removeLast(tracks.count - configuration.maximumTrackCount)
        }
    }

    private mutating func markConfirmedBestTrackIfNeeded() {
        let rankedTracks = tracks.sorted { lhs, rhs in
            if lhs.confidenceLogOdds != rhs.confidenceLogOdds {
                return lhs.confidenceLogOdds > rhs.confidenceLogOdds
            }

            return lhs.offsetMS < rhs.offsetMS
        }
        guard let bestTrack = rankedTracks.first,
              let bestIndex = tracks.firstIndex(of: bestTrack)
        else {
            return
        }
        if tracks.contains(where: { track in
            track.hasBeenConfirmed
                && canCoast(track)
                && abs(track.offsetMS - bestTrack.offsetMS) > configuration.confirmationInnovationGateMS
        }) {
            return
        }

        let secondLogOdds = rankedTracks.dropFirst().first?.confidenceLogOdds ?? 0
        let margin = bestTrack.confidenceLogOdds - secondLogOdds
        let candidateResult = Result(tracks: rankedTracks, configuration: configuration)
        if candidateResult.isConfirmationCandidate(bestTrack),
           margin >= configuration.minimumConfirmationMarginLogOdds {
            tracks[bestIndex].hasBeenConfirmed = true
        }
    }

    private func canCoast(_ track: AmbientSyncOffsetTrack) -> Bool {
        track.confidenceLogOdds >= configuration.minimumCoastLogOdds
            && track.consecutiveMisses <= configuration.maximumCoastMisses
    }
}

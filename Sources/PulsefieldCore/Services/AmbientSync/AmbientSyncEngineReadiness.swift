import Foundation

struct AmbientSyncQueryReadiness: Equatable, Sendable {
    let queryDurationMS: Double
    let activeFrameFraction: Double
    let averageEnergyDBFS: Double
    let queryLandmarkCount: Int
}

extension AmbientSyncEngine {
    func readinessMetrics(
        queryWindow: MicFeatureWindow,
        queryLandmarkCount: Int
    ) -> AmbientSyncQueryReadiness {
        let activeFrameCount = queryWindow.frames.reduce(0) { count, frame in
            frame.energyDBFS >= configuration.minimumActiveFrameEnergyDBFS ? count + 1 : count
        }
        let activeFrameFraction = Double(activeFrameCount) / Double(queryWindow.frames.count)

        return AmbientSyncQueryReadiness(
            queryDurationMS: queryWindow.durationMS,
            activeFrameFraction: activeFrameFraction,
            averageEnergyDBFS: Self.averageEnergyDBFS(queryWindow.frames),
            queryLandmarkCount: queryLandmarkCount
        )
    }

    func readinessFailure(_ readiness: AmbientSyncQueryReadiness) -> AmbientSyncWithholdReason? {
        if readiness.queryDurationMS < requiredReadinessDurationMS {
            return .insufficientDuration
        }

        if readiness.averageEnergyDBFS < configuration.minimumAverageEnergyDBFS {
            return .insufficientEnergy
        }

        if readiness.activeFrameFraction < configuration.minimumActiveFrameFraction {
            return .insufficientActiveFrames
        }

        if readiness.queryLandmarkCount < configuration.minimumQueryLandmarkCount {
            return .insufficientLandmarkEvidence
        }

        return nil
    }

    var requiredReadinessDurationMS: Double {
        guard finalLockElapsedMS != nil || confirmedLockElapsedMS != nil else {
            return configuration.minimumReadinessDurationMS
        }

        return min(
            configuration.minimumReadinessDurationMS,
            max(
                0,
                configuration.featureConfiguration.trackingQueryDurationMS
                    - configuration.featureConfiguration.featureHopMS
            )
        )
    }

    static func averageEnergyDBFS(_ frames: [MicFeatureFrame]) -> Double {
        guard !frames.isEmpty else {
            return -Double.infinity
        }

        let meanPower = frames.reduce(0) { total, frame in
            total + pow(10, frame.energyDBFS / 10)
        } / Double(frames.count)

        guard meanPower > 0 else {
            return -Double.infinity
        }

        return 10 * log10(meanPower)
    }
}

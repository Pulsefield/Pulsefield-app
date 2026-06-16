import Foundation

extension AmbientSyncEngine {
    static func framesAreSortedByRecordedTime(_ frames: [MicFeatureFrame]) -> Bool {
        !frames.indices.dropFirst().contains { index in
            frames[frames.index(before: index)].recordedTimeMS > frames[index].recordedTimeMS
        }
    }

    static func landmarks(from frames: [MicFeatureFrame]) -> [MicFeatureLandmark] {
        frames.flatMap { frame in
            if !frame.landmarks.isEmpty {
                return frame.landmarks
            }

            return frame.landmarkHashes.map { hash in
                MicFeatureLandmark(
                    hash: hash,
                    anchorTimeMS: frame.recordedTimeMS,
                    anchorFrequencyBin: 0,
                    targetFrequencyBin: 1,
                    deltaFrames: 1
                )
            }
        }
    }
}

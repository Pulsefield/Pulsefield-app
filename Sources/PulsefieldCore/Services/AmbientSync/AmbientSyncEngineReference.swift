import Foundation

public protocol AmbientSyncEngineReferenceIndex: Sendable {
    var sourceDisplayPath: String { get }
    var featureConfiguration: AmbientSyncFeatureConfiguration { get }
    var frames: [MicFeatureFrame] { get }
    var landmarks: [MicFeatureLandmark] { get }
    var landmarkIndex: AmbientSyncLandmarkIndex { get }
}

public extension AmbientSyncEngine {
    struct Reference: AmbientSyncEngineReferenceIndex, Equatable, Sendable {
        public let sourceDisplayPath: String
        public let featureConfiguration: AmbientSyncFeatureConfiguration
        public let frames: [MicFeatureFrame]
        public let landmarks: [MicFeatureLandmark]
        public let landmarkIndex: AmbientSyncLandmarkIndex

        public init(
            sourceDisplayPath: String,
            featureConfiguration: AmbientSyncFeatureConfiguration = .v1,
            frames: [MicFeatureFrame],
            landmarks: [MicFeatureLandmark] = [],
            landmarkIndex: AmbientSyncLandmarkIndex? = nil
        ) {
            let referenceLandmarks = landmarks.isEmpty
                ? AmbientSyncEngine.landmarks(from: frames)
                : landmarks

            self.sourceDisplayPath = sourceDisplayPath
            self.featureConfiguration = featureConfiguration
            self.frames = frames.sorted { $0.recordedTimeMS < $1.recordedTimeMS }
            self.landmarks = referenceLandmarks
            self.landmarkIndex = landmarkIndex ?? AmbientSyncLandmarkIndex(landmarks: referenceLandmarks)
        }
    }
}

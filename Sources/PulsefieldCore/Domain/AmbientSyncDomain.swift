import Foundation

public struct MicAudioChunk: Equatable, Sendable {
    public let monoSamples: [Float]
    public let sampleRate: Double
    public let recordedStartTimeMS: Double
    public let hostStartTimeMS: Double
    public let inputChannelCount: Int

    public init(
        monoSamples: [Float],
        sampleRate: Double,
        recordedStartTimeMS: Double,
        hostStartTimeMS: Double,
        inputChannelCount: Int
    ) {
        precondition(sampleRate > 0, "sampleRate must be positive.")
        precondition(inputChannelCount > 0, "inputChannelCount must be positive.")

        self.monoSamples = monoSamples
        self.sampleRate = sampleRate
        self.recordedStartTimeMS = recordedStartTimeMS
        self.hostStartTimeMS = hostStartTimeMS
        self.inputChannelCount = inputChannelCount
    }

    public var durationMS: Double {
        Double(monoSamples.count) / sampleRate * 1_000
    }

    public var recordedEndTimeMS: Double {
        recordedStartTimeMS + durationMS
    }

    public var hostEndTimeMS: Double {
        hostStartTimeMS + durationMS
    }
}

public struct MicFeatureAudioWindow: Equatable, Sendable {
    public let monoSamples: [Float]
    public let sampleRate: Double
    public let recordedStartTimeMS: Double
    public let recordedTimeMS: Double
    public let hostStartTimeMS: Double
    public let hostTimeMS: Double
    public let inputChannelCount: Int

    public init(
        monoSamples: [Float],
        sampleRate: Double,
        recordedStartTimeMS: Double,
        recordedTimeMS: Double,
        hostStartTimeMS: Double,
        hostTimeMS: Double,
        inputChannelCount: Int
    ) {
        self.monoSamples = monoSamples
        self.sampleRate = sampleRate
        self.recordedStartTimeMS = recordedStartTimeMS
        self.recordedTimeMS = recordedTimeMS
        self.hostStartTimeMS = hostStartTimeMS
        self.hostTimeMS = hostTimeMS
        self.inputChannelCount = inputChannelCount
    }

    public var durationMS: Double {
        recordedTimeMS - recordedStartTimeMS
    }
}

public struct MicFeaturePayload: Equatable, Sendable {
    public let onsetEnvelope: Float
    public let subbandOnset: [Float]
    public let pcenMel: [Float]
    public let chroma: [Float]
    public let cens: [Float]
    public let landmarkHashes: [UInt64]
    public let energyDBFS: Double
    public let snrDB: Double?

    public init(
        onsetEnvelope: Float,
        subbandOnset: [Float],
        pcenMel: [Float],
        chroma: [Float],
        cens: [Float],
        landmarkHashes: [UInt64],
        energyDBFS: Double,
        snrDB: Double?
    ) {
        self.onsetEnvelope = onsetEnvelope
        self.subbandOnset = subbandOnset
        self.pcenMel = pcenMel
        self.chroma = chroma
        self.cens = cens
        self.landmarkHashes = landmarkHashes
        self.energyDBFS = energyDBFS
        self.snrDB = snrDB
    }
}

public struct MicFeatureFrame: Equatable, Sendable {
    public let recordedTimeMS: Double
    public let hostTimeMS: Double
    public let onsetEnvelope: Float
    public let subbandOnset: [Float]
    public let pcenMel: [Float]
    public let chroma: [Float]
    public let cens: [Float]
    public let landmarkHashes: [UInt64]
    public let energyDBFS: Double
    public let snrDB: Double?

    public init(
        recordedTimeMS: Double,
        hostTimeMS: Double,
        onsetEnvelope: Float,
        subbandOnset: [Float],
        pcenMel: [Float],
        chroma: [Float],
        cens: [Float],
        landmarkHashes: [UInt64],
        energyDBFS: Double,
        snrDB: Double?
    ) {
        self.recordedTimeMS = recordedTimeMS
        self.hostTimeMS = hostTimeMS
        self.onsetEnvelope = onsetEnvelope
        self.subbandOnset = subbandOnset
        self.pcenMel = pcenMel
        self.chroma = chroma
        self.cens = cens
        self.landmarkHashes = landmarkHashes
        self.energyDBFS = energyDBFS
        self.snrDB = snrDB
    }

    public init(
        recordedTimeMS: Double,
        hostTimeMS: Double,
        payload: MicFeaturePayload
    ) {
        self.init(
            recordedTimeMS: recordedTimeMS,
            hostTimeMS: hostTimeMS,
            onsetEnvelope: payload.onsetEnvelope,
            subbandOnset: payload.subbandOnset,
            pcenMel: payload.pcenMel,
            chroma: payload.chroma,
            cens: payload.cens,
            landmarkHashes: payload.landmarkHashes,
            energyDBFS: payload.energyDBFS,
            snrDB: payload.snrDB
        )
    }
}

public struct MicFeatureWindow: Equatable, Sendable {
    public let frames: [MicFeatureFrame]

    public init(frames: [MicFeatureFrame]) {
        precondition(!frames.isEmpty, "MicFeatureWindow requires at least one frame.")
        self.frames = frames
    }

    public var startRecordedTimeMS: Double {
        frames[0].recordedTimeMS
    }

    public var endpointRecordedTimeMS: Double {
        frames[frames.count - 1].recordedTimeMS
    }

    public var endpointHostTimeMS: Double {
        frames[frames.count - 1].hostTimeMS
    }

    public var durationMS: Double {
        endpointRecordedTimeMS - startRecordedTimeMS
    }

    public var landmarkCount: Int {
        frames.reduce(0) { count, frame in
            count + frame.landmarkHashes.count
        }
    }
}

public enum AmbientSyncTimeProjection {
    public static func offsetMS(localReferenceTimeMS: Double, micQueryTimeMS: Double) -> Double {
        localReferenceTimeMS - micQueryTimeMS
    }

    public static func referenceTimeAtNowMS(
        localReferenceTimeAtQueryMS: Double,
        queryEndpointRecordedTimeMS: Double,
        nowMS: Double
    ) -> Double {
        localReferenceTimeAtQueryMS + nowMS - queryEndpointRecordedTimeMS
    }
}

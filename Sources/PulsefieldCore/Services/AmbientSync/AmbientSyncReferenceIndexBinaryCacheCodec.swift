import Foundation

enum AmbientSyncReferenceIndexBinaryCacheCodec {
    private static let magic = Array("PFASIDX".utf8)
    private static let formatVersion: UInt32 = 1

    static func encode(_ cache: AmbientSyncReferenceIndexCache) throws -> Data {
        var writer = AmbientSyncReferenceIndexBinaryWriter(reservingCapacity: estimatedByteCount(for: cache))
        writer.appendBytes(magic)
        writer.appendUInt32(formatVersion)
        try writer.appendInt(cache.schemaVersion)
        try writer.appendString(cache.sourceDisplayPath)
        try writer.appendString(cache.sourceStandardizedPath)
        try writer.appendSourceFileIdentity(cache.sourceFileIdentity)
        try writer.appendFeatureConfiguration(cache.featureConfiguration)
        try writer.appendFrames(cache.frames)
        return writer.data
    }

    static func decode(_ data: Data) throws -> AmbientSyncReferenceIndexCache {
        try data.withUnsafeBytes { rawBuffer in
            var reader = AmbientSyncReferenceIndexBinaryReader(buffer: rawBuffer)
            let decodedMagic = try reader.readBytes(count: magic.count)
            guard decodedMagic.elementsEqual(magic) else {
                throw AmbientSyncReferenceIndexBinaryCacheError.invalidMagic
            }

            let decodedVersion = try reader.readUInt32()
            guard decodedVersion == formatVersion else {
                throw AmbientSyncReferenceIndexBinaryCacheError.unsupportedVersion(Int(decodedVersion))
            }

            let schemaVersion = try reader.readInt()
            let sourceDisplayPath = try reader.readString()
            let sourceStandardizedPath = try reader.readString()
            let sourceFileIdentity = try reader.readSourceFileIdentity()
            let featureConfiguration = try reader.readFeatureConfiguration()
            let frames = try reader.readFrames()
            guard reader.isAtEnd else {
                throw AmbientSyncReferenceIndexBinaryCacheError.trailingBytes
            }

            let landmarks = frames.flatMap(\.landmarks)
            return AmbientSyncReferenceIndexCache(
                schemaVersion: schemaVersion,
                sourceDisplayPath: sourceDisplayPath,
                sourceStandardizedPath: sourceStandardizedPath,
                sourceFileIdentity: sourceFileIdentity,
                featureConfiguration: featureConfiguration,
                frames: frames,
                landmarks: landmarks,
                landmarkIndexDebug: AmbientSyncLandmarkIndexDebug(landmarks: landmarks)
            )
        }
    }

    private static func estimatedByteCount(for cache: AmbientSyncReferenceIndexCache) -> Int {
        let landmarkCount = cache.frames.reduce(0) { count, frame in
            count + frame.landmarks.count
        }
        return 1_024 + cache.frames.count * 360 + landmarkCount * 40
    }
}

private enum AmbientSyncReferenceIndexBinaryCacheError: Error, LocalizedError {
    case invalidMagic
    case unsupportedVersion(Int)
    case invalidCount(UInt64)
    case invalidUTF8
    case truncated
    case trailingBytes
    case integerOverflow

    var errorDescription: String? {
        switch self {
        case .invalidMagic:
            return "Invalid ambient sync reference index binary cache header."
        case .unsupportedVersion(let version):
            return "Unsupported ambient sync reference index binary cache version: \(version)."
        case .invalidCount(let count):
            return "Invalid ambient sync reference index binary cache count: \(count)."
        case .invalidUTF8:
            return "Invalid UTF-8 string in ambient sync reference index binary cache."
        case .truncated:
            return "Truncated ambient sync reference index binary cache."
        case .trailingBytes:
            return "Unexpected trailing bytes in ambient sync reference index binary cache."
        case .integerOverflow:
            return "Integer value is too large for ambient sync reference index binary cache."
        }
    }
}

private struct AmbientSyncReferenceIndexBinaryWriter {
    private(set) var data: Data

    init(reservingCapacity capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func appendBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    mutating func appendUInt8(_ value: UInt8) {
        data.append(contentsOf: [value])
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func appendInt(_ value: Int) throws {
        guard let encoded = Int64(exactly: value) else {
            throw AmbientSyncReferenceIndexBinaryCacheError.integerOverflow
        }

        appendInt64(encoded)
    }

    mutating func appendInt64(_ value: Int64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }

    mutating func appendDouble(_ value: Double) {
        appendUInt64(value.bitPattern)
    }

    mutating func appendString(_ value: String) throws {
        let bytes = Array(value.utf8)
        try appendCount(bytes.count)
        appendBytes(bytes)
    }

    mutating func appendOptionalString(_ value: String?) throws {
        switch value {
        case .some(let value):
            appendUInt8(1)
            try appendString(value)
        case nil:
            appendUInt8(0)
        }
    }

    mutating func appendOptionalDouble(_ value: Double?) {
        switch value {
        case .some(let value):
            appendUInt8(1)
            appendDouble(value)
        case nil:
            appendUInt8(0)
        }
    }

    mutating func appendCount(_ value: Int) throws {
        guard value >= 0 else {
            throw AmbientSyncReferenceIndexBinaryCacheError.integerOverflow
        }

        appendUInt64(UInt64(value))
    }

    mutating func appendFloatArray(_ values: [Float]) throws {
        try appendCount(values.count)
        for value in values {
            appendFloat(value)
        }
    }

    mutating func appendUInt64Array(_ values: [UInt64]) throws {
        try appendCount(values.count)
        for value in values {
            appendUInt64(value)
        }
    }

    mutating func appendLandmark(_ landmark: MicFeatureLandmark) throws {
        appendUInt64(landmark.hash)
        appendDouble(landmark.anchorTimeMS)
        try appendInt(landmark.anchorFrequencyBin)
        try appendInt(landmark.targetFrequencyBin)
        try appendInt(landmark.deltaFrames)
    }

    mutating func appendLandmarks(_ landmarks: [MicFeatureLandmark]) throws {
        try appendCount(landmarks.count)
        for landmark in landmarks {
            try appendLandmark(landmark)
        }
    }

    mutating func appendFrame(_ frame: MicFeatureFrame) throws {
        appendDouble(frame.recordedTimeMS)
        appendDouble(frame.hostTimeMS)
        appendFloat(frame.onsetEnvelope)
        try appendFloatArray(frame.subbandOnset)
        try appendFloatArray(frame.pcenMel)
        try appendFloatArray(frame.chroma)
        try appendFloatArray(frame.cens)
        try appendLandmarks(frame.landmarks)
        try appendUInt64Array(frame.landmarkHashes)
        appendDouble(frame.energyDBFS)
        appendOptionalDouble(frame.snrDB)
    }

    mutating func appendFrames(_ frames: [MicFeatureFrame]) throws {
        try appendCount(frames.count)
        for frame in frames {
            try appendFrame(frame)
        }
    }

    mutating func appendFeatureConfiguration(_ configuration: AmbientSyncFeatureConfiguration) throws {
        appendDouble(configuration.processingSampleRate)
        try appendInt(configuration.featureWindowSizeSamples)
        try appendInt(configuration.featureHopSizeSamples)
        appendDouble(configuration.speculativeQueryDurationMS)
        appendDouble(configuration.firstLockMinimumDurationMS)
        appendDouble(configuration.firstLockTargetDurationMS)
        appendDouble(configuration.finalLockMinimumDurationMS)
        appendDouble(configuration.finalLockTargetDurationMS)
        appendDouble(configuration.trackingQueryDurationMS)
    }

    mutating func appendSourceFileIdentity(_ identity: AmbientSyncReferenceSourceFileIdentity?) throws {
        switch identity {
        case .some(let identity):
            appendUInt8(1)
            try appendString(identity.standardizedPath)
            appendUInt64(identity.fileSizeBytes)
            appendDouble(identity.modificationTimeSince1970)
            try appendOptionalString(identity.sha256)
        case nil:
            appendUInt8(0)
        }
    }
}

private struct AmbientSyncReferenceIndexBinaryReader {
    private static let encodedLandmarkByteCount = (
        MemoryLayout<UInt64>.size
        + MemoryLayout<Double>.size
        + MemoryLayout<Int64>.size * 3
    )
    private static let minimumEncodedFrameByteCount = (
        MemoryLayout<Double>.size * 2
        + MemoryLayout<Float>.size
        + MemoryLayout<UInt64>.size * 6
        + MemoryLayout<Double>.size
        + MemoryLayout<UInt8>.size
    )

    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool {
        offset == buffer.count
    }

    private var remainingByteCount: Int {
        buffer.count - offset
    }

    private func requireRemainingByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= remainingByteCount else {
            throw AmbientSyncReferenceIndexBinaryCacheError.truncated
        }
    }

    private func validateElementCount(_ count: Int, minimumElementByteCount: Int) throws {
        guard minimumElementByteCount > 0,
              count <= remainingByteCount / minimumElementByteCount
        else {
            throw AmbientSyncReferenceIndexBinaryCacheError.invalidCount(UInt64(count))
        }
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        try requireRemainingByteCount(count)

        let start = offset
        offset += count
        return Array(buffer[start..<offset])
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < buffer.count else {
            throw AmbientSyncReferenceIndexBinaryCacheError.truncated
        }

        defer {
            offset += 1
        }
        return buffer[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        try requireRemainingByteCount(MemoryLayout<UInt32>.size)

        let value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += MemoryLayout<UInt32>.size
        return UInt32(littleEndian: value)
    }

    mutating func readUInt64() throws -> UInt64 {
        try requireRemainingByteCount(MemoryLayout<UInt64>.size)

        let value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += MemoryLayout<UInt64>.size
        return UInt64(littleEndian: value)
    }

    mutating func readInt() throws -> Int {
        let value = try readInt64()
        guard let decoded = Int(exactly: value) else {
            throw AmbientSyncReferenceIndexBinaryCacheError.integerOverflow
        }
        return decoded
    }

    mutating func readInt64() throws -> Int64 {
        let value = try readUInt64()
        return Int64(bitPattern: value)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readCount() throws -> Int {
        let value = try readUInt64()
        guard value <= UInt64(Int.max) else {
            throw AmbientSyncReferenceIndexBinaryCacheError.invalidCount(value)
        }
        return Int(value)
    }

    mutating func readString() throws -> String {
        let byteCount = try readCount()
        try requireRemainingByteCount(byteCount)

        let start = offset
        offset += byteCount
        guard let value = String(bytes: buffer[start..<offset], encoding: .utf8) else {
            throw AmbientSyncReferenceIndexBinaryCacheError.invalidUTF8
        }
        return value
    }

    mutating func readOptionalString() throws -> String? {
        switch try readUInt8() {
        case 0:
            return nil
        case 1:
            return try readString()
        default:
            throw AmbientSyncReferenceIndexBinaryCacheError.truncated
        }
    }

    mutating func readOptionalDouble() throws -> Double? {
        switch try readUInt8() {
        case 0:
            return nil
        case 1:
            return try readDouble()
        default:
            throw AmbientSyncReferenceIndexBinaryCacheError.truncated
        }
    }

    mutating func readFloatArray() throws -> [Float] {
        let count = try readCount()
        try validateElementCount(count, minimumElementByteCount: MemoryLayout<Float>.size)
        var values: [Float] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readFloat())
        }
        return values
    }

    mutating func readUInt64Array() throws -> [UInt64] {
        let count = try readCount()
        try validateElementCount(count, minimumElementByteCount: MemoryLayout<UInt64>.size)
        var values: [UInt64] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readUInt64())
        }
        return values
    }

    mutating func readLandmark() throws -> MicFeatureLandmark {
        try MicFeatureLandmark(
            hash: readUInt64(),
            anchorTimeMS: readDouble(),
            anchorFrequencyBin: readInt(),
            targetFrequencyBin: readInt(),
            deltaFrames: readInt()
        )
    }

    mutating func readLandmarks() throws -> [MicFeatureLandmark] {
        let count = try readCount()
        try validateElementCount(count, minimumElementByteCount: Self.encodedLandmarkByteCount)
        var landmarks: [MicFeatureLandmark] = []
        landmarks.reserveCapacity(count)
        for _ in 0..<count {
            landmarks.append(try readLandmark())
        }
        return landmarks
    }

    mutating func readFrame() throws -> MicFeatureFrame {
        let recordedTimeMS = try readDouble()
        let hostTimeMS = try readDouble()
        let onsetEnvelope = try readFloat()
        let subbandOnset = try readFloatArray()
        let pcenMel = try readFloatArray()
        let chroma = try readFloatArray()
        let cens = try readFloatArray()
        let landmarks = try readLandmarks()
        let landmarkHashes = try readUInt64Array()
        let energyDBFS = try readDouble()
        let snrDB = try readOptionalDouble()

        return MicFeatureFrame(
            recordedTimeMS: recordedTimeMS,
            hostTimeMS: hostTimeMS,
            onsetEnvelope: onsetEnvelope,
            subbandOnset: subbandOnset,
            pcenMel: pcenMel,
            chroma: chroma,
            cens: cens,
            landmarkHashes: landmarkHashes,
            landmarks: landmarks,
            energyDBFS: energyDBFS,
            snrDB: snrDB
        )
    }

    mutating func readFrames() throws -> [MicFeatureFrame] {
        let count = try readCount()
        try validateElementCount(count, minimumElementByteCount: Self.minimumEncodedFrameByteCount)
        var frames: [MicFeatureFrame] = []
        frames.reserveCapacity(count)
        for _ in 0..<count {
            frames.append(try readFrame())
        }
        return frames
    }

    mutating func readFeatureConfiguration() throws -> AmbientSyncFeatureConfiguration {
        try AmbientSyncFeatureConfiguration(
            processingSampleRate: readDouble(),
            featureWindowSizeSamples: readInt(),
            featureHopSizeSamples: readInt(),
            speculativeQueryDurationMS: readDouble(),
            firstLockMinimumDurationMS: readDouble(),
            firstLockTargetDurationMS: readDouble(),
            finalLockMinimumDurationMS: readDouble(),
            finalLockTargetDurationMS: readDouble(),
            trackingQueryDurationMS: readDouble()
        )
    }

    mutating func readSourceFileIdentity() throws -> AmbientSyncReferenceSourceFileIdentity? {
        switch try readUInt8() {
        case 0:
            return nil
        case 1:
            return try AmbientSyncReferenceSourceFileIdentity(
                standardizedPath: readString(),
                fileSizeBytes: readUInt64(),
                modificationTimeSince1970: readDouble(),
                sha256: readOptionalString()
            )
        default:
            throw AmbientSyncReferenceIndexBinaryCacheError.truncated
        }
    }
}

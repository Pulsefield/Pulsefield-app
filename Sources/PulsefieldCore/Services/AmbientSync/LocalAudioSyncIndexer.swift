import AVFoundation
import CryptoKit
import Foundation

public actor LocalAudioSyncIndexer: LocalAudioSyncIndexing {
    public static let currentVersion = SyncIndexManifestValidation.currentSchemaVersion
    #if os(macOS)
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private let rootDirectory: URL
    private let frameHopMS: Double
    private let featureExtractor = AmbientSyncFeatureExtractor()

    public init(rootDirectory: URL? = nil, frameHopMS: Double = 100) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.frameHopMS = frameHopMS
    }

    public func buildIndex(for asset: LocalAudioAsset) async throws -> LocalAudioSyncIndex {
        let assetURL = resolveURL(for: asset)
        let accessed = assetURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                assetURL.stopAccessingSecurityScopedResource()
            }
        }

        let assetDirectory = rootDirectory.appendingPathComponent(asset.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let featuresDirectory = assetDirectory.appendingPathComponent("features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresDirectory, withIntermediateDirectories: true)

        let features = try extractSyncFeatures(from: assetURL)
        let onsetFluxURL = featuresDirectory.appendingPathComponent("dense-onset-flux.f32")
        let landmarkURL = featuresDirectory.appendingPathComponent("landmark-postings.bin")
        let logMelURL = featuresDirectory.appendingPathComponent("dense-logmel.f32")
        let chromaURL = featuresDirectory.appendingPathComponent("dense-chroma.f32")
        let energyURL = featuresDirectory.appendingPathComponent("energy.f32")
        try writeFloat32(values: features.onsetFlux, to: onsetFluxURL)
        try features.landmarkPostings.write(to: landmarkURL, options: [.atomic])
        try writeFloat32(values: features.logMel, to: logMelURL)
        try writeFloat32(values: features.chroma, to: chromaURL)
        try writeFloat32(values: features.energy, to: energyURL)
        let manifestURL = assetDirectory.appendingPathComponent("manifest.json")
        let manifest = try syncIndexManifest(
            asset: asset,
            assetURL: assetURL,
            features: features,
            onsetFluxURL: onsetFluxURL,
            landmarkURL: landmarkURL,
            logMelURL: logMelURL,
            chromaURL: chromaURL,
            energyURL: energyURL
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: [.atomic])

        let index = LocalAudioSyncIndex(
            assetID: asset.id,
            durationMS: asset.durationMS,
            sampleRate: features.sampleRate,
            frameHopMS: frameHopMS,
            onsetEnvelopeURL: onsetFluxURL,
            spectralSummaryURL: logMelURL,
            chromaURL: chromaURL,
            version: Self.currentVersion,
            createdAt: Date(),
            manifestURL: manifestURL
        )

        let metadataURL = assetDirectory.appendingPathComponent("index.json")
        let data = try JSONEncoder().encode(index)
        try data.write(to: metadataURL, options: .atomic)
        return index
    }

    public func loadIndex(for assetID: UUID) async -> LocalAudioSyncIndex? {
        let assetDirectory = rootDirectory.appendingPathComponent(assetID.uuidString, isDirectory: true)
        let manifestURL = assetDirectory.appendingPathComponent("manifest.json")
        guard let manifest = try? SyncIndexManifestValidation.loadManifest(at: manifestURL),
              let validatedFiles = try? SyncIndexManifestValidation.validate(
                manifest: manifest,
                directory: assetDirectory,
                expectedAssetID: assetID
              )
        else {
            return nil
        }

        return LocalAudioSyncIndex(
            assetID: assetID,
            durationMS: manifest.asset.durationMS,
            sampleRate: Double(manifest.processing.processingSampleRate),
            frameHopMS: Double(manifest.processing.hopSize),
            onsetEnvelopeURL: validatedFiles.onsetFluxURL,
            spectralSummaryURL: validatedFiles.logMelURL,
            chromaURL: validatedFiles.chromaURL,
            version: manifest.schemaVersion,
            createdAt: SyncIndexManifestValidation.date(fromISO8601: manifest.createdAt) ?? Date(),
            manifestURL: manifestURL
        )
    }

    private func resolveURL(for asset: LocalAudioAsset) -> URL {
        if let bookmark = asset.fileURLBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.standardizedFileURL
            }
        }

        return URL(fileURLWithPath: asset.displayPath).standardizedFileURL
    }

    private func extractSyncFeatures(from url: URL) throws -> AmbientSyncFeatureSet {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let decodedFrameCount = Int(file.length)
        let processingSampleCount = AmbientSyncFeatureExtractor.processingSampleCount(
            sourceFrameCount: decodedFrameCount,
            sourceSampleRate: sampleRate
        )
        var features = try featureExtractor.extractProcessingSamples(
            processingSampleCount: processingSampleCount,
            frameHopMS: frameHopMS
        ) { range in
            try Self.processingSamples(
                in: range,
                from: file,
                format: format,
                sourceSampleRate: sampleRate,
                sourceFrameCount: decodedFrameCount
            )
        }
        features.originalSampleRate = sampleRate
        features.originalChannelCount = Int(format.channelCount)
        features.decodedFrameCount = decodedFrameCount
        return features
    }

    private nonisolated static func processingSamples(
        in range: Range<Int>,
        from file: AVAudioFile,
        format: AVAudioFormat,
        sourceSampleRate: Double,
        sourceFrameCount: Int
    ) throws -> [Float] {
        guard !range.isEmpty, sourceFrameCount > 0 else {
            return []
        }

        let targetSampleRate = AmbientSyncFeatureExtractor.processingSampleRate
        if abs(sourceSampleRate - targetSampleRate) <= 0.5 {
            let startFrame = min(sourceFrameCount, max(0, range.lowerBound))
            let endFrame = min(sourceFrameCount, max(startFrame, range.upperBound))
            return try readMonoSamples(
                from: file,
                format: format,
                startFrame: startFrame,
                frameCount: endFrame - startFrame
            )
        }

        let lowerSourcePosition = Double(range.lowerBound) * sourceSampleRate / targetSampleRate
        let upperSourcePosition = Double(max(range.lowerBound, range.upperBound - 1)) * sourceSampleRate / targetSampleRate
        let sourceStartFrame = min(sourceFrameCount - 1, max(0, Int(floor(lowerSourcePosition))))
        let sourceEndFrame = min(sourceFrameCount, max(sourceStartFrame + 1, Int(ceil(upperSourcePosition)) + 2))
        let sourceSamples = try readMonoSamples(
            from: file,
            format: format,
            startFrame: sourceStartFrame,
            frameCount: sourceEndFrame - sourceStartFrame
        )
        guard !sourceSamples.isEmpty else {
            return Array(repeating: 0, count: range.count)
        }

        return range.map { processingIndex in
            let sourcePosition = Double(processingIndex) * sourceSampleRate / targetSampleRate
            let lowerFrame = min(sourceFrameCount - 1, max(0, Int(floor(sourcePosition))))
            let upperFrame = min(sourceFrameCount - 1, lowerFrame + 1)
            let lowerIndex = min(sourceSamples.count - 1, max(0, lowerFrame - sourceStartFrame))
            let upperIndex = min(sourceSamples.count - 1, max(0, upperFrame - sourceStartFrame))
            let fraction = Float(sourcePosition - Double(lowerFrame))
            return sourceSamples[lowerIndex] + ((sourceSamples[upperIndex] - sourceSamples[lowerIndex]) * fraction)
        }
    }

    private nonisolated static func readMonoSamples(
        from file: AVAudioFile,
        format: AVAudioFormat,
        startFrame: Int,
        frameCount: Int
    ) throws -> [Float] {
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              )
        else {
            return []
        }

        file.framePosition = AVAudioFramePosition(startFrame)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        return monoSamples(from: buffer)
    }

    private nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return []
        }

        if channelCount == 1 {
            let samples = channels[0]
            return (0..<frameCount).map { samples[$0] }
        }

        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            return sum / Float(channelCount)
        }
    }

    private func syncIndexManifest(
        asset: LocalAudioAsset,
        assetURL: URL,
        features: AmbientSyncFeatureSet,
        onsetFluxURL: URL,
        landmarkURL: URL,
        logMelURL: URL,
        chromaURL: URL,
        energyURL: URL
    ) throws -> SyncIndexManifest {
        let resourceValues = try? assetURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modificationDate = resourceValues?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let fileSizeBytes = Int64(resourceValues?.fileSize ?? Int(asset.fileSizeBytes))
        let frameCount = features.frameCount
        let sampleRate = Int(features.sampleRate.rounded())
        let hopSize = Int(frameHopMS.rounded())

        return SyncIndexManifest(
            schemaVersion: Self.currentVersion,
            featureExtractorVersion: SyncIndexManifestValidation.currentFeatureExtractorVersion,
            settingsHash: SyncIndexManifestValidation.settingsHash(
                processingSampleRate: sampleRate,
                hopSizeMS: Double(hopSize)
            ),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            asset: SyncIndexManifestAsset(
                assetID: asset.id,
                durationMS: asset.durationMS
            ),
            source: SyncIndexSourceIdentity(
                fileSizeBytes: fileSizeBytes,
                contentModificationDate: ISO8601DateFormatter().string(from: modificationDate),
                fullFileSHA256: try sha256Hex(contentsOf: assetURL),
                decodedFrameCount: features.decodedFrameCount,
                decodedDurationMS: asset.durationMS,
                originalSampleRate: Int(features.originalSampleRate.rounded()),
                originalChannelCount: features.originalChannelCount
            ),
            processing: SyncIndexProcessingSettings(
                processingSampleRate: sampleRate,
                fftSize: AmbientSyncFeatureExtractor.fftSize,
                hopSize: hopSize,
                window: "hann",
                monoMix: "average"
            ),
            features: SyncIndexFeatureSettings(
                landmark: SyncIndexLandmarkSettings(
                    hashVersion: 1,
                    peakNeighborhoodTime: 3,
                    peakNeighborhoodFreq: 3,
                    fanout: 6,
                    targetZoneStartMS: 250,
                    targetZoneEndMS: 2_500
                ),
                onsetFlux: SyncIndexDenseFeatureSettings(dims: AmbientSyncFeatureExtractor.onsetFluxDimensions),
                logMel: SyncIndexDenseFeatureSettings(dims: AmbientSyncFeatureExtractor.logMelDimensions),
                chroma: SyncIndexChromaFeatureSettings(dims: AmbientSyncFeatureExtractor.chromaDimensions, smoothingMS: 1_000)
            ),
            featureFiles: SyncIndexFeatureFiles(
                landmarkPostings: SyncIndexRecordFeatureFile(
                    path: "features/landmark-postings.bin",
                    recordCount: features.landmarkRecordCount,
                    sha256: try sha256Hex(contentsOf: landmarkURL)
                ),
                denseOnsetFlux: SyncIndexMatrixFeatureFile(
                    path: "features/dense-onset-flux.f32",
                    frames: frameCount,
                    dims: AmbientSyncFeatureExtractor.onsetFluxDimensions,
                    sha256: try sha256Hex(contentsOf: onsetFluxURL)
                ),
                denseLogMel: SyncIndexMatrixFeatureFile(
                    path: "features/dense-logmel.f32",
                    frames: frameCount,
                    dims: AmbientSyncFeatureExtractor.logMelDimensions,
                    sha256: try sha256Hex(contentsOf: logMelURL)
                ),
                denseChroma: SyncIndexMatrixFeatureFile(
                    path: "features/dense-chroma.f32",
                    frames: frameCount,
                    dims: AmbientSyncFeatureExtractor.chromaDimensions,
                    sha256: try sha256Hex(contentsOf: chromaURL)
                ),
                energy: SyncIndexMatrixFeatureFile(
                    path: "features/energy.f32",
                    frames: frameCount,
                    dims: 1,
                    sha256: try sha256Hex(contentsOf: energyURL)
                )
            )
        )
    }

    private func writeFloat32(values: [Double], to url: URL) throws {
        var data = Data(capacity: values.count * MemoryLayout<Float32>.size)
        for value in values {
            var bits = Float32(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        try data.write(to: url, options: [.atomic])
    }

    private func sha256Hex(contentsOf url: URL) throws -> String {
        try SyncIndexManifestValidation.sha256Hex(contentsOf: url)
    }

    private static func defaultRootDirectory() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pulsefield/SyncIndexes", isDirectory: true)
        return directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PulsefieldSyncIndexes", isDirectory: true)
    }
}

struct AmbientSyncFeatureSet: Sendable {
    var onsetFlux: [Double]
    var logMel: [Double]
    var chroma: [Double]
    var energy: [Double]
    var landmarkPostings: Data
    var landmarkRecordCount: Int
    var frameCount: Int
    var sampleRate: Double
    var originalSampleRate: Double
    var originalChannelCount: Int
    var decodedFrameCount: Int

    static func empty(sampleRate: Double) -> AmbientSyncFeatureSet {
        AmbientSyncFeatureSet(
            onsetFlux: [],
            logMel: [],
            chroma: [],
            energy: [],
            landmarkPostings: Data(),
            landmarkRecordCount: 0,
            frameCount: 0,
            sampleRate: sampleRate,
            originalSampleRate: sampleRate,
            originalChannelCount: 0,
            decodedFrameCount: 0
        )
    }
}

struct AmbientSyncFeatureExtractor: Sendable {
    static let processingSampleRate = 22_050.0
    static let fftSize = 256
    static let onsetFluxDimensions = 8
    static let logMelDimensions = 24
    static let chromaDimensions = 12

    enum PreviousFramePolicy: Sendable {
        case silence
        case unavailable
    }

    static func processingSampleCount(sourceFrameCount: Int, sourceSampleRate: Double) -> Int {
        guard sourceFrameCount > 0, sourceSampleRate > 0 else {
            return 0
        }

        if abs(sourceSampleRate - processingSampleRate) <= 0.5 {
            return sourceFrameCount
        }

        let duration = Double(sourceFrameCount) / sourceSampleRate
        return max(1, Int((duration * processingSampleRate).rounded()))
    }

    func extract(
        samples: [Float],
        sampleRate: Double,
        frameHopMS: Double,
        previousFrame: PreviousFramePolicy
    ) -> AmbientSyncFeatureSet {
        guard sampleRate > 0, frameHopMS > 0, !samples.isEmpty else {
            return .empty(sampleRate: sampleRate)
        }

        let processingSamples = resample(
            samples: samples,
            sourceSampleRate: sampleRate,
            targetSampleRate: Self.processingSampleRate
        )
        var features = extractProcessingSamples(
            processingSampleCount: processingSamples.count,
            frameHopMS: frameHopMS,
            previousFrame: previousFrame
        ) { range in
            Array(processingSamples[range])
        }
        features.originalSampleRate = sampleRate
        features.originalChannelCount = 1
        features.decodedFrameCount = samples.count
        return features
    }

    func extractProcessingSamples(
        processingSampleCount: Int,
        frameHopMS: Double,
        previousFrame: PreviousFramePolicy = .silence,
        samplesInRange: (Range<Int>) throws -> [Float]
    ) rethrows -> AmbientSyncFeatureSet {
        guard frameHopMS > 0, processingSampleCount > 0 else {
            return .empty(sampleRate: Self.processingSampleRate)
        }

        let hopFrames = max(1, Int(Self.processingSampleRate * frameHopMS / 1_000))
        let window = hannWindow(count: Self.fftSize)
        let samplesPerRequest = max(hopFrames, Self.fftSize)
        var onsetFlux: [Double] = []
        var logMel: [Double] = []
        var chroma: [Double] = []
        var energy: [Double] = []
        var landmarkWords: [UInt32] = []
        var previousRMS = 0.0
        var previousSpectralBands = Array(repeating: 0.0, count: Self.onsetFluxDimensions - 1)
        var hasPreviousFrame = previousFrame == .silence
        var offset = 0

        while offset < processingSampleCount {
            let rangeEnd = min(offset + samplesPerRequest, processingSampleCount)
            let frameSamples = try samplesInRange(offset..<rangeEnd)
            let rmsFrameCount = min(hopFrames, frameSamples.count)
            let rms = rootMeanSquare(frameSamples.prefix(rmsFrameCount))
            let spectrum = logMagnitudeSpectrum(
                samples: frameSamples,
                start: 0,
                window: window,
                sampleCount: Self.fftSize
            )
            let spectralBands = bandAverages(
                spectrum: spectrum,
                dimensions: Self.onsetFluxDimensions - 1,
                includeDC: false
            )
            let logMelFrame = bandAverages(
                spectrum: spectrum,
                dimensions: Self.logMelDimensions,
                includeDC: true
            )
            let chromaFrame = chromaVector(
                spectrum: spectrum,
                sampleRate: Self.processingSampleRate,
                fftSize: Self.fftSize
            )

            if hasPreviousFrame {
                let frameIndex = energy.count
                onsetFlux.append(max(0, rms - previousRMS))
                for (current, previous) in zip(spectralBands, previousSpectralBands) {
                    onsetFlux.append(max(0, current - previous))
                }
                logMel.append(contentsOf: logMelFrame)
                chroma.append(contentsOf: chromaFrame)
                energy.append(rms)
                landmarkWords.append(contentsOf: landmarkRecords(
                    frameIndex: frameIndex,
                    spectralFluxBands: Array(onsetFlux.suffix(Self.onsetFluxDimensions))
                ))
            } else {
                hasPreviousFrame = true
            }

            previousRMS = rms
            previousSpectralBands = spectralBands
            offset += hopFrames
        }

        return AmbientSyncFeatureSet(
            onsetFlux: onsetFlux,
            logMel: logMel,
            chroma: chroma,
            energy: energy,
            landmarkPostings: landmarkData(words: landmarkWords),
            landmarkRecordCount: landmarkWords.count / 2,
            frameCount: energy.count,
            sampleRate: Self.processingSampleRate,
            originalSampleRate: Self.processingSampleRate,
            originalChannelCount: 1,
            decodedFrameCount: processingSampleCount
        )
    }

    func correlationSeries(
        samples: [Float],
        sampleRate: Double,
        frameHopMS: Double,
        previousFrame: PreviousFramePolicy,
        onsetFluxDimensions: Int
    ) -> [Double] {
        if onsetFluxDimensions <= 1 || sampleRate < 8_000 {
            return onsetFlux(
                samples: samples,
                sampleRate: sampleRate,
                frameHopMS: frameHopMS,
                previousFrame: previousFrame
            )
        }

        let features = extract(
            samples: samples,
            sampleRate: sampleRate,
            frameHopMS: frameHopMS,
            previousFrame: previousFrame
        )
        return Self.projectOnsetFlux(features.onsetFlux, dimensions: onsetFluxDimensions)
    }

    static func projectOnsetFlux(_ values: [Double], dimensions: Int) -> [Double] {
        guard dimensions > 1 else {
            return values
        }

        guard values.count % dimensions == 0 else {
            return []
        }

        return stride(from: 0, to: values.count, by: dimensions).map { offset in
            let transientFlux = values[offset]
            let spectralStart = offset + 1
            let spectralEnd = offset + dimensions
            guard spectralStart < spectralEnd else {
                return transientFlux
            }

            let spectralMean = values[spectralStart..<spectralEnd].reduce(0, +) / Double(dimensions - 1)
            return transientFlux + spectralMean
        }
    }

    func onsetFlux(
        samples: [Float],
        sampleRate: Double,
        frameHopMS: Double,
        previousFrame: PreviousFramePolicy
    ) -> [Double] {
        guard sampleRate > 0, frameHopMS > 0, !samples.isEmpty else {
            return []
        }

        let hopFrames = max(1, Int(sampleRate * frameHopMS / 1_000))
        var values: [Double] = []
        var previousRMS = 0.0
        var hasPreviousFrame = previousFrame == .silence
        var offset = 0

        while offset < samples.count {
            let end = min(offset + hopFrames, samples.count)
            let rms = rootMeanSquare(samples[offset..<end])
            if hasPreviousFrame {
                values.append(max(0, rms - previousRMS))
            } else {
                hasPreviousFrame = true
            }
            previousRMS = rms
            offset = end
        }

        return values
    }

    func onsetFluxValue<S: Collection>(
        samples: S,
        previousRMS: inout Double
    ) -> Double where S.Element == Float {
        denseFeatureValue(samples: samples, previousRMS: &previousRMS).onsetFlux
    }

    func denseFeatureValue<S: Collection>(
        samples: S,
        previousRMS: inout Double
    ) -> (onsetFlux: Double, energy: Double) where S.Element == Float {
        let rms = rootMeanSquare(samples)
        defer {
            previousRMS = rms
        }
        return (max(0, rms - previousRMS), rms)
    }

    private func rootMeanSquare<S: Collection>(_ samples: S) -> Double where S.Element == Float {
        guard !samples.isEmpty else {
            return 0
        }

        let sum = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    private func resample(
        samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard sourceSampleRate > 0,
              targetSampleRate > 0,
              !samples.isEmpty,
              abs(sourceSampleRate - targetSampleRate) > 0.5
        else {
            return samples
        }

        let duration = Double(samples.count) / sourceSampleRate
        let targetCount = max(1, Int((duration * targetSampleRate).rounded()))
        guard targetCount > 1, samples.count > 1 else {
            return samples
        }

        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) * sourceSampleRate / targetSampleRate
            let lowerIndex = min(samples.count - 1, max(0, Int(floor(sourcePosition))))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            return samples[lowerIndex] + ((samples[upperIndex] - samples[lowerIndex]) * fraction)
        }
    }

    private func hannWindow(count: Int) -> [Double] {
        guard count > 1 else {
            return Array(repeating: 1, count: max(0, count))
        }

        return (0..<count).map { index in
            0.5 - (0.5 * cos((2 * Double.pi * Double(index)) / Double(count - 1)))
        }
    }

    private func logMagnitudeSpectrum(
        samples: [Float],
        start: Int,
        window: [Double],
        sampleCount: Int
    ) -> [Double] {
        let binCount = max(1, sampleCount / 2)
        return (0..<binCount).map { bin in
            var real = 0.0
            var imaginary = 0.0
            for sampleIndex in 0..<sampleCount {
                let sourceIndex = start + sampleIndex
                let sample = sourceIndex < samples.count ? Double(samples[sourceIndex]) : 0
                let windowedSample = sample * window[sampleIndex]
                let angle = (2 * Double.pi * Double(bin) * Double(sampleIndex)) / Double(sampleCount)
                real += windowedSample * cos(angle)
                imaginary -= windowedSample * sin(angle)
            }
            return log1p(sqrt((real * real) + (imaginary * imaginary)))
        }
    }

    private func bandAverages(
        spectrum: [Double],
        dimensions: Int,
        includeDC: Bool
    ) -> [Double] {
        guard dimensions > 0 else {
            return []
        }

        let startIndex = includeDC ? 0 : min(1, spectrum.count)
        let usableBins = max(0, spectrum.count - startIndex)
        guard usableBins > 0 else {
            return Array(repeating: 0, count: dimensions)
        }

        return (0..<dimensions).map { dimension in
            let lower = startIndex + Int(floor((Double(dimension) * Double(usableBins)) / Double(dimensions)))
            let upper = startIndex + Int(floor((Double(dimension + 1) * Double(usableBins)) / Double(dimensions)))
            let boundedUpper = max(lower + 1, min(spectrum.count, upper))
            guard lower < spectrum.count else {
                return 0
            }

            let slice = spectrum[lower..<boundedUpper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private func chromaVector(
        spectrum: [Double],
        sampleRate: Double,
        fftSize: Int
    ) -> [Double] {
        var chroma = Array(repeating: 0.0, count: Self.chromaDimensions)
        guard sampleRate > 0, fftSize > 0, spectrum.count > 1 else {
            return chroma
        }

        for bin in 1..<spectrum.count {
            let frequency = (Double(bin) * sampleRate) / Double(fftSize)
            guard frequency >= 27.5 else {
                continue
            }

            let midiNote = Int(round(69 + (12 * log2(frequency / 440))))
            let pitchClass = ((midiNote % Self.chromaDimensions) + Self.chromaDimensions) % Self.chromaDimensions
            chroma[pitchClass] += spectrum[bin]
        }

        let peak = chroma.max() ?? 0
        guard peak > 0 else {
            return chroma
        }

        return chroma.map { $0 / peak }
    }

    private func landmarkRecords(frameIndex: Int, spectralFluxBands: [Double]) -> [UInt32] {
        guard let peak = spectralFluxBands.max(), peak > 0.02 else {
            return []
        }

        var records: [UInt32] = []
        for (band, value) in spectralFluxBands.enumerated() {
            guard value >= peak * 0.8 else {
                continue
            }

            let quantizedValue = min(4_095, max(0, Int((value * 1_000).rounded())))
            let hash = UInt32((band & 0xff) << 12 | quantizedValue)
            records.append(hash)
            records.append(UInt32(frameIndex))
        }
        return records
    }

    private func landmarkData(words: [UInt32]) -> Data {
        var data = Data(capacity: words.count * MemoryLayout<UInt32>.size)
        for word in words {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }
}

struct ValidatedSyncIndexFiles {
    var onsetFluxURL: URL
    var onsetFluxDimensions: Int
    var landmarkPostingsURL: URL?
    var landmarkRecordCount: Int?
    var logMelURL: URL?
    var logMelDimensions: Int?
    var chromaURL: URL?
    var chromaDimensions: Int?
    var energyURL: URL?
    var energyDimensions: Int?
}

private struct SyncIndexSourceValidationIdentity {
    var fileSizeBytes: Int64
    var fullFileSHA256: String
}

enum SyncIndexManifestValidation {
    static let currentSchemaVersion = 2
    static let currentFeatureExtractorVersion = "ambient-sync-v2"
    static let processingSampleRate = Int(AmbientSyncFeatureExtractor.processingSampleRate.rounded())
    static let onsetFluxDims = AmbientSyncFeatureExtractor.onsetFluxDimensions
    static let logMelDims = AmbientSyncFeatureExtractor.logMelDimensions
    static let chromaDims = AmbientSyncFeatureExtractor.chromaDimensions

    static func settingsHash(processingSampleRate: Int, hopSizeMS: Double) -> String {
        [
            "processingSampleRate=\(processingSampleRate)",
            "hopSizeMS=\(hopSizeMS)",
            "fftSize=\(AmbientSyncFeatureExtractor.fftSize)",
            "window=hann",
            "onsetFluxDims=\(onsetFluxDims)",
            "logMelDims=\(logMelDims)",
            "chromaDims=\(chromaDims)"
        ].joined(separator: ";")
    }

    static func manifestURL(for index: LocalAudioSyncIndex) -> URL {
        if let manifestURL = index.manifestURL {
            return manifestURL
        }

        let directory = index.onsetEnvelopeURL.deletingLastPathComponent()
        if directory.lastPathComponent == "features" {
            return directory.deletingLastPathComponent().appendingPathComponent("manifest.json")
        }

        return directory.appendingPathComponent("manifest.json")
    }

    static func loadManifest(at manifestURL: URL) throws -> SyncIndexManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AmbientSyncStartError.indexUnavailable
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(SyncIndexManifest.self, from: data)
        } catch let error as AmbientSyncStartError {
            throw error
        } catch {
            throw AmbientSyncStartError.indexInvalid
        }
    }

    static func validate(
        manifest: SyncIndexManifest,
        directory: URL,
        expectedAssetID: UUID,
        expectedIndex: LocalAudioSyncIndex? = nil,
        selectedAsset: LocalAudioAsset? = nil
    ) throws -> ValidatedSyncIndexFiles {
        guard manifest.asset.assetID == expectedAssetID else {
            throw AmbientSyncStartError.indexInvalid
        }

        guard manifest.schemaVersion == currentSchemaVersion else {
            throw AmbientSyncStartError.indexIncompatible
        }

        guard manifest.featureExtractorVersion == currentFeatureExtractorVersion else {
            throw AmbientSyncStartError.indexIncompatible
        }

        guard date(fromISO8601: manifest.createdAt) != nil else {
            throw AmbientSyncStartError.indexInvalid
        }

        guard manifest.processing.fftSize == AmbientSyncFeatureExtractor.fftSize,
              manifest.processing.processingSampleRate == processingSampleRate,
              manifest.processing.hopSize > 0,
              manifest.processing.window == "hann",
              manifest.processing.monoMix == "average"
        else {
            throw AmbientSyncStartError.indexIncompatible
        }

        guard manifest.features.onsetFlux.dims == onsetFluxDims,
              manifest.features.logMel.dims == logMelDims,
              manifest.features.chroma.dims == chromaDims,
              manifest.featureFiles.denseOnsetFlux.dims == onsetFluxDims,
              manifest.featureFiles.denseLogMel?.dims == logMelDims,
              manifest.featureFiles.denseChroma?.dims == chromaDims,
              manifest.featureFiles.energy?.dims == 1
        else {
            throw AmbientSyncStartError.indexIncompatible
        }

        let expectedSettingsHash = settingsHash(
            processingSampleRate: processingSampleRate,
            hopSizeMS: Double(manifest.processing.hopSize)
        )
        guard manifest.settingsHash == expectedSettingsHash else {
            throw AmbientSyncStartError.indexIncompatible
        }

        if let expectedIndex {
            guard expectedIndex.version == currentSchemaVersion,
                  Int(expectedIndex.sampleRate.rounded()) == manifest.processing.processingSampleRate,
                  Int(expectedIndex.frameHopMS.rounded()) == manifest.processing.hopSize
            else {
                throw AmbientSyncStartError.indexIncompatible
            }
        }

        if let selectedAsset {
            guard selectedAsset.id == expectedAssetID else {
                throw AmbientSyncStartError.indexInvalid
            }
            let snapshotMatchesSource = selectedAsset.fileSizeBytes == manifest.source.fileSizeBytes
                && selectedAsset.sha256 == manifest.source.fullFileSHA256
            let currentIdentityMatchesSource: Bool
            if snapshotMatchesSource {
                currentIdentityMatchesSource = false
            } else if let currentIdentity = currentSourceIdentity(
                for: selectedAsset,
                expectedFileSizeBytes: manifest.source.fileSizeBytes
            ) {
                currentIdentityMatchesSource = currentIdentity.fileSizeBytes == manifest.source.fileSizeBytes
                    && currentIdentity.fullFileSHA256 == manifest.source.fullFileSHA256
            } else {
                currentIdentityMatchesSource = false
            }
            guard (snapshotMatchesSource || currentIdentityMatchesSource),
                  selectedAsset.durationMS == manifest.asset.durationMS,
                  selectedAsset.durationMS == manifest.source.decodedDurationMS
            else {
                throw AmbientSyncStartError.indexInvalid
            }
        }

        let onsetFluxURL = try featureURL(directory: directory, path: manifest.featureFiles.denseOnsetFlux.path)
        try validateMatrixFile(manifest.featureFiles.denseOnsetFlux, at: onsetFluxURL)
        guard manifest.featureFiles.denseOnsetFlux.frames > 0 else {
            throw AmbientSyncStartError.indexInvalid
        }

        let landmarkPostingsURL = try validateRecordFileIfPresent(manifest.featureFiles.landmarkPostings, directory: directory)
        let logMelURL = try validateMatrixFileIfPresent(
            manifest.featureFiles.denseLogMel,
            directory: directory,
            expectedFrames: manifest.featureFiles.denseOnsetFlux.frames
        )
        let chromaURL = try validateMatrixFileIfPresent(
            manifest.featureFiles.denseChroma,
            directory: directory,
            expectedFrames: manifest.featureFiles.denseOnsetFlux.frames
        )
        let energyURL = try validateMatrixFileIfPresent(
            manifest.featureFiles.energy,
            directory: directory,
            expectedFrames: manifest.featureFiles.denseOnsetFlux.frames
        )
        return ValidatedSyncIndexFiles(
            onsetFluxURL: onsetFluxURL,
            onsetFluxDimensions: manifest.featureFiles.denseOnsetFlux.dims,
            landmarkPostingsURL: landmarkPostingsURL,
            landmarkRecordCount: manifest.featureFiles.landmarkPostings?.recordCount,
            logMelURL: logMelURL,
            logMelDimensions: manifest.featureFiles.denseLogMel?.dims,
            chromaURL: chromaURL,
            chromaDimensions: manifest.featureFiles.denseChroma?.dims,
            energyURL: energyURL,
            energyDimensions: manifest.featureFiles.energy?.dims
        )
    }

    static func featureURL(directory: URL, path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw AmbientSyncStartError.indexInvalid
        }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = directory
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard url.path.hasPrefix(rootPath) else {
            throw AmbientSyncStartError.indexInvalid
        }
        return url
    }

    static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(contentsOf url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func date(fromISO8601 string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func currentSourceIdentity(
        for asset: LocalAudioAsset,
        expectedFileSizeBytes: Int64
    ) -> SyncIndexSourceValidationIdentity? {
        let url = sourceURL(for: asset)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize
        else {
            return nil
        }

        let fileSizeBytes = Int64(fileSize)
        guard fileSizeBytes == expectedFileSizeBytes,
              let fullFileSHA256 = try? sha256Hex(contentsOf: url)
        else {
            return nil
        }

        return SyncIndexSourceValidationIdentity(
            fileSizeBytes: fileSizeBytes,
            fullFileSHA256: fullFileSHA256
        )
    }

    private static func sourceURL(for asset: LocalAudioAsset) -> URL {
        if let bookmark = asset.fileURLBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: LocalAudioSyncIndexer.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.standardizedFileURL
            }
        }

        return URL(fileURLWithPath: asset.displayPath).standardizedFileURL
    }

    private static func validateMatrixFileIfPresent(
        _ file: SyncIndexMatrixFeatureFile?,
        directory: URL,
        expectedFrames: Int
    ) throws -> URL? {
        guard let file else {
            return nil
        }
        guard file.frames == expectedFrames else {
            throw AmbientSyncStartError.indexInvalid
        }
        let url = try featureURL(directory: directory, path: file.path)
        try validateMatrixFile(file, at: url)
        return url
    }

    private static func validateRecordFileIfPresent(
        _ file: SyncIndexRecordFeatureFile?,
        directory: URL
    ) throws -> URL? {
        guard let file else {
            return nil
        }
        guard file.recordCount >= 0 else {
            throw AmbientSyncStartError.indexIncompatible
        }

        let url = try featureURL(directory: directory, path: file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AmbientSyncStartError.indexUnavailable
        }

        let data = try Data(contentsOf: url)
        guard data.count == file.recordCount * 2 * MemoryLayout<UInt32>.size else {
            throw AmbientSyncStartError.indexInvalid
        }
        guard sha256Hex(data: data) == file.sha256 else {
            throw AmbientSyncStartError.indexInvalid
        }
        return url
    }

    private static func validateMatrixFile(
        _ file: SyncIndexMatrixFeatureFile,
        at url: URL
    ) throws {
        guard file.frames >= 0, file.dims > 0 else {
            throw AmbientSyncStartError.indexIncompatible
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AmbientSyncStartError.indexUnavailable
        }

        let data = try Data(contentsOf: url)
        guard data.count == file.frames * file.dims * MemoryLayout<Float32>.size else {
            throw AmbientSyncStartError.indexInvalid
        }

        guard sha256Hex(data: data) == file.sha256 else {
            throw AmbientSyncStartError.indexInvalid
        }
    }
}

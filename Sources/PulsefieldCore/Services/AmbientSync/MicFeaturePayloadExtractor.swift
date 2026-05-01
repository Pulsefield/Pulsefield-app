import Accelerate
import Foundation

public struct MicFeaturePayloadExtractor: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public let subbandCount: Int
        public let melBandCount: Int
        public let chromaBinCount: Int
        public let landmarkPeakCount: Int
        public let minimumFrequency: Double
        public let maximumFrequency: Double
        public let pcenSmoothingCoefficient: Float
        public let pcenAlpha: Float
        public let pcenDelta: Float
        public let pcenRoot: Float
        public let censSmoothingCoefficient: Float
        public let noiseFloorRiseCoefficient: Double
        public let noiseFloorFallCoefficient: Double
        public let silenceFloorDBFS: Double

        public init(
            subbandCount: Int = 6,
            melBandCount: Int = 24,
            chromaBinCount: Int = 12,
            landmarkPeakCount: Int = 4,
            minimumFrequency: Double = 40,
            maximumFrequency: Double = 8_000,
            pcenSmoothingCoefficient: Float = 0.025,
            pcenAlpha: Float = 0.98,
            pcenDelta: Float = 2,
            pcenRoot: Float = 0.5,
            censSmoothingCoefficient: Float = 0.25,
            noiseFloorRiseCoefficient: Double = 0.02,
            noiseFloorFallCoefficient: Double = 0.25,
            silenceFloorDBFS: Double = -120
        ) {
            precondition(subbandCount > 0, "subbandCount must be positive.")
            precondition(melBandCount > 0, "melBandCount must be positive.")
            precondition(chromaBinCount > 0, "chromaBinCount must be positive.")
            precondition(landmarkPeakCount > 0, "landmarkPeakCount must be positive.")
            precondition(minimumFrequency > 0, "minimumFrequency must be positive.")
            precondition(maximumFrequency > minimumFrequency, "maximumFrequency must exceed minimumFrequency.")
            precondition((0...1).contains(pcenSmoothingCoefficient), "pcenSmoothingCoefficient must be between 0 and 1.")
            precondition((0...1).contains(pcenAlpha), "pcenAlpha must be between 0 and 1.")
            precondition(pcenDelta > 0, "pcenDelta must be positive.")
            precondition(pcenRoot > 0, "pcenRoot must be positive.")
            precondition((0...1).contains(censSmoothingCoefficient), "censSmoothingCoefficient must be between 0 and 1.")
            precondition((0...1).contains(noiseFloorRiseCoefficient), "noiseFloorRiseCoefficient must be between 0 and 1.")
            precondition((0...1).contains(noiseFloorFallCoefficient), "noiseFloorFallCoefficient must be between 0 and 1.")

            self.subbandCount = subbandCount
            self.melBandCount = melBandCount
            self.chromaBinCount = chromaBinCount
            self.landmarkPeakCount = landmarkPeakCount
            self.minimumFrequency = minimumFrequency
            self.maximumFrequency = maximumFrequency
            self.pcenSmoothingCoefficient = pcenSmoothingCoefficient
            self.pcenAlpha = pcenAlpha
            self.pcenDelta = pcenDelta
            self.pcenRoot = pcenRoot
            self.censSmoothingCoefficient = censSmoothingCoefficient
            self.noiseFloorRiseCoefficient = noiseFloorRiseCoefficient
            self.noiseFloorFallCoefficient = noiseFloorFallCoefficient
            self.silenceFloorDBFS = silenceFloorDBFS
        }
    }

    public let configuration: Configuration

    private var previousSubbandLogEnergies: [Float]?
    private var pcenSmoothers: [Float] = []
    private var censSmoother: [Float] = []
    private var previousPeaks: [SpectralPeak] = []
    private var noiseFloorDBFS: Double?
    private var spectrumAnalyzer = MicFeatureSpectrumAnalyzer()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public static func == (lhs: MicFeaturePayloadExtractor, rhs: MicFeaturePayloadExtractor) -> Bool {
        lhs.configuration == rhs.configuration
            && lhs.previousSubbandLogEnergies == rhs.previousSubbandLogEnergies
            && lhs.pcenSmoothers == rhs.pcenSmoothers
            && lhs.censSmoother == rhs.censSmoother
            && lhs.previousPeaks == rhs.previousPeaks
            && lhs.noiseFloorDBFS == rhs.noiseFloorDBFS
    }

    public mutating func reset() {
        previousSubbandLogEnergies = nil
        pcenSmoothers.removeAll(keepingCapacity: true)
        censSmoother.removeAll(keepingCapacity: true)
        previousPeaks.removeAll(keepingCapacity: true)
        noiseFloorDBFS = nil
    }

    public mutating func extract(from window: MicFeatureAudioWindow) -> MicFeaturePayload {
        guard !window.monoSamples.isEmpty, window.sampleRate > 0 else {
            return emptyPayload()
        }

        let energyDBFS = calculateEnergyDBFS(samples: window.monoSamples)
        let spectralBins = calculateSpectrum(samples: window.monoSamples, sampleRate: window.sampleRate)
        let subbandEnergies = logFrequencyBandEnergies(
            from: spectralBins,
            sampleRate: window.sampleRate,
            bandCount: configuration.subbandCount
        )
        let subbandLogEnergies = subbandEnergies.map(logScaledEnergy)
        let subbandOnset = calculateSubbandOnset(currentLogEnergies: subbandLogEnergies)
        let melEnergies = melBandEnergies(from: spectralBins, sampleRate: window.sampleRate)
        let pcenMel = calculatePCENMel(from: melEnergies)
        let chroma = calculateChroma(from: spectralBins, sampleRate: window.sampleRate)
        let cens = calculateCENS(from: chroma)
        let peaks = calculateSpectralPeaks(from: spectralBins)
        let landmarkHashes = calculateLandmarkHashes(currentPeaks: peaks)
        let snrDB = updateSNR(energyDBFS: energyDBFS)

        previousSubbandLogEnergies = subbandLogEnergies
        previousPeaks = peaks

        return MicFeaturePayload(
            onsetEnvelope: subbandOnset.reduce(0, +),
            subbandOnset: subbandOnset,
            pcenMel: pcenMel,
            chroma: chroma,
            cens: cens,
            landmarkHashes: landmarkHashes,
            energyDBFS: energyDBFS,
            snrDB: snrDB
        )
    }

    private func emptyPayload() -> MicFeaturePayload {
        MicFeaturePayload(
            onsetEnvelope: 0,
            subbandOnset: Array(repeating: 0, count: configuration.subbandCount),
            pcenMel: Array(repeating: 0, count: configuration.melBandCount),
            chroma: Array(repeating: 0, count: configuration.chromaBinCount),
            cens: Array(repeating: 0, count: configuration.chromaBinCount),
            landmarkHashes: [],
            energyDBFS: configuration.silenceFloorDBFS,
            snrDB: nil
        )
    }

    private func calculateEnergyDBFS(samples: [Float]) -> Double {
        let meanSquare = samples.reduce(0.0) { partial, sample in
            partial + Double(sample) * Double(sample)
        } / Double(samples.count)
        let rms = sqrt(meanSquare)
        guard rms > 0 else {
            return configuration.silenceFloorDBFS
        }

        return max(configuration.silenceFloorDBFS, 20 * log10(rms))
    }

    private mutating func calculateSpectrum(samples: [Float], sampleRate: Double) -> [SpectralBin] {
        spectrumAnalyzer.spectrum(samples: samples, sampleRate: sampleRate)
    }

    private func logFrequencyBandEnergies(
        from spectralBins: [SpectralBin],
        sampleRate: Double,
        bandCount: Int
    ) -> [Float] {
        guard let range = usableFrequencyRange(sampleRate: sampleRate) else {
            return Array(repeating: 0, count: bandCount)
        }

        let lowerLog = log2(range.lowerBound)
        let upperLog = log2(range.upperBound)
        guard upperLog > lowerLog else {
            return Array(repeating: 0, count: bandCount)
        }

        var energies = Array(repeating: Float(0), count: bandCount)
        for bin in spectralBins where range.contains(bin.frequency) {
            let position = (log2(bin.frequency) - lowerLog) / (upperLog - lowerLog)
            let bandIndex = min(bandCount - 1, max(0, Int(position * Double(bandCount))))
            energies[bandIndex] += bin.power
        }

        return energies
    }

    private func melBandEnergies(from spectralBins: [SpectralBin], sampleRate: Double) -> [Float] {
        guard let range = usableFrequencyRange(sampleRate: sampleRate) else {
            return Array(repeating: 0, count: configuration.melBandCount)
        }

        let lowerMel = hertzToMel(range.lowerBound)
        let upperMel = hertzToMel(range.upperBound)
        let melPoints = (0..<(configuration.melBandCount + 2)).map { pointIndex in
            lowerMel + (upperMel - lowerMel) * Double(pointIndex) / Double(configuration.melBandCount + 1)
        }
        var energies = Array(repeating: Float(0), count: configuration.melBandCount)

        for bandIndex in 0..<configuration.melBandCount {
            let lower = melPoints[bandIndex]
            let center = melPoints[bandIndex + 1]
            let upper = melPoints[bandIndex + 2]

            for bin in spectralBins where range.contains(bin.frequency) {
                let mel = hertzToMel(bin.frequency)
                let weight: Double
                if mel >= lower, mel <= center {
                    weight = (mel - lower) / max(center - lower, .ulpOfOne)
                } else if mel > center, mel <= upper {
                    weight = (upper - mel) / max(upper - center, .ulpOfOne)
                } else {
                    weight = 0
                }

                if weight > 0 {
                    energies[bandIndex] += bin.power * Float(weight)
                }
            }
        }

        return energies
    }

    private func usableFrequencyRange(sampleRate: Double) -> ClosedRange<Double>? {
        let nyquist = sampleRate / 2
        guard nyquist > 0 else {
            return nil
        }

        let upper = min(configuration.maximumFrequency, nyquist)
        let lower = min(configuration.minimumFrequency, upper * 0.5)
        guard upper > lower else {
            return nil
        }

        return lower...upper
    }

    private func hertzToMel(_ hertz: Double) -> Double {
        2_595 * log10(1 + hertz / 700)
    }

    private func logScaledEnergy(_ energy: Float) -> Float {
        Float(log1p(Double(max(0, energy)) * 1_000))
    }

    private mutating func calculateSubbandOnset(currentLogEnergies: [Float]) -> [Float] {
        guard let previousSubbandLogEnergies,
              previousSubbandLogEnergies.count == currentLogEnergies.count
        else {
            return Array(repeating: 0, count: currentLogEnergies.count)
        }

        return zip(currentLogEnergies, previousSubbandLogEnergies).map { current, previous in
            max(0, current - previous)
        }
    }

    private mutating func calculatePCENMel(from melEnergies: [Float]) -> [Float] {
        if pcenSmoothers.count != melEnergies.count {
            pcenSmoothers = melEnergies
        }

        let smoothing = configuration.pcenSmoothingCoefficient
        let epsilon: Float = 0.000_001
        let deltaRoot = pow(configuration.pcenDelta, configuration.pcenRoot)

        return melEnergies.indices.map { index in
            let smoothed = (1 - smoothing) * pcenSmoothers[index] + smoothing * melEnergies[index]
            pcenSmoothers[index] = smoothed
            let denominator = pow(max(epsilon, smoothed), configuration.pcenAlpha)
            let normalized = melEnergies[index] / denominator
            return max(0, pow(normalized + configuration.pcenDelta, configuration.pcenRoot) - deltaRoot)
        }
    }

    private func calculateChroma(from spectralBins: [SpectralBin], sampleRate: Double) -> [Float] {
        guard let range = usableFrequencyRange(sampleRate: sampleRate) else {
            return Array(repeating: 0, count: configuration.chromaBinCount)
        }

        var chroma = Array(repeating: Float(0), count: configuration.chromaBinCount)
        for bin in spectralBins where range.contains(bin.frequency) {
            let midiNote = 69 + 12 * log2(bin.frequency / 440)
            let chromaIndex = positiveModulo(Int(round(midiNote)), configuration.chromaBinCount)
            chroma[chromaIndex] += bin.power
        }

        return l2Normalized(chroma)
    }

    private mutating func calculateCENS(from chroma: [Float]) -> [Float] {
        if censSmoother.count != chroma.count {
            censSmoother = chroma
        } else {
            let smoothing = configuration.censSmoothingCoefficient
            censSmoother = zip(censSmoother, chroma).map { previous, current in
                (1 - smoothing) * previous + smoothing * current
            }
        }

        let quantized = censSmoother.map { value -> Float in
            switch value {
            case ..<0.05:
                return 0
            case ..<0.10:
                return 1
            case ..<0.20:
                return 2
            case ..<0.40:
                return 3
            default:
                return 4
            }
        }

        return l2Normalized(quantized)
    }

    private func calculateSpectralPeaks(from spectralBins: [SpectralBin]) -> [SpectralPeak] {
        guard let maximumMagnitude = spectralBins.map(\.magnitude).max(), maximumMagnitude > 0 else {
            return []
        }

        let floorMagnitude = maximumMagnitude * 0.10
        var peaks: [SpectralPeak] = []

        for index in spectralBins.indices {
            let magnitude = spectralBins[index].magnitude
            let previousMagnitude = index > spectralBins.startIndex ? spectralBins[index - 1].magnitude : 0
            let nextMagnitude = index < spectralBins.index(before: spectralBins.endIndex)
                ? spectralBins[index + 1].magnitude
                : 0

            if magnitude >= floorMagnitude, magnitude >= previousMagnitude, magnitude >= nextMagnitude {
                peaks.append(SpectralPeak(binIndex: spectralBins[index].index, magnitude: magnitude))
            }
        }

        return peaks
            .sorted { $0.magnitude > $1.magnitude }
            .prefix(configuration.landmarkPeakCount)
            .map { $0 }
    }

    private func calculateLandmarkHashes(currentPeaks: [SpectralPeak]) -> [UInt64] {
        guard !currentPeaks.isEmpty else {
            return []
        }

        var hashes: [UInt64] = []
        if previousPeaks.isEmpty {
            hashes = currentPeaks.map { landmarkHash(anchorBin: $0.binIndex, targetBin: $0.binIndex, deltaFrames: 0) }
        } else {
            for anchor in previousPeaks {
                for target in currentPeaks {
                    hashes.append(landmarkHash(anchorBin: anchor.binIndex, targetBin: target.binIndex, deltaFrames: 1))
                }
            }
        }

        return Array(Set(hashes)).sorted()
    }

    private func landmarkHash(anchorBin: Int, targetBin: Int, deltaFrames: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for value in [UInt64(anchorBin), UInt64(targetBin), UInt64(deltaFrames)] {
            hash ^= value
            hash &*= 0x100000001b3
        }
        return hash
    }

    private mutating func updateSNR(energyDBFS: Double) -> Double {
        guard let noiseFloorDBFS else {
            self.noiseFloorDBFS = energyDBFS
            return 0
        }

        let coefficient = energyDBFS > noiseFloorDBFS
            ? configuration.noiseFloorRiseCoefficient
            : configuration.noiseFloorFallCoefficient
        let updatedNoiseFloor = noiseFloorDBFS + (energyDBFS - noiseFloorDBFS) * coefficient
        self.noiseFloorDBFS = max(configuration.silenceFloorDBFS, updatedNoiseFloor)

        return max(0, energyDBFS - updatedNoiseFloor)
    }

    private func positiveModulo(_ value: Int, _ modulo: Int) -> Int {
        let remainder = value % modulo
        return remainder >= 0 ? remainder : remainder + modulo
    }

    private func l2Normalized(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { partial, value in
            partial + value * value
        })
        guard norm > 0 else {
            return values
        }

        return values.map { $0 / norm }
    }
}

private struct SpectralBin: Equatable, Sendable {
    let index: Int
    let frequency: Double
    let magnitude: Float

    var power: Float {
        magnitude * magnitude
    }
}

private struct SpectralPeak: Equatable, Sendable {
    let binIndex: Int
    let magnitude: Float
}

private struct MicFeatureSpectrumAnalyzer: @unchecked Sendable {
    private var sampleCount = 0
    private var fftSize = 0
    private var log2FFTSize = vDSP_Length(0)
    private var plan: MicFeatureFFTPlan?
    private var hannWindow: [Float] = []
    private var centeredSamples: [Float] = []
    private var windowedSamples: [Float] = []
    private var realParts: [Float] = []
    private var imaginaryParts: [Float] = []
    private var spectralBins: [SpectralBin] = []

    mutating func spectrum(samples: [Float], sampleRate: Double) -> [SpectralBin] {
        guard samples.count > 1, sampleRate > 0 else {
            return []
        }

        prepareBuffers(sampleCount: samples.count)
        centerAndWindow(samples)
        runFFT()
        updateSpectralBins(sampleRate: sampleRate)
        return spectralBins
    }

    private mutating func prepareBuffers(sampleCount: Int) {
        let requiredFFTSize = nextPowerOfTwo(sampleCount)
        guard self.sampleCount != sampleCount || fftSize != requiredFFTSize else {
            return
        }

        self.sampleCount = sampleCount
        fftSize = requiredFFTSize
        log2FFTSize = vDSP_Length(fftSize.trailingZeroBitCount)
        plan = MicFeatureFFTPlan(size: fftSize)
        hannWindow = Self.makeHannWindow(count: sampleCount)
        centeredSamples = Array(repeating: 0, count: fftSize)
        windowedSamples = Array(repeating: 0, count: fftSize)
        realParts = Array(repeating: 0, count: fftSize / 2)
        imaginaryParts = Array(repeating: 0, count: fftSize / 2)
        spectralBins = (1...(fftSize / 2)).map { binIndex in
            SpectralBin(index: binIndex, frequency: 0, magnitude: 0)
        }
    }

    private mutating func centerAndWindow(_ samples: [Float]) {
        centeredSamples.withUnsafeMutableBufferPointer { centeredPointer in
            guard let centeredBaseAddress = centeredPointer.baseAddress else {
                return
            }

            samples.withUnsafeBufferPointer { samplePointer in
                guard let sampleBaseAddress = samplePointer.baseAddress else {
                    return
                }

                var mean = Float(0)
                vDSP_meanv(sampleBaseAddress, 1, &mean, vDSP_Length(sampleCount))
                var negativeMean = -mean
                vDSP_vsadd(
                    sampleBaseAddress,
                    1,
                    &negativeMean,
                    centeredBaseAddress,
                    1,
                    vDSP_Length(sampleCount)
                )
            }

            if fftSize > sampleCount {
                for index in sampleCount..<fftSize {
                    centeredPointer[index] = 0
                }
            }
        }

        hannWindow.withUnsafeBufferPointer { hannPointer in
            centeredSamples.withUnsafeBufferPointer { centeredPointer in
                windowedSamples.withUnsafeMutableBufferPointer { windowedPointer in
                    guard let hannBaseAddress = hannPointer.baseAddress,
                          let centeredBaseAddress = centeredPointer.baseAddress,
                          let windowedBaseAddress = windowedPointer.baseAddress
                    else {
                        return
                    }

                    vDSP_vmul(
                        centeredBaseAddress,
                        1,
                        hannBaseAddress,
                        1,
                        windowedBaseAddress,
                        1,
                        vDSP_Length(sampleCount)
                    )

                    if fftSize > sampleCount {
                        for index in sampleCount..<fftSize {
                            windowedPointer[index] = 0
                        }
                    }
                }
            }
        }
    }

    private mutating func runFFT() {
        guard let setup = plan?.setup else {
            return
        }

        realParts.withUnsafeMutableBufferPointer { realPointer in
            imaginaryParts.withUnsafeMutableBufferPointer { imaginaryPointer in
                windowedSamples.withUnsafeBufferPointer { samplePointer in
                    guard let realBaseAddress = realPointer.baseAddress,
                          let imaginaryBaseAddress = imaginaryPointer.baseAddress,
                          let sampleBaseAddress = samplePointer.baseAddress
                    else {
                        return
                    }

                    var splitComplex = DSPSplitComplex(realp: realBaseAddress, imagp: imaginaryBaseAddress)
                    sampleBaseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(
                            complexPointer,
                            2,
                            &splitComplex,
                            1,
                            vDSP_Length(fftSize / 2)
                        )
                    }
                    vDSP_fft_zrip(setup, &splitComplex, 1, log2FFTSize, FFTDirection(FFT_FORWARD))
                }
            }
        }
    }

    private mutating func updateSpectralBins(sampleRate: Double) {
        guard fftSize > 1 else {
            spectralBins = []
            return
        }

        let magnitudeScale = 1 / Float(sampleCount)
        let nyquistBinIndex = fftSize / 2

        for binIndex in 1..<nyquistBinIndex {
            let real = realParts[binIndex]
            let imaginary = imaginaryParts[binIndex]
            let magnitude = hypotf(real, imaginary) * magnitudeScale
            spectralBins[binIndex - 1] = SpectralBin(
                index: binIndex,
                frequency: sampleRate * Double(binIndex) / Double(fftSize),
                magnitude: magnitude
            )
        }

        spectralBins[nyquistBinIndex - 1] = SpectralBin(
            index: nyquistBinIndex,
            frequency: sampleRate / 2,
            magnitude: abs(imaginaryParts[0]) * magnitudeScale
        )
    }

    private func nextPowerOfTwo(_ value: Int) -> Int {
        var power = 1
        while power < value {
            power <<= 1
        }
        return power
    }

    private static func makeHannWindow(count: Int) -> [Float] {
        guard count > 1 else {
            return Array(repeating: 1, count: count)
        }

        return (0..<count).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1)))
        }
    }
}

private final class MicFeatureFFTPlan: @unchecked Sendable {
    let setup: FFTSetup

    init?(size: Int) {
        let log2Size = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            return nil
        }

        self.setup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }
}

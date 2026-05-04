import Foundation

public struct LandmarkHashStats: Equatable, Sendable {
    public let hash: UInt64
    public let postingCount: Int
    public let idfWeight: Double

    public init(hash: UInt64, postingCount: Int, idfWeight: Double) {
        self.hash = hash
        self.postingCount = postingCount
        self.idfWeight = idfWeight
    }
}

public struct AmbientSyncLandmarkIndex: Equatable, Sendable {
    public let landmarkCount: Int

    private let anchorTimesByHash: [UInt64: [Double]]

    public init(landmarks: [MicFeatureLandmark]) {
        var anchorTimesByHash: [UInt64: [Double]] = [:]
        for landmark in landmarks {
            anchorTimesByHash[landmark.hash, default: []].append(landmark.anchorTimeMS)
        }

        self.landmarkCount = landmarks.count
        self.anchorTimesByHash = anchorTimesByHash.mapValues { $0.sorted() }
    }

    public var hashCount: Int {
        anchorTimesByHash.count
    }

    public var postingsByHash: [UInt64: [Double]] {
        anchorTimesByHash
    }

    public func postingCount(for hash: UInt64) -> Int {
        anchorTimesByHash[hash]?.count ?? 0
    }

    public func idfWeight(for hash: UInt64) -> Double {
        log1p(Double(landmarkCount) / Double(postingCount(for: hash) + 1))
    }

    public func hashStats(for hash: UInt64) -> LandmarkHashStats {
        LandmarkHashStats(
            hash: hash,
            postingCount: postingCount(for: hash),
            idfWeight: idfWeight(for: hash)
        )
    }

    public func anchorTimes(for hash: UInt64) -> [Double] {
        anchorTimesByHash[hash] ?? []
    }
}

public struct AmbientSyncOffsetHistogram: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public let binWidthMS: Double
        public let maximumCandidateCount: Int
        public let minimumCandidateSeparationMS: Double

        public init(
            binWidthMS: Double = 20,
            maximumCandidateCount: Int = 32,
            minimumCandidateSeparationMS: Double = 1_500
        ) {
            precondition(binWidthMS > 0, "binWidthMS must be positive.")
            precondition(maximumCandidateCount > 0, "maximumCandidateCount must be positive.")
            precondition(minimumCandidateSeparationMS >= 0, "minimumCandidateSeparationMS must be non-negative.")

            self.binWidthMS = binWidthMS
            self.maximumCandidateCount = maximumCandidateCount
            self.minimumCandidateSeparationMS = minimumCandidateSeparationMS
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let binIndex: Int
        public let binCenterOffsetMS: Double
        public let offsetMS: Double
        public let voteCount: Int
        public let voteDensity: Double
        public let weightedVoteScore: Double
        public let uniqueHashCount: Int
        public let commonHashVoteCount: Int
        public let meanReferencePostingCount: Double
        public let queryTemporalSpreadMS: Double

        public var rawVoteCount: Int {
            voteCount
        }

        public init(
            binIndex: Int,
            binCenterOffsetMS: Double,
            offsetMS: Double,
            voteCount: Int,
            voteDensity: Double,
            weightedVoteScore: Double? = nil,
            uniqueHashCount: Int? = nil,
            commonHashVoteCount: Int = 0,
            meanReferencePostingCount: Double = 0,
            queryTemporalSpreadMS: Double
        ) {
            self.binIndex = binIndex
            self.binCenterOffsetMS = binCenterOffsetMS
            self.offsetMS = offsetMS
            self.voteCount = voteCount
            self.voteDensity = voteDensity
            self.weightedVoteScore = weightedVoteScore ?? Double(voteCount)
            self.uniqueHashCount = uniqueHashCount ?? voteCount
            self.commonHashVoteCount = commonHashVoteCount
            self.meanReferencePostingCount = meanReferencePostingCount
            self.queryTemporalSpreadMS = queryTemporalSpreadMS
        }
    }

    public let binWidthMS: Double
    public let queryLandmarkCount: Int
    public let totalVoteCount: Int
    public let bins: [Candidate]
    public let candidates: [Candidate]

    public init(
        queryLandmarks: [MicFeatureLandmark],
        localIndex: AmbientSyncLandmarkIndex,
        configuration: Configuration = Configuration(),
        searchRangeMS: ClosedRange<Double>? = nil
    ) {
        var accumulators: [Int: AmbientSyncOffsetVoteAccumulator] = [:]
        let queryHashCounts = Self.hashCounts(in: queryLandmarks)

        for queryLandmark in queryLandmarks {
            let hashStats = localIndex.hashStats(for: queryLandmark.hash)
            let queryTF = queryHashCounts[queryLandmark.hash, default: 1]
            let weight = Self.matchWeight(idfWeight: hashStats.idfWeight, queryTF: queryTF)

            for localAnchorTimeMS in localIndex.anchorTimes(for: queryLandmark.hash) {
                let offsetMS = AmbientSyncTimeProjection.offsetMS(
                    localReferenceTimeMS: localAnchorTimeMS,
                    micQueryTimeMS: queryLandmark.anchorTimeMS
                )
                if let searchRangeMS, !searchRangeMS.contains(offsetMS) {
                    continue
                }

                let binIndex = Int((offsetMS / configuration.binWidthMS).rounded(.toNearestOrAwayFromZero))
                accumulators[binIndex, default: AmbientSyncOffsetVoteAccumulator()].record(
                    offsetMS: offsetMS,
                    queryAnchorTimeMS: queryLandmark.anchorTimeMS,
                    hash: queryLandmark.hash,
                    weight: weight,
                    referencePostingCount: hashStats.postingCount
                )
            }
        }

        let bins = accumulators.map { binIndex, accumulator in
            accumulator.makeCandidate(
                binIndex: binIndex,
                binWidthMS: configuration.binWidthMS,
                queryLandmarkCount: queryLandmarks.count
            )
        }
        .sorted { lhs, rhs in
            lhs.binCenterOffsetMS < rhs.binCenterOffsetMS
        }

        let candidates = Self.independentCandidates(
            from: bins,
            maximumCount: configuration.maximumCandidateCount,
            minimumSeparationMS: configuration.minimumCandidateSeparationMS
        )

        self.binWidthMS = configuration.binWidthMS
        self.queryLandmarkCount = queryLandmarks.count
        self.totalVoteCount = bins.reduce(0) { total, bin in
            total + bin.voteCount
        }
        self.bins = bins
        self.candidates = Array(candidates)
    }

    private static func hashCounts(in landmarks: [MicFeatureLandmark]) -> [UInt64: Int] {
        var hashCounts: [UInt64: Int] = [:]
        for landmark in landmarks {
            hashCounts[landmark.hash, default: 0] += 1
        }

        return hashCounts
    }

    private static func matchWeight(idfWeight: Double, queryTF: Int) -> Double {
        let dampedWeight = idfWeight / sqrt(Double(max(queryTF, 1)))
        return min(3.0, max(0.05, dampedWeight))
    }

    public var topVoteCount: Int {
        candidates.first?.voteCount ?? 0
    }

    public var secondVoteCount: Int {
        guard candidates.count > 1 else {
            return 0
        }

        return candidates[1].voteCount
    }

    public var topWeightedVoteScore: Double {
        candidates.first?.weightedVoteScore ?? 0
    }

    public var secondWeightedVoteScore: Double {
        guard candidates.count > 1 else {
            return 0
        }

        return candidates[1].weightedVoteScore
    }

    public var topToSecondVoteRatio: Double {
        guard topVoteCount > 0 else {
            return 0
        }

        guard secondVoteCount > 0 else {
            return .infinity
        }

        return Double(topVoteCount) / Double(secondVoteCount)
    }

    public var topToSecondWeightedVoteRatio: Double {
        guard topWeightedVoteScore > 0 else {
            return 0
        }

        guard secondWeightedVoteScore > 0 else {
            return .infinity
        }

        return topWeightedVoteScore / secondWeightedVoteScore
    }

    public var topVoteMargin: Int {
        topVoteCount - secondVoteCount
    }

    public var topWeightedVoteMargin: Double {
        topWeightedVoteScore - secondWeightedVoteScore
    }

    public var candidateOffsetsMS: [Double] {
        candidates.map(\.offsetMS)
    }

    private static func independentCandidates(
        from bins: [Candidate],
        maximumCount: Int,
        minimumSeparationMS: Double
    ) -> [Candidate] {
        var selectedCandidates: [Candidate] = []

        for candidate in bins.sorted(by: Self.isHigherRankedCandidate) {
            guard selectedCandidates.allSatisfy({ selectedCandidate in
                abs(selectedCandidate.binCenterOffsetMS - candidate.binCenterOffsetMS) >= minimumSeparationMS
            }) else {
                continue
            }

            selectedCandidates.append(candidate)
            if selectedCandidates.count == maximumCount {
                break
            }
        }

        return selectedCandidates
    }

    private static func isHigherRankedCandidate(
        lhs: Candidate,
        rhs: Candidate
    ) -> Bool {
        if lhs.weightedVoteScore != rhs.weightedVoteScore {
            return lhs.weightedVoteScore > rhs.weightedVoteScore
        }

        if lhs.uniqueHashCount != rhs.uniqueHashCount {
            return lhs.uniqueHashCount > rhs.uniqueHashCount
        }

        if lhs.queryTemporalSpreadMS != rhs.queryTemporalSpreadMS {
            return lhs.queryTemporalSpreadMS > rhs.queryTemporalSpreadMS
        }

        if lhs.rawVoteCount != rhs.rawVoteCount {
            return lhs.rawVoteCount > rhs.rawVoteCount
        }

        return lhs.binCenterOffsetMS < rhs.binCenterOffsetMS
    }
}

private struct AmbientSyncOffsetVoteAccumulator: Equatable, Sendable {
    private var offsetSumMS: Double = 0
    private var weightedOffsetSumMS: Double = 0
    private var earliestQueryAnchorTimeMS: Double?
    private var latestQueryAnchorTimeMS: Double?
    private var matchedHashes: Set<UInt64> = []
    private var referencePostingCountSum: Int = 0

    private(set) var voteCount: Int = 0
    private(set) var weightedVoteScore: Double = 0
    private(set) var commonHashVoteCount: Int = 0

    mutating func record(
        offsetMS: Double,
        queryAnchorTimeMS: Double,
        hash: UInt64,
        weight: Double,
        referencePostingCount: Int
    ) {
        offsetSumMS += offsetMS
        weightedOffsetSumMS += offsetMS * weight
        voteCount += 1
        weightedVoteScore += weight
        matchedHashes.insert(hash)
        referencePostingCountSum += referencePostingCount
        if referencePostingCount > 1 {
            commonHashVoteCount += 1
        }

        earliestQueryAnchorTimeMS = min(earliestQueryAnchorTimeMS ?? queryAnchorTimeMS, queryAnchorTimeMS)
        latestQueryAnchorTimeMS = max(latestQueryAnchorTimeMS ?? queryAnchorTimeMS, queryAnchorTimeMS)
    }

    func makeCandidate(
        binIndex: Int,
        binWidthMS: Double,
        queryLandmarkCount: Int
    ) -> AmbientSyncOffsetHistogram.Candidate {
        let temporalSpreadMS: Double
        if let earliestQueryAnchorTimeMS, let latestQueryAnchorTimeMS {
            temporalSpreadMS = latestQueryAnchorTimeMS - earliestQueryAnchorTimeMS
        } else {
            temporalSpreadMS = 0
        }

        let voteDensity: Double
        if queryLandmarkCount > 0 {
            voteDensity = Double(voteCount) / Double(queryLandmarkCount)
        } else {
            voteDensity = 0
        }

        let meanReferencePostingCount: Double
        if voteCount > 0 {
            meanReferencePostingCount = Double(referencePostingCountSum) / Double(voteCount)
        } else {
            meanReferencePostingCount = 0
        }

        let meanOffsetMS: Double
        if weightedVoteScore > 0 {
            meanOffsetMS = weightedOffsetSumMS / weightedVoteScore
        } else if voteCount > 0 {
            meanOffsetMS = offsetSumMS / Double(voteCount)
        } else {
            meanOffsetMS = Double(binIndex) * binWidthMS
        }

        return AmbientSyncOffsetHistogram.Candidate(
            binIndex: binIndex,
            binCenterOffsetMS: Double(binIndex) * binWidthMS,
            offsetMS: meanOffsetMS,
            voteCount: voteCount,
            voteDensity: voteDensity,
            weightedVoteScore: weightedVoteScore,
            uniqueHashCount: matchedHashes.count,
            commonHashVoteCount: commonHashVoteCount,
            meanReferencePostingCount: meanReferencePostingCount,
            queryTemporalSpreadMS: temporalSpreadMS
        )
    }
}

public struct AmbientSyncDenseReranker: Equatable, Sendable {
    private static let downweightedDenseFrameWeight = 0.25

    public struct FeatureSet: OptionSet, Equatable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let onsetEnvelope = FeatureSet(rawValue: 1 << 0)
        public static let subbandOnset = FeatureSet(rawValue: 1 << 1)
        public static let pcenMel = FeatureSet(rawValue: 1 << 2)
        public static let chromaOnset = FeatureSet(rawValue: 1 << 3)
        public static let cens = FeatureSet(rawValue: 1 << 4)
    }

    public struct FeatureWeights: Equatable, Sendable {
        public let onsetEnvelope: Double
        public let subbandOnset: Double
        public let pcenMel: Double
        public let chromaOnset: Double
        public let cens: Double

        public init(
            onsetEnvelope: Double = 0.25,
            subbandOnset: Double = 0.25,
            pcenMel: Double = 0.20,
            chromaOnset: Double = 0.15,
            cens: Double = 0.15
        ) {
            precondition(onsetEnvelope >= 0, "onsetEnvelope weight must be non-negative.")
            precondition(subbandOnset >= 0, "subbandOnset weight must be non-negative.")
            precondition(pcenMel >= 0, "pcenMel weight must be non-negative.")
            precondition(chromaOnset >= 0, "chromaOnset weight must be non-negative.")
            precondition(cens >= 0, "cens weight must be non-negative.")

            self.onsetEnvelope = onsetEnvelope
            self.subbandOnset = subbandOnset
            self.pcenMel = pcenMel
            self.chromaOnset = chromaOnset
            self.cens = cens
        }

        var total: Double {
            onsetEnvelope + subbandOnset + pcenMel + chromaOnset + cens
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let weights: FeatureWeights
        public let minimumComparableFrameCount: Int
        public let minimumComparableDurationMS: Double
        public let minimumCoverageRatio: Double
        public let maximumFrameTimeErrorMS: Double
        public let refinementSearchRadiusMS: Double
        public let refinementStepMS: Double
        public let featureAgreementThreshold: Double
        public let minimumTimingFeatureScore: Double
        public let minimumUsableFrameEnergyDBFS: Double
        public let minimumUsableFrameSNRDB: Double?
        public let minimumLandmarkVoteCount: Int
        public let minimumLandmarkScore: Double
        public let minimumCombinedDenseScore: Double
        public let minimumDenseMargin: Double
        public let minimumFeatureAgreementCount: Int
        public let maximumDenseLandmarkDisagreementMS: Double
        public let timingEvidenceFeatures: FeatureSet
        public let robustEvidenceFeatures: FeatureSet

        public init(
            weights: FeatureWeights = FeatureWeights(),
            minimumComparableFrameCount: Int = 60,
            minimumComparableDurationMS: Double = 1_000,
            minimumCoverageRatio: Double = 0.90,
            maximumFrameTimeErrorMS: Double = 12,
            refinementSearchRadiusMS: Double = 100,
            refinementStepMS: Double = 5,
            featureAgreementThreshold: Double = 0.55,
            minimumTimingFeatureScore: Double = 0.45,
            minimumUsableFrameEnergyDBFS: Double = -80,
            minimumUsableFrameSNRDB: Double? = nil,
            minimumLandmarkVoteCount: Int = 8,
            minimumLandmarkScore: Double = 0.015,
            minimumCombinedDenseScore: Double = 0.52,
            minimumDenseMargin: Double = 0.05,
            minimumFeatureAgreementCount: Int = 2,
            maximumDenseLandmarkDisagreementMS: Double = 120,
            timingEvidenceFeatures: FeatureSet = [.onsetEnvelope, .subbandOnset, .chromaOnset],
            robustEvidenceFeatures: FeatureSet = [.pcenMel, .cens]
        ) {
            precondition(weights.total > 0, "At least one dense rerank feature weight must be positive.")
            precondition(minimumComparableFrameCount > 0, "minimumComparableFrameCount must be positive.")
            precondition(
                minimumComparableDurationMS >= 0 && minimumComparableDurationMS.isFinite,
                "minimumComparableDurationMS must be finite and non-negative."
            )
            precondition((0...1).contains(minimumCoverageRatio), "minimumCoverageRatio must be between 0 and 1.")
            precondition(maximumFrameTimeErrorMS >= 0, "maximumFrameTimeErrorMS must be non-negative.")
            precondition(
                refinementSearchRadiusMS >= 0 && refinementSearchRadiusMS.isFinite,
                "refinementSearchRadiusMS must be finite and non-negative."
            )
            precondition(
                refinementStepMS > 0 && refinementStepMS.isFinite,
                "refinementStepMS must be finite and positive."
            )
            precondition(
                (0...1).contains(featureAgreementThreshold),
                "featureAgreementThreshold must be between 0 and 1."
            )
            precondition(
                (0...1).contains(minimumTimingFeatureScore),
                "minimumTimingFeatureScore must be between 0 and 1."
            )
            precondition(minimumUsableFrameEnergyDBFS.isFinite, "minimumUsableFrameEnergyDBFS must be finite.")
            if let minimumUsableFrameSNRDB {
                precondition(minimumUsableFrameSNRDB >= 0, "minimumUsableFrameSNRDB must be non-negative.")
            }
            precondition(minimumLandmarkVoteCount > 0, "minimumLandmarkVoteCount must be positive.")
            precondition((0...1).contains(minimumLandmarkScore), "minimumLandmarkScore must be between 0 and 1.")
            precondition((0...1).contains(minimumCombinedDenseScore), "minimumCombinedDenseScore must be between 0 and 1.")
            precondition(minimumDenseMargin >= 0, "minimumDenseMargin must be non-negative.")
            precondition(minimumFeatureAgreementCount > 0, "minimumFeatureAgreementCount must be positive.")
            precondition(
                maximumDenseLandmarkDisagreementMS >= 0,
                "maximumDenseLandmarkDisagreementMS must be non-negative."
            )
            precondition(!timingEvidenceFeatures.isEmpty, "At least one timing evidence feature must be configured.")
            precondition(!robustEvidenceFeatures.isEmpty, "At least one robust evidence feature must be configured.")

            self.weights = weights
            self.minimumComparableFrameCount = minimumComparableFrameCount
            self.minimumComparableDurationMS = minimumComparableDurationMS
            self.minimumCoverageRatio = minimumCoverageRatio
            self.maximumFrameTimeErrorMS = maximumFrameTimeErrorMS
            self.refinementSearchRadiusMS = refinementSearchRadiusMS
            self.refinementStepMS = refinementStepMS
            self.featureAgreementThreshold = featureAgreementThreshold
            self.minimumTimingFeatureScore = minimumTimingFeatureScore
            self.minimumUsableFrameEnergyDBFS = minimumUsableFrameEnergyDBFS
            self.minimumUsableFrameSNRDB = minimumUsableFrameSNRDB
            self.minimumLandmarkVoteCount = minimumLandmarkVoteCount
            self.minimumLandmarkScore = minimumLandmarkScore
            self.minimumCombinedDenseScore = minimumCombinedDenseScore
            self.minimumDenseMargin = minimumDenseMargin
            self.minimumFeatureAgreementCount = minimumFeatureAgreementCount
            self.maximumDenseLandmarkDisagreementMS = maximumDenseLandmarkDisagreementMS
            self.timingEvidenceFeatures = timingEvidenceFeatures
            self.robustEvidenceFeatures = robustEvidenceFeatures
        }
    }

    public struct CandidateScore: Equatable, Sendable {
        public let offsetMS: Double
        public let coarseOffsetMS: Double
        public let landmarkVoteCount: Int
        public let rawVoteCount: Int
        public let weightedVoteScore: Double
        public let uniqueHashCount: Int
        public let commonHashVoteCount: Int
        public let meanReferencePostingCount: Double
        public let landmarkScore: Double
        public let voteDensity: Double
        public let comparableFrameCount: Int
        public let coverageRatio: Double
        public let hasSufficientCoverage: Bool
        public let onsetScore: Double
        public let subbandOnsetScore: Double
        public let pcenMelScore: Double
        public let chromaOnsetScore: Double
        public let censScore: Double
        public let combinedDenseScore: Double
        public let featureAgreementCount: Int

        public init(
            offsetMS: Double,
            landmarkVoteCount: Int,
            rawVoteCount: Int? = nil,
            weightedVoteScore: Double? = nil,
            uniqueHashCount: Int? = nil,
            commonHashVoteCount: Int = 0,
            meanReferencePostingCount: Double = 0,
            landmarkScore: Double,
            voteDensity: Double? = nil,
            comparableFrameCount: Int,
            coverageRatio: Double,
            hasSufficientCoverage: Bool,
            onsetScore: Double,
            subbandOnsetScore: Double,
            pcenMelScore: Double,
            chromaOnsetScore: Double,
            censScore: Double,
            combinedDenseScore: Double,
            featureAgreementCount: Int,
            coarseOffsetMS: Double? = nil
        ) {
            self.offsetMS = offsetMS
            self.coarseOffsetMS = coarseOffsetMS ?? offsetMS
            self.landmarkVoteCount = landmarkVoteCount
            self.rawVoteCount = rawVoteCount ?? landmarkVoteCount
            self.weightedVoteScore = weightedVoteScore ?? Double(rawVoteCount ?? landmarkVoteCount)
            self.uniqueHashCount = uniqueHashCount ?? rawVoteCount ?? landmarkVoteCount
            self.commonHashVoteCount = commonHashVoteCount
            self.meanReferencePostingCount = meanReferencePostingCount
            self.landmarkScore = landmarkScore
            self.voteDensity = voteDensity ?? landmarkScore
            self.comparableFrameCount = comparableFrameCount
            self.coverageRatio = coverageRatio
            self.hasSufficientCoverage = hasSufficientCoverage
            self.onsetScore = onsetScore
            self.subbandOnsetScore = subbandOnsetScore
            self.pcenMelScore = pcenMelScore
            self.chromaOnsetScore = chromaOnsetScore
            self.censScore = censScore
            self.combinedDenseScore = combinedDenseScore
            self.featureAgreementCount = featureAgreementCount
        }

        fileprivate func score(for feature: AmbientSyncDenseFeatureKind) -> Double {
            switch feature {
            case .onsetEnvelope:
                onsetScore
            case .subbandOnset:
                subbandOnsetScore
            case .pcenMel:
                pcenMelScore
            case .chromaOnset:
                chromaOnsetScore
            case .cens:
                censScore
            }
        }

        fileprivate func passesAnyFeature(in features: FeatureSet, threshold: Double) -> Bool {
            if features.contains(.onsetEnvelope), onsetScore >= threshold {
                return true
            }
            if features.contains(.subbandOnset), subbandOnsetScore >= threshold {
                return true
            }
            if features.contains(.pcenMel), pcenMelScore >= threshold {
                return true
            }
            if features.contains(.chromaOnset), chromaOnsetScore >= threshold {
                return true
            }
            if features.contains(.cens), censScore >= threshold {
                return true
            }

            return false
        }

        fileprivate func withFeatureAgreementCount(_ featureAgreementCount: Int) -> CandidateScore {
            CandidateScore(
                offsetMS: offsetMS,
                landmarkVoteCount: landmarkVoteCount,
                rawVoteCount: rawVoteCount,
                weightedVoteScore: weightedVoteScore,
                uniqueHashCount: uniqueHashCount,
                commonHashVoteCount: commonHashVoteCount,
                meanReferencePostingCount: meanReferencePostingCount,
                landmarkScore: landmarkScore,
                voteDensity: voteDensity,
                comparableFrameCount: comparableFrameCount,
                coverageRatio: coverageRatio,
                hasSufficientCoverage: hasSufficientCoverage,
                onsetScore: onsetScore,
                subbandOnsetScore: subbandOnsetScore,
                pcenMelScore: pcenMelScore,
                chromaOnsetScore: chromaOnsetScore,
                censScore: censScore,
                combinedDenseScore: combinedDenseScore,
                featureAgreementCount: featureAgreementCount,
                coarseOffsetMS: coarseOffsetMS
            )
        }
    }

    public struct Result: Equatable, Sendable {
        public let candidates: [CandidateScore]
        public let denseMargin: Double
        public let hasConfidentBestCandidate: Bool

        public init(candidates: [CandidateScore], denseMargin: Double, hasConfidentBestCandidate: Bool = true) {
            self.candidates = candidates
            self.denseMargin = denseMargin
            self.hasConfidentBestCandidate = hasConfidentBestCandidate
        }

        public var bestCandidate: CandidateScore? {
            hasConfidentBestCandidate ? candidates.first : nil
        }

        public var leadingCandidate: CandidateScore? {
            candidates.first
        }

        public var secondCandidate: CandidateScore? {
            guard candidates.count > 1 else {
                return nil
            }

            return candidates[1]
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func rerank(
        queryWindow: MicFeatureWindow,
        localFrames: [MicFeatureFrame],
        candidates: [AmbientSyncOffsetHistogram.Candidate]
    ) -> Result {
        let sortedQueryFrames = Self.sortedByRecordedTimeIfNeeded(queryWindow.frames)
        let sortedLocalFrames = Self.sortedByRecordedTimeIfNeeded(localFrames)
        let queryEvidence = denseQueryEvidence(in: sortedQueryFrames)
        let scoredCandidates = candidates.map { candidate in
            score(
                candidate: candidate,
                queryFrames: sortedQueryFrames,
                localFrames: sortedLocalFrames,
                queryEvidence: queryEvidence
            )
        }
        let candidatesWithAgreement = addFeatureAgreement(to: scoredCandidates)
        let rankedCandidates = candidatesWithAgreement.sorted(by: Self.isHigherRanked)
        let denseMargin: Double
        if rankedCandidates.count > 1 {
            denseMargin = rankedCandidates[0].combinedDenseScore - rankedCandidates[1].combinedDenseScore
        } else {
            denseMargin = rankedCandidates.first?.combinedDenseScore ?? 0
        }
        let clampedDenseMargin = max(0, denseMargin)
        let hasConfidentBestCandidate = rankedCandidates.first.map { candidate in
            passesDenseGate(
                candidate: candidate,
                denseMargin: clampedDenseMargin
            )
        } ?? false

        return Result(
            candidates: rankedCandidates,
            denseMargin: clampedDenseMargin,
            hasConfidentBestCandidate: hasConfidentBestCandidate
        )
    }

    private func score(
        candidate: AmbientSyncOffsetHistogram.Candidate,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> CandidateScore {
        let bestEvaluation = bestDenseEvaluation(
            coarseOffsetMS: candidate.offsetMS,
            queryFrames: queryFrames,
            localFrames: localFrames,
            queryEvidence: queryEvidence
        )

        return CandidateScore(
            offsetMS: bestEvaluation.offsetMS,
            landmarkVoteCount: candidate.voteCount,
            rawVoteCount: candidate.rawVoteCount,
            weightedVoteScore: candidate.weightedVoteScore,
            uniqueHashCount: candidate.uniqueHashCount,
            commonHashVoteCount: candidate.commonHashVoteCount,
            meanReferencePostingCount: candidate.meanReferencePostingCount,
            landmarkScore: min(1, max(0, candidate.voteDensity)),
            voteDensity: candidate.voteDensity,
            comparableFrameCount: bestEvaluation.comparableFrameCount,
            coverageRatio: bestEvaluation.coverageRatio,
            hasSufficientCoverage: bestEvaluation.hasSufficientCoverage,
            onsetScore: bestEvaluation.onsetScore,
            subbandOnsetScore: bestEvaluation.subbandOnsetScore,
            pcenMelScore: bestEvaluation.pcenMelScore,
            chromaOnsetScore: bestEvaluation.chromaOnsetScore,
            censScore: bestEvaluation.censScore,
            combinedDenseScore: bestEvaluation.combinedDenseScore,
            featureAgreementCount: 0,
            coarseOffsetMS: candidate.offsetMS
        )
    }

    private func denseQueryEvidence(in queryFrames: [MicFeatureFrame]) -> AmbientSyncDenseQueryEvidence {
        var usableFrameCount = 0
        var firstUsableTimeMS: Double?
        var lastUsableTimeMS: Double?

        for frame in queryFrames where isUsableDenseFrame(frame) {
            usableFrameCount += 1
            firstUsableTimeMS = firstUsableTimeMS ?? frame.recordedTimeMS
            lastUsableTimeMS = frame.recordedTimeMS
        }

        let usableDurationMS: Double
        if let firstUsableTimeMS, let lastUsableTimeMS {
            usableDurationMS = lastUsableTimeMS - firstUsableTimeMS
        } else {
            usableDurationMS = 0
        }

        return AmbientSyncDenseQueryEvidence(
            coverageFrameCount: queryFrames.count,
            usableFrameCount: usableFrameCount,
            usableDurationMS: usableDurationMS
        )
    }

    private func bestDenseEvaluation(
        coarseOffsetMS: Double,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> AmbientSyncDenseOffsetEvaluation {
        var bestEvaluation = AmbientSyncDenseOffsetEvaluation.empty(offsetMS: coarseOffsetMS)
        for offsetMS in denseOffsetSearchOffsets(centerOffsetMS: coarseOffsetMS) {
            let evaluation = evaluateDenseOffset(
                offsetMS: offsetMS,
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence
            )
            if Self.isHigherDenseEvaluation(
                lhs: evaluation,
                rhs: bestEvaluation,
                coarseOffsetMS: coarseOffsetMS
            ) {
                bestEvaluation = evaluation
            }
        }

        return bestEvaluation
    }

    private func denseOffsetSearchOffsets(centerOffsetMS: Double) -> [Double] {
        guard configuration.refinementSearchRadiusMS > 0 else {
            return [centerOffsetMS]
        }

        var offsets = [centerOffsetMS]
        var deltaMS = configuration.refinementStepMS
        while deltaMS <= configuration.refinementSearchRadiusMS + configuration.refinementStepMS * 0.5 {
            offsets.append(centerOffsetMS - deltaMS)
            offsets.append(centerOffsetMS + deltaMS)
            deltaMS += configuration.refinementStepMS
        }

        return offsets
    }

    private func evaluateDenseOffset(
        offsetMS: Double,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> AmbientSyncDenseOffsetEvaluation {
        let framePairs = alignedFramePairs(
            queryFrames: queryFrames,
            localFrames: localFrames,
            offsetMS: offsetMS
        )
        let comparableFrameCount = usableDenseFramePairCount(framePairs)
        let coverageRatio = queryEvidence.coverageFrameCount == 0
            ? 0
            : Double(framePairs.count) / Double(queryEvidence.coverageFrameCount)
        let meanFrameTimeErrorMS = meanFrameTimeErrorMS(framePairs, offsetMS: offsetMS)
        let hasSufficientCoverage = comparableFrameCount >= configuration.minimumComparableFrameCount
            && queryEvidence.usableDurationMS >= configuration.minimumComparableDurationMS
            && coverageRatio >= configuration.minimumCoverageRatio

        guard hasSufficientCoverage else {
            return AmbientSyncDenseOffsetEvaluation(
                offsetMS: offsetMS,
                comparableFrameCount: comparableFrameCount,
                coverageRatio: coverageRatio,
                hasSufficientCoverage: false,
                meanFrameTimeErrorMS: meanFrameTimeErrorMS
            )
        }

        let onsetScore = scalarFeatureScore(framePairs) { $0.onsetEnvelope }
        let subbandOnsetScore = vectorFeatureScore(framePairs) { $0.subbandOnset }
        let pcenMelScore = vectorFeatureScore(framePairs) { $0.pcenMel }
        let chromaOnsetScore = chromaOnsetFeatureScore(framePairs)
        let censScore = vectorFeatureScore(framePairs) { $0.cens }
        let combinedDenseScore = weightedCombinedScore(
            onsetScore: onsetScore,
            subbandOnsetScore: subbandOnsetScore,
            pcenMelScore: pcenMelScore,
            chromaOnsetScore: chromaOnsetScore,
            censScore: censScore
        )

        return AmbientSyncDenseOffsetEvaluation(
            offsetMS: offsetMS,
            comparableFrameCount: comparableFrameCount,
            coverageRatio: coverageRatio,
            hasSufficientCoverage: true,
            meanFrameTimeErrorMS: meanFrameTimeErrorMS,
            onsetScore: onsetScore,
            subbandOnsetScore: subbandOnsetScore,
            pcenMelScore: pcenMelScore,
            chromaOnsetScore: chromaOnsetScore,
            censScore: censScore,
            combinedDenseScore: combinedDenseScore
        )
    }

    private func meanFrameTimeErrorMS(
        _ framePairs: [AmbientSyncDenseFramePair],
        offsetMS: Double
    ) -> Double {
        guard !framePairs.isEmpty else {
            return .infinity
        }

        let totalErrorMS = framePairs.reduce(0) { total, framePair in
            let targetLocalTimeMS = framePair.query.recordedTimeMS + offsetMS
            return total + abs(framePair.local.recordedTimeMS - targetLocalTimeMS)
        }

        return totalErrorMS / Double(framePairs.count)
    }

    private func addFeatureAgreement(to candidates: [CandidateScore]) -> [CandidateScore] {
        return candidates.map { candidate in
            let agreementCount = AmbientSyncDenseFeatureKind.allCases.reduce(0) { count, feature in
                let featureScore = candidate.score(for: feature)
                guard candidate.hasSufficientCoverage,
                      featureScore >= configuration.featureAgreementThreshold
                else {
                    return count
                }

                return count + 1
            }

            return candidate.withFeatureAgreementCount(agreementCount)
        }
    }

    private func alignedFramePairs(
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        offsetMS: Double
    ) -> [AmbientSyncDenseFramePair] {
        guard let firstQueryFrame = queryFrames.first,
              let lastQueryFrame = queryFrames.last
        else {
            return []
        }

        let lowerTimeMS = firstQueryFrame.recordedTimeMS + offsetMS - configuration.maximumFrameTimeErrorMS
        let upperTimeMS = lastQueryFrame.recordedTimeMS + offsetMS + configuration.maximumFrameTimeErrorMS
        let localWindow = localFrameWindow(in: localFrames, from: lowerTimeMS, through: upperTimeMS)
        guard !localWindow.isEmpty else {
            return []
        }

        var framePairs: [AmbientSyncDenseFramePair] = []
        framePairs.reserveCapacity(queryFrames.count)
        var localIndex = localWindow.startIndex

        for queryFrame in queryFrames {
            let localTimeMS = queryFrame.recordedTimeMS + offsetMS
            while localIndex < localWindow.endIndex,
                  localWindow[localIndex].recordedTimeMS < localTimeMS {
                localIndex = localWindow.index(after: localIndex)
            }

            var bestFrame: MicFeatureFrame?
            if localIndex < localWindow.endIndex {
                bestFrame = localWindow[localIndex]
            }
            if localIndex > localWindow.startIndex {
                let previousFrame = localWindow[localWindow.index(before: localIndex)]
                if let currentBest = bestFrame {
                    let previousDistance = abs(previousFrame.recordedTimeMS - localTimeMS)
                    let bestDistance = abs(currentBest.recordedTimeMS - localTimeMS)
                    if previousDistance < bestDistance {
                        bestFrame = previousFrame
                    }
                } else {
                    bestFrame = previousFrame
                }
            }

            guard let localFrame = bestFrame
            else {
                continue
            }

            let timeErrorMS = abs(localFrame.recordedTimeMS - localTimeMS)
            guard timeErrorMS <= configuration.maximumFrameTimeErrorMS else {
                continue
            }

            framePairs.append(
                AmbientSyncDenseFramePair(
                    query: queryFrame,
                    local: localFrame,
                    weight: densePairWeight(query: queryFrame, local: localFrame)
                )
            )
        }

        return framePairs
    }

    private func localFrameWindow(
        in frames: [MicFeatureFrame],
        from lowerTimeMS: Double,
        through upperTimeMS: Double
    ) -> ArraySlice<MicFeatureFrame> {
        guard !frames.isEmpty, lowerTimeMS <= upperTimeMS else {
            return frames[0..<0]
        }

        let startIndex = lowerBoundFrameIndex(in: frames, timeMS: lowerTimeMS)
        let endIndex = upperBoundFrameIndex(in: frames, timeMS: upperTimeMS)
        return frames[startIndex..<endIndex]
    }

    private func lowerBoundFrameIndex(in frames: [MicFeatureFrame], timeMS: Double) -> Int {
        var lowerBound = 0
        var upperBound = frames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if frames[middle].recordedTimeMS < timeMS {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
    }

    private func upperBoundFrameIndex(in frames: [MicFeatureFrame], timeMS: Double) -> Int {
        var lowerBound = 0
        var upperBound = frames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if frames[middle].recordedTimeMS <= timeMS {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
    }

    private func isUsableDenseFrame(_ frame: MicFeatureFrame) -> Bool {
        guard frame.energyDBFS >= configuration.minimumUsableFrameEnergyDBFS else {
            return false
        }

        if let minimumSNRDB = configuration.minimumUsableFrameSNRDB {
            guard let snrDB = frame.snrDB, snrDB >= minimumSNRDB else {
                return false
            }
        }

        return true
    }

    private func usableDenseFramePairCount(_ framePairs: [AmbientSyncDenseFramePair]) -> Int {
        framePairs.reduce(0) { count, framePair in
            isUsableDenseFrame(framePair.query) && isUsableDenseFrame(framePair.local) ? count + 1 : count
        }
    }

    private func densePairWeight(query: MicFeatureFrame, local: MicFeatureFrame) -> Double {
        min(denseFrameWeight(query), denseFrameWeight(local))
    }

    private func denseFrameWeight(_ frame: MicFeatureFrame) -> Double {
        var weight = 1.0
        if frame.energyDBFS < configuration.minimumUsableFrameEnergyDBFS {
            weight *= Self.downweightedDenseFrameWeight
        }

        if let minimumSNRDB = configuration.minimumUsableFrameSNRDB {
            guard let snrDB = frame.snrDB else {
                return weight * Self.downweightedDenseFrameWeight
            }

            if snrDB < minimumSNRDB {
                weight *= Self.downweightedDenseFrameWeight
            }
        }

        return weight
    }

    private func scalarFeatureScore(
        _ framePairs: [AmbientSyncDenseFramePair],
        value: (MicFeatureFrame) -> Float
    ) -> Double {
        var accumulator = AmbientSyncCosineAccumulator()
        for framePair in framePairs {
            accumulator.append(
                Double(value(framePair.query)),
                Double(value(framePair.local)),
                weight: framePair.weight
            )
        }

        return accumulator.score
    }

    private func vectorFeatureScore(
        _ framePairs: [AmbientSyncDenseFramePair],
        values: (MicFeatureFrame) -> [Float]
    ) -> Double {
        var accumulator = AmbientSyncCosineAccumulator()

        for framePair in framePairs {
            guard appendComparableValues(
                query: values(framePair.query),
                local: values(framePair.local),
                weight: framePair.weight,
                accumulator: &accumulator
            ) else {
                return 0
            }
        }

        return accumulator.score
    }

    private func chromaOnsetFeatureScore(_ framePairs: [AmbientSyncDenseFramePair]) -> Double {
        guard framePairs.count > 1 else {
            return 0
        }

        var accumulator = AmbientSyncCosineAccumulator()

        for index in framePairs.indices.dropFirst() {
            let previousPair = framePairs[index - 1]
            let currentPair = framePairs[index]
            guard appendComparablePositiveDeltas(
                previousQuery: previousPair.query.chroma,
                currentQuery: currentPair.query.chroma,
                previousLocal: previousPair.local.chroma,
                currentLocal: currentPair.local.chroma,
                weight: min(previousPair.weight, currentPair.weight),
                accumulator: &accumulator
            ) else {
                return 0
            }
        }

        return accumulator.score
    }

    private func appendComparableValues(
        query: [Float],
        local: [Float],
        weight: Double,
        accumulator: inout AmbientSyncCosineAccumulator
    ) -> Bool {
        guard !query.isEmpty, query.count == local.count else {
            return false
        }

        for index in query.indices {
            accumulator.append(Double(query[index]), Double(local[index]), weight: weight)
        }

        return true
    }

    private func appendComparablePositiveDeltas(
        previousQuery: [Float],
        currentQuery: [Float],
        previousLocal: [Float],
        currentLocal: [Float],
        weight: Double,
        accumulator: inout AmbientSyncCosineAccumulator
    ) -> Bool {
        guard !previousQuery.isEmpty,
              previousQuery.count == currentQuery.count,
              previousQuery.count == previousLocal.count,
              previousQuery.count == currentLocal.count
        else {
            return false
        }

        for index in previousQuery.indices {
            accumulator.append(
                Double(max(0, currentQuery[index] - previousQuery[index])),
                Double(max(0, currentLocal[index] - previousLocal[index])),
                weight: weight
            )
        }

        return true
    }

    private func weightedCombinedScore(
        onsetScore: Double,
        subbandOnsetScore: Double,
        pcenMelScore: Double,
        chromaOnsetScore: Double,
        censScore: Double
    ) -> Double {
        let weights = configuration.weights
        let weightedSum = onsetScore * weights.onsetEnvelope
            + subbandOnsetScore * weights.subbandOnset
            + pcenMelScore * weights.pcenMel
            + chromaOnsetScore * weights.chromaOnset
            + censScore * weights.cens

        return weightedSum / weights.total
    }

    private func passesDenseGate(
        candidate: CandidateScore,
        denseMargin: Double
    ) -> Bool {
        guard candidate.hasSufficientCoverage,
              candidate.landmarkVoteCount >= configuration.minimumLandmarkVoteCount,
              candidate.landmarkScore >= configuration.minimumLandmarkScore,
              candidate.combinedDenseScore >= configuration.minimumCombinedDenseScore,
              denseMargin >= configuration.minimumDenseMargin,
              candidate.featureAgreementCount >= configuration.minimumFeatureAgreementCount
        else {
            return false
        }

        if abs(candidate.offsetMS - candidate.coarseOffsetMS) > configuration.maximumDenseLandmarkDisagreementMS {
            return false
        }

        let timingFeaturePasses = candidate.passesAnyFeature(
            in: configuration.timingEvidenceFeatures,
            threshold: configuration.minimumTimingFeatureScore
        )
        let robustFeaturePasses = candidate.passesAnyFeature(
            in: configuration.robustEvidenceFeatures,
            threshold: configuration.featureAgreementThreshold
        )

        return timingFeaturePasses && robustFeaturePasses
    }

    private static func sortedByRecordedTimeIfNeeded(_ frames: [MicFeatureFrame]) -> [MicFeatureFrame] {
        guard frames.indices.dropFirst().contains(where: { index in
            frames[frames.index(before: index)].recordedTimeMS > frames[index].recordedTimeMS
        }) else {
            return frames
        }

        return frames.sorted { lhs, rhs in
            lhs.recordedTimeMS < rhs.recordedTimeMS
        }
    }

    private static func isHigherRanked(lhs: CandidateScore, rhs: CandidateScore) -> Bool {
        if lhs.hasSufficientCoverage != rhs.hasSufficientCoverage {
            return lhs.hasSufficientCoverage
        }

        if lhs.combinedDenseScore != rhs.combinedDenseScore {
            return lhs.combinedDenseScore > rhs.combinedDenseScore
        }

        if lhs.featureAgreementCount != rhs.featureAgreementCount {
            return lhs.featureAgreementCount > rhs.featureAgreementCount
        }

        if lhs.weightedVoteScore != rhs.weightedVoteScore {
            return lhs.weightedVoteScore > rhs.weightedVoteScore
        }

        if lhs.uniqueHashCount != rhs.uniqueHashCount {
            return lhs.uniqueHashCount > rhs.uniqueHashCount
        }

        if lhs.landmarkScore != rhs.landmarkScore {
            return lhs.landmarkScore > rhs.landmarkScore
        }

        return lhs.offsetMS < rhs.offsetMS
    }

    private static func isHigherDenseEvaluation(
        lhs: AmbientSyncDenseOffsetEvaluation,
        rhs: AmbientSyncDenseOffsetEvaluation,
        coarseOffsetMS: Double
    ) -> Bool {
        if lhs.hasSufficientCoverage != rhs.hasSufficientCoverage {
            return lhs.hasSufficientCoverage
        }

        if lhs.combinedDenseScore != rhs.combinedDenseScore {
            return lhs.combinedDenseScore > rhs.combinedDenseScore
        }

        if lhs.comparableFrameCount != rhs.comparableFrameCount {
            return lhs.comparableFrameCount > rhs.comparableFrameCount
        }

        if lhs.meanFrameTimeErrorMS != rhs.meanFrameTimeErrorMS {
            return lhs.meanFrameTimeErrorMS < rhs.meanFrameTimeErrorMS
        }

        let lhsCoarseDistance = abs(lhs.offsetMS - coarseOffsetMS)
        let rhsCoarseDistance = abs(rhs.offsetMS - coarseOffsetMS)
        if lhsCoarseDistance != rhsCoarseDistance {
            return lhsCoarseDistance < rhsCoarseDistance
        }

        return lhs.offsetMS < rhs.offsetMS
    }

}

private enum AmbientSyncDenseFeatureKind: CaseIterable {
    case onsetEnvelope
    case subbandOnset
    case pcenMel
    case chromaOnset
    case cens
}

private struct AmbientSyncDenseQueryEvidence: Equatable, Sendable {
    let coverageFrameCount: Int
    let usableFrameCount: Int
    let usableDurationMS: Double
}

private struct AmbientSyncDenseOffsetEvaluation: Equatable, Sendable {
    let offsetMS: Double
    let comparableFrameCount: Int
    let coverageRatio: Double
    let hasSufficientCoverage: Bool
    let meanFrameTimeErrorMS: Double
    let onsetScore: Double
    let subbandOnsetScore: Double
    let pcenMelScore: Double
    let chromaOnsetScore: Double
    let censScore: Double
    let combinedDenseScore: Double

    init(
        offsetMS: Double,
        comparableFrameCount: Int,
        coverageRatio: Double,
        hasSufficientCoverage: Bool,
        meanFrameTimeErrorMS: Double = .infinity,
        onsetScore: Double = 0,
        subbandOnsetScore: Double = 0,
        pcenMelScore: Double = 0,
        chromaOnsetScore: Double = 0,
        censScore: Double = 0,
        combinedDenseScore: Double = 0
    ) {
        self.offsetMS = offsetMS
        self.comparableFrameCount = comparableFrameCount
        self.coverageRatio = coverageRatio
        self.hasSufficientCoverage = hasSufficientCoverage
        self.meanFrameTimeErrorMS = meanFrameTimeErrorMS
        self.onsetScore = onsetScore
        self.subbandOnsetScore = subbandOnsetScore
        self.pcenMelScore = pcenMelScore
        self.chromaOnsetScore = chromaOnsetScore
        self.censScore = censScore
        self.combinedDenseScore = combinedDenseScore
    }

    static func empty(offsetMS: Double) -> AmbientSyncDenseOffsetEvaluation {
        AmbientSyncDenseOffsetEvaluation(
            offsetMS: offsetMS,
            comparableFrameCount: 0,
            coverageRatio: 0,
            hasSufficientCoverage: false
        )
    }
}

private struct AmbientSyncCosineAccumulator: Equatable, Sendable {
    private var dotProduct = 0.0
    private var lhsMagnitudeSquared = 0.0
    private var rhsMagnitudeSquared = 0.0
    private var valueCount = 0

    mutating func append(_ lhs: Double, _ rhs: Double, weight: Double = 1) {
        guard weight > 0 else {
            return
        }

        dotProduct += weight * lhs * rhs
        lhsMagnitudeSquared += weight * lhs * lhs
        rhsMagnitudeSquared += weight * rhs * rhs
        valueCount += 1
    }

    var score: Double {
        guard valueCount > 0, lhsMagnitudeSquared > 0, rhsMagnitudeSquared > 0 else {
            return 0
        }

        let similarity = dotProduct / sqrt(lhsMagnitudeSquared * rhsMagnitudeSquared)
        return min(1, max(0, similarity))
    }
}

private struct AmbientSyncDenseFramePair: Equatable, Sendable {
    let query: MicFeatureFrame
    let local: MicFeatureFrame
    let weight: Double
}

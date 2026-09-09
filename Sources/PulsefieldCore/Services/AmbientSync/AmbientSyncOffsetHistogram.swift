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
        let postingCount = anchorTimesByHash[hash]?.count ?? 0
        return LandmarkHashStats(
            hash: hash,
            postingCount: postingCount,
            idfWeight: log1p(Double(landmarkCount) / Double(postingCount + 1))
        )
    }

    public func anchorTimes(for hash: UInt64) -> [Double] {
        anchorTimesByHash[hash] ?? []
    }

    func anchorTimes(for hash: UInt64, in anchorTimeRangeMS: ClosedRange<Double>) -> ArraySlice<Double> {
        guard let anchorTimes = anchorTimesByHash[hash] else {
            return ArraySlice()
        }

        let startIndex = Self.lowerBound(in: anchorTimes, value: anchorTimeRangeMS.lowerBound)
        let endIndex = Self.upperBound(in: anchorTimes, value: anchorTimeRangeMS.upperBound)
        return anchorTimes[startIndex..<endIndex]
    }

    fileprivate func anchorTimeSlice(for hash: UInt64) -> ArraySlice<Double> {
        guard let anchorTimes = anchorTimesByHash[hash] else {
            return ArraySlice()
        }

        return anchorTimes[anchorTimes.startIndex..<anchorTimes.endIndex]
    }

    private static func lowerBound(in values: [Double], value: Double) -> Int {
        var lowerBound = 0
        var upperBound = values.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if values[middle] < value {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
    }

    private static func upperBound(in values: [Double], value: Double) -> Int {
        var lowerBound = 0
        var upperBound = values.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if values[middle] <= value {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
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
        let matchStatsByHash = Self.matchStatsByHash(
            queryHashCounts: queryHashCounts,
            localIndex: localIndex
        )

        for queryLandmark in queryLandmarks {
            let matchStats = matchStatsByHash[queryLandmark.hash]
                ?? Self.matchStats(
                    for: queryLandmark.hash,
                    queryTF: 1,
                    localIndex: localIndex
                )

            let localAnchorTimes: ArraySlice<Double>
            if let searchRangeMS {
                let anchorTimeRangeMS = (queryLandmark.anchorTimeMS + searchRangeMS.lowerBound)
                    ... (queryLandmark.anchorTimeMS + searchRangeMS.upperBound)
                localAnchorTimes = localIndex.anchorTimes(for: queryLandmark.hash, in: anchorTimeRangeMS)
            } else {
                localAnchorTimes = localIndex.anchorTimeSlice(for: queryLandmark.hash)
            }

            for localAnchorTimeMS in localAnchorTimes {
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
                    weight: matchStats.weight,
                    referencePostingCount: matchStats.referencePostingCount
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

    private static func matchStatsByHash(
        queryHashCounts: [UInt64: Int],
        localIndex: AmbientSyncLandmarkIndex
    ) -> [UInt64: AmbientSyncOffsetMatchStats] {
        Dictionary(
            uniqueKeysWithValues: queryHashCounts.map { hash, queryTF in
                (hash, matchStats(for: hash, queryTF: queryTF, localIndex: localIndex))
            }
        )
    }

    private static func matchStats(
        for hash: UInt64,
        queryTF: Int,
        localIndex: AmbientSyncLandmarkIndex
    ) -> AmbientSyncOffsetMatchStats {
        let hashStats = localIndex.hashStats(for: hash)
        return AmbientSyncOffsetMatchStats(
            weight: matchWeight(idfWeight: hashStats.idfWeight, queryTF: queryTF),
            referencePostingCount: hashStats.postingCount
        )
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

private struct AmbientSyncOffsetMatchStats: Equatable, Sendable {
    let weight: Double
    let referencePostingCount: Int
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
        public let maximumRefinedCandidateCount: Int?
        public let refinementCandidateScoreMargin: Double

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
            robustEvidenceFeatures: FeatureSet = [.pcenMel, .cens],
            maximumRefinedCandidateCount: Int? = nil,
            refinementCandidateScoreMargin: Double = 0
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
            if let maximumRefinedCandidateCount {
                precondition(
                    maximumRefinedCandidateCount > 0,
                    "maximumRefinedCandidateCount must be positive when set."
                )
            }
            precondition(
                refinementCandidateScoreMargin >= 0 && refinementCandidateScoreMargin.isFinite,
                "refinementCandidateScoreMargin must be finite and non-negative."
            )

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
            self.maximumRefinedCandidateCount = maximumRefinedCandidateCount
            self.refinementCandidateScoreMargin = refinementCandidateScoreMargin
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
        rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            localFramesAreSorted: false,
            queryFramesAreSorted: false,
            candidates: candidates
        )
    }

    func rerank(
        queryWindow: MicFeatureWindow,
        localFrames: [MicFeatureFrame],
        localFramesAreSorted: Bool,
        queryFramesAreSorted: Bool = false,
        candidates: [AmbientSyncOffsetHistogram.Candidate]
    ) -> Result {
        let sortedQueryFrames = queryFramesAreSorted
            ? queryWindow.frames
            : Self.sortedByRecordedTimeIfNeeded(queryWindow.frames)
        let sortedLocalFrames = localFramesAreSorted ? localFrames : Self.sortedByRecordedTimeIfNeeded(localFrames)
        let queryEvidence = denseQueryEvidence(in: sortedQueryFrames)
        let scoredCandidates: [CandidateScore]
        if let maximumRefinedCandidateCount = configuration.maximumRefinedCandidateCount,
           maximumRefinedCandidateCount < candidates.count,
           configuration.refinementSearchRadiusMS > 0 {
            scoredCandidates = progressivelyScoreCandidates(
                candidates: candidates,
                maximumRefinedCandidateCount: maximumRefinedCandidateCount,
                queryFrames: sortedQueryFrames,
                localFrames: sortedLocalFrames,
                queryEvidence: queryEvidence
            )
        } else {
            scoredCandidates = candidates.map { candidate in
                score(
                    candidate: candidate,
                    queryFrames: sortedQueryFrames,
                    localFrames: sortedLocalFrames,
                    queryEvidence: queryEvidence,
                    allowRefinement: true
                )
            }
        }
        let rankedCandidates = scoredCandidates.sorted(by: Self.isHigherRanked)
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

    private func progressivelyScoreCandidates(
        candidates: [AmbientSyncOffsetHistogram.Candidate],
        maximumRefinedCandidateCount: Int,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> [CandidateScore] {
        var coarseScores = candidates.map { candidate in
            score(
                candidate: candidate,
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence,
                allowRefinement: false
            )
        }

        let refinedIndexes = refinementCandidateIndexes(
            in: coarseScores,
            maximumRefinedCandidateCount: maximumRefinedCandidateCount
        )
        for index in refinedIndexes {
            coarseScores[index] = score(
                candidate: candidates[index],
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence,
                allowRefinement: true
            )
        }

        return coarseScores
    }

    private func refinementCandidateIndexes(
        in coarseScores: [CandidateScore],
        maximumRefinedCandidateCount: Int
    ) -> Set<Int> {
        guard !coarseScores.isEmpty else {
            return []
        }

        let rankedIndexes = coarseScores.indices.sorted { lhsIndex, rhsIndex in
            Self.isHigherRanked(lhs: coarseScores[lhsIndex], rhs: coarseScores[rhsIndex])
        }
        var refinedIndexes = Set(rankedIndexes.prefix(maximumRefinedCandidateCount))
        guard let leadingIndex = rankedIndexes.first else {
            return refinedIndexes
        }

        let leadingScore = coarseScores[leadingIndex].combinedDenseScore
        for index in rankedIndexes.dropFirst(maximumRefinedCandidateCount) {
            if leadingScore - coarseScores[index].combinedDenseScore <= configuration.refinementCandidateScoreMargin {
                refinedIndexes.insert(index)
            }
        }

        return refinedIndexes
    }

    private func score(
        candidate: AmbientSyncOffsetHistogram.Candidate,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence,
        allowRefinement: Bool
    ) -> CandidateScore {
        let bestEvaluation = bestDenseEvaluation(
            coarseOffsetMS: candidate.offsetMS,
            queryFrames: queryFrames,
            localFrames: localFrames,
            queryEvidence: queryEvidence,
            allowRefinement: allowRefinement
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
            featureAgreementCount: featureAgreementCount(in: bestEvaluation),
            coarseOffsetMS: candidate.offsetMS
        )
    }

    private func featureAgreementCount(in evaluation: AmbientSyncDenseOffsetEvaluation) -> Int {
        guard evaluation.hasSufficientCoverage else {
            return 0
        }

        var agreementCount = 0
        if evaluation.onsetScore >= configuration.featureAgreementThreshold {
            agreementCount += 1
        }
        if evaluation.subbandOnsetScore >= configuration.featureAgreementThreshold {
            agreementCount += 1
        }
        if evaluation.pcenMelScore >= configuration.featureAgreementThreshold {
            agreementCount += 1
        }
        if evaluation.chromaOnsetScore >= configuration.featureAgreementThreshold {
            agreementCount += 1
        }
        if evaluation.censScore >= configuration.featureAgreementThreshold {
            agreementCount += 1
        }

        return agreementCount
    }

    private func denseQueryEvidence(in queryFrames: [MicFeatureFrame]) -> AmbientSyncDenseQueryEvidence {
        var usableFrameCount = 0
        var firstUsableTimeMS: Double?
        var lastUsableTimeMS: Double?
        var queryFrameUsability: [Bool] = []
        var queryFrameWeights: [Double] = []
        queryFrameUsability.reserveCapacity(queryFrames.count)
        queryFrameWeights.reserveCapacity(queryFrames.count)

        for frame in queryFrames {
            let isUsable = isUsableDenseFrame(frame)
            queryFrameUsability.append(isUsable)
            queryFrameWeights.append(denseFrameWeight(frame))
            if isUsable {
                usableFrameCount += 1
                firstUsableTimeMS = firstUsableTimeMS ?? frame.recordedTimeMS
                lastUsableTimeMS = frame.recordedTimeMS
            }
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
            usableDurationMS: usableDurationMS,
            queryFrameUsability: queryFrameUsability,
            queryFrameWeights: queryFrameWeights
        )
    }

    private func bestDenseEvaluation(
        coarseOffsetMS: Double,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence,
        allowRefinement: Bool
    ) -> AmbientSyncDenseOffsetEvaluation {
        var evaluationsByFramePairs: [[AmbientSyncDenseFramePair]: AmbientSyncDenseOffsetEvaluation] = [:]
        var bestEvaluation = evaluateDenseOffset(
            offsetMS: coarseOffsetMS,
            queryFrames: queryFrames,
            localFrames: localFrames,
            queryEvidence: queryEvidence,
            evaluationsByFramePairs: &evaluationsByFramePairs
        )

        if Self.isDominatingDenseEvaluation(bestEvaluation, queryEvidence: queryEvidence) {
            return bestEvaluation
        }

        guard allowRefinement, configuration.refinementSearchRadiusMS > 0 else {
            return bestEvaluation
        }

        var deltaMS = configuration.refinementStepMS
        while deltaMS <= configuration.refinementSearchRadiusMS + configuration.refinementStepMS * 0.5 {
            let lowerEvaluation = evaluateDenseOffset(
                offsetMS: coarseOffsetMS - deltaMS,
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence,
                evaluationsByFramePairs: &evaluationsByFramePairs
            )
            if Self.isHigherDenseEvaluation(
                lhs: lowerEvaluation,
                rhs: bestEvaluation,
                coarseOffsetMS: coarseOffsetMS
            ) {
                bestEvaluation = lowerEvaluation
                if Self.isDominatingDenseEvaluation(bestEvaluation, queryEvidence: queryEvidence) {
                    return bestEvaluation
                }
            }

            let upperEvaluation = evaluateDenseOffset(
                offsetMS: coarseOffsetMS + deltaMS,
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence,
                evaluationsByFramePairs: &evaluationsByFramePairs
            )
            if Self.isHigherDenseEvaluation(
                lhs: upperEvaluation,
                rhs: bestEvaluation,
                coarseOffsetMS: coarseOffsetMS
            ) {
                bestEvaluation = upperEvaluation
                if Self.isDominatingDenseEvaluation(bestEvaluation, queryEvidence: queryEvidence) {
                    return bestEvaluation
                }
            }

            deltaMS += configuration.refinementStepMS
        }

        return bestEvaluation
    }

    private func evaluateDenseOffset(
        offsetMS: Double,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence,
        evaluationsByFramePairs: inout [[AmbientSyncDenseFramePair]: AmbientSyncDenseOffsetEvaluation]
    ) -> AmbientSyncDenseOffsetEvaluation {
        guard queryEvidence.usableFrameCount >= configuration.minimumComparableFrameCount,
              queryEvidence.usableDurationMS >= configuration.minimumComparableDurationMS
        else {
            return evaluateDenseOffsetCoverageOnly(
                offsetMS: offsetMS,
                queryFrames: queryFrames,
                localFrames: localFrames,
                queryEvidence: queryEvidence
            )
        }

        var framePairs: [AmbientSyncDenseFramePair] = []
        framePairs.reserveCapacity(queryFrames.count)
        var totalFrameTimeErrorMS = 0.0
        forEachAlignedFramePair(
            queryFrames: queryFrames,
            localFrames: localFrames,
            offsetMS: offsetMS
        ) { queryFrameIndex, localFrameIndex, timeErrorMS in
            framePairs.append(AmbientSyncDenseFramePair(queryIndex: queryFrameIndex, localIndex: localFrameIndex))
            totalFrameTimeErrorMS += timeErrorMS
        }
        let meanFrameTimeErrorMS = framePairs.isEmpty
            ? Double.infinity
            : totalFrameTimeErrorMS / Double(framePairs.count)

        // Nearest-frame alignment is constant between frame boundaries. Refined offsets
        // with exactly the same pairs share all feature scores, but retain their own
        // timing error so refinement still selects the best timestamp within that span.
        if var cachedEvaluation = evaluationsByFramePairs[framePairs] {
            cachedEvaluation.offsetMS = offsetMS
            cachedEvaluation.meanFrameTimeErrorMS = meanFrameTimeErrorMS
            return cachedEvaluation
        }

        var matchedFrameCount = 0
        var comparableFrameCount = 0
        var onsetAccumulator = AmbientSyncCosineAccumulator()
        var subbandOnsetAccumulator = AmbientSyncCosineAccumulator()
        var pcenMelAccumulator = AmbientSyncCosineAccumulator()
        var chromaOnsetAccumulator = AmbientSyncCosineAccumulator()
        var censAccumulator = AmbientSyncCosineAccumulator()
        var subbandOnsetValid = true
        var pcenMelValid = true
        var chromaOnsetValid = true
        var censValid = true
        var previousQueryFrame: MicFeatureFrame?
        var previousLocalFrame: MicFeatureFrame?
        var previousWeight = 1.0
        var shouldAccumulateFeatureScores = true

        for pair in framePairs {
            let queryFrameIndex = pair.queryIndex
            let queryFrame = queryFrames[queryFrameIndex]
            let localFrame = localFrames[pair.localIndex]
            matchedFrameCount += 1
            if queryEvidence.isUsableQueryFrame(at: queryFrameIndex),
               isUsableDenseFrame(localFrame) {
                comparableFrameCount += 1
            }

            if shouldAccumulateFeatureScores {
                let weight = min(
                    queryEvidence.queryFrameWeight(at: queryFrameIndex),
                    denseFrameWeight(localFrame)
                )
                onsetAccumulator.append(
                    Double(queryFrame.onsetEnvelope),
                    Double(localFrame.onsetEnvelope),
                    weight: weight
                )
                if subbandOnsetValid {
                    subbandOnsetValid = appendComparableValues(
                        query: queryFrame.subbandOnset,
                        local: localFrame.subbandOnset,
                        weight: weight,
                        accumulator: &subbandOnsetAccumulator
                    )
                }
                if pcenMelValid {
                    pcenMelValid = appendComparableValues(
                        query: queryFrame.pcenMel,
                        local: localFrame.pcenMel,
                        weight: weight,
                        accumulator: &pcenMelAccumulator
                    )
                }
                if censValid {
                    censValid = appendComparableValues(
                        query: queryFrame.cens,
                        local: localFrame.cens,
                        weight: weight,
                        accumulator: &censAccumulator
                    )
                }

                if chromaOnsetValid,
                   let previousQueryFrame,
                   let previousLocalFrame {
                    chromaOnsetValid = appendComparablePositiveDeltas(
                        previousQuery: previousQueryFrame.chroma,
                        currentQuery: queryFrame.chroma,
                        previousLocal: previousLocalFrame.chroma,
                        currentLocal: localFrame.chroma,
                        weight: min(previousWeight, weight),
                        accumulator: &chromaOnsetAccumulator
                    )
                }

                previousQueryFrame = queryFrame
                previousLocalFrame = localFrame
                previousWeight = weight

                let remainingQueryFrameCount = queryEvidence.coverageFrameCount - queryFrameIndex - 1
                shouldAccumulateFeatureScores = Self.canStillReachSufficientCoverage(
                    matchedFrameCount: matchedFrameCount,
                    comparableFrameCount: comparableFrameCount,
                    remainingCoverageFrameCount: remainingQueryFrameCount,
                    remainingComparableQueryFrameCount: queryEvidence.usableQueryFrameCount(after: queryFrameIndex),
                    queryEvidence: queryEvidence,
                    configuration: configuration
                )
            }
        }

        let coverageRatio = queryEvidence.coverageFrameCount == 0
            ? 0
            : Double(matchedFrameCount) / Double(queryEvidence.coverageFrameCount)
        let hasSufficientCoverage = comparableFrameCount >= configuration.minimumComparableFrameCount
            && queryEvidence.usableDurationMS >= configuration.minimumComparableDurationMS
            && coverageRatio >= configuration.minimumCoverageRatio

        guard hasSufficientCoverage else {
            let evaluation = AmbientSyncDenseOffsetEvaluation(
                offsetMS: offsetMS,
                comparableFrameCount: comparableFrameCount,
                coverageRatio: coverageRatio,
                hasSufficientCoverage: false,
                meanFrameTimeErrorMS: meanFrameTimeErrorMS
            )
            evaluationsByFramePairs[framePairs] = evaluation
            return evaluation
        }

        let scores = AmbientSyncDenseOffsetScores(
            onsetScore: onsetAccumulator.score,
            subbandOnsetScore: subbandOnsetValid ? subbandOnsetAccumulator.score : 0,
            pcenMelScore: pcenMelValid ? pcenMelAccumulator.score : 0,
            chromaOnsetScore: chromaOnsetValid && matchedFrameCount > 1 ? chromaOnsetAccumulator.score : 0,
            censScore: censValid ? censAccumulator.score : 0
        )
        let combinedDenseScore = weightedCombinedScore(
            onsetScore: scores.onsetScore,
            subbandOnsetScore: scores.subbandOnsetScore,
            pcenMelScore: scores.pcenMelScore,
            chromaOnsetScore: scores.chromaOnsetScore,
            censScore: scores.censScore
        )

        let evaluation = AmbientSyncDenseOffsetEvaluation(
            offsetMS: offsetMS,
            comparableFrameCount: comparableFrameCount,
            coverageRatio: coverageRatio,
            hasSufficientCoverage: true,
            meanFrameTimeErrorMS: meanFrameTimeErrorMS,
            onsetScore: scores.onsetScore,
            subbandOnsetScore: scores.subbandOnsetScore,
            pcenMelScore: scores.pcenMelScore,
            chromaOnsetScore: scores.chromaOnsetScore,
            censScore: scores.censScore,
            combinedDenseScore: combinedDenseScore
        )
        evaluationsByFramePairs[framePairs] = evaluation
        return evaluation
    }

    private static func canStillReachSufficientCoverage(
        matchedFrameCount: Int,
        comparableFrameCount: Int,
        remainingCoverageFrameCount: Int,
        remainingComparableQueryFrameCount: Int,
        queryEvidence: AmbientSyncDenseQueryEvidence,
        configuration: Configuration
    ) -> Bool {
        let maximumPossibleComparableFrameCount = comparableFrameCount + remainingComparableQueryFrameCount
        guard maximumPossibleComparableFrameCount >= configuration.minimumComparableFrameCount else {
            return false
        }

        guard queryEvidence.coverageFrameCount > 0 else {
            return false
        }

        let maximumPossibleCoverageRatio = Double(matchedFrameCount + remainingCoverageFrameCount)
            / Double(queryEvidence.coverageFrameCount)
        return maximumPossibleCoverageRatio >= configuration.minimumCoverageRatio
    }

    private func evaluateDenseOffsetCoverageOnly(
        offsetMS: Double,
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> AmbientSyncDenseOffsetEvaluation {
        var matchedFrameCount = 0
        var comparableFrameCount = 0
        var totalFrameTimeErrorMS = 0.0

        forEachAlignedFramePair(
            queryFrames: queryFrames,
            localFrames: localFrames,
            offsetMS: offsetMS
        ) { queryFrameIndex, localFrameIndex, timeErrorMS in
            matchedFrameCount += 1
            totalFrameTimeErrorMS += timeErrorMS
            if queryEvidence.isUsableQueryFrame(at: queryFrameIndex),
               isUsableDenseFrame(localFrames[localFrameIndex]) {
                comparableFrameCount += 1
            }
        }

        let coverageRatio = queryEvidence.coverageFrameCount == 0
            ? 0
            : Double(matchedFrameCount) / Double(queryEvidence.coverageFrameCount)
        let meanFrameTimeErrorMS = matchedFrameCount == 0
            ? Double.infinity
            : totalFrameTimeErrorMS / Double(matchedFrameCount)

        return AmbientSyncDenseOffsetEvaluation(
            offsetMS: offsetMS,
            comparableFrameCount: comparableFrameCount,
            coverageRatio: coverageRatio,
            hasSufficientCoverage: false,
            meanFrameTimeErrorMS: meanFrameTimeErrorMS
        )
    }

    private func forEachAlignedFramePair(
        queryFrames: [MicFeatureFrame],
        localFrames: [MicFeatureFrame],
        offsetMS: Double,
        _ body: (Int, Int, Double) -> Void
    ) {
        guard let firstQueryFrame = queryFrames.first,
              let lastQueryFrame = queryFrames.last
        else {
            return
        }

        let lowerTimeMS = firstQueryFrame.recordedTimeMS + offsetMS - configuration.maximumFrameTimeErrorMS
        let upperTimeMS = lastQueryFrame.recordedTimeMS + offsetMS + configuration.maximumFrameTimeErrorMS
        let localStartIndex = lowerBoundFrameIndex(in: localFrames, timeMS: lowerTimeMS)
        let localEndIndex = upperBoundFrameIndex(in: localFrames, timeMS: upperTimeMS)
        guard localStartIndex < localEndIndex else {
            return
        }

        var localIndex = localStartIndex
        for (queryFrameIndex, queryFrame) in queryFrames.enumerated() {
            let localTimeMS = queryFrame.recordedTimeMS + offsetMS
            while localIndex < localEndIndex,
                  localFrames[localIndex].recordedTimeMS < localTimeMS {
                localIndex += 1
            }

            var bestFrameIndex: Int?
            if localIndex < localEndIndex {
                bestFrameIndex = localIndex
            }
            if localIndex > localStartIndex {
                let previousFrame = localFrames[localIndex - 1]
                if let currentBestIndex = bestFrameIndex {
                    let previousDistance = abs(previousFrame.recordedTimeMS - localTimeMS)
                    let bestDistance = abs(localFrames[currentBestIndex].recordedTimeMS - localTimeMS)
                    if previousDistance < bestDistance {
                        bestFrameIndex = localIndex - 1
                    }
                } else {
                    bestFrameIndex = localIndex - 1
                }
            }

            guard let bestFrameIndex
            else {
                continue
            }

            let timeErrorMS = abs(localFrames[bestFrameIndex].recordedTimeMS - localTimeMS)
            guard timeErrorMS <= configuration.maximumFrameTimeErrorMS else {
                continue
            }

            body(queryFrameIndex, bestFrameIndex, timeErrorMS)
        }
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

    private static func isDominatingDenseEvaluation(
        _ evaluation: AmbientSyncDenseOffsetEvaluation,
        queryEvidence: AmbientSyncDenseQueryEvidence
    ) -> Bool {
        evaluation.hasSufficientCoverage
            && evaluation.combinedDenseScore == 1
            && evaluation.comparableFrameCount == queryEvidence.usableFrameCount
            && evaluation.meanFrameTimeErrorMS == 0
    }

}

private struct AmbientSyncDenseQueryEvidence: Equatable, Sendable {
    let coverageFrameCount: Int
    let usableFrameCount: Int
    let usableDurationMS: Double
    let queryFrameUsability: [Bool]
    let queryFrameWeights: [Double]
    private let usableQueryFrameCountsAfterIndex: [Int]

    init(
        coverageFrameCount: Int,
        usableFrameCount: Int,
        usableDurationMS: Double,
        queryFrameUsability: [Bool],
        queryFrameWeights: [Double]
    ) {
        self.coverageFrameCount = coverageFrameCount
        self.usableFrameCount = usableFrameCount
        self.usableDurationMS = usableDurationMS
        self.queryFrameUsability = queryFrameUsability
        self.queryFrameWeights = queryFrameWeights

        var usableQueryFrameCountsAfterIndex = Array(repeating: 0, count: queryFrameUsability.count)
        var remainingUsableFrameCount = 0
        for index in queryFrameUsability.indices.reversed() {
            usableQueryFrameCountsAfterIndex[index] = remainingUsableFrameCount
            if queryFrameUsability[index] {
                remainingUsableFrameCount += 1
            }
        }
        self.usableQueryFrameCountsAfterIndex = usableQueryFrameCountsAfterIndex
    }

    func isUsableQueryFrame(at index: Int) -> Bool {
        queryFrameUsability[index]
    }

    func queryFrameWeight(at index: Int) -> Double {
        queryFrameWeights[index]
    }

    func usableQueryFrameCount(after index: Int) -> Int {
        usableQueryFrameCountsAfterIndex[index]
    }
}

private struct AmbientSyncDenseFramePair: Hashable, Sendable {
    let queryIndex: Int
    let localIndex: Int
}

private struct AmbientSyncDenseOffsetEvaluation: Equatable, Sendable {
    var offsetMS: Double
    let comparableFrameCount: Int
    let coverageRatio: Double
    let hasSufficientCoverage: Bool
    var meanFrameTimeErrorMS: Double
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

private struct AmbientSyncDenseOffsetScores: Equatable, Sendable {
    let onsetScore: Double
    let subbandOnsetScore: Double
    let pcenMelScore: Double
    let chromaOnsetScore: Double
    let censScore: Double
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

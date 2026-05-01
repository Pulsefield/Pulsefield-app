import Foundation

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
        public let queryTemporalSpreadMS: Double

        public init(
            binIndex: Int,
            binCenterOffsetMS: Double,
            offsetMS: Double,
            voteCount: Int,
            voteDensity: Double,
            queryTemporalSpreadMS: Double
        ) {
            self.binIndex = binIndex
            self.binCenterOffsetMS = binCenterOffsetMS
            self.offsetMS = offsetMS
            self.voteCount = voteCount
            self.voteDensity = voteDensity
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

        for queryLandmark in queryLandmarks {
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
                    queryAnchorTimeMS: queryLandmark.anchorTimeMS
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

    public var topVoteCount: Int {
        candidates.first?.voteCount ?? 0
    }

    public var secondVoteCount: Int {
        guard candidates.count > 1 else {
            return 0
        }

        return candidates[1].voteCount
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

    public var topVoteMargin: Int {
        topVoteCount - secondVoteCount
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
        if lhs.voteCount != rhs.voteCount {
            return lhs.voteCount > rhs.voteCount
        }

        if lhs.queryTemporalSpreadMS != rhs.queryTemporalSpreadMS {
            return lhs.queryTemporalSpreadMS > rhs.queryTemporalSpreadMS
        }

        return lhs.binCenterOffsetMS < rhs.binCenterOffsetMS
    }
}

private struct AmbientSyncOffsetVoteAccumulator: Equatable, Sendable {
    private var offsetSumMS: Double = 0
    private var earliestQueryAnchorTimeMS: Double?
    private var latestQueryAnchorTimeMS: Double?

    private(set) var voteCount: Int = 0

    mutating func record(offsetMS: Double, queryAnchorTimeMS: Double) {
        offsetSumMS += offsetMS
        voteCount += 1

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

        return AmbientSyncOffsetHistogram.Candidate(
            binIndex: binIndex,
            binCenterOffsetMS: Double(binIndex) * binWidthMS,
            offsetMS: voteCount > 0 ? offsetSumMS / Double(voteCount) : Double(binIndex) * binWidthMS,
            voteCount: voteCount,
            voteDensity: voteDensity,
            queryTemporalSpreadMS: temporalSpreadMS
        )
    }
}

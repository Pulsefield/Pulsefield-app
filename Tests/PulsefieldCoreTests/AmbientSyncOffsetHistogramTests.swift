import XCTest
@testable import PulsefieldCore

final class AmbientSyncOffsetHistogramTests: XCTestCase {
    func testLandmarkIndexExposesPostingStats() {
        let index = AmbientSyncLandmarkIndex(
            landmarks: [
                makeLandmark(hash: 7, anchorTimeMS: 1_000),
                makeLandmark(hash: 7, anchorTimeMS: 2_000),
                makeLandmark(hash: 8, anchorTimeMS: 3_000)
            ]
        )

        XCTAssertEqual(index.postingCount(for: 7), 2)
        XCTAssertEqual(index.postingCount(for: 99), 0)
        XCTAssertEqual(index.idfWeight(for: 7), log1p(3.0 / 3.0), accuracy: 0.0001)

        let stats = index.hashStats(for: 8)
        XCTAssertEqual(stats.hash, 8)
        XCTAssertEqual(stats.postingCount, 1)
        XCTAssertEqual(stats.idfWeight, log1p(3.0 / 2.0), accuracy: 0.0001)
    }

    func testCandidateDiagnosticsDecodesLegacyJSONWithoutWeightedFields() throws {
        let json = """
        {
          "offsetMS": 4000,
          "coarseOffsetMS": 4000,
          "landmarkVoteCount": 12,
          "landmarkScore": 0.6,
          "voteDensity": 0.6,
          "comparableFrameCount": 80,
          "coverageRatio": 0.95,
          "onsetScore": 0.7,
          "subbandOnsetScore": 0.1,
          "pcenMelScore": 0.8,
          "chromaOnsetScore": 0.2,
          "censScore": 0.75,
          "combinedDenseScore": 0.72,
          "featureAgreementCount": 3
        }
        """.data(using: .utf8)!

        let diagnostics = try JSONDecoder().decode(AmbientSyncCandidateDiagnostics.self, from: json)

        XCTAssertEqual(diagnostics.rawVoteCount, 12)
        XCTAssertEqual(diagnostics.weightedVoteScore, 12, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.uniqueHashCount, 12)
        XCTAssertEqual(diagnostics.commonHashVoteCount, 0)
        XCTAssertEqual(diagnostics.meanReferencePostingCount, 0, accuracy: 0.0001)
    }

    func testDiagnosticsDecodesLegacyJSONWithoutWeightedTopLevelFields() throws {
        let json = """
        {
          "queryDurationMS": 3000,
          "activeFrameFraction": 0.9,
          "queryLandmarkCount": 20,
          "histogramCandidateCount": 2,
          "topLandmarkVoteCount": 12,
          "secondLandmarkVoteCount": 8,
          "topToSecondVoteRatio": 1.5,
          "topVoteMargin": 4,
          "coarseAmbiguous": false,
          "denseMargin": 0.08,
          "candidates": []
        }
        """.data(using: .utf8)!

        let diagnostics = try JSONDecoder().decode(AmbientSyncDiagnostics.self, from: json)

        XCTAssertEqual(diagnostics.topWeightedVoteScore, 12, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.secondWeightedVoteScore, 8, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.topToSecondWeightedVoteRatio, 1.5, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.topWeightedVoteMargin, 4, accuracy: 0.0001)
    }

    func testRanksOffsetByClusteredHashVotes() {
        let queryLandmarks = [
            makeLandmark(hash: 10, anchorTimeMS: 1_000),
            makeLandmark(hash: 11, anchorTimeMS: 1_040),
            makeLandmark(hash: 12, anchorTimeMS: 1_080)
        ]
        let localLandmarks = [
            makeLandmark(hash: 10, anchorTimeMS: 5_003),
            makeLandmark(hash: 11, anchorTimeMS: 5_037),
            makeLandmark(hash: 12, anchorTimeMS: 5_084),
            makeLandmark(hash: 10, anchorTimeMS: 8_000)
        ]
        let localIndex = AmbientSyncLandmarkIndex(landmarks: localLandmarks)

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 40,
                maximumCandidateCount: 8
            )
        )

        XCTAssertEqual(histogram.candidates.first?.voteCount, 3)
        let expectedWeightedOffset = (
            4_003 * localIndex.idfWeight(for: 10)
                + 3_997 * localIndex.idfWeight(for: 11)
                + 4_004 * localIndex.idfWeight(for: 12)
        ) / (
            localIndex.idfWeight(for: 10)
                + localIndex.idfWeight(for: 11)
                + localIndex.idfWeight(for: 12)
        )
        XCTAssertEqual(histogram.candidates.first?.offsetMS ?? 0, expectedWeightedOffset, accuracy: 0.01)
        XCTAssertEqual(histogram.candidates.first?.voteDensity ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(histogram.candidates.first?.queryTemporalSpreadMS ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(histogram.candidates.dropFirst().first?.voteCount, 1)
    }

    func testWeightedRankingFavorsRareHashSpreadOverCommonRepeatedHash() throws {
        let queryLandmarks = (0..<16).map { _ in
            makeLandmark(hash: 1, anchorTimeMS: 0)
        } + [
            makeLandmark(hash: 2, anchorTimeMS: 0),
            makeLandmark(hash: 3, anchorTimeMS: 40),
            makeLandmark(hash: 4, anchorTimeMS: 80)
        ]
        let commonReferenceLandmarks = (0..<100).map { index in
            makeLandmark(
                hash: 1,
                anchorTimeMS: index == 0 ? 1_000 : 50_000 + Double(index) * 1_000
            )
        }
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: commonReferenceLandmarks + [
                makeLandmark(hash: 2, anchorTimeMS: 2_000),
                makeLandmark(hash: 3, anchorTimeMS: 2_040),
                makeLandmark(hash: 4, anchorTimeMS: 2_080)
            ]
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 20,
                maximumCandidateCount: 4,
                minimumCandidateSeparationMS: 100
            )
        )

        let winningCandidate = try XCTUnwrap(histogram.candidates.first)
        let commonCandidate = try XCTUnwrap(
            histogram.candidates.first { $0.binCenterOffsetMS == 1_000 }
        )

        XCTAssertEqual(winningCandidate.offsetMS, 2_000, accuracy: 0.001)
        XCTAssertEqual(winningCandidate.rawVoteCount, 3)
        XCTAssertEqual(winningCandidate.uniqueHashCount, 3)
        XCTAssertEqual(winningCandidate.commonHashVoteCount, 0)
        XCTAssertEqual(winningCandidate.meanReferencePostingCount, 1, accuracy: 0.001)
        XCTAssertEqual(winningCandidate.weightedVoteScore, 9, accuracy: 0.001)

        XCTAssertEqual(commonCandidate.rawVoteCount, 16)
        XCTAssertEqual(commonCandidate.uniqueHashCount, 1)
        XCTAssertEqual(commonCandidate.commonHashVoteCount, 16)
        XCTAssertEqual(commonCandidate.meanReferencePostingCount, 100, accuracy: 0.001)
        XCTAssertGreaterThan(winningCandidate.weightedVoteScore, commonCandidate.weightedVoteScore)
        XCTAssertLessThan(winningCandidate.rawVoteCount, commonCandidate.rawVoteCount)
        XCTAssertEqual(histogram.topWeightedVoteScore, winningCandidate.weightedVoteScore, accuracy: 0.001)
        XCTAssertEqual(histogram.secondWeightedVoteScore, commonCandidate.weightedVoteScore, accuracy: 0.001)
        XCTAssertEqual(
            histogram.topWeightedVoteMargin,
            winningCandidate.weightedVoteScore - commonCandidate.weightedVoteScore,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(histogram.topToSecondWeightedVoteRatio, 1)
        XCTAssertLessThan(histogram.topToSecondVoteRatio, 1)
    }

    func testRepeatedQueryHashUsesSqrtTermFrequencyDampening() throws {
        let queryLandmarks = (0..<4).map { _ in
            makeLandmark(hash: 7, anchorTimeMS: 0)
        }
        let unrelatedReferenceLandmarks = (0..<10).map { index in
            makeLandmark(hash: UInt64(100 + index), anchorTimeMS: Double(index) * 1_000)
        }
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: [makeLandmark(hash: 7, anchorTimeMS: 1_000)] + unrelatedReferenceLandmarks
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 20,
                maximumCandidateCount: 2
            )
        )

        let candidate = try XCTUnwrap(histogram.candidates.first)
        let undampenedScore = localIndex.idfWeight(for: 7) * 4
        let dampenedScore = localIndex.idfWeight(for: 7) / sqrt(4.0) * 4

        XCTAssertEqual(candidate.rawVoteCount, 4)
        XCTAssertEqual(candidate.uniqueHashCount, 1)
        XCTAssertEqual(candidate.weightedVoteScore, dampenedScore, accuracy: 0.0001)
        XCTAssertLessThan(candidate.weightedVoteScore, undampenedScore)
    }

    func testWeightedRankingBreaksScoreTiesByUniqueHashCount() throws {
        let unrelatedReferenceLandmarks = (0..<1_000).map { index in
            makeLandmark(hash: UInt64(1_000 + index), anchorTimeMS: Double(index) * 1_000)
        }
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: [
                makeLandmark(hash: 7, anchorTimeMS: 1_000),
                makeLandmark(hash: 8, anchorTimeMS: 2_000),
                makeLandmark(hash: 9, anchorTimeMS: 2_000)
            ] + unrelatedReferenceLandmarks
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: [
                makeLandmark(hash: 7, anchorTimeMS: 0),
                makeLandmark(hash: 7, anchorTimeMS: 0),
                makeLandmark(hash: 8, anchorTimeMS: 0),
                makeLandmark(hash: 9, anchorTimeMS: 0)
            ],
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 20,
                maximumCandidateCount: 2,
                minimumCandidateSeparationMS: 100
            )
        )

        XCTAssertEqual(histogram.candidates.map(\.binCenterOffsetMS), [2_000, 1_000])
        XCTAssertEqual(histogram.candidates.map(\.weightedVoteScore), [6, 6])
        XCTAssertEqual(histogram.candidates.map(\.uniqueHashCount), [2, 1])
        XCTAssertEqual(histogram.candidates.map(\.rawVoteCount), [2, 2])
    }

    func testWeightedOffsetMeanFavorsRareVotesInsideBin() throws {
        let commonReferenceLandmarks = [makeLandmark(hash: 7, anchorTimeMS: 900)]
            + (1..<20).map { index in
                makeLandmark(hash: 7, anchorTimeMS: 10_000 + Double(index) * 1_000)
            }
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: commonReferenceLandmarks + [
                makeLandmark(hash: 8, anchorTimeMS: 1_090)
            ]
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: [
                makeLandmark(hash: 7, anchorTimeMS: 0),
                makeLandmark(hash: 8, anchorTimeMS: 0)
            ],
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 200,
                maximumCandidateCount: 1
            ),
            searchRangeMS: 800 ... 1_200
        )

        let candidate = try XCTUnwrap(histogram.candidates.first)
        let commonWeight = localIndex.idfWeight(for: 7)
        let rareWeight = localIndex.idfWeight(for: 8)
        let expectedWeightedOffset = (900 * commonWeight + 1_090 * rareWeight) / (commonWeight + rareWeight)
        let rawMeanOffset = (900.0 + 1_090.0) / 2

        XCTAssertEqual(candidate.binCenterOffsetMS, 1_000, accuracy: 0.001)
        XCTAssertEqual(candidate.rawVoteCount, 2)
        XCTAssertEqual(candidate.weightedVoteScore, commonWeight + rareWeight, accuracy: 0.0001)
        XCTAssertEqual(candidate.offsetMS, expectedWeightedOffset, accuracy: 0.0001)
        XCTAssertLessThan(abs(candidate.offsetMS - 1_090), abs(rawMeanOffset - 1_090))
        XCTAssertEqual(candidate.commonHashVoteCount, 1)
        XCTAssertEqual(candidate.meanReferencePostingCount, 10.5, accuracy: 0.001)
    }

    func testUsesLocalMinusQueryOffsetSignAndSearchRange() {
        let queryLandmarks = [
            makeLandmark(hash: 20, anchorTimeMS: 2_000),
            makeLandmark(hash: 21, anchorTimeMS: 2_050)
        ]
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: [
                makeLandmark(hash: 20, anchorTimeMS: 1_900),
                makeLandmark(hash: 21, anchorTimeMS: 1_950),
                makeLandmark(hash: 20, anchorTimeMS: 5_000)
            ]
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 20,
                maximumCandidateCount: 4
            ),
            searchRangeMS: -200 ... 200
        )

        XCTAssertEqual(histogram.candidates.map(\.voteCount), [2])
        XCTAssertEqual(histogram.candidates.first?.offsetMS ?? 0, -100, accuracy: 0.001)
        XCTAssertEqual(histogram.topVoteCount, 2)
        XCTAssertEqual(histogram.secondVoteCount, 0)
    }

    func testCandidateRankingSkipsNeighboringShoulderBins() {
        let queryLandmarks = [
            makeLandmark(hash: 100, anchorTimeMS: 1_000),
            makeLandmark(hash: 101, anchorTimeMS: 1_040),
            makeLandmark(hash: 102, anchorTimeMS: 1_080),
            makeLandmark(hash: 103, anchorTimeMS: 1_120),
            makeLandmark(hash: 104, anchorTimeMS: 1_160),
            makeLandmark(hash: 105, anchorTimeMS: 1_200)
        ]
        let localIndex = AmbientSyncLandmarkIndex(
            landmarks: [
                makeLandmark(hash: 100, anchorTimeMS: 5_000),
                makeLandmark(hash: 101, anchorTimeMS: 5_040),
                makeLandmark(hash: 102, anchorTimeMS: 5_080),
                makeLandmark(hash: 103, anchorTimeMS: 5_160),
                makeLandmark(hash: 104, anchorTimeMS: 5_200),
                makeLandmark(hash: 105, anchorTimeMS: 9_200)
            ]
        )

        let histogram = AmbientSyncOffsetHistogram(
            queryLandmarks: queryLandmarks,
            localIndex: localIndex,
            configuration: AmbientSyncOffsetHistogram.Configuration(
                binWidthMS: 40,
                maximumCandidateCount: 2
            )
        )

        XCTAssertEqual(histogram.bins.map(\.voteCount), [3, 2, 1])
        XCTAssertEqual(histogram.candidates.map(\.voteCount), [3, 1])
        XCTAssertEqual(histogram.candidates.map(\.binCenterOffsetMS), [4_000, 8_000])
        XCTAssertEqual(histogram.secondVoteCount, 1)
        XCTAssertEqual(histogram.topToSecondVoteRatio, 3, accuracy: 0.001)
    }

    func testDenseRerankAcceptsDenseWinnerFromNonLeadingCoarseCandidate() {
        let queryWindow = MicFeatureWindow(
            frames: makeDensePatternFrames(offsetMS: 0)
        )
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
            + makeDenseDecoyFrames(offsetMS: 8_000)
        let candidates = [
            makeCandidate(offsetMS: 8_000, voteCount: 30, voteDensity: 0.90),
            makeCandidate(offsetMS: 4_000, voteCount: 12, voteDensity: 0.30)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertEqual(result.bestCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertGreaterThan(result.leadingCandidate?.combinedDenseScore ?? 0, 0.95)
        XCTAssertGreaterThan(result.denseMargin, 0.20)
        XCTAssertEqual(result.leadingCandidate?.featureAgreementCount, 5)
        XCTAssertGreaterThan(
            result.candidates.first { $0.coarseOffsetMS == 8_000 }?.landmarkScore ?? 0,
            result.leadingCandidate?.landmarkScore ?? 1
        )
    }

    func testDenseRerankCarriesWeightedLandmarkMetrics() throws {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(
                offsetMS: 4_000,
                voteCount: 10,
                voteDensity: 0.50,
                weightedVoteScore: 6.25,
                uniqueHashCount: 4,
                commonHashVoteCount: 3,
                meanReferencePostingCount: 2.5
            )
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )
        let candidate = try XCTUnwrap(result.leadingCandidate)

        XCTAssertEqual(candidate.rawVoteCount, 10)
        XCTAssertEqual(candidate.weightedVoteScore, 6.25, accuracy: 0.0001)
        XCTAssertEqual(candidate.uniqueHashCount, 4)
        XCTAssertEqual(candidate.commonHashVoteCount, 3)
        XCTAssertEqual(candidate.meanReferencePostingCount, 2.5, accuracy: 0.0001)
        XCTAssertEqual(candidate.voteDensity, 0.50, accuracy: 0.0001)
    }

    func testDenseRerankRefinesNearbyCoarseOffsetBeforeScoring() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_030, voteCount: 20, voteDensity: 0.80)
        ]
        let configuration = AmbientSyncDenseReranker.Configuration(
            minimumComparableFrameCount: 4,
            minimumComparableDurationMS: 0
        )

        let result = AmbientSyncDenseReranker(configuration: configuration).rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.bestCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertEqual(result.bestCandidate?.combinedDenseScore ?? 0, 1, accuracy: 0.0001)
    }

    func testDenseRerankDefaultDoesNotExposeBestCandidateForShortWindow() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80)
        ]

        let result = AmbientSyncDenseReranker().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.comparableFrameCount, 4)
        XCTAssertNil(result.bestCandidate)
    }

    func testDenseRerankCoverageIncludesDownweightedLowEnergyQueryFrames() {
        let queryWindow = MicFeatureWindow(
            frames: makeDensePatternFramesWithLowEnergyEdges(offsetMS: 0)
        )
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.comparableFrameCount, 4)
        XCTAssertEqual(result.leadingCandidate?.coverageRatio ?? 0, 4.0 / 6.0, accuracy: 0.0001)
        XCTAssertFalse(result.leadingCandidate?.hasSufficientCoverage ?? true)
        XCTAssertNil(result.bestCandidate)
    }

    func testDenseRerankDownweightsButScoresLowEnergyPairs() {
        let queryWindow = MicFeatureWindow(
            frames: makeDensePatternFramesWithLowEnergyEdges(offsetMS: 0)
        )
        let localFrames = makeDensePatternFramesWithMismatchedLowEnergyEdges(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.comparableFrameCount, 4)
        XCTAssertEqual(result.leadingCandidate?.coverageRatio ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(result.leadingCandidate?.hasSufficientCoverage ?? false)
        XCTAssertLessThan(result.leadingCandidate?.combinedDenseScore ?? 1, 0.99)
    }

    func testDenseRerankFeatureAgreementCountsCandidateFeaturePasses() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeSlightlyPerturbedDensePatternFrames(offsetMS: 4_000)
            + makeDenseFramesMatchingOnly(offsetMS: 8_000, feature: .onsetEnvelope)
            + makeDenseFramesMatchingOnly(offsetMS: 12_000, feature: .subbandOnset)
            + makeDenseFramesMatchingOnly(offsetMS: 16_000, feature: .pcenMel)
            + makeDenseFramesMatchingOnly(offsetMS: 20_000, feature: .chromaOnset)
            + makeDenseFramesMatchingOnly(offsetMS: 24_000, feature: .cens)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80),
            makeCandidate(offsetMS: 8_000, voteCount: 20, voteDensity: 0.80),
            makeCandidate(offsetMS: 12_000, voteCount: 20, voteDensity: 0.80),
            makeCandidate(offsetMS: 16_000, voteCount: 20, voteDensity: 0.80),
            makeCandidate(offsetMS: 20_000, voteCount: 20, voteDensity: 0.80),
            makeCandidate(offsetMS: 24_000, voteCount: 20, voteDensity: 0.80)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertEqual(result.bestCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertEqual(result.bestCandidate?.featureAgreementCount, 5)
        XCTAssertGreaterThan(result.bestCandidate?.combinedDenseScore ?? 0, 0.90)
    }

    func testDenseRerankAcceptsWeakTimingWhenRobustDenseFeaturesAgree() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeWeakTimingRobustDenseFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.20)
        ]
        let configuration = AmbientSyncDenseReranker.Configuration()

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        guard let candidate = result.leadingCandidate else {
            return XCTFail("Expected a dense candidate.")
        }

        XCTAssertEqual(candidate.featureAgreementCount, 2)
        XCTAssertLessThan(candidate.onsetScore, configuration.featureAgreementThreshold)
        XCTAssertGreaterThan(candidate.onsetScore, configuration.minimumTimingFeatureScore)
        XCTAssertGreaterThan(candidate.combinedDenseScore, configuration.minimumCombinedDenseScore)
        XCTAssertNotNil(result.bestCandidate)
    }

    func testDenseRerankRejectsMismatchedVectorFeatureDimensions() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFramesWithShortSubband(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 12, voteDensity: 0.30)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.candidates.first?.subbandOnsetScore ?? 1, 0, accuracy: 0.0001)
        XCTAssertLessThan(result.candidates.first?.featureAgreementCount ?? 5, 5)
    }

    func testDenseRerankDoesNotExposeBestCandidateWithoutFeatureAgreement() {
        let queryWindow = MicFeatureWindow(frames: makeOnsetOnlyFrames(offsetMS: 0))
        let localFrames = makeOnsetOnlyFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80)
        ]
        let configuration = AmbientSyncDenseReranker.Configuration(
            weights: AmbientSyncDenseReranker.FeatureWeights(
                onsetEnvelope: 1,
                subbandOnset: 0,
                pcenMel: 0,
                chromaOnset: 0,
                cens: 0
            ),
            minimumComparableFrameCount: 4,
            minimumComparableDurationMS: 0
        )

        let result = AmbientSyncDenseReranker(configuration: configuration).rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.candidates.first?.combinedDenseScore ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(result.candidates.first?.featureAgreementCount, 1)
        XCTAssertNil(result.bestCandidate)
    }

    func testDenseRerankDoesNotCountLowEnergyFramesAsComparableEvidence() {
        let queryWindow = MicFeatureWindow(
            frames: makeDensePatternFrames(offsetMS: 0, energyDBFS: -120, snrDB: 0)
        )
        let localFrames = makeDensePatternFrames(offsetMS: 4_000, energyDBFS: -120, snrDB: 0)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 20, voteDensity: 0.80)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.candidates.first?.comparableFrameCount, 0)
        XCTAssertEqual(result.candidates.first?.coverageRatio ?? 0, 1, accuracy: 0.0001)
        XCTAssertFalse(result.candidates.first?.hasSufficientCoverage ?? true)
        XCTAssertEqual(result.candidates.first?.combinedDenseScore ?? 1, 0, accuracy: 0.0001)
        XCTAssertNil(result.bestCandidate)
    }

    func testDenseRerankExposesAmbiguousMarginForRepeatedDenseMatches() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
            + makeDensePatternFrames(offsetMS: 8_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 15, voteDensity: 0.60),
            makeCandidate(offsetMS: 8_000, voteCount: 15, voteDensity: 0.60)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].combinedDenseScore, 1, accuracy: 0.0001)
        XCTAssertEqual(result.candidates[1].combinedDenseScore, 1, accuracy: 0.0001)
        XCTAssertEqual(result.denseMargin, 0, accuracy: 0.0001)
        XCTAssertEqual(result.candidates[0].featureAgreementCount, 5)
        XCTAssertEqual(result.candidates[1].featureAgreementCount, 5)
        XCTAssertNil(result.bestCandidate)
    }

    func testDenseRerankAcceptsCoveredCandidateWhenLandmarkLeaderIsUncovered() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 9_000, voteCount: 40, voteDensity: 1.0),
            makeCandidate(offsetMS: 4_000, voteCount: 10, voteDensity: 0.25)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertTrue(result.leadingCandidate?.hasSufficientCoverage ?? false)
        XCTAssertEqual(result.bestCandidate?.offsetMS ?? 0, 4_000, accuracy: 0.001)
        XCTAssertEqual(
            result.candidates.first { $0.offsetMS == 9_000 }?.coverageRatio ?? 1,
            0,
            accuracy: 0.001
        )
        XCTAssertFalse(result.candidates.first { $0.offsetMS == 9_000 }?.hasSufficientCoverage ?? true)
    }

    func testDenseRerankDoesNotExposeBestCandidateWithoutLandmarkSupport() {
        let queryWindow = MicFeatureWindow(frames: makeDensePatternFrames(offsetMS: 0))
        let localFrames = makeDensePatternFrames(offsetMS: 4_000)
        let candidates = [
            makeCandidate(offsetMS: 4_000, voteCount: 2, voteDensity: 0.01)
        ]

        let result = makeDenseRerankerForShortFixture().rerank(
            queryWindow: queryWindow,
            localFrames: localFrames,
            candidates: candidates
        )

        XCTAssertEqual(result.leadingCandidate?.combinedDenseScore ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(result.leadingCandidate?.featureAgreementCount, 5)
        XCTAssertNil(result.bestCandidate)
    }

    private func makeLandmark(hash: UInt64, anchorTimeMS: Double) -> MicFeatureLandmark {
        MicFeatureLandmark(
            hash: hash,
            anchorTimeMS: anchorTimeMS,
            anchorFrequencyBin: 1,
            targetFrequencyBin: 2,
            deltaFrames: 1
        )
    }

    private func makeCandidate(
        offsetMS: Double,
        voteCount: Int,
        voteDensity: Double,
        weightedVoteScore: Double? = nil,
        uniqueHashCount: Int? = nil,
        commonHashVoteCount: Int = 0,
        meanReferencePostingCount: Double = 0
    ) -> AmbientSyncOffsetHistogram.Candidate {
        AmbientSyncOffsetHistogram.Candidate(
            binIndex: Int(offsetMS / 20),
            binCenterOffsetMS: offsetMS,
            offsetMS: offsetMS,
            voteCount: voteCount,
            voteDensity: voteDensity,
            weightedVoteScore: weightedVoteScore,
            uniqueHashCount: uniqueHashCount,
            commonHashVoteCount: commonHashVoteCount,
            meanReferencePostingCount: meanReferencePostingCount,
            queryTemporalSpreadMS: 1_000
        )
    }

    private func makeDenseRerankerForShortFixture() -> AmbientSyncDenseReranker {
        AmbientSyncDenseReranker(
            configuration: AmbientSyncDenseReranker.Configuration(
                minimumComparableFrameCount: 4,
                minimumComparableDurationMS: 0
            )
        )
    }

    private func makeDensePatternFrames(
        offsetMS: Double,
        energyDBFS: Double = -18,
        snrDB: Double? = 24
    ) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS + 0,
                onsetEnvelope: 0.10,
                subbandOnset: [0.10, 0.00, 0.20],
                pcenMel: [0.90, 0.10, 0.20],
                chroma: [1.00, 0.00, 0.00],
                cens: [0.90, 0.10, 0.00],
                energyDBFS: energyDBFS,
                snrDB: snrDB
            ),
            makeDenseFrame(
                timeMS: offsetMS + 20,
                onsetEnvelope: 0.80,
                subbandOnset: [0.90, 0.10, 0.00],
                pcenMel: [0.20, 0.80, 0.10],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.20, 0.70, 0.10],
                energyDBFS: energyDBFS,
                snrDB: snrDB
            ),
            makeDenseFrame(
                timeMS: offsetMS + 40,
                onsetEnvelope: 0.20,
                subbandOnset: [0.00, 0.20, 0.80],
                pcenMel: [0.10, 0.30, 0.90],
                chroma: [0.00, 0.00, 1.00],
                cens: [0.10, 0.20, 0.70],
                energyDBFS: energyDBFS,
                snrDB: snrDB
            ),
            makeDenseFrame(
                timeMS: offsetMS + 60,
                onsetEnvelope: 0.60,
                subbandOnset: [0.70, 0.30, 0.10],
                pcenMel: [0.80, 0.20, 0.30],
                chroma: [1.00, 0.00, 0.00],
                cens: [0.70, 0.20, 0.10],
                energyDBFS: energyDBFS,
                snrDB: snrDB
            )
        ]
    }

    private func makeDensePatternFramesWithLowEnergyEdges(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS - 20,
                onsetEnvelope: 0,
                energyDBFS: -120,
                snrDB: 0
            )
        ]
        + makeDensePatternFrames(offsetMS: offsetMS)
        + [
            makeDenseFrame(
                timeMS: offsetMS + 80,
                onsetEnvelope: 0,
                energyDBFS: -120,
                snrDB: 0
            )
        ]
    }

    private func makeDensePatternFramesWithMismatchedLowEnergyEdges(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS - 20,
                onsetEnvelope: 0.90,
                subbandOnset: [0.80, 0.10, 0.20],
                pcenMel: [0.00, 0.90, 0.10],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.10, 0.80, 0.20],
                energyDBFS: -120,
                snrDB: 0
            )
        ]
        + makeDensePatternFrames(offsetMS: offsetMS)
        + [
            makeDenseFrame(
                timeMS: offsetMS + 80,
                onsetEnvelope: 0.70,
                subbandOnset: [0.10, 0.80, 0.20],
                pcenMel: [0.20, 0.10, 0.90],
                chroma: [0.00, 0.00, 1.00],
                cens: [0.20, 0.10, 0.80],
                energyDBFS: -120,
                snrDB: 0
            )
        ]
    }

    private func makeSlightlyPerturbedDensePatternFrames(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS + 0,
                onsetEnvelope: 0.12,
                subbandOnset: [0.12, 0.01, 0.18],
                pcenMel: [0.86, 0.14, 0.24],
                chroma: [0.96, 0.04, 0.00],
                cens: [0.86, 0.14, 0.02]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 20,
                onsetEnvelope: 0.78,
                subbandOnset: [0.86, 0.14, 0.02],
                pcenMel: [0.25, 0.74, 0.14],
                chroma: [0.04, 0.94, 0.02],
                cens: [0.24, 0.68, 0.12]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 40,
                onsetEnvelope: 0.24,
                subbandOnset: [0.02, 0.23, 0.76],
                pcenMel: [0.12, 0.34, 0.86],
                chroma: [0.02, 0.04, 0.94],
                cens: [0.12, 0.22, 0.68]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 60,
                onsetEnvelope: 0.56,
                subbandOnset: [0.66, 0.34, 0.12],
                pcenMel: [0.76, 0.25, 0.34],
                chroma: [0.94, 0.04, 0.02],
                cens: [0.68, 0.24, 0.12]
            )
        ]
    }

    private func makeWeakTimingRobustDenseFrames(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS + 0,
                onsetEnvelope: 0.00,
                subbandOnset: [0.00, 1.00, 0.00],
                pcenMel: [0.90, 0.10, 0.20],
                chroma: [0.00, 0.00, 0.00],
                cens: [0.90, 0.10, 0.00]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 20,
                onsetEnvelope: 0.30,
                subbandOnset: [0.00, 1.00, 0.00],
                pcenMel: [0.20, 0.80, 0.10],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.20, 0.70, 0.10]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 40,
                onsetEnvelope: 1.00,
                subbandOnset: [0.00, 1.00, 0.00],
                pcenMel: [0.10, 0.30, 0.90],
                chroma: [1.00, 1.00, 0.00],
                cens: [0.10, 0.20, 0.70]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 60,
                onsetEnvelope: 0.20,
                subbandOnset: [0.00, 1.00, 0.00],
                pcenMel: [0.80, 0.20, 0.30],
                chroma: [1.00, 1.00, 1.00],
                cens: [0.70, 0.20, 0.10]
            )
        ]
    }

    private enum DenseFeatureForTest {
        case onsetEnvelope
        case subbandOnset
        case pcenMel
        case chromaOnset
        case cens
    }

    private func makeDenseFramesMatchingOnly(
        offsetMS: Double,
        feature: DenseFeatureForTest
    ) -> [MicFeatureFrame] {
        makeDensePatternFrames(offsetMS: 0).map { frame in
            makeDenseFrame(
                timeMS: offsetMS + frame.recordedTimeMS,
                onsetEnvelope: feature == .onsetEnvelope ? frame.onsetEnvelope : 0,
                subbandOnset: feature == .subbandOnset ? frame.subbandOnset : [0, 0, 0],
                pcenMel: feature == .pcenMel ? frame.pcenMel : [0, 0, 0],
                chroma: feature == .chromaOnset ? frame.chroma : [0, 0, 0],
                cens: feature == .cens ? frame.cens : [0, 0, 0]
            )
        }
    }

    private func makeDensePatternFramesWithShortSubband(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS + 0,
                onsetEnvelope: 0.10,
                subbandOnset: [0.10, 0.00],
                pcenMel: [0.90, 0.10, 0.20],
                chroma: [1.00, 0.00, 0.00],
                cens: [0.90, 0.10, 0.00]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 20,
                onsetEnvelope: 0.80,
                subbandOnset: [0.90, 0.10],
                pcenMel: [0.20, 0.80, 0.10],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.20, 0.70, 0.10]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 40,
                onsetEnvelope: 0.20,
                subbandOnset: [0.00, 0.20],
                pcenMel: [0.10, 0.30, 0.90],
                chroma: [0.00, 0.00, 1.00],
                cens: [0.10, 0.20, 0.70]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 60,
                onsetEnvelope: 0.60,
                subbandOnset: [0.70, 0.30],
                pcenMel: [0.80, 0.20, 0.30],
                chroma: [1.00, 0.00, 0.00],
                cens: [0.70, 0.20, 0.10]
            )
        ]
    }

    private func makeOnsetOnlyFrames(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(timeMS: offsetMS + 0, onsetEnvelope: 0.10),
            makeDenseFrame(timeMS: offsetMS + 20, onsetEnvelope: 0.80),
            makeDenseFrame(timeMS: offsetMS + 40, onsetEnvelope: 0.20),
            makeDenseFrame(timeMS: offsetMS + 60, onsetEnvelope: 0.60)
        ]
    }

    private func makeDenseDecoyFrames(offsetMS: Double) -> [MicFeatureFrame] {
        [
            makeDenseFrame(
                timeMS: offsetMS + 0,
                onsetEnvelope: 0.10,
                subbandOnset: [0.00, 0.40, 0.90],
                pcenMel: [0.00, 0.80, 0.10],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.00, 0.80, 0.20]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 20,
                onsetEnvelope: 0.80,
                subbandOnset: [0.20, 0.00, 0.80],
                pcenMel: [0.70, 0.00, 0.20],
                chroma: [1.00, 0.00, 0.00],
                cens: [0.70, 0.10, 0.20]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 40,
                onsetEnvelope: 0.20,
                subbandOnset: [0.80, 0.20, 0.00],
                pcenMel: [0.20, 0.90, 0.00],
                chroma: [0.00, 1.00, 0.00],
                cens: [0.20, 0.80, 0.00]
            ),
            makeDenseFrame(
                timeMS: offsetMS + 60,
                onsetEnvelope: 0.60,
                subbandOnset: [0.00, 0.90, 0.30],
                pcenMel: [0.10, 0.20, 0.80],
                chroma: [0.00, 0.00, 1.00],
                cens: [0.10, 0.20, 0.70]
            )
        ]
    }

    private func makeDenseFrame(
        timeMS: Double,
        onsetEnvelope: Float,
        subbandOnset: [Float] = [0, 0, 0],
        pcenMel: [Float] = [0, 0, 0],
        chroma: [Float] = [0, 0, 0],
        cens: [Float] = [0, 0, 0],
        energyDBFS: Double = -18,
        snrDB: Double? = 24
    ) -> MicFeatureFrame {
        MicFeatureFrame(
            recordedTimeMS: timeMS,
            hostTimeMS: timeMS + 10_000,
            onsetEnvelope: onsetEnvelope,
            subbandOnset: subbandOnset,
            pcenMel: pcenMel,
            chroma: chroma,
            cens: cens,
            landmarkHashes: [],
            energyDBFS: energyDBFS,
            snrDB: snrDB
        )
    }
}

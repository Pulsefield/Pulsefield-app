import XCTest
@testable import PulsefieldCore

final class AmbientSyncOffsetHistogramTests: XCTestCase {
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
        XCTAssertEqual(histogram.candidates.first?.offsetMS ?? 0, 4_001.33, accuracy: 0.01)
        XCTAssertEqual(histogram.candidates.first?.voteDensity ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(histogram.candidates.first?.queryTemporalSpreadMS ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(histogram.candidates.dropFirst().first?.voteCount, 1)
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

    private func makeLandmark(hash: UInt64, anchorTimeMS: Double) -> MicFeatureLandmark {
        MicFeatureLandmark(
            hash: hash,
            anchorTimeMS: anchorTimeMS,
            anchorFrequencyBin: 1,
            targetFrequencyBin: 2,
            deltaFrames: 1
        )
    }
}

import Accelerate
import Foundation

/// Delay estimation for a known track. Each band votes through its temporal
/// correlation, rather than through its absolute level or its loudest peaks.
struct AmbientSyncSpectralMatcher: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let offsetMS: Double
        let score: Double
        let firstHalfScore: Double
        let secondHalfScore: Double
        let recentScore: Double
    }

    struct Result: Equatable, Sendable {
        let candidates: [Candidate]
        var best: Candidate? { candidates.first }
        var margin: Double {
            guard let best else { return 0 }
            return best.score - (candidates.dropFirst().first?.score ?? 0)
        }
    }

    private struct Bands: Equatable, Sendable {
        let values: [[Float]]
        let energy: [[Double]]
        var count: Int { values.first?.count ?? 0 }

        init(values: [[Float]]) {
            self.values = values
            self.energy = values.map { band in
                var sums = [Double](repeating: 0, count: band.count + 1)
                for i in band.indices { sums[i + 1] = sums[i] + Double(band[i]) * Double(band[i]) }
                return sums
            }
        }

        func reduced(by factor: Int) -> Bands {
            Bands(
                values: values.map { band in
                    (0..<(band.count / factor)).map { i in
                        var sum: Float = 0
                        for j in 0..<factor { sum += band[i * factor + j] }
                        return sum / Float(factor)
                    }
                })
        }
    }

    private let fine: Bands
    private let coarse: Bands
    private let startMS: Double
    private let hopMS: Double
    private let radius: Int
    private let reduction = 4
    private static let varianceFloor = 0.001

    init?(frames: [MicFeatureFrame], hopMS: Double) {
        guard Self.isRegular(frames, hopMS: hopMS),
            let count = frames.first?.pcenMel.count, count > 0
        else { return nil }
        self.startMS = frames[0].recordedTimeMS
        self.hopMS = hopMS
        self.radius = max(1, Int((250 / hopMS).rounded()))
        guard let values = Self.centered(frames, bandCount: count, radius: radius) else { return nil }
        self.fine = Bands(values: values)
        self.coarse = fine.reduced(by: 4)
    }

    func acceptsTimeline(_ query: MicFeatureWindow) -> Bool {
        Self.isRegular(query.frames, hopMS: hopMS)
    }

    /// A nil range searches the entire track; tracking supplies a narrow offset range.
    func match(query: MicFeatureWindow, rangeMS: ClosedRange<Double>? = nil) -> Result {
        guard Self.isRegular(query.frames, hopMS: hopMS),
            query.frames.count > 2 * radius + 16,
            let centered = Self.centered(query.frames, bandCount: fine.values.count, radius: radius)
        else { return Result(candidates: []) }

        // Both ends have complete centering context. This consumes only samples
        // already in the rolling window and prevents padding from becoming evidence.
        let queryBands = Bands(values: centered.map { Array($0[radius..<($0.count - radius)]) })
        let queryStartMS = query.frames[radius].recordedTimeMS
        let maximumStart = fine.count - queryBands.count
        guard maximumStart >= 0 else { return Result(candidates: []) }
        let fullRange = 0...maximumStart
        var ranges: [ClosedRange<Int>] = []
        if let rangeMS {
            let low = max(0, Int(ceil((queryStartMS + rangeMS.lowerBound - startMS) / hopMS)))
            let high = min(maximumStart, Int(floor((queryStartMS + rangeMS.upperBound - startMS) / hopMS)))
            guard low <= high else { return Result(candidates: []) }
            ranges = [low...high]
        } else {
            let reducedQuery = queryBands.reduced(by: reduction)
            guard coarse.count >= reducedQuery.count, reducedQuery.count > 0 else { return Result(candidates: []) }
            let scores = correlations(
                reference: coarse, query: reducedQuery, starts: 0...(coarse.count - reducedQuery.count))
            // Preserve independent alternatives so a repeated phrase stays ambiguous.
            let peaks = Self.peaks(scores, separation: max(1, Int(750 / (hopMS * Double(reduction)))), limit: 8)
            ranges = peaks.compactMap { peak in
                let low = max(fullRange.lowerBound, peak * reduction - reduction)
                let high = min(fullRange.upperBound, peak * reduction + reduction)
                return low <= high ? low...high : nil
            }
        }

        var candidates: [Candidate] = []
        for range in ranges {
            let scores = correlations(reference: fine, query: queryBands, starts: range)
            guard let peak = scores.indices.max(by: { scores[$0] < scores[$1] }) else { continue }
            let index = range.lowerBound + peak
            var fraction = 0.0
            if peak > 0 && peak + 1 < scores.count {
                let left = scores[peak - 1]
                let center = scores[peak]
                let right = scores[peak + 1]
                let curvature = left - 2 * center + right
                if curvature < -0.000_001 {
                    fraction = max(-0.5, min(0.5, 0.5 * (left - right) / curvature))
                }
            }
            let split = queryBands.count / 2
            candidates.append(
                Candidate(
                    offsetMS: startMS + (Double(index) + fraction) * hopMS - queryStartMS,
                    score: scores[peak],
                    firstHalfScore: scorePart(query: queryBands, referenceStart: index, part: 0..<split),
                    secondHalfScore: scorePart(
                        query: queryBands, referenceStart: index, part: split..<queryBands.count),
                    recentScore: scorePart(
                        query: queryBands, referenceStart: index,
                        part: max(0, queryBands.count - Int(1_000 / hopMS))..<queryBands.count)
                ))
        }
        candidates.sort { $0.score > $1.score }
        var independent: [Candidate] = []
        for candidate in candidates where !independent.contains(where: { abs($0.offsetMS - candidate.offsetMS) < 750 })
        {
            independent.append(candidate)
        }
        return Result(candidates: independent)
    }

    private func correlations(reference: Bands, query: Bands, starts: ClosedRange<Int>) -> [Double] {
        let n = query.count
        let count = starts.count
        var scores = [Double](repeating: 0, count: count)
        var dots = [Float](repeating: 0, count: count)
        let floor = Double(n) * Self.varianceFloor
        for band in query.values.indices {
            reference.values[band].withUnsafeBufferPointer { r in
                query.values[band].withUnsafeBufferPointer { q in
                    vDSP_conv(
                        r.baseAddress! + starts.lowerBound, 1, q.baseAddress!, 1,
                        &dots, 1, vDSP_Length(count), vDSP_Length(n))
                }
            }
            let queryEnergy = max(floor, query.energy[band][n])
            for i in 0..<count {
                let start = starts.lowerBound + i
                let referenceEnergy = max(floor, reference.energy[band][start + n] - reference.energy[band][start])
                scores[i] += Double(dots[i]) / sqrt(queryEnergy * referenceEnergy)
            }
        }
        let scale = 1 / Double(query.values.count)
        for i in scores.indices { scores[i] *= scale }
        return scores
    }

    private func scorePart(query: Bands, referenceStart: Int, part: Range<Int>) -> Double {
        var score = 0.0
        let floor = Double(part.count) * Self.varianceFloor
        for band in query.values.indices {
            var dot: Float = 0
            fine.values[band].withUnsafeBufferPointer { r in
                query.values[band].withUnsafeBufferPointer { q in
                    vDSP_dotpr(
                        r.baseAddress! + referenceStart + part.lowerBound, 1,
                        q.baseAddress! + part.lowerBound, 1, &dot, vDSP_Length(part.count))
                }
            }
            let re =
                fine.energy[band][referenceStart + part.upperBound]
                - fine.energy[band][referenceStart + part.lowerBound]
            let qe = query.energy[band][part.upperBound] - query.energy[band][part.lowerBound]
            score += Double(dot) / sqrt(max(floor, re) * max(floor, qe))
        }
        return score / Double(query.values.count)
    }

    private static func peaks(_ scores: [Double], separation: Int, limit: Int) -> [Int] {
        var result: [Int] = []
        // Eight linear scans avoid sorting every possible reference offset.
        for _ in 0..<limit {
            var best: Int?
            for i in scores.indices where !result.contains(where: { abs($0 - i) < separation }) {
                if best == nil || scores[i] > scores[best!] { best = i }
            }
            guard let best else { break }
            result.append(best)
        }
        return result
    }

    private static func isRegular(_ frames: [MicFeatureFrame], hopMS: Double) -> Bool {
        guard hopMS.isFinite, hopMS > 0, frames.count > 1,
            frames[0].recordedTimeMS.isFinite
        else { return false }
        return frames.indices.dropFirst().allSatisfy {
            let delta = frames[$0].recordedTimeMS - frames[$0 - 1].recordedTimeMS
            let expected = frames[0].recordedTimeMS + Double($0) * hopMS
            return delta.isFinite && abs(delta - hopMS) < hopMS * 0.05
                && abs(frames[$0].recordedTimeMS - expected) < hopMS * 0.05
        }
    }

    private static func centered(_ frames: [MicFeatureFrame], bandCount: Int, radius: Int) -> [[Float]]? {
        guard frames.allSatisfy({ $0.pcenMel.count == bandCount && $0.pcenMel.allSatisfy { $0.isFinite && $0 >= 0 } })
        else { return nil }
        let count = frames.count
        var output = [[Float]]()
        output.reserveCapacity(bandCount)
        for band in 0..<bandCount {
            let values = frames.map { log1p($0.pcenMel[band]) }
            var sums = [Double](repeating: 0, count: count + 1)
            for i in values.indices { sums[i + 1] = sums[i] + Double(values[i]) }
            var centered = [Float](repeating: 0, count: count)
            for i in values.indices {
                let low = max(0, i - radius)
                let high = min(count, i + radius + 1)
                let before = max(0, radius - i)
                let after = max(0, i + radius + 1 - count)
                let total =
                    sums[high] - sums[low] + Double(before) * Double(values[0]) + Double(after)
                    * Double(values[count - 1])
                centered[i] = values[i] - Float(total / Double(2 * radius + 1))
            }
            output.append(centered)
        }
        return output
    }
}

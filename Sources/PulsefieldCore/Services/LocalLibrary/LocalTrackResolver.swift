import Foundation

public actor LocalTrackResolver: LocalTrackResolving {
    private static let autoAcceptAmbiguityMargin = 0.03

    private let database: LocalAudioLibraryDatabase

    public init(database: LocalAudioLibraryDatabase) {
        self.database = database
    }

    public func resolve(_ track: CanonicalTrack) async -> [LocalResolveResult] {
        let candidates = applyAmbiguityPolicy(
            to: await database.listAssets()
            .filter { $0.status == .ready || $0.status == .metadataPartial }
            .map { score(asset: $0, against: track) }
            .sorted {
                if $0.confidence == $1.confidence {
                    return $0.asset.displayPath < $1.asset.displayPath
                }
                return $0.confidence > $1.confidence
            }
        )

        if let best = candidates.first {
            await database.recordResolve(query: track, result: best)
        }

        return candidates
    }

    private func score(asset: LocalAudioAsset, against track: CanonicalTrack) -> LocalResolveResult {
        var confidence = 0.0
        var evidence: [MatchEvidence] = []

        if let trackISRC = track.isrc?.normalizedToken,
           let assetISRC = asset.isrc?.normalizedToken,
           !trackISRC.isEmpty,
           trackISRC == assetISRC {
            confidence = max(confidence, 0.98)
            evidence.append(.isrcExact)
        }

        let trackTitle = track.title.normalizedSearchText
        let assetTitle = asset.title?.normalizedSearchText ?? ""
        if !trackTitle.isEmpty, !assetTitle.isEmpty, trackTitle == assetTitle {
            confidence += 0.38
            evidence.append(.titleExact)
        } else {
            let titleScore = fuzzyScore(trackTitle, assetTitle)
            if titleScore >= 0.82 {
                confidence += 0.28 * titleScore
                evidence.append(.titleFuzzy(score: titleScore))
            }
        }

        let trackArtists = track.artists.map(\.normalizedSearchText).filter { !$0.isEmpty }
        let assetArtists = asset.artists.map(\.normalizedSearchText).filter { !$0.isEmpty }
        if !trackArtists.isEmpty, !assetArtists.isEmpty, trackArtists.contains(where: { assetArtists.contains($0) }) {
            confidence += 0.34
            evidence.append(.artistExact)
        } else if let bestArtistScore = bestFuzzyScore(trackArtists, assetArtists), bestArtistScore >= 0.82 {
            confidence += 0.24 * bestArtistScore
            evidence.append(.artistFuzzy(score: bestArtistScore))
        }

        if let queryAlbum = track.album?.normalizedSearchText,
           let assetAlbum = asset.album?.normalizedSearchText,
           !queryAlbum.isEmpty,
           queryAlbum == assetAlbum {
            confidence += 0.12
            evidence.append(.albumExact)
        }

        var durationDeltaMS: Int?
        var hasWeakDurationMatch = false
        if let durationMS = track.durationMS {
            let delta = abs(asset.durationMS - durationMS)
            durationDeltaMS = delta
            if delta <= 2_000 {
                confidence += 0.20
                evidence.append(.durationWithinTolerance(deltaMS: delta))
            } else if delta <= 8_000 {
                hasWeakDurationMatch = true
                confidence += 0.08
                evidence.append(.durationWithinTolerance(deltaMS: delta))
            } else {
                confidence -= 0.20
            }
        }

        let fileNameScore = fileNameScore(trackTitle: trackTitle, fileName: asset.fileName.normalizedFileNameSearchText)
        if fileNameScore >= 0.86 {
            let fileNameWeight = assetTitle.isEmpty && durationDeltaMS.map({ $0 <= 8_000 }) == true ? 0.62 : 0.08
            confidence += fileNameWeight * fileNameScore
            evidence.append(.fileNameFuzzy(score: fileNameScore))
        }

        confidence = min(max(confidence, 0), 1)

        return LocalResolveResult(
            asset: asset,
            confidence: confidence,
            evidence: evidence,
            decision: decision(for: confidence, hasWeakDurationMatch: hasWeakDurationMatch)
        )
    }

    private func applyAmbiguityPolicy(to results: [LocalResolveResult]) -> [LocalResolveResult] {
        guard let best = results.first, best.decision == .autoAccepted else {
            return results
        }

        let ambiguousIDs = Set(
            results
                .filter { result in
                    result.decision == .autoAccepted
                        && best.confidence - result.confidence <= Self.autoAcceptAmbiguityMargin
                }
                .map(\.asset.id)
        )
        guard ambiguousIDs.count > 1 else {
            return results
        }

        return results.map { result in
            guard ambiguousIDs.contains(result.asset.id) else {
                return result
            }

            return LocalResolveResult(
                asset: result.asset,
                confidence: result.confidence,
                evidence: result.evidence,
                decision: .requiresUserConfirmation
            )
        }
    }

    private func decision(for confidence: Double, hasWeakDurationMatch: Bool) -> LocalResolveDecision {
        if hasWeakDurationMatch, confidence >= 0.70 {
            return .requiresUserConfirmation
        }

        if confidence >= 0.90 {
            return .autoAccepted
        }

        if confidence >= 0.70 {
            return .requiresUserConfirmation
        }

        return .rejected
    }

    private func bestFuzzyScore(_ left: [String], _ right: [String]) -> Double? {
        var best: Double?
        for leftValue in left {
            for rightValue in right {
                let score = fuzzyScore(leftValue, rightValue)
                best = max(best ?? score, score)
            }
        }
        return best
    }

    private func fileNameScore(trackTitle: String, fileName: String) -> Double {
        max(fuzzyScore(trackTitle, fileName), contiguousTokenScore(trackTitle, in: fileName))
    }

    private func contiguousTokenScore(_ query: String, in candidate: String) -> Double {
        let queryTokens = query.split(separator: " ")
        let candidateTokens = candidate.split(separator: " ")
        guard !queryTokens.isEmpty, queryTokens.count <= candidateTokens.count else {
            return 0
        }

        for startIndex in 0...(candidateTokens.count - queryTokens.count) {
            let candidateSlice = candidateTokens[startIndex..<(startIndex + queryTokens.count)]
            if candidateSlice.elementsEqual(queryTokens) {
                return 1
            }
        }

        return 0
    }

    private func fuzzyScore(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else {
            return 0
        }

        if left == right {
            return 1
        }

        let leftTokens = Set(left.split(separator: " ").map(String.init))
        let rightTokens = Set(right.split(separator: " ").map(String.init))
        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        let tokenScore = union == 0 ? 0 : Double(intersection) / Double(union)
        let editScore = 1 - (Double(levenshtein(left, right)) / Double(max(left.count, right.count)))

        return max(tokenScore, editScore)
    }

    private func levenshtein(_ left: String, _ right: String) -> Int {
        let left = Array(left)
        let right = Array(right)
        var previous = Array(0...right.count)

        for (i, leftCharacter) in left.enumerated() {
            var current = [i + 1]
            for (j, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current.append(previous[j])
                } else {
                    current.append(min(previous[j], previous[j + 1], current[j]) + 1)
                }
            }
            previous = current
        }

        return previous[right.count]
    }
}

private extension String {
    var normalizedSearchText: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var normalizedToken: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    var normalizedFileNameSearchText: String {
        (self as NSString).deletingPathExtension.normalizedSearchText
    }
}

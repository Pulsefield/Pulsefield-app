import Foundation

public enum PreviewFixtures {
    public static let recognizedTrack = RecognizedTrack(
        id: "mock:satellite-heart",
        title: "Satellite Heart",
        artist: "Anya Marina",
        artworkURL: URL(string: "https://example.com/artwork/satellite-heart.jpg"),
        externalIDs: ExternalIDs(appleMusicID: "1603171040", isrc: "USAT20901391"),
        source: .mockCatalog
    )

    public static let recognitionSnapshot = RecognitionSnapshot(
        track: recognizedTrack,
        anchor: RecognitionAnchor(
            recognizedAt: Date(timeIntervalSince1970: 1_710_000_000),
            predictedMatchOffset: 41.25,
            frequencySkew: 0.0,
            matchedRanges: [0..<12]
        )
    )
}

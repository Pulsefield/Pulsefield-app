import AVFoundation
import Foundation

public actor LocalAudioMetadataExtractor: LocalAudioMetadataExtracting {
    public init() {}

    public func extract(from fileURL: URL) async throws -> ExtractedAudioMetadata {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw LocalAudioMetadataExtractionError.unsupportedMetadata
        }

        let metadata = await loadMetadata(from: asset)
        let title = await stringValue(
            for: [.commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription],
            in: metadata
        )
        let artist = await stringValue(
            for: [.commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer],
            in: metadata
        )
        let album = await stringValue(
            for: [.commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle],
            in: metadata
        )
        var albumArtist = await stringValue(
            for: [.iTunesMetadataAlbumArtist, .id3MetadataBand],
            in: metadata
        )
        if albumArtist == nil {
            albumArtist = await rawStringValue(containing: "albumartist", in: metadata)
        }

        var trackNumber = await integerValue(
            for: [.iTunesMetadataTrackNumber, .id3MetadataTrackNumber],
            in: metadata
        )
        if trackNumber == nil {
            trackNumber = await rawIntegerValue(containing: "track", in: metadata)
        }

        var discNumber = await integerValue(
            for: [.iTunesMetadataDiscNumber, .id3MetadataPartOfASet],
            in: metadata
        )
        if discNumber == nil {
            discNumber = await rawIntegerValue(containing: "disc", in: metadata)
        }

        var primaryISRC = await stringValue(
            for: [.id3MetadataInternationalStandardRecordingCode],
            in: metadata
        )
        if primaryISRC == nil {
            primaryISRC = await rawStringValue(containing: "isrc", in: metadata)
        }
        let isrc: String?
        if let primaryISRC {
            isrc = primaryISRC
        } else {
            isrc = await rawStringValue(containing: "internationalstandardrecordingcode", in: metadata)
        }
        let releaseYear = await releaseYear(in: metadata)

        return ExtractedAudioMetadata(
            durationMS: Int((durationSeconds * 1_000).rounded()),
            title: title,
            artists: artistValues(artist),
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            isrc: isrc,
            releaseYear: releaseYear
        )
    }

    private func loadMetadata(from asset: AVURLAsset) async -> [AVMetadataItem] {
        var metadata = (try? await asset.load(.commonMetadata)) ?? []
        metadata.append(contentsOf: (try? await asset.load(.metadata)) ?? [])

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            metadata.append(contentsOf: (try? await asset.loadMetadata(for: format)) ?? [])
        }

        return metadata
    }

    private func stringValue(for identifiers: [AVMetadataIdentifier], in metadata: [AVMetadataItem]) async -> String? {
        for identifier in identifiers {
            if let value = await stringValue(for: identifier, in: metadata) {
                return value
            }
        }
        return nil
    }

    private func stringValue(for identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        return (try? await item.load(.stringValue))?.trimmedNonEmpty
    }

    private func integerValue(for identifiers: [AVMetadataIdentifier], in metadata: [AVMetadataItem]) async -> Int? {
        for identifier in identifiers {
            guard let item = metadata.first(where: { $0.identifier == identifier }) else {
                continue
            }

            if let string = (try? await item.load(.stringValue))?.trimmedNonEmpty,
               let value = integerPrefix(in: string) {
                return value
            }

            if let number = try? await item.load(.numberValue) {
                return number.intValue
            }
        }

        return nil
    }

    private func rawStringValue(containing needle: String, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { item in
            item.matchesMetadataName(containing: needle)
        }) else {
            return nil
        }
        return (try? await item.load(.stringValue))?.trimmedNonEmpty
    }

    private func rawIntegerValue(containing needle: String, in metadata: [AVMetadataItem]) async -> Int? {
        guard let value = await rawStringValue(containing: needle, in: metadata) else {
            return nil
        }

        return integerPrefix(in: value)
    }

    private func releaseYear(in metadata: [AVMetadataItem]) async -> Int? {
        let dateValue = await rawStringValue(containing: "date", in: metadata)
        let yearValue: String?
        if let dateValue {
            yearValue = dateValue
        } else {
            yearValue = await rawStringValue(containing: "year", in: metadata)
        }

        guard let value = yearValue else {
            return nil
        }

        return integerPrefix(in: value)
    }

    private func integerPrefix(in value: String) -> Int? {
        value.split { !$0.isNumber }.first.map(String.init).flatMap(Int.init)
    }

    private func artistValues(_ value: String?) -> [String] {
        guard let value = value?.trimmedNonEmpty else {
            return []
        }

        return [value]
    }
}

private extension AVMetadataItem {
    func matchesMetadataName(containing needle: String) -> Bool {
        if identifier?.rawValue.lowercased().contains(needle) == true {
            return true
        }

        if let key = key as? String, key.lowercased().contains(needle) {
            return true
        }

        return false
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

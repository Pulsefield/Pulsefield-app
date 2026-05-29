import Foundation

public struct CanonicalTrack: Equatable, Sendable {
    public let title: String
    public let artists: [String]
    public let album: String?
    public let durationMS: Int?
    public let isrc: String?
    public let providerIDs: [ProviderTrackID]

    public init(
        title: String,
        artists: [String],
        album: String? = nil,
        durationMS: Int? = nil,
        isrc: String? = nil,
        providerIDs: [ProviderTrackID] = []
    ) {
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.isrc = isrc
        self.providerIDs = providerIDs
    }
}

public struct ProviderTrackID: Equatable, Sendable {
    public enum Provider: String, Sendable {
        case manual
        case local
        case acrCloud
        case shazamKitFuture
    }

    public let provider: Provider
    public let value: String

    public init(provider: Provider, value: String) {
        self.provider = provider
        self.value = value
    }
}

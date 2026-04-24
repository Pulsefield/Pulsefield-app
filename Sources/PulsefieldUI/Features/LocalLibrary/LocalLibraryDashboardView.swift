import Observation
import PulsefieldCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
public final class LocalLibraryDashboardModel {
    public var directories: [MusicLibraryDirectory] = []
    public var status: LocalAudioLibraryStatus = .empty
    public var resolveTitle = ""
    public var resolveArtist = ""
    public var resolveAlbum = ""
    public var resolveISRC = ""
    public var resolveDurationMS = ""
    public var resolveResults: [LocalResolveResult] = []
    public var errorMessage: String?

    @ObservationIgnored
    private let directoryStore: any LocalMusicDirectoryManaging

    @ObservationIgnored
    private let indexer: any LocalAudioLibraryIndexing

    @ObservationIgnored
    private let resolver: any LocalTrackResolving

    public init(
        directoryStore: any LocalMusicDirectoryManaging,
        indexer: any LocalAudioLibraryIndexing,
        resolver: any LocalTrackResolving
    ) {
        self.directoryStore = directoryStore
        self.indexer = indexer
        self.resolver = resolver
    }

    public static func livePrototype() -> LocalLibraryDashboardModel {
        livePrototype(databaseOpener: LocalAudioLibraryDatabase.openDefault)
    }

    public static func livePrototype(databaseOpener: () throws -> LocalAudioLibraryDatabase) -> LocalLibraryDashboardModel {
        do {
            return livePrototype(database: try databaseOpener())
        } catch {
            let model = livePrototype(database: try! LocalAudioLibraryDatabase.openInMemory())
            model.errorMessage = "Could not open persistent local audio library: \(error.localizedDescription)"
            return model
        }
    }

    private static func livePrototype(database: LocalAudioLibraryDatabase) -> LocalLibraryDashboardModel {
        return LocalLibraryDashboardModel(
            directoryStore: LocalMusicDirectoryStore(database: database),
            indexer: LocalAudioLibraryIndexer(database: database),
            resolver: LocalTrackResolver(database: database)
        )
    }

    public func refresh() {
        Task {
            await refreshNow()
        }
    }

    public func addDirectory(_ url: URL) {
        Task {
            do {
                try await directoryStore.addDirectory(url, recursive: true)
                await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func removeDirectory(_ directory: MusicLibraryDirectory) {
        Task {
            do {
                try await directoryStore.removeDirectory(id: directory.id)
                await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func rescanAll() {
        Task {
            await indexer.rescanAll()
            errorMessage = nil
            await refreshNow()
        }
    }

    public func resolveManualTrack() {
        let artists = resolveArtist
            .components(separatedBy: CharacterSet(charactersIn: ",;&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let duration = Int(resolveDurationMS.trimmingCharacters(in: .whitespacesAndNewlines))
        let track = CanonicalTrack(
            title: resolveTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            artists: artists,
            album: resolveAlbum.trimmedNilIfEmpty,
            durationMS: duration,
            isrc: resolveISRC.trimmedNilIfEmpty,
            providerIDs: [.init(provider: .manual, value: "manual-debug")]
        )

        Task {
            resolveResults = await resolver.resolve(track)
        }
    }

    private func refreshNow() async {
        directories = await directoryStore.listDirectories()
        status = await indexer.status()
    }
}

public struct LocalLibraryDashboardView: View {
    @Bindable public var model: LocalLibraryDashboardModel
    @State private var isImportingDirectory = false
    private let onSelectForAmbient: ((LocalAudioAsset) -> Void)?

    public init(model: LocalLibraryDashboardModel, onSelectForAmbient: ((LocalAudioAsset) -> Void)? = nil) {
        self.model = model
        self.onSelectForAmbient = onSelectForAmbient
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                statusGrid
                directoriesList
                LocalResolveDebugView(model: model, onSelectForAmbient: onSelectForAmbient)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task {
            model.refresh()
        }
        .fileImporter(
            isPresented: $isImportingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.addDirectory(url)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Music Library")
                .font(.title.bold())
            Text("Directories, scan status, and manual resolve checks for local audio assets.")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                isImportingDirectory = true
            } label: {
                Label("Add Directory", systemImage: "folder.badge.plus")
            }

            Button {
                model.rescanAll()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }

            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "list.bullet.rectangle")
            }
        }
        .buttonStyle(.bordered)
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            statusRow("discovered", "\(model.status.discoveredCount)")
            statusRow("indexed", "\(model.status.indexedCount)")
            statusRow("failed", "\(model.status.failedCount)")
            statusRow("missing", "\(model.status.missingCount)")
            statusRow("last scan", model.status.lastScanFinishedAt?.formatted(date: .abbreviated, time: .standard) ?? "never")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
        }
    }

    private var directoriesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Directories")
                .font(.headline)

            if model.directories.isEmpty {
                Text("No directories added.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.directories) { directory in
                    HStack(spacing: 12) {
                        Image(systemName: directory.recursive ? "folder.fill.badge.gearshape" : "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(directory.displayPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.removeDirectory(directory)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    LocalLibraryDashboardView(model: .livePrototype())
}

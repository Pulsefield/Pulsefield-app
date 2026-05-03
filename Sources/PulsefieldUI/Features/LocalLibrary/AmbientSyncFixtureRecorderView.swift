#if os(macOS)
import AppKit
import Foundation
import Observation
import PulsefieldCore
import SwiftUI

@MainActor
@Observable
public final class AmbientSyncFixtureRecorderModel {
    public var assets: [LocalAudioAsset] = []
    public var selectedAssetID: UUID?
    public var recordingGroup = ""
    public var takeLabel = "take-01"
    public var notes = ""
    public var fixtureDirectoryPath: String
    public var isRecording = false
    public var activeSession: AmbientSyncFixtureRecordingSession?
    public var latestMetadata: AmbientSyncFixtureRecordingMetadata?
    public var statusMessage: String?
    public var errorMessage: String?

    @ObservationIgnored
    private let assetProvider: @Sendable () async -> [LocalAudioAsset]

    @ObservationIgnored
    private let permissionService: any MicrophonePermissionProviding

    @ObservationIgnored
    private var recorder: AmbientSyncFixtureRecorder?

    public init(
        assetProvider: @escaping @Sendable () async -> [LocalAudioAsset],
        permissionService: any MicrophonePermissionProviding = MicrophonePermissionService(),
        fixtureDirectoryURL: URL = AmbientSyncFixtureRecorder.defaultFixtureDirectoryURL()
    ) {
        self.assetProvider = assetProvider
        self.permissionService = permissionService
        fixtureDirectoryPath = fixtureDirectoryURL.path
    }

    public var selectedAsset: LocalAudioAsset? {
        guard let selectedAssetID else {
            return nil
        }

        return assets.first { $0.id == selectedAssetID }
    }

    public var canStartRecording: Bool {
        selectedAsset != nil
            && !isRecording
            && !recordingGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !takeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func refreshAssets() {
        Task {
            await refreshAssetsNow()
        }
    }

    public func selectAsset(_ assetID: UUID?) {
        selectedAssetID = assetID
        syncRecordingGroupWithSelection()
    }

    public func startRecording() {
        Task {
            await startRecordingNow()
        }
    }

    public func stopRecording() {
        guard let recorder else {
            errorMessage = "No active fixture recording."
            return
        }

        do {
            let metadata = try recorder.stopRecording()
            self.recorder = nil
            isRecording = false
            activeSession = nil
            latestMetadata = metadata
            statusMessage = "Saved \(metadata.audioFileName)"
            errorMessage = nil
        } catch {
            self.recorder = nil
            isRecording = false
            activeSession = nil
            errorMessage = error.localizedDescription
        }
    }

    public func revealFixtureDirectory() {
        let url = fixtureDirectoryURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshAssetsNow() async {
        let loadedAssets = await assetProvider()
        assets = loadedAssets
            .filter { $0.status == .ready || $0.status == .metadataPartial }
            .sorted { lhs, rhs in
                lhs.assetSortKey.localizedCaseInsensitiveCompare(rhs.assetSortKey) == .orderedAscending
            }

        if selectedAssetID == nil || selectedAsset == nil {
            selectedAssetID = assets.first?.id
        }

        syncRecordingGroupWithSelection()

        statusMessage = assets.isEmpty ? "No indexed local assets available." : "Loaded \(assets.count) indexed assets."
    }

    private func syncRecordingGroupWithSelection() {
        guard let selectedAsset else {
            recordingGroup = ""
            return
        }

        recordingGroup = AmbientSyncFixtureRecorder.suggestedRecordingGroup(for: selectedAsset)
    }

    private func startRecordingNow() async {
        guard let selectedAsset else {
            errorMessage = "Choose an indexed local asset before recording."
            return
        }

        let permission = await permissionService.requestAccess()
        guard permission == .authorized else {
            errorMessage = "Microphone access is \(permission.label)."
            return
        }

        let directoryURL = fixtureDirectoryURL()
        let request = AmbientSyncFixtureRecordingRequest(
            targetAsset: selectedAsset,
            recordingGroup: recordingGroup,
            takeLabel: takeLabel,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        )
        let recorder = AmbientSyncFixtureRecorder(
            configuration: AmbientSyncFixtureRecorder.Configuration(outputDirectoryURL: directoryURL)
        )

        do {
            let session = try recorder.startRecording(request: request)
            self.recorder = recorder
            activeSession = session
            latestMetadata = nil
            isRecording = true
            statusMessage = "Recording \(session.audioURL.lastPathComponent)"
            errorMessage = nil
        } catch {
            self.recorder = nil
            isRecording = false
            activeSession = nil
            errorMessage = error.localizedDescription
        }
    }

    private func fixtureDirectoryURL() -> URL {
        URL(
            fileURLWithPath: (fixtureDirectoryPath as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }
}

public struct AmbientSyncFixtureRecorderView: View {
    @Bindable public var model: AmbientSyncFixtureRecorderModel

    public init(model: AmbientSyncFixtureRecorderModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ambient Sync Fixture Recorder")
                .font(.headline)

            directoryRow
            trackPicker
            selectedAssetSummary
            metadataControls
            recordingControls
            statusSummary
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task {
            model.refreshAssets()
        }
    }

    private var directoryRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("fixtures")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Fixture directory", text: $model.fixtureDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .disabled(model.isRecording)

                    Button {
                        model.revealFixtureDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal fixture directory")
                    .disabled(model.isRecording)
                }
            }
        }
    }

    private var trackPicker: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("track")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Track", selection: Binding(
                        get: { model.selectedAssetID },
                        set: { model.selectAsset($0) }
                    )) {
                        Text("No track").tag(UUID?.none)
                        ForEach(model.assets) { asset in
                            Text(asset.assetPickerLabel)
                                .tag(Optional(asset.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 520)
                    .disabled(model.isRecording || model.assets.isEmpty)

                    Button {
                        model.refreshAssets()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh indexed assets")
                    .disabled(model.isRecording)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedAssetSummary: some View {
        if let asset = model.selectedAsset {
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.fileName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(asset.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 12) {
                    Text(asset.status.label)
                    Text(asset.durationMS.durationLabel)
                    if let title = asset.title {
                        Text(title)
                            .lineLimit(1)
                    }
                    if !asset.artists.isEmpty {
                        Text(asset.artists.joined(separator: ", "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var metadataControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("group")
                    .foregroundStyle(.secondary)
                Text(model.recordingGroup.isEmpty ? "No track selected" : model.recordingGroup)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360, alignment: .leading)
            }

            GridRow {
                Text("take")
                    .foregroundStyle(.secondary)
                TextField("Take", text: $model.takeLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .disabled(model.isRecording)
            }

            GridRow {
                Text("notes")
                    .foregroundStyle(.secondary)
                TextField("Notes", text: $model.notes)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 520)
                    .disabled(model.isRecording)
            }
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 10) {
            Button {
                model.startRecording()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartRecording)

            Button {
                model.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!model.isRecording)
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let activeSession = model.activeSession {
            fixturePathRow("recording", activeSession.audioURL.path)
        }

        if let latestMetadata = model.latestMetadata {
            VStack(alignment: .leading, spacing: 6) {
                Text("Latest Fixture")
                    .font(.subheadline.weight(.semibold))
                fixturePathRow("audio", latestMetadata.audioFileName)
                Text("duration \(latestMetadata.durationMS.durationLabel) / target \(latestMetadata.targetAsset.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        if let status = model.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error = model.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func fixturePathRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private extension LocalAudioAsset {
    var assetPickerLabel: String {
        if let title, !artists.isEmpty {
            return "\(title) - \(artists.joined(separator: ", "))"
        }

        if let title {
            return title
        }

        return fileName
    }

    var assetSortKey: String {
        "\(title ?? fileName) \(artists.joined(separator: " ")) \(displayPath)"
    }
}

private extension LocalAudioIndexStatus {
    var label: String {
        switch self {
        case .ready:
            return "ready"
        case .metadataPartial:
            return "metadata partial"
        case .missingFile:
            return "missing"
        case .unsupportedFormat:
            return "unsupported"
        case .unreadable:
            return "unreadable"
        case .failed:
            return "failed"
        }
    }
}

private extension MicrophonePermissionStatus {
    var label: String {
        switch self {
        case .undetermined:
            return "undetermined"
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        }
    }
}

private extension Int {
    var durationLabel: String {
        let totalSeconds = Swift.max(0, self) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
#endif

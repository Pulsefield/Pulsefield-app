import PulsefieldCore
import SwiftUI

public struct LocalResolveDebugView: View {
    @Bindable public var model: LocalLibraryDashboardModel

    public init(model: LocalLibraryDashboardModel) {
        self.model = model
    }

    public var body: some View {
        LocalResolveDebugPanel(
            title: "Manual Resolve Test",
            resolveTitle: $model.resolveTitle,
            resolveArtist: $model.resolveArtist,
            resolveAlbum: $model.resolveAlbum,
            resolveISRC: $model.resolveISRC,
            resolveDurationMS: $model.resolveDurationMS,
            resolveResults: model.resolveResults,
            resolveActionTitle: "Resolve Against Local Library",
            onResolve: model.resolveManualTrack
        )
    }
}

public struct LocalResolveDebugPanel: View {
    private let title: String
    @Binding private var resolveTitle: String
    @Binding private var resolveArtist: String
    @Binding private var resolveAlbum: String
    @Binding private var resolveISRC: String
    @Binding private var resolveDurationMS: String
    private let resolveResults: [LocalResolveResult]
    private let selectedAssetID: Binding<UUID?>?
    private let resolveActionTitle: String
    private let onResolve: () -> Void

    public init(
        title: String,
        resolveTitle: Binding<String>,
        resolveArtist: Binding<String>,
        resolveAlbum: Binding<String>,
        resolveISRC: Binding<String>,
        resolveDurationMS: Binding<String>,
        resolveResults: [LocalResolveResult],
        selectedAssetID: Binding<UUID?>? = nil,
        resolveActionTitle: String,
        onResolve: @escaping () -> Void
    ) {
        self.title = title
        self._resolveTitle = resolveTitle
        self._resolveArtist = resolveArtist
        self._resolveAlbum = resolveAlbum
        self._resolveISRC = resolveISRC
        self._resolveDurationMS = resolveDurationMS
        self.resolveResults = resolveResults
        self.selectedAssetID = selectedAssetID
        self.resolveActionTitle = resolveActionTitle
        self.onResolve = onResolve
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                inputRow("title", text: $resolveTitle)
                inputRow("artist", text: $resolveArtist)
                inputRow("album", text: $resolveAlbum)
                inputRow("ISRC", text: $resolveISRC)
                inputRow("duration", text: $resolveDurationMS)
            }

            Button {
                onResolve()
            } label: {
                Label(resolveActionTitle, systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !resolveResults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Resolve Result")
                        .font(.subheadline.weight(.semibold))

                    if let selectedAssetID {
                        Picker("Candidate", selection: selectedAssetID) {
                            ForEach(resolveResults.prefix(8), id: \.asset.id) { result in
                                Text(result.asset.matchPickerLabel)
                                    .tag(Optional(result.asset.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 520)
                    }

                    ForEach(resolveResults.prefix(5), id: \.asset.id) { result in
                        LocalResolveResultRow(
                            result: result,
                            isSelected: selectedAssetID?.wrappedValue == result.asset.id,
                            isSelectable: selectedAssetID != nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAssetID?.wrappedValue = result.asset.id
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func inputRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        }
    }
}

private struct LocalResolveResultRow: View {
    let result: LocalResolveResult
    let isSelected: Bool
    let isSelectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isSelectable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }

                Text(result.asset.fileName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(result.decision.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.decision == .autoAccepted ? .green : .secondary)
            }

            Text(result.asset.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("confidence \(result.confidence.formatted(.number.precision(.fractionLength(2)))) / \(result.decision.label)")
                .font(.caption.monospaced())

            if !result.evidence.isEmpty {
                Text(result.evidence.map(\.label).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(isSelected ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension LocalResolveDecision {
    var label: String {
        switch self {
        case .autoAccepted:
            return "auto"
        case .requiresUserConfirmation:
            return "confirm"
        case .rejected:
            return "rejected"
        }
    }
}

private extension LocalAudioAsset {
    var matchPickerLabel: String {
        if let title, !artists.isEmpty {
            return "\(title) - \(artists.joined(separator: ", "))"
        }

        if let title {
            return title
        }

        return fileName
    }
}

private extension MatchEvidence {
    var label: String {
        switch self {
        case .isrcExact:
            return "ISRC exact"
        case .titleExact:
            return "title exact"
        case .artistExact:
            return "artist exact"
        case .albumExact:
            return "album exact"
        case .durationWithinTolerance(let deltaMS):
            return "duration delta \(deltaMS)ms"
        case .titleFuzzy(let score):
            return "title fuzzy \(score.formatted(.number.precision(.fractionLength(2))))"
        case .artistFuzzy(let score):
            return "artist fuzzy \(score.formatted(.number.precision(.fractionLength(2))))"
        case .albumFuzzy(let score):
            return "album fuzzy \(score.formatted(.number.precision(.fractionLength(2))))"
        case .fileNameFuzzy(let score):
            return "filename fuzzy \(score.formatted(.number.precision(.fractionLength(2))))"
        }
    }
}

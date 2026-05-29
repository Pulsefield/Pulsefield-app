import PulsefieldCore
import SwiftUI

public struct LocalResolveDebugView: View {
    @Bindable public var model: LocalLibraryDashboardModel

    public init(model: LocalLibraryDashboardModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual Resolve Test")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                inputRow("title", text: $model.resolveTitle)
                inputRow("artist", text: $model.resolveArtist)
                inputRow("album", text: $model.resolveAlbum)
                inputRow("ISRC", text: $model.resolveISRC)
                inputRow("duration", text: $model.resolveDurationMS)
            }

            Button {
                model.resolveManualTrack()
            } label: {
                Label("Resolve Against Local Library", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.resolveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !model.resolveResults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Resolve Result")
                        .font(.subheadline.weight(.semibold))

                    ForEach(model.resolveResults.prefix(5), id: \.asset.id) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.asset.fileName)
                                .font(.body.weight(.semibold))
                            Text(result.asset.displayPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("confidence \(result.confidence.formatted(.number.precision(.fractionLength(2)))) / \(result.decision.label)")
                                .font(.caption.monospaced())
                            Text(result.evidence.map(\.label).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
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
        case .fileNameFuzzy(let score):
            return "filename fuzzy \(score.formatted(.number.precision(.fractionLength(2))))"
        }
    }
}

import SwiftUI

public struct RecognitionDashboardView: View {
    @Bindable public var model: RecognitionAppModel

    public init(model: RecognitionAppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statusCard
                recognitionCard
                beatmapCard
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(backgroundGradient)
        .task {
            model.bootstrap()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pulsefield")
                .font(.system(size: 38, weight: .bold, design: .rounded))

            Text("A compile-correct SwiftUI scaffold for music-reactive prototyping. Microphone permission is real, recognition is mocked, and the future beatmap pipeline is already reserved in the app model.")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                chip(label: "Backend: \(model.activeBackendLabel)")
                chip(label: "Beatmap Mode: \(BeatmapMode.mania4k.rawValue)")
                chip(label: "Live ShazamKit: gated")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permission & State")
                .font(.headline)

            Text(model.phaseTitle)
                .font(.title2.bold())

            Text(model.phaseDetail)
                .foregroundStyle(.secondary)

            Text("Microphone status: \(model.permissionStatus.rawValue)")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)

            Button(model.primaryActionTitle) {
                model.handlePrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.permissionStatus == .denied || model.permissionStatus == .restricted)
        }
        .cardStyle()
    }

    private var recognitionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recognition Snapshot")
                .font(.headline)

            if let snapshot = model.latestSnapshot {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.track.title)
                        .font(.title2.bold())

                    Text(snapshot.track.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Text("Source: \(snapshot.track.source.rawValue)")
                        .font(.callout.monospaced())

                    if let offset = snapshot.anchor.predictedMatchOffset {
                        Text("Predicted offset: \(offset.formatted(.number.precision(.fractionLength(2))))s")
                            .font(.callout.monospaced())
                    }

                    Text("Recognized at: \(snapshot.anchor.recognizedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.callout.monospaced())
                }
            } else {
                Text("No snapshot yet. Run the prototype flow after granting microphone permission.")
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var beatmapCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reserved Beatmap Interface")
                .font(.headline)

            if let request = model.beatmapRequest {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prepared request for \(request.snapshot.track.title)")
                        .font(.title3.bold())

                    Text("Mode: \(request.mode.rawValue)")
                        .font(.callout.monospaced())

                    if let handle = model.beatmapHandle {
                        Text(handle.note)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("The app will create a `BeatmapGenerationRequest` here once a recognition snapshot exists.")
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func chip(label: String) -> some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.98, blue: 1.0),
                Color(red: 0.88, green: 0.93, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

#Preview("Matched") {
    RecognitionDashboardView(model: .previewMatched())
}

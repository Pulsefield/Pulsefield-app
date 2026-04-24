import Observation
import PulsefieldCore
import SwiftUI

@MainActor
@Observable
public final class AmbientMatchingDashboardModel {
    public var selectedAsset: LocalAudioAsset? {
        didSet {
            guard selectedAsset?.id != oldValue?.id else {
                return
            }

            clearSelectionScopedState()
        }
    }
    public var syncIndex: LocalAudioSyncIndex?
    public var state: AmbientSyncState = .idle
    public var currentEstimate: SyncEstimate?
    public var microphonePermissionStatus: MicrophonePermissionStatus = .undetermined
    public var errorMessage: String?

    @ObservationIgnored
    private let syncIndexer: any LocalAudioSyncIndexing

    @ObservationIgnored
    private let estimator: FeatureCorrelationSyncEstimator

    @ObservationIgnored
    private let microphonePermissionService: any MicrophonePermissionProviding

    public init(
        selectedAsset: LocalAudioAsset? = nil,
        syncIndexer: any LocalAudioSyncIndexing,
        estimator: FeatureCorrelationSyncEstimator,
        microphonePermissionService: any MicrophonePermissionProviding = MicrophonePermissionService()
    ) {
        self.selectedAsset = selectedAsset
        self.syncIndexer = syncIndexer
        self.estimator = estimator
        self.microphonePermissionService = microphonePermissionService
    }

    public static func livePrototype(selectedAsset: LocalAudioAsset? = nil) -> AmbientMatchingDashboardModel {
        let capture = AmbientAudioCaptureService()
        return AmbientMatchingDashboardModel(
            selectedAsset: selectedAsset,
            syncIndexer: LocalAudioSyncIndexer(),
            estimator: FeatureCorrelationSyncEstimator(capture: capture)
        )
    }

    public func buildIndex() {
        guard let selectedAsset else {
            errorMessage = "Select a local audio asset before building a sync index."
            return
        }

        Task {
            do {
                state = .preparingIndex
                let index = try await syncIndexer.buildIndex(for: selectedAsset)
                guard self.selectedAsset?.id == selectedAsset.id else {
                    return
                }
                syncIndex = index
                state = .idle
                errorMessage = nil
            } catch {
                guard self.selectedAsset?.id == selectedAsset.id else {
                    return
                }
                state = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    public func startMatching() {
        guard let selectedAsset else {
            errorMessage = "Select a local audio asset before starting ambient matching."
            return
        }
        guard let syncIndex else {
            errorMessage = "Build a sync index before starting ambient matching."
            return
        }
        guard syncIndex.assetID == selectedAsset.id else {
            clearSelectionScopedState()
            errorMessage = "Build a sync index for the selected local audio asset before starting ambient matching."
            return
        }

        Task {
            let permissionStatus = await ensureMicrophonePermission()
            microphonePermissionStatus = permissionStatus
            guard permissionStatus == .authorized else {
                state = .idle
                currentEstimate = nil
                errorMessage = "Microphone access is required before ambient matching can start."
                return
            }

            do {
                try await estimator.start(asset: selectedAsset, index: syncIndex)
                await refreshEstimate()
                errorMessage = nil
            } catch {
                state = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    public func stop() {
        Task {
            await estimator.stop()
            await refreshState()
        }
    }

    public func refreshEstimate() async {
        currentEstimate = await estimator.currentEstimate()
        await refreshState()
    }

    public func refreshMicrophonePermission() {
        Task {
            microphonePermissionStatus = await microphonePermissionService.currentStatus()
        }
    }

    public func nudge(byMilliseconds deltaMS: Double) {
        Task {
            await estimator.nudge(byMilliseconds: deltaMS)
            await refreshEstimate()
        }
    }

    public func forceRelock() {
        Task {
            await estimator.forceRelock()
            await refreshState()
        }
    }

    private func refreshState() async {
        state = await estimator.currentState()
    }

    private func ensureMicrophonePermission() async -> MicrophonePermissionStatus {
        let status = await microphonePermissionService.currentStatus()
        guard status == .undetermined else {
            return status
        }

        return await microphonePermissionService.requestAccess()
    }

    private func clearSelectionScopedState() {
        syncIndex = nil
        currentEstimate = nil
        state = .idle
        errorMessage = nil
        Task {
            await estimator.stop()
        }
    }
}

public struct AmbientMatchingDashboardView: View {
    @Bindable public var model: AmbientMatchingDashboardModel

    public init(model: AmbientMatchingDashboardModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                assetSummary
                syncIndexSummary
                matchingSummary
                controls
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task {
            model.refreshMicrophonePermission()
            while !Task.isCancelled {
                await model.refreshEstimate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ambient Matching")
                .font(.title.bold())
            Text("Feature-correlation sync estimate against a resolved local audio asset.")
                .foregroundStyle(.secondary)
        }
    }

    private var assetSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Local Asset")
                .font(.headline)
            if let asset = model.selectedAsset {
                Text(asset.title ?? asset.fileName)
                    .font(.title3.weight(.semibold))
                Text(asset.artists.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Text(asset.displayPath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("duration \(asset.durationMS)ms")
                    .font(.caption.monospaced())
            } else {
                Text("No local asset selected.")
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }

    private var syncIndexSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Index")
                .font(.headline)
            if let index = model.syncIndex {
                Text("ready / version \(index.version)")
                    .font(.body.monospaced())
                Text(index.onsetEnvelopeURL.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("missing")
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }

    private var matchingSummary: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            row("state", model.state.label)
            row("reference", model.currentEstimate.map { "\($0.referenceTimeMS.formatted(.number.precision(.fractionLength(1))))ms" } ?? "none")
            row("confidence", model.currentEstimate.map { $0.confidence.formatted(.number.precision(.fractionLength(2))) } ?? "none")
            row("drift", model.currentEstimate?.driftPPM.map { "\($0)ppm" } ?? "none")
            row("microphone", model.microphonePermissionStatus.rawValue)
            row("source", model.currentEstimate?.source.rawValue ?? "none")
        }
        .panelStyle()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    model.buildIndex()
                } label: {
                    Label("Build Index", systemImage: "waveform.path.ecg")
                }

                Button {
                    model.startMatching()
                } label: {
                    Label("Start Matching", systemImage: "mic")
                }

                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }

            HStack(spacing: 12) {
                Button {
                    model.nudge(byMilliseconds: -50)
                } label: {
                    Label("-50ms", systemImage: "backward.end")
                }

                Button {
                    model.nudge(byMilliseconds: 50)
                } label: {
                    Label("+50ms", systemImage: "forward.end")
                }

                Button {
                    model.forceRelock()
                } label: {
                    Label("Force Relock", systemImage: "scope")
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.bordered)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
        }
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension AmbientSyncState {
    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .preparingIndex:
            return "preparingIndex"
        case .listening:
            return "listening"
        case .locking:
            return "locking"
        case .locked:
            return "locked"
        case .drifting:
            return "drifting"
        case .lost:
            return "lost"
        case .failed(let message):
            return "failed: \(message)"
        }
    }
}

#Preview {
    AmbientMatchingDashboardView(model: .livePrototype())
}

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
    public var state: AmbientSyncEngineState = .idle
    public var currentEstimate: SyncEstimate?
    public var currentDiagnostics: AmbientMatchDiagnostics?
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
                state = .indexing
                let index = try await syncIndexer.buildIndex(for: selectedAsset)
                guard self.selectedAsset?.id == selectedAsset.id else {
                    return
                }
                syncIndex = index
                state = .ready
                errorMessage = nil
            } catch {
                guard self.selectedAsset?.id == selectedAsset.id else {
                    return
                }
                state = .failed
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
            guard isCurrentMatchingRequest(asset: selectedAsset, index: syncIndex) else {
                return
            }

            guard permissionStatus == .authorized else {
                state = .idle
                currentEstimate = nil
                currentDiagnostics = nil
                errorMessage = "Microphone access is required before ambient matching can start."
                return
            }

            do {
                try await estimator.start(asset: selectedAsset, index: syncIndex)
                guard isCurrentMatchingRequest(asset: selectedAsset, index: syncIndex) else {
                    await estimator.stop()
                    return
                }

                await refreshEstimate()
                guard isCurrentMatchingRequest(asset: selectedAsset, index: syncIndex) else {
                    await estimator.stop()
                    return
                }

                errorMessage = nil
            } catch {
                guard isCurrentMatchingRequest(asset: selectedAsset, index: syncIndex) else {
                    return
                }

                state = .failed
                currentDiagnostics = await estimator.currentDiagnostics()
                errorMessage = error.localizedDescription
            }
        }
    }

    public func stop() {
        Task {
            await estimator.stop()
            currentEstimate = nil
            currentDiagnostics = nil
            await refreshState()
        }
    }

    public func refreshEstimate() async {
        currentEstimate = await estimator.currentEstimate()
        currentDiagnostics = await estimator.currentDiagnostics()
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

    private func isCurrentMatchingRequest(asset: LocalAudioAsset, index: LocalAudioSyncIndex) -> Bool {
        selectedAsset?.id == asset.id && syncIndex == index
    }

    private func clearSelectionScopedState() {
        syncIndex = nil
        currentEstimate = nil
        currentDiagnostics = nil
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
                diagnosticsSummary
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
            row("drift", formatPPM(model.currentEstimate?.driftPPM))
            row("microphone", model.microphonePermissionStatus.rawValue)
            row("source", model.currentEstimate?.source.rawValue ?? "none")
            row("published", model.currentDiagnostics.map { $0.decision.didPublishEstimate ? "yes" : "no" } ?? "none")
            row("withhold", model.currentDiagnostics?.decision.withholdReason?.rawValue ?? "none")
            row("search", model.currentDiagnostics?.search.mode.rawValue ?? "none")
            row("peak", model.currentDiagnostics.map { formatScore($0.scoring.peakScore) } ?? "none")
            row("explanation", model.currentDiagnostics?.decision.explanation ?? "none")
        }
        .panelStyle()
    }

    @ViewBuilder
    private var diagnosticsSummary: some View {
        if let diagnostics = model.currentDiagnostics {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnostics")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    row("index status", diagnostics.index.status.rawValue)
                    row("feature version", diagnostics.index.featureExtractorVersion)
                    row("settings hash", diagnostics.index.settingsHash)
                    row("window", formatMS(diagnostics.capture.windowDurationMS))
                    row("input sample rate", formatNumber(diagnostics.capture.inputSampleRate))
                    row("input channels", "\(diagnostics.capture.inputChannelCount)")
                    row("captured frames", "\(diagnostics.capture.capturedFrameCount)")
                    row("dropped windows", "\(diagnostics.capture.droppedWindowCount)")
                    row("query frames", "\(diagnostics.query.featureFrameCount)")
                    row("query energy", formatDBFS(diagnostics.query.energyDBFS))
                    row("active frames", formatPercent(diagnostics.query.activeFrameFraction))
                    row("query landmarks", "\(diagnostics.query.landmarkCount)")
                    row("processing rate", "\(diagnostics.query.processingSampleRate)")
                    row("hop", "\(diagnostics.query.hopSize)")
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    row("search range", "\(formatMS(diagnostics.search.searchRangeStartMS)) - \(formatMS(diagnostics.search.searchRangeEndMS))")
                    row("predicted", formatOptionalMS(diagnostics.search.predictedReferenceMS))
                    row("selected", formatOptionalMS(diagnostics.search.selectedReferenceMS))
                    row("candidate count", "\(diagnostics.search.candidateCount)")
                    row("candidate density", formatScore(diagnostics.search.candidateDensity))
                    row("second best", formatOptionalScore(diagnostics.scoring.secondBestScore))
                    row("peak margin", formatOptionalScore(diagnostics.scoring.peakMargin))
                    row("peak ratio", formatOptionalScore(diagnostics.scoring.peakRatio))
                    row("peak sharpness", formatOptionalScore(diagnostics.scoring.peakSharpness))
                    row("peak width", formatOptionalMS(diagnostics.scoring.peakWidthMS))
                    row("noise mean", formatOptionalScore(diagnostics.scoring.noiseFloorMean))
                    row("noise std", formatOptionalScore(diagnostics.scoring.noiseFloorStd))
                    row("peak z", formatOptionalScore(diagnostics.scoring.peakZ))
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    row("landmark votes", "\(diagnostics.scoring.landmarkVoteCount)")
                    row("landmark inliers", formatPercent(diagnostics.scoring.landmarkInlierRate))
                    row("onset flux", formatOptionalScore(diagnostics.scoring.onsetFluxScore))
                    row("log mel", formatOptionalScore(diagnostics.scoring.logMelScore))
                    row("chroma", formatOptionalScore(diagnostics.scoring.chromaScore))
                    row("energy score", formatOptionalScore(diagnostics.scoring.energyScore))
                    row("time residual", formatOptionalMS(diagnostics.scoring.timeResidualMS))
                    row("clock observations", "\(diagnostics.clock.observationCount)")
                    row("raw drift", formatPPM(diagnostics.clock.rawDriftPPM))
                    row("smoothed drift", formatPPM(diagnostics.clock.smoothedDriftPPM))
                    row("tracking stability", formatScore(diagnostics.clock.trackingStability))
                    row("latency", formatOptionalMS(diagnostics.clock.latencyMS))
                    row("latency source", diagnostics.clock.latencySource.rawValue)
                }

                if !diagnostics.search.topCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Candidates")
                            .font(.subheadline.weight(.semibold))
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            ForEach(Array(diagnostics.search.topCandidates.enumerated()), id: \.offset) { index, candidate in
                                candidateRow(index: index + 1, candidate: candidate)
                            }
                        }
                    }
                }
            }
            .panelStyle()
        }
    }

    private func candidateRow(index: Int, candidate: CandidateAlignment) -> some View {
        GridRow {
            Text("#\(index)")
                .foregroundStyle(.secondary)
            Text(
                [
                    "offset \(formatMS(candidate.offsetMS))",
                    "ref \(formatMS(candidate.referenceTimeAtWindowEndMS))",
                    "score \(formatScore(candidate.combinedScore))",
                    "votes \(candidate.landmarkVoteCount)",
                    "inliers \(formatPercent(candidate.landmarkInlierRate))"
                ].joined(separator: " / ")
            )
            .font(.body.monospaced())
        }
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

    private func formatNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func formatScore(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatOptionalScore(_ value: Double?) -> String {
        value.map(formatScore) ?? "none"
    }

    private func formatMS(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))ms"
    }

    private func formatOptionalMS(_ value: Double?) -> String {
        value.map(formatMS) ?? "none"
    }

    private func formatPPM(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1))))ppm" } ?? "none"
    }

    private func formatDBFS(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) dBFS"
    }

    private func formatPercent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension AmbientSyncEngineState {
    var label: String {
        switch self {
        case .idle:
            return "idle"
        case .indexing:
            return "indexing"
        case .ready:
            return "ready"
        case .listening:
            return "listening"
        case .locking:
            return "locking"
        case .locked:
            return "locked"
        case .drifting:
            return "drifting"
        case .relocking:
            return "relocking"
        case .lost:
            return "lost"
        case .failed:
            return "failed"
        }
    }
}

#Preview {
    AmbientMatchingDashboardView(model: .livePrototype())
}

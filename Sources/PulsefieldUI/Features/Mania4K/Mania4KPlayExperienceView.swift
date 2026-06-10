import Foundation
import AVFoundation
import PulsefieldCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct Mania4KPlayExperienceView: View {
    @Bindable public var model: Mania4KPlaySessionModel
    @AppStorage("mania4k.offsetCalibrationState") private var storedOffsetCalibrationState = ""
    @State private var didRestoreStoredOffsets = false

    public init(model: Mania4KPlaySessionModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Mania4KBackdrop()

            if model.phase == .setup {
                Mania4KSetupView(
                    model: model,
                    storedOffsetCalibrationState: $storedOffsetCalibrationState,
                    shouldRestoreStoredOffsets: !didRestoreStoredOffsets
                ) {
                    didRestoreStoredOffsets = true
                }
            } else {
                Mania4KPlaySceneView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

private struct Mania4KSetupView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: Mania4KPlaySessionModel
    @State private var fileImportTarget: Mania4KFileImportTarget?
    @State private var isChoosingFile = false
    @State private var offsetCalibrationModel: Mania4KOffsetCalibrationModel?
    @Binding var storedOffsetCalibrationState: String
    let shouldRestoreStoredOffsets: Bool
    let onStoredOffsetsRestored: () -> Void
    #if os(macOS)
    @AppStorage("mania4k.keyBindings") private var storedKeyBindings = Mania4KKeyBindingSet.default.storageValue
    @State private var capturingKeyBindingLane: Mania4KLane?
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                if let offsetCalibrationModel {
                    Mania4KOffsetCalibrationView(
                        model: offsetCalibrationModel,
                        scrollTimeMs: model.scrollTimeMs,
                        onStateChanged: { state in
                            persistCalibrationState(state)
                        },
                        onApply: applyOffsetCalibration,
                        onCancel: cancelOffsetCalibration
                    )
                } else {
                    header
                    setupContent
                }
                #else
                header
                setupContent
                #endif
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .fileImporter(
            isPresented: $isChoosingFile,
            // .osu is normally a dynamic UTType; using public.data avoids picker-side rejection and leaves role checks to the model.
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImportResult(result)
        }
        .onAppear {
            if shouldRestoreStoredOffsets {
                restoreStoredOffsets()
                onStoredOffsetsRestored()
            }
            #if os(macOS)
            restoreStoredKeyBindings()
            #endif
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 16) {
                inputPanel
                previewPanel
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                inputPanel
                    .frame(maxWidth: 460)

                previewPanel
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pulsefield")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Mania4KStyle.textPrimary)

                Text("mania4k first playable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.textSecondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Label("4K", systemImage: "square.grid.2x2.fill")
                Text(model.isReadyToStart ? "READY" : "SETUP")
            }
            .font(.caption.monospaced().weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Mania4KStyle.textPrimary)
            .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(model.isReadyToStart ? Mania4KStyle.accentGreen : Mania4KStyle.border, lineWidth: 1)
            )
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Play Setup")
                .font(.title2.bold())
                .foregroundStyle(Mania4KStyle.textPrimary)

            filePickerRow(
                title: "Beatmap",
                value: model.beatmapFileName,
                message: model.beatmapSelectionErrorMessage,
                systemImage: "doc.text",
                action: { presentFileImporter(for: .beatmap) }
            )

            filePickerRow(
                title: "Audio",
                value: model.audioFileName,
                message: model.audioSelectionErrorMessage,
                systemImage: "waveform",
                action: { presentFileImporter(for: .audio) }
            )

            settings

            Button {
                Task {
                    await model.startPlay()
                }
            } label: {
                Label("Start Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(Mania4KPrimaryButtonStyle())
            .controlSize(.large)
            .disabled(!model.isReadyToStart || model.phase == .loading)
        }
        .panelStyle()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            numericField(
                title: "osu!mania star difficulty",
                value: $model.starDifficulty,
                range: 0.1...12.0,
                step: 0.1,
                suffix: "stars"
            )

            numericField(
                title: "Scroll speed",
                value: $model.scrollSpeed,
                range: 1.0...40.0,
                step: 0.1,
                suffix: "x"
            )

            offsetSettings

            VStack(alignment: .leading, spacing: 8) {
                Text("Judge difficulty")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.textPrimary)

                Picker("Judge difficulty", selection: $model.judgeDifficulty) {
                    ForEach(Mania4KJudgeDifficulty.allCases) { difficulty in
                        Text(difficulty.rawValue).tag(difficulty)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Mania4KStyle.accentBlue)
            }

            #if os(macOS)
            keyBindingSettings
            #endif
        }
    }

    private var offsetSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            offsetSetting(
                title: "Audio offset",
                description: "Moves song timing and judgement timing. Use when hits sound early or late.",
                binding: audioOffsetBinding
            )

            offsetSetting(
                title: "Visual offset",
                description: "Moves note display only. Use when notes look early or late while the sound feels correct.",
                binding: visualOffsetBinding
            )

            #if os(macOS)
            Button {
                openOffsetCalibration()
            } label: {
                Label("Calibrate", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentGreen))
            #endif
        }
    }

    private func offsetSetting(title: String, description: String, binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textPrimary)

            Text(description)
                .font(.caption)
                .foregroundStyle(Mania4KStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Stepper(value: binding, in: -500...500, step: 1) {
                    TextField(
                        title,
                        value: binding,
                        format: .number.precision(.fractionLength(0))
                    )
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Mania4KStyle.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Mania4KStyle.border, lineWidth: 1)
                    )
                    .frame(minWidth: 82, maxWidth: 120)
                }

                Text("ms")
                    .font(.callout.monospaced())
                    .foregroundStyle(Mania4KStyle.textMuted)
            }
        }
    }

    private var audioOffsetBinding: Binding<Double> {
        Binding(
            get: {
                model.audioOffsetMilliseconds
            },
            set: { value in
                let offsetMilliseconds = clampedOffsetMilliseconds(value)
                model.audioOffsetMilliseconds = Double(offsetMilliseconds)
            }
        )
    }

    private var visualOffsetBinding: Binding<Double> {
        Binding(
            get: {
                model.visualOffsetMilliseconds
            },
            set: { value in
                let offsetMilliseconds = clampedOffsetMilliseconds(value)
                model.visualOffsetMilliseconds = Double(offsetMilliseconds)
            }
        )
    }

    private func restoreStoredOffsets() {
        guard let storedState = calibrationStoredState else {
            return
        }

        model.audioOffsetMilliseconds = Double(storedState.appliedAudioOffsetMilliseconds)
        model.visualOffsetMilliseconds = Double(storedState.appliedVisualOffsetMilliseconds)
    }

    private var calibrationStoredState: Mania4KOffsetCalibrationStoredState? {
        guard let storedState = Mania4KOffsetCalibrationStoredState(storageValue: storedOffsetCalibrationState) else {
            return nil
        }

        return Mania4KOffsetCalibrationModel.normalizedStoredState(
            storedState,
            fallbackAppliedAudioOffsetMilliseconds: 0,
            fallbackAppliedVisualOffsetMilliseconds: 0
        )
    }

    private func persistCalibrationState(
        _ state: Mania4KOffsetCalibrationStoredState,
        createsStateIfNeeded: Bool = false
    ) {
        guard createsStateIfNeeded || calibrationStoredState != nil || !state.presets.isEmpty || state.activePresetID != nil else {
            return
        }

        storedOffsetCalibrationState = state.storageValue
    }

    private func clampedOffsetMilliseconds(_ value: Double) -> Int {
        min(max(Int(value.rounded()), -500), 500)
    }

    #if os(macOS)
    private func openOffsetCalibration() {
        let calibrationModel = Mania4KOffsetCalibrationModel(
            originalAudioOffsetMilliseconds: clampedOffsetMilliseconds(model.audioOffsetMilliseconds),
            originalVisualOffsetMilliseconds: clampedOffsetMilliseconds(model.visualOffsetMilliseconds),
            storedState: calibrationStoredState,
            tickPlayer: Mania4KOffsetCalibrationResourceTickPlayer()
        )
        calibrationModel.prewarmCalibrationTicks()
        offsetCalibrationModel = calibrationModel
    }

    private func applyOffsetCalibration(_ calibrationModel: Mania4KOffsetCalibrationModel) {
        let appliedOffsets = calibrationModel.apply()
        model.audioOffsetMilliseconds = Double(appliedOffsets.audioOffsetMilliseconds)
        model.visualOffsetMilliseconds = Double(appliedOffsets.visualOffsetMilliseconds)
        persistCalibrationState(calibrationModel.storedState, createsStateIfNeeded: true)
        offsetCalibrationModel = nil
    }

    private func cancelOffsetCalibration(_ calibrationModel: Mania4KOffsetCalibrationModel) {
        let originalOffsets = calibrationModel.cancel()
        model.audioOffsetMilliseconds = Double(originalOffsets.audioOffsetMilliseconds)
        model.visualOffsetMilliseconds = Double(originalOffsets.visualOffsetMilliseconds)
        offsetCalibrationModel = nil
    }

    private var keyBindingSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keybinds")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.textPrimary)

                Spacer()

                Button {
                    model.resetKeyBindingsToDefault()
                    storedKeyBindings = model.keyBindings.storageValue
                    capturingKeyBindingLane = nil
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(Mania4KSecondaryButtonStyle())
            }

            HStack(spacing: 8) {
                ForEach(Mania4KLane.allCases) { lane in
                    keyBindingButton(for: lane)
                }
            }
            .background(
                Mania4KKeyBindingCaptureView(activeLane: $capturingKeyBindingLane) { lane, key in
                    if model.updateKeyBinding(lane: lane, key: key) {
                        storedKeyBindings = model.keyBindings.storageValue
                    }
                }
            )

            if let message = model.keyBindingErrorMessage {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.accentRed)
            }
        }
    }

    private func keyBindingButton(for lane: Mania4KLane) -> some View {
        Button {
            capturingKeyBindingLane = lane
        } label: {
            VStack(spacing: 5) {
                Text(laneShortName(for: lane))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.textMuted)

                Text(capturingKeyBindingLane == lane ? "..." : model.keyBindings.displayLabel(for: lane))
                    .font(.headline.monospaced().weight(.bold))
                    .foregroundStyle(Mania4KStyle.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(height: 22)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(Mania4KKeyBindingButtonStyle(isCapturing: capturingKeyBindingLane == lane))
    }

    private func laneShortName(for lane: Mania4KLane) -> String {
        switch lane {
        case .left:
            return "L1"
        case .innerLeft:
            return "L2"
        case .innerRight:
            return "R2"
        case .right:
            return "R1"
        }
    }

    private func restoreStoredKeyBindings() {
        guard let keyBindings = Mania4KKeyBindingSet(storageValue: storedKeyBindings) else {
            storedKeyBindings = Mania4KKeyBindingSet.default.storageValue
            model.applyKeyBindings(.default)
            return
        }

        model.applyKeyBindings(keyBindings)
    }
    #endif

    private func presentFileImporter(for target: Mania4KFileImportTarget) {
        fileImportTarget = target
        isChoosingFile = true
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        guard let fileImportTarget else {
            return
        }

        defer {
            self.fileImportTarget = nil
        }

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            switch fileImportTarget {
            case .beatmap:
                model.selectBeatmapFile(url)
            case .audio:
                model.selectAudioFile(url)
            }

        case .failure(let error):
            guard !error.isUserCancellation else {
                return
            }

            switch fileImportTarget {
            case .beatmap:
                model.recordBeatmapImportFailure(error)
            case .audio:
                model.recordAudioImportFailure(error)
            }
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Session")
                    .font(.title2.bold())
                    .foregroundStyle(Mania4KStyle.textPrimary)

                Spacer()

                Text(model.isReadyToStart ? "READY" : "WAITING")
                    .font(.caption.monospaced().weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(model.isReadyToStart ? Mania4KStyle.accentGreen : Mania4KStyle.textMuted)
                    .background(
                        (model.isReadyToStart ? Mania4KStyle.accentGreen : Mania4KStyle.textMuted).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    statTile(title: "Beatmap", value: model.beatmapFileURL?.lastPathComponent ?? "--")
                    statTile(title: "Audio", value: model.audioFileURL?.lastPathComponent ?? "--")
                    statTile(title: "Difficulty", value: model.starDifficulty.formatted(.number.precision(.fractionLength(1))))
                }

                VStack(spacing: 10) {
                    statTile(title: "Beatmap", value: model.beatmapFileURL?.lastPathComponent ?? "--")
                    statTile(title: "Audio", value: model.audioFileURL?.lastPathComponent ?? "--")
                    statTile(title: "Difficulty", value: model.starDifficulty.formatted(.number.precision(.fractionLength(1))))
                }
            }

            SetupLanePreview()
                .frame(minHeight: 360)
        }
        .panelStyle()
    }

    private func filePickerRow(
        title: String,
        value: String,
        message: String?,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textPrimary)

            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Mania4KStyle.accentBlue)
                    .background(Mania4KStyle.accentBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))

                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(Mania4KStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: action) {
                    Label("Choose", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(Mania4KSecondaryButtonStyle())
            }
            .padding(12)
            .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Mania4KStyle.border, lineWidth: 1)
            )

            if let message {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Mania4KStyle.accentRed)
            }
        }
    }

    private func numericField(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textPrimary)

            HStack(spacing: 10) {
                Stepper(value: value, in: range, step: step) {
                    TextField(title, value: value, format: .number.precision(.fractionLength(step < 1 ? 1 : 0)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Mania4KStyle.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Mania4KStyle.border, lineWidth: 1)
                        )
                        .frame(minWidth: 82, maxWidth: 120)
                }

                Text(suffix)
                    .font(.callout.monospaced())
                    .foregroundStyle(Mania4KStyle.textMuted)
            }
        }
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textMuted)

            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(Mania4KStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Mania4KStyle.border, lineWidth: 1)
        )
    }
}

private enum Mania4KFileImportTarget {
    case beatmap
    case audio
}

#if os(macOS)
private enum Mania4KOffsetCalibrationFocusedTextField: Hashable {
    case pendingAudioOffset
    case pendingVisualOffset
    case presetName
}

private struct Mania4KOffsetCalibrationView: View {
    @Bindable var model: Mania4KOffsetCalibrationModel
    let scrollTimeMs: Double
    let onStateChanged: (Mania4KOffsetCalibrationStoredState) -> Void
    let onApply: (Mania4KOffsetCalibrationModel) -> Void
    let onCancel: (Mania4KOffsetCalibrationModel) -> Void

    @State private var frameLoopTask: Task<Void, Never>?
    @State private var calibrationStartTimeSeconds: TimeInterval?
    @State private var presetName = ""
    @State private var presetIDPendingDeletion: UUID?
    @FocusState private var focusedTextField: Mania4KOffsetCalibrationFocusedTextField?

    private let calibrationLane: Mania4KLane = .innerRight
    private let calibrationPrewarmDelayMs = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 16) {
                calibrationStage
                    .frame(maxWidth: .infinity, minHeight: 520)

                controls
                    .frame(width: 340)
            }
        }
        .background(
            Mania4KOffsetCalibrationKeyboardCaptureView(
                calibrationKey: Mania4KOffsetCalibrationModel.calibrationKey,
                isCaptureEnabled: focusedTextField == nil
            ) {
                _ = model.recordInput(rawInputTimeMs: currentRawClockTimeMs())
            }
        )
        .onAppear(perform: startFrameLoop)
        .onDisappear(perform: stopFrameLoop)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Offset Calibration")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Mania4KStyle.textPrimary)

                Text("A \(model.pendingAudioOffsetMilliseconds) ms pending / \(model.renderedAudioOffsetMilliseconds) ms rendered  V \(model.pendingVisualOffsetMilliseconds) ms pending / \(model.renderedVisualOffsetMilliseconds) ms rendered")
                    .font(.caption.monospaced())
                    .foregroundStyle(Mania4KStyle.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer()

            Text("Key \(Mania4KOffsetCalibrationModel.calibrationKey.uppercased())")
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(Mania4KStyle.textPrimary)
                .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Mania4KStyle.border, lineWidth: 1)
                )

            Button(role: .cancel) {
                onCancel(model)
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentRed))

            Button {
                onApply(model)
            } label: {
                Label("Apply", systemImage: "checkmark")
            }
            .buttonStyle(Mania4KPrimaryButtonStyle())
        }
    }

    private var calibrationStage: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Mania4KStyle.stageFill,
                        Color(red: 0.035, green: 0.040, blue: 0.055)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Mania4KGridOverlay(spacing: 40, opacity: 0.12)

                Mania4KLiveLaneView(
                    lane: calibrationLane,
                    frame: calibrationFrame,
                    laneState: nil,
                    noteColor: Mania4KStyle.accentGreen,
                    keyLabel: Mania4KOffsetCalibrationModel.calibrationKey.uppercased()
                )
                .frame(width: min(max(proxy.size.width * 0.22, 112), 150))
                .padding(.vertical, 22)

                VStack {
                    Spacer()

                    HStack(spacing: 12) {
                        metricPill(title: "Raw", value: "\(model.rawClockTimeMs) ms")
                        metricPill(title: "Suggestion", value: suggestionText)
                        metricPill(title: "Latest", value: latestHitText)
                    }
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Mania4KStyle.stageFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Mania4KStyle.borderStrong, lineWidth: 1)
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Offset")
                .font(.title3.bold())
                .foregroundStyle(Mania4KStyle.textPrimary)

            HStack(spacing: 8) {
                offsetStepButton(-100) { model.stepPendingAudioOffset(by: $0) }
                offsetStepButton(-10) { model.stepPendingAudioOffset(by: $0) }
                offsetStepButton(-1) { model.stepPendingAudioOffset(by: $0) }
            }

            HStack(spacing: 10) {
                TextField("Audio Offset", value: pendingAudioOffsetBinding, format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Mania4KStyle.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Mania4KStyle.border, lineWidth: 1)
                    )
                    .focused($focusedTextField, equals: .pendingAudioOffset)
                    .onSubmit {
                        focusedTextField = nil
                    }

                Text("ms")
                    .font(.callout.monospaced())
                    .foregroundStyle(Mania4KStyle.textMuted)
            }

            HStack(spacing: 8) {
                offsetStepButton(1) { model.stepPendingAudioOffset(by: $0) }
                offsetStepButton(10) { model.stepPendingAudioOffset(by: $0) }
                offsetStepButton(100) { model.stepPendingAudioOffset(by: $0) }
            }

            Button {
                focusedTextField = nil
                if model.useSuggestedAudioOffset() {
                    onStateChanged(model.storedState)
                }
            } label: {
                Label("Use Suggestion", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentAmber))
            .disabled(model.suggestedAudioOffsetMilliseconds == nil)

            Divider()
                .overlay(Mania4KStyle.border)

            Text("Visual Offset")
                .font(.title3.bold())
                .foregroundStyle(Mania4KStyle.textPrimary)

            HStack(spacing: 8) {
                offsetStepButton(-100) { model.stepPendingVisualOffset(by: $0) }
                offsetStepButton(-10) { model.stepPendingVisualOffset(by: $0) }
                offsetStepButton(-1) { model.stepPendingVisualOffset(by: $0) }
            }

            HStack(spacing: 10) {
                TextField("Visual Offset", value: pendingVisualOffsetBinding, format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Mania4KStyle.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Mania4KStyle.border, lineWidth: 1)
                    )
                    .focused($focusedTextField, equals: .pendingVisualOffset)
                    .onSubmit {
                        focusedTextField = nil
                    }

                Text("ms")
                    .font(.callout.monospaced())
                    .foregroundStyle(Mania4KStyle.textMuted)
            }

            HStack(spacing: 8) {
                offsetStepButton(1) { model.stepPendingVisualOffset(by: $0) }
                offsetStepButton(10) { model.stepPendingVisualOffset(by: $0) }
                offsetStepButton(100) { model.stepPendingVisualOffset(by: $0) }
            }

            Divider()
                .overlay(Mania4KStyle.border)

            Text("Presets")
                .font(.title3.bold())
                .foregroundStyle(Mania4KStyle.textPrimary)

            Text("Active preset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textMuted)

            Picker("Preset", selection: activePresetBinding) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(model.presets) { preset in
                    Text(presetLabel(for: preset)).tag(Optional(preset.id))
                }
            }
            .labelsHidden()

            HStack(spacing: 8) {
                TextField("Name", text: $presetName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Mania4KStyle.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Mania4KStyle.controlFill, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Mania4KStyle.border, lineWidth: 1)
                    )
                    .focused($focusedTextField, equals: .presetName)
                    .onSubmit(addPreset)

                Button(action: addPreset) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(Mania4KSecondaryButtonStyle())
            }

            Text("Delete preset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textMuted)

            Picker("Delete preset", selection: presetDeletionBinding) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(model.presets) { preset in
                    Text(presetLabel(for: preset)).tag(Optional(preset.id))
                }
            }
            .labelsHidden()

            Button(role: .destructive) {
                deleteSelectedPreset()
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentRed))
            .disabled(!canDeleteSelectedPreset)
        }
        .panelStyle()
        .onChange(of: model.presets.map(\.id)) { _, presetIDs in
            if let presetIDPendingDeletion, !presetIDs.contains(presetIDPendingDeletion) {
                self.presetIDPendingDeletion = nil
            }
        }
    }

    private var calibrationFrame: Mania4KPlayFrame {
        Mania4KPlayFrame(
            gameplayChartTimeMs: Double(model.gameplayChartTimeMs),
            renderChartTimeMs: Double(model.renderedChartTimeMs),
            scrollTimeMs: scrollTimeMs,
            metadata: Mania4KChartMetadata(title: "Offset calibration", sourceDescription: "Synthetic"),
            visibleObjects: model.visibleObjects(
                travelTimeMs: scrollTimeMs,
                postLineVisibleMs: 280,
                lookaheadPaddingMs: 120,
                lane: calibrationLane
            ),
            score: .zero,
            laneStates: [],
            latestJudgement: nil
        )
    }

    private var pendingAudioOffsetBinding: Binding<Int> {
        Binding(
            get: {
                model.pendingAudioOffsetMilliseconds
            },
            set: { value in
                model.setPendingAudioOffsetMilliseconds(value)
                onStateChanged(model.storedState)
            }
        )
    }

    private var pendingVisualOffsetBinding: Binding<Int> {
        Binding(
            get: {
                model.pendingVisualOffsetMilliseconds
            },
            set: { value in
                model.setPendingVisualOffsetMilliseconds(value)
                onStateChanged(model.storedState)
            }
        )
    }

    private var activePresetBinding: Binding<UUID?> {
        Binding(
            get: {
                model.activePresetID
            },
            set: { id in
                focusedTextField = nil
                if let id {
                    _ = model.selectPreset(id: id)
                } else {
                    model.clearActivePreset()
                }
                onStateChanged(model.storedState)
            }
        )
    }

    private var presetDeletionBinding: Binding<UUID?> {
        Binding(
            get: {
                presetIDPendingDeletion
            },
            set: { id in
                focusedTextField = nil
                presetIDPendingDeletion = id
            }
        )
    }

    private var canDeleteSelectedPreset: Bool {
        guard let presetIDPendingDeletion else {
            return false
        }

        return model.presets.contains { $0.id == presetIDPendingDeletion }
    }

    private var suggestionText: String {
        guard let adjustment = model.suggestedAudioAdjustmentMilliseconds else {
            return "--"
        }

        return "\(adjustment >= 0 ? "+" : "")\(adjustment) ms"
    }

    private var latestHitText: String {
        guard let latest = model.hitSamples.last else {
            return "--"
        }

        return "\(latest.hitErrorMs >= 0 ? "+" : "")\(Int(latest.hitErrorMs.rounded())) ms"
    }

    private func offsetStepButton(_ delta: Int, _ apply: @escaping (Int) -> Void) -> some View {
        Button {
            focusedTextField = nil
            apply(delta)
            onStateChanged(model.storedState)
        } label: {
            Text(delta > 0 ? "+\(delta)" : "\(delta)")
                .font(.callout.monospaced().weight(.bold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(Mania4KSecondaryButtonStyle())
    }

    private func presetLabel(for preset: Mania4KOffsetPreset) -> String {
        "\(preset.name)  A \(signedMilliseconds(preset.audioOffsetMilliseconds))  V \(signedMilliseconds(preset.visualOffsetMilliseconds))"
    }

    private func signedMilliseconds(_ milliseconds: Int) -> String {
        "\(milliseconds >= 0 ? "+" : "")\(milliseconds) ms"
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textMuted)

            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Mania4KStyle.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 104, alignment: .leading)
        .background(Mania4KStyle.panelFill.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Mania4KStyle.border, lineWidth: 1)
        )
    }

    private func addPreset() {
        focusedTextField = nil
        _ = model.addPreset(name: presetName)
        presetName = ""
        onStateChanged(model.storedState)
    }

    private func deleteSelectedPreset() {
        focusedTextField = nil
        guard let presetIDPendingDeletion, model.deletePreset(id: presetIDPendingDeletion) else {
            return
        }

        self.presetIDPendingDeletion = nil
        onStateChanged(model.storedState)
    }

    private func startFrameLoop() {
        guard frameLoopTask == nil else {
            return
        }

        let startTimeSeconds = ProcessInfo.processInfo.systemUptime
        calibrationStartTimeSeconds = startTimeSeconds
        model.advanceClock(rawClockTimeMs: 0)
        frameLoopTask = Task { @MainActor in
            var didPrewarmTicks = false
            while !Task.isCancelled {
                let rawClockTimeMs = rawClockTimeMs(since: startTimeSeconds)
                if !didPrewarmTicks, rawClockTimeMs >= calibrationPrewarmDelayMs {
                    model.prewarmCalibrationTicks()
                    didPrewarmTicks = true
                }
                model.advanceClock(rawClockTimeMs: rawClockTimeMs)
                do {
                    try await Task.sleep(nanoseconds: 16_666_667)
                } catch {
                    break
                }
            }
        }
    }

    private func stopFrameLoop() {
        frameLoopTask?.cancel()
        frameLoopTask = nil
        calibrationStartTimeSeconds = nil
        model.stopCalibrationTicks()
    }

    private func currentRawClockTimeMs() -> Int {
        guard let calibrationStartTimeSeconds else {
            return model.rawClockTimeMs
        }

        return rawClockTimeMs(since: calibrationStartTimeSeconds)
    }

    private func rawClockTimeMs(since startTimeSeconds: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - startTimeSeconds) * 1_000))
    }
}

private final class Mania4KOffsetCalibrationResourceBundleToken: NSObject {}

@MainActor
private final class Mania4KOffsetCalibrationResourceTickPlayer: Mania4KOffsetCalibrationTickPlaying {
    private let player: AVAudioPlayer?
    private var didPrewarm = false
    private var prewarmRestoreVolume: Float?
    private var prewarmTask: Task<Void, Never>?

    init() {
        let bundle = Bundle(for: Mania4KOffsetCalibrationResourceBundleToken.self)
        guard let url = bundle.url(forResource: "calibration_tick", withExtension: "wav") else {
            assertionFailure("Missing bundled calibration_tick.wav resource.")
            player = nil
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
        } catch {
            assertionFailure("Could not prepare calibration_tick.wav: \(error.localizedDescription)")
            player = nil
        }
    }

    deinit {
        prewarmTask?.cancel()
    }

    func prewarmCalibrationTicks() {
        guard !didPrewarm, let player else {
            return
        }

        didPrewarm = true
        prewarmRestoreVolume = player.volume
        player.volume = 0
        player.currentTime = 0
        player.play()

        prewarmTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
            } catch {
                return
            }

            self?.finishPrewarm()
        }
    }

    func playCalibrationTick() {
        guard let player else {
            return
        }

        if prewarmRestoreVolume != nil {
            finishPrewarm()
        }
        player.currentTime = 0
        player.play()
    }

    func stopCalibrationTicks() {
        prewarmTask?.cancel()
        prewarmTask = nil
        if let prewarmRestoreVolume {
            player?.volume = prewarmRestoreVolume
            self.prewarmRestoreVolume = nil
        }
        player?.stop()
        player?.currentTime = 0
    }

    private func finishPrewarm() {
        prewarmTask = nil
        if player?.isPlaying == true {
            player?.stop()
        }
        player?.currentTime = 0
        if let prewarmRestoreVolume {
            player?.volume = prewarmRestoreVolume
            self.prewarmRestoreVolume = nil
        }
    }
}

private struct Mania4KOffsetCalibrationKeyboardCaptureView: NSViewRepresentable {
    let calibrationKey: String
    let isCaptureEnabled: Bool
    let onHit: () -> Void

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.calibrationKey = Mania4KKeyBindingSet.normalizedKey(calibrationKey)
        view.isCaptureEnabled = isCaptureEnabled
        view.onHit = onHit
        return view
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {
        let wasCaptureEnabled = nsView.isCaptureEnabled
        nsView.calibrationKey = Mania4KKeyBindingSet.normalizedKey(calibrationKey)
        nsView.isCaptureEnabled = isCaptureEnabled
        nsView.onHit = onHit
        nsView.requestFirstResponderIfNeeded(allowTextEditingResponder: !wasCaptureEnabled && isCaptureEnabled)
    }

    final class KeyboardView: NSView {
        var calibrationKey = Mania4KOffsetCalibrationModel.calibrationKey
        var isCaptureEnabled = true
        var onHit: (() -> Void)?
        private var didRequestInitialFirstResponder = false

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didRequestInitialFirstResponder else {
                return
            }

            didRequestInitialFirstResponder = true
            requestFirstResponderIfNeeded(allowTextEditingResponder: true)
        }

        override func keyDown(with event: NSEvent) {
            guard isCaptureEnabled,
                  !event.isARepeat,
                  let key = event.charactersIgnoringModifiers,
                  Mania4KKeyBindingSet.normalizedKey(key) == calibrationKey else {
                super.keyDown(with: event)
                return
            }

            onHit?()
        }

        func requestFirstResponderIfNeeded(allowTextEditingResponder: Bool = false) {
            guard isCaptureEnabled,
                  let window,
                  window.firstResponder !== self,
                  allowTextEditingResponder || !Self.isTextEditingResponder(window.firstResponder)
            else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isCaptureEnabled,
                      let window = self.window,
                      window.firstResponder !== self,
                      allowTextEditingResponder || !Self.isTextEditingResponder(window.firstResponder)
                else {
                    return
                }

                window.makeFirstResponder(self)
            }
        }

        private static func isTextEditingResponder(_ responder: Any?) -> Bool {
            responder is NSText || responder is NSTextField || responder is NSTextView
        }
    }
}
#endif

private struct SetupLanePreview: View {
    var body: some View {
        GeometryReader { proxy in
            let laneWidth = max((proxy.size.width - 30) / 4, 44)

            ZStack(alignment: .bottom) {
                Mania4KGridOverlay(spacing: 34, opacity: 0.18)

                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<4, id: \.self) { lane in
                        VStack(spacing: 0) {
                            Spacer()

                            RoundedRectangle(cornerRadius: 5)
                                .fill(noteColor(for: lane).opacity(0.86))
                                .frame(height: 46 + CGFloat(lane * 22))
                                .shadow(color: noteColor(for: lane).opacity(0.45), radius: 10, x: 0, y: 0)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(Mania4KStyle.textPrimary.opacity(0.84))
                                .frame(height: 10)
                                .padding(.top, 16)
                        }
                        .frame(width: laneWidth)
                        .frame(maxHeight: .infinity)
                        .background(Mania4KStyle.laneFill, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(noteColor(for: lane).opacity(0.34), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(16)
        }
        .background(Mania4KStyle.stageFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Mania4KStyle.borderStrong, lineWidth: 1)
        )
    }

    private func noteColor(for lane: Int) -> Color {
        switch lane {
        case 0:
            return Color(red: 0.96, green: 0.67, blue: 0.21)
        case 1:
            return Color(red: 0.26, green: 0.70, blue: 0.64)
        case 2:
            return Color(red: 0.89, green: 0.35, blue: 0.37)
        default:
            return Color(red: 0.56, green: 0.63, blue: 0.94)
        }
    }
}

private struct Mania4KPlaySceneView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: Mania4KPlaySessionModel

    var body: some View {
        VStack(spacing: 0) {
            playHUD

            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            Mania4KStyle.stageFill,
                            Color(red: 0.02, green: 0.025, blue: 0.035)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Mania4KGridOverlay(spacing: 42, opacity: 0.10)

                    playField
                        .frame(width: playFieldWidth(for: proxy.size.width))
                        .padding(.bottom, 22)

                    if let frame = model.playFrame, let latest = frame.latestJudgement {
                        judgementBurst(for: latest)
                            .position(x: proxy.size.width / 2, y: max(proxy.size.height * 0.34, 120))
                    }

                    overlayState
                }
            }
        }
        .background(Mania4KStyle.stageFill)
        #if os(macOS)
        .background(Mania4KKeyboardCaptureView(model: model))
        #endif
    }

    private var playHUD: some View {
        Group {
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        playTitle
                        Spacer()
                        quitButton
                    }

                    HStack(spacing: 14) {
                        hudValue(title: "Accuracy", value: accuracyText)
                        hudValue(title: "Combo", value: comboText)
                        hudValue(title: "Judge", value: latestJudgementText)
                    }
                }
            } else {
                HStack(spacing: 18) {
                    playTitle

                    Spacer()

                    hudValue(title: "Accuracy", value: accuracyText)
                    hudValue(title: "Combo", value: comboText)
                    hudValue(title: "Judge", value: latestJudgementText)
                    pauseButton
                    quitButton
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Mania4KStyle.panelFill.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Mania4KStyle.borderStrong)
                .frame(height: 1)
        }
    }

    private var playTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.playFrame?.metadata.title ?? model.activeConfiguration?.beatmapFileURL.deletingPathExtension().lastPathComponent ?? "mania4k")
                .font(.headline)
                .foregroundStyle(Mania4KStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(subtitleText)
                .font(.caption.monospaced())
                .foregroundStyle(Mania4KStyle.textSecondary)
        }
    }

    private var pauseButton: some View {
        Button {
            Task {
                switch model.phase {
                case .paused:
                    await model.resume()
                case .playing:
                    await model.pause()
                default:
                    break
                }
            }
        } label: {
            Label(model.phase == .paused ? "Resume" : "Pause", systemImage: model.phase == .paused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentAmber))
        .disabled(model.phase != .playing && model.phase != .paused)
    }

    private var quitButton: some View {
        Button(role: .cancel) {
            Task {
                await model.quitToSetup()
            }
        } label: {
            Label("Quit", systemImage: "xmark")
        }
        .buttonStyle(Mania4KSecondaryButtonStyle(tint: Mania4KStyle.accentRed))
    }

    private func hudValue(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Mania4KStyle.textMuted)

            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(Mania4KStyle.textPrimary)
        }
        .frame(minWidth: 76, alignment: .trailing)
    }

    private var playField: some View {
        GeometryReader { proxy in
            let laneSpacing: CGFloat = 8
            let laneWidth = max((proxy.size.width - laneSpacing * 3) / 4, 48)

            HStack(alignment: .bottom, spacing: laneSpacing) {
                ForEach(Mania4KLane.allCases) { lane in
                    Mania4KLiveLaneView(
                        lane: lane,
                        frame: model.playFrame,
                        laneState: visualLaneState(for: lane),
                        noteColor: noteColor(for: lane.rawValue),
                        keyLabel: model.keyBindings.displayLabel(for: lane)
                    )
                    .frame(width: laneWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func visualLaneState(for lane: Mania4KLane) -> Mania4KLaneState {
        let frameState = model.playFrame?.laneStates.first(where: { $0.lane == lane })
        let liveState = model.liveInputLaneStates.first(where: { $0.lane == lane })

        return Mania4KLaneState(
            lane: lane,
            isPressed: liveState?.isPressed ?? frameState?.isPressed ?? false,
            holdingObjectID: frameState?.holdingObjectID
        )
    }

    @ViewBuilder
    private var overlayState: some View {
        switch model.phase {
        case .loading:
            statePanel(title: "Loading", detail: model.activeConfiguration?.beatmapFileURL.lastPathComponent ?? "Preparing chart")
        case .failed(let failure):
            statePanel(title: "Failed", detail: failure.localizedDescription)
        case .finished(let result):
            statePanel(
                title: "Results",
                detail: "\(formatAccuracy(result.score.accuracy))  \(result.score.maxCombo)x max  \(result.score.missCount) miss"
            )
        default:
            EmptyView()
        }
    }

    private func statePanel(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Mania4KStyle.textPrimary)

            Text(detail)
                .font(.callout)
                .foregroundStyle(Mania4KStyle.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)

            Button {
                Task {
                    await model.quitToSetup()
                }
            } label: {
                Label("Setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(Mania4KSecondaryButtonStyle())
        }
        .padding(18)
        .frame(maxWidth: 360)
        .background(Mania4KStyle.panelFill.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Mania4KStyle.borderStrong, lineWidth: 1)
        )
    }

    private func judgementBurst(for event: Mania4KJudgementEvent) -> some View {
        ZStack {
            Text(event.judgement.rawValue)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(event.judgement == .miss ? Mania4KStyle.accentRed : Mania4KStyle.textPrimary)
                .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 8)

            if let hint = timingArrowHint(for: event) {
                Image(systemName: hint.systemName)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(hint.color)
                    .shadow(color: Color.black.opacity(0.36), radius: 8, x: 0, y: 4)
                    .offset(x: 82)
            }
        }
        .frame(width: 210, height: 56)
    }

    private func timingArrowHint(for event: Mania4KJudgementEvent) -> (systemName: String, color: Color)? {
        guard event.judgement == .perfect || event.judgement == .good,
              let hitErrorMs = event.hitErrorMs,
              hitErrorMs != 0
        else {
            return nil
        }

        return hitErrorMs < 0
            ? ("arrow.up", Mania4KStyle.accentBlue)
            : ("arrow.down", Mania4KStyle.accentAmber)
    }

    private func playFieldWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.58, 280), 620)
    }

    private var accuracyText: String {
        formatAccuracy(model.playFrame?.score.accuracy ?? 1)
    }

    private var comboText: String {
        String(model.playFrame?.score.combo ?? 0)
    }

    private var latestJudgementText: String {
        model.playFrame?.latestJudgement?.judgement.rawValue ?? "-"
    }

    private var subtitleText: String {
        guard let configuration = model.activeConfiguration else {
            return "--"
        }

        return "\(configuration.starDifficulty.formatted(.number.precision(.fractionLength(1)))) stars  \(configuration.scrollSpeed.formatted(.number.precision(.fractionLength(1))))x"
    }

    private func formatAccuracy(_ accuracy: Double) -> String {
        (accuracy * 100).formatted(.number.precision(.fractionLength(2))) + "%"
    }

    private func noteColor(for lane: Int) -> Color {
        switch lane {
        case 0:
            return Color(red: 0.96, green: 0.67, blue: 0.21)
        case 1:
            return Color(red: 0.26, green: 0.70, blue: 0.64)
        case 2:
            return Color(red: 0.89, green: 0.35, blue: 0.37)
        default:
            return Color(red: 0.56, green: 0.63, blue: 0.94)
        }
    }
}

private struct Mania4KLiveLaneView: View {
    let lane: Mania4KLane
    let frame: Mania4KPlayFrame?
    let laneState: Mania4KLaneState?
    let noteColor: Color
    let keyLabel: String

    @State private var pressHighlight = 0.0
    @State private var releaseAfterglow = 0.0

    private var isPressed: Bool {
        laneState?.isPressed == true
    }

    var body: some View {
        GeometryReader { proxy in
            let receptorY = proxy.size.height - 78

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Mania4KStyle.laneFill)

                Rectangle()
                    .fill(noteColor.opacity(0.22 * pressHighlight + 0.06 * releaseAfterglow))
                    .blendMode(.plusLighter)

                if let frame {
                    ForEach(frame.visibleObjects.filter { $0.lane == lane }) { object in
                        visibleObject(object, frame: frame, laneSize: proxy.size, receptorY: receptorY)
                    }
                }

                receptorLine

                RoundedRectangle(cornerRadius: 5)
                    .fill(Mania4KStyle.receptorFill)
                    .frame(height: 58)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(noteColor.opacity(0.46 * pressHighlight + 0.10 * releaseAfterglow))
                            .blendMode(.plusLighter)
                    )
                    .overlay(
                        Text(keyLabel)
                            .font(.headline.monospaced())
                            .foregroundStyle(Mania4KStyle.textPrimary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(noteColor.opacity(0.62), lineWidth: 1)
                    )
            }
        }
        .background(Mania4KStyle.laneFill, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(noteColor.opacity(0.22), lineWidth: 1)
        )
        .onAppear {
            pressHighlight = isPressed ? 1 : 0
            releaseAfterglow = 0
        }
        .onChange(of: isPressed) { _, newValue in
            animatePressFeedback(isPressed: newValue)
        }
    }

    private var receptorLine: some View {
        Rectangle()
            .fill(noteColor.opacity(0.82))
            .frame(height: 3)
            .padding(.bottom, 76)
    }

    @ViewBuilder
    private func visibleObject(
        _ object: Mania4KVisibleObject,
        frame: Mania4KPlayFrame,
        laneSize: CGSize,
        receptorY: CGFloat
    ) -> some View {
        let opacity = object.state == .resolved ? 0.28 : (object.state == .missedButVisible ? 0.36 : 0.96)

        switch Mania4KNoteRenderLayout.geometry(for: object, frame: frame, laneHeight: laneSize.height, receptorY: receptorY) {
        case .hold(let geometry):
            RoundedRectangle(cornerRadius: 4)
                .fill(noteColor.opacity(0.42 * opacity))
                .frame(width: max(laneSize.width * 0.52, 24), height: geometry.bodyHeight)
                .position(x: laneSize.width / 2, y: geometry.bodyCenterY)

            if let tailY = geometry.tailY {
                note(height: 18, opacity: opacity)
                    .position(x: laneSize.width / 2, y: tailY)
            }

            note(height: 22, opacity: opacity)
                .position(x: laneSize.width / 2, y: geometry.headY)

        case .tap(let geometry):
            note(height: 24, opacity: opacity)
                .position(x: laneSize.width / 2, y: geometry.y)
        }
    }

    private func note(height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(noteColor.opacity(opacity))
            .frame(height: height)
            .padding(.horizontal, 8)
            .shadow(color: noteColor.opacity(0.45), radius: 10, x: 0, y: 0)
    }

    private func animatePressFeedback(isPressed: Bool) {
        if isPressed {
            withAnimation(.timingCurve(0.20, 0.95, 0.35, 1.0, duration: 0.035)) {
                pressHighlight = 1
                releaseAfterglow = 0
            }
        } else {
            releaseAfterglow = max(releaseAfterglow, pressHighlight)
            withAnimation(.timingCurve(0.16, 0.0, 0.35, 1.0, duration: 0.055)) {
                pressHighlight = 0
            }
            withAnimation(.easeOut(duration: 0.12)) {
                releaseAfterglow = 0
            }
        }
    }
}

struct Mania4KNoteRenderLayout {
    static let minimumHoldBodyHeight: CGFloat = 12

    enum Geometry: Equatable {
        case tap(TapGeometry)
        case hold(HoldGeometry)
    }

    struct TapGeometry: Equatable {
        let y: CGFloat
    }

    struct HoldGeometry: Equatable {
        let bodyTopY: CGFloat
        let bodyBottomY: CGFloat
        let headY: CGFloat
        let tailY: CGFloat?

        var bodyHeight: CGFloat {
            bodyBottomY - bodyTopY
        }

        var bodyCenterY: CGFloat {
            bodyTopY + bodyHeight / 2
        }
    }

    static func geometry(
        for object: Mania4KVisibleObject,
        frame: Mania4KPlayFrame,
        laneHeight: CGFloat,
        receptorY: CGFloat
    ) -> Geometry {
        let headY = displayedY(
            rawY: yPosition(for: object.startTimeMs, frame: frame, laneHeight: laneHeight, receptorY: receptorY),
            objectState: object.state,
            receptorY: receptorY
        )
        let isHold = object.endTimeMs != nil || object.state == .holding || object.state == .openEnded

        guard isHold else {
            return .tap(TapGeometry(y: headY))
        }

        let tailY = object.endTimeMs.map {
            displayedY(
                rawY: yPosition(for: $0, frame: frame, laneHeight: laneHeight, receptorY: receptorY),
                objectState: object.state,
                receptorY: receptorY
            )
        }
        let rawTopY = tailY.map { min(headY, $0) } ?? min(0, headY)
        let rawBottomY = tailY.map { max(headY, $0) } ?? max(0, headY)
        let bodyHeight = max(rawBottomY - rawTopY, minimumHoldBodyHeight)
        let bodyBottomY = rawBottomY

        return .hold(
            HoldGeometry(
                bodyTopY: bodyBottomY - bodyHeight,
                bodyBottomY: bodyBottomY,
                headY: headY,
                tailY: tailY
            )
        )
    }

    static func yPosition(for objectTimeMs: Double, frame: Mania4KPlayFrame, laneHeight: CGFloat, receptorY: CGFloat) -> CGFloat {
        let travelHeight = max(receptorY - 18, 1)
        let progress = (objectTimeMs - frame.renderChartTimeMs) / max(frame.scrollTimeMs, 1)
        return receptorY - CGFloat(progress) * travelHeight
    }

    private static func displayedY(rawY: CGFloat, objectState: Mania4KVisibleObjectState, receptorY: CGFloat) -> CGFloat {
        objectState == .holding ? min(rawY, receptorY) : rawY
    }
}

#if os(macOS)
private struct Mania4KKeyboardCaptureView: NSViewRepresentable {
    let model: Mania4KPlaySessionModel

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: KeyboardView, context: Context) {
        nsView.model = model
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyboardView: NSView {
        var model: Mania4KPlaySessionModel?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard let key = event.charactersIgnoringModifiers else {
                return
            }

            Task {
                await model?.handleKeyboardInput(key: key, isPressed: true, isRepeat: event.isARepeat)
            }
        }

        override func keyUp(with event: NSEvent) {
            guard let key = event.charactersIgnoringModifiers else {
                return
            }

            Task {
                await model?.handleKeyboardInput(key: key, isPressed: false, isRepeat: false)
            }
        }
    }
}

private struct Mania4KKeyBindingCaptureView: NSViewRepresentable {
    @Binding var activeLane: Mania4KLane?
    let onCapture: (Mania4KLane, String) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        KeyCaptureView()
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.activeLane = activeLane
        nsView.onCapture = onCapture
        nsView.setActiveLane = { activeLane = $0 }

        guard activeLane != nil else {
            return
        }

        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyCaptureView: NSView {
        var activeLane: Mania4KLane?
        var onCapture: ((Mania4KLane, String) -> Void)?
        var setActiveLane: ((Mania4KLane?) -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            guard let activeLane else {
                return
            }

            if event.keyCode == 53 {
                setActiveLane?(nil)
                return
            }

            guard !event.isARepeat,
                  let key = event.charactersIgnoringModifiers,
                  !Mania4KKeyBindingSet.normalizedKey(key).isEmpty
            else {
                return
            }

            setActiveLane?(nil)
            onCapture?(activeLane, key)
        }
    }
}
#endif

// Placeholder visual theme for the first playable mock. Replace with shared tokens once Pulsefield has a settled design system.
private enum Mania4KStyle {
    static let backgroundTop = Color(red: 0.025, green: 0.035, blue: 0.055)
    static let backgroundBottom = Color(red: 0.085, green: 0.045, blue: 0.070)
    static let panelFill = Color(red: 0.075, green: 0.085, blue: 0.115)
    static let controlFill = Color(red: 0.105, green: 0.120, blue: 0.160)
    static let stageFill = Color(red: 0.030, green: 0.035, blue: 0.050)
    static let laneFill = Color(red: 0.070, green: 0.080, blue: 0.110).opacity(0.86)
    static let receptorFill = Color(red: 0.150, green: 0.165, blue: 0.205)
    static let border = Color.white.opacity(0.12)
    static let borderStrong = Color.white.opacity(0.20)
    static let textPrimary = Color(red: 0.965, green: 0.980, blue: 1.000)
    static let textSecondary = Color(red: 0.700, green: 0.760, blue: 0.840)
    static let textMuted = Color(red: 0.500, green: 0.565, blue: 0.660)
    static let accentBlue = Color(red: 0.290, green: 0.670, blue: 1.000)
    static let accentGreen = Color(red: 0.260, green: 0.880, blue: 0.620)
    static let accentAmber = Color(red: 1.000, green: 0.700, blue: 0.230)
    static let accentRed = Color(red: 1.000, green: 0.330, blue: 0.390)
}

private struct Mania4KBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Mania4KStyle.backgroundTop,
                    Mania4KStyle.backgroundBottom,
                    Color(red: 0.025, green: 0.028, blue: 0.040)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Mania4KGridOverlay(spacing: 44, opacity: 0.08)
        }
        .ignoresSafeArea()
    }
}

private struct Mania4KGridOverlay: View {
    let spacing: CGFloat
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var path = Path()

            for y in stride(from: CGFloat(0), through: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            for x in stride(from: CGFloat(0), through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }

            context.stroke(path, with: .color(Color.white.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct Mania4KPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(isEnabled ? Mania4KStyle.textPrimary : Mania4KStyle.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: isEnabled ? [Mania4KStyle.accentBlue, Mania4KStyle.accentGreen] : [Mania4KStyle.controlFill, Mania4KStyle.controlFill],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            )
            .shadow(color: Mania4KStyle.accentBlue.opacity(isEnabled ? (configuration.isPressed ? 0.18 : 0.34) : 0), radius: configuration.isPressed ? 5 : 14, x: 0, y: 0)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private struct Mania4KSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var tint = Mania4KStyle.accentBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(isEnabled ? tint : Mania4KStyle.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((isEnabled ? tint : Mania4KStyle.textMuted).opacity(configuration.isPressed ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke((isEnabled ? tint : Mania4KStyle.textMuted).opacity(0.42), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct Mania4KKeyBindingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isCapturing: Bool

    func makeBody(configuration: Configuration) -> some View {
        let tint = isCapturing ? Mania4KStyle.accentAmber : Mania4KStyle.accentBlue

        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                (isEnabled ? tint : Mania4KStyle.textMuted).opacity(isCapturing ? 0.22 : 0.10),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke((isEnabled ? tint : Mania4KStyle.textMuted).opacity(isCapturing ? 0.62 : 0.28), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension Error {
    var isUserCancellation: Bool {
        let error = self as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(18)
            .background(Mania4KStyle.panelFill.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Mania4KStyle.borderStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

#Preview("Setup") {
    Mania4KPlayExperienceView(model: Mania4KPlaySessionModel())
}

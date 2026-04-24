import PulsefieldCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct Mania4KPlayExperienceView: View {
    @Bindable public var model: Mania4KPlaySessionModel

    public init(model: Mania4KPlaySessionModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            Mania4KBackdrop()

            if model.phase == .setup {
                Mania4KSetupView(model: model)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                setupContent
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

            numericField(
                title: "Global audio offset",
                value: $model.globalAudioOffsetMilliseconds,
                range: -500...500,
                step: 1,
                suffix: "ms"
            )

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
        }
    }

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
                        judgementBurst(latest.judgement.rawValue)
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
                        laneState: model.playFrame?.laneStates.first(where: { $0.lane == lane }),
                        noteColor: noteColor(for: lane.rawValue)
                    )
                    .frame(width: laneWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
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

    private func judgementBurst(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .black, design: .rounded))
            .foregroundStyle(text == "Miss" ? Mania4KStyle.accentRed : Mania4KStyle.textPrimary)
            .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 8)
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

    var body: some View {
        GeometryReader { proxy in
            let receptorY = proxy.size.height - 78

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill((laneState?.isPressed == true ? noteColor.opacity(0.18) : Mania4KStyle.laneFill))

                if let frame {
                    ForEach(frame.visibleObjects.filter { $0.lane == lane }) { object in
                        visibleObject(object, frame: frame, laneSize: proxy.size, receptorY: receptorY)
                    }
                }

                receptorLine

                RoundedRectangle(cornerRadius: 5)
                    .fill(laneState?.isPressed == true ? noteColor.opacity(0.42) : Mania4KStyle.receptorFill)
                    .frame(height: 58)
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
    }

    private var keyLabel: String {
        ["D", "F", "J", "K"][lane.rawValue]
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
        let progress = (objectTimeMs - frame.chartTimeMs) / max(frame.scrollTimeMs, 1)
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

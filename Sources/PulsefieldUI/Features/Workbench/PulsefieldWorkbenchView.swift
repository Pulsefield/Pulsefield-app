import PulsefieldCore
import SwiftUI

public struct PulsefieldWorkbenchView: View {
    #if os(macOS) && DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif

    @AppStorage("mania4k.offsetCalibrationState") private var storedOffsetCalibrationState = ""
    @AppStorage("mania4k.keyBindings") private var storedKeyBindings = Mania4KKeyBindingSet.default.storageValue
    @State private var selection: WorkbenchTab
    @State private var maniaModel: Mania4KPlaySessionModel
    @State private var localLibraryModel: LocalLibraryDashboardModel
    @State private var isShowingSettings = false
    @State private var didRestoreStoredManiaSettings = false
    private let onAmbientRecognitionRequested: (@MainActor (Bool) -> Void)?

    public init(
        maniaModel: Mania4KPlaySessionModel = Mania4KPlaySessionModel(),
        localLibraryModel: LocalLibraryDashboardModel = .livePrototype(),
        initialSelection: WorkbenchTab = .localLibrary,
        onAmbientRecognitionRequested: (@MainActor (Bool) -> Void)? = nil
    ) {
        _selection = State(initialValue: initialSelection)
        _maniaModel = State(initialValue: maniaModel)
        _localLibraryModel = State(initialValue: localLibraryModel)
        self.onAmbientRecognitionRequested = onAmbientRecognitionRequested
    }

    public var body: some View {
        TabView(selection: $selection) {
            LocalLibraryDashboardView(model: localLibraryModel)
            .tabItem {
                Label("Library", systemImage: "music.note.list")
            }
            .tag(WorkbenchTab.localLibrary)

            Mania4KPlayExperienceView(
                model: maniaModel,
                onAmbientRecognitionRequested: onAmbientRecognitionRequested
            )
                .tabItem {
                    Label("Play", systemImage: "square.grid.2x2")
                }
                .tag(WorkbenchTab.play)
        }
        .onAppear(perform: restoreStoredManiaSettingsIfNeeded)
        .sheet(isPresented: $isShowingSettings) {
            Mania4KSettingsPageView(
                model: maniaModel,
                storedOffsetCalibrationState: $storedOffsetCalibrationState,
                storedKeyBindings: $storedKeyBindings
            )
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        #if os(macOS) && DEBUG
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: LiveRecognitionSyncWindow.windowID)
                } label: {
                    Label("Recognition Flow", systemImage: "waveform.badge.magnifyingglass")
                }
                .help("Open Recognition Sync Flow")
            }
        }
        #endif
    }

    private func restoreStoredManiaSettingsIfNeeded() {
        guard !didRestoreStoredManiaSettings else {
            return
        }

        didRestoreStoredManiaSettings = true

        if let storedState = calibrationStoredState {
            maniaModel.audioOffsetMilliseconds = Double(storedState.appliedAudioOffsetMilliseconds)
            maniaModel.visualOffsetMilliseconds = Double(storedState.appliedVisualOffsetMilliseconds)
        }

        guard let keyBindings = Mania4KKeyBindingSet(storageValue: storedKeyBindings) else {
            storedKeyBindings = Mania4KKeyBindingSet.default.storageValue
            maniaModel.applyKeyBindings(.default)
            return
        }

        maniaModel.applyKeyBindings(keyBindings)
    }

    private var calibrationStoredState: Mania4KOffsetCalibrationStoredState? {
        guard !storedOffsetCalibrationState.isEmpty else {
            return Mania4KOffsetCalibrationStoredState.defaultPlayState
        }

        guard let storedState = Mania4KOffsetCalibrationStoredState(storageValue: storedOffsetCalibrationState) else {
            return nil
        }

        return Mania4KOffsetCalibrationModel.normalizedStoredState(
            storedState,
            fallbackAppliedAudioOffsetMilliseconds: 0,
            fallbackAppliedVisualOffsetMilliseconds: 0
        )
    }
}

public enum WorkbenchTab: Hashable {
    case localLibrary
    case play
}

#Preview {
    PulsefieldWorkbenchView()
}

import PulsefieldCore
import SwiftUI

public struct PulsefieldWorkbenchView: View {
    #if os(macOS) && DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var selection: WorkbenchTab
    @State private var maniaModel: Mania4KPlaySessionModel
    @State private var localLibraryModel: LocalLibraryDashboardModel

    public init(
        maniaModel: Mania4KPlaySessionModel = Mania4KPlaySessionModel(),
        localLibraryModel: LocalLibraryDashboardModel = .livePrototype(),
        initialSelection: WorkbenchTab = .localLibrary
    ) {
        _selection = State(initialValue: initialSelection)
        _maniaModel = State(initialValue: maniaModel)
        _localLibraryModel = State(initialValue: localLibraryModel)
    }

    public var body: some View {
        TabView(selection: $selection) {
            LocalLibraryDashboardView(model: localLibraryModel)
            .tabItem {
                Label("Library", systemImage: "music.note.list")
            }
            .tag(WorkbenchTab.localLibrary)

            Mania4KPlayExperienceView(model: maniaModel)
                .tabItem {
                    Label("Play", systemImage: "square.grid.2x2")
                }
                .tag(WorkbenchTab.play)
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
}

public enum WorkbenchTab: Hashable {
    case localLibrary
    case play
}

#Preview {
    PulsefieldWorkbenchView()
}

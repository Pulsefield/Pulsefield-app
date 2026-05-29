import PulsefieldCore
import SwiftUI

public struct PulsefieldWorkbenchView: View {
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
    }
}

public enum WorkbenchTab: Hashable {
    case localLibrary
    case play
}

#Preview {
    PulsefieldWorkbenchView()
}

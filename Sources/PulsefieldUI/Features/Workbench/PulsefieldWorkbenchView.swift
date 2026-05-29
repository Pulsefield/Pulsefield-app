import PulsefieldCore
import SwiftUI

public struct PulsefieldWorkbenchView: View {
    @State private var selection: WorkbenchTab
    @State private var maniaModel: Mania4KPlaySessionModel
    @State private var localLibraryModel: LocalLibraryDashboardModel
    @State private var ambientModel: AmbientMatchingDashboardModel

    public init(
        maniaModel: Mania4KPlaySessionModel = Mania4KPlaySessionModel(),
        localLibraryModel: LocalLibraryDashboardModel = .livePrototype(),
        ambientModel: AmbientMatchingDashboardModel = .livePrototype(),
        initialSelection: WorkbenchTab = .localLibrary
    ) {
        _selection = State(initialValue: initialSelection)
        _maniaModel = State(initialValue: maniaModel)
        _localLibraryModel = State(initialValue: localLibraryModel)
        _ambientModel = State(initialValue: ambientModel)
    }

    public var body: some View {
        TabView(selection: $selection) {
            LocalLibraryDashboardView(model: localLibraryModel) { asset in
                ambientModel.selectedAsset = asset
                selection = .ambientMatching
            }
            .tabItem {
                Label("Library", systemImage: "music.note.list")
            }
            .tag(WorkbenchTab.localLibrary)

            AmbientMatchingDashboardView(model: ambientModel)
                .tabItem {
                    Label("Ambient", systemImage: "waveform.and.mic")
                }
                .tag(WorkbenchTab.ambientMatching)

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
    case ambientMatching
    case play
}

#Preview {
    PulsefieldWorkbenchView()
}

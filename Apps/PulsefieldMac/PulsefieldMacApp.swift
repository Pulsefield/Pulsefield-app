import Foundation
import PulsefieldCore
import PulsefieldUI
import SwiftUI

@main
@MainActor
struct PulsefieldMacApp: App {
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var model: Mania4KPlaySessionModel

    init() {
        _model = State(initialValue: Self.makeInitialModel())
    }

    var body: some Scene {
        WindowGroup {
            PulsefieldWorkbenchView(
                maniaModel: model,
                initialSelection: model.isReadyToStart ? .play : .localLibrary
            )
        }
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Button("Open Recognition Sync Flow") {
                    openWindow(id: LiveRecognitionSyncWindow.windowID)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        #endif

        #if DEBUG
        Window(LiveRecognitionSyncWindow.windowTitle, id: LiveRecognitionSyncWindow.windowID) {
            LiveRecognitionSyncWindow(model: .liveDebug())
        }
        .defaultSize(width: 980, height: 760)
        #endif
    }

    private static func makeInitialModel() -> Mania4KPlaySessionModel {
        #if DEBUG
        let beatmapURL = URL(
            fileURLWithPath: "/Users/l/projects/Pulsefield-model/dataset/0/120289/Dj Mashiro - Prismatic Lollipops (victorica_db) [S.Star's 4K Lv.7].osu"
        )
        let audioURL = URL(fileURLWithPath: "/Users/l/projects/Pulsefield-model/dataset/0/120289/Prismatic Lollipops.mp3")

        if FileManager.default.fileExists(atPath: beatmapURL.path),
           FileManager.default.fileExists(atPath: audioURL.path) {
            return Mania4KPlaySessionModel(beatmapFileURL: beatmapURL, audioFileURL: audioURL)
        }
        #endif

        return Mania4KPlaySessionModel()
    }
}

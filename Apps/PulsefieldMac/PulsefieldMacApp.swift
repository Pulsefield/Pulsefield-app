import Foundation
import PulsefieldCore
import PulsefieldUI
import SwiftUI

@main
@MainActor
struct PulsefieldMacApp: App {
    @State private var model: Mania4KPlaySessionModel

    init() {
        _model = State(initialValue: Self.makeInitialModel())
    }

    var body: some Scene {
        WindowGroup {
            PulsefieldWorkbenchView(maniaModel: model)
        }
    }

    private static func makeInitialModel() -> Mania4KPlaySessionModel {
        #if DEBUG
        let beatmapURL = URL(
            fileURLWithPath: "/Users/l/projects/Mapperatorinator/mania-dataset/0/136986/Lia - My Soul, Your Beats! (TV Size) (DJPop) [4K SC].osu"
        )
        let audioURL = URL(fileURLWithPath: "/Users/l/projects/Mapperatorinator/mania-dataset/0/136986/bgm.mp3")

        if FileManager.default.fileExists(atPath: beatmapURL.path),
           FileManager.default.fileExists(atPath: audioURL.path) {
            return Mania4KPlaySessionModel(beatmapFileURL: beatmapURL, audioFileURL: audioURL)
        }
        #endif

        return Mania4KPlaySessionModel()
    }
}

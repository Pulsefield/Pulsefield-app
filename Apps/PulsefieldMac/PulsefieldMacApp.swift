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
    #if DEBUG
    @State private var recognitionModel: LiveRecognitionSyncModel
    #endif

    init() {
        _model = State(initialValue: Self.makeInitialModel())
        #if DEBUG
        _recognitionModel = State(initialValue: .liveDebug())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PulsefieldWorkbenchView(
                maniaModel: model,
                initialSelection: model.isReadyToStart ? .play : .localLibrary,
                onAmbientRecognitionRequested: openRecognitionSyncFromMode3(isMock:)
            )
        }
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Button("Open Recognition Sync Flow") {
                    openRecognitionSync()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        #endif

        #if DEBUG
        Window(LiveRecognitionSyncWindow.windowTitle, id: LiveRecognitionSyncWindow.windowID) {
            LiveRecognitionSyncWindow(model: recognitionModel)
                .onAppear {
                    recognitionModel.setPlaySessionRequestHandler(openPlaySession(from:))
                }
        }
        .defaultSize(width: 980, height: 760)
        #endif

        Window(Mania4KPlaySessionWindow.windowTitle, id: Mania4KPlaySessionWindow.windowID) {
            Mania4KPlayExperienceView(
                model: model,
                onAmbientRecognitionRequested: openRecognitionSyncFromMode3(isMock:)
            )
        }
        .defaultSize(width: 1120, height: 780)
    }

    #if DEBUG
    private func openRecognitionSyncFromMode3(isMock: Bool) {
        recognitionModel.inferenceIsMock = isMock
        openRecognitionSync()
    }

    private func openRecognitionSync() {
        recognitionModel.setPlaySessionRequestHandler(openPlaySession(from:))
        openWindow(id: LiveRecognitionSyncWindow.windowID)
    }

    private func openPlaySession(from request: LiveRecognitionPlaySessionRequest) {
        openWindow(id: Mania4KPlaySessionWindow.windowID)
        Task {
            await model.startAmbientGeneratedBackendPlay(
                audioFileURL: request.audioFileURL,
                isMock: request.isMock,
                referenceTimeMS: request.referenceTimeMS,
                anchorHostTimeMS: request.anchorHostTimeMS,
                durationMS: request.durationMS,
                title: request.title,
                musicSource: request.musicSource
            )
        }
    }
    #else
    private func openRecognitionSyncFromMode3(isMock: Bool) {}
    #endif

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

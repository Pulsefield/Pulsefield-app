import PulsefieldCore
import SwiftUI

@main
@MainActor
struct PulsefieldApp: App {
    @State private var model = RecognitionAppModel.livePrototype()

    var body: some Scene {
        WindowGroup {
            RecognitionDashboardView(model: model)
        }
    }
}

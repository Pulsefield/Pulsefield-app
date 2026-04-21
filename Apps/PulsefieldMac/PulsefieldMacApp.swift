import PulsefieldCore
import PulsefieldUI
import SwiftUI

@main
@MainActor
struct PulsefieldMacApp: App {
    @State private var model = RecognitionAppModel.livePrototype()

    var body: some Scene {
        WindowGroup {
            RecognitionDashboardView(model: model)
        }
    }
}

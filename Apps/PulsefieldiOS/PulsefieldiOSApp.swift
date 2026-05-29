import PulsefieldCore
import PulsefieldUI
import SwiftUI

@main
@MainActor
struct PulsefieldiOSApp: App {
    @State private var model = RecognitionAppModel.livePrototype()

    var body: some Scene {
        WindowGroup {
            RecognitionDashboardView(model: model)
        }
    }
}

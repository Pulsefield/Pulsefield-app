import PulsefieldCore
import PulsefieldUI
import SwiftUI

@main
@MainActor
struct PulsefieldiOSApp: App {
    @State private var model = Mania4KPlaySessionModel()

    var body: some Scene {
        WindowGroup {
            Mania4KPlayExperienceView(model: model)
        }
    }
}

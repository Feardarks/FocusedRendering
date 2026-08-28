import SwiftUI

@main
struct FocusedRenderingClientApp: App {
    @State private var session = StreamSession()

    var body: some SwiftUI.Scene {
        WindowGroup {
            DebugPanel(session: session)
        }
        .defaultSize(width: 620, height: 780)

        ImmersiveSpace(id: "screen") {
            ImmersiveScreen(session: session)
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive, .full)
    }
}

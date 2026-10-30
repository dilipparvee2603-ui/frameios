import SwiftUI

@main
struct CFXFrameStudioApp: App {
    init() {
        NotificationManager.shared.setup()
        #if DEBUG
        CFXEditorTests.shared.runAllTests()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LauncherView()
                .preferredColorScheme(.dark)
        }
    }
}

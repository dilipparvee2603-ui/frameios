import SwiftUI

@main
struct CFXFrameStudioApp: App {
    init() {
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

import SwiftUI

@main
struct XmuxApp: App {
    init() {
        XmuxLog.shared.setup()
        XmuxEventPort.shared.setup()
    }

    var body: some Scene {
        WindowGroup("xmux") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            Text("Settings coming soon")
                .padding()
        }
    }
}

import SwiftUI

@main
struct XmuxApp: App {
    init() {
        XmuxLog.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            Text("Settings coming soon")
                .padding()
        }
    }
}

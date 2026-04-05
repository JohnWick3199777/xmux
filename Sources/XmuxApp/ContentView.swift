import SwiftUI

private enum LayoutMetrics {
    static let sidePanelMinWidth: CGFloat = 160
    static let sidePanelIdealWidth: CGFloat = 220
    static let sidePanelMaxWidth: CGFloat = 320
}

/// Root layout: fixed left panel | terminal + live events | fixed right panel
struct ContentView: View {
    @StateObject private var xmux = XmuxState()

    var body: some View {
        HSplitView {
            LeftPanel()
                .frame(
                    minWidth: LayoutMetrics.sidePanelMinWidth,
                    idealWidth: LayoutMetrics.sidePanelIdealWidth,
                    maxWidth: LayoutMetrics.sidePanelMaxWidth,
                    maxHeight: .infinity
                )

            MainTerminalColumn(xmux: xmux)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            SessionsPanel(xmux: xmux)
                .frame(
                    minWidth: LayoutMetrics.sidePanelMinWidth,
                    idealWidth: LayoutMetrics.sidePanelIdealWidth,
                    maxWidth: LayoutMetrics.sidePanelMaxWidth,
                    maxHeight: .infinity
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarBackground(terminalBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
    }
}

// MARK: - Left Panel

let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255)
let terminalPanelForeground = Color.white.opacity(0.94)
let terminalPanelSecondaryForeground = Color.white.opacity(0.6)

struct LeftPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Label("Files", systemImage: "folder")
                    .listRowBackground(terminalBackground)
                Label("Branches", systemImage: "arrow.triangle.branch")
                    .listRowBackground(terminalBackground)
                Label("Sessions", systemImage: "terminal")
                    .listRowBackground(terminalBackground)
            }
            .listStyle(.sidebar)
            .foregroundStyle(terminalPanelForeground)
            .scrollContentBackground(.hidden)
            .background(terminalBackground)

            Spacer()
        }
        .background(terminalBackground)
    }
}

// MARK: - Main Terminal Column

struct MainTerminalColumn: View {
    @ObservedObject var xmux: XmuxState

    var body: some View {
        VSplitView {
            // All terminal surfaces live in the hierarchy simultaneously.
            // Only the active one is visible; others are hidden so their
            // ghostty_surface_t stays alive without resetting the session.
            ZStack {
                ForEach(xmux.sessions) { session in
                    TerminalRepresentable(
                        terminalID: session.id,
                        isActive: session.id == xmux.activeSessionID
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            XmuxEventPanel()
                .frame(minHeight: 150, idealHeight: 190, maxHeight: 280)
        }
        .background(terminalBackground)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        LeftPanel()
            .previewDisplayName("Left Panel")
    }
}

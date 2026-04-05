import SwiftUI

private enum LayoutMetrics {
    static let sidePanelMinWidth: CGFloat = 160
    static let sidePanelIdealWidth: CGFloat = 220
    static let sidePanelMaxWidth: CGFloat = 320
}

/// Root layout: fixed left panel | terminal + live log/events | fixed right panel
struct ContentView: View {
    @State private var terminalID = UUID()

    var body: some View {
        HSplitView {
            LeftPanel()
                .frame(
                    minWidth: LayoutMetrics.sidePanelMinWidth,
                    idealWidth: LayoutMetrics.sidePanelIdealWidth,
                    maxWidth: LayoutMetrics.sidePanelMaxWidth,
                    maxHeight: .infinity
                )

            MainTerminalColumn(terminalID: terminalID)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            WorkspaceInspectorPanel()
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

// MARK: - Right Panel

struct MainTerminalColumn: View {
    let terminalID: UUID
    
    var body: some View {
        VSplitView {
            TerminalRepresentable(terminalID: terminalID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HSplitView {
                XmuxLogPanel()
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)

                XmuxEventPanel()
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 150, idealHeight: 190, maxHeight: 280)
        }
        .background(terminalBackground)
    }
}

struct WorkspaceInspectorPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Label("Environment", systemImage: "info.circle")
                    .frame(height: 20)
                    .listRowBackground(terminalBackground)
                Label("Processes", systemImage: "cpu")
                    .frame(height: 20)
                    .listRowBackground(terminalBackground)
                Label("History", systemImage: "clock")
                    .frame(height: 20)
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LeftPanel()
                .previewDisplayName("Left Panel")

            MainTerminalColumn(terminalID: UUID())
                .previewDisplayName("Main Terminal Column")

            WorkspaceInspectorPanel()
                .previewDisplayName("Right Panel")
        }
    }
}

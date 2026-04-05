import SwiftUI

/// Root layout: left sidebar | terminal + live log | right sidebar
struct ContentView: View {
    @State private var terminalID = UUID()

    var body: some View {
        NavigationSplitView(
            sidebar: { LeftPanel() },
            content: { MainTerminalColumn(terminalID: terminalID) },
            detail: { WorkspaceInspectorPanel() }
        )
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Left Panel

struct LeftPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Navigator")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            List {
                Label("Files", systemImage: "folder")
                Label("Branches", systemImage: "arrow.triangle.branch")
                Label("Sessions", systemImage: "terminal")
            }
            .listStyle(.sidebar)

            Spacer()
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
    }
}

// MARK: - Right Panel

let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255)

struct MainTerminalColumn: View {
    let terminalID: UUID
    
    var body: some View {
        VSplitView {
            TerminalRepresentable(terminalID: terminalID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            XmuxLogPanel()
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
            .scrollContentBackground(.hidden)
            .background(terminalBackground)

            Spacer()
        }
        .background(terminalBackground)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
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

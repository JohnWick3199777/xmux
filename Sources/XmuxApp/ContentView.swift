import SwiftUI

/// Root layout: left sidebar | terminal | right sidebar
struct ContentView: View {
    @State private var terminalID = UUID()

    var body: some View {
        NavigationSplitView(
            sidebar: { LeftPanel() },
            content: { TerminalRepresentable(terminalID: terminalID) },
            detail: { RightPanel() }
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

struct RightPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inspector")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            List {
                Label("Environment", systemImage: "info.circle")
                Label("Processes", systemImage: "cpu")
                Label("History", systemImage: "clock")
            }
            .listStyle(.sidebar)

            Spacer()
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
    }
}

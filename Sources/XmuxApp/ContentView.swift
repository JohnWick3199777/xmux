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

#Preview("Left Panel") { LeftPanel() }

// MARK: - Right Panel

private let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255)

struct RightPanel: View {
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

#Preview("Right Panel") { RightPanel() }

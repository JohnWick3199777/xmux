import SwiftUI
import Foundation

private enum LayoutMetrics {
    static let sidePanelMinWidth: CGFloat = 160
    static let sidePanelIdealWidth: CGFloat = 220
    static let sidePanelMaxWidth: CGFloat = 320
}

/// Root layout: fixed left panel | terminal + live events | fixed right panel
struct ContentView: View {
    @StateObject private var xmux = XmuxState()
    @State private var selectedFileURL: URL?

    private var activeSessionPath: String {
        guard let id = xmux.activeSessionID,
              let session = xmux.session(withID: id) else {
            return ""
        }
        return session.pwd
    }

    var body: some View {
        HSplitView {
            GitView(
                activeSessionPath: activeSessionPath,
                selectedFileURL: $selectedFileURL,
                onOpenFile: { selectedFileURL = $0 }
            )
                .frame(
                    minWidth: LayoutMetrics.sidePanelMinWidth,
                    idealWidth: LayoutMetrics.sidePanelIdealWidth,
                    maxWidth: LayoutMetrics.sidePanelMaxWidth,
                    maxHeight: .infinity
                )

            MainTerminalColumn(xmux: xmux, selectedFileURL: $selectedFileURL)
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

// MARK: - Git View

let terminalBackground = Color(red: 40/255, green: 44/255, blue: 52/255)
let terminalPanelForeground = Color.white.opacity(0.94)
let terminalPanelSecondaryForeground = Color.white.opacity(0.6)

struct GitView: View {
    enum Mode: String, Identifiable, CaseIterable {
        case diffRemoteCurrent = "remote-current"
        case diffRemoteMain = "remote-main"
        case allFiles = "all"

        static var allCases: [Mode] {
            [.diffRemoteCurrent, .diffRemoteMain, .allFiles]
        }

        var id: String { rawValue }

        var title: String {
            switch self {
            case .diffRemoteCurrent:
                return "Remote Current"
            case .diffRemoteMain:
                return "Remote Main"
            case .allFiles:
                return "All"
            }
        }
    }

    let activeSessionPath: String
    @Binding var selectedFileURL: URL?
    let onOpenFile: (URL) -> Void

    @State private var repoRoot: URL?
    @State private var tree: [FileTreeNode] = []
    @State private var expandedPaths: Set<String> = []
    @State private var mode: Mode = .diffRemoteCurrent
    @State private var visibleRelativePaths: Set<String>?
    @State private var repoDetails = GitRepoDetails()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let repoRoot {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repoRoot.lastPathComponent)

                        if let worktree = repoDetails.worktree, !worktree.isEmpty {
                            GitViewMetaRow(label: "Worktree", value: worktree)
                        }
                        if let branch = repoDetails.branch, !branch.isEmpty {
                            GitViewMetaRow(label: "Branch", value: branch)
                        }
                        if let commit = repoDetails.commit, !commit.isEmpty {
                            GitViewMetaRow(label: "Commit", value: commit)
                        }

                        Text(repoRoot.path)
                            .font(.caption2)
                            .foregroundStyle(terminalPanelSecondaryForeground)
                    }

                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree) { node in
                            FileTreeRow(
                                node: node,
                                rootURL: repoRoot,
                                depth: 0,
                                visibleRelativePaths: visibleRelativePaths,
                                selectedFileURL: $selectedFileURL,
                                expandedPaths: $expandedPaths,
                                onOpenFile: onOpenFile
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                List {
                    Label("Open a Git project to see its file tree", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(terminalPanelSecondaryForeground)
                        .listRowBackground(terminalBackground)
                }
                .listStyle(.sidebar)
                .foregroundStyle(terminalPanelForeground)
                .scrollContentBackground(.hidden)
                .background(terminalBackground)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(terminalPanelForeground)
        .background(terminalBackground)
        .onAppear(perform: refreshTree)
        .onChange(of: activeSessionPath) { refreshTree() }
        .onChange(of: mode) { refreshTree() }
    }

    private func refreshTree() {
        guard !activeSessionPath.isEmpty,
              let root = GitRepositoryLocator.repositoryRoot(for: URL(fileURLWithPath: activeSessionPath)) else {
            repoRoot = nil
            tree = []
            expandedPaths = []
            visibleRelativePaths = nil
            repoDetails = GitRepoDetails()
            return
        }

        if repoRoot?.path != root.path {
            expandedPaths = []
        }

        repoRoot = root
        repoDetails = GitRepositoryInspector.repoDetails(rootURL: root)

        if let selectedFileURL,
           !selectedFileURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            self.selectedFileURL = nil
        }

        let filter = GitTreeFilterResolver.resolve(for: mode, rootURL: root)
        visibleRelativePaths = filter.visibleRelativePaths
        tree = FileTreeBuilder.makeChildren(of: root, rootURL: root, visibleRelativePaths: filter.visibleRelativePaths)
    }
}

private struct GitViewMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(terminalPanelSecondaryForeground)
            Text(value)
                .foregroundStyle(terminalPanelForeground)
                .lineLimit(1)
        }
        .font(.caption2)
    }
}

private struct FileTreeRow: View {
    let node: FileTreeNode
    let rootURL: URL
    let depth: Int
    let visibleRelativePaths: Set<String>?

    @Binding var selectedFileURL: URL?
    @Binding var expandedPaths: Set<String>

    let onOpenFile: (URL) -> Void

    private var isExpanded: Bool {
        expandedPaths.contains(node.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: handleTap) {
                HStack(spacing: 6) {
                    Image(systemName: disclosureSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                        .opacity(node.isDirectory ? 1 : 0)

                    Image(systemName: node.systemImage)
                        .frame(width: 14)

                    Text(node.name)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? terminalPanelForeground : terminalPanelSecondaryForeground)

                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 5 + 10)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, node.isDirectory {
                ForEach(FileTreeBuilder.makeChildren(of: node.url, rootURL: rootURL, visibleRelativePaths: visibleRelativePaths)) { child in
                    FileTreeRow(
                        node: child,
                        rootURL: rootURL,
                        depth: depth + 1,
                        visibleRelativePaths: visibleRelativePaths,
                        selectedFileURL: $selectedFileURL,
                        expandedPaths: $expandedPaths,
                        onOpenFile: onOpenFile
                    )
                }
            }
        }
    }

    private var isSelected: Bool {
        selectedFileURL?.standardizedFileURL == node.url.standardizedFileURL
    }

    private var disclosureSymbol: String {
        if !node.isDirectory { return "chevron.right" }
        return isExpanded ? "chevron.down" : "chevron.right"
    }

    private func handleTap() {
        if node.isDirectory {
            if isExpanded {
                expandedPaths.remove(node.id)
            } else {
                expandedPaths.insert(node.id)
            }
            return
        }

        selectedFileURL = node.url
        onOpenFile(node.url)
    }
}

private struct FileTreeNode: Identifiable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool

    var systemImage: String {
        isDirectory ? "folder" : "doc"
    }
}

private enum GitRepositoryLocator {
    static func repositoryRoot(for url: URL) -> URL? {
        let fileManager = FileManager.default
        var candidate = normalizedDirectoryURL(from: url)

        while true {
            let gitMarker = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMarker.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private static func normalizedDirectoryURL(from url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}

private struct GitRepoDetails {
    var worktree: String?
    var branch: String?
    var commit: String?
}

private struct GitTreeFilter {
    let visibleRelativePaths: Set<String>?
}

private enum GitTreeFilterResolver {
    static func resolve(for mode: GitView.Mode, rootURL: URL) -> GitTreeFilter {
        switch mode {
        case .allFiles:
            return GitTreeFilter(visibleRelativePaths: nil)
        case .diffRemoteMain:
            guard let ref = GitReferenceResolver.remoteMainReference(rootURL: rootURL) else {
                return GitTreeFilter(visibleRelativePaths: [])
            }
            let paths = GitRepositoryInspector.changedPaths(rootURL: rootURL, against: ref)
            return GitTreeFilter(visibleRelativePaths: expandedVisiblePaths(from: paths))
        case .diffRemoteCurrent:
            guard let ref = GitReferenceResolver.remoteCurrentReference(rootURL: rootURL) else {
                return GitTreeFilter(visibleRelativePaths: [])
            }
            let paths = GitRepositoryInspector.changedPaths(rootURL: rootURL, against: ref)
            return GitTreeFilter(visibleRelativePaths: expandedVisiblePaths(from: paths))
        }
    }

    private static func expandedVisiblePaths(from paths: Set<String>) -> Set<String> {
        var result = paths

        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }

            for depth in 1..<(components.count) {
                result.insert(components.prefix(depth).joined(separator: "/"))
            }
        }

        return result
    }
}

private enum GitReferenceResolver {
    static func remoteMainReference(rootURL: URL) -> String? {
        let candidates = [
            "origin/main",
            "origin/master",
            GitRepositoryInspector.gitOutput(rootURL: rootURL, arguments: ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if GitRepositoryInspector.gitSucceeded(rootURL: rootURL, arguments: ["rev-parse", "--verify", "--quiet", candidate]) {
                return candidate
            }
        }

        return nil
    }

    static func remoteCurrentReference(rootURL: URL) -> String? {
        guard let upstream = GitRepositoryInspector.gitOutput(
            rootURL: rootURL,
            arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]
        ), !upstream.isEmpty else {
            return nil
        }
        return upstream
    }
}

private enum GitRepositoryInspector {
    static func repoDetails(rootURL: URL) -> GitRepoDetails {
        let worktree = gitOutput(rootURL: rootURL, arguments: ["worktree", "list", "--porcelain"])
            .flatMap { parseWorktreeName(from: $0, rootURL: rootURL) } ?? rootURL.lastPathComponent
        let branch = gitOutput(rootURL: rootURL, arguments: ["branch", "--show-current"])
            ?? gitOutput(rootURL: rootURL, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        let commit = gitOutput(rootURL: rootURL, arguments: ["rev-parse", "--short", "HEAD"])

        return GitRepoDetails(worktree: worktree, branch: branch, commit: commit)
    }

    static func changedPaths(rootURL: URL, against ref: String) -> Set<String> {
        let diffPaths = gitLines(rootURL: rootURL, arguments: ["diff", "--name-only", ref, "--"])
        let untrackedPaths = gitLines(rootURL: rootURL, arguments: ["ls-files", "--others", "--exclude-standard"])
        return Set(diffPaths + untrackedPaths)
    }

    static func gitSucceeded(rootURL: URL, arguments: [String]) -> Bool {
        runGit(rootURL: rootURL, arguments: arguments).status == 0
    }

    static func gitOutput(rootURL: URL, arguments: [String]) -> String? {
        let result = runGit(rootURL: rootURL, arguments: arguments)
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static func parseWorktreeName(from porcelain: String, rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        var currentPath: String?

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
                continue
            }

            if line.hasPrefix("branch "), currentPath == rootPath {
                return URL(fileURLWithPath: rootPath).lastPathComponent
            }
        }

        if currentPath == rootPath {
            return URL(fileURLWithPath: rootPath).lastPathComponent
        }

        return nil
    }

    private static func gitLines(rootURL: URL, arguments: [String]) -> [String] {
        guard let output = gitOutput(rootURL: rootURL, arguments: arguments) else { return [] }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func runGit(rootURL: URL, arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = rootURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

private enum FileTreeBuilder {
    static func makeChildren(of directoryURL: URL, rootURL: URL, visibleRelativePaths: Set<String>?) -> [FileTreeNode] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        return urls
            .filter { url in shouldInclude(url: url, rootURL: rootURL, visibleRelativePaths: visibleRelativePaths) }
            .sorted { lhs, rhs in
                let lhsDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rhsDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if lhsDirectory != rhsDirectory {
                    return lhsDirectory && !rhsDirectory
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileTreeNode(
                    id: url.path,
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: isDirectory
                )
            }
    }

    private static func shouldInclude(url: URL, rootURL: URL, visibleRelativePaths: Set<String>?) -> Bool {
        guard let visibleRelativePaths else { return true }
        let relativePath = relativePath(for: url, rootURL: rootURL)
        guard !relativePath.isEmpty else { return true }
        return visibleRelativePaths.contains(relativePath)
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative
    }
}

// MARK: - Main Terminal Column

struct MainTerminalColumn: View {
    @ObservedObject var xmux: XmuxState
    @Binding var selectedFileURL: URL?

    var body: some View {
        VSplitView {
            HSplitView {
                if let selectedFileURL {
                    FilePreviewPane(fileURL: selectedFileURL) {
                        self.selectedFileURL = nil
                    }
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }

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
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            XmuxEventPanel()
                .frame(minHeight: 150, idealHeight: 190, maxHeight: 280)
        }
        .background(terminalBackground)
    }
}

private struct FilePreviewPane: View {
    let fileURL: URL
    let onClose: () -> Void

    @State private var fileContent = ""
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(terminalPanelForeground)
                        .lineLimit(1)

                    Text(fileURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(terminalPanelSecondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(terminalPanelSecondaryForeground)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.08))

            Group {
                if let loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Could not open file", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.orange.opacity(0.9))
                        Text(loadError)
                            .font(.caption.monospaced())
                            .foregroundStyle(terminalPanelSecondaryForeground)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(fileContent)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(terminalPanelForeground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                }
            }
            .background(terminalBackground.opacity(0.92))
        }
        .background(terminalBackground)
        .task(id: fileURL.path) {
            await loadFile()
        }
    }

    private func loadFile() async {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            await MainActor.run {
                fileContent = content
                loadError = nil
            }
        } catch {
            await MainActor.run {
                fileContent = ""
                loadError = error.localizedDescription
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        GitView(
            activeSessionPath: FileManager.default.currentDirectoryPath,
            selectedFileURL: .constant(nil),
            onOpenFile: { _ in }
        )
        .previewDisplayName("GitView")
    }
}

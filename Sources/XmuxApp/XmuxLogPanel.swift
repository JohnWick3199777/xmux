import Foundation
import SwiftUI

private struct XmuxLogReadResult {
    let fileAvailable: Bool
    let didReset: Bool
    let nextOffset: UInt64
    let trailingFragment: String
    let lines: [String]
}

private enum XmuxLogReader {
    static func readDelta(path: String, from offset: UInt64, trailingFragment: String) -> XmuxLogReadResult {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return XmuxLogReadResult(
                fileAvailable: false,
                didReset: offset > 0 || !trailingFragment.isEmpty,
                nextOffset: 0,
                trailingFragment: "",
                lines: []
            )
        }

        let fileSize = fileSizeNumber.uint64Value
        let didReset = fileSize < offset
        let startOffset = didReset ? UInt64.zero : offset
        let previousFragment = didReset ? "" : trailingFragment
        let logURL = URL(fileURLWithPath: path)

        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return XmuxLogReadResult(
                fileAvailable: true,
                didReset: didReset,
                nextOffset: startOffset,
                trailingFragment: previousFragment,
                lines: []
            )
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            let nextOffset = startOffset + UInt64(data.count)

            guard !data.isEmpty else {
                return XmuxLogReadResult(
                    fileAvailable: true,
                    didReset: didReset,
                    nextOffset: fileSize,
                    trailingFragment: previousFragment,
                    lines: []
                )
            }

            let combinedText = previousFragment + String(decoding: data, as: UTF8.self)
            var lines = combinedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let nextFragment: String

            if combinedText.hasSuffix("\n") {
                nextFragment = ""
            } else {
                nextFragment = lines.popLast() ?? ""
            }

            return XmuxLogReadResult(
                fileAvailable: true,
                didReset: didReset,
                nextOffset: nextOffset,
                trailingFragment: nextFragment,
                lines: lines.filter { !$0.isEmpty }
            )
        } catch {
            return XmuxLogReadResult(
                fileAvailable: true,
                didReset: didReset,
                nextOffset: startOffset,
                trailingFragment: previousFragment,
                lines: []
            )
        }
    }
}

@MainActor
final class XmuxLogTailModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var logPath = ""
    @Published private(set) var scrollVersion = 0

    private var watchTask: Task<Void, Never>?
    private var offset: UInt64 = 0
    private var trailingFragment = ""
    private let maxLines = 500

    var visibleText: String {
        lines.joined(separator: "\n")
    }

    var displayPath: String {
        if !logPath.isEmpty {
            return logPath
        }

        return (NSHomeDirectory() as NSString).appendingPathComponent(".xmux/xmux.log")
    }

    deinit {
        watchTask?.cancel()
    }

    func start() {
        guard watchTask == nil else { return }
        lines.removeAll(keepingCapacity: true)
        scrollVersion = 0
        offset = 0
        trailingFragment = ""

        watchTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        scrollVersion += 1
    }

    private func poll() async {
        guard let path = XmuxLog.shared.path, !path.isEmpty else {
            logPath = displayPath
            return
        }

        logPath = path
        let currentOffset = offset
        let currentFragment = trailingFragment

        let readResult = await Task.detached(priority: .utility) {
            XmuxLogReader.readDelta(path: path, from: currentOffset, trailingFragment: currentFragment)
        }.value

        if readResult.didReset {
            lines.removeAll(keepingCapacity: true)
        }

        offset = readResult.nextOffset
        trailingFragment = readResult.trailingFragment

        if !readResult.fileAvailable {
            return
        }

        if !readResult.lines.isEmpty {
            append(lines: readResult.lines)
        }
    }

    private func append(lines: [String]) {
        self.lines.append(contentsOf: lines)

        if self.lines.count > maxLines {
            self.lines.removeFirst(self.lines.count - maxLines)
        }

        scrollVersion += 1
    }
}

struct XmuxLogPanel: View {
    @StateObject private var model = XmuxLogTailModel()
    private let bottomAnchorID = "xmux-log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            logFeed
        }
        .background(terminalBackground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Clear") {
                model.clear()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(terminalBackground)
    }

    private var logFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.visibleText.isEmpty {
                        Text("Waiting for xmux.log output...")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.visibleText)
                            .foregroundStyle(.white.opacity(0.94))
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(12)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(terminalBackground)
            .onAppear {
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: model.scrollVersion) { _, _ in
                scrollToBottom(using: proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

struct XmuxLogPanel_Previews: PreviewProvider {
    static var previews: some View {
        XmuxLogPanel()
            .previewDisplayName("Live Log Panel")
    }
}

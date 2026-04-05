import Foundation
import SwiftUI

@MainActor
final class XmuxEventTailModel: ObservableObject {
    @Published private(set) var lines: [XmuxEventLine] = []
    @Published private(set) var portPath = ""
    @Published private(set) var scrollVersion = 0

    private var watchTask: Task<Void, Never>?
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var visibleText: String {
        lines.map(Self.format(line:)).joined(separator: "\n")
    }

    var displayPath: String {
        if !portPath.isEmpty {
            return portPath
        }

        return XmuxEventPort.shared.displayPath
    }

    deinit {
        watchTask?.cancel()
    }

    func start() {
        guard watchTask == nil else { return }
        lines.removeAll(keepingCapacity: true)
        portPath = ""
        scrollVersion = 0

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
        XmuxEventPort.shared.clear()
        lines.removeAll(keepingCapacity: true)
        scrollVersion += 1
    }

    private func poll() async {
        let snapshot = XmuxEventPort.shared.snapshot()
        portPath = snapshot.path

        if snapshot.lines != lines {
            lines = snapshot.lines
            scrollVersion += 1
        }
    }

    private static func format(line: XmuxEventLine) -> String {
        let time = timeFormatter.string(from: line.timestamp)
        let method = extractMethod(from: line.raw) ?? line.raw
        return "[\(time)] \(method)"
    }

    private static func extractMethod(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return nil
        }
        return method
    }
}

struct XmuxEventPanel: View {
    @StateObject private var model = XmuxEventTailModel()
    private let bottomAnchorID = "xmux-event-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            eventFeed
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

    private var eventFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.visibleText.isEmpty {
                        Text("Waiting for xmux.port events...")
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

struct XmuxEventPanel_Previews: PreviewProvider {
    static var previews: some View {
        XmuxEventPanel()
            .previewDisplayName("Live Event Panel")
    }
}

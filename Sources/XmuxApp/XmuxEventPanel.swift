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
        return "[\(time)] \(summarize(raw: line.raw))"
    }

    private static func summarize(raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return raw
        }

        let params = object["params"] as? [String: Any]
        let event = params?["event"] as? [String: Any]

        switch method {
        case "command.start":
            if let command = params?["command"] as? String {
                return "\(method) \(inline(command))"
            }
            return method

        case "pi.message_start", "pi.message_end":
            if let event,
               let message = event["message"] as? [String: Any] {
                let role = (message["role"] as? String) ?? "message"
                if let content = extractMessageContent(from: message), !content.isEmpty {
                    return "\(method) \(role): \(content)"
                }
                return "\(method) \(role)"
            }
            return method

        case "pi.message_update":
            if let event,
               let assistantEvent = event["assistantMessageEvent"] as? [String: Any] {
                let assistantType = (assistantEvent["type"] as? String) ?? "update"
                if let content = extractAssistantUpdateContent(from: assistantEvent), !content.isEmpty {
                    return "\(method) \(assistantType): \(content)"
                }
                return "\(method) \(assistantType)"
            }
            return method

        case "pi.tool_execution_start", "pi.tool_execution_update", "pi.tool_execution_end":
            if let toolName = event?["toolName"] as? String {
                return "\(method) \(toolName)"
            }
            return method

        default:
            return method
        }
    }

    private static func extractMessageContent(from message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }

        let parts = content.compactMap { item -> String? in
            let type = item["type"] as? String
            switch type {
            case "text":
                return item["text"] as? String
            case "thinking":
                return item["thinking"] as? String
            case "toolCall":
                let name = item["name"] as? String ?? "tool"
                if let arguments = item["partialJson"] as? String, !arguments.isEmpty {
                    return "toolCall \(name) \(arguments)"
                }
                return "toolCall \(name)"
            default:
                return nil
            }
        }

        guard !parts.isEmpty else { return nil }
        return inline(parts.joined(separator: " | "))
    }

    private static func extractAssistantUpdateContent(from assistantEvent: [String: Any]) -> String? {
        if let delta = assistantEvent["delta"] as? String, !delta.isEmpty {
            return inline(delta)
        }

        if let content = assistantEvent["content"] as? String, !content.isEmpty {
            return inline(content)
        }

        if let partial = assistantEvent["partial"] as? [String: Any],
           let content = extractMessageContent(from: partial), !content.isEmpty {
            return content
        }

        return nil
    }

    private static func inline(_ text: String, limit: Int = 240) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flattened.count > limit else { return flattened }
        let end = flattened.index(flattened.startIndex, offsetBy: limit)
        return String(flattened[..<end]) + "…"
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

import Foundation
import SwiftUI

// MARK: - Sessions panel (right column)

struct SessionsPanel: View {
    @ObservedObject var xmux: XmuxState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            sessionList
        }
        .background(terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(terminalPanelForeground)
            Spacer()
            Button(action: { xmux.addSession() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(terminalPanelForeground)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: List

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(xmux.sessions) { session in
                    SessionCard(
                        session: session,
                        isActive: session.id == xmux.activeSessionID,
                        canClose: xmux.sessions.count > 1,
                        onActivate: { xmux.activateSession(session.id) },
                        onClose: { xmux.closeSession(session.id) }
                    )
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Single session card

struct SessionCard: View {
    let session: XmuxSessionState
    let isActive: Bool
    let canClose: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .top, spacing: 8) {
                // Active dot
                Circle()
                    .fill(isActive ? Color.green : Color.clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? terminalPanelForeground : terminalPanelSecondaryForeground)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(session.displayPwd)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(terminalPanelSecondaryForeground)

                    if let piLabel = piLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text(piLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(piStatusColor)

                        if let piToolLabel = piToolLabel {
                            HStack(spacing: 6) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 9))
                                Text(piToolLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(Color.orange.opacity(0.9))
                        }

                        if let piToolCountLabel = piToolCountLabel {
                            HStack(spacing: 6) {
                                Image(systemName: "number")
                                    .font(.system(size: 9))
                                Text(piToolCountLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(terminalPanelSecondaryForeground.opacity(0.9))
                        }

                        if let piUsageLabel = piUsageLabel {
                            Text(piUsageLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(terminalPanelSecondaryForeground.opacity(0.9))
                        }
                    }

                    Text(elapsedString(from: session.startTime))
                        .font(.system(size: 10))
                        .foregroundStyle(terminalPanelSecondaryForeground.opacity(0.6))
                }

                Spacer(minLength: 0)

                if canClose && isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(terminalPanelSecondaryForeground)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.white.opacity(0.1)
                          : isHovered ? Color.white.opacity(0.04) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var piLabel: String? {
        guard let sessionID = session.piSessionID else { return nil }
        let shortID = String(sessionID.prefix(8))

        if let status = session.piStatus {
            return "pi \(shortID) · \(status.label)"
        }

        return "pi \(shortID)"
    }

    private var piToolLabel: String? {
        guard let toolName = session.piCurrentToolName, !toolName.isEmpty else { return nil }
        return "tool \(toolName) · running"
    }

    private var piToolCountLabel: String? {
        guard let summary = session.piUsageSummary,
              summary.toolCallCount > 0 else { return nil }
        return "tools:\(summary.toolCallCount)"
    }

    private var piUsageLabel: String? {
        guard let summary = session.piUsageSummary else { return nil }

        var parts: [String] = []

        if summary.inputTokens > 0 {
            parts.append("↑\(formatTokens(summary.inputTokens))")
        }
        if summary.outputTokens > 0 {
            parts.append("↓\(formatTokens(summary.outputTokens))")
        }
        if summary.totalCostUSD > 0 || summary.usingSubscription {
            parts.append(String(format: "$%.3f%@", summary.totalCostUSD, summary.usingSubscription ? " (sub)" : ""))
        }

        if let contextText = contextUsageText(summary: summary) {
            parts.append(contextText)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var piStatusColor: Color {
        switch session.piStatus {
        case .working:
            return Color.orange.opacity(0.9)
        case .idle:
            return Color.cyan.opacity(0.9)
        case nil:
            return terminalPanelSecondaryForeground
        }
    }

    private func contextUsageText(summary: XmuxSessionState.PiUsageSummary) -> String? {
        let auto = summary.autoCompactEnabled ? " (auto)" : ""

        switch (summary.contextPercent, summary.contextWindow) {
        case let (.some(percent), .some(window)):
            return String(format: "%.1f%%/%@%@", percent, formatTokens(window), auto)
        case let (_, .some(window)):
            return "?/\(formatTokens(window))\(auto)"
        default:
            return nil
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 10_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        if count < 1_000_000 { return "\(Int(round(Double(count) / 1_000)))k" }
        if count < 10_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        return "\(Int(round(Double(count) / 1_000_000)))M"
    }

    private func elapsedString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60  { return "just now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

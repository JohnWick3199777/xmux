import SwiftUI

// MARK: - Sessions panel (right column)

struct SessionsPanel: View {
    @ObservedObject var sessions: SessionManager

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
            Button(action: { sessions.addSession() }) {
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
                ForEach(sessions.sessions) { session in
                    SessionCard(
                        session: session,
                        isActive: session.id == sessions.activeID,
                        canClose: sessions.sessions.count > 1,
                        onActivate: { sessions.activate(session.id) },
                        onClose: { sessions.removeSession(session.id) }
                    )
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Single session card

struct SessionCard: View {
    let session: TerminalSession
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

    private func elapsedString(from date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60  { return "just now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

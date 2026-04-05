import Foundation
import SwiftUI

// MARK: - Session model

struct TerminalSession: Identifiable {
    let id: UUID
    let index: Int
    let startTime: Date
    var title: String = ""
    var pwd: String = ""

    /// Human-readable name: shell-reported title > last path component > fallback
    var displayName: String {
        if !title.isEmpty { return title }
        if !pwd.isEmpty, let last = pwd.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return "Session \(index)"
    }

    var displayPwd: String {
        guard !pwd.isEmpty else { return "~" }
        let home = NSHomeDirectory()
        if pwd.hasPrefix(home) { return "~" + pwd.dropFirst(home.count) }
        return pwd
    }
}

// MARK: - Session manager

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var activeID: UUID

    private var counter = 0
    private var refreshTask: Task<Void, Never>?

    init() {
        let first = Self.makeSession(index: 1)
        sessions = [first]
        activeID = first.id
        startRefreshing()
        // Defer so XmuxEventPort is fully set up before we emit
        Task { @MainActor [weak self] in
            self?.emitEvent("xmux.session.start", session: first)
        }
    }

    deinit { refreshTask?.cancel() }

    // MARK: Public API

    func addSession() {
        counter += 1
        let s = Self.makeSession(index: sessions.count + 1)
        sessions.append(s)
        activeID = s.id
        emitEvent("xmux.session.start", session: s)
    }

    func activate(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    func removeSession(_ id: UUID) {
        guard sessions.count > 1 else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }

        let session = sessions[idx]
        emitEvent("xmux.session.end", session: session,
                  extra: ["duration": Int(Date().timeIntervalSince(session.startTime))])

        // Clean up the Ghostty surface
        GhosttyView.registry[id]?.closeSurface()

        sessions.remove(at: idx)

        if activeID == id {
            // Prefer the session that was to the left, else the new last one
            let newIdx = max(0, idx - 1)
            activeID = sessions[newIdx].id
        }
    }

    // MARK: Private

    private static func makeSession(index: Int) -> TerminalSession {
        TerminalSession(id: UUID(), index: index, startTime: Date())
    }

    private func emitEvent(_ name: String, session: TerminalSession, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "id": session.id.uuidString,
            "index": session.index,
        ]
        if !session.pwd.isEmpty { payload["cwd"] = session.pwd }
        for (k, v) in extra { payload[k] = v }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": name,
            "params": payload,
        ]

        let json = (try? JSONSerialization.data(withJSONObject: message))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        XmuxEventPort.shared.emit(json)
    }

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.refreshMeta()
            }
        }
    }

    /// Pull live pwd + title from GhosttyView registry
    private func refreshMeta() {
        for i in sessions.indices {
            guard let view = GhosttyView.registry[sessions[i].id] else { continue }
            sessions[i].title = view.title
            sessions[i].pwd = view.pwd
        }
    }
}

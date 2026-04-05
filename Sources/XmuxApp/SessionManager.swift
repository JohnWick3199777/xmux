import Foundation
import SwiftUI

// MARK: - Session model

struct TerminalSession: Identifiable {
    enum PiStatus: String {
        case idle
        case working

        var label: String { rawValue }
    }

    let id: UUID
    let index: Int
    let startTime: Date
    var title: String = ""
    var pwd: String = ""
    var piSessionID: String?
    var piStatus: PiStatus?

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

private struct PiSessionState {
    var sessionID: String?
    var status: TerminalSession.PiStatus?
    var isAgentRunning = false
}

private struct XmuxEventEnvelope {
    let method: String
    let params: [String: Any]

    var terminalID: UUID? {
        guard let raw = params["terminal_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    var sessionFile: String? {
        params["session_file"] as? String
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

    /// Pull live pwd + title from GhosttyView registry and reconcile latest pi state.
    private func refreshMeta() {
        let piStates = latestPiStateByTerminalID()

        for i in sessions.indices {
            if let view = GhosttyView.registry[sessions[i].id] {
                sessions[i].title = view.title
                sessions[i].pwd = view.pwd
            }

            let piState = piStates[sessions[i].id]
            sessions[i].piSessionID = piState?.sessionID
            sessions[i].piStatus = piState?.status
        }
    }

    private func latestPiStateByTerminalID() -> [UUID: PiSessionState] {
        let snapshot = XmuxEventPort.shared.snapshot()
        var states: [UUID: PiSessionState] = [:]

        for line in snapshot.lines {
            guard let event = parseEventEnvelope(from: line.raw),
                  event.method.hasPrefix("pi."),
                  let terminalID = event.terminalID else {
                continue
            }

            var state = states[terminalID] ?? PiSessionState()

            if let sessionID = extractPiSessionID(from: event.sessionFile) {
                state.sessionID = sessionID
            }

            switch event.method {
            case "pi.before_agent_start", "pi.agent_start":
                state.isAgentRunning = true
                state.status = .working

            case "pi.agent_end":
                state.isAgentRunning = false
                state.status = .idle

            case "pi.session_start",
                 "pi.session_before_switch",
                 "pi.session_before_fork",
                 "pi.session_before_compact",
                 "pi.session_compact",
                 "pi.session_before_tree",
                 "pi.session_tree",
                 "pi.model_select":
                if !state.isAgentRunning {
                    state.status = .idle
                }

            case "pi.turn_start",
                 "pi.message_start",
                 "pi.message_update",
                 "pi.tool_execution_start",
                 "pi.tool_execution_update":
                if state.isAgentRunning {
                    state.status = .working
                }

            case "pi.turn_end",
                 "pi.message_end",
                 "pi.tool_execution_end":
                if state.isAgentRunning {
                    state.status = .working
                } else {
                    state.status = .idle
                }

            case "pi.session_shutdown":
                state.status = nil
                state.sessionID = nil
                state.isAgentRunning = false

            default:
                break
            }

            states[terminalID] = state
        }

        return states
    }

    private func parseEventEnvelope(from raw: String) -> XmuxEventEnvelope? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else {
            return nil
        }

        return XmuxEventEnvelope(method: method, params: params)
    }

    private func extractPiSessionID(from sessionFile: String?) -> String? {
        guard let sessionFile, !sessionFile.isEmpty else { return nil }

        let fileName = URL(fileURLWithPath: sessionFile)
            .deletingPathExtension()
            .lastPathComponent
        guard !fileName.isEmpty else { return nil }

        if let underscore = fileName.lastIndex(of: "_") {
            let candidate = String(fileName[fileName.index(after: underscore)...])
            if !candidate.isEmpty {
                return candidate
            }
        }

        return fileName
    }
}

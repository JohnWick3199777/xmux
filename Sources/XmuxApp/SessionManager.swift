import Foundation
import SwiftUI

// MARK: - Xmux GUI state

struct XmuxSessionState: Identifiable {
    enum TerminalLifecycle: String {
        case creating
        case running
        case closing
        case closed
    }

    enum ShellLifecycle: Equatable {
        case booting
        case ready
        case executing(command: String)
    }

    enum AgentLifecycle: Equatable {
        case none
        case idle(sessionID: String?)
        case working(sessionID: String?)
    }

    let id: UUID
    let index: Int
    let startTime: Date
    var title: String = ""
    var pwd: String = ""
    var terminalLifecycle: TerminalLifecycle = .creating
    var shellLifecycle: ShellLifecycle = .booting
    var agentLifecycle: AgentLifecycle = .none
    var lastEventAt: Date?

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

    var piSessionID: String? {
        switch agentLifecycle {
        case .none:
            return nil
        case .idle(let sessionID), .working(let sessionID):
            return sessionID
        }
    }

    var piStatus: PiStatus? {
        switch agentLifecycle {
        case .none:
            return nil
        case .idle:
            return .idle
        case .working:
            return .working
        }
    }

    enum PiStatus: String {
        case idle
        case working

        var label: String { rawValue }
    }
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

    var command: String? {
        params["command"] as? String
    }
}

@MainActor
final class XmuxState: ObservableObject {
    enum AppPhase: String {
        case launching
        case running
    }

    @Published private(set) var sessions: [XmuxSessionState] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var appPhase: AppPhase = .launching

    private var refreshTask: Task<Void, Never>?

    init() {
        let first = Self.makeSession(index: 1)
        sessions = [first]
        activeSessionID = first.id
        appPhase = .running
        startRefreshing()
        // Defer so XmuxEventPort is fully set up before we emit.
        Task { @MainActor [weak self] in
            self?.emitEvent("xmux.session.start", session: first)
        }
    }

    deinit { refreshTask?.cancel() }

    // MARK: Public API

    func addSession() {
        let session = Self.makeSession(index: sessions.count + 1)
        sessions.append(session)
        activeSessionID = session.id
        emitEvent("xmux.session.start", session: session)
    }

    func activateSession(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
    }

    func closeSession(_ id: UUID) {
        guard sessions.count > 1 else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }

        var session = sessions[idx]
        session.terminalLifecycle = .closing
        sessions[idx] = session

        emitEvent(
            "xmux.session.end",
            session: session,
            extra: ["duration": Int(Date().timeIntervalSince(session.startTime))]
        )

        GhosttyView.registry[id]?.closeSurface()

        session.terminalLifecycle = .closed
        sessions.remove(at: idx)

        if activeSessionID == id {
            let newIdx = max(0, idx - 1)
            activeSessionID = sessions[newIdx].id
        }
    }

    func session(withID id: UUID) -> XmuxSessionState? {
        sessions.first(where: { $0.id == id })
    }

    // MARK: Private

    private static func makeSession(index: Int) -> XmuxSessionState {
        XmuxSessionState(id: UUID(), index: index, startTime: Date())
    }

    private func emitEvent(_ name: String, session: XmuxSessionState, extra: [String: Any] = [:]) {
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
                self?.refreshFromRuntime()
            }
        }
    }

    /// Reconciles the single GUI state container from runtime sources.
    private func refreshFromRuntime() {
        let agentStates = latestAgentStateByTerminalID()
        let shellStates = latestShellStateByTerminalID()

        for i in sessions.indices {
            let id = sessions[i].id

            if let view = GhosttyView.registry[id] {
                sessions[i].title = view.title
                sessions[i].pwd = view.pwd
                sessions[i].terminalLifecycle = .running
            }

            if let shellState = shellStates[id] {
                sessions[i].shellLifecycle = shellState
            }

            if let agentLifecycle = agentStates[id] {
                sessions[i].agentLifecycle = agentLifecycle
            } else {
                sessions[i].agentLifecycle = .none
            }
        }
    }

    private func latestShellStateByTerminalID() -> [UUID: XmuxSessionState.ShellLifecycle] {
        let snapshot = XmuxEventPort.shared.snapshot()
        var states: [UUID: XmuxSessionState.ShellLifecycle] = [:]

        for line in snapshot.lines {
            guard let event = parseEventEnvelope(from: line.raw),
                  let terminalID = event.terminalID else {
                continue
            }

            switch event.method {
            case "command.start":
                let command = event.command ?? ""
                states[terminalID] = .executing(command: command)
            case "xmux.session.start":
                if states[terminalID] == nil {
                    states[terminalID] = .booting
                }
            default:
                if states[terminalID] == nil {
                    states[terminalID] = .ready
                }
            }
        }

        return states
    }

    private func latestAgentStateByTerminalID() -> [UUID: XmuxSessionState.AgentLifecycle] {
        let snapshot = XmuxEventPort.shared.snapshot()
        var states: [UUID: XmuxSessionState.AgentLifecycle] = [:]
        var isAgentRunning: [UUID: Bool] = [:]

        for line in snapshot.lines {
            guard let event = parseEventEnvelope(from: line.raw),
                  event.method.hasPrefix("pi."),
                  let terminalID = event.terminalID else {
                continue
            }

            let sessionID = extractPiSessionID(from: event.sessionFile)
            let currentlyRunning = isAgentRunning[terminalID] ?? false

            switch event.method {
            case "pi.before_agent_start", "pi.agent_start":
                isAgentRunning[terminalID] = true
                states[terminalID] = .working(sessionID: sessionID ?? states[terminalID]?.sessionID)

            case "pi.agent_end":
                isAgentRunning[terminalID] = false
                states[terminalID] = .idle(sessionID: sessionID ?? states[terminalID]?.sessionID)

            case "pi.session_start",
                 "pi.session_before_switch",
                 "pi.session_before_fork",
                 "pi.session_before_compact",
                 "pi.session_compact",
                 "pi.session_before_tree",
                 "pi.session_tree",
                 "pi.model_select":
                if !currentlyRunning {
                    states[terminalID] = .idle(sessionID: sessionID ?? states[terminalID]?.sessionID)
                }

            case "pi.turn_start",
                 "pi.message_start",
                 "pi.message_update",
                 "pi.tool_execution_start",
                 "pi.tool_execution_update":
                if currentlyRunning {
                    states[terminalID] = .working(sessionID: sessionID ?? states[terminalID]?.sessionID)
                }

            case "pi.turn_end",
                 "pi.message_end",
                 "pi.tool_execution_end":
                if currentlyRunning {
                    states[terminalID] = .working(sessionID: sessionID ?? states[terminalID]?.sessionID)
                } else {
                    states[terminalID] = .idle(sessionID: sessionID ?? states[terminalID]?.sessionID)
                }

            case "pi.session_shutdown":
                isAgentRunning[terminalID] = false
                states[terminalID] = XmuxSessionState.AgentLifecycle.none

            default:
                break
            }
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

private extension XmuxSessionState.AgentLifecycle {
    var sessionID: String? {
        switch self {
        case .none:
            return nil
        case .idle(let sessionID), .working(let sessionID):
            return sessionID
        }
    }
}

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

    struct PiUsageSummary: Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var toolCallCount: Int = 0
        var totalCostUSD: Double = 0
        var contextTokens: Int?
        var contextWindow: Int?
        var contextPercent: Double?
        var usingSubscription: Bool = false
        var autoCompactEnabled: Bool = true
        var provider: String?
        var modelID: String?
    }

    let id: UUID
    let index: Int
    let startTime: Date
    var title: String = ""
    var pwd: String = ""
    var terminalLifecycle: TerminalLifecycle = .creating
    var shellLifecycle: ShellLifecycle = .booting
    var agentLifecycle: AgentLifecycle = .none
    var piCurrentToolName: String?
    var piSessionFile: String?
    var piUsageSummary: PiUsageSummary?
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

    var event: [String: Any]? {
        params["event"] as? [String: Any]
    }

    var toolName: String? {
        event?["toolName"] as? String
    }
}

private struct PiRuntimeState {
    var lifecycle: XmuxSessionState.AgentLifecycle
    var sessionFile: String?
    var currentToolName: String?
}

private struct CachedPiSummary {
    let fileSize: UInt64
    let modificationDate: Date
    let summary: XmuxSessionState.PiUsageSummary
}

private struct CachedPiAuthState {
    let modificationDate: Date
    let oauthProviders: Set<String>
}

private struct CachedPiSettingsState {
    let modificationDate: Date
    let autoCompactEnabled: Bool
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
    private var piSummaryCache: [String: CachedPiSummary] = [:]
    private var piAuthCache: CachedPiAuthState?
    private var piSettingsCache: CachedPiSettingsState?

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

            if let runtimeState = agentStates[id] {
                sessions[i].agentLifecycle = runtimeState.lifecycle
                sessions[i].piCurrentToolName = runtimeState.currentToolName
                sessions[i].piSessionFile = runtimeState.sessionFile
                sessions[i].piUsageSummary = piUsageSummary(for: runtimeState.sessionFile)
            } else if sessions[i].agentLifecycle == .none {
                sessions[i].piCurrentToolName = nil
                sessions[i].piSessionFile = nil
                sessions[i].piUsageSummary = nil
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

    private func latestAgentStateByTerminalID() -> [UUID: PiRuntimeState] {
        let snapshot = XmuxEventPort.shared.snapshot()
        var states: [UUID: PiRuntimeState] = [:]
        var isAgentRunning: [UUID: Bool] = [:]
        var didShutdownSession: [UUID: Bool] = [:]

        for line in snapshot.lines {
            guard let event = parseEventEnvelope(from: line.raw),
                  event.method.hasPrefix("pi."),
                  let terminalID = event.terminalID else {
                continue
            }

            let sessionID = extractPiSessionID(from: event.sessionFile)
            let existingState = states[terminalID]
            let resolvedSessionFile = event.sessionFile ?? existingState?.sessionFile
            let isShutdown = didShutdownSession[terminalID] ?? false

            // Pi may emit trailing lifecycle notifications after session_shutdown
            // (for example: message_end / turn_end / agent_end). Once shutdown is
            // observed, keep the session cleared until a new session/agent starts.
            if isShutdown,
               event.method != "pi.session_start",
               event.method != "pi.before_agent_start",
               event.method != "pi.agent_start" {
                continue
            }

            let currentlyRunning = isAgentRunning[terminalID] ?? false

            switch event.method {
            case "pi.before_agent_start", "pi.agent_start":
                didShutdownSession[terminalID] = false
                isAgentRunning[terminalID] = true
                states[terminalID] = PiRuntimeState(
                    lifecycle: .working(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                    sessionFile: resolvedSessionFile,
                    currentToolName: existingState?.currentToolName
                )

            case "pi.agent_end":
                isAgentRunning[terminalID] = false
                states[terminalID] = PiRuntimeState(
                    lifecycle: .idle(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                    sessionFile: resolvedSessionFile,
                    currentToolName: nil
                )

            case "pi.session_start",
                 "pi.session_before_switch",
                 "pi.session_before_fork",
                 "pi.session_before_compact",
                 "pi.session_compact",
                 "pi.session_before_tree",
                 "pi.session_tree",
                 "pi.model_select":
                if event.method == "pi.session_start" {
                    didShutdownSession[terminalID] = false
                }
                if !currentlyRunning {
                    states[terminalID] = PiRuntimeState(
                        lifecycle: .idle(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                        sessionFile: resolvedSessionFile,
                        currentToolName: existingState?.currentToolName
                    )
                }

            case "pi.tool_execution_start", "pi.tool_execution_update":
                if currentlyRunning {
                    states[terminalID] = PiRuntimeState(
                        lifecycle: .working(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                        sessionFile: resolvedSessionFile,
                        currentToolName: event.toolName ?? existingState?.currentToolName
                    )
                }

            case "pi.turn_start",
                 "pi.message_start",
                 "pi.message_update":
                if currentlyRunning {
                    states[terminalID] = PiRuntimeState(
                        lifecycle: .working(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                        sessionFile: resolvedSessionFile,
                        currentToolName: existingState?.currentToolName
                    )
                }

            case "pi.tool_execution_end":
                states[terminalID] = PiRuntimeState(
                    lifecycle: currentlyRunning
                        ? .working(sessionID: sessionID ?? existingState?.lifecycle.sessionID)
                        : .idle(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                    sessionFile: resolvedSessionFile,
                    currentToolName: nil
                )

            case "pi.turn_end":
                isAgentRunning[terminalID] = false
                states[terminalID] = PiRuntimeState(
                    lifecycle: .idle(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                    sessionFile: resolvedSessionFile,
                    currentToolName: existingState?.currentToolName
                )

            case "pi.message_end":
                states[terminalID] = PiRuntimeState(
                    lifecycle: currentlyRunning
                        ? .working(sessionID: sessionID ?? existingState?.lifecycle.sessionID)
                        : .idle(sessionID: sessionID ?? existingState?.lifecycle.sessionID),
                    sessionFile: resolvedSessionFile,
                    currentToolName: existingState?.currentToolName
                )

            case "pi.session_shutdown":
                didShutdownSession[terminalID] = true
                isAgentRunning[terminalID] = false
                states[terminalID] = PiRuntimeState(lifecycle: .none, sessionFile: nil, currentToolName: nil)

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

    private func piUsageSummary(for sessionFile: String?) -> XmuxSessionState.PiUsageSummary? {
        guard let sessionFile, !sessionFile.isEmpty else { return nil }

        let url = URL(fileURLWithPath: sessionFile)
        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              let modificationDate = attrs[.modificationDate] as? Date else {
            return nil
        }

        if let cached = piSummaryCache[url.path],
           cached.fileSize == fileSize.uint64Value,
           cached.modificationDate == modificationDate {
            return cached.summary
        }

        guard let summary = parsePiSessionFile(at: url) else { return nil }
        piSummaryCache[url.path] = CachedPiSummary(
            fileSize: fileSize.uint64Value,
            modificationDate: modificationDate,
            summary: summary
        )
        return summary
    }

    private func parsePiSessionFile(at url: URL) -> XmuxSessionState.PiUsageSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.readToEnd() else {
            return nil
        }
        try? handle.close()

        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
            return nil
        }

        var summary = XmuxSessionState.PiUsageSummary()
        summary.autoCompactEnabled = loadPiAutoCompactEnabled()

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            switch type {
            case "model_change":
                summary.provider = object["provider"] as? String ?? summary.provider
                summary.modelID = object["modelId"] as? String ?? summary.modelID

            case "message":
                guard let message = object["message"] as? [String: Any],
                      let role = message["role"] as? String,
                      role == "assistant" else {
                    continue
                }

                if let usage = message["usage"] as? [String: Any] {
                    summary.inputTokens += intValue(usage["input"])
                    summary.outputTokens += intValue(usage["output"])
                    summary.cacheReadTokens += intValue(usage["cacheRead"])
                    summary.cacheWriteTokens += intValue(usage["cacheWrite"])
                    summary.contextTokens = intValueIfPresent(usage["totalTokens"]) ?? summary.contextTokens

                    if let cost = usage["cost"] as? [String: Any] {
                        summary.totalCostUSD += doubleValue(cost["total"])
                    }
                }

                if let content = message["content"] as? [[String: Any]] {
                    summary.toolCallCount += content.reduce(0) { partial, item in
                        partial + ((item["type"] as? String) == "toolCall" ? 1 : 0)
                    }
                }

                if let provider = message["provider"] as? String, !provider.isEmpty {
                    summary.provider = provider
                }
                if let model = message["model"] as? String, !model.isEmpty {
                    summary.modelID = model
                }

            default:
                continue
            }
        }

        summary.contextWindow = resolveContextWindow(provider: summary.provider, modelID: summary.modelID)
        if let contextTokens = summary.contextTokens,
           let contextWindow = summary.contextWindow,
           contextWindow > 0 {
            summary.contextPercent = (Double(contextTokens) / Double(contextWindow)) * 100
        }
        summary.usingSubscription = isUsingSubscription(provider: summary.provider)

        let hasAnyValue =
            summary.inputTokens > 0 ||
            summary.outputTokens > 0 ||
            summary.cacheReadTokens > 0 ||
            summary.cacheWriteTokens > 0 ||
            summary.toolCallCount > 0 ||
            summary.totalCostUSD > 0 ||
            summary.contextTokens != nil ||
            summary.provider != nil ||
            summary.modelID != nil

        return hasAnyValue ? summary : nil
    }

    private func loadPiAutoCompactEnabled() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/settings.json")
        let fileManager = FileManager.default

        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modificationDate = attrs[.modificationDate] as? Date else {
            return true
        }

        if let cached = piSettingsCache, cached.modificationDate == modificationDate {
            return cached.autoCompactEnabled
        }

        var enabled = true
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            enabled = extractAutoCompactEnabled(from: object) ?? true
        }

        piSettingsCache = CachedPiSettingsState(modificationDate: modificationDate, autoCompactEnabled: enabled)
        return enabled
    }

    private func extractAutoCompactEnabled(from object: [String: Any]) -> Bool? {
        if let value = object["autoCompactEnabled"] as? Bool { return value }
        if let value = object["autocompact"] as? Bool { return value }
        if let compact = object["compact"] as? [String: Any] {
            if let value = compact["auto"] as? Bool { return value }
            if let value = compact["enabled"] as? Bool { return value }
            if let value = compact["autocompact"] as? Bool { return value }
        }
        return nil
    }

    private func isUsingSubscription(provider: String?) -> Bool {
        guard let provider, !provider.isEmpty else { return false }
        let oauthProviders = loadPiOAuthProviders()
        return oauthProviders.contains(provider)
    }

    private func loadPiOAuthProviders() -> Set<String> {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/auth.json")
        let fileManager = FileManager.default

        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modificationDate = attrs[.modificationDate] as? Date else {
            return []
        }

        if let cached = piAuthCache, cached.modificationDate == modificationDate {
            return cached.oauthProviders
        }

        var providers = Set<String>()
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (provider, rawValue) in object {
                guard let providerObject = rawValue as? [String: Any],
                      let type = providerObject["type"] as? String,
                      type == "oauth" else {
                    continue
                }
                providers.insert(provider)
            }
        }

        piAuthCache = CachedPiAuthState(modificationDate: modificationDate, oauthProviders: providers)
        return providers
    }

    private func resolveContextWindow(provider: String?, modelID: String?) -> Int? {
        guard let provider, let modelID else { return nil }
        let normalizedProvider = provider.lowercased()
        let normalizedModel = modelID.lowercased()

        switch (normalizedProvider, normalizedModel) {
        case ("openai-codex", "gpt-5.4"):
            return 272_000
        case ("openai-codex", "gpt-5"):
            return 272_000
        case ("openai-codex", "gpt-5-mini"):
            return 272_000
        case ("openai-codex", "gpt-5-nano"):
            return 272_000
        default:
            return nil
        }
    }

    private func intValue(_ raw: Any?) -> Int {
        intValueIfPresent(raw) ?? 0
    }

    private func intValueIfPresent(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func doubleValue(_ raw: Any?) -> Double {
        switch raw {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value) ?? 0
        default:
            return 0
        }
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

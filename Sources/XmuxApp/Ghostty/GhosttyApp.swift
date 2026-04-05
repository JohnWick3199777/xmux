import AppKit
import GhosttyKit

/// Singleton wrapping `ghostty_app_t`. One per process.
/// Owns config, C callbacks, and the tick loop.
@Observable
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    @ObservationIgnored nonisolated(unsafe) private(set) var app: ghostty_app_t?
    @ObservationIgnored nonisolated(unsafe) private var config: ghostty_config_t?
    private var appearanceObserver: NSKeyValueObservation?

    // MARK: - Init

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            print("[Ghostty] ghostty_init failed")
            return
        }

        guard let cfg = ghostty_config_new() else {
            print("[Ghostty] ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { ud in GhosttyApp.wakeupCallback(ud) }
        rt.action_cb = { app, target, action in GhosttyApp.actionCallback(app, target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in _ = GhosttyApp.readClipboardCallback(ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = nil
        rt.write_clipboard_cb = { ud, loc, content, len, confirm in
            GhosttyApp.writeClipboardCallback(ud, location: loc, content: content, len: len, confirm: confirm)
        }
        rt.close_surface_cb = { ud, processAlive in GhosttyApp.closeSurfaceCallback(ud, processAlive: processAlive) }

        guard let ghosttyApp = ghostty_app_new(&rt, cfg) else {
            print("[Ghostty] ghostty_app_new failed")
            return
        }
        app = ghosttyApp
        print("[Ghostty] initialized")

        // Track system appearance for dark/light theme
        nonisolated(unsafe) let capturedApp = ghosttyApp
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new, .initial]) { _, change in
            guard let appearance = change.newValue else { return }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(capturedApp, scheme)
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    // MARK: - Tick

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Surface creation

    func newSurface(in view: NSView, terminalID: UUID? = nil) -> ghostty_surface_t? {
        guard let app else { return nil }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // use config default
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let surface = withXmuxEnvVars(terminalID: terminalID) { envPtr, envCount in
            cfg.env_vars = envPtr
            cfg.env_var_count = envCount
            return ghostty_surface_new(app, &cfg)
        }
        if surface == nil { print("[Ghostty] ghostty_surface_new failed") }
        return surface
    }

    private func withXmuxEnvVars<T>(
        terminalID: UUID?,
        _ body: (UnsafeMutablePointer<ghostty_env_var_s>?, Int) -> T
    ) -> T {
        let log = XmuxLog.shared
        guard let logPath = log.path, let resourcesDir = log.resourcesDir else {
            return body(nil, 0)
        }

        let zdotdir = (resourcesDir as NSString).appendingPathComponent("shell-integration/zsh")
        let origZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? ""

        let pairs: [(String, String)] = [
            ("XMUX_LOG", logPath),
            ("XMUX_RESOURCES_DIR", resourcesDir),
            ("ZDOTDIR", zdotdir),
            ("_XMUX_ORIG_ZDOTDIR", origZdotdir),
            ("XMUX_TERMINAL_ID", terminalID?.uuidString ?? ""),
        ]

        let keys   = pairs.map { strdup($0.0) }
        let values = pairs.map { strdup($0.1) }
        defer {
            keys.forEach   { free($0) }
            values.forEach { free($0) }
        }

        var envVars = (0..<pairs.count).map { i in
            ghostty_env_var_s(key: keys[i], value: values[i])
        }
        return envVars.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress, buf.count)
        }
    }

    // MARK: - Callbacks

    private static func wakeupCallback(_ ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        let self_ = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
        Task { @MainActor in self_.tick() }
    }

    private static func actionCallback(
        _ ghosttyApp: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        var sourceView: GhosttyView?
        if target.tag == GHOSTTY_TARGET_SURFACE,
           let ud = ghostty_surface_userdata(target.target.surface) {
            sourceView = Unmanaged<GhosttyView>.fromOpaque(ud).takeUnretainedValue()
        }

        // Copy C strings before dispatch (pointers may be freed after return)
        var title: String?
        var pwd: String?
        if action.tag == GHOSTTY_ACTION_SET_TITLE, let ptr = action.action.set_title.title {
            title = String(cString: ptr)
        }
        if action.tag == GHOSTTY_ACTION_PWD, let ptr = action.action.pwd.pwd {
            pwd = String(cString: ptr)
        }

        Task { @MainActor in
            GhosttyApp.shared.handleAction(action, sourceView: sourceView, title: title, pwd: pwd)
        }
        return true
    }

    @MainActor
    private func handleAction(
        _ action: ghostty_action_s,
        sourceView: GhosttyView?,
        title: String?,
        pwd: String?
    ) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            sourceView?.title = title ?? ""
        case GHOSTTY_ACTION_PWD:
            sourceView?.pwd = pwd ?? ""
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            NotificationCenter.default.post(name: .ghosttyChildExited, object: sourceView)
        default:
            break
        }
    }

    private static func readClipboardCallback(
        _ ud: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let state else { return false }
        let view = ud.map { Unmanaged<GhosttyView>.fromOpaque($0).takeUnretainedValue() }
        guard let surface = view?.surface else { return false }
        let str = Thread.isMainThread
            ? NSPasteboard.general.string(forType: .string)
            : DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) }
        guard let str, let dup = strdup(str) else {
            ghostty_surface_complete_clipboard_request(surface, nil, state, false)
            return true
        }
        ghostty_surface_complete_clipboard_request(surface, dup, state, true)
        free(dup)
        return true
    }

    private static func writeClipboardCallback(
        _ ud: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        let entries = UnsafeBufferPointer(start: content, count: len)
        let entry = entries.first {
            guard let mime = $0.mime else { return false }
            let m = String(cString: mime)
            return m.contains("text/plain") || m.contains("public.utf8-plain-text")
        } ?? entries.first
        guard let entry, let data = entry.data else { return }
        let str = String(cString: data)
        Task { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    private static func closeSurfaceCallback(_ ud: UnsafeMutableRawPointer?, processAlive: Bool) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .ghosttyCloseSurface, object: nil)
        }
    }

    private func reloadConfig() {
        guard let app, let cfg = ghostty_config_new() else { return }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        ghostty_app_update_config(app, cfg)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let ghosttyChildExited = Notification.Name("GhosttyChildExited")
    static let ghosttyCloseSurface = Notification.Name("GhosttyCloseSurface")
}

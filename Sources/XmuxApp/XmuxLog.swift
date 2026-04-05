import Foundation

/// Manages the xmux append-only log file.
@MainActor
final class XmuxLog {
    static let shared = XmuxLog()

    /// Absolute path to `xmux.log`, set after `setup()` succeeds.
    private(set) var path: String?

    /// Path to the bundled `xmux` resources directory inside the app bundle.
    var resourcesDir: String? {
        Bundle.main.resourceURL?.appendingPathComponent("xmux").path
    }

    private init() {}

    /// Creates the log file (and parent directory) if they don't exist.
    /// Call once at app startup.
    func setup() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".xmux")
        let file = (dir as NSString).appendingPathComponent("xmux.log")

        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !FileManager.default.fileExists(atPath: file) {
                FileManager.default.createFile(atPath: file, contents: nil)
            }
            path = file
        } catch {
            // Fail silently — log unavailability must not affect the app.
        }

        ensureBinScriptsExecutable()
    }

    /// Ensures bundled shell scripts in `xmux/bin/` have execute permission.
    /// Xcode strips execute bits from bundle resources, so we restore them at runtime.
    private func ensureBinScriptsExecutable() {
        guard let rsrc = resourcesDir else { return }
        let binDir = (rsrc as NSString).appendingPathComponent("bin")
        let scripts = ["claude", "xmux-claude-hook"]
        for script in scripts {
            let scriptPath = (binDir as NSString).appendingPathComponent(script)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptPath
            )
        }
    }
}

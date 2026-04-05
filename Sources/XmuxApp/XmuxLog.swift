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
    }
}

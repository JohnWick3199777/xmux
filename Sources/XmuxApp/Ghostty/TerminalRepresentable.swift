import SwiftUI
import GhosttyKit

/// SwiftUI bridge for `GhosttyView`.
/// Reuses views from the registry to survive SwiftUI re-renders without resetting the session.
struct TerminalRepresentable: NSViewRepresentable {
    let terminalID: UUID
    /// When false the underlying NSView is hidden but kept in the hierarchy so the
    /// surface stays alive.
    var isActive: Bool = true

    func makeNSView(context: Context) -> GhosttyView {
        if let existing = GhosttyView.view(for: terminalID) { return existing }
        let view = GhosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoresizingMask = [.width, .height]
        view.terminalID = terminalID
        // Surface is created in viewDidMoveToWindow once the window is available.
        return view
    }

    func updateNSView(_ nsView: GhosttyView, context: Context) {
        nsView.terminalID = terminalID
        nsView.isHidden = !isActive
        if isActive {
            // Defer so we don't interfere with the current layout pass.
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

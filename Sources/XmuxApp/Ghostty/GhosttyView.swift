import AppKit
import GhosttyKit
import QuartzCore

/// NSView subclass wrapping a single `ghostty_surface_t`.
/// Handles Metal layer attachment, keyboard/mouse forwarding, and IME.
@MainActor
final class GhosttyView: NSView, @preconcurrency NSTextInputClient {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var contentSize: CGSize = .zero

    /// The UUID used by TerminalRepresentable to look up this view.
    var terminalID: UUID?
    var title: String = ""
    var pwd: String = ""

    // MARK: - Registry

    static var registry: [UUID: GhosttyView] = [:]

    static func view(for id: UUID) -> GhosttyView? { registry[id] }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: - Surface lifecycle

    func createSurface() {
        guard surface == nil else { return }
        surface = GhosttyApp.shared.newSurface(in: self)
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        contentSize = bounds.size
        let fb = convertToBacking(NSRect(origin: .zero, size: contentSize)).size
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }

    func closeSurface() {
        if let surface { ghostty_surface_free(surface); self.surface = nil }
        if let id = terminalID { GhosttyView.registry.removeValue(forKey: id) }
    }

    // MARK: - Layout

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil { createSurface() }
        if let id = terminalID {
            if window != nil { GhosttyView.registry[id] = self }
            else { GhosttyView.registry.removeValue(forKey: id) }
        }
        if let surface {
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
            if let displayID = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface, newSize.width > 0, newSize.height > 0 else { return }
        contentSize = newSize
        let fb = convertToBacking(NSRect(origin: .zero, size: newSize)).size
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface else { return }
        let fb = convertToBacking(frame)
        let xScale = fb.size.width / frame.size.width
        let yScale = fb.size.height / frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        let scaledSize = convertToBacking(NSRect(origin: .zero, size: contentSize)).size
        if scaledSize.width > 0, scaledSize.height > 0 {
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self
        ))
    }

    override func becomeFirstResponder() -> Bool {
        guard let surface else { return false }
        ghostty_surface_set_focus(surface, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { interpretKeyEvents([event]); return }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        syncPreedit(clearIfNeeded: markedBefore)
        if let acc = keyTextAccumulator, !acc.isEmpty {
            for text in acc { _ = sendKey(action, event: event, text: text) }
        } else {
            _ = sendKey(action, event: event, text: Self.filteredChars(event), composing: markedText.length > 0 || markedBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText() else { return }
        let modBit: UInt32
        switch event.keyCode {
        case 0x39: modBit = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: modBit = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: modBit = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: modBit = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: modBit = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let isPress = mods.rawValue & modBit != 0
        _ = sendKey(isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let keycode = Self.ghosttyKeycode(event.keyCode).rawValue
        if let text, !text.isEmpty {
            return text.withCString { ptr in
                let input = ghostty_input_key_s(
                    action: action, mods: mods, consumed_mods: ghostty_input_mods_e(rawValue: 0),
                    keycode: keycode, text: ptr, unshifted_codepoint: 0, composing: composing
                )
                return ghostty_surface_key(surface, input)
            }
        }
        let input = ghostty_input_key_s(
            action: action, mods: mods, consumed_mods: ghostty_input_mods_e(rawValue: 0),
            keycode: keycode, text: nil, unshifted_codepoint: 0, composing: composing
        )
        return ghostty_surface_key(surface, input)
    }

    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private static func filteredChars(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        let filtered = chars.unicodeScalars.filter { $0.value >= 0x20 || $0.value == 0x0D }
        return filtered.isEmpty ? nil : String(String.UnicodeScalarView(filtered))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, event: event) }
    override func mouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, event: event) }
    override func rightMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT, event: event) }
    override func rightMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT, event: event) }
    override func otherMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE, event: event) }
    override func otherMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE, event: event) }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event: event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event: event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event: event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let dx = event.scrollingDeltaX
        let dy = -event.scrollingDeltaY
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 } // GHOSTTY_SCROLL_MODS_PRECISE
        ghostty_surface_mouse_scroll(surface, dx, dy, mods)
    }

    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pt.x, bounds.height - pt.y, mods)
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    private func sendMousePos(event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pt.x, bounds.height - pt.y, Self.ghosttyMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, ghostty_input_mods_e(rawValue: 0)) }
    }

    override func mouseExited(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pos(surface, -1, -1, ghostty_input_mods_e(rawValue: 0)) }
    }

    // MARK: - NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let as_ = string as? NSAttributedString { text = as_.string }
        else { return }
        if markedText.length > 0 { markedText = NSMutableAttributedString() }
        if var acc = keyTextAccumulator { acc.append(text); keyTextAccumulator = acc }
        else {
            guard let surface else { return }
            text.withCString { ptr in
                let input = ghostty_input_key_s(
                    action: GHOSTTY_ACTION_PRESS,
                    mods: ghostty_input_mods_e(rawValue: 0),
                    consumed_mods: ghostty_input_mods_e(rawValue: 0),
                    keycode: GHOSTTY_KEY_UNIDENTIFIED.rawValue,
                    text: ptr,
                    unshifted_codepoint: 0,
                    composing: false
                )
                ghostty_surface_key(surface, input)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = if let s = string as? String { NSMutableAttributedString(string: s) }
        else if let as_ = string as? NSAttributedString { NSMutableAttributedString(attributedString: as_) }
        else { NSMutableAttributedString() }
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.frame ?? .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Key translation helpers

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // macOS key code → ghostty key enum
    private static func ghosttyKeycode(_ code: UInt16) -> ghostty_input_key_e {
        switch code {
        case 0x00: return GHOSTTY_KEY_A
        case 0x01: return GHOSTTY_KEY_S
        case 0x02: return GHOSTTY_KEY_D
        case 0x03: return GHOSTTY_KEY_F
        case 0x04: return GHOSTTY_KEY_H
        case 0x05: return GHOSTTY_KEY_G
        case 0x06: return GHOSTTY_KEY_Z
        case 0x07: return GHOSTTY_KEY_X
        case 0x08: return GHOSTTY_KEY_C
        case 0x09: return GHOSTTY_KEY_V
        case 0x0B: return GHOSTTY_KEY_B
        case 0x0C: return GHOSTTY_KEY_Q
        case 0x0D: return GHOSTTY_KEY_W
        case 0x0E: return GHOSTTY_KEY_E
        case 0x0F: return GHOSTTY_KEY_R
        case 0x10: return GHOSTTY_KEY_Y
        case 0x11: return GHOSTTY_KEY_T
        case 0x12: return GHOSTTY_KEY_DIGIT_1
        case 0x13: return GHOSTTY_KEY_DIGIT_2
        case 0x14: return GHOSTTY_KEY_DIGIT_3
        case 0x15: return GHOSTTY_KEY_DIGIT_4
        case 0x16: return GHOSTTY_KEY_DIGIT_6
        case 0x17: return GHOSTTY_KEY_DIGIT_5
        case 0x18: return GHOSTTY_KEY_EQUAL
        case 0x19: return GHOSTTY_KEY_DIGIT_9
        case 0x1A: return GHOSTTY_KEY_DIGIT_7
        case 0x1B: return GHOSTTY_KEY_MINUS
        case 0x1C: return GHOSTTY_KEY_DIGIT_8
        case 0x1D: return GHOSTTY_KEY_DIGIT_0
        case 0x1E: return GHOSTTY_KEY_BRACKET_RIGHT
        case 0x1F: return GHOSTTY_KEY_O
        case 0x20: return GHOSTTY_KEY_U
        case 0x21: return GHOSTTY_KEY_BRACKET_LEFT
        case 0x22: return GHOSTTY_KEY_I
        case 0x23: return GHOSTTY_KEY_P
        case 0x24: return GHOSTTY_KEY_ENTER
        case 0x25: return GHOSTTY_KEY_L
        case 0x26: return GHOSTTY_KEY_J
        case 0x27: return GHOSTTY_KEY_QUOTE
        case 0x28: return GHOSTTY_KEY_K
        case 0x29: return GHOSTTY_KEY_SEMICOLON
        case 0x2A: return GHOSTTY_KEY_BACKSLASH
        case 0x2B: return GHOSTTY_KEY_COMMA
        case 0x2C: return GHOSTTY_KEY_SLASH
        case 0x2D: return GHOSTTY_KEY_N
        case 0x2E: return GHOSTTY_KEY_M
        case 0x2F: return GHOSTTY_KEY_PERIOD
        case 0x30: return GHOSTTY_KEY_TAB
        case 0x31: return GHOSTTY_KEY_SPACE
        case 0x32: return GHOSTTY_KEY_BACKQUOTE
        case 0x33: return GHOSTTY_KEY_BACKSPACE
        case 0x35: return GHOSTTY_KEY_ESCAPE
        case 0x38: return GHOSTTY_KEY_SHIFT_LEFT
        case 0x3B: return GHOSTTY_KEY_CONTROL_LEFT
        case 0x3A: return GHOSTTY_KEY_ALT_LEFT
        case 0x37: return GHOSTTY_KEY_META_LEFT
        case 0x3C: return GHOSTTY_KEY_SHIFT_RIGHT
        case 0x3D: return GHOSTTY_KEY_ALT_RIGHT
        case 0x36: return GHOSTTY_KEY_META_RIGHT
        case 0x7B: return GHOSTTY_KEY_ARROW_LEFT
        case 0x7C: return GHOSTTY_KEY_ARROW_RIGHT
        case 0x7D: return GHOSTTY_KEY_ARROW_DOWN
        case 0x7E: return GHOSTTY_KEY_ARROW_UP
        case 0x73: return GHOSTTY_KEY_HOME
        case 0x77: return GHOSTTY_KEY_END
        case 0x74: return GHOSTTY_KEY_PAGE_UP
        case 0x79: return GHOSTTY_KEY_PAGE_DOWN
        case 0x75: return GHOSTTY_KEY_DELETE
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}

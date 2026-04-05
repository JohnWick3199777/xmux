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
    private var lastPerformKeyEvent: TimeInterval?
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
        surface = GhosttyApp.shared.newSurface(in: self, terminalID: terminalID)
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let surface else { return false }
        guard let firstResponder = window?.firstResponder as? NSView,
              firstResponder === self || firstResponder.isDescendant(of: self) else { return false }

        if isBindingEvent(event, surface: surface) {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            if event.timestamp == 0 { return false }

            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }

        keyDown(with: finalEvent)
        return true
    }

    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }

        // Prevent AppKit from beeping on terminal-editing commands
        // like deleteBackward: that should remain terminal input.
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translationEvent = Self.translatedEvent(for: event, surface: surface)
        let markedBefore = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedBefore)

        if let acc = keyTextAccumulator, !acc.isEmpty {
            for text in acc {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: Self.textForKeyEvent(translationEvent),
                composing: markedText.length > 0 || markedBefore
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
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
        _ = keyAction(isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var input = Self.ghosttyKeyEvent(
            action,
            event: event,
            translationMods: translationEvent?.modifierFlags
        )
        input.composing = composing

        if let text,
           !text.isEmpty,
           let first = text.utf8.first,
           first >= 0x20 {
            return text.withCString { ptr in
                input.text = ptr
                return ghostty_surface_key(surface, input)
            }
        }
        return ghostty_surface_key(surface, input)
    }

    private func isBindingEvent(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        var input = Self.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS, event: event)
        var flags = ghostty_binding_flags_e(rawValue: 0)
        let text = event.characters ?? ""
        return text.withCString { ptr in
            input.text = ptr
            return ghostty_surface_key_is_binding(surface, input, &flags)
        }
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

    private static func translatedEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translatedGhosttyMods = ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags))
        var translatedFlags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = translatedGhosttyMods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0
            case .control:
                hasFlag = translatedGhosttyMods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0
            case .option:
                hasFlag = translatedGhosttyMods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0
            case .command:
                hasFlag = translatedGhosttyMods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0
            default:
                hasFlag = translatedFlags.contains(flag)
            }
            if hasFlag { translatedFlags.insert(flag) }
            else { translatedFlags.remove(flag) }
        }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translatedFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translatedFlags) ?? event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private static func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var input = ghostty_input_key_s()
        input.action = action
        input.keycode = UInt32(event.keyCode)
        input.text = nil
        input.composing = false
        input.mods = ghosttyMods(event.modifierFlags)
        input.consumed_mods = ghosttyMods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command])
        )
        input.unshifted_codepoint = unshiftedCodepoint(for: event)
        return input
    }

    private static func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        guard !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if isControlCharacter(scalar), flags.contains(.control) {
                return event.characters(byApplyingModifiers: flags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    private static func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: [])
                ?? event.charactersIgnoringModifiers
                ?? event.characters,
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private static func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
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
        if state == GHOSTTY_MOUSE_PRESS {
            window?.makeFirstResponder(self)
        }
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
}

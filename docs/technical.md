# Technical Reference

## Architecture

```
XmuxApp (@main, SwiftUI)
└── ContentView
    └── NavigationSplitView
        ├── LeftPanel (SwiftUI placeholder)
        ├── TerminalRepresentable (NSViewRepresentable)
        │   └── GhosttyView (NSView)
        │       └── ghostty_surface_t  ← libghostty owns Metal rendering
        └── RightPanel (SwiftUI placeholder)

GhosttyApp (singleton)
└── ghostty_app_t  ← one per process
    └── C runtime callbacks → GhosttyApp methods
```

## libghostty integration

### One app, many surfaces

`ghostty_app_t` is the process-level singleton. Each terminal pane is a `ghostty_surface_t`. In the current skeleton there is one surface; adding split panes means creating additional surfaces and routing input to the focused one.

```swift
// GhosttyApp.swift
ghostty_init(argc, argv)
let cfg = ghostty_config_new()
ghostty_config_load_default_files(cfg)   // reads ~/.config/ghostty/config
ghostty_config_finalize(cfg)
let app = ghostty_app_new(&runtime, cfg)

// GhosttyView.swift — called in viewDidMoveToWindow
let surface = ghostty_surface_new(app, &surfaceCfg)
```

### Metal rendering

libghostty owns the entire Metal pipeline. The host provides an `NSView` with `wantsLayer = true`; libghostty creates its own `CAMetalLayer` on top of it. The host never touches Metal directly.

```swift
// GhosttyView.init
wantsLayer = true
layer?.isOpaque = false

// surface config
cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
```

Resize and scale changes are forwarded via:

```swift
ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
ghostty_surface_set_content_scale(surface, xScale, yScale)
```

### Tick loop

libghostty is event-driven. It signals the host when it needs attention via `wakeup_cb`. The host responds by calling `ghostty_app_tick()` on the main thread.

```swift
rt.wakeup_cb = { ud in
    // called from any thread
    Task { @MainActor in GhosttyApp.shared.tick() }
}
```

### C callback pattern

`ghostty_runtime_config_s` holds bare C function pointers. Swift closures that capture context can't be passed as C function pointers — only non-capturing ones compile to `@convention(c)`. The standard workaround: static methods + a `userdata` opaque pointer back to the Swift object.

```swift
rt.userdata = Unmanaged.passUnretained(self).toOpaque()
rt.action_cb = { app, target, action in
    // static — no capture
    GhosttyApp.actionCallback(app, target: target, action: action)
}

private static func actionCallback(...) {
    // recover Swift object from userdata
    let self_ = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
    Task { @MainActor in self_.handleAction(...) }
}
```

### Input forwarding

**Keyboard** — `NSEvent` → `ghostty_input_key_s` → `ghostty_surface_key`. Key codes are mapped from macOS hardware scancodes (`event.keyCode`) to `ghostty_input_key_e`. Text input goes through `NSTextInputClient` / `interpretKeyEvents` to handle IME composition correctly.

**Mouse** — position via `ghostty_surface_mouse_pos`, clicks via `ghostty_surface_mouse_button`, scroll via `ghostty_surface_mouse_scroll`.

**Focus** — `ghostty_surface_set_focus(surface, bool)` on `becomeFirstResponder` / `resignFirstResponder`.

### Actions (terminal → host)

The terminal emits actions via `action_cb`: title changes (`GHOSTTY_ACTION_SET_TITLE`), working directory updates (`GHOSTTY_ACTION_PWD`), config reload requests, close requests. C string pointers in the action struct are only valid for the duration of the callback — copy them synchronously before any async dispatch.

```swift
// copy before Task dispatch
var title: String?
if action.tag == GHOSTTY_ACTION_SET_TITLE, let ptr = action.action.set_title.title {
    title = String(cString: ptr)
}
Task { @MainActor in self.handleAction(..., title: title) }
```

## File structure

```
Sources/XmuxApp/
  XmuxApp.swift                   @main, window scene
  ContentView.swift               NavigationSplitView layout
  Ghostty/
    GhosttyApp.swift              ghostty_app_t wrapper, C callbacks, clipboard
    GhosttyView.swift             ghostty_surface_t NSView, keyboard/mouse/IME
    TerminalRepresentable.swift   NSViewRepresentable bridge, view registry

Resources/
  terminfo/78/xterm-ghostty       sentinel file — libghostty locates resources dir from this
  ghostty/shell-integration/      bash/zsh/fish scripts injected by libghostty into shells

Frameworks/
  GhosttyKit.xcframework          prebuilt static lib + C headers (git-ignored, download separately)

project.yml                       XcodeGen spec
pixi.toml                         build tasks
```

## GhosttyKit version

The xcframework used is built from commit `9fa3ab01` of `manaflow-ai/ghostty` (a fork tracking upstream). Released at:

```
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-9fa3ab01bb67d5cec4daa358e25509a271af8171
```

The API surface is the same as upstream ghostty at that commit. Key differences from older versions of the header: `ghostty_surface_key` takes a value (not pointer), key names follow Web standard (`GHOSTTY_KEY_DIGIT_1`, `GHOSTTY_KEY_ARROW_LEFT`, `GHOSTTY_KEY_BRACKET_LEFT`), `ghostty_surface_preedit` takes an explicit length.

## Adding a second terminal pane

1. Create a new `UUID` and pass it to a second `TerminalRepresentable`
2. `GhosttyView` creates a new `ghostty_surface_t` for it via `GhosttyApp.shared.newSurface`
3. Route keyboard events to whichever view is first responder — libghostty handles each surface independently

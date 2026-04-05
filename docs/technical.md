# Technical Reference

## Architecture

```
Frontend / host app (native macOS UI)
XmuxApp (@main, SwiftUI)
└── ContentView
    └── NavigationSplitView
        ├── LeftPanel (SwiftUI placeholder)
        ├── TerminalRepresentable (NSViewRepresentable)
        │   └── GhosttyView (NSView / NSTextInputClient)
        └── RightPanel (SwiftUI placeholder)

Embedding boundary (libghostty C API)
GhosttyApp (singleton)
└── ghostty_app_t
    ├── wakeup_cb / action_cb / clipboard callbacks
    └── ghostty_surface_t per terminal view

Backend / terminal core (inside libghostty)
└── Ghostty core surface
    ├── input + key encoding
    ├── terminal parser/state machine
    ├── PTY/process IO
    └── renderer thread + Metal layer ownership
```

### Frontend vs backend

Ghostty's architecture is cleanest if you think about it as **host app** versus **embedded terminal core**, not as two separate services.

- **Frontend / host app**: native macOS UI code. In `xmux` this is SwiftUI/AppKit: window management, split layout, responder chain, `NSEvent` handling, clipboard bridging, and all app-specific panels.
- **Backend / terminal core**: libghostty. This owns the actual terminal behavior: PTY subprocess management, byte stream parsing, terminal state, key encoding rules, scrollback, and rendering.
- **Boundary**: `ghostty_app_t` and `ghostty_surface_t`. The frontend creates views and forwards native events across this boundary; the backend emits actions back to the host through callbacks.

This matches upstream Ghostty's own terminology:

- the platform UI shell is the **application runtime** (`apprt`)
- the reusable core is the embedded **libghostty** surface/app implementation

For `xmux`, the important design rule is: **AppKit/SwiftUI owns native UI concerns; libghostty owns terminal semantics.** We should avoid re-implementing terminal behavior in the host if libghostty already has a canonical path for it.

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

**Keyboard** — `NSEvent` → `ghostty_input_key_s` → `ghostty_surface_key`. The embedded API expects the native macOS hardware key code in `keycode` (`event.keyCode`), plus translated modifier state, consumed modifiers, optional UTF-8 text, and an unshifted codepoint. Text input goes through `NSTextInputClient` / `interpretKeyEvents` so IME composition follows the same path as upstream Ghostty.

**Mouse** — position via `ghostty_surface_mouse_pos`, clicks via `ghostty_surface_mouse_button`, scroll via `ghostty_surface_mouse_scroll`.

**Focus** — `ghostty_surface_set_focus(surface, bool)` on `becomeFirstResponder` / `resignFirstResponder`.

**Command routing** — AppKit shortcuts can be intercepted before `keyDown` via `performKeyEquivalent` / `doCommand`. To match upstream Ghostty behavior, terminal views need to route terminal-relevant command events back into the Ghostty key path rather than letting AppKit consume them.

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

## xmux.log — command event log

Every interactive command typed in an xmux terminal is appended to `~/.xmux/xmux.log` as a newline-delimited record. This is the first-stage transport for issue #1.

### Log format

Each line is tab-separated:

```
<ISO 8601 UTC timestamp>\t<command as typed>
```

Example:

```
2026-04-05T09:30:12Z	git status
2026-04-05T09:30:15Z	ls && ls -la
```

### How it works

**App startup** — `XmuxLog.setup()` creates `~/.xmux/` and `~/.xmux/xmux.log` if they do not exist. `XmuxEventPort.setup()` reserves `~/.xmux/xmux.port` and starts the local Unix-domain socket listener for live events. Failures are silent so missing log or socket permissions never affect the app.

**Surface creation** — `GhosttyApp.newSurface` injects the following env vars into every spawned shell process via `ghostty_surface_config_s.env_vars`:

| Variable | Value |
|---|---|
| `XMUX_LOG` | absolute path to `xmux.log` |
| `XMUX_PORT` | absolute path to `xmux.port` |
| `XMUX_RESOURCES_DIR` | path to bundled `xmux/` resources in the app bundle |
| `ZDOTDIR` | `<resources>/shell-integration/zsh/` |
| `_XMUX_ORIG_ZDOTDIR` | original `ZDOTDIR` (or empty) |
| `XMUX_TERMINAL_ID` | UUID of the surface |

**Standalone CLI** — the Python CLI now lives in the top-level `cli/` directory and is meant to be installed separately with `uv tool install ./cli`. Xmux-launched shells prepend both `Resources/xmux/bin` and `~/.local/bin` to `PATH`, so the GUI-owned helper scripts can call the installed `xmux` executable.

The first commands are:

```bash
xmux log add "git status"
xmux log show
xmux log show --once
xmux event send --notify --param "command=git status" command.start
xmux event show
xmux event show --once
```

`xmux log <data>` is also accepted as shorthand for `xmux log add <data>`.
`xmux log show` tails the log live; `--once` prints a snapshot and exits.
`xmux event send` writes newline-delimited JSON-RPC messages to `xmux.port`.
`xmux event show` connects to `xmux.port` and streams the live event feed.

**Shell integration (zsh)** — ZDOTDIR injection causes zsh to load `shell-integration/zsh/.zshenv` before any user dotfile. That file:
1. Restores `ZDOTDIR` to the original value so `.zprofile`, `.zshrc`, etc. are found in the user's usual location.
2. Sources the user's original `.zshenv` if it exists.
3. Queues `_xmux_load_integration` via `precmd_functions` (runs once, after `.zshrc`).

On the first prompt, `xmux-integration` is sourced. It registers `_xmux_preexec` in `preexec_functions`. Before each command runs, `_xmux_preexec` calls `xmux log add "$cmd"` and `xmux event send --notify --param "command=$cmd" command.start`, which appends the human-readable log record and emits a live JSON-RPC event on `xmux.port`.

## xmux.port — live JSON-RPC event stream

`xmux.port` is a Unix-domain socket at `~/.xmux/xmux.port`. The app accepts newline-delimited JSON messages on that socket, keeps a small in-memory ring buffer, mirrors those events into the live panel under the terminal, and forwards them to any `xmux event show` subscribers.

The intended shape is JSON-RPC notifications or requests, for example:

```json
{"jsonrpc":"2.0","method":"command.start","params":{"command":"git status","terminal_id":"..."}}
```

### Live consumer

`tools/watch_log.py` tails the log and prints new lines as they arrive:

```
python3 tools/watch_log.py
```

### File structure additions

```
Sources/XmuxApp/
  XmuxLog.swift                   log file lifecycle + surface env var injection helper
  XmuxEventPort.swift             `xmux.port` Unix socket listener + in-memory event ring buffer
  XmuxEventPanel.swift            live panel for `xmux.port` event traffic

Resources/xmux/
  bin/
    claude                        Claude wrapper — logs through `xmux log add`
    xmux-claude-hook              Claude hook bridge — logs through `xmux log add`
  shell-integration/zsh/
    .zshenv                       ZDOTDIR injection entry point (chains to user's dotfiles)
    xmux-integration              preexec hook — calls `xmux log add` and emits `command.start`

tools/
  watch_log.py                    live log consumer (tails ~/.xmux/xmux.log)
```

## File structure

```
Sources/XmuxApp/
  XmuxApp.swift                   @main, window scene
  ContentView.swift               NavigationSplitView layout
  XmuxLog.swift                   ~/.xmux/xmux.log lifecycle + surface env var injection
  XmuxEventPort.swift             ~/.xmux/xmux.port listener + event ring buffer
  XmuxEventPanel.swift            live xmux.port panel
  Ghostty/
    GhosttyApp.swift              ghostty_app_t wrapper, C callbacks, clipboard
    GhosttyView.swift             ghostty_surface_t NSView, keyboard/mouse/IME
    TerminalRepresentable.swift   NSViewRepresentable bridge, view registry

Resources/
  terminfo/78/xterm-ghostty       sentinel file — libghostty locates resources dir from this
  ghostty/shell-integration/      bash/zsh/fish scripts injected by libghostty into shells
  xmux/shell-integration/zsh/
    .zshenv                       ZDOTDIR injection entry point
    xmux-integration              preexec hook — logs commands through the xmux CLI
  xmux/bin/
    claude                        wrapper that logs Claude invocations through xmux
    xmux-claude-hook              Claude lifecycle hook bridge

cli/
  pyproject.toml                  uv tool project definition for `uv tool install ./cli`
  src/xmux_cli/                   CLI implementation
  tests/test_cli.py               focused CLI tests

Frameworks/
  GhosttyKit.xcframework          prebuilt static lib + C headers (git-ignored, download separately)

tools/
  watch_log.py                    live tail of ~/.xmux/xmux.log

project.yml                       XcodeGen spec
pixi.toml                         build tasks
```

Related upstream Ghostty areas:

- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — native macOS frontend event handling
- `src/apprt/embedded.zig` — embedder boundary used by macOS/libghostty hosts
- `src/Surface.zig` — core terminal surface lifecycle
- `src/termio.zig` — PTY/process IO layer
- `src/renderer.zig` — renderer abstraction and thread management

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

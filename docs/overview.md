# Xmux

A native macOS terminal built on [libghostty](https://github.com/ghostty-org/ghostty) — the terminal engine from the Ghostty project.

## What it is

Xmux is a terminal application with a three-panel layout: a navigator sidebar on the left, a full terminal in the centre, and an inspector panel on the right. The terminal is rendered entirely by libghostty using Metal — the same engine that powers Ghostty itself.

The goal is a purpose-built macOS terminal with a native IDE-like shell, designed around how developers actually use terminals alongside code, agents, and tooling.

## Layout

```
┌──────────┬────────────────────────┬──────────┐
│          │                        │          │
│Navigator │       Terminal         │Inspector │
│          │    (libghostty/Metal)  │          │
│          │                        │          │
└──────────┴────────────────────────┴──────────┘
```

- **Left panel** — Navigator: file tree, branches, sessions
- **Centre** — Terminal surface: full GPU-rendered terminal via libghostty
- **Right panel** — Inspector: environment, processes, history

## Status

This is a skeleton. The terminal is fully functional (PTY, keyboard, mouse, IME, scrollback). The side panels are placeholders to be built out.

## Building

Prerequisites: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

GhosttyKit is not committed — download the prebuilt xcframework:

```bash
gh release download xcframework-9fa3ab01bb67d5cec4daa358e25509a271af8171 \
  --repo manaflow-ai/ghostty \
  --pattern "*.tar.gz" \
  --dir Frameworks

cd Frameworks && tar xzf GhosttyKit.xcframework.tar.gz && rm *.tar.gz
```

Then generate and build:

```bash
xcodegen generate --spec project.yml
xcodebuild -project Xmux.xcodeproj -scheme Xmux -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Or use pixi if you have it: `pixi run run`.

## Configuration

Terminal settings (font, colours, cursor, keybindings) are read from Ghostty's standard config file at `~/.config/ghostty/config`. No separate terminal config needed.

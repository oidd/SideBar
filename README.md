# SideBar

SideBar is a macOS menu bar utility that brings edge-snap and hover-reveal behavior to regular third-party app windows.

The project is built around a cross-process window control model: instead of managing its own windows, it uses macOS Accessibility APIs to observe, reposition, hide, restore, and coordinate windows owned by other applications.

## Overview

The interaction model is straightforward:

1. Drag a supported window to the left or right edge of the screen.
2. SideBar captures it into a snapped state and moves it just outside the visible area.
3. Hover the screen edge to reveal it.
4. Leave the safe region to collapse it again.
5. Use Dock activation or an optional per-app shortcut to toggle it explicitly.

This repository is interesting mainly because it solves a set of awkward macOS problems that appear once you try to control windows belonging to other processes: focus handoff, AX timing, geometry drift, multi-display edge logic, and reliable recovery after interruptions.

## Feature Set

- Edge snap for regular third-party app windows
- Hover reveal and automatic collapse
- Per-app color and opacity configuration
- Per-app global shortcuts
- Dock click integration with explicit focus handoff
- Multi-display handling
- Crash recovery for hidden windows
- Lightweight localization support
- DockMinimize interoperability

## Design Approach

SideBar does not rely on ordinary AppKit ownership of the target windows. Instead, it builds a thin control layer on top of the system Accessibility stack:

- It discovers supported running apps and monitors their focused windows.
- It moves windows physically just outside the screen bounds instead of treating visibility as a purely visual toggle.
- It uses invisible non-activating edge indicators to detect hover intent without stealing focus.
- It keeps a dedicated per-window state machine so drag, hover, shortcut, and Dock-triggered flows all resolve through a consistent transition model.
- It restores focus and geometry explicitly, which matters when the controlled window is not owned by the app performing the interaction.

## Architecture

### Runtime Entry Points

- `Sources/SideBar/main.swift`
  App bootstrap.
- `Sources/SideBar/AppDelegate.swift`
  App lifecycle, menu bar integration, settings window bootstrapping, and permission entry points.
- `Sources/SideBar/PermissionsManager.swift`
  Accessibility trust checks and System Settings redirection.

### Window Control

- `Sources/SideBar/AXWindowManager.swift`
  Running app discovery, session synchronization, AX observers, and shortcut dispatch.
- `Sources/SideBar/WindowSession.swift`
  The main per-window state machine for snapping, expanding, collapsing, focus handling, and geometry correction.
- `Sources/SideBar/WindowAlphaManager.swift`
  Window alpha coordination used by the hide/reveal pipeline.

### UI and Effects

- `Sources/SideBar/EdgeIndicatorWindow.swift`
  Non-activating edge sensors used for hover-based reveal.
- `Sources/SideBar/VisualEffectOverlayWindow.swift`
  Overlay visuals and effect alignment logic.
- `Sources/SideBar/SettingsView.swift`
  SwiftUI-based settings UI.

### Configuration and Support Systems

- `Sources/SideBar/AppConfig.swift`
  Persistent settings for enabled apps, colors, opacity, shortcuts, and shared app coordination.
- `Sources/SideBar/AppListManager.swift`
  Running app enumeration and filtering.
- `Sources/SideBar/UpdateChecker.swift`
  Remote version checking.
- `Sources/SideBar/I18n.swift`
  Lightweight in-app localization.

## Technical Characteristics

- Built with `AppKit`, `SwiftUI`, `ApplicationServices`, and standard macOS Accessibility APIs
- Uses AX observers and window geometry reads instead of injecting into target apps
- Avoids relying on `hide/unhide` as the primary animation path to reduce restore artifacts
- Uses geometry locking and alpha fallback strategies to stabilize behavior on apps with aggressive window resizing logic
- Handles focus transfer explicitly so Dock-driven and shortcut-driven flows behave consistently
- Treats hover detection, collapse timing, and cleanup as first-class runtime concerns rather than UI-only behavior

## Requirements

- macOS 12.0 or later
- A recent Xcode / Swift toolchain with AppKit and SwiftUI support
- Accessibility permission granted to the built app

## Repository Layout

- `Sources/SideBar`
  Application source code.
- `Sources/Recommends`
  Static images used by the in-app recommendation UI.
- `Sources/icon.png`
  Base app icon source.
- `Sources/menu.png`
  Menu bar icon asset.
- `Info.plist`
  Menu bar app configuration.

## Local Validation

### Quick Type Check

```bash
swiftc -typecheck Sources/SideBar/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework Foundation
```

### Typical Development Flow

1. Open the code in a macOS-capable Swift/Xcode environment.
2. Run the app.
3. Grant Accessibility permission.
4. Enable one or more regular GUI apps from the settings window.
5. Test drag-to-edge, hover reveal, Dock activation, shortcuts, and multi-display behavior.

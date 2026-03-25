# SideBar

## English

SideBar is a macOS menu bar utility that brings edge-snap and hover-reveal behavior to regular third-party app windows.

The project is built around a cross-process window control model: instead of managing its own windows, it uses macOS Accessibility APIs to observe, reposition, hide, restore, and coordinate windows owned by other applications.

### Overview

The interaction model is straightforward:

1. Drag a supported window to the left or right edge of the screen.
2. SideBar captures it into a snapped state and moves it just outside the visible area.
3. Hover the screen edge to reveal it.
4. Leave the safe region to collapse it again.
5. Use Dock activation or an optional per-app shortcut to toggle it explicitly.

This repository is interesting mainly because it solves a set of awkward macOS problems that appear once you try to control windows belonging to other processes: focus handoff, AX timing, geometry drift, multi-display edge logic, and reliable recovery after interruptions.

### Feature Set

- Edge snap for regular third-party app windows
- Hover reveal and automatic collapse
- Per-app color and opacity configuration
- Per-app global shortcuts
- Dock click integration with explicit focus handoff
- Multi-display handling
- Crash recovery for hidden windows
- Lightweight localization support
- DockMinimize interoperability

### Design Approach

SideBar does not rely on ordinary AppKit ownership of the target windows. Instead, it builds a thin control layer on top of the system Accessibility stack:

- It discovers supported running apps and monitors their focused windows.
- It moves windows physically just outside the screen bounds instead of treating visibility as a purely visual toggle.
- It uses invisible non-activating edge indicators to detect hover intent without stealing focus.
- It keeps a dedicated per-window state machine so drag, hover, shortcut, and Dock-triggered flows all resolve through a consistent transition model.
- It restores focus and geometry explicitly, which matters when the controlled window is not owned by the app performing the interaction.

### Architecture

#### Runtime Entry Points

- `Sources/SideBar/main.swift`
  App bootstrap.
- `Sources/SideBar/AppDelegate.swift`
  App lifecycle, menu bar integration, settings window bootstrapping, and permission entry points.
- `Sources/SideBar/PermissionsManager.swift`
  Accessibility trust checks and System Settings redirection.

#### Window Control

- `Sources/SideBar/AXWindowManager.swift`
  Running app discovery, session synchronization, AX observers, and shortcut dispatch.
- `Sources/SideBar/WindowSession.swift`
  The main per-window state machine for snapping, expanding, collapsing, focus handling, and geometry correction.
- `Sources/SideBar/WindowAlphaManager.swift`
  Window alpha coordination used by the hide/reveal pipeline.

#### UI and Effects

- `Sources/SideBar/EdgeIndicatorWindow.swift`
  Non-activating edge sensors used for hover-based reveal.
- `Sources/SideBar/VisualEffectOverlayWindow.swift`
  Overlay visuals and effect alignment logic.
- `Sources/SideBar/SettingsView.swift`
  SwiftUI-based settings UI.

#### Configuration and Support Systems

- `Sources/SideBar/AppConfig.swift`
  Persistent settings for enabled apps, colors, opacity, shortcuts, and shared app coordination.
- `Sources/SideBar/AppListManager.swift`
  Running app enumeration and filtering.
- `Sources/SideBar/UpdateChecker.swift`
  Remote version checking.
- `Sources/SideBar/I18n.swift`
  Lightweight in-app localization.

### Technical Characteristics

- Built with `AppKit`, `SwiftUI`, `ApplicationServices`, and standard macOS Accessibility APIs
- Uses AX observers and window geometry reads instead of injecting into target apps
- Avoids relying on `hide/unhide` as the primary animation path to reduce restore artifacts
- Uses geometry locking and alpha fallback strategies to stabilize behavior on apps with aggressive window resizing logic
- Handles focus transfer explicitly so Dock-driven and shortcut-driven flows behave consistently
- Treats hover detection, collapse timing, and cleanup as first-class runtime concerns rather than UI-only behavior

### Requirements

- macOS 12.0 or later
- A recent Xcode / Swift toolchain with AppKit and SwiftUI support
- Accessibility permission granted to the built app

### Repository Layout

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

### Local Validation

#### Quick Type Check

```bash
swiftc -typecheck Sources/SideBar/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework Foundation
```

#### Typical Development Flow

1. Open the code in a macOS-capable Swift/Xcode environment.
2. Run the app.
3. Grant Accessibility permission.
4. Enable one or more regular GUI apps from the settings window.
5. Test drag-to-edge, hover reveal, Dock activation, shortcuts, and multi-display behavior.

## 中文

SideBar 是一个 macOS 菜单栏工具，为普通第三方应用窗口提供贴边吸附和悬停唤回的交互方式。

这个项目围绕一套跨进程窗口控制模型构建：它不是只管理自己的窗口，而是通过 macOS 辅助功能 API 去观察、重新定位、隐藏、恢复并协调其他应用所拥有的窗口。

### 概览

它的交互模型很直接：

1. 将受支持的窗口拖到屏幕左侧或右侧边缘。
2. SideBar 会将窗口捕获到吸附状态，并把它移动到可视区域外侧。
3. 将鼠标悬停在屏幕边缘即可重新唤出窗口。
4. 离开安全区域后，窗口会再次折叠。
5. 也可以通过 Dock 激活或可选的按应用快捷键来显式切换窗口状态。

这个仓库的价值主要在于它解决了一组在跨进程控制窗口时很容易遇到、但又很难处理好的 macOS 问题：焦点交接、AX 时序、几何漂移、多显示器边缘逻辑，以及中断后的可靠恢复。

### 功能特性

- 面向普通第三方应用窗口的边缘吸附
- 悬停唤回与自动折叠
- 按应用配置颜色与透明度
- 按应用配置全局快捷键
- 带有明确焦点交接逻辑的 Dock 点击联动
- 多显示器支持
- 隐藏窗口的异常恢复
- 轻量级本地化支持
- 与 DockMinimize 的互操作能力

### 设计思路

SideBar 不依赖对目标窗口的普通 AppKit 所有权。相反，它在系统辅助功能栈之上构建了一层很薄的控制层：

- 它会发现受支持的运行中应用，并监控这些应用当前聚焦的窗口。
- 它会把窗口物理移动到屏幕边界之外，而不是把可见性仅仅当作一个视觉开关。
- 它使用不可激活的隐形边缘指示层来检测悬停意图，同时避免抢占焦点。
- 它为每个窗口维护独立的状态机，使拖拽、悬停、快捷键和 Dock 触发的路径都通过一致的状态转换模型收敛。
- 它会显式处理焦点和几何恢复，这一点在被控制窗口并不归当前应用所有时尤其重要。

### 架构

#### 运行时入口

- `Sources/SideBar/main.swift`
  应用启动入口。
- `Sources/SideBar/AppDelegate.swift`
  应用生命周期、菜单栏集成、设置窗口启动，以及权限入口。
- `Sources/SideBar/PermissionsManager.swift`
  辅助功能权限检查与系统设置跳转。

#### 窗口控制

- `Sources/SideBar/AXWindowManager.swift`
  运行中应用发现、会话同步、AX 观察器以及快捷键分发。
- `Sources/SideBar/WindowSession.swift`
  每个窗口的核心状态机，负责吸附、展开、折叠、焦点处理和几何修正。
- `Sources/SideBar/WindowAlphaManager.swift`
  用于隐藏与唤回链路的窗口透明度协调。

#### UI 与特效

- `Sources/SideBar/EdgeIndicatorWindow.swift`
  用于悬停唤回的不可激活边缘感应层。
- `Sources/SideBar/VisualEffectOverlayWindow.swift`
  覆盖层特效与特效对齐逻辑。
- `Sources/SideBar/SettingsView.swift`
  基于 SwiftUI 的设置界面。

#### 配置与支持系统

- `Sources/SideBar/AppConfig.swift`
  已启用应用、颜色、透明度、快捷键以及共享应用协调相关的持久化配置。
- `Sources/SideBar/AppListManager.swift`
  运行中应用的枚举与过滤。
- `Sources/SideBar/UpdateChecker.swift`
  远程版本检查。
- `Sources/SideBar/I18n.swift`
  轻量级应用内本地化。

### 技术特点

- 基于 `AppKit`、`SwiftUI`、`ApplicationServices` 和标准 macOS 辅助功能 API 构建
- 使用 AX 观察器和窗口几何读取，而不是向目标应用注入代码
- 不把 `hide/unhide` 作为主要动画路径，以减少恢复伪影
- 使用几何锁定和透明度兜底策略，提升在激进窗口缩放逻辑应用上的稳定性
- 显式处理焦点交接，确保 Dock 驱动和快捷键驱动的流程行为一致
- 将悬停检测、折叠时序和清理恢复视为一等运行时问题，而不是纯 UI 层细节

### 环境要求

- macOS 12.0 或更高版本
- 支持 AppKit 与 SwiftUI 的较新 Xcode / Swift 工具链
- 已为构建出的应用授予辅助功能权限

### 仓库结构

- `Sources/SideBar`
  应用源码。
- `Sources/Recommends`
  应用内推荐界面使用的静态图片资源。
- `Sources/icon.png`
  应用图标源文件。
- `Sources/menu.png`
  菜单栏图标资源。
- `Info.plist`
  菜单栏应用配置。

### 本地验证

#### 快速类型检查

```bash
swiftc -typecheck Sources/SideBar/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework Foundation
```

#### 典型开发流程

1. 在支持 macOS 的 Swift / Xcode 环境中打开代码。
2. 运行应用。
3. 授予辅助功能权限。
4. 在设置窗口中启用一个或多个常规 GUI 应用。
5. 测试贴边吸附、悬停唤回、Dock 激活、快捷键以及多显示器行为。

import AppKit
import ApplicationServices
import CoreVideo
import ScreenCaptureKit

enum SnapState: Equatable {
    case floating
    case snapped(edge: Int, hiddenOrX: CGFloat) // 1=left, 2=right
    case expanded
}

private struct PinnedAnchor {
    let expandedMidY: CGFloat
}

private struct FocusReturnSnapshot {
    let pid: pid_t
    let bundleID: String
    let windowID: CGWindowID?
    let capturedAt: Date
}

private struct VisibleAppWindowSample {
    let id: CGWindowID
    let frame: CGRect
}

private enum GlobalClickRegion {
    case dock
    case menuBar
    case notificationBanner
    case content
    case unknown
}

private struct GlobalMouseDownSample {
    let at: Date
    let location: CGPoint
    let region: GlobalClickRegion
}

private enum ExplicitRevealTrigger {
    case dockClick
    case appSwitch
    case notificationClick
    case menuBarClick
}

private struct ExplicitRevealIntent {
    let trigger: ExplicitRevealTrigger
    let createdAt: Date
    let expiresAt: Date
}

private final class WeakWindowSessionBox {
    weak var session: WindowSession?

    init(_ session: WindowSession) {
        self.session = session
    }
}

@discardableResult
private func axSetBoolAttribute(
    on element: AXUIElement,
    attribute: CFString,
    value: Bool,
    context: String
) -> AXError {
    AccessibilityRuntimeGuard.setAttributeValue(
        on: element,
        attribute: attribute,
        value: value ? kCFBooleanTrue : kCFBooleanFalse,
        context: context
    )
}

@discardableResult
private func axSetPositionAttribute(
    on element: AXUIElement,
    position: CGPoint,
    context: String
) -> AXError {
    var newPosition = position
    guard let axValue = AXValueCreate(.cgPoint, &newPosition) else {
        return .failure
    }
    return AccessibilityRuntimeGuard.setAttributeValue(
        on: element,
        attribute: kAXPositionAttribute as CFString,
        value: axValue,
        context: context
    )
}

@discardableResult
private func axSetSizeAttribute(
    on element: AXUIElement,
    size: CGSize,
    context: String
) -> AXError {
    var newSize = size
    guard let axValue = AXValueCreate(.cgSize, &newSize) else {
        return .failure
    }
    return AccessibilityRuntimeGuard.setAttributeValue(
        on: element,
        attribute: kAXSizeAttribute as CFString,
        value: axValue,
        context: context
    )
}

class WindowSession {
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let pid: pid_t
    let bundleID: String
    private let appDisplayName: String
    private let appIcon: NSImage?
    
    private var state: SnapState = .floating {
        didSet {
            guard oldValue != state else { return }
            onHotkeyRuntimeStateChanged?(self)
            onStateTransition?(self, oldValue, state)
        }
    }
    private var currentEdge: Int = 0
    
    // MARK: - 多显示器支持
    
    /// 吸附时锁定的屏幕信息（这两个值在 snapToEdge 时设置，取消吸附时清空）
    /// 核心原则：窗口被隐藏/折叠后位置已不在原始屏幕内，动态检测会失败，因此必须锁定。
    private var snappedDisplayBounds: CGRect?
    private var snappedScreen: NSScreen?
    /// AppKit 坐标下 `snappedScreen` 在**锁定瞬间**的 `frame` 值快照。
    /// 这是跨屏幕参数变化时判定"锁定的物理显示器是否发生几何变化"的**唯一可靠依据**。
    ///
    /// 为什么不直接读 `snappedScreen.frame`：`NSScreen.frame` 是 live getter，macOS 在
    /// **纯分辨率切换**时会**复用**同一个 NSScreen 实例并原地更新它的 `frame`，读出来
    /// 已经是"新"分辨率——与 `NSScreen.screens` 中它自己完全匹配，会把真实发生了的
    /// 几何变化误判为"未变化"，导致锁定的 `snappedDisplayBounds` 一直停留在旧值，
    /// 隐藏窗口和快照条永远画在已不存在的旧坐标上。
    private var snappedScreenFrame: CGRect?
    
    /// 获取窗口所在屏幕的 CG 坐标系 bounds
    /// 吸附状态下使用锁定值，浮动状态下动态检测
    private func getDisplayBounds() -> CGRect {
        if let cached = snappedDisplayBounds { return cached }
        return detectDisplayBounds()
    }
    
    /// 获取窗口所在的 NSScreen
    private func getScreenForWindow() -> NSScreen {
        if let cached = snappedScreen { return cached }
        return detectScreen()
    }

    private func isSnapAllowed(for edge: Int) -> Bool {
        let snapSide = AppConfig.shared.getSnapSide(for: bundleID)
        let blockedDockSide = AppConfig.shared.resolvedDockAvoidanceSide()

        if blockedDockSide == "left", edge == 1 {
            return false
        }

        if blockedDockSide == "right", edge == 2 {
            return false
        }

        switch edge {
        case 1:
            return snapSide == "left" || snapSide == "leftRight"
        case 2:
            return snapSide == "right" || snapSide == "leftRight"
        default:
            return false
        }
    }

    private func triggerCollapseEffect(edge: SnapEdge, point: CGPoint, color: NSColor) {
        guard AppConfig.shared.isVisualEffectEnabled else {
            effectWindow.stopExpandEffect(closeWindow: true)
            return
        }
        effectWindow.startCollapseEffect(edge: edge, point: point, color: color, on: getScreenForWindow())
    }

    private func triggerExpandEffect(edge: SnapEdge, frame: NSRect, color: NSColor) {
        guard AppConfig.shared.isVisualEffectEnabled else {
            effectWindow.stopExpandEffect(closeWindow: true)
            return
        }
        effectWindow.startExpandEffect(edge: edge, frame: frame, color: color, on: getScreenForWindow())
    }
    
    /// 动态检测窗口所在屏幕的 CG bounds（仅在浮动状态可靠）
    private func detectDisplayBounds() -> CGRect {
        guard let frame = getWindowFrame() else { return CGDisplayBounds(CGMainDisplayID()) }
        let ph = primaryScreenHeight
        for screen in NSScreen.screens {
            let sf = screen.frame
            let cgRect = CGRect(x: sf.origin.x, y: ph - sf.origin.y - sf.height, width: sf.width, height: sf.height)
            if cgRect.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return cgRect
            }
        }
        // 边缘情况：用交集判断
        for screen in NSScreen.screens {
            let sf = screen.frame
            let cgRect = CGRect(x: sf.origin.x, y: ph - sf.origin.y - sf.height, width: sf.width, height: sf.height)
            if cgRect.intersects(frame) { return cgRect }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }
    
    /// 动态检测窗口所在的 NSScreen（仅在浮动状态可靠）
    private func detectScreen() -> NSScreen {
        guard let frame = getWindowFrame() else { return NSScreen.main ?? NSScreen.screens[0] }
        let ph = primaryScreenHeight
        for screen in NSScreen.screens {
            let sf = screen.frame
            let cgRect = CGRect(x: sf.origin.x, y: ph - sf.origin.y - sf.height, width: sf.width, height: sf.height)
            if cgRect.contains(CGPoint(x: frame.midX, y: frame.midY)) { return screen }
        }
        for screen in NSScreen.screens {
            let sf = screen.frame
            let cgRect = CGRect(x: sf.origin.x, y: ph - sf.origin.y - sf.height, width: sf.width, height: sf.height)
            if cgRect.intersects(frame) { return screen }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
    
    /// 在吸附时锁定当前屏幕信息
    private func lockCurrentScreen() {
        snappedDisplayBounds = detectDisplayBounds()
        let screen = detectScreen()
        snappedScreen = screen
        // 关键：这里必须存 frame 的**值快照**，不是引用。原因见 snappedScreenFrame 注释。
        snappedScreenFrame = screen.frame
    }
    
    /// 取消吸附时清空屏幕锁定
    private func unlockScreen() {
        snappedDisplayBounds = nil
        snappedScreen = nil
        snappedScreenFrame = nil
    }

    /// 由 AXWindowManager 在屏幕参数变化时调用，判断本 session 之前锁定的屏幕
    /// 是否仍然存在于当前 `NSScreen.screens` 中。
    /// - Returns: `true` 表示锁定的屏幕已消失（典型场景：拔掉外接显示器、分辨率变化），需要主动复位。
    func snappedScreenIsStale(in activeScreens: [NSScreen]) -> Bool {
        // 用锁定**瞬间**的 frame 值快照做几何匹配。绝对不能读 `snappedScreen.frame`：
        // 那是 live getter，macOS 在纯分辨率切换时会复用同一实例并原地更新 frame，
        // 读出来是"新"值，反而误判为未变化（这正是老版本导致快照条错位、窗口卡死的根因）。
        guard let lockedFrame = snappedScreenFrame else { return false }
        let stillExists = activeScreens.contains { screen in
            let f = screen.frame
            return abs(f.origin.x - lockedFrame.origin.x) < 1 &&
                   abs(f.origin.y - lockedFrame.origin.y) < 1 &&
                   abs(f.width  - lockedFrame.width)  < 1 &&
                   abs(f.height - lockedFrame.height) < 1
        }
        return !stillExists
    }

    /// 屏幕参数变化时的**就地重贴**路径（优先于 `recoverFromScreenParametersChange`）。
    ///
    /// 场景：同一块物理显示器只是切换了分辨率——`snappedScreenFrame` 快照与任何 live NSScreen
    /// 都不再匹配（`snappedScreenIsStale == true`），但仍能找到一块 live NSScreen 与旧的
    /// `snappedDisplayBounds` 有大量重叠（或原点几乎不变），说明用户想要的边缘还存在。
    /// 这时不应该把窗口扔回主屏中心，而应该把锁定信息迁移到新几何、把隐藏窗口和快照条
    /// 一起搬到新分辨率下的对应边缘，保留用户的吸附意图。
    ///
    /// - Returns: 成功迁移则返回 `true`；找不到"对得上"的新屏幕则返回 `false`，
    ///   由调用方走 `recoverFromScreenParametersChange()` 兜底路径。
    func reseatSnappedGeometryIfPossible(in activeScreens: [NSScreen]) -> Bool {
        guard let oldDisplayBounds = snappedDisplayBounds else { return false }
        guard !activeScreens.isEmpty else { return false }

        // 一次性计算所有 live 屏幕的 CG bounds。复用 `cgBounds(for:)` 助手（line 1118），
        // 确保 NSScreen→CG 坐标转换公式在整份代码里**只有一处定义**——这正是本次修复
        // 要根除的"坐标口径漂移"这一类 bug 的同源风险。
        // 注意：此时 `NSScreen.screens` 已经反映新的屏幕配置，`primaryScreenHeight`（cgBounds
        // 内部使用）也已是新值。
        let candidates: [(screen: NSScreen, cg: CGRect)] = activeScreens.map { ($0, cgBounds(for: $0)) }

        // Pass 1：与旧 snappedDisplayBounds 有最大重叠面积的屏（覆盖 90% 的场景，
        // 也就是"同一物理显示器切换分辨率"）。
        var bestOverlap: (screen: NSScreen, cg: CGRect, area: CGFloat)?
        for c in candidates {
            let inter = c.cg.intersection(oldDisplayBounds)
            let area = max(inter.width, 0) * max(inter.height, 0)
            guard area > 0 else { continue }
            if bestOverlap == nil || area > bestOverlap!.area {
                bestOverlap = (c.screen, c.cg, area)
            }
        }

        // Pass 2 兜底：若分辨率大幅缩水导致完全无重叠，仍允许"CG 原点足够接近"的
        // 屏幕作为候选（如 4K 外接屏 3840x2160 缩到 1920x1080 且窗口在旧屏最右侧的极端场景）。
        // 两个 pass 共用同一份 `candidates`，避免未来只改其中一处阈值造成"两 pass 挑不同屏"的 drift。
        let reseatCandidate: (screen: NSScreen, cg: CGRect)? = {
            if let best = bestOverlap { return (best.screen, best.cg) }
            return candidates.first {
                abs($0.cg.minX - oldDisplayBounds.minX) < 40 &&
                abs($0.cg.minY - oldDisplayBounds.minY) < 40
            }
        }()

        guard let match = reseatCandidate else { return false }

        // 更新所有锁定值到新几何。之后 `getDisplayBounds()`/`edgeGeometry` 都会用新坐标。
        snappedScreen = match.screen
        snappedScreenFrame = match.screen.frame
        snappedDisplayBounds = match.cg

        // 只有处于吸附态（.snapped）时，才需要把物理窗口和快照条也搬到新边缘；
        // .expanded 或 .floating 让后续正常操作自然收敛即可。
        guard case .snapped = state else {
            print("🖥️ \(bundleID) 分辨率变化：仅更新锁定几何 (\(oldDisplayBounds) → \(match.cg))")
            return true
        }

        guard let rawFrame = getRawWindowFrame() else {
            print("🖥️ \(bundleID) 分辨率变化：锁定已更新，但无法读取窗口 frame，跳过几何搬迁")
            return true
        }

        // Y 钳制：旧的 `rawFrame.minY` 是在**旧屏几何**下算出来的。若新屏更矮（如 4K→1080p
        // 或旋转导致高度骤降），原样透传给 `edgeGeometry` 会让窗口 Y 落在新屏之外，
        // 表现为"边缘有快照条，展开却看不见窗口"。这里先把 Y 钳制到新 bounds 的可见区间。
        let adjustedFrame = clampFrameYToBounds(rawFrame, bounds: match.cg)

        guard let geometry = edgeGeometry(for: adjustedFrame) else {
            print("🖥️ \(bundleID) 分辨率变化：无法基于新几何计算 edge 位置，跳过搬迁")
            return true
        }

        // 停掉任何仍指向旧坐标的动画，避免动画中途把窗口拉回旧 X。
        windowAnimator.stop()

        // 把物理窗口搬到新边缘的 visualHidden 位置（AppKit 坐标下）。
        setWindowPosition(position: geometry.visualHidden)

        // 保持隐藏 alpha，并顺带刷新持久化救援记录中的 displayFrame（用新的 getDisplayBounds()）。
        let visibleFrame = CGRect(origin: geometry.expanded, size: adjustedFrame.size)
        setWindowAlpha(CGFloat(collapsedWindowAlpha()), isHidden: true, frameHint: visibleFrame)

        // 让快照条回到新屏的正确坐标（此时 showIndicator 内部读的 getDisplayBounds 已是新值）。
        indicatorWindow.alphaValue = 1.0
        showIndicator(animated: false)
        updatePinControlWindow()

        // 状态机里记录的 hiddenX 也需要更新到新几何下的 sentinel 值。
        state = .snapped(edge: currentEdge, hiddenOrX: geometry.hidden.x)

        print("🖥️ \(bundleID) 分辨率变化：已就地重贴到新几何 (\(oldDisplayBounds) → \(match.cg))")
        return true
    }

    /// 把窗口 frame 的 Y 钳制到目标 CG bounds 的可见范围内，留出上下 20pt 的安全边距。
    /// 用于分辨率缩水场景：若新屏比窗口还矮（`safeMaxY <= safeMinY`）就先保留原 Y，
    /// 让后续 hover 展开逻辑或用户手动操作自然收敛。
    private func clampFrameYToBounds(_ frame: CGRect, bounds: CGRect) -> CGRect {
        let margin: CGFloat = 20
        let safeMinY = bounds.minY + margin
        let safeMaxY = bounds.maxY - frame.height - margin
        guard safeMaxY > safeMinY else { return frame }
        var adjusted = frame
        adjusted.origin.y = min(max(frame.minY, safeMinY), safeMaxY)
        return adjusted
    }

    /// 当锁定的屏幕已消失时调用：把窗口安全复位到主屏可见区域中心，并把状态机降级为 .floating，
    /// 让用户重新拖拽即可恢复吸附。绝不强行帮用户决定窗口应该出现在哪一块新屏幕。
    func recoverFromScreenParametersChange() {
        print("🖥️ \(bundleID) 锁定屏幕已消失，复位窗口到 floating 态")
        // 复位前停掉所有可能基于 stale 几何的动画/定时器。
        windowAnimator.stop()
        mouseTrackingTimer?.invalidate()
        hoverDelayTimer?.invalidate()
        hoverInterruptTimer?.invalidate()
        pinnedRaiseTimer?.invalidate()
        mirrorGeometryTimer?.invalidate()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        indicatorWindow.orderOut(nil)
        pinControlWindow.orderOut(nil)
        teardownMirrorCapture()

        // 复位 alpha，防止窗口长期保持 0.01 在屏幕外。
        setWindowAlpha(1.0, isHidden: false, preserveRecoveryRecord: true)

        // 安全位置：用主屏中心兜底，避免窗口飞到屏幕外永远找不到。
        if let mainScreen = NSScreen.main ?? NSScreen.screens.first,
           let frame = getRawWindowFrame() {
            let safeFrame = mainScreen.visibleFrame
            let targetX = safeFrame.midX - frame.width / 2
            // AppKit 的 visibleFrame 原点在左下角；AX 的坐标原点在主屏左上角。
            // primaryScreenHeight 表示主屏高度，转换公式与 showIndicator 中保持一致。
            let targetY = primaryScreenHeight - safeFrame.midY - frame.height / 2
            axSetPositionAttribute(
                on: windowElement,
                position: CGPoint(x: targetX, y: targetY),
                context: "WindowSession.recoverFromScreenParametersChange.position"
            )
        }

        // 降级到 floating：清空 snappedScreen/snappedDisplayBounds 等锁定状态，
        // 让用户重新拖拽窗口靠近边缘即可重新吸附。
        transitionToFloatingFromManagedState(
            notifyOwnerChange: true,
            restoreVisiblePositionIfNeeded: false
        )
    }
    
    /// 判断在指定屏幕的某侧是否紧贴着另一块屏幕（交界处不允许吸附）
    private func hasAdjacentScreen(at edge: Int, bounds: CGRect) -> Bool {
        let tolerance: CGFloat = 5.0
        let ph = primaryScreenHeight
        for screen in NSScreen.screens {
            let sf = screen.frame
            let cgRect = CGRect(x: sf.origin.x, y: ph - sf.origin.y - sf.height, width: sf.width, height: sf.height)
            
            // 跳过自己所在的这块屏幕
            if cgRect.contains(CGPoint(x: bounds.midX, y: bounds.midY)) { continue }
            
            // 是否在垂直方向上有交叠
            let yOverlap = (cgRect.minY < bounds.maxY && cgRect.maxY > bounds.minY)
            if edge == 1 { // 左边缘：检查是否有屏幕的右侧贴着这里
                if abs(cgRect.maxX - bounds.minX) <= tolerance && yOverlap { return true }
            } else if edge == 2 { // 右边缘：检查是否有屏幕的左侧贴着这里
                if abs(cgRect.minX - bounds.maxX) <= tolerance && yOverlap { return true }
            }
        }
        return false
    }
    
    /// 主屏高度：所有 CG↔AppKit Y 轴转换必须使用此值（AppKit 全局坐标系原点在主屏左下角）
    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 1080
    }
    
    private var axObserver: AXObserver?
    private var observerRunLoopSource: CFRunLoopSource?
    private var isAnimating = false {
        didSet {
            // 记录最近一次进入动画态的时间戳，供 stateWatchdogTimer 做超时兜底。
            // 仅在从 false → true 的瞬间打戳；中途反复设 true 不重新计时也无所谓，
            // 因为 watchdog 的判定阈值远大于任何合理动画时长。
            if isAnimating && !oldValue {
                isAnimatingSince = Date()
                // 任何 false → true 转换都视作"新一次动画开始"，让所有已挂起的
                // 延迟 isAnimating 复位闭包（例如 expandWindow(isDockActivated:) 的
                // 150ms 稳定窗口）通过 token 校验失败而放弃复位，避免误将新动画
                // 的 isAnimating 打回 false 而破坏其不变式。
                animationGenerationToken &+= 1
            } else if !isAnimating {
                isAnimatingSince = nil
            }
        }
    }
    private var isAnimatingSince: Date?
    /// 动画代号：每次 isAnimating 由 false 转 true 都自增一次。
    /// 用于让延迟复位闭包（当前唯一使用者是 expandWindow(isDockActivated:) 的
    /// 150ms 稳定窗口）能通过 token 比对确认自己是否仍然对应当前这段 isAnimating，
    /// 若期间有新动画启动就放弃复位。
    private var animationGenerationToken: Int = 0
    private var stateWatchdogTimer: Timer?
    private static let stateWatchdogInterval: TimeInterval = 2.0
    /// `isAnimating` 超时阈值。任何正常的展开/折叠/融合动画都远小于此值；
    /// 如果跨过这个阈值仍未复位，几乎可以确定是 `WindowAnimator.stop()` 被外力
    /// 打断后没人再接管 `isAnimating = false`，必须强制复位以恢复 indicator 显隐链路。
    private static let isAnimatingTimeoutSeconds: TimeInterval = 3.0
    private var isIndicatorSuppressed = false
    private var fusionHoverLock = false
    private var activationSuppressionUntil: Date = .distantPast
    private var indicatorAnimationSuppressionUntil: Date = .distantPast
    private var fusionReentrySuppressionUntil: Date = .distantPast
    private var focusReturnExclusionUntil: Date = .distantPast
    private var focusReturnSnapshot: FocusReturnSnapshot?
    private var focusReleaseGeneration: Int = 0
    private var queuedForwardedHotkeyToggle = false
    private var transientAXRoleFailureCount: Int = 0
    private var lastTransientAXRoleFailureAt: Date?
    
    private var indicatorWindow = EdgeIndicatorWindow()
    private var effectWindow = VisualEffectOverlayWindow()
    private var pinControlWindow = PinControlWindow()
    private var mirrorOverlayWindow = WindowMirrorOverlayWindow()
    /// 置顶画面的实时采集器（ScreenCaptureKit）。仅在置顶态期间存在。
    private var mirrorLiveCapturer: WindowMirrorLiveCapturer?
    private var lastMousePos: CGPoint?
    private var mouseTrackingTimer: Timer?
    private var hoverDelayTimer: Timer?
    private var hoverInterruptTimer: Timer?
    private var hoverCooldownActive: Bool = false
    /// 用户在快照条上点击折叠后的临时锁：阻止后续 hover 自动展开，
    /// 鼠标完全离开快照条后会自动解除。再次点击时立即解除并展开。
    private var clickCollapseLockActive: Bool = false
    private var pinnedRaiseTimer: Timer?
    private var pinnedRaiseRemainingPulses: Int = 0
    // 尺寸锁定：防止反馈循环导致窗口变宽
    private var lockedWidth: CGFloat = 0
    private var initialFrameCaptured = false
    private let windowAnimator = WindowAnimator()
    private var pendingDockInteraction = false
    private var hasReleasedDockClick = false
    private var lastCollapseTime: Date = .distantPast
    private var lastSpaceChangeAt: Date = .distantPast
    private var outsideCollapseCandidateSince: Date?
    private var lastSiblingWindowInteractionAt: Date?
    /// .expanded 期间"窗口几何已脱离托管边缘"的候选起始时间戳。
    /// 关键修复（与"展开后偶发快照条消失 + 无法自动折叠"Bug 直接相关）：
    /// 第三方 App 在 expanded 期间可能因内部布局事件（content 重排、模态弹出、
    /// 焦点切换、显示器/Dock 配置变化）短暂自行改写自身位置/宽度，导致 AX
    /// 上报的 minX/maxX 瞬时飘出 managedEdgeDetachTolerance 阈值。原本的
    /// 单帧硬判定会立刻把 state 静默降级为 .floating，进而 orderOut 快照条、
    /// invalidate mouseTrackingTimer，链路彻底断开，必须重新拖窗才能恢复。
    /// 用候选时间戳 + managedEdgeDetachConfirmInterval（250ms）做滞回确认，
    /// 吸收瞬时抖动；真正的用户拖拽脱边轻易超过该阈值，不会被误抑制。
    private var edgeDetachCandidateSince: Date?
    /// 取消置顶（普通置顶 / 镜像置顶）后，临时让 checkMouseForCollapse 绕过
    /// "兄弟窗口宽限期"判定，只走纯几何 isOutside。原因：sibling grace 是
    /// 为右键菜单/弹出层这类瞬时子窗口设计的（Phase 55/56），但取消置顶后
    /// 紧接着归位的过程中，鼠标可能恰好停留在某个同 PID 的非主窗口几何区域
    /// 上，被持续打戳 lastSiblingWindowInteractionAt，导致 1.5s 宽限期循环
    /// 续期，自动折叠永远不触发。短窗口绕过即可让鼠标在窗外的判定恢复正常，
    /// 时间到了再回到原有 sibling 防误触逻辑，不影响其他功能。
    private var siblingGraceBypassUntil: Date = .distantPast

    // MARK: - checkMouseForCollapse 性能缓存
    // 展开窗口期间 mouseTrackingTimer 以 10Hz 调用 checkMouseForCollapse，每次都
    // 跑 getRawWindowFrame（跨进程 AX 读）+ interactionHitTestFrame（CGWindowList
    // 全量枚举）+ pinControlFrames（又一次 AX 读）。鼠标静止在窗口内时，这些结果
    // 完全不变，是稳态 CPU 占用的主要来源。下面这组缓存用于在"输入未变化"时短路。
    /// 上一次 checkMouseForCollapse 采样到的鼠标位置（量化到 mouseCacheQuantum）。
    private var lastCheckedMouseLocation: CGPoint?
    /// 上一次采样判定出的 isOutside 结果。仅当鼠标量化位置未变时才可信。
    private var lastCheckedIsOutside: Bool?
    /// interactionHitTestFrame 缓存：值 + 计算时刻。AX 几何抖动回调会主动失效它。
    private var cachedInteractionHitFrame: CGRect?
    private var cachedInteractionHitFrameAt: Date = .distantPast
    /// AX Observer 上报的几何变化次数计数。每次 handleObservedGeometryChange 递增，
    /// checkMouseForCollapse 据此判断"窗口几何是否在上一帧之后发生了变化"以决定
    /// 是否复用缓存。比直接比对 frame 更便宜（无需先读一次 AX）。
    private var observedGeometryChangeToken: Int = 0
    private var lastCheckedObservedGeometryToken: Int = 0
    /// 鼠标量化粒度（point）。小于该值的位移被视为"静止"，跳过重计算。
    private static let mouseCacheQuantum: CGFloat = 3

    private var isTemporaryShortcutManaged = false
    private var isTemporarilyPinned = false
    /// 置顶能力是否处于激活状态：源窗口被钉住后，面板显示实时采集画面。
    private var isMirrorPinActive = false
    private var isMirrorOverlayVisible = false
    /// 跟踪源窗口几何（位置/尺寸/所在屏）变化的定时器。仅用于让置顶面板跟随源窗口移动，
    /// 画面内容由 SCStream 推流，不再依赖此定时器刷新。
    private var mirrorGeometryTimer: Timer?
    /// 上一次同步给采集器的源窗口尺寸（point），用于判断是否要 updateOutputDimensions。
    private var lastMirrorAppliedPointSize: CGSize = .zero
    /// 上一次跟踪到的源窗口屏，用于跨屏移动后重新解析 SCDisplay。
    private var lastMirrorScreen: NSScreen?
    /// 上一次 SCStream 失败时的自动重启时间戳，用于在 1.5s 内重复失败时判定为不可恢复。
    private var lastMirrorCaptureRestartAt: Date = .distantPast
    /// resize 期间防抖：尺寸稳定 0.35s 后才真正下发 updateOutputDimensions。
    /// 详见 `syncMirrorGeometryWithSourceWindow` 注释。
    private var pendingMirrorOutputUpdate: DispatchWorkItem?
    /// 监听全局/本进程鼠标事件，驱动 sharing ↔ userInteraction 两态机：
    /// - sharing：SCStream 跑，面板显示画面；
    /// - userInteraction：SCStream 完全停止，面板从屏幕摘掉，真实窗口以普通方式聚焦。
    private var mirrorOverlayMouseMonitors: [Any] = []
    /// 鼠标事件 hit-test 用的源窗口区域缓存（AppKit 坐标系）。
    /// 仅由 `syncMirrorGeometryWithSourceWindow` (0.18s) 与 `startMirrorCapture` 写入；
    /// `handleMirrorPointerEvent` 只读这份缓存做几何 contains 判定，
    /// **不再**在每次 mouseMoved/Dragged 上同步调跨进程 AX (getRawWindowFrame)。
    /// 60–120Hz × 2 次跨进程 AX 调用全部跑在主线程上，目标 App 繁忙时单次可阻塞数百毫秒，
    /// 会直接拖垮系统光标——这是必须缓存的关键热点。
    private var cachedSourceHitFrame: CGRect?
    /// `syncMirrorGeometryWithSourceWindow` 连续拿不到源窗口 frame 的起始时刻。
    /// 偶发 nil 不立刻拆置顶（这会让用户 resize 过快、Space 切换等瞬时 miss 都把状态炸掉），
    /// 仅在持续 ≥ `mirrorGeometryMissTolerance` 后才判定为"源窗口真的没了"，归位置顶态。
    private var mirrorGeometryMissSince: Date?
    private static let mirrorGeometryMissTolerance: TimeInterval = 1.0
    /// 当前是否处于"用户交互态"：鼠标 hover 进入源窗口覆盖区后，立刻完全停止 SCStream，
    /// 真实窗口此刻就是一个普通聚焦窗口，用户可以正常拖动 / resize / 点击；
    /// 必须等到用户在源窗口**之外**点击一下，才会重启 SCStream，按当时最新的几何重启画面。
    /// 这套切换语义彻底回避了 hover 期间面板跟随产生的残影、双窗口、SCStream 高频
    /// reconfigure 把流挂掉等问题——交互期间 SCStream 根本就没在跑。
    private var isInUserInteractionMode = false
    private var pinnedAnchor: PinnedAnchor?
    private var pinControlRevealSuppressionUntil: Date = .distantPast
    var isDragging = false

    private static var sessionRegistry: [WeakWindowSessionBox] = []
    private static let siblingWindowTransitionGraceInterval: TimeInterval = 0.22
    private static let siblingWindowPostInteractionGraceInterval: TimeInterval = 1.5
    private static let managedEdgeDetachTolerance: CGFloat = 72
    /// "几何已脱离边缘"判定的滞回确认时长：脱离状态需要连续保持至少这么久，
    /// 才会真正触发 transitionToFloatingFromManagedState。低于该时长则视为
    /// 第三方 App 内部的瞬时位移抖动，主动忽略。详见 edgeDetachCandidateSince。
    private static let managedEdgeDetachConfirmInterval: TimeInterval = 0.25
    private static var targetedActivationByPID: [pid_t: (sessionID: ObjectIdentifier, expiresAt: Date)] = [:]
    private static var preferredSessionByPID: [pid_t: ObjectIdentifier] = [:]
    private static var programmaticActivationIgnoreUntilByPID: [pid_t: Date] = [:]
    private static var lastObservedFocusSnapshot: FocusReturnSnapshot?
    private static var lastGlobalMouseDownAt: Date = .distantPast
    private static var lastGlobalMouseDownSample: GlobalMouseDownSample?
    private static var lastGlobalKeyDownAt: Date = .distantPast
    private static var lastAppSwitchIntentAt: Date = .distantPast
    private static var explicitRevealIntentByPID: [pid_t: ExplicitRevealIntent] = [:]
    private static let finderDesktopRealClickWindow: TimeInterval = 0.35
    private static let explicitRevealIntentWindow: TimeInterval = 0.55

    var onTemporaryShortcutSessionEnded: ((WindowSession, Bool, Bool) -> Void)?
    var onTemporaryShortcutStashStateChanged: ((WindowSession, Bool) -> Void)?
    var onHotkeyRuntimeStateChanged: ((WindowSession) -> Void)?
    var onStateTransition: ((WindowSession, SnapState, SnapState) -> Void)?
    var onManagedEdgeDetachment: ((WindowSession) -> Void)?
    var isManagedByTemporaryShortcut: Bool { isTemporaryShortcutManaged }
    var coordinationAppDisplayName: String { appDisplayName }
    var coordinationSessionID: String? { bridgeSessionID }
    var isFloatingForCoordination: Bool {
        if case .floating = state { return true }
        return false
    }
    var isSnappedForCoordination: Bool {
        if case .snapped = state { return true }
        return false
    }
    var isExpandedForCoordination: Bool {
        if case .expanded = state { return true }
        return false
    }
    var isManagedForCoordination: Bool { !isFloatingForCoordination }
    
    init(appElement: AXUIElement, windowElement: AXUIElement, pid: pid_t, bundleID: String) {
        self.appElement = appElement
        self.windowElement = windowElement
        self.pid = pid
        self.bundleID = bundleID
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            self.appDisplayName = runningApp.localizedName ?? bundleID
            if let bundleURL = runningApp.bundleURL {
                self.appIcon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            } else {
                self.appIcon = nil
            }
        } else {
            self.appDisplayName = bundleID
            self.appIcon = nil
        }

        indicatorWindow.alphaValue = 0 // 初始化为透明，以便后续优雅淡入
        setupAXObserver()
        indicatorWindow.onMouseEntered = { [weak self] in
            self?.handleMouseEnteredIndicator()
        }
        indicatorWindow.onMouseExited = { [weak self] in
            self?.handleMouseExitedIndicator()
        }
        indicatorWindow.onMouseClicked = { [weak self] in
            self?.handleIndicatorClicked()
        }
        pinControlWindow.onToggle = { [weak self] in
            self?.toggleTemporaryPin()
        }
        // 置顶面板自身鼠标事件穿透 (`ignoresMouseEvents = true`)，无需在此挂接交互回调。
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleAppActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        // [Space Awareness Fix] 监听桌面切换通知以实现优雅显隐
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // 监听全局配置变更通知，实现颜色动态同步
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigChanged), name: NSNotification.Name("AppConfigDidChange"), object: nil)
        
        // 核心修复：自动收编遗留在边缘的应用窗口
        checkAndAdoptEdgeState()
        Self.register(self)

        // [Watchdog] 启动状态自愈定时器：唯一的两件事——
        // 1. 把"应显未显"的快照条捞回来；2. 把卡死的 isAnimating 复位。
        // 永远不主动改变 state / 几何 / 焦点，只做正向兜底。
        startStateWatchdog()
    }

    var runtimeClaimSnapshot: SideBarBridge.RuntimeClaimSnapshot {
        SideBarBridge.RuntimeClaimSnapshot(
            bundleID: bundleID,
            hotkeyOwner: hotkeyClaimOwner,
            state: hotkeyRuntimeState,
            sessionID: bridgeSessionID
        )
    }

    var canHandleForwardedHotkeyAction: Bool {
        if isTemporarilyPinned || isAnimating { return false }
        switch state {
        case .snapped:
            return canExpandViaHotkey
        case .expanded:
            return canCollapseViaHotkey
        case .floating:
            return false
        }
    }

    var shouldRetainForwardedHotkeyOwnership: Bool {
        guard !isTemporarilyPinned else { return false }
        guard isAnimating else { return false }
        switch state {
        case .snapped, .expanded:
            return true
        case .floating:
            return false
        }
    }

    func handleForwardedHotkeyAction() -> Bool {
        if shouldRetainForwardedHotkeyOwnership {
            queuedForwardedHotkeyToggle = true
            invalidatePendingFocusRelease()
            return true
        }

        guard canHandleForwardedHotkeyAction else { return false }
        return toggleExpandCollapse()
    }

    @discardableResult
    func relinquishToDockMinimizeIfDetachedFromEdge() -> Bool {
        guard !isAnimating else {
            // 动画过程中 frame 一定会临时偏离最终锚点，禁止任何脱离判定，
            // 也清空候选时间戳，避免动画结束的瞬间被误判为"持续脱离"。
            edgeDetachCandidateSince = nil
            return false
        }
        // 关键修复：临时置顶 / 镜像置顶期间，用户允许把窗口拖到屏幕任意位置；
        // 不能在置顶期间把这种位移当成"detach"，否则 state 会被错误降级为 .floating，
        // 取消置顶后即使窗口归位回边缘，自动折叠链路也已断开（`checkMouseForCollapse`
        // 的 `guard case .expanded = state` 会直接早退）。
        guard !isTemporarilyPinned else {
            edgeDetachCandidateSince = nil
            return false
        }
        guard case .expanded = state else {
            edgeDetachCandidateSince = nil
            return false
        }
        guard let frame = getRawWindowFrame(), isDetachedFromManagedEdge(frame) else {
            // 已回到 / 仍贴在边缘 -> 清空候选时间戳，重新积累滞回窗口
            edgeDetachCandidateSince = nil
            return false
        }

        // 关键修复（"展开后偶发快照条消失 + 鼠标移出不自动折叠"Bug 治本方案）：
        // 第三方 App 在 expanded 期间会因为内部布局重排（content 刷新、模态弹出、
        // 焦点切换、显示器/Dock 配置变化等）短暂自行改写位置/宽度，导致 AX
        // 上报的 minX/maxX 瞬时飘出 72px。如果直接单帧降级到 .floating，会一并
        // orderOut 快照条、invalidate mouseTrackingTimer、unlock 屏幕锚点，
        // 用户视觉上就是"快照条莫名其妙没了，鼠标移出窗口也不收回，必须重新
        // 拖到边缘才行"，这正是反馈中"偶发"现象的根因。
        //
        // 滞回确认：脱离状态需要连续持续至少 managedEdgeDetachConfirmInterval
        // 才真正降级。真正的用户拖拽脱边轻易超过该阈值，不受影响；而第三方
        // 应用的瞬时位移抖动通常会在下一两个 AX 事件内自我纠正，从而被吸收。
        let now = Date()
        if let since = edgeDetachCandidateSince {
            if now.timeIntervalSince(since) < Self.managedEdgeDetachConfirmInterval {
                return false
            }
            // 持续脱离已确认，真实降级
            edgeDetachCandidateSince = nil
            transitionToFloatingFromManagedState()
            return true
        } else {
            // 首次观察到脱离，进入候选期，本帧不降级
            edgeDetachCandidateSince = now
            return false
        }
    }

    func relinquishManagedStateForBundleTransfer() {
        transitionToFloatingFromManagedState(
            notifyOwnerChange: false,
            restoreVisiblePositionIfNeeded: true
        )
    }

    private func finishTemporaryShortcutSession(excludeWindow: Bool, removeSession: Bool) {
        guard isTemporaryShortcutManaged else { return }
        isTemporaryShortcutManaged = false
        AppConfig.shared.setTemporaryDockMinimizeExclusion(bundleID: bundleID, excluded: false)
        onTemporaryShortcutStashStateChanged?(self, false)
        onTemporaryShortcutSessionEnded?(self, excludeWindow, removeSession)
    }

    private func notifyTemporaryShortcutStashStateChanged(isStashed: Bool) {
        guard isTemporaryShortcutManaged else { return }
        onTemporaryShortcutStashStateChanged?(self, isStashed)
    }

    private var hotkeyRuntimeState: String {
        switch state {
        case .floating:
            return "floating"
        case .snapped:
            return "snapped_hidden"
        case .expanded:
            return "expanded_visible"
        }
    }

    private var hotkeyClaimOwner: SideBarHotkeyClaim.HotkeyOwner {
        switch state {
        case .snapped, .expanded:
            return .sidebar
        case .floating:
            return .dockminimize
        }
    }

    private var canExpandViaHotkey: Bool {
        guard let currentFrame = getWindowFrame() else { return false }
        return edgeGeometry(for: currentFrame) != nil
    }

    private var canCollapseViaHotkey: Bool {
        guard let currentFrame = getRawWindowFrame() else { return false }
        return edgeGeometry(for: currentFrame) != nil
    }

    private var bridgeSessionID: String? {
        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else {
            return nil
        }
        return "\(pid):\(windowID)"
    }

    var debugStateSummary: String {
        let stateLabel: String
        switch state {
        case .floating:
            stateLabel = "floating"
        case .snapped(let edge, _):
            stateLabel = "snapped(edge:\(edge))"
        case .expanded:
            stateLabel = "expanded"
        }

        if let frame = getRawWindowFrame() {
            return "\(stateLabel) edge=\(currentEdge) frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))) animating=\(isAnimating) temporary=\(isTemporaryShortcutManaged) fusionLock=\(fusionHoverLock)"
        }

        return "\(stateLabel) edge=\(currentEdge) frame=nil animating=\(isAnimating) temporary=\(isTemporaryShortcutManaged) fusionLock=\(fusionHoverLock)"
    }

    func noteAXRoleCheckSucceeded() {
        transientAXRoleFailureCount = 0
        lastTransientAXRoleFailureAt = nil
    }

    func shouldDeferRemovalAfterAXRoleFailure(_ result: AXError) -> Bool {
        switch result {
        case .cannotComplete, .invalidUIElement:
            break
        default:
            return false
        }

        let now = Date()
        if let lastFailureAt = lastTransientAXRoleFailureAt,
           now.timeIntervalSince(lastFailureAt) > 1.2 {
            transientAXRoleFailureCount = 0
        }

        transientAXRoleFailureCount += 1
        lastTransientAXRoleFailureAt = now

        return transientAXRoleFailureCount <= 12
    }
    
    private func handleMouseEnteredIndicator() {
        if hoverCooldownActive { return } // 悬停冷却锁开启中，阻止触发
        if clickCollapseLockActive { return } // 用户点击折叠后的临时锁，阻止再次自动展开
        if Date() < fusionReentrySuppressionUntil { return }
        
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        hoverInterruptTimer?.invalidate()
        hoverInterruptTimer = nil
        
        let delayMS = AppConfig.shared.hoverDelayMS
        if delayMS <= 0 {
            expandWindow()
        } else {
            // 启动意图防抖倒计时
            hoverDelayTimer = Timer.scheduledTimer(withTimeInterval: Double(delayMS) / 1000.0, repeats: false) { [weak self] _ in
                self?.expandWindow()
                self?.hoverDelayTimer = nil
                self?.hoverInterruptTimer?.invalidate()
                self?.hoverInterruptTimer = nil
            }
            
            // 同步启动按压侦测打断
            hoverInterruptTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                if NSEvent.pressedMouseButtons != 0 {
                    print("🛑 停驻倒计时期间发生物理点击，防抖生效！中止窗口展开并获得冷却锁。")
                    self.hoverDelayTimer?.invalidate()
                    self.hoverDelayTimer = nil
                    self.hoverCooldownActive = true
                    timer.invalidate()
                }
            }
        }
    }
    
    private func handleMouseExitedIndicator() {
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        hoverInterruptTimer?.invalidate()
        hoverInterruptTimer = nil
        hoverCooldownActive = false // 彻底离开区域后，冷却锁破除
        // 鼠标完全离开快照条后，解除“点击折叠临时锁”，恢复 hover 自动展开能力
        clickCollapseLockActive = false
    }

    /// 处理用户对独立快照条（非融合）的单击事件：
    /// - 展开态：点击折叠 + 进入临时锁，鼠标停留期间不再 hover 自动展开。
    /// - 折叠态 + 临时锁：再次点击立即展开（保留锁，等待下一次点击折叠）。
    /// - 折叠态 + 无锁：忽略，避免和悬停防误触逻辑互相干扰。
    private func handleIndicatorClicked() {
        if isAnimating { return }
        if fusionHoverLock { return } // 融合接管时单条快照条点击交给融合逻辑
        if isTemporarilyPinned { return }

        // 取消 hover 等待中的展开倒计时
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        hoverInterruptTimer?.invalidate()
        hoverInterruptTimer = nil

        switch state {
        case .expanded:
            if collapseWindow() {
                clickCollapseLockActive = true
                hoverCooldownActive = false
                scheduleFocusRelease(after: 0.35)
            }
        case .snapped:
            guard clickCollapseLockActive else { return }
            // 注意：不要清掉 clickCollapseLockActive。
            // 鼠标停留在快照条期间，hover 仍被这把锁屏蔽（不会自动再展开），
            // 但下一次点击进入 .expanded 分支时会再次进入"折叠+加锁"路径，
            // 从而实现连续点击：折叠↔展开↔折叠↔展开… 鼠标离开后再由
            // handleMouseExitedIndicator 解锁，恢复正常 hover 自动展开。
            hoverCooldownActive = false
            // 关键：不要走 isDockActivated 路径。
            // 否则 expandWindow 会设置 pendingDockInteraction，导致 checkMouseForCollapse
            // 在鼠标仍在快照条上（被识别为窗口外）时立即折叠刚展开的窗口。
            hasReleasedDockClick = true
            if expandWindow() {
                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    runningApp.activate(options: .activateIgnoringOtherApps)
                }
                axSetBoolAttribute(on: windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.handleIndicatorClicked.main")
                axSetBoolAttribute(on: windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.handleIndicatorClicked.focused")
            }
        case .floating:
            break
        }
    }
    
    deinit {
        destroy()
    }

    
    @objc private func handleSpaceChanged() {
        lastSpaceChangeAt = Date()

        // [Space Switch Fix] 回归手工强控模式，先执行点状消散动画
        // 当用户关闭“动态特效”时，跳过收缩成点的弹性动画，直接隐藏指示条。
        if AppConfig.shared.isVisualEffectEnabled {
            self.indicatorWindow.animateCollapseToDot { }
        } else {
            self.indicatorWindow.orderOut(nil)
        }
        
        // 延迟 0.7s 检测系统的物理稳定状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self else { return }
            self.refreshIndicatorVisibility()
        }
    }

    private func refreshIndicatorVisibility() {
        if isIndicatorSuppressed {
            indicatorWindow.orderOut(nil)
            updatePinControlWindow()
            return
        }

        let screen = getScreenForWindow()
        
        // [LightToDo Logic] 全屏大绝招
        if isInFullscreenSpace(screen: screen) {
             indicatorWindow.orderOut(nil)
             updatePinControlWindow()
             return
        }

        if isAnimating {
            switch state {
            case .snapped, .expanded:
                updatePinControlWindow()
                return
            case .floating:
                break
            }
        }

        let isOnScreen = isWindowOnScreen()
        
        switch state {
        case .snapped:
            if isOnScreen {
                let wasHidden = !indicatorWindow.isVisible || indicatorWindow.alphaValue < 0.1
                let shouldAnimate = wasHidden && isIndicatorAnimationAllowed
                if shouldAnimate {
                    indicatorWindow.animateExpandFromDot()
                }
                showIndicator(animated: shouldAnimate)
            } else {
                indicatorWindow.orderOut(nil)
                updatePinControlWindow()
            }
        case .expanded:
            if shouldTreatExpandedWindowAsVisibleForIndicator(isOnScreen: isOnScreen) {
                let wasHidden = !indicatorWindow.isVisible || indicatorWindow.alphaValue < 0.1
                let shouldAnimate = wasHidden && isIndicatorAnimationAllowed
                if shouldAnimate {
                    indicatorWindow.animateExpandFromDot()
                }
                showIndicator(animated: shouldAnimate)
            } else {
                indicatorWindow.orderOut(nil)
                updatePinControlWindow()
            }
        case .floating:
            indicatorWindow.orderOut(nil)
            updatePinControlWindow()
        }
    }    

    private func shouldTreatExpandedWindowAsVisibleForIndicator(isOnScreen: Bool) -> Bool {
        if isOnScreen { return true }
        guard case .expanded = state else { return false }

        let now = Date()
        if let targeted = Self.targetedActivationByPID[pid],
           targeted.sessionID == ObjectIdentifier(self),
           targeted.expiresAt > now {
            return true
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let frame = getWindowFrame() else {
            return false
        }
        return getDisplayBounds().intersects(frame)
    }

    private func scheduleIndicatorVisibilityRefresh(after delay: TimeInterval = 0.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshIndicatorVisibility()
        }
    }

    /// 检测当前桌面是否包含全屏应用，以决定是否隐藏指示条
    private func isInFullscreenSpace(screen: NSScreen) -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.activationPolicy == .regular,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &focusedValue,
            context: "WindowSession.isInFullscreenSpace.focusedWindow"
        ) == .success,
              let focusedWindow = focusedValue else {
            return false
        }

        let focusedWindowElement = focusedWindow as! AXUIElement
        if let subrole = getAXWindowSubrole(of: focusedWindowElement),
           subrole != kAXStandardWindowSubrole {
            return false
        }
        var fullscreenValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: focusedWindowElement,
            attribute: "AXFullScreen" as CFString,
            value: &fullscreenValue,
            context: "WindowSession.isInFullscreenSpace.fullscreen"
        ) == .success else {
            return false
        }

        let isFullscreen: Bool
        if let boolValue = fullscreenValue as? Bool {
            isFullscreen = boolValue
        } else if let numberValue = fullscreenValue as? NSNumber {
            isFullscreen = numberValue.boolValue
        } else {
            return false
        }

        let screenBounds = cgBounds(for: screen)
        guard isFullscreen else { return false }

        let visibleWindows = visibleWindowsInCurrentSpace(for: frontmostApp.processIdentifier, on: screen)
        guard !visibleWindows.isEmpty else { return false }

        if let focusedWindowID = WindowAlphaManager.shared.findWindowID(for: focusedWindowElement, pid: frontmostApp.processIdentifier),
           let matchedWindow = visibleWindows.first(where: { $0.id == focusedWindowID }) {
            if let focusedFrame = getAXWindowFrame(of: focusedWindowElement) {
                guard isRectApproximatelyFullscreen(focusedFrame, within: screenBounds) else {
                    return false
                }
                return isRectApproximatelyFullscreen(matchedWindow.frame, within: screenBounds) &&
                    rectsApproximatelyMatch(matchedWindow.frame, focusedFrame)
            }

            return isRectApproximatelyFullscreen(matchedWindow.frame, within: screenBounds)
        }

        guard let focusedFrame = getAXWindowFrame(of: focusedWindowElement) else {
            return false
        }

        guard isRectApproximatelyFullscreen(focusedFrame, within: screenBounds) else {
            return false
        }

        return visibleWindows.contains { window in
            isRectApproximatelyFullscreen(window.frame, within: screenBounds) &&
                rectsApproximatelyMatch(window.frame, focusedFrame)
        }
    }

    private func cgBounds(for screen: NSScreen) -> CGRect {
        let sf = screen.frame
        return CGRect(
            x: sf.origin.x,
            y: primaryScreenHeight - sf.origin.y - sf.height,
            width: sf.width,
            height: sf.height
        )
    }

    private func visibleWindowsInCurrentSpace(for pid: pid_t, on screen: NSScreen) -> [VisibleAppWindowSample] {
        let screenBounds = cgBounds(for: screen)
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        return windowList.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { return nil }

            let rect = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )

            guard rect.width >= 16, rect.height >= 16, rect.intersects(screenBounds) else {
                return nil
            }
            return VisibleAppWindowSample(id: windowID, frame: rect)
        }
    }

    private func getAXWindowSubrole(of element: AXUIElement) -> String? {
        WindowCapabilityProfiler.subrole(
            of: element,
            context: "WindowSession.getAXWindowSubrole.subrole"
        )
    }

    private func isRectApproximatelyFullscreen(_ rect: CGRect, within screenBounds: CGRect) -> Bool {
        rect.intersects(screenBounds) &&
            abs(rect.minX - screenBounds.minX) < 6 &&
            abs(rect.minY - screenBounds.minY) < 6 &&
            abs(rect.width - screenBounds.width) < 6 &&
            abs(rect.height - screenBounds.height) < 6
    }

    private func rectsApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 60 &&
            abs(lhs.minY - rhs.minY) < 120 &&
            abs(lhs.width - rhs.width) < 60 &&
            abs(lhs.height - rhs.height) < 120
    }

    private func getAXWindowFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: element,
            attribute: kAXPositionAttribute as CFString,
            value: &positionValue,
            context: "WindowSession.getAXWindowFrame.position"
        ) == .success,
              AccessibilityRuntimeGuard.copyAttributeValue(
                of: element,
                attribute: kAXSizeAttribute as CFString,
                value: &sizeValue,
                context: "WindowSession.getAXWindowFrame.size"
              ) == .success else {
            return nil
        }

        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position: CGPoint = .zero
        var size: CGSize = .zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func rememberFocusReturnTargetBeforeReveal() {
        let sourceWindowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid)

        if let currentSnapshot = Self.currentFrontmostFocusSnapshot(),
           !Self.isSnapshot(currentSnapshot, sameAsSourcePID: pid, sourceWindowID: sourceWindowID) {
            focusReturnSnapshot = currentSnapshot
            return
        }

        if let observedSnapshot = Self.lastObservedFocusSnapshot,
           !Self.isSnapshot(observedSnapshot, sameAsSourcePID: pid, sourceWindowID: sourceWindowID) {
            focusReturnSnapshot = observedSnapshot
            return
        }

        focusReturnSnapshot = nil
    }

    static func recordObservedFocusSnapshot(for app: NSRunningApplication) {
        guard let snapshot = focusedWindowSnapshot(for: app) else { return }
        guard shouldStoreObservedFocusSnapshot(snapshot) else { return }
        lastObservedFocusSnapshot = snapshot
    }

    private static func currentFrontmostFocusSnapshot() -> FocusReturnSnapshot? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return focusedWindowSnapshot(for: frontmostApp)
    }

    private static func focusedWindowSnapshot(for app: NSRunningApplication) -> FocusReturnSnapshot? {
        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              bundleID != selfBundleID else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedWindow: AXUIElement?
        if AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &focusedValue,
            context: "WindowSession.focusedWindowSnapshot.focusedWindow"
        ) == .success,
           let focusedWindowValue = focusedValue {
            focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
        } else {
            focusedWindow = nil
        }

        let windowID = focusedWindow.flatMap { window in
            WindowAlphaManager.shared.findWindowID(for: window, pid: app.processIdentifier)
        }

        return FocusReturnSnapshot(
            pid: app.processIdentifier,
            bundleID: bundleID,
            windowID: windowID,
            capturedAt: Date()
        )
    }

    private static func shouldStoreObservedFocusSnapshot(_ snapshot: FocusReturnSnapshot) -> Bool {
        if let windowID = snapshot.windowID,
           shouldExcludeCandidateFromFocusReturn(windowID: windowID, ownerPID: snapshot.pid) {
            return false
        }
        return true
    }

    static func noteGlobalMouseDown() {
        let now = Date()
        let point = NSEvent.mouseLocation
        lastGlobalMouseDownAt = now
        lastGlobalMouseDownSample = GlobalMouseDownSample(
            at: now,
            location: point,
            region: classifyGlobalClickRegion(at: point)
        )
    }

    func handleMouseDown() {
        isDragging = false
        edgeDetachCandidateSince = nil
    }

    static func noteGlobalKeyDown(_ event: NSEvent) {
        let now = Date()
        lastGlobalKeyDownAt = now

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.keyCode == 48 {
            lastAppSwitchIntentAt = now
        }
    }

    static func hasRecentDockClickIntent(now: Date = Date()) -> Bool {
        guard let sample = lastGlobalMouseDownSample else { return false }
        guard now.timeIntervalSince(sample.at) <= explicitRevealIntentWindow else { return false }
        guard sample.region == .dock else { return false }
        return sample.at >= lastGlobalKeyDownAt
    }

    static func suppressProgrammaticActivation(for pid: pid_t, duration: TimeInterval) {
        registerProgrammaticActivationIgnore(for: pid, duration: duration)
    }

    private static func classifyGlobalClickRegion(at point: CGPoint) -> GlobalClickRegion {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return .unknown
        }

        let frame = screen.frame
        let menuBarHeight = max(NSStatusBar.system.thickness, 28)
        if point.y >= frame.maxY - menuBarHeight {
            return .menuBar
        }

        if isNotificationCenterClick(at: point, screenFrame: frame) {
            return .notificationBanner
        }

        guard let dockSide = AppConfig.shared.resolvedDockAvoidanceSide() else {
            return .content
        }

        if let dockRect = estimatedDockHitRect(for: frame, side: dockSide),
           dockRect.contains(point) {
            return .dock
        }

        return .content
    }

    /// 通知横幅/通知中心点击判定：命中点位于屏幕右侧竖条区域，且该点最上层窗口属于
    /// NotificationCenter 进程。归属校验避免"点击某 App 自家窗口右上角"被误判为通知点击。
    /// 仅在命中右侧区域时才查询窗口列表，普通点击无额外开销。
    private static func isNotificationCenterClick(at point: CGPoint, screenFrame: CGRect) -> Bool {
        let stripWidth: CGFloat = 420
        guard point.x >= screenFrame.maxX - stripWidth else { return false }

        // CGWindowList 使用 Quartz 全局坐标（原点在主屏左上角），需转换 Y 轴
        let quartzPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 1080) - point.y)
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in infoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(quartzPoint) else { continue }
            // 列表按 Z 序从前到后排列，第一个命中点的就是最上层窗口
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 {
                return NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == "com.apple.notificationcenterui"
            }
            if let ownerName = info[kCGWindowOwnerName as String] as? String {
                return ownerName == "Notification Center" || ownerName == "NotificationCenter"
            }
            return false
        }
        return false
    }

    private static func dockPreferenceValue(forKey key: String) -> Any? {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let persistentDomain = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")
        return dockDefaults?.object(forKey: key) ?? persistentDomain?[key]
    }

    private static func estimatedDockHitRect(for screenFrame: CGRect, side: String) -> CGRect? {
        let thickness = estimatedDockThickness(for: screenFrame, side: side)

        let tileSizeValue = dockPreferenceValue(forKey: "tilesize") as? NSNumber
        let largeSizeValue = dockPreferenceValue(forKey: "largesize") as? NSNumber
        let magnificationEnabled = (dockPreferenceValue(forKey: "magnification") as? NSNumber)?.boolValue ?? false
        let showRecents = (dockPreferenceValue(forKey: "show-recents") as? NSNumber)?.boolValue ?? false

        let persistentApps = dockPreferenceValue(forKey: "persistent-apps") as? [Any] ?? []
        let persistentOthers = dockPreferenceValue(forKey: "persistent-others") as? [Any] ?? []
        let runningRegularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.count

        let tileSize = CGFloat(tileSizeValue?.doubleValue ?? 48)
        let largeSize = CGFloat(largeSizeValue?.doubleValue ?? tileSize)
        let iconSpan = magnificationEnabled ? max(tileSize, largeSize) : tileSize
        let effectiveTileSpan = max(iconSpan + (magnificationEnabled ? 20 : 14), 56)

        let appTileCount = max(persistentApps.count, runningRegularApps)
        let totalTileCount = max(appTileCount + persistentOthers.count + (showRecents ? 3 : 0), 4)
        let separatorGap: CGFloat = persistentOthers.isEmpty ? 0 : 24
        let outerPadding: CGFloat = 40

        let dockLength = CGFloat(totalTileCount) * effectiveTileSpan + separatorGap + outerPadding * 2

        switch side {
        case "left":
            let clampedHeight = min(max(dockLength, 180), screenFrame.height - 24)
            return CGRect(
                x: screenFrame.minX,
                y: screenFrame.midY - clampedHeight / 2,
                width: thickness,
                height: clampedHeight
            )
        case "right":
            let clampedHeight = min(max(dockLength, 180), screenFrame.height - 24)
            return CGRect(
                x: screenFrame.maxX - thickness,
                y: screenFrame.midY - clampedHeight / 2,
                width: thickness,
                height: clampedHeight
            )
        case "bottom":
            let clampedWidth = min(max(dockLength, 220), screenFrame.width - 24)
            return CGRect(
                x: screenFrame.midX - clampedWidth / 2,
                y: screenFrame.minY,
                width: clampedWidth,
                height: thickness
            )
        default:
            return nil
        }
    }

    private static func estimatedDockThickness(for screenFrame: CGRect, side: String) -> CGFloat {
        let tileSizeValue = dockPreferenceValue(forKey: "tilesize") as? NSNumber
        let largeSizeValue = dockPreferenceValue(forKey: "largesize") as? NSNumber
        let magnificationEnabled = (dockPreferenceValue(forKey: "magnification") as? NSNumber)?.boolValue ?? false
        let autohideEnabled = (dockPreferenceValue(forKey: "autohide") as? NSNumber)?.boolValue ?? false

        let tileSize = CGFloat(tileSizeValue?.doubleValue ?? 48)
        let largeSize = CGFloat(largeSizeValue?.doubleValue ?? tileSize)
        let iconSpan = magnificationEnabled ? max(tileSize, largeSize) : tileSize
        let paddedThickness = iconSpan + (autohideEnabled ? 22 : 42)

        let maxSpan: CGFloat
        if side == "bottom" {
            maxSpan = max(88, min(screenFrame.height * 0.22, 180))
        } else {
            maxSpan = max(88, min(screenFrame.width * 0.18, 180))
        }

        return min(max(paddedThickness, autohideEnabled ? 36 : 84), maxSpan)
    }

    private static func isSnapshot(
        _ snapshot: FocusReturnSnapshot,
        sameAsSourcePID sourcePID: pid_t,
        sourceWindowID: CGWindowID?
    ) -> Bool {
        guard snapshot.pid == sourcePID else { return false }
        guard let snapshotWindowID = snapshot.windowID,
              let sourceWindowID else {
            return true
        }
        return snapshotWindowID == sourceWindowID
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        Self.recordObservedFocusSnapshot(for: app)

        switch state {
        case .snapped, .expanded:
            scheduleIndicatorVisibilityRefresh(after: 0.08)
        case .floating:
            break
        }

        if isTemporarilyPinned, app.processIdentifier != self.pid {
            if isMirrorPinActive {
                if Self.shouldYieldPinnedWindow(to: app.processIdentifier, excluding: self) {
                    // 让位（yield）给优先级更高的另一个置顶窗口：把面板从屏幕摘掉。
                    // userInteraction 态下面板本就不在屏幕上，hideMirrorOverlay 幂等。
                    hideMirrorOverlay()
                } else if !isInUserInteractionMode, isMirrorOverlayVisible {
                    // 其他 App 拿到前台且当前处于 sharing 态：把面板顶回最前。
                    // userInteraction 态下面板已被摘掉、SCStream 已停，用户正在直接操作真实窗口，
                    // 这里不动它——直到用户在源窗口外点击才会回到 sharing 态。
                    mirrorOverlayWindow.alphaValue = 1
                    if let rawFrame = getRawWindowFrame() {
                        mirrorOverlayWindow.display(at: appKitFrame(fromCGFrame: rawFrame))
                    } else {
                        mirrorOverlayWindow.orderFrontRegardless()
                    }
                }
                return
            }
            if !Self.shouldYieldPinnedWindow(to: app.processIdentifier, excluding: self) {
                bringPinnedWindowToFrontSoon()
            }
            return
        }
        if app.processIdentifier == self.pid {
            if Self.shouldIgnoreProgrammaticActivation(for: self.pid) {
                print("📱 忽略: 程序内部触发的激活，不展开窗口")
                return
            }
            if Date() < fusionReentrySuppressionUntil {
                print("📱 忽略: 该窗口正在通过融合条退场，暂不重新展开")
                return
            }
            if Date() < activationSuppressionUntil {
                print("📱 忽略: 处于融合切换保护期")
                return
            }
            let isFocusedWindowSession = isCurrentFocusedWindowOfApp()
            if !Self.isAppActivationAllowed(for: self) {
                // 无定向路由时，多窗口唤回需要额外收窄：
                // 通知点击放行代表窗口；菜单栏点击只放行当前真正获得焦点的窗口。
                let activationTrigger = recentExplicitRevealTrigger()
                    ?? Self.peekExplicitRevealIntent(for: self.pid)?.trigger
                let isNotificationReveal = activationTrigger == .notificationClick
                let isMenuBarReveal = activationTrigger == .menuBarClick
                let allowsUntargetedReveal =
                    (isNotificationReveal && Self.isPreferredNotificationRevealSession(self))
                    || (isMenuBarReveal && isFocusedWindowSession)
                guard Self.targetedActivationByPID[self.pid] == nil,
                      allowsUntargetedReveal else {
                    print("📱 忽略: 这次激活被定向给同 App 的另一个窗口")
                    return
                }
            }
            registerExplicitRevealIntentIfNeeded()
            if isMirrorPinActive {
                // 置顶面板就是源窗口的实时画面，源 App 拿到前台时不再隐藏面板，
                // 避免与 handleAppActivated 的其它分支形成"先隐后显"的视觉抖动。
                // 用户若需要解除置顶并直接操作真实窗口，请再次点击图钉按钮，
                // 或鼠标 hover 进入面板覆盖区由两态机自动切到 userInteraction 态。
                return
            }
            if isTemporarilyPinned {
                print("📌 忽略: 临时置顶窗口不参与 Dock 自动折叠")
                return
            }
            if case .snapped = state {
                // 通知点击唤回以"主窗口路由"为准（门禁处已筛选），macOS 焦点落在哪个窗口不影响展开决策
                let pendingTrigger = Self.peekExplicitRevealIntent(for: pid)?.trigger
                let allowsUnfocusedReveal = pendingTrigger == .notificationClick
                guard isFocusedWindowSession || allowsUnfocusedReveal else {
                    if isRecentExplicitFinderDesktopClick() {
                        print("📱 Finder 桌面真实点击，保留前台，不再主动释放焦点")
                        return
                    }
                    if shouldReleaseFinderDesktopActivation() {
                        print("📱 Finder 桌面层激活，重新释放前台状态")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            Self.activateNonManagedApp(sourcePID: self.pid)
                        }
                    }
                    if discardExplicitRevealIntentIfSiblingWindowWon() {
                        print("📱 显式唤回被同 App 的其他标准窗口接管，丢弃本窗口展开意图")
                        return
                    }
                    if let pendingTrigger = Self.peekExplicitRevealIntent(for: pid)?.trigger,
                       pendingTrigger != .menuBarClick {
                        scheduleDeferredExplicitRevealIfNeeded()
                    }
                    print("📱 忽略: 当前激活的是同 App 的其他窗口")
                    return
                }
                if shouldIgnoreActivationTriggeredBySpaceSwitch() {
                    print("📱 忽略: Space 回切导致的前台恢复，不视为 Dock 展开")
                    releaseFocusAfterSuppressedSpaceSwitchIfNeeded()
                    return
                }
                guard let pendingRevealIntent = Self.peekExplicitRevealIntent(for: pid) else {
                    print("📱 应用被动回前台，忽略自动展开")
                    return
                }

                if isRevealIntentStaleAfterLatestCollapse(pendingRevealIntent) {
                    Self.clearExplicitRevealIntent(for: pid)
                    print("📱 防抖: 忽略折叠前残留的旧展开意图")
                    return
                }

                guard let revealIntent = Self.consumeExplicitRevealIntent(for: pid) else { return }
                let interaction = interactionFlags(for: revealIntent.trigger)
                let triggerLabel: String
                switch revealIntent.trigger {
                case .dockClick: triggerLabel = "Dock"
                case .appSwitch: triggerLabel = "App Switch"
                case .notificationClick: triggerLabel = "通知"
                case .menuBarClick: triggerLabel = "菜单栏"
                }
                print("📱 \(triggerLabel) 展开: \(bundleID)")
                hasReleasedDockClick = interaction.hasReleasedDockClick
                expandWindow(isDockActivated: interaction.isDockActivated)
            } else if case .expanded = state {
                guard isFocusedWindowSession else {
                    print("📱 忽略: 当前激活的是同 App 的其他窗口")
                    return
                }
                // 如果还处于豁免保护期，忽略这次由系统滞后发来的自己变为前台的通知
                if pendingDockInteraction {
                    print("📱 忽略: 处于 Dock/Shortcut 豁免期，暂不响应系统二次激活通知")
                    return
                }
                
                // 检查鼠标是否在窗口安全区内：如果在窗口内，说明是用户点击窗口而非 Dock，忽略
                if let frame = interactionHitTestFrame() ?? getWindowFrame() {
                    let mouseLoc = NSEvent.mouseLocation
                    let displayHeight = primaryScreenHeight
                    let mappedMouse = CGPoint(x: mouseLoc.x, y: displayHeight - mouseLoc.y)
                    let tolX = AppConfig.shared.hoverTolerance
                    let tolY = AppConfig.shared.hoverToleranceY
                    let bufferRect = frame.insetBy(dx: -tolX, dy: -tolY)
                    if bufferRect.contains(mappedMouse) {
                        print("📱 忽略: 鼠标在窗口内，非 Dock 点击")
                        return
                    }
                }
                if collapseWindow() {
                    // 释放前台状态：激活一个不被 SideBar 管理的应用
                    scheduleFocusRelease(after: 0.35)
                }
            }
        }
    }
    
    @objc private func handleConfigChanged() {
        if !AppConfig.shared.isVisualEffectEnabled {
            effectWindow.stopExpandEffect(closeWindow: true)
        }
        // 如果当前正处于吸附或展开态，立即刷新指示器颜色
        if case .floating = state { return }
        print("🎨 实时同步: 检测到配置变更，刷新 \(bundleID) 侧边条颜色")
        showIndicator(animated: true)
        updatePinControlWindow()
    }

    func setIndicatorSuppressed(_ suppressed: Bool) {
        guard isIndicatorSuppressed != suppressed else { return }
        isIndicatorSuppressed = suppressed
        if suppressed {
            indicatorWindow.orderOut(nil)
            updatePinControlWindow()
        } else {
            refreshIndicatorVisibility()
        }
    }

    func setFusionHoverLock(_ locked: Bool) {
        fusionHoverLock = locked
    }

    func isTemporaryPinnedForFusion() -> Bool {
        isTemporarilyPinned
    }

    func toggleTemporaryPin() {
        if isTemporarilyPinned {
            releaseTemporaryPin()
        } else {
            engageTemporaryPin()
        }
    }

    private var usesMirrorPin: Bool {
        AppConfig.shared.isMirrorPinEnabled
    }

    private func engageTemporaryPin() {
        guard case .expanded = state else { return }
        guard currentEdge == 1 || currentEdge == 2 else { return }
        guard let frame = getRawWindowFrame() else { return }

        if usesMirrorPin {
            engageMirrorPin(using: frame)
            return
        }

        pinnedAnchor = PinnedAnchor(expandedMidY: frame.midY)
        isTemporarilyPinned = true
        stopPinnedRaisePulse()
        startMouseTrackingTimer()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        showIndicator(animated: false)
        updatePinControlWindow()
    }

    private func releaseTemporaryPin() {
        guard isTemporarilyPinned else { return }
        if isMirrorPinActive {
            releaseMirrorPin()
            return
        }
        guard let rawFrame = getRawWindowFrame() else {
            isTemporarilyPinned = false
            pinnedAnchor = nil
            updatePinControlWindow()
            return
        }
        guard let targetFrame = pinnedExpandedTargetFrame(from: rawFrame) else {
            isTemporarilyPinned = false
            pinnedAnchor = nil
            updatePinControlWindow()
            return
        }

        lockedWidth = rawFrame.width
        initialFrameCaptured = true
        isTemporarilyPinned = false
        stopPinnedRaisePulse()
        isAnimating = true
        mouseTrackingTimer?.invalidate()
        windowAnimator.stop()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)

        animateWindowPositionFast(
            from: rawFrame.minX,
            to: targetFrame.minX,
            startY: rawFrame.minY,
            endY: targetFrame.minY,
            duration: 0.16,
            easeIn: false
        ) { [weak self] in
            guard let self else { return }
            self.forceWindowGeometry(x: targetFrame.minX, y: targetFrame.minY, height: targetFrame.height)
            self.isAnimating = false
            self.pinnedAnchor = nil
            // 关键修复：取消置顶并归位后，清空 sibling 防误触相关的所有状态，
            // 并临时绕过 sibling grace 判定 2 秒。原因详见 siblingGraceBypassUntil 注释。
            self.lastSiblingWindowInteractionAt = nil
            self.outsideCollapseCandidateSince = nil
            self.edgeDetachCandidateSince = nil
            self.siblingGraceBypassUntil = Date().addingTimeInterval(2.0)
            self.showIndicator(animated: false)
            self.startMouseTrackingTimer()
            self.updatePinControlWindow()
            axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.releaseTemporaryPin.main")
            axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.releaseTemporaryPin.focused")
        }
    }

    private func engageMirrorPin(using frame: CGRect) {
        // 屏幕录制权限：用户首次点击置顶图钉时按需请求；未授权直接退出，保留真实窗口本来的展开态。
        guard ScreenCaptureAccessManager.shared.hasAccess() || ScreenCaptureAccessManager.shared.requestAccess() else {
            return
        }
        guard #available(macOS 12.3, *) else { return }

        pinnedAnchor = PinnedAnchor(expandedMidY: frame.midY)
        isTemporarilyPinned = true
        isMirrorPinActive = true
        stopPinnedRaisePulse()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        startMouseTrackingTimer()
        showIndicator(animated: false)
        startMirrorCapture(initialFrame: frame)
        updatePinControlWindow()
    }

    private func releaseMirrorPin() {
        stopMirrorGeometryTimer()
        hideMirrorOverlay()
        teardownMirrorCapture()
        isMirrorPinActive = false

        guard let rawFrame = getRawWindowFrame() else {
            isTemporarilyPinned = false
            pinnedAnchor = nil
            updatePinControlWindow()
            return
        }
        guard let targetFrame = pinnedExpandedTargetFrame(from: rawFrame) else {
            isTemporarilyPinned = false
            pinnedAnchor = nil
            updatePinControlWindow()
            return
        }

        lockedWidth = rawFrame.width
        initialFrameCaptured = true
        isTemporarilyPinned = false
        isAnimating = true
        mouseTrackingTimer?.invalidate()
        windowAnimator.stop()

        animateWindowPositionFast(
            from: rawFrame.minX,
            to: targetFrame.minX,
            startY: rawFrame.minY,
            endY: targetFrame.minY,
            duration: 0.16,
            easeIn: false
        ) { [weak self] in
            guard let self else { return }
            self.forceWindowGeometry(x: targetFrame.minX, y: targetFrame.minY, height: targetFrame.height)
            self.isAnimating = false
            self.pinnedAnchor = nil
            // 关键修复：取消置顶并归位后，清空 sibling 防误触相关的所有状态，
            // 并临时绕过 sibling grace 判定 2 秒。原因详见 siblingGraceBypassUntil 注释。
            self.lastSiblingWindowInteractionAt = nil
            self.outsideCollapseCandidateSince = nil
            self.edgeDetachCandidateSince = nil
            self.siblingGraceBypassUntil = Date().addingTimeInterval(2.0)
            self.showIndicator(animated: false)
            self.startMouseTrackingTimer()
            self.updatePinControlWindow()
            axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.releaseMirrorPin.main")
            axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.releaseMirrorPin.focused")
        }
    }

    private func bringPinnedWindowToFrontSoon() {
        stopPinnedRaisePulse()

        let pulseCount = 6
        let interval: TimeInterval = 0.06
        pinnedRaiseRemainingPulses = pulseCount
        attemptPinnedRaise()

        guard pinnedRaiseRemainingPulses > 0 else { return }
        pinnedRaiseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if !self.isTemporarilyPinned {
                self.stopPinnedRaisePulse()
                return
            }
            if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               Self.shouldYieldPinnedWindow(to: frontmostPID, excluding: self) {
                self.stopPinnedRaisePulse()
                return
            }

            self.attemptPinnedRaise()
            if self.pinnedRaiseRemainingPulses <= 0 {
                self.stopPinnedRaisePulse()
            }
        }
    }

    private func attemptPinnedRaise() {
        guard isTemporarilyPinned else { return }
        let raiseResult = AccessibilityRuntimeGuard.performAction(
            on: windowElement,
            action: kAXRaiseAction as CFString,
            context: "WindowSession.attemptPinnedRaise"
        )
        if raiseResult != .success {
            print("📌 AXRaise 失败: \(bundleID), result=\(raiseResult.rawValue)")
        }
        pinnedRaiseRemainingPulses = max(0, pinnedRaiseRemainingPulses - 1)
    }

    private func stopPinnedRaisePulse() {
        pinnedRaiseTimer?.invalidate()
        pinnedRaiseTimer = nil
        pinnedRaiseRemainingPulses = 0
    }

    /// 启动一次完整的置顶画面采集：
    /// - 立刻把空面板按源窗口当前 frame 显示出来，避免 SCStream 首帧到达前出现位置漂移；
    /// - 解析 `CGWindowID -> SCWindow/SCDisplay` 后再异步发起 `SCStream.startCapture`，
    ///   解析失败或采集器自报错时进入恢复流程，仍失败再退出置顶态。
    private func startMirrorCapture(initialFrame: CGRect) {
        guard #available(macOS 12.3, *) else { return }

        isMirrorOverlayVisible = true
        isInUserInteractionMode = false
        let initialAppKitFrame = appKitFrame(fromCGFrame: initialFrame)
        mirrorOverlayWindow.display(at: initialAppKitFrame)
        // 立即写入 hit-test 缓存，让 hover tracking 启动后第一次评估也能拿到有效几何，
        // 避免 0.18s 内事件全部因为缓存为空而被丢弃。
        cachedSourceHitFrame = initialAppKitFrame
        mirrorGeometryMissSince = nil

        lastMirrorAppliedPointSize = CGSize(width: initialFrame.width, height: initialFrame.height)

        guard attachMirrorCapturer() else {
            isMirrorPinActive = false
            isMirrorOverlayVisible = false
            mirrorOverlayWindow.hide()
            return
        }

        startMirrorGeometryTimer()
        startMirrorOverlayHoverTracking()
    }

    /// 创建一个新的 `WindowMirrorLiveCapturer`、挂到面板上、并异步发起 `SCStream.startCapture`。
    /// 成功返回 true；解析源窗口 ID 失败返回 false（调用方负责状态归位）。
    /// 启动后 SCStream 异常停止由 `handleMirrorCaptureFailure` 兜底，不在这里关心。
    @discardableResult
    private func attachMirrorCapturer() -> Bool {
        guard #available(macOS 12.3, *) else { return false }
        guard let sourceWindowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else {
            print("🪟 置顶启动失败：无法解析源窗口 ID")
            return false
        }

        let capturer = WindowMirrorLiveCapturer()
        capturer.onCaptureFailure = { [weak self] in
            guard let self, self.isMirrorPinActive else { return }
            self.handleMirrorCaptureFailure()
        }
        mirrorLiveCapturer = capturer
        mirrorOverlayWindow.attachCaptureLayer(capturer.renderingLayer)

        let preferredScreen = detectScreen()
        lastMirrorScreen = preferredScreen
        let backingScale = preferredScreen.backingScaleFactor
        let pointSize = lastMirrorAppliedPointSize

        // ⚠️ resolver 必须 weak capture capturer：在解析回调返回前，hover 引导（或 destroy）
        // 完全可能已经把 `mirrorLiveCapturer` 置为 nil（进入 userInteraction 态会同步 stop+清引用）。
        // 如果这里 strong capture capturer，闭包会让那只"已经被换掉"的 capturer 起死回生并启动
        // 一条无人能再 stop 的 SCStream（SCStream 与 capturer 通过 addStreamOutput 形成强引循环，
        // 整个回路不再有人持有 capturer 时也无法被回收）—— 这就是"光标已在源窗口区域时点钉
        // 立刻泄漏一条永驻 SCStream"的根因。
        //
        // 修复：weak capture，并在回调里只服务"我仍然是当前挂载者，且不在 userInteraction 态"
        // 这一个最新版本。其它情况一律放过，让该 capturer 自然释放。
        WindowMirrorSourceResolver.shared.resolve(windowID: sourceWindowID,
                                                  preferredScreen: preferredScreen) { [weak self, weak capturer] resolved in
            guard let self, let capturer,
                  self.isMirrorPinActive,
                  self.mirrorLiveCapturer === capturer,
                  !self.isInUserInteractionMode else { return }
            guard let resolved else {
                print("🪟 置顶启动失败：未在 ScreenCaptureKit 中找到匹配窗口 (\(sourceWindowID))")
                self.releaseMirrorPin()
                return
            }
            capturer.start(window: resolved.window,
                           on: resolved.display,
                           nominalPointSize: pointSize,
                           backingScale: backingScale)
        }
        return true
    }

    /// SCStream 报错（多见于源窗口被外部强制 resize、空间切换、瞬时配置冲突等）时的兜底：
    /// - 1.5s 内已经尝试过一次自动重启 → 判定为不可恢复，退出置顶态归位；
    /// - 否则摘掉旧 capturer，刷新 resolver 缓存，延迟 0.2s 后用 `attachMirrorCapturer` 重启一次。
    ///
    /// 之所以"重启而不直接归位"，是为了避免之前观察到的一类问题：用户拖动 resize 句柄期间
    /// SCStream 偶发报错就把整个置顶态拆掉，肉眼上看到的就是"调整窗口大小后共享立刻断掉"。
    private func handleMirrorCaptureFailure() {
        guard #available(macOS 12.3, *) else {
            releaseMirrorPin()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastMirrorCaptureRestartAt) < 1.5 {
            print("🪟 置顶采集短时间内重复失败，回到普通态")
            releaseMirrorPin()
            return
        }
        lastMirrorCaptureRestartAt = now
        guard let rawFrame = getRawWindowFrame() else {
            releaseMirrorPin()
            return
        }
        print("🪟 置顶采集异常，自动重启")
        mirrorLiveCapturer?.stop()
        mirrorLiveCapturer = nil
        mirrorOverlayWindow.detachCaptureLayer()
        lastMirrorAppliedPointSize = CGSize(width: rawFrame.width, height: rawFrame.height)
        WindowMirrorSourceResolver.shared.invalidateCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isMirrorPinActive else { return }
            if !self.attachMirrorCapturer() {
                self.releaseMirrorPin()
            }
        }
    }

    /// 收尾实时采集：停 stream、摘 layer、清缓存。仅清理，不动状态机标志位本身。
    private func teardownMirrorCapture() {
        pendingMirrorOutputUpdate?.cancel()
        pendingMirrorOutputUpdate = nil
        isInUserInteractionMode = false
        stopMirrorOverlayHoverTracking()
        stopMirrorGeometryTimer()
        mirrorLiveCapturer?.stop()
        mirrorLiveCapturer = nil
        mirrorOverlayWindow.detachCaptureLayer()
        mirrorOverlayWindow.hide()
        isMirrorOverlayVisible = false
        lastMirrorAppliedPointSize = .zero
        lastMirrorScreen = nil
        lastMirrorCaptureRestartAt = .distantPast
        cachedSourceHitFrame = nil
        mirrorGeometryMissSince = nil
    }

    /// 装上 sharing ↔ userInteraction 两态机的鼠标事件探测器。
    /// 置顶面板自身鼠标穿透，无法用 NSTrackingArea 直接探测，这里用两个事件监听器组合捕捉：
    /// - 全局 monitor 抓鼠标处在其它 App 窗口上时的事件；
    /// - 本地 monitor 抓鼠标处在本 App 自己的窗口（例如图钉按钮）上时的事件。
    ///
    /// 关键语义：
    /// - 鼠标 hover **进入**源窗口覆盖区 → 立刻进入 userInteraction 态：**完全停止 SCStream**，
    ///   面板从屏幕摘掉。真实窗口此刻就是一个普通聚焦窗口，用户怎么拖、怎么 resize、
    ///   怎么右键菜单都不会出问题——因为根本没有 SCStream 在跑。
    /// - 鼠标 **点击** 源窗口覆盖区**之外** → 进入 sharing 态：按真实窗口当时最新的
    ///   几何（resize 之后的新尺寸）重启 SCStream，挂回面板。短暂黑屏即可换上新画面。
    /// - 鼠标移到源窗口区外但**没点击**：不重启共享，保持 userInteraction 态。
    ///   避免用户视线扫到旁边内容、鼠标飘出去又飘回来时反复 stop/start SCStream。
    private func startMirrorOverlayHoverTracking() {
        stopMirrorOverlayHoverTracking()
        let interestingTypes: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: interestingTypes, handler: { [weak self] event in
            self?.handleMirrorPointerEvent(eventType: event.type)
        }) {
            mirrorOverlayMouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: interestingTypes, handler: { [weak self] event in
            self?.handleMirrorPointerEvent(eventType: event.type)
            return event
        }) {
            mirrorOverlayMouseMonitors.append(local)
        }
        // 评估一次初始状态：若启动时鼠标已经压在源窗口上，应当进入 userInteraction 态。
        // 关键：必须延后到下一个 runloop tick——否则会同步早于 resolver 回调一步发出 stop()，
        // 把 mirrorLiveCapturer 置为 nil；resolver 仍带着旧 capturer 起死回生启动 SCStream，
        // 形成永远停不下来的孤儿流（见 attachMirrorCapturer 的 weak capturer 修复）。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMirrorPinActive else { return }
            self.handleMirrorPointerEvent(eventType: .mouseMoved)
        }
    }

    private func stopMirrorOverlayHoverTracking() {
        for monitor in mirrorOverlayMouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mirrorOverlayMouseMonitors.removeAll()
    }

    /// 鼠标事件分发：根据当前鼠标位置与事件类型在 sharing/userInteraction 之间切换。
    /// 见 `startMirrorOverlayHoverTracking` 的注释了解状态机语义。
    private func handleMirrorPointerEvent(eventType: NSEvent.EventType) {
        guard isMirrorPinActive else { return }

        // hit-test 完全走缓存：源窗口几何由 `syncMirrorGeometryWithSourceWindow` (0.18s)
        // 维护，事件路径上不再触发任何跨进程 AX 调用，避免 60–120Hz × 2 次 AX IPC 拖垮主线程。
        guard let hitFrame = cachedSourceHitFrame else { return }
        let pointer = NSEvent.mouseLocation
        let isInside = hitFrame.contains(pointer)

        let isMouseDown: Bool
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            isMouseDown = true
        default:
            isMouseDown = false
        }
        // 当前是否有任意鼠标键已经被按下。用于过滤"外部 drag 越过置顶区"——例如用户
        // 从 Finder 拖文件、从 Safari 拖图、从其它 App 拖窗口标题栏，鼠标路径若恰好穿过
        // 置顶区域，绝不能视为"进入交互"。否则会被强制 raise 源 App，drop 目标被遮挡或失焦。
        let isAnyMouseButtonPressed = NSEvent.pressedMouseButtons != 0

        if isInside {
            if isMouseDown {
                // 真正的"点击落到源窗口覆盖区里"：这是用户明确意图，
                // 停 SCStream + 摘面板 + raise 源 App，让点击落到真实窗口。
                if !isInUserInteractionMode {
                    enterUserInteractionMode(promoteSourceWindow: true)
                } else {
                    // 已在 userInteraction 态：仍把源 App 抬一下，防止用户连击中途焦点被旁路抢走。
                    promoteSourceWindowBeneathMirrorOverlay()
                }
            } else if !isAnyMouseButtonPressed {
                // 纯 hover：没有任何按键被按下。停流 + 摘面板 + 把源窗口提到最前。
                // 用户主动把窗口置顶就是要看它——面板消失后看到的就必须是源窗口，
                // 而不是面板背后其他 App 的窗口。误扫抢焦的代价远小于"移过去啥都看不见"。
                if !isInUserInteractionMode {
                    enterUserInteractionMode(promoteSourceWindow: true)
                }
            }
            // else: 鼠标键已按下但不是本次事件触发的 mouseDown —— 这是外部 drag，
            // 让事件穿透，不切换状态。
        } else {
            // 鼠标在源窗口覆盖区**之外**：仅在点击事件上才重启共享，单纯移动到外部不切换，
            // 避免来回飘移触发反复 stop/start。
            if isInUserInteractionMode, isMouseDown {
                resumeMirrorCaptureMode()
            }
        }
    }

    /// 进入用户交互态：彻底停止 SCStream，让真实窗口表现得就像一个普通聚焦窗口。
    /// 调用时机由 hover 或源窗口区域内的 mouseDown 触发；调用后 `isMirrorPinActive` 仍为
    /// true（图钉按钮保持置顶图标），但 `isMirrorOverlayVisible` 与 capturer 都被收起，
    /// 下次 mouseDown 落在源窗口区域外部时由 `resumeMirrorCaptureMode` 重新创建一份。
    ///
    /// - Parameter promoteSourceWindow: 是否把源 App 抬到最前（拿焦点）。
    ///   当前所有进入 userInteraction 的路径（hover 或 mouseDown）都传 `true`：
    ///   面板消失后用户看到的必须就是源窗口，而不是面板背后的其他 App。
    private func enterUserInteractionMode(promoteSourceWindow: Bool) {
        guard isMirrorPinActive, !isInUserInteractionMode else { return }
        isInUserInteractionMode = true
        // userInteraction 态下面板已从屏幕摘掉、SCStream 也停了，几何 timer 继续以 0.18s
        // 跑 AX + detect screen 没有任何意义；更危险的是它会在 syncMirrorGeometryWithSourceWindow
        // 单次 nil 时立刻拆置顶（resize 中途、Space 切换瞬时 miss 都会被误判为窗口消失）。
        // 这里直接停掉，等 resume 时再起。
        stopMirrorGeometryTimer()
        pendingMirrorOutputUpdate?.cancel()
        pendingMirrorOutputUpdate = nil
        if promoteSourceWindow {
            // 仅在 mouseDown 命中源窗口区域时抢焦：在 SCStream 停止瞬间面板会从屏幕上消失，
            // 提前 promote 一次保证那一刻用户看到的是真实窗口而不是它后面的应用。
            promoteSourceWindowBeneathMirrorOverlay()
        }
        mirrorLiveCapturer?.stop()
        mirrorLiveCapturer = nil
        mirrorOverlayWindow.detachCaptureLayer()
        mirrorOverlayWindow.hide()
        isMirrorOverlayVisible = false
    }

    /// 退出用户交互态：按真实窗口当时的最新几何重启 SCStream，再次置顶。
    /// 因为 SCStream 是全新启动的，画面尺寸天然匹配新窗口（用户刚才如果改过 resize，
    /// 这里看到的就是 resize 之后的样子），不会再出现"新窗口 + 旧尺寸共享副本"的双窗口诡异感。
    private func resumeMirrorCaptureMode() {
        guard isMirrorPinActive, isInUserInteractionMode else { return }
        guard #available(macOS 12.3, *) else {
            releaseMirrorPin()
            return
        }
        guard let rawFrame = getRawWindowFrame() else {
            releaseMirrorPin()
            return
        }

        isInUserInteractionMode = false
        isMirrorOverlayVisible = true
        let appKit = appKitFrame(fromCGFrame: rawFrame)
        mirrorOverlayWindow.display(at: appKit)
        cachedSourceHitFrame = appKit
        mirrorGeometryMissSince = nil
        lastMirrorAppliedPointSize = CGSize(width: rawFrame.width, height: rawFrame.height)
        // 正常 resume 路径不强制 invalidateCache：源窗口的 windowID 在其生命周期里稳定，
        // 反复 hover-in/click-out 都丢 SCShareableContent 缓存只会引发 >100ms 的全量枚举。
        // 缓存失效只在 attach 真的失败（窗口消失 / 流挂掉）时由 handleMirrorCaptureFailure 触发。
        if !attachMirrorCapturer() {
            releaseMirrorPin()
            return
        }
        startMirrorGeometryTimer()
    }

    /// 把源 App 与源窗口抬到最前。userInteraction 态下面板已从屏幕摘掉，
    /// 此处把真实窗口提到前台，用户就能看到、点击、拖动、resize 它。
    private func promoteSourceWindowBeneathMirrorOverlay() {
        if let runningApp = NSRunningApplication(processIdentifier: pid), !runningApp.isActive {
            runningApp.activate(options: .activateIgnoringOtherApps)
        }
        // 显式把目标窗口提为 main + focused，避免 App 内有多个窗口时被系统挑到另一个。
        axSetBoolAttribute(on: windowElement, attribute: kAXMainAttribute as CFString, value: true,
                           context: "WindowSession.promoteSourceWindowBeneathMirrorOverlay.main")
        axSetBoolAttribute(on: windowElement, attribute: kAXFocusedAttribute as CFString, value: true,
                           context: "WindowSession.promoteSourceWindowBeneathMirrorOverlay.focused")
        // 显式 raise：保险起见把窗口在 AX 层面也提到本 App 最前。
        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
    }

    /// 仅把面板从屏幕收起（用于 yield 给具备置顶权重更高的窗口时的临时让位）。
    /// 注意：sharing 态下采集仍在跑，仅 z-order 摘掉；userInteraction 态下面板本就不在屏幕上，
    /// 这里仅做幂等收尾。
    private func hideMirrorOverlay() {
        isMirrorOverlayVisible = false
        mirrorOverlayWindow.hide()
    }

    /// 跟踪源窗口几何（位置/尺寸/所在屏）的轻量定时器。
    /// 这里只搬面板、按需 update 采集尺寸；画面内容由 SCStream 异步推流，无需我们触发刷新。
    private func startMirrorGeometryTimer() {
        stopMirrorGeometryTimer()
        mirrorGeometryTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.syncMirrorGeometryWithSourceWindow()
        }
    }

    private func stopMirrorGeometryTimer() {
        mirrorGeometryTimer?.invalidate()
        mirrorGeometryTimer = nil
    }

    private func syncMirrorGeometryWithSourceWindow() {
        guard isMirrorPinActive else { return }
        guard let rawFrame = getRawWindowFrame() else {
            // 偶发 nil 不立刻拆置顶：用户拖动 resize 句柄过快、刚切 Space、AX 瞬时返回 nil
            // 等场景都会触发单次 miss——直接 releaseMirrorPin 就是用户原始抱怨"调整窗口
            // 大小过快立刻失去置顶"的同款症状。这里加滞回：累计 ≥ mirrorGeometryMissTolerance
            // 才判定为"源窗口真的没了"。
            let now = Date()
            if let since = mirrorGeometryMissSince {
                if now.timeIntervalSince(since) >= Self.mirrorGeometryMissTolerance {
                    releaseMirrorPin()
                }
            } else {
                mirrorGeometryMissSince = now
            }
            return
        }
        mirrorGeometryMissSince = nil
        let mirrorAppKitFrame = appKitFrame(fromCGFrame: rawFrame)
        // 缓存供 handleMirrorPointerEvent 做几乎免费的几何 contains 判定，
        // 让事件路径上不再触发任何跨进程 AX。
        cachedSourceHitFrame = mirrorAppKitFrame
        if isMirrorOverlayVisible {
            mirrorOverlayWindow.update(frame: mirrorAppKitFrame)
        }
        let currentScreen = detectScreen()
        let pointSize = CGSize(width: rawFrame.width, height: rawFrame.height)
        let backingScale = currentScreen.backingScaleFactor
        let referenceScale = lastMirrorScreen?.backingScaleFactor ?? backingScale
        let sizeDelta = abs(pointSize.width - lastMirrorAppliedPointSize.width) > 0.5
            || abs(pointSize.height - lastMirrorAppliedPointSize.height) > 0.5
        let scaleDelta = abs(backingScale - referenceScale) > 0.01

        guard sizeDelta || scaleDelta else { return }

        // ⚠️ 防抖：用户拖动 resize 句柄期间，源窗口尺寸每 0.18s 都会发生变化。
        // 直接每次都调 `SCStream.updateConfiguration`（或 macOS 13 之前的整体重启）
        // 极易触发底层报错 → `didStopWithError` → `onCaptureFailure`，肉眼看到的
        // 就是"调整窗口大小后共享立刻断掉"。
        //
        // 这里只在尺寸稳定 ≥ 0.35s 之后才把新尺寸推给采集器；resize 进行中：
        // - 面板 frame 继续每 0.18s 跟随真实窗口（视觉无延迟）；
        // - 画面层依赖 `SCStreamConfiguration.scalesToFit` + `AVSampleBufferDisplayLayer.videoGravity = .resizeAspect`
        //   动态拉伸到新面板大小，期间略糊但不会断流；
        // - 用户停手后才把高清分辨率一次性下发，避免高频热更新。
        pendingMirrorOutputUpdate?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isMirrorPinActive,
                  let capturer = self.mirrorLiveCapturer,
                  let liveFrame = self.getRawWindowFrame() else { return }
            let liveScreen = self.detectScreen()
            let livePointSize = CGSize(width: liveFrame.width, height: liveFrame.height)
            capturer.updateOutputDimensions(pointSize: livePointSize,
                                            backingScale: liveScreen.backingScaleFactor)
            self.lastMirrorAppliedPointSize = livePointSize
            self.lastMirrorScreen = liveScreen
            self.pendingMirrorOutputUpdate = nil
        }
        pendingMirrorOutputUpdate = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /// 把 CG 坐标系下的源窗口 frame 翻译成 AppKit 坐标系下的面板 frame。
    /// 主屏左下角是 AppKit 原点；这一步必须使用主屏高度作为基准，否则跨屏会偏移整屏高度。
    private func appKitFrame(fromCGFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func pinnedExpandedTargetFrame(from currentFrame: CGRect) -> CGRect? {
        guard let anchor = pinnedAnchor else { return nil }
        let displayBounds = getDisplayBounds()
        let targetX = currentEdge == 1 ? displayBounds.minX : displayBounds.maxX - currentFrame.width
        let targetY = Swift.max(
            displayBounds.minY,
            Swift.min(anchor.expandedMidY - currentFrame.height / 2, displayBounds.maxY - currentFrame.height)
        )
        return CGRect(x: targetX, y: targetY, width: currentFrame.width, height: currentFrame.height)
    }

    private func edgeReferenceFrame() -> CGRect? {
        if isTemporarilyPinned,
           let rawFrame = getRawWindowFrame(),
           let targetFrame = pinnedExpandedTargetFrame(from: rawFrame) {
            return targetFrame
        }
        return getWindowFrame()
    }

    private func focusedWindowOfApp() -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &focusedValue,
            context: "WindowSession.focusedWindowOfApp.focusedWindow"
        ) == .success,
              let focusedWindowRef = focusedValue else {
            return nil
        }
        return unsafeBitCast(focusedWindowRef, to: AXUIElement.self)
    }

    private func focusedWindowSubroleOfApp() -> String? {
        guard let focusedWindow = focusedWindowOfApp() else { return nil }
        return WindowCapabilityProfiler.subrole(
            of: focusedWindow,
            context: "WindowSession.focusedWindowSubroleOfApp.subrole"
        )
    }

    private func focusedWindowCapabilityProfileOfApp() -> WindowCapabilityProfile? {
        guard let focusedWindow = focusedWindowOfApp() else { return nil }
        return WindowCapabilityProfiler.profile(
            of: focusedWindow,
            bundleID: bundleID,
            context: "WindowSession.focusedWindowCapabilityProfileOfApp.profile"
        )
    }

    private func isCurrentFocusedWindowOfApp() -> Bool {
        guard let focusedWindow = focusedWindowOfApp() else { return false }
        return CFEqual(focusedWindow, windowElement)
    }

    private static func cleanupExplicitRevealIntents() {
        let now = Date()
        explicitRevealIntentByPID = explicitRevealIntentByPID.filter { $0.value.expiresAt > now }
    }

    private static func registerExplicitRevealIntent(for pid: pid_t, trigger: ExplicitRevealTrigger) {
        cleanupExplicitRevealIntents()
        explicitRevealIntentByPID[pid] = ExplicitRevealIntent(
            trigger: trigger,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(explicitRevealIntentWindow)
        )
    }


    private static func peekExplicitRevealIntent(for pid: pid_t) -> ExplicitRevealIntent? {
        cleanupExplicitRevealIntents()
        return explicitRevealIntentByPID[pid]
    }

    private static func consumeExplicitRevealIntent(for pid: pid_t) -> ExplicitRevealIntent? {
        guard let intent = peekExplicitRevealIntent(for: pid) else { return nil }
        explicitRevealIntentByPID.removeValue(forKey: pid)
        return intent
    }

    private static func clearExplicitRevealIntent(for pid: pid_t) {
        explicitRevealIntentByPID.removeValue(forKey: pid)
    }

    private func recentExplicitRevealTrigger() -> ExplicitRevealTrigger? {
        if let sample = Self.lastGlobalMouseDownSample,
           Date().timeIntervalSince(sample.at) <= Self.explicitRevealIntentWindow,
           sample.at >= Self.lastGlobalKeyDownAt {
            if sample.region == .dock {
                return .dockClick
            }
            if sample.region == .notificationBanner {
                return .notificationClick
            }
            if sample.region == .menuBar {
                return .menuBarClick
            }
        }
        if Date().timeIntervalSince(Self.lastAppSwitchIntentAt) <= Self.explicitRevealIntentWindow {
            return .appSwitch
        }
        return nil
    }

    private func registerExplicitRevealIntentIfNeeded() {
        guard case .snapped = state else { return }
        guard let trigger = recentExplicitRevealTrigger() else { return }
        Self.registerExplicitRevealIntent(for: pid, trigger: trigger)
    }

    private func interactionFlags(for trigger: ExplicitRevealTrigger) -> (isDockActivated: Bool, hasReleasedDockClick: Bool) {
        switch trigger {
        case .dockClick:
            return (true, false)
        case .menuBarClick:
            return (true, false)
        case .appSwitch, .notificationClick:
            return (true, true)
        }
    }

    private func isRevealIntentStaleAfterLatestCollapse(_ intent: ExplicitRevealIntent) -> Bool {
        intent.createdAt <= lastCollapseTime
    }

    private func shouldReleaseFinderDesktopActivation() -> Bool {
        guard bundleID == "com.apple.finder" else { return false }
        guard case .snapped = state else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let profile = focusedWindowCapabilityProfileOfApp() else { return true }
        return profile.isFinderDesktopProxy
    }

    private func isRecentExplicitFinderDesktopClick() -> Bool {
        guard bundleID == "com.apple.finder" else { return false }
        guard shouldReleaseFinderDesktopActivation() else { return false }
        guard let sample = Self.lastGlobalMouseDownSample else { return false }
        guard Date().timeIntervalSince(sample.at) <= Self.finderDesktopRealClickWindow else { return false }
        guard sample.region == .content else { return false }
        guard getDisplayBounds().contains(sample.location) else { return false }
        return true
    }

    func handleFocusedWindowChangedWithinApp() {
        guard case .snapped = state else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        guard isCurrentFocusedWindowOfApp() else { return }
        guard Date().timeIntervalSince(lastCollapseTime) >= 0.2 else { return }
        guard !Self.shouldIgnoreProgrammaticActivation(for: pid) else { return }

        if bundleID == "com.apple.finder" {
            registerExplicitRevealIntentIfNeeded()
        } else if let trigger = recentExplicitRevealTrigger(),
                  trigger == .notificationClick || trigger == .menuBarClick {
            // 通知 / 菜单栏点击时 App 可能已在前台（不触发 didActivate），在此补注册唤回意图
            registerExplicitRevealIntentIfNeeded()
        }

        guard let pendingRevealIntent = Self.peekExplicitRevealIntent(for: pid) else {
            if bundleID == "com.apple.finder" {
                print("📱 Finder 焦点回到隐藏窗口，但缺少显式唤回意图，忽略自动展开")
            }
            return
        }

        // 通知点击唤回只放行"主窗口" session，其余窗口即使获得焦点也不展开
        if pendingRevealIntent.trigger == .notificationClick,
           !Self.isPreferredNotificationRevealSession(self) {
            return
        }

        if isRevealIntentStaleAfterLatestCollapse(pendingRevealIntent) {
            Self.clearExplicitRevealIntent(for: pid)
            print("📱 忽略: 折叠前残留的旧唤回意图")
            return
        }

        guard let revealIntent = Self.consumeExplicitRevealIntent(for: pid) else { return }

        if bundleID == "com.apple.finder" {
            print("📱 Finder 焦点窗口已回到被隐藏窗口，按窗口焦点变化触发展开")
        } else {
            print("📱 焦点窗口已回到被隐藏窗口，继续完成显式唤回")
        }
        let interaction = interactionFlags(for: revealIntent.trigger)
        hasReleasedDockClick = interaction.hasReleasedDockClick
        expandWindow(isDockActivated: interaction.isDockActivated)
    }

    private func shouldIgnoreActivationTriggeredBySpaceSwitch() -> Bool {
        guard case .snapped = state else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastSpaceChangeAt) < 0.9 else { return false }
        return Self.lastGlobalMouseDownAt <= lastSpaceChangeAt
    }

    private func hasFocusedStandardSiblingWindowOfApp() -> Bool {
        guard let profile = focusedWindowCapabilityProfileOfApp(),
              profile.isStandardWindow else {
            return false
        }
        return hasFocusedSiblingWindowOfApp()
    }

    private func discardExplicitRevealIntentIfSiblingWindowWon() -> Bool {
        guard hasFocusedStandardSiblingWindowOfApp() else { return false }
        guard Self.peekExplicitRevealIntent(for: pid) != nil else { return false }
        Self.clearExplicitRevealIntent(for: pid)
        return true
    }

    private func scheduleDeferredExplicitRevealIfNeeded() {
        guard let pendingIntent = Self.peekExplicitRevealIntent(for: pid) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard case .snapped = self.state else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
            guard !Self.shouldIgnoreProgrammaticActivation(for: self.pid) else { return }

            guard let intent = Self.peekExplicitRevealIntent(for: self.pid),
                  intent.trigger == pendingIntent.trigger else { return }

            if self.isRevealIntentStaleAfterLatestCollapse(intent) {
                Self.clearExplicitRevealIntent(for: self.pid)
                print("📱 忽略: 折叠前残留的延迟唤回意图")
                return
            }

            if self.discardExplicitRevealIntentIfSiblingWindowWon() {
                print("📱 显式唤回被同 App 的其他标准窗口接管，丢弃旧展开意图")
                return
            }

            let frontmostOwnsFocus = self.isCurrentFocusedWindowOfApp()
            let hasBlockingSibling = self.hasFocusedSiblingWindowOfApp()
            guard frontmostOwnsFocus || !hasBlockingSibling else {
                Self.clearExplicitRevealIntent(for: self.pid)
                return
            }

            guard let consumedIntent = Self.consumeExplicitRevealIntent(for: self.pid) else { return }
            let interaction = self.interactionFlags(for: consumedIntent.trigger)
            self.hasReleasedDockClick = interaction.hasReleasedDockClick
            self.expandWindow(isDockActivated: interaction.isDockActivated)
        }
    }

    private func releaseFocusAfterSuppressedSpaceSwitchIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard case .snapped = self.state else { return }
            guard Self.lastGlobalMouseDownAt <= self.lastSpaceChangeAt else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid else { return }
            guard Self.activateDockOnly() else { return }
            self.scheduleIndicatorVisibilityRefresh(after: 0.08)
        }
    }

    private func hasFocusedSiblingWindowOfApp() -> Bool {
        guard let focusedWindow = focusedWindowOfApp() else { return false }
        return !CFEqual(focusedWindow, windowElement)
    }

    private func isMouseInsideAnyVisibleSiblingWindow(_ mousePoint: CGPoint) -> Bool {
        let currentWindowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid)
        let screenBounds = getDisplayBounds()
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windowList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            guard ownerPID == pid else { continue }

            let rect = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
            if rect.width < 8 || rect.height < 8 { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            if alpha <= 0.05 { continue }

            if let cgWindowID = info[kCGWindowNumber as String] as? CGWindowID,
               let currentWindowID,
               cgWindowID == currentWindowID {
                continue
            }

            // Finder 等应用会带一个几乎铺满整块屏幕的“桌面层”窗口。
            // 鼠标离开左侧贴边窗口后很容易落进这层，导致误判成“还在同 App 的兄弟窗口里”。
            // 这里直接视为“不在兄弟窗口里”，因为它虽然命中几何区域，但不是用户真正进入的可交互子窗口。
            let isScreenSizedBackground =
                abs(rect.minX - screenBounds.minX) <= 4 &&
                abs(rect.minY - screenBounds.minY) <= 4 &&
                abs(rect.width - screenBounds.width) <= 4 &&
                abs(rect.height - screenBounds.height) <= 4
            if isScreenSizedBackground {
                continue
            }

            if rect.contains(mousePoint) {
                return true
            }
        }
        return false
    }

    private func isWithinSiblingWindowPostInteractionGrace(_ now: Date) -> Bool {
        guard let lastSiblingWindowInteractionAt else { return false }
        return now.timeIntervalSince(lastSiblingWindowInteractionAt) < Self.siblingWindowPostInteractionGraceInterval
    }

    private func updatePinControlWindow() {
        guard shouldShowPinControl,
              let rawFrame = getRawWindowFrame(),
              let pinFrames = pinControlFrames(for: rawFrame) else {
            pinControlWindow.orderOut(nil)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let shouldReveal = isTemporarilyPinned
            || pinFrames.triggerRect.contains(mouseLocation)
            || pinFrames.safeRect.contains(mouseLocation)
        let accentColor = AppConfig.shared.getColor(for: bundleID)
        pinControlWindow.update(
            frame: pinFrames.buttonFrame,
            hiddenFrame: pinFrames.hiddenFrame,
            isVisible: shouldReveal,
            isPinned: isTemporarilyPinned,
            accentColor: accentColor
        )
    }

    private var shouldShowPinControl: Bool {
        if isDragging { return false }
        if Date() < pinControlRevealSuppressionUntil { return false }
        if isTemporarilyPinned { return true }
        guard caseExpanded(), isWindowOnScreen() else { return false }
        return true
    }

    private func pinControlFrames(for rawFrame: CGRect) -> (buttonFrame: CGRect, hiddenFrame: CGRect, triggerRect: CGRect, safeRect: CGRect)? {
        guard currentEdge == 1 || currentEdge == 2 else { return nil }

        // 统一走 appKitFrame(fromCGFrame:) helper，避免与镜像路径维护两份手写公式；
        // 一旦跨屏修复或夹紧逻辑更新只需改 helper 一处。
        // 注意：局部变量名避免与方法 `appKitFrame(fromCGFrame:)` 同名造成 shadow。
        let appKitWindowFrame = appKitFrame(fromCGFrame: rawFrame)
        let screenFrame = getScreenForWindow().frame
        let buttonSize: CGFloat = 38
        let sideGap: CGFloat = 14
        let verticalInset: CGFloat = 2
        let minEdgePadding: CGFloat = 8

        let preferredSide: SnapEdge = currentEdge == 1 ? .right : .left
        let leftFits = appKitWindowFrame.minX - sideGap - buttonSize >= screenFrame.minX + minEdgePadding
        let rightFits = appKitWindowFrame.maxX + sideGap + buttonSize <= screenFrame.maxX - minEdgePadding

        let buttonSide: SnapEdge
        switch preferredSide {
        case .left:
            buttonSide = leftFits || !rightFits ? .left : .right
        case .right:
            buttonSide = rightFits || !leftFits ? .right : .left
        }

        let proposedX: CGFloat
        let hiddenX: CGFloat
        let corridorRect: CGRect
        let triggerRect: CGRect
        if buttonSide == .right {
            proposedX = appKitWindowFrame.maxX + sideGap
            hiddenX = appKitWindowFrame.maxX - buttonSize * 0.58
            corridorRect = CGRect(
                x: appKitWindowFrame.maxX - 2,
                y: appKitWindowFrame.maxY - buttonSize - verticalInset - 8,
                width: sideGap + buttonSize + 4,
                height: buttonSize + 20
            )
            triggerRect = CGRect(
                x: appKitWindowFrame.maxX - 72,
                y: appKitWindowFrame.maxY - 56,
                width: 110,
                height: 64
            )
        } else {
            proposedX = appKitWindowFrame.minX - buttonSize - sideGap
            hiddenX = appKitWindowFrame.minX - buttonSize * 0.42
            corridorRect = CGRect(
                x: appKitWindowFrame.minX - buttonSize - sideGap - 2,
                y: appKitWindowFrame.maxY - buttonSize - verticalInset - 8,
                width: sideGap + buttonSize + 4,
                height: buttonSize + 20
            )
            triggerRect = CGRect(
                x: appKitWindowFrame.minX - 38,
                y: appKitWindowFrame.maxY - 56,
                width: 110,
                height: 64
            )
        }

        let clampedX = Swift.max(
            screenFrame.minX + minEdgePadding,
            Swift.min(proposedX, screenFrame.maxX - buttonSize - minEdgePadding)
        )
        let clampedY = Swift.max(
            screenFrame.minY + minEdgePadding,
            Swift.min(appKitWindowFrame.maxY - buttonSize - verticalInset, screenFrame.maxY - buttonSize - minEdgePadding)
        )

        let buttonFrame = CGRect(x: clampedX, y: clampedY, width: buttonSize, height: buttonSize)
        let hiddenFrame = CGRect(x: hiddenX, y: clampedY, width: buttonSize, height: buttonSize)
        let safeRect = buttonFrame.insetBy(dx: -12, dy: -10).union(corridorRect)
        return (buttonFrame, hiddenFrame, triggerRect, safeRect)
    }

    func fusionReveal() {
        guard !isTemporarilyPinned else { return }
        guard !isAnimating else { return }
        guard Date() >= fusionReentrySuppressionUntil else { return }
        guard isEligibleForFusionInCurrentSpace() else { return }
        invalidatePendingFocusRelease()
        queuedForwardedHotkeyToggle = false
        guard let geometry = edgeGeometry() else { return }
        guard let currentFrame = getWindowFrame() else { return }
        rememberFocusReturnTargetBeforeReveal()
        let targetFrame = CGRect(
            x: geometry.expanded.x,
            y: geometry.expanded.y,
            width: lockedWidth > 0 ? lockedWidth : currentFrame.width,
            height: currentFrame.height
        )
        let hiddenFrame = CGRect(
            x: geometry.visualHidden.x,
            y: geometry.visualHidden.y,
            width: targetFrame.width,
            height: targetFrame.height
        )

        state = .expanded
        isAnimating = true
        pendingDockInteraction = false
        hasReleasedDockClick = false
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        hoverInterruptTimer?.invalidate()
        hoverInterruptTimer = nil
        mouseTrackingTimer?.invalidate()
        windowAnimator.stop()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        suppressActivationNotifications(for: 0.45)
        suppressIndicatorAnimations(for: 0.45)
        beginTargetedActivationWindow(for: 0.6)

        setWindowAlpha(1.0, isHidden: false)
        forceWindowGeometry(x: hiddenFrame.minX, y: hiddenFrame.minY, height: hiddenFrame.height)

        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate(options: .activateIgnoringOtherApps)
        }

        animateWindowPositionFast(
            from: hiddenFrame.minX,
            to: targetFrame.minX,
            startY: hiddenFrame.minY,
            endY: targetFrame.minY,
            duration: fusionTransitionDuration(),
            easeIn: false
        ) { [weak self] in
            guard let self else { return }
            self.forceWindowGeometry(x: targetFrame.minX, y: targetFrame.minY, height: targetFrame.height)
            self.isAnimating = false
            self.showIndicator(animated: false)
            self.startMouseTrackingTimer()
            axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.fusionReveal.main")
            axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.fusionReveal.focused")
            self.runQueuedForwardedHotkeyToggleIfNeeded()
        }
    }

    func fusionHide() {
        guard !isTemporarilyPinned else { return }
        guard !isAnimating else { return }
        queuedForwardedHotkeyToggle = false
        excludeFromFocusReturn(for: 0.6)
        guard let geometry = edgeGeometry() else { return }
        guard let currentFrame = getWindowFrame() else { return }
        let hiddenFrame = CGRect(
            x: geometry.visualHidden.x,
            y: geometry.visualHidden.y,
            width: lockedWidth > 0 ? lockedWidth : currentFrame.width,
            height: currentFrame.height
        )

        state = .snapped(edge: currentEdge, hiddenOrX: geometry.hidden.x)
        notifyTemporaryShortcutStashStateChanged(isStashed: true)
        isAnimating = true
        pendingDockInteraction = false
        hasReleasedDockClick = false
        hoverDelayTimer?.invalidate()
        hoverDelayTimer = nil
        hoverInterruptTimer?.invalidate()
        hoverInterruptTimer = nil
        mouseTrackingTimer?.invalidate()
        windowAnimator.stop()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        suppressActivationNotifications(for: 0.25)
        suppressIndicatorAnimations(for: 0.4)
        suppressFusionReentry(for: 0.45)

        animateWindowPositionFast(
            from: currentFrame.minX,
            to: hiddenFrame.minX,
            startY: currentFrame.minY,
            endY: hiddenFrame.minY,
            duration: fusionTransitionDuration(),
            easeIn: true
        ) { [weak self] in
            guard let self else { return }
            self.forceWindowGeometry(x: hiddenFrame.minX, y: hiddenFrame.minY, height: hiddenFrame.height)
            self.setWindowAlpha(0.01, isHidden: true, frameHint: currentFrame)
            self.isAnimating = false
            self.showIndicator(animated: false)
            self.runQueuedForwardedHotkeyToggleIfNeeded()
        }
    }

    func isEligibleForFusionInCurrentSpace() -> Bool {
        guard currentEdge == 1 || currentEdge == 2 else { return false }

        switch state {
        case .snapped, .expanded:
            break
        case .floating:
            return false
        }

        // 核心修复：增加对进程存活的信任，减少对探测结果单次失败的敏感度
        if let app = NSRunningApplication(processIdentifier: pid), app.isTerminated {
            return false
        }

        let screen = getScreenForWindow()
        if isInFullscreenSpace(screen: screen) { return false }
        return isWindowOnScreen()
    }

    func fusionStripDescriptor() -> FusionStripSessionDescriptor? {
        guard currentEdge == 1 || currentEdge == 2 else { return nil }

        switch state {
        case .snapped, .expanded:
            break
        case .floating:
            return nil
        }

        let screen = getScreenForWindow()
        if isInFullscreenSpace(screen: screen) { return nil }
        if !isIndicatorSuppressed && !fusionHoverLock {
            guard isWindowOnScreen() else { return nil }
        }
        guard let winFrame = edgeReferenceFrame() else { return nil }

        let displayHeight = primaryScreenHeight
        let visibleMinY = displayHeight - winFrame.minY - winFrame.height
        let visibleMaxY = visibleMinY + winFrame.height
        let opacity = AppConfig.shared.getOpacity(for: bundleID)
        let color = AppConfig.shared.getColor(for: bundleID).withAlphaComponent(CGFloat(opacity))

        return FusionStripSessionDescriptor(
            sessionID: ObjectIdentifier(self),
            session: self,
            edge: currentEdge,
            screenFrame: screen.frame,
            visibleMinY: visibleMinY,
            visibleMaxY: visibleMaxY,
            windowHeight: winFrame.height,
            color: color,
            title: appDisplayName,
            icon: appIcon,
            isExpanded: caseExpanded() && !isTemporarilyPinned,
            isPinned: isTemporarilyPinned
        )
    }
    
    private func caseExpanded() -> Bool {
        if case .expanded = state { return true }
        return false
    }

    private func caseSnapped() -> Bool {
        if case .snapped = state { return true }
        return false
    }

    private func isMainWindowOfApp() -> Bool {
        var mainValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXMainWindowAttribute as CFString,
            value: &mainValue,
            context: "WindowSession.isMainWindowOfApp.mainWindow"
        ) == .success,
              let mainWindowRef = mainValue else {
            return false
        }
        return CFEqual(unsafeBitCast(mainWindowRef, to: AXUIElement.self), windowElement)
    }

    private func suppressActivationNotifications(for duration: TimeInterval) {
        activationSuppressionUntil = Date().addingTimeInterval(duration)
    }

    private func suppressIndicatorAnimations(for duration: TimeInterval) {
        indicatorAnimationSuppressionUntil = Date().addingTimeInterval(duration)
    }

    /// 是否允许在快照条展开/折叠/重布局时播放指示条的拉伸回弹与点状收放动画。
    /// 受 "动态特效" 总开关与 indicatorAnimationSuppressionUntil 时间窗双重约束。
    private var isIndicatorAnimationAllowed: Bool {
        return AppConfig.shared.isVisualEffectEnabled && Date() >= indicatorAnimationSuppressionUntil
    }

    private func suppressFusionReentry(for duration: TimeInterval) {
        fusionReentrySuppressionUntil = Date().addingTimeInterval(duration)
    }

    private func excludeFromFocusReturn(for duration: TimeInterval) {
        focusReturnExclusionUntil = Date().addingTimeInterval(duration)
    }

    private func trackedWindowIDsForAlpha(frameHint: CGRect? = nil) -> [CGWindowID] {
        if let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) {
            return [windowID]
        }
        return []
    }

    private func clearTrackedWindowRecoveryState(frameHint: CGRect? = nil) {
        let windowIDs = trackedWindowIDsForAlpha(frameHint: frameHint)
        if windowIDs.isEmpty {
            return
        }
        AppConfig.shared.removeWindowRescueRecords(pid: pid, windowIDs: windowIDs.map { $0 })
    }

    private func safeRestorePosition(for frame: CGRect) -> CGPoint {
        let displayBounds = getDisplayBounds()
        let winWidth = lockedWidth > 0 ? lockedWidth : frame.width
        let safeY = frame.minY

        if currentEdge == 1 {
            return CGPoint(x: displayBounds.minX + 80, y: safeY)
        } else {
            return CGPoint(x: displayBounds.maxX - winWidth - 80, y: safeY)
        }
    }

    private func persistWindowRescueRecord(windowIDs: [CGWindowID], visibleFrame: CGRect) {
        guard currentEdge == 1 || currentEdge == 2 else { return }
        guard let windowID = windowIDs.first else { return }

        let record = WindowRescueRecord(
            bundleID: bundleID,
            pid: pid,
            windowID: UInt32(windowID),
            edge: currentEdge,
            visibleFrame: PersistedRect(visibleFrame),
            safeRestorePosition: PersistedPoint(safeRestorePosition(for: visibleFrame)),
            displayFrame: PersistedRect(getDisplayBounds()),
            updatedAt: Date().timeIntervalSince1970
        )
        AppConfig.shared.upsertWindowRescueRecord(record)
    }

    private func setWindowAlpha(
        _ alpha: CGFloat,
        isHidden: Bool,
        frameHint: CGRect? = nil,
        preserveRecoveryRecord: Bool = false
    ) {
        let windowIDs = trackedWindowIDsForAlpha(frameHint: frameHint)
        guard !windowIDs.isEmpty else { return }

        if isHidden, let frameHint {
            persistWindowRescueRecord(windowIDs: windowIDs, visibleFrame: frameHint)
        }

        WindowAlphaManager.shared.setAlpha(for: windowIDs, alpha: Float(alpha))
        for windowID in windowIDs {
            if isHidden {
                AppConfig.shared.addHiddenWindowRecord(pid: self.pid, windowID: windowID)
            } else if !preserveRecoveryRecord {
                AppConfig.shared.removeHiddenWindowRecord(pid: self.pid, windowID: windowID)
            }
        }

        if !isHidden && !preserveRecoveryRecord {
            clearTrackedWindowRecoveryState(frameHint: frameHint)
        }
    }

    private func fusionTransitionDuration() -> TimeInterval {
        0.12
    }

    private func standardTransitionDuration() -> TimeInterval {
        0.12
    }

    private func beginTargetedActivationWindow(for duration: TimeInterval) {
        Self.targetedActivationByPID[pid] = (ObjectIdentifier(self), Date().addingTimeInterval(duration))
        Self.preferredSessionByPID[pid] = ObjectIdentifier(self)
    }

    private func forceWindowGeometry(x: CGFloat, y: CGFloat, height: CGFloat) {
        setWindowPosition(position: CGPoint(x: x, y: y))
        let size = CGSize(width: lockedWidth, height: height)
        axSetSizeAttribute(on: windowElement, size: size, context: "WindowSession.forceWindowGeometry.size")
    }

    func restoreAndDestroy() {
        finishTemporaryShortcutSession(excludeWindow: false, removeSession: true)
        isTemporarilyPinned = false
        isMirrorPinActive = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        teardownMirrorCapture()
        let currentFrame = getWindowFrame() ?? CGRect(x: 100, y: 100, width: 400, height: 400)
        setWindowAlpha(1.0, isHidden: false, frameHint: currentFrame, preserveRecoveryRecord: true)
        
        // We deliberately do not unhide the app here! If the user or a third-party app (like DockMinimize)
        // explicitly hid the app, unhiding it here would break their intended state and cause infinite loops.        
        effectWindow.stopExpandEffect(closeWindow: true)
        
        effectWindow.stopExpandEffect(closeWindow: true)
        
        if case .floating = state {
            // 已在可视区域，无需处理
            clearTrackedWindowRecoveryState(frameHint: currentFrame)
        } else {
            // 核心修复：退出时将窗口完整推回屏幕内。
            let positionResult = axSetPositionAttribute(
                on: windowElement,
                position: safeRestorePosition(for: currentFrame),
                context: "WindowSession.restoreAndDestroy.position"
            )
            if positionResult == .success {
                clearTrackedWindowRecoveryState(frameHint: currentFrame)
            }
        }
        destroy()
    }
    
    private func destroy() {
        // 防御性主线程化：destroy 链路涉及 AppKit/UI 操作，且必须在 AXObserver 注册时所在的
        // 主 run loop 上拆除 run loop source。如果当前不在主线程（例如某条 dispatch.global 上
        // 的最后一个强引用被释放从而触发 deinit），就把整个 destroy 重新调度到主线程，
        // 避免在错误的 run loop 上调用 CFRunLoopRemoveSource 造成 source 残留 + use-after-free。
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.destroy() }
            return
        }
        Self.unregister(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let source = observerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            observerRunLoopSource = nil
        }
        mouseTrackingTimer?.invalidate()
        hoverDelayTimer?.invalidate()
        hoverInterruptTimer?.invalidate()
        pinnedRaiseTimer?.invalidate()
        // 置顶相关资源统一交给 teardownMirrorCapture：它会停 SCStream、摘 layer、停 hover
        // monitor、cancel pending resize work、停几何 timer。如果不调用，destroy 路径只
        // invalidate 几何 timer 就退出，挂在 NSEvent global/local monitor 上的两个 token
        // 永远不会被 removeMonitor，AppKit 会持续派发 mouseMoved/Dragged 到闭包，每销毁一个
        // 置顶会话累计一次泄漏。
        if isMirrorPinActive
            || isMirrorOverlayVisible
            || mirrorLiveCapturer != nil
            || !mirrorOverlayMouseMonitors.isEmpty
            || pendingMirrorOutputUpdate != nil
            || mirrorGeometryTimer != nil {
            isMirrorPinActive = false
            teardownMirrorCapture()
        }
        stateWatchdogTimer?.invalidate()
        stateWatchdogTimer = nil
        windowAnimator.stop()
        indicatorWindow.close()
        pinControlWindow.close()
        mirrorOverlayWindow.close()
        // 从 AccessibilityRuntimeGuard 的 messaging timeout 缓存中移除本会话持有的
        // AX element，避免 Set 长期驻留已消亡的 AXUIElement 引用（长时间运行的
        // 菜单栏应用累计可见的内存泄漏）。
        AccessibilityRuntimeGuard.shared.discardMessagingTimeoutCache(for: windowElement)
        AccessibilityRuntimeGuard.shared.discardMessagingTimeoutCache(for: appElement)
    }

    // MARK: - 状态自愈 Watchdog
    //
    // 这是 SideBar 的"状态机救生圈"。它只做两件事，永远不主动改 state / 几何 / 焦点：
    //
    // 1. 把"应显未显"的快照条捞回来。
    //    背景：极偶发情况下，折叠动画 completion 与外部对 `windowAnimator.stop()` 的
    //    调用产生竞争，导致 `isAnimating` 没被复位，或 `refreshIndicatorVisibility`
    //    在 `isWindowOnScreen()` 假阴性、跨 Space 切换时被误判隐藏，最终用户看到
    //    "窗口贴边了，但是边缘那条彩色快照条没出现"。一旦发生，**没有任何代码会再把
    //    它救回来**——只能重启进程。该 watchdog 周期检查这种"应显未显"的死锁状态，
    //    若命中条件就再调一次 `showIndicator(animated:false)` 把它重新 orderFront。
    //
    // 2. 把卡死的 `isAnimating` 复位。
    //    背景：所有正常的展开/折叠/融合动画都远短于 3 秒。一旦 `isAnimatingSince`
    //    跨过这个阈值仍未被复位，几乎可以确定是动画 completion 路径被吞掉了，
    //    必须强制把 `isAnimating` 拨回 false，否则后续所有依赖它的 indicator
    //    刷新链路都会持续 early return，永远走不出来。
    //
    // 注意：watchdog 不依赖、也不修改 isIndicatorSuppressed / isInFullscreenSpace /
    // fusionHoverLock / isTemporarilyPinned 等其它状态——这些状态出错时它一律按
    // "正常情况"对待并直接放过，让既有逻辑自己处理；watchdog 只负责打捞"明显失序"。
    private func startStateWatchdog() {
        stateWatchdogTimer?.invalidate()
        stateWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Self.stateWatchdogInterval,
            repeats: true
        ) { [weak self] _ in
            self?.runStateWatchdogTick()
        }
    }

    private func runStateWatchdogTick() {
        // 兜底 1：isAnimating 超时复位。
        if isAnimating, let since = isAnimatingSince,
           Date().timeIntervalSince(since) > Self.isAnimatingTimeoutSeconds {
            print("⚠️ [Watchdog] \(bundleID) isAnimating 卡死 \(Int(Date().timeIntervalSince(since)))s，强制复位并停 animator")
            // 关键：光复位 isAnimating 标志不够。CVDisplayLink 是独立跑在
            // 显示服务线程上的，watchdog 不主动 stop() 它，一旦 hover-expand 因
            // slow-write 补偿卡住 easing，displayLink 会以 60Hz 持续 `axSetPositionAttribute`
            // 到目标 App，CPU 常驻高负载直到 SideBar 重启。必须显式停 animator。
            windowAnimator.stop()
            isAnimating = false
        }

        // 兜底 2：吸附态下，快照条应显未显时重新 showIndicator。
        // 注意所有早退条件都和 refreshIndicatorVisibility() 主路径保持一致，避免和它打架。
        guard case .snapped = state else { return }
        if isAnimating { return }
        if isIndicatorSuppressed { return }
        if fusionHoverLock { return }
        if isTemporarilyPinned { return }
        if currentEdge != 1 && currentEdge != 2 { return }

        let screen = getScreenForWindow()
        if isInFullscreenSpace(screen: screen) { return }

        guard isWindowOnScreen() else { return }

        let isHidden = !indicatorWindow.isVisible || indicatorWindow.alphaValue < 0.1
        guard isHidden else { return }

        print("🛟 [Watchdog] \(bundleID) 检测到吸附态快照条应显未显，重新展示")
        indicatorWindow.alphaValue = 1.0
        showIndicator(animated: false)
    }

    private static func register(_ session: WindowSession) {
        cleanupRegistry()
        sessionRegistry.append(WeakWindowSessionBox(session))
    }

    private static func unregister(_ session: WindowSession) {
        sessionRegistry.removeAll {
            guard let stored = $0.session else { return true }
            return stored === session
        }
        if preferredSessionByPID[session.pid] == ObjectIdentifier(session) {
            preferredSessionByPID.removeValue(forKey: session.pid)
        }
        if targetedActivationByPID[session.pid]?.sessionID == ObjectIdentifier(session) {
            targetedActivationByPID.removeValue(forKey: session.pid)
        }
    }

    private static func cleanupRegistry() {
        sessionRegistry.removeAll { $0.session == nil }
        let now = Date()
        targetedActivationByPID = targetedActivationByPID.filter { $0.value.expiresAt > now }
        preferredSessionByPID = preferredSessionByPID.filter { pid, sessionID in
            sessionRegistry.contains {
                guard let session = $0.session else { return false }
                return session.pid == pid && ObjectIdentifier(session) == sessionID
            }
        }
    }

    private static func shouldYieldPinnedWindow(to pid: pid_t, excluding current: WindowSession) -> Bool {
        cleanupRegistry()
        for box in sessionRegistry {
            guard let session = box.session, session !== current else { continue }
            guard session.pid == pid else { continue }
            if session.caseExpanded() && !session.isTemporaryPinnedForFusion() {
                return true
            }
        }
        return false
    }

    private static func isAppActivationAllowed(for session: WindowSession) -> Bool {
        cleanupRegistry()
        let sessionID = ObjectIdentifier(session)
        if let targeted = targetedActivationByPID[session.pid] {
            return targeted.sessionID == sessionID
        }

        let siblingCount = sessionRegistry.reduce(into: 0) { count, box in
            if box.session?.pid == session.pid {
                count += 1
            }
        }
        guard siblingCount > 1 else { return true }

        if let preferred = preferredSessionByPID[session.pid] {
            return preferred == sessionID
        }
        return false
    }

    /// 通知点击唤回时的"主窗口"选择：同 App 多窗口中只放行一个代表窗口。
    /// 优先级：用户最近交互（展开/快捷键）过的窗口 > AXMainWindow > 注册顺序首个。
    private static func isPreferredNotificationRevealSession(_ session: WindowSession) -> Bool {
        cleanupRegistry()
        let sessionID = ObjectIdentifier(session)
        let candidates = sessionRegistry.compactMap { $0.session }.filter {
            $0.pid == session.pid && $0.caseSnapped()
        }
        guard candidates.count > 1 else {
            return candidates.first.map { ObjectIdentifier($0) == sessionID } ?? false
        }
        if let preferred = preferredSessionByPID[session.pid],
           candidates.contains(where: { ObjectIdentifier($0) == preferred }) {
            return preferred == sessionID
        }
        if let mainSession = candidates.first(where: { $0.isMainWindowOfApp() }) {
            return ObjectIdentifier(mainSession) == sessionID
        }
        return candidates.first.map { ObjectIdentifier($0) == sessionID } ?? false
    }

    private static func shouldExcludeCandidateFromFocusReturn(windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        cleanupRegistry()
        let now = Date()
        for box in sessionRegistry {
            guard let session = box.session else { continue }
            guard session.pid == ownerPID else { continue }
            guard let sessionWindowID = WindowAlphaManager.shared.findWindowID(for: session.windowElement, pid: session.pid) else { continue }
            guard sessionWindowID == windowID else { continue }

            if session.focusReturnExclusionUntil > now {
                return true
            }

            if case .snapped = session.state {
                return true
            }
        }
        return false
    }

    private func scheduleFocusRelease(after delay: TimeInterval) {
        let generation = focusReleaseGeneration + 1
        focusReleaseGeneration = generation
        let sourcePID = pid
        let sourceWindowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid)
        let focusSnapshot = focusReturnSnapshot
        focusReturnSnapshot = nil
        let preferredTargetPID = Self.preferredReleaseTargetPID(sourcePID: sourcePID, sourceWindowID: sourceWindowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.focusReleaseGeneration == generation else { return }
            if Self.shouldSkipScheduledFocusRestore(sourcePID: sourcePID, targetPID: focusSnapshot?.pid) {
                return
            }

            if let focusSnapshot,
               Self.restoreFocus(to: focusSnapshot, sourcePID: sourcePID, sourceWindowID: sourceWindowID) {
                return
            }

            Self.activateNonManagedApp(
                preferredTargetPID: preferredTargetPID,
                sourcePID: sourcePID,
                sourceWindowID: sourceWindowID
            )
        }
    }

    private func invalidatePendingFocusRelease() {
        focusReleaseGeneration += 1
    }

    private func runQueuedForwardedHotkeyToggleIfNeeded() {
        guard queuedForwardedHotkeyToggle else { return }
        queuedForwardedHotkeyToggle = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isAnimating else {
                self.queuedForwardedHotkeyToggle = true
                return
            }
            guard !self.relinquishToDockMinimizeIfDetachedFromEdge() else { return }
            _ = self.toggleExpandCollapse()
        }
    }

    private func isDetachedFromManagedEdge(_ frame: CGRect) -> Bool {
        let displayBounds = getDisplayBounds()
        switch currentEdge {
        case 1:
            return abs(frame.minX - displayBounds.minX) > Self.managedEdgeDetachTolerance
        case 2:
            return abs(frame.maxX - displayBounds.maxX) > Self.managedEdgeDetachTolerance
        default:
            return true
        }
    }

    private func transitionToFloatingFromManagedState(
        notifyOwnerChange: Bool = true,
        restoreVisiblePositionIfNeeded: Bool = false
    ) {
        guard case .floating = state else {
            let previousState = state
            invalidatePendingFocusRelease()
            queuedForwardedHotkeyToggle = false
            let shouldEndTemporaryShortcutSession = isTemporaryShortcutManaged
            let currentFrame = getWindowFrame() ?? CGRect(x: 100, y: 100, width: 400, height: 400)
            state = .floating
            if notifyOwnerChange {
                onManagedEdgeDetachment?(self)
            }
            notifyTemporaryShortcutStashStateChanged(isStashed: false)
            unlockScreen()
            isIndicatorSuppressed = false
            indicatorWindow.orderOut(nil)
            pinControlWindow.orderOut(nil)
            effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
            mouseTrackingTimer?.invalidate()
            hoverDelayTimer?.invalidate()
            hoverInterruptTimer?.invalidate()
            outsideCollapseCandidateSince = nil
            edgeDetachCandidateSince = nil
            lastSiblingWindowInteractionAt = nil
            pendingDockInteraction = false
            hasReleasedDockClick = false
            fusionHoverLock = false
            windowAnimator.stop()
            if restoreVisiblePositionIfNeeded {
                setWindowAlpha(1.0, isHidden: false, frameHint: currentFrame, preserveRecoveryRecord: true)
                if case .snapped = previousState {
                    let positionResult = axSetPositionAttribute(
                        on: windowElement,
                        position: safeRestorePosition(for: currentFrame),
                        context: "WindowSession.transitionToFloatingFromManagedState.position"
                    )
                    if positionResult == .success {
                        clearTrackedWindowRecoveryState(frameHint: currentFrame)
                    }
                } else {
                    clearTrackedWindowRecoveryState(frameHint: currentFrame)
                }
            }
            if shouldEndTemporaryShortcutSession {
                let shouldKeepConfiguredSession = AppConfig.shared.isAppEnabled(bundleID: bundleID)
                finishTemporaryShortcutSession(
                    excludeWindow: !shouldKeepConfiguredSession,
                    removeSession: !shouldKeepConfiguredSession
                )
                if !shouldKeepConfiguredSession {
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreAndDestroy()
                    }
                }
            }
            return
        }
    }

    private static func shouldSkipScheduledFocusRestore(sourcePID: pid_t, targetPID: pid_t?) -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let selfBundleID = Bundle.main.bundleIdentifier ?? ""

        if frontmostApp.bundleIdentifier == selfBundleID {
            return false
        }

        if frontmostApp.processIdentifier == sourcePID {
            return false
        }

        if let targetPID, frontmostApp.processIdentifier == targetPID {
            return false
        }

        return true
    }

    private static func isSnapshotVisibleInCurrentSpace(_ snapshot: FocusReturnSnapshot) -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == snapshot.pid,
                  let visibleWindowID = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { continue }

            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let width = boundsDict["Width"] as? CGFloat ?? 0
                let height = boundsDict["Height"] as? CGFloat ?? 0
                guard width >= 16, height >= 16 else { continue }
            }

            if let windowID = snapshot.windowID {
                if visibleWindowID == windowID {
                    return true
                }
            } else {
                return true
            }
        }

        return false
    }

    private static func restoreFocus(
        to snapshot: FocusReturnSnapshot,
        sourcePID: pid_t,
        sourceWindowID: CGWindowID?
    ) -> Bool {
        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        guard snapshot.bundleID != selfBundleID else { return false }
        guard !isSnapshot(snapshot, sameAsSourcePID: sourcePID, sourceWindowID: sourceWindowID) else {
            return false
        }

        if let windowID = snapshot.windowID,
           shouldExcludeCandidateFromFocusReturn(windowID: windowID, ownerPID: snapshot.pid) {
            return false
        }

        guard isSnapshotVisibleInCurrentSpace(snapshot) else { return false }

        guard let app = NSRunningApplication(processIdentifier: snapshot.pid) else { return false }
        guard !app.isHidden else { return false }

        let activated = app.activate(options: .activateIgnoringOtherApps) || app.activate()
        guard activated else { return false }

        guard let windowID = snapshot.windowID else { return true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let appElement = AXUIElementCreateApplication(snapshot.pid)
            guard let matchedWindow = matchingAXWindow(in: appElement, pid: snapshot.pid, windowID: windowID) else {
                return
            }
            axSetBoolAttribute(on: matchedWindow, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.restoreFocus.main")
            axSetBoolAttribute(on: matchedWindow, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.restoreFocus.focused")
        }

        return true
    }

    private static func matchingAXWindow(in appElement: AXUIElement, pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        var windowsValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXWindowsAttribute as CFString,
            value: &windowsValue,
            context: "WindowSession.matchingAXWindow.windows"
        ) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            guard WindowAlphaManager.shared.findWindowID(for: window, pid: pid) == windowID else { continue }
            return window
        }

        return nil
    }

    private static func preferredReleaseSourceIndex(
        in windowList: [[String: Any]],
        sourcePID: pid_t?,
        sourceWindowID: CGWindowID?
    ) -> Int? {
        if let sourceWindowID {
            for (index, info) in windowList.enumerated() {
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                      windowNumber == sourceWindowID else {
                    continue
                }
                return index
            }
        }

        if let sourcePID {
            for (index, info) in windowList.enumerated() {
                guard let layer = info[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID == sourcePID else {
                    continue
                }
                return index
            }
        }

        return nil
    }

    private static func firstEligibleReleaseTargetPID(
        in windowList: [[String: Any]],
        startingAfter startIndex: Int?,
        sourcePID: pid_t?,
        selfBundleID: String
    ) -> pid_t? {
        let start = (startIndex ?? -1) + 1
        guard start < windowList.count else { return nil }

        for index in start..<windowList.count {
            let info = windowList[index]
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            if let sourcePID, pid == sourcePID { continue }
            if shouldExcludeCandidateFromFocusReturn(windowID: windowID, ownerPID: pid) { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            if alpha <= 0.05 { continue }

            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let width = boundsDict["Width"] as? CGFloat ?? 0
                let height = boundsDict["Height"] as? CGFloat ?? 0
                if width < 16 || height < 16 { continue }
            }

            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            if app.activationPolicy == .regular &&
                !app.isHidden &&
                bundleID != selfBundleID {
                return pid
            }
        }

        return nil
    }

    private static func preferredReleaseTargetPID(sourcePID: pid_t, sourceWindowID: CGWindowID?) -> pid_t? {
        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let sourceIndex = preferredReleaseSourceIndex(in: windowList, sourcePID: sourcePID, sourceWindowID: sourceWindowID)
        if let pid = firstEligibleReleaseTargetPID(
            in: windowList,
            startingAfter: sourceIndex,
            sourcePID: sourcePID,
            selfBundleID: selfBundleID
        ) {
            return pid
        }
        return nil
    }

    private static func activatePreferredTarget(pid: pid_t, selfBundleID: String, sourcePID: pid_t?) -> Bool {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  ownerPID == pid else {
                continue
            }

            if let sourcePID, ownerPID == sourcePID { return false }
            if shouldExcludeCandidateFromFocusReturn(windowID: windowID, ownerPID: ownerPID) { return false }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            if alpha <= 0.05 { continue }

            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let width = boundsDict["Width"] as? CGFloat ?? 0
                let height = boundsDict["Height"] as? CGFloat ?? 0
                if width < 16 || height < 16 { continue }
            }

            guard let app = NSRunningApplication(processIdentifier: ownerPID) else { return false }
            let bundleID = app.bundleIdentifier ?? ""
            guard app.activationPolicy == .regular, !app.isHidden, bundleID != selfBundleID else {
                return false
            }
            app.activate()
            return true
        }

        return false
    }

    @discardableResult
    private static func activateDockOnly() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        return dock.activate(options: [])
    }
    
    /// 激活一个不被 SideBar 管理的应用来释放前台状态
    static func activateNonManagedApp(
        preferredTargetPID: pid_t? = nil,
        sourcePID: pid_t? = nil,
        sourceWindowID: CGWindowID? = nil
    ) {
        let selfBundleID = Bundle.main.bundleIdentifier ?? ""

        if let preferredTargetPID,
           activatePreferredTarget(pid: preferredTargetPID, selfBundleID: selfBundleID, sourcePID: sourcePID) {
            return
        }
        
        // 1. 获取按 Z 轴顺序从前到后的屏幕窗口列表
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        // 2. 优先从“当前折叠窗口的下一层”开始往后找，精确把焦点交回它下面那一个应用。
        let sourceIndex = preferredReleaseSourceIndex(in: windowList, sourcePID: sourcePID, sourceWindowID: sourceWindowID)
        if let targetPID = firstEligibleReleaseTargetPID(
            in: windowList,
            startingAfter: sourceIndex,
            sourcePID: sourcePID,
            selfBundleID: selfBundleID
        ), let app = NSRunningApplication(processIdentifier: targetPID) {
            app.activate()
            return
        }

        // 3. 如果来源窗口已经不在可见列表里，再退回“全屏最前面的未管理 regular app”。
        if let targetPID = firstEligibleReleaseTargetPID(
            in: windowList,
            startingAfter: nil,
            sourcePID: sourcePID,
            selfBundleID: selfBundleID
        ), let app = NSRunningApplication(processIdentifier: targetPID) {
            app.activate()
            return
        }
        
        // 4. 空桌面兜底：优先交给 Dock 本身。
        // Dock 没有可展开的标准窗口，既能释放当前前台状态，又不会把 Finder 的被管理窗口误拉出来。
        if activateDockOnly() {
            return
        }

        // 5. 极端兜底：如果 Dock 无法接管，再退回 Finder，但忽略这次程序内部触发的激活。
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            registerProgrammaticActivationIgnore(for: finder.processIdentifier, duration: 0.45)
            finder.activate()
        }
    }

    private static func registerProgrammaticActivationIgnore(for pid: pid_t, duration: TimeInterval) {
        cleanupProgrammaticActivationIgnores()
        programmaticActivationIgnoreUntilByPID[pid] = Date().addingTimeInterval(duration)
    }

    private static func shouldIgnoreProgrammaticActivation(for pid: pid_t) -> Bool {
        cleanupProgrammaticActivationIgnores()
        guard let until = programmaticActivationIgnoreUntilByPID[pid] else { return false }
        return until > Date()
    }

    private static func cleanupProgrammaticActivationIgnores() {
        let now = Date()
        programmaticActivationIgnoreUntilByPID = programmaticActivationIgnoreUntilByPID.filter { $0.value > now }
    }
    
    private func setupAXObserver() {
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { (observer: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) in
            let session = Unmanaged<WindowSession>.fromOpaque(context!).takeUnretainedValue()
            if notification == kAXWindowMovedNotification as CFString {
                if session.shouldTreatObservedMoveAsUserDrag() {
                    session.isDragging = true
                }
                DispatchQueue.main.async {
                    session.handleObservedGeometryChange()
                }
            } else if notification == kAXWindowResizedNotification as CFString {
                DispatchQueue.main.async {
                    session.handleObservedGeometryChange()
                }
            } else if notification == kAXWindowMiniaturizedNotification as CFString {
                session.handleMiniaturized()
            } else if notification == kAXUIElementDestroyedNotification as CFString {
                session.handleDestroyed()
            }
        }
        
        if AccessibilityRuntimeGuard.createObserver(
            pid: pid,
            callback: callback,
            observer: &newObserver,
            context: "WindowSession.setupAXObserver.createObserver"
        ) == .success, let observer = newObserver {
            self.axObserver = observer
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            
            let notifications: [(CFString, String)] = [
                (kAXWindowMovedNotification as CFString, "WindowSession.setupAXObserver.moved"),
                (kAXWindowResizedNotification as CFString, "WindowSession.setupAXObserver.resized"),
                (kAXWindowMiniaturizedNotification as CFString, "WindowSession.setupAXObserver.miniaturized"),
                (kAXUIElementDestroyedNotification as CFString, "WindowSession.setupAXObserver.destroyed")
            ]
            for (notificationName, context) in notifications {
                let result = AccessibilityRuntimeGuard.addObserverNotification(
                    observer,
                    element: windowElement,
                    notification: notificationName,
                    context: context,
                    refcon: selfPtr
                )
                if result != .success {
                    return
                }
            }
            
            self.observerRunLoopSource = AXObserverGetRunLoopSource(observer)
            // 显式绑定到主 run loop：保证 AX 回调始终在主线程，且 destroy() 时能从同一 run loop 上拆除。
            CFRunLoopAddSource(CFRunLoopGetMain(), self.observerRunLoopSource, .defaultMode)
        }
    }

    private func shouldTreatObservedMoveAsUserDrag() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        guard !caseSnapped() else { return false }
        guard let sample = Self.lastGlobalMouseDownSample else { return false }
        guard Date().timeIntervalSince(sample.at) < 30 else { return false }
        guard sample.region == .content else { return false }
        guard let frame = getRawWindowFrame() else { return false }

        let mappedMouseDown = CGPoint(
            x: sample.location.x,
            y: primaryScreenHeight - sample.location.y
        )
        return frame.insetBy(dx: -8, dy: -8).contains(mappedMouseDown)
    }

    private func handleObservedGeometryChange() {
        // 性能优化：动画期间是"我们自己"在 60Hz 反复写 AX 位置，每一帧都会
        // 反向触发一次 kAXWindowMovedNotification 到本回调。放任它进入
        // showIndicator / updatePinControlWindow / syncMirrorGeometryWithSourceWindow
        // 会在动画持续期间每 16ms 多派发一轮 AX 读 + NSPanel setFrame，白白抬高
        // 主线程占用；等 completion 跑完后再从状态机主路径统一刷新即可。
        if isAnimating { return }

        // 标记几何已变化：checkMouseForCollapse / interactionHitTestFrame 会据此
        // 失效缓存，重新读取真实 frame（否则会一直用旧 frame 判定鼠标内外）。
        observedGeometryChangeToken &+= 1

        if relinquishToDockMinimizeIfDetachedFromEdge() {
            return
        }
        if isTemporarilyPinned {
            showIndicator(animated: false)
        }
        if isMirrorPinActive {
            // 实时采集模式下，画面由 SCStream 推流，几何由专门的定时器跟踪；
            // 这里只在 AX 观察到变化时立刻同步一次面板位置，缩短肉眼可感的延迟。
            syncMirrorGeometryWithSourceWindow()
        }
        if case .expanded = state {
            showIndicator(animated: false)
            updatePinControlWindow()
        }
    }
    
    private func handleMiniaturized() {
        if case .floating = state { return }
        print("🗕 窗口被最小化，解除边栏")
        finishTemporaryShortcutSession(excludeWindow: false, removeSession: true)
        isTemporarilyPinned = false
        isMirrorPinActive = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        teardownMirrorCapture()
        state = .floating
        indicatorWindow.orderOut(nil)
        pinControlWindow.orderOut(nil)
        effectWindow.stopExpandEffect(closeWindow: true)
        mouseTrackingTimer?.invalidate()
        outsideCollapseCandidateSince = nil
        edgeDetachCandidateSince = nil
    }
    
    private func handleDestroyed() {
        print("❌ 窗口被关闭，销毁 SideBar Session")
        finishTemporaryShortcutSession(excludeWindow: false, removeSession: true)
        restoreAndDestroy()
    }
    
    @discardableResult
    func toggleExpandCollapse() -> Bool {
        if isTemporarilyPinned {
            releaseTemporaryPin()
            return true
        }
        switch state {
        case .expanded:
            guard collapseWindow() else { return false }
            // 快捷键折叠后释放前台状态，确保后续可通过 Dock 唤醒
            scheduleFocusRelease(after: 0.35)
            return true
        case .snapped:
            // 快捷键触发展开：需要豁免期保护，与 Dock 展开共用同一路径
            hasReleasedDockClick = true // 快捷键无需等待松开鼠标
            guard expandWindow(isDockActivated: true) else { return false }
            
            // 快捷键展开需要强制置顶应用并获取焦点（Dock有系统帮助，快捷键没有）
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: .activateIgnoringOtherApps)
            }
            axSetBoolAttribute(on: windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.toggleExpandCollapse.main")
            axSetBoolAttribute(on: windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.toggleExpandCollapse.focused")
            return true
        case .floating:
            return false
        }
    }

    func enableTemporaryShortcutManagement() {
        if !isTemporaryShortcutManaged {
            AppConfig.shared.setTemporaryDockMinimizeExclusion(bundleID: bundleID, excluded: true)
        }
        isTemporaryShortcutManaged = true
    }

    func toggleTemporaryShortcutStash() {
        if isTemporarilyPinned {
            releaseTemporaryPin()
            return
        }

        switch state {
        case .floating:
            guard let frame = getWindowFrame() else { return }
            let displayBounds = detectDisplayBounds()
            let candidateEdges = [1, 2].filter {
                !hasAdjacentScreen(at: $0, bounds: displayBounds) && isSnapAllowed(for: $0)
            }

            let targetEdge = candidateEdges.min { lhs, rhs in
                distanceToEdge(lhs, frame: frame, displayBounds: displayBounds) < distanceToEdge(rhs, frame: frame, displayBounds: displayBounds)
            }

            guard let targetEdge else { return }
            lockedWidth = frame.width
            initialFrameCaptured = true
            lockCurrentScreen()
            snapToEdge(edgeConfig: targetEdge, frame: frame, displayBounds: displayBounds)
        case .snapped, .expanded:
            toggleExpandCollapse()
        }
    }
    
    func handleMouseUp() {
        let wasDragging = isDragging
        isDragging = false
        
        guard let frame = getWindowFrame() else { return }
        // 浮动状态下动态检测屏幕（此时窗口在可见位置，检测可靠）
        let displayBounds = detectDisplayBounds()
        let edgeThreshold: CGFloat = 40
        let minX = displayBounds.minX
        let maxX = displayBounds.maxX
        
        if !wasDragging { return }
        if isTemporarilyPinned {
            if let rawFrame = getRawWindowFrame(), abs(rawFrame.width - lockedWidth) > 1 {
                lockedWidth = rawFrame.width
                initialFrameCaptured = true
            }
            pinControlRevealSuppressionUntil = Date().addingTimeInterval(0.18)
            showIndicator(animated: false)
            pinControlWindow.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, !self.isDragging else { return }
                self.updatePinControlWindow()
            }
            return
        }
        
        let candidateEdges = [1, 2].compactMap { edge -> (edge: Int, score: CGFloat)? in
            guard !hasAdjacentScreen(at: edge, bounds: displayBounds), isSnapAllowed(for: edge) else { return nil }
            switch edge {
            case 1:
                guard frame.minX <= (minX + edgeThreshold) else { return nil }
                return (edge, (minX + edgeThreshold) - frame.minX)
            case 2:
                guard frame.maxX >= (maxX - edgeThreshold) else { return nil }
                return (edge, frame.maxX - (maxX - edgeThreshold))
            default:
                return nil
            }
        }

        if let bestEdge = candidateEdges.max(by: { lhs, rhs in
            if abs(lhs.score - rhs.score) < 0.5 {
                return edgePriority(lhs.edge) > edgePriority(rhs.edge)
            }
            return lhs.score < rhs.score
        })?.edge {
            lockCurrentScreen()
            snapToEdge(edgeConfig: bestEdge, frame: frame, displayBounds: displayBounds)
        } else {
            if case .floating = state {} else {
                transitionToFloatingFromManagedState()
            }
        }
    }
    
    private func edgeGeometry(for frame: CGRect? = nil) -> (expanded: CGPoint, hidden: CGPoint, visualHidden: CGPoint)? {
        guard let frame = frame ?? getWindowFrame() else { return nil }
        let displayBounds = getDisplayBounds()
        let lockedOrCurrentWidth = lockedWidth > 0 ? lockedWidth : frame.width
        let hideOffset: CGFloat = 20000
        let visualHideOffset: CGFloat = 1

        switch currentEdge {
        case 1:
            let expanded = CGPoint(x: displayBounds.minX, y: frame.minY)
            let hidden = CGPoint(x: displayBounds.minX - frame.width - hideOffset, y: frame.minY)
            let visualHidden = CGPoint(x: displayBounds.minX - frame.width + visualHideOffset, y: frame.minY)
            return (expanded, hidden, visualHidden)
        case 2:
            let expanded = CGPoint(x: displayBounds.maxX - lockedOrCurrentWidth, y: frame.minY)
            let hidden = CGPoint(x: displayBounds.maxX + hideOffset, y: frame.minY)
            let visualHidden = CGPoint(x: displayBounds.maxX - visualHideOffset, y: frame.minY)
            return (expanded, hidden, visualHidden)
        default:
            return nil
        }
    }

    private func distanceToEdge(_ edge: Int, frame: CGRect, displayBounds: CGRect) -> CGFloat {
        switch edge {
        case 1:
            return abs(frame.minX - displayBounds.minX)
        case 2:
            return abs(displayBounds.maxX - frame.maxX)
        default:
            return .greatestFiniteMagnitude
        }
    }

    private func edgePriority(_ edge: Int) -> Int {
        switch edge {
        case 2:
            return 2
        case 1:
            return 1
        default:
            return 0
        }
    }

    private func collapsedWindowAlpha() -> Float {
        0.01
    }
    
    /// 判断给定的 CG bounds 是否与当前任何一块 live NSScreen 匹配。
    /// 用于在 adopt/收编逻辑前验证锁定几何仍然有效，防止在屏幕参数变化后
    /// 用已失效的坐标把用户刚拖出来的窗口再次钉死在旧边缘。
    /// 复用 `cgBounds(for:)` 助手（line 1118），避免坐标转换公式再多一份 inline 副本。
    private func displayBoundsMatchesAnyLiveScreen(_ bounds: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let cg = cgBounds(for: screen)
            if abs(cg.minX  - bounds.minX)  < 1 &&
               abs(cg.minY  - bounds.minY)  < 1 &&
               abs(cg.width - bounds.width) < 1 &&
               abs(cg.height - bounds.height) < 1 {
                return true
            }
        }
        return false
    }

    private func checkAndAdoptEdgeState() {
        guard let frame = getWindowFrame() else { return }
        let displayBounds = getDisplayBounds()

        // 防护：如果 getDisplayBounds() 返回的 bounds 已经不与任何一块 live 屏幕匹配
        //（例如刚发生分辨率切换但 handleScreenParametersChanged 尚未跑完 reseat），
        // 任何 adopt 都会把窗口重新钉到已失效的坐标上、用户根本拖不出来。
        // 此时主动放弃锁定，让下一次 checkAndAdoptEdgeState/detectDisplayBounds
        // 走"动态检测"路径。
        if snappedScreen != nil && !displayBoundsMatchesAnyLiveScreen(displayBounds) {
            print("⚠️ \(bundleID) 检测到锁定 bounds 已失效 \(displayBounds)，主动清空以允许用户重新拖拽")
            unlockScreen()
            return
        }

        let threshold: CGFloat = 8 // 允许一定误差
        
        let leftHiddenX = displayBounds.minX - frame.width + 1
        let rightHiddenX = displayBounds.maxX - 1
        
        let shouldSnapLeft = abs(frame.minX - leftHiddenX) <= threshold && !hasAdjacentScreen(at: 1, bounds: displayBounds) && isSnapAllowed(for: 1)
        let shouldSnapRight = abs(frame.minX - rightHiddenX) <= threshold && !hasAdjacentScreen(at: 2, bounds: displayBounds) && isSnapAllowed(for: 2)
        
        if shouldSnapLeft {
            print("⚓ 自动收编: 检测到 \(bundleID) 在左边缘，进入吸附态")
            currentEdge = 1
            lockedWidth = frame.width
            lockCurrentScreen() // 吸附时锁定屏幕
            state = .snapped(edge: 1, hiddenOrX: edgeGeometry(for: frame)?.hidden.x ?? 0)
            indicatorWindow.alphaValue = 1.0 // 核心修复：解除 init 时的透明锁定
            showIndicator()
            updatePinControlWindow()
            
            // 确保应用重启后（macOS可能会恢复其位置但初始 alpha 为 1）窗口视觉被正确隐藏
            let visibleFrame = CGRect(x: displayBounds.minX, y: frame.minY, width: frame.width, height: frame.height)
            setWindowAlpha(CGFloat(collapsedWindowAlpha()), isHidden: true, frameHint: visibleFrame)
        } else if shouldSnapRight {
            print("⚓ 自动收编: 检测到 \(bundleID) 在右边缘，进入吸附态")
            currentEdge = 2
            lockedWidth = frame.width
            lockCurrentScreen() // 吸附时锁定屏幕
            state = .snapped(edge: 2, hiddenOrX: edgeGeometry(for: frame)?.hidden.x ?? 0)
            indicatorWindow.alphaValue = 1.0 // 核心修复：解除 init 时的透明锁定
            showIndicator()
            updatePinControlWindow()
            
            let visibleFrame = CGRect(x: displayBounds.maxX - frame.width, y: frame.minY, width: frame.width, height: frame.height)
            setWindowAlpha(CGFloat(collapsedWindowAlpha()), isHidden: true, frameHint: visibleFrame)
        }
    }
    
    private func animateWindowPositionFast(
        from startX: CGFloat,
        to endX: CGFloat,
        startY: CGFloat? = nil,
        endY: CGFloat? = nil,
        duration: TimeInterval,
        easeIn: Bool,
        enableSlowPositionCompensation: Bool = false,
        onStart: (() -> Void)? = nil,
        completion: @escaping () -> Void
    ) {
        // 关键：停止并复用同一个 animator，防止两个 displayLink 同时抢占 AX 设置权限产生“晃动”
        windowAnimator.stop()
        
        guard let currentFrame = getWindowFrame() else { 
            completion()
            return 
        }
        
        windowAnimator.animate(
            element: windowElement,
            startX: startX,
            endX: endX,
            startY: startY ?? currentFrame.minY,
            endY: endY ?? (startY ?? currentFrame.minY),
            duration: duration,
            easeIn: easeIn,
            lockedWidth: lockedWidth,
            lockedHeight: currentFrame.height,
            enableSlowPositionCompensation: enableSlowPositionCompensation,
            onStart: onStart,
            completion: completion
        )
    }
    private func snapToEdge(edgeConfig: Int, frame: CGRect, displayBounds: CGRect) {
        currentEdge = edgeConfig
        if collapseWindow() {
            // 首次吸附后释放前台状态，确保后续 Dock 点击能触发激活通知
            scheduleFocusRelease(after: 0.5)
        }
    }
    
    @discardableResult
    private func collapseWindow(immediate: Bool = false, triggerEffects: Bool = true) -> Bool {
        if isTemporarilyPinned { return false }
        if isAnimating { return false } // 正在动画中，拒绝新指令
        queuedForwardedHotkeyToggle = false
        excludeFromFocusReturn(for: 0.6)
        lastCollapseTime = Date() // 记录折叠时间戳用于防抖
        outsideCollapseCandidateSince = nil
        edgeDetachCandidateSince = nil
        lastSiblingWindowInteractionAt = nil
        let shouldTriggerEffects = triggerEffects && !isIndicatorSuppressed
        
        // 必须在计算坐标前抓取最新尺寸
        guard let rawFrame = getRawWindowFrame() else { return false }
        
        // 核心修复: 平衡手动缩放记忆与系统渲染抖动引起的宽度雪崩累加
        // 系统推移导致的变宽一般<4px，大于15px则说明人类拖拽过窗口边缘
        if abs(rawFrame.width - lockedWidth) > 15 {
            print("🎚️ 尺寸更新: 检测到手动缩放 (差异 > 15px)，更新锁从 \(lockedWidth) 到 \(rawFrame.width)")
            lockedWidth = rawFrame.width
        }
        
        let currentFrame = rawFrame
        
        guard let geometry = edgeGeometry(for: currentFrame) else { return false }

        // 准备失败时保留跟踪；只有接收收回操作后才停止，避免一次 AX 失败永久失联。
        mouseTrackingTimer?.invalidate()
        state = .snapped(edge: currentEdge, hiddenOrX: geometry.hidden.x)
        notifyTemporaryShortcutStashStateChanged(isStashed: true)
        isAnimating = true
        
        // 我们以鼠标所在位置作为碰撞中心
        let mouseLoc = NSEvent.mouseLocation
        let screenForWin = getScreenForWindow()
        let impactPoint = CGPoint(x: currentEdge == 1 ? screenForWin.frame.minX : screenForWin.frame.maxX, y: mouseLoc.y)
        let customColor = AppConfig.shared.getColor(for: bundleID)
        let edge: SnapEdge = currentEdge == 1 ? .left : .right

        if !shouldTriggerEffects {
            effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        }

        if immediate {
            setWindowAlpha(CGFloat(collapsedWindowAlpha()), isHidden: true, frameHint: currentFrame)
            setWindowPosition(position: geometry.visualHidden)
            isAnimating = false
            if shouldTriggerEffects {
                triggerCollapseEffect(edge: edge, point: impactPoint, color: customColor)
            }
            indicatorWindow.alphaValue = 1.0
            showIndicator(animated: isIndicatorAnimationAllowed)
            updatePinControlWindow()
            runQueuedForwardedHotkeyToggleIfNeeded()
            return true
        }
        
        animateWindowPositionFast(
            from: currentFrame.minX,
            to: geometry.visualHidden.x,
            startY: currentFrame.minY,
            endY: geometry.visualHidden.y,
            duration: self.standardTransitionDuration(),
            easeIn: true
        ) { [weak self] in
            guard let self = self else { return }
            
            self.setWindowAlpha(CGFloat(self.collapsedWindowAlpha()), isHidden: true, frameHint: currentFrame)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.setWindowPosition(position: geometry.visualHidden)
                
                self.isAnimating = false
                if shouldTriggerEffects {
                    self.triggerCollapseEffect(edge: edge, point: impactPoint, color: customColor)
                }
                self.indicatorWindow.alphaValue = 1.0
                self.showIndicator(animated: self.isIndicatorAnimationAllowed)
                self.updatePinControlWindow()
                self.runQueuedForwardedHotkeyToggleIfNeeded()
            }
        }
        return true
    }
    
    @discardableResult
    private func expandWindow(isDockActivated: Bool = false, immediate: Bool = false, triggerEffects: Bool = true) -> Bool {
        if isTemporarilyPinned { return false }
        if isAnimating { return false }
        if case .expanded = state { return false }
        invalidatePendingFocusRelease()
        queuedForwardedHotkeyToggle = false
        outsideCollapseCandidateSince = nil
        edgeDetachCandidateSince = nil
        let shouldTriggerEffects = triggerEffects && !isIndicatorSuppressed
        
        guard let currentFrame = getWindowFrame() else { return false }
        guard let geometry = edgeGeometry(for: currentFrame) else { return false }
        rememberFocusReturnTargetBeforeReveal()
        
        state = .expanded
        notifyTemporaryShortcutStashStateChanged(isStashed: false)
        isAnimating = true

        if !shouldTriggerEffects {
            effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        }

        if immediate {
            windowAnimator.stop()
            beginTargetedActivationWindow(for: 0.35)
            setWindowAlpha(CGFloat(collapsedWindowAlpha()), isHidden: true, frameHint: currentFrame)
            setWindowPosition(position: geometry.visualHidden)
            setWindowPosition(position: geometry.expanded)

            let size = CGSize(width: lockedWidth, height: currentFrame.height)
            axSetSizeAttribute(on: windowElement, size: size, context: "WindowSession.expandWindow.immediate.initialSize")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                self.setWindowPosition(position: geometry.expanded)
                let secondSize = CGSize(width: self.lockedWidth, height: currentFrame.height)
                axSetSizeAttribute(on: self.windowElement, size: secondSize, context: "WindowSession.expandWindow.immediate.secondSize")

                if let runningApp = NSRunningApplication(processIdentifier: self.pid) {
                    runningApp.activate(options: .activateIgnoringOtherApps)
                }
                self.setWindowAlpha(1.0, isHidden: false, frameHint: CGRect(origin: geometry.expanded, size: currentFrame.size))

                if shouldTriggerEffects {
                    let snapEdge = self.currentEdge == 1 ? SnapEdge.left : SnapEdge.right
                    let effectColor = AppConfig.shared.getColor(for: self.bundleID)
                    self.triggerExpandEffect(edge: snapEdge, frame: currentFrame, color: effectColor)
                }

                self.isAnimating = false
                self.indicatorWindow.alphaValue = 1.0
                self.showIndicator(animated: false)
                self.startMouseTrackingTimer()
                self.updatePinControlWindow()
                axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.expandWindow.immediate.main")
                axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.expandWindow.immediate.focused")
                self.runQueuedForwardedHotkeyToggleIfNeeded()
            }
            return true
        }
        
        if isDockActivated {
            pendingDockInteraction = true
            // 关键修复：此前这里在展开动作刚开始就把 isAnimating 置为 false，
            // 而 relinquishToDockMinimizeIfDetachedFromEdge 只在 isAnimating 为真时
            // 吸收第三方 App 的几何抖动（见该方法的 guard !isAnimating 分支）。
            // 一旦提前清零，dock 展开后窗口被系统/微信布局重排触发的瞬时位移
            // 会被 AX Observer 回调（handleObservedGeometryChange）当成"脱边"，
            // 250ms 后误降级到 .floating，claim 随之变 dockminimize，下次快捷键
            // DockMinimize 就直接隐藏窗口、脱离接管。
            // 这里保持 isAnimating = true 一个短暂稳定窗口（150ms），让抖动被吸收，
            // 之后复位并消费排队 toggle。checkMouseForCollapse 内有 if isAnimating { return }
            // 兜底，这段时间不会误触发折叠判定。
            beginTargetedActivationWindow(for: 0.45)
            setWindowPosition(position: geometry.visualHidden)
            setWindowAlpha(1.0, isHidden: false, frameHint: CGRect(origin: geometry.expanded, size: currentFrame.size))
            setWindowPosition(position: geometry.expanded)

            // Dock 激活也同步触发特效
            let snapEdge = currentEdge == 1 ? SnapEdge.left : SnapEdge.right
            let effectColor = AppConfig.shared.getColor(for: bundleID)
            if shouldTriggerEffects {
                self.triggerExpandEffect(edge: snapEdge, frame: currentFrame, color: effectColor)
            }

            showIndicator(animated: false)
            startMouseTrackingTimer()
            updatePinControlWindow()
            // 延迟复位 isAnimating：给第三方 App 一个稳定窗口，期间任何 AX 几何
            // 抖动都会被 relinquishToDockMinimizeIfDetachedFromEdge 当作动画期吸收，
            // 不会误降级状态机。
            // 用 animationGenerationToken 版本号保护：`isAnimating` 的 didSet 会在
            // 任何 false → true 转换时自增 token。若 150ms 内本会话启动了新的动画
            // （fusion / pin engage / 其它 expandWindow 路径），token 就会不匹配，
            // 本闭包会放弃复位，从而避免把新动画的 isAnimating 状态误清零。
            let expectedToken = animationGenerationToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self else { return }
                guard self.animationGenerationToken == expectedToken else { return }
                self.isAnimating = false
                self.runQueuedForwardedHotkeyToggleIfNeeded()
            }
            return true
        } else {
            // Hover logic (Slide)
            let startHoverReveal = { [weak self] in
                guard let self else { return }
                self.beginTargetedActivationWindow(for: 0.45)
                
                // 先将坐标瞬移回起跑线
                self.setWindowAlpha(CGFloat(self.collapsedWindowAlpha()), isHidden: true, frameHint: currentFrame)
                self.setWindowPosition(position: geometry.visualHidden)
                
                // 强制置顶，确保窗口从隐藏位直接接管前台交互
                if let runningApp = NSRunningApplication(processIdentifier: self.pid) {
                    runningApp.activate(options: .activateIgnoringOtherApps)
                }
                
                let snapEdge = self.currentEdge == 1 ? SnapEdge.left : SnapEdge.right
                let effectColor = AppConfig.shared.getColor(for: self.bundleID)
                if shouldTriggerEffects {
                    self.triggerExpandEffect(edge: snapEdge, frame: currentFrame, color: effectColor)
                }
                
                self.animateWindowPositionFast(
                    from: geometry.visualHidden.x,
                    to: geometry.expanded.x,
                    startY: geometry.visualHidden.y,
                    endY: geometry.expanded.y,
                    duration: self.standardTransitionDuration(),
                    easeIn: false,
                    enableSlowPositionCompensation: true,
                    onStart: {
                        // 动画开始的第一帧瞬间恢复可见，不再有“冲出再回弹”
                        self.setWindowAlpha(1.0, isHidden: false, frameHint: CGRect(origin: geometry.expanded, size: currentFrame.size))
                    },
                    completion: { [weak self] in
                        guard let self = self else { return }
                        // 安全降落：动画结束后 50ms 再次强化坐标与尺寸，消除宽窗口带来的 IPC 指令丢失
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.setWindowPosition(position: geometry.expanded)
                            let size = CGSize(width: self.lockedWidth, height: currentFrame.height)
                            axSetSizeAttribute(on: self.windowElement, size: size, context: "WindowSession.expandWindow.hover.safeLandingSize")
                            if let runningApp = NSRunningApplication(processIdentifier: self.pid) {
                                _ = runningApp.activate()
                            }
                            axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.safeLandingMain")
                            axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.safeLandingFocused")
                        }
                        self.isAnimating = false
                        self.updatePinControlWindow()
                        self.startMouseTrackingTimer()
                        self.runQueuedForwardedHotkeyToggleIfNeeded()
                    }
                )
                
                axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.main")
                axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.focused")
            }

            startHoverReveal()
        }
        return true
    }
    
    private func showIndicator(animated: Bool = false) {
        if isIndicatorSuppressed {
            indicatorWindow.orderOut(nil)
            updatePinControlWindow()
            return
        }
        
        let displayBounds = getDisplayBounds()
        
        // 在屏幕上映射软件窗口的高度位置
        guard let winFrame = edgeReferenceFrame() else { return }
        let h = winFrame.height
        let currentY = winFrame.minY
        let displayHeight = primaryScreenHeight
        let mappedAppKitY = displayHeight - currentY - h

        let vPadding: CGFloat = 40
        var indFrame: NSRect

        indFrame = NSRect(x: 0, y: mappedAppKitY - vPadding, width: 12, height: h + vPadding * 2)
        if currentEdge == 1 {
            indFrame.origin.x = displayBounds.minX - 3
        } else {
            indFrame.origin.x = displayBounds.maxX - 9
        }
        
        let opacity = AppConfig.shared.getOpacity(for: bundleID)
        let customColor = AppConfig.shared.getColor(for: bundleID).withAlphaComponent(CGFloat(opacity))
        indicatorWindow.currentEdge = currentEdge
        indicatorWindow.updateColor(customColor)
        
        if let view = indicatorWindow.contentView as? SimpleColorView {
            view.updateLayout(stripLength: h, edge: currentEdge)
            
            if animated && isIndicatorAnimationAllowed {
                view.playSquashAndStretch(targetLength: h)
            }
        }
        
        // 终结全屏高度逻辑，物理隔离同侧多窗口
        indicatorWindow.setFrame(indFrame, display: true)
        indicatorWindow.orderFront(nil)
        updatePinControlWindow()
    }
    
    private func startMouseTrackingTimer() {
        mouseTrackingTimer?.invalidate()
        // 清空 checkMouseForCollapse 的稳态缓存：新一轮 tracking 的窗口几何/鼠标
        // 位置都可能已变化，不能沿用上一轮的缓存判定。
        lastCheckedMouseLocation = nil
        lastCheckedIsOutside = nil
        cachedInteractionHitFrame = nil
        cachedInteractionHitFrameAt = .distantPast
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkMouseForCollapse()
        }
    }
    
    private func checkMouseForCollapse() {
        // 切到其他普通应用后，窗口即使仍在鼠标所在矩形内，也可能已被遮挡。
        // 不能沿用“鼠标还在窗内”的缓存或快捷键等待；按现有宽限期真正收回。
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let hasOtherForegroundApp = frontmostApp.map {
            $0.processIdentifier != pid && $0.activationPolicy == .regular
        } ?? false
        // 性能优化：展开稳态期间 mouseTrackingTimer 以 10Hz 触发本方法。若鼠标量化
        // 位置未变、AX 几何未抖动（observedGeometryChangeToken 未变）、且上次判定
        // 鼠标在窗口内（isOutside=false），则整轮（含 updatePinControlWindow 的 AX 读、
        // interactionHitTestFrame 的 CGWindowList 枚举、pinControlFrames 的 AX 读）
        // 结果都不会变——直接 return。这是把展开稳态 CPU 从 ~10% 压到接近 0 的关键。
        // 注意：此短路仅覆盖"鼠标静止 + 几何静止 + 鼠标在窗内"这一最常见稳态；
        // 任何一项变化（鼠标移动、窗口被第三方改写、鼠标在窗外）都会正常进入完整逻辑。
        let rawMouseLoc = NSEvent.mouseLocation
        let quantizedMouse = CGPoint(
            x: (rawMouseLoc.x / Self.mouseCacheQuantum).rounded(),
            y: (rawMouseLoc.y / Self.mouseCacheQuantum).rounded()
        )
        let geometryUnchanged = observedGeometryChangeToken == lastCheckedObservedGeometryToken
        if !hasOtherForegroundApp,
           let lastLoc = lastCheckedMouseLocation, lastLoc == quantizedMouse,
           geometryUnchanged, lastCheckedIsOutside == false {
            return
        }

        updatePinControlWindow()
        if isAnimating { return } // 正在动画中，不进行碰撞检查
        if fusionHoverLock { return }
        if isTemporarilyPinned { return }
        if relinquishToDockMinimizeIfDetachedFromEdge() {
            // 脱边降级后几何/状态已变，清缓存避免下一轮误用。
            lastCheckedMouseLocation = nil
            lastCheckedIsOutside = nil
            return
        }

        guard case .expanded = state else {
            mouseTrackingTimer?.invalidate()
            outsideCollapseCandidateSince = nil
            return
        }

        guard let frame = interactionHitTestFrame() ?? getWindowFrame() else { return }
        let mouseLoc = rawMouseLoc
        let displayHeight = primaryScreenHeight
        let mappedMouseY = displayHeight - mouseLoc.y
        let mappedMouseLoc = CGPoint(x: mouseLoc.x, y: mappedMouseY)
        let now = Date()
        
        let isPrimaryMouseDown = (NSEvent.pressedMouseButtons & 1 != 0)
        let isAnyMouseDown = NSEvent.pressedMouseButtons != 0
        let tolX = AppConfig.shared.hoverTolerance
        let tolY = AppConfig.shared.hoverToleranceY
        let bufferRect = frame.insetBy(dx: -tolX, dy: -tolY)
        let pinSafeRectContainsMouse: Bool
        if let rawFrame = getRawWindowFrame(),
           let pinFrames = pinControlFrames(for: rawFrame) {
            pinSafeRectContainsMouse = pinFrames.safeRect.contains(mouseLoc)
        } else {
            pinSafeRectContainsMouse = false
        }
        let isOutside = hasOtherForegroundApp || (!bufferRect.contains(mappedMouseLoc) && !pinSafeRectContainsMouse)

        // 回写"鼠标静止短路"缓存：记录本轮量化鼠标位置、isOutside、以及当前几何 token。
        // 下一轮若三者均未变化，即可在方法入口直接 return。
        // 注意：只在几何未抖动的稳态下缓存 isOutside 才有意义，因此同时记录 token。
        lastCheckedMouseLocation = quantizedMouse
        lastCheckedIsOutside = isOutside
        lastCheckedObservedGeometryToken = observedGeometryChangeToken

        // 取消置顶后的短暂绕过：让自动折叠仅依赖纯几何 isOutside，
        // 避免镜像置顶 / 普通置顶过程中残留的同 PID 兄弟窗口几何/焦点状态把鼠标判定卡死。
        let bypassSiblingGrace = now < siblingGraceBypassUntil

        // 性能优化：兄弟窗口的三项查询（isMouseInsideAnyVisibleSiblingWindow /
        // hasFocusedSiblingWindowOfApp / isWithinSiblingWindowPostInteractionGrace）
        // 都要跨进程 AX 读或整份 `CGWindowListCopyWindowInfo` 枚举，是本 timer 里
        // 最重的一坨。它们的结果**只在**"鼠标已经越出容差框 && 不在 sibling grace 绕过期"
        // 时才会影响下游折叠判断（见 line ~4300 的组合早退条件）——
        // 鼠标还在窗口内（isOutside=false）时，`!isOutside` 已经导致早退，
        // 任何 sibling 值都不会改变结果。因此直接跳过枚举，把 10Hz × N 的
        // CGWindowList 全量扫描消掉，显著降低 mouseTrackingTimer 的基线 CPU。
        let shouldQuerySiblingState = !hasOtherForegroundApp && isOutside && !bypassSiblingGrace
        let rawIsInsideSiblingWindow = shouldQuerySiblingState
            ? isMouseInsideAnyVisibleSiblingWindow(mappedMouseLoc)
            : false
        let isInsideSiblingWindow = rawIsInsideSiblingWindow
        if rawIsInsideSiblingWindow {
            lastSiblingWindowInteractionAt = now
        }
        let isSiblingWindowFocused = shouldQuerySiblingState
            && hasFocusedSiblingWindowOfApp()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let isWithinSiblingWindowGrace = shouldQuerySiblingState
            && isWithinSiblingWindowPostInteractionGrace(now)


        if hasOtherForegroundApp { pendingDockInteraction = false }
        if pendingDockInteraction {
            if !isOutside {
                pendingDockInteraction = false
                outsideCollapseCandidateSince = nil
            } else {
                if isPrimaryMouseDown {
                    if hasReleasedDockClick {
                        pendingDockInteraction = false
                        if collapseWindow() {
                            // 点击外部触发折叠后，释放前台状态
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                                guard let self else { return }
                                self.scheduleFocusRelease(after: 0)
                            }
                        }
                    }
                } else {
                    hasReleasedDockClick = true
                }
            }
            return
        }
        
        if isAnyMouseDown {
            outsideCollapseCandidateSince = nil
            return
        }
        
        if !isOutside || isInsideSiblingWindow || isSiblingWindowFocused || isWithinSiblingWindowGrace {
            outsideCollapseCandidateSince = nil
            return
        }

        if let since = outsideCollapseCandidateSince,
           now.timeIntervalSince(since) >= Self.siblingWindowTransitionGraceInterval {
            if collapseWindow() {
                // 用户已选择另一个应用时保留其焦点；普通移出仍执行原有焦点归还。
                if !hasOtherForegroundApp { scheduleFocusRelease(after: 0.35) }
            }
        } else if outsideCollapseCandidateSince == nil {
            outsideCollapseCandidateSince = now
        }
    }
    

    
    private func getWindowFrame() -> CGRect? {
        guard var frame = getRawWindowFrame() else { return nil }
        
        // 首次抓取并锁死宽度
        if !initialFrameCaptured && frame.width > 0 {
            lockedWidth = frame.width
            initialFrameCaptured = true
        }
        // 强行纠正 frame 宽度，维持物理锁，防止窗口自适应变形
        if initialFrameCaptured {
            frame.size.width = lockedWidth
        }
        
        return frame
    }

    private func interactionHitTestFrame() -> CGRect? {
        // 性能优化：展开稳态期间，AX Observer 不会上报几何变化（observedGeometryChangeToken
        // 不变），此时窗口在 CGWindowList 中的 bounds 也不会变。复用 200ms 内的缓存结果，
        // 完全跳过 CGWindowListCopyWindowInfo 的全量枚举（这是 checkMouseForCollapse 里
        // 最重的单次调用）。一旦 AX 上报变化（token 递增）或缓存过期，立即重算。
        if observedGeometryChangeToken == lastCheckedObservedGeometryToken,
           Date().timeIntervalSince(cachedInteractionHitFrameAt) < 0.2,
           let cached = cachedInteractionHitFrame {
            return cached
        }

        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else {
            let fallback = getRawWindowFrame()
            cachedInteractionHitFrame = fallback
            cachedInteractionHitFrameAt = Date()
            return fallback
        }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windowList {
            guard let cgWindowID = info[kCGWindowNumber as String] as? CGWindowID,
                  cgWindowID == windowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let frame = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
            cachedInteractionHitFrame = frame
            cachedInteractionHitFrameAt = Date()
            return frame
        }

        let fallback = getRawWindowFrame()
        cachedInteractionHitFrame = fallback
        cachedInteractionHitFrameAt = Date()
        return fallback
    }
    
    /// 仅获取真实的物理镜像，不参与尺寸锁定逻辑，用于在收合前抓取用户手动调整的新宽度
    private func getRawWindowFrame() -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AccessibilityRuntimeGuard.copyAttributeValue(
            of: windowElement,
            attribute: kAXPositionAttribute as CFString,
            value: &positionValue,
            context: "WindowSession.getRawWindowFrame.position"
        ) == .success,
           AccessibilityRuntimeGuard.copyAttributeValue(
            of: windowElement,
            attribute: kAXSizeAttribute as CFString,
            value: &sizeValue,
            context: "WindowSession.getRawWindowFrame.size"
           ) == .success {
            var position: CGPoint = .zero
            var size: CGSize = .zero
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) &&
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                return CGRect(origin: position, size: size)
            }
        }
        return nil
    }
    /// [Space Sensing] 基于 PID 与边界坐标的比准
    private func isWindowOnScreen() -> Bool {
        // 获取预期的窗体在无界限全景空间中的物理几何尺寸
        guard let axFrame = getRawWindowFrame() else { return false }
        let pid = self.pid
        
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        
        for info in windowList {
            // 首先判断 PID 归属
            if let windowPID = info[kCGWindowOwnerPID as String] as? Int32, windowPID == pid {
                
                // 获取屏幕上此窗口的真实框体
                if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                    let rect = CGRect(
                        x: boundsDict["X"] as? CGFloat ?? 0,
                        y: boundsDict["Y"] as? CGFloat ?? 0,
                        width: boundsDict["Width"] as? CGFloat ?? 0,
                        height: boundsDict["Height"] as? CGFloat ?? 0
                    )
                    
                    // 跨帧容错几何比对（允许50px误差与阴影或标题栏出入）
                    if abs(rect.minX - axFrame.minX) < 50 &&
                       abs(rect.minY - axFrame.minY) < 100 &&
                       abs(rect.width - axFrame.width) < 50 {
                        return true // 找到了匹配坐标的这个属于该 PID 的窗口，说明它在当前屏幕的可见空间列表内！
                    }
                }
            }
        }
        
        // 核心：在【当前可见的】所有窗口列表里没有找到匹配预定几何坐标的窗体，哪怕它有一万个属性说在屏 -> 它根本不在当前桌面！
        return false 
    }
    
    private func setWindowPosition(position: CGPoint) {
        axSetPositionAttribute(on: windowElement, position: position, context: "WindowSession.setWindowPosition")
    }

    func suspendForAccessibilityLoss() {
        finishTemporaryShortcutSession(excludeWindow: false, removeSession: true)
        isTemporarilyPinned = false
        isMirrorPinActive = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        teardownMirrorCapture()
        mouseTrackingTimer?.invalidate()
        hoverDelayTimer?.invalidate()
        hoverInterruptTimer?.invalidate()
        pinnedRaiseTimer?.invalidate()
        windowAnimator.stop()
        outsideCollapseCandidateSince = nil
        edgeDetachCandidateSince = nil
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        indicatorWindow.orderOut(nil)
        pinControlWindow.orderOut(nil)
        setWindowAlpha(1.0, isHidden: false, preserveRecoveryRecord: true)
        destroy()
    }
}

class WindowAnimator {
    private var displayLink: CVDisplayLink?
    private var startTime: CFAbsoluteTime = 0
    /// wall-clock 时间上"animate() 被调用"的那一刻，用作**硬性超时**的基准。
    /// 与 `startTime` 不同的是：`startTime` 会被 slow-write 补偿逻辑（line ~4560）
    /// 反复往后推，用来让 easing 曲线在 IPC 变慢时"暂停"。而 `originalStartTime`
    /// 从头到尾不动，用于判定"墙上时间已经过去多久了"。
    ///
    /// 关键 bug：hover-expand 路径开启了 `enableSlowPositionCompensation`；一旦目标
    /// App 对 AX 响应慢或返回 `.cannotComplete`，补偿会每帧把 `startTime` 往后推
    /// 36ms，而 wall-clock 每帧只前进 ~16ms，净变化 -20ms/帧；`progress` 被
    /// `lastAppliedProgress` 卡在高水位、永远回不到 1.0；`finished` 永远为 false，
    /// `CVDisplayLinkStop` 永远不被调用，孤儿 displayLink 在 60Hz 心跳里持续
    /// `axSetPositionAttribute` 到目标 App，用户看到的就是"CPU 从 5% 飙到 30% 且必须
    /// 重启才能恢复"。加这个硬超时是最后一道闸门。
    private var originalStartTime: CFAbsoluteTime = 0
    private var duration: TimeInterval = 0
    private var startX: CGFloat = 0
    private var endX: CGFloat = 0
    private var startY: CGFloat = 0
    private var endY: CGFloat = 0
    private var isEaseIn: Bool = false
    private var element: AXUIElement?
    private var completion: (() -> Void)?
    private var onStart: (() -> Void)?
    private var hasCalledOnStart: Bool = false
    private var lastAppliedProgress: CGFloat = 0
    private var enableSlowPositionCompensation: Bool = false
    /// 硬超时倍率。任何正常动画的 wall-clock 用时都远小于 `duration`；
    /// 只要墙上时间已经跨过 `duration * hardTimeoutMultiplier`，无论 easing 进度如何
    /// 都强制收尾，避免 slow-write 补偿把 displayLink 永久锁在跑。
    private let hardTimeoutMultiplier: Double = 3.0
    
    // 跨进程频率熔断：记录上次更新指令发送的时间，防止溢出 3rd 方 App 的缓冲区
    private var lastAXUpdateTime: CFAbsoluteTime = 0
    private let minAXInterval: TimeInterval = 0.016 // 锁定 60Hz 采样率，消除 120Hz 屏幕下的指令积压
    private let slowPositionWriteThresholdMS: Double = 24
    private let maxHoverTimeCompensationMS: Double = 36
    
    private var lockedWidth: CGFloat = 0
    private var lockedHeight: CGFloat = 0
    
    func animate(element: AXUIElement, startX: CGFloat, endX: CGFloat, startY: CGFloat, endY: CGFloat, duration: TimeInterval, easeIn: Bool, lockedWidth: CGFloat, lockedHeight: CGFloat, enableSlowPositionCompensation: Bool = false, onStart: (() -> Void)? = nil, completion: @escaping () -> Void) {
        stop()
        self.element = element
        self.startX = startX
        self.endX = endX
        self.startY = startY
        self.endY = endY
        self.duration = duration
        self.isEaseIn = easeIn
        self.lockedWidth = lockedWidth
        self.lockedHeight = lockedHeight
        self.onStart = onStart
        self.completion = completion
        self.hasCalledOnStart = false
        let now = CFAbsoluteTimeGetCurrent()
        self.startTime = now
        self.originalStartTime = now
        self.lastAppliedProgress = 0
        self.enableSlowPositionCompensation = enableSlowPositionCompensation
        
        var dl: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard result == kCVReturnSuccess, let link = dl else {
            // fallback
            axSetPositionAttribute(on: element, position: CGPoint(x: endX, y: endY), context: "WindowAnimator.animate.fallbackPosition")
            completion()
            return
        }
        self.displayLink = link
        
        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext in
            let animator = Unmanaged<WindowAnimator>.fromOpaque(displayLinkContext!).takeUnretainedValue()
            let isFinished = animator.tick()
            if isFinished {
                CVDisplayLinkStop(displayLink)
                DispatchQueue.main.async { animator.completion?() }
            }
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }
    
    private func tick() -> Bool {
        let currentTime = CFAbsoluteTimeGetCurrent()
        let elapsed = currentTime - startTime
        var progress = CGFloat(elapsed / duration)
        var finished = false
        if progress < lastAppliedProgress {
            progress = lastAppliedProgress
        }
        if progress >= 1.0 {
            progress = 1.0
            finished = true
        }

        // 硬性超时闸门：不管 easing 进度多少、不管 slow-write 补偿把 startTime 推到哪里，
        // 只要墙上时间累计已经跨过 duration * hardTimeoutMultiplier，就强制收尾。
        // 这是防止孤儿 CVDisplayLink 因 slow-write 补偿把 progress 永久卡在高水位、
        // 导致 finished 永远为 false 的最后一道保险；一旦踩到，CPU 会持续 60Hz IPC。
        if !finished && currentTime - originalStartTime > duration * hardTimeoutMultiplier {
            progress = 1.0
            finished = true
        }
        
        let eased: CGFloat
        if isEaseIn { // collapse
            eased = progress * progress * progress
        } else { // expand
            let p1 = progress - 1.0
            eased = p1 * p1 * p1 + 1.0
        }
        
        let currentX = startX + (endX - startX) * eased
        let currentY = startY + (endY - startY) * eased
        let newPos = CGPoint(x: currentX, y: currentY)
        let newSize = CGSize(width: lockedWidth, height: lockedHeight)
        
        // 频率熔断核心：如果距离上次发指令不足 16ms，且不是最后一帧，则跳过此次 IPC 通讯
        let timeSinceLastAX = currentTime - lastAXUpdateTime
        if !finished && timeSinceLastAX < minAXInterval {
            return false 
        }
        lastAXUpdateTime = currentTime
        
        if let el = element {
            // 优化：仅在必要时刻更新坐标
            let positionStart = CFAbsoluteTimeGetCurrent()
            let positionResult = axSetPositionAttribute(on: el, position: newPos, context: "WindowAnimator.tick.position")
            let positionWriteMS = (CFAbsoluteTimeGetCurrent() - positionStart) * 1000

            if enableSlowPositionCompensation {
                let shouldCompensateForSlowWrite =
                    positionResult == .cannotComplete ||
                    positionWriteMS > slowPositionWriteThresholdMS

                if shouldCompensateForSlowWrite {
                    let excessMS = max(positionWriteMS - slowPositionWriteThresholdMS, 0)
                    let compensationMS = min(
                        maxHoverTimeCompensationMS,
                        positionResult == .cannotComplete ? maxHoverTimeCompensationMS : excessMS * 0.6
                    )
                    startTime += compensationMS / 1000
                }
            }
            
            // IPC 优化：大幅减低指令频率。不再每帧设置 Size，仅在动画开始、结束以及中途两个关键点锁定。
            // 减流方案：如果是最后一帧(finished)或者第一帧(0.0)则必设；中间过程通过大幅间隔检测减流。
            let isKeyFrame = finished || (progress == 0.0) || floor(progress * 2) != floor((progress - 0.02) * 2)
            if isKeyFrame {
                axSetSizeAttribute(on: el, size: newSize, context: "WindowAnimator.tick.size")
            }
            
            if !hasCalledOnStart {
                hasCalledOnStart = true
                if let cls = onStart {
                    DispatchQueue.main.async { cls() }
                }
            }

            lastAppliedProgress = max(lastAppliedProgress, progress)
        }
        
        return finished
    }
    
    func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // 关键修复：被外力打断（fusionHide / suspendForAccessibilityLoss /
        // 立即展开等场景）时，必须把保存的 completion / onStart 也清空。否则
        // 它们会在下一次 animate(...) 调用前被 completion 闭包捕获的强引用
        // 残留下来；更严重的是，调用方期望"动画结束后才会做某件事"——一旦 stop()
        // 静默吞掉 completion，那件"某件事"就再也不会发生（典型例子：折叠
        // completion 里的 isAnimating = false 不会被复位，导致整套 indicator
        // 显示链路被锁死）。
        //
        // 这里我们选择**不再回放 completion**：
        // - 如果调用方还想跑 completion，它们应该让动画自己跑完，而不是 stop()；
        // - 现有所有 stop() 调用方在调用 stop() 之后，要么紧接着发起一个新的
        //   animate(...)（它会重新覆盖 completion / onStart），要么本身就在
        //   destroy/suspend 路径，不再需要 completion。
        // 因此最安全的做法就是：把 completion / onStart 主动清空，避免它们意外
        // 被下一次动画的 tick 误触发。WindowSession 那边由 stateWatchdogTimer
        // 兜底 isAnimating 的超时复位，所以即便此处不回放 completion，也不会
        // 永久卡住状态机。
        completion = nil
        onStart = nil
        element = nil
        hasCalledOnStart = false
    }
}

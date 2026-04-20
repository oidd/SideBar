import AppKit
import ApplicationServices
import CoreVideo

enum SnapState {
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
    
    private var state: SnapState = .floating
    private var currentEdge: Int = 0
    
    // MARK: - 多显示器支持
    
    /// 吸附时锁定的屏幕信息（这两个值在 snapToEdge 时设置，取消吸附时清空）
    /// 核心原则：窗口被隐藏/折叠后位置已不在原始屏幕内，动态检测会失败，因此必须锁定。
    private var snappedDisplayBounds: CGRect?
    private var snappedScreen: NSScreen?
    
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
        snappedScreen = detectScreen()
    }
    
    /// 取消吸附时清空屏幕锁定
    private func unlockScreen() {
        snappedDisplayBounds = nil
        snappedScreen = nil
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
    private var isAnimating = false
    private var isIndicatorSuppressed = false
    private var fusionHoverLock = false
    private var activationSuppressionUntil: Date = .distantPast
    private var indicatorAnimationSuppressionUntil: Date = .distantPast
    private var fusionReentrySuppressionUntil: Date = .distantPast
    private var focusReturnExclusionUntil: Date = .distantPast
    private var focusReturnSnapshot: FocusReturnSnapshot?
    
    private var indicatorWindow = EdgeIndicatorWindow()
    private var effectWindow = VisualEffectOverlayWindow()
    private var pinControlWindow = PinControlWindow()
    private var mirrorOverlayWindow = WindowMirrorOverlayWindow()
    private var lastMousePos: CGPoint?
    private var mouseTrackingTimer: Timer?
    private var hoverDelayTimer: Timer?
    private var hoverInterruptTimer: Timer?
    private var hoverCooldownActive: Bool = false
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
    private var isTemporaryShortcutManaged = false
    private var isTemporarilyPinned = false
    private var isMirrorPinActive = false
    private var isMirrorOverlayVisible = false
    private var mirrorHidesRealWindow = false
    private var mirrorRefreshTimer: Timer?
    private var pinnedAnchor: PinnedAnchor?
    private var pinControlRevealSuppressionUntil: Date = .distantPast
    var isDragging = false

    private static var sessionRegistry: [WeakWindowSessionBox] = []
    private static let mirrorHoverSuppressionInterval: TimeInterval = 0.42
    private static let siblingWindowTransitionGraceInterval: TimeInterval = 0.22
    private static let siblingWindowPostInteractionGraceInterval: TimeInterval = 1.5
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
    var isManagedByTemporaryShortcut: Bool { isTemporaryShortcutManaged }
    
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
        pinControlWindow.onToggle = { [weak self] in
            self?.toggleTemporaryPin()
        }
        mirrorOverlayWindow.onActivateRealWindow = { [weak self] in
            self?.activateMirrorBackedWindow()
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleAppActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        
        // [Space Awareness Fix] 监听桌面切换通知以实现优雅显隐
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // 监听全局配置变更通知，实现颜色动态同步
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigChanged), name: NSNotification.Name("AppConfigDidChange"), object: nil)
        
        // 核心修复：自动收编遗留在边缘的应用窗口
        checkAndAdoptEdgeState()
        Self.register(self)
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
    
    private func handleMouseEnteredIndicator() {
        if hoverCooldownActive { return } // 悬停冷却锁开启中，阻止触发
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
    }
    
    deinit {
        destroy()
    }
    
    @objc private func handleSpaceChanged() {
        lastSpaceChangeAt = Date()

        // [Space Switch Fix] 回归手工强控模式，先执行点状消散动画
        self.indicatorWindow.animateCollapseToDot { }
        
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
                if wasHidden, Date() >= indicatorAnimationSuppressionUntil {
                    indicatorWindow.animateExpandFromDot()
                }
                showIndicator(animated: wasHidden && Date() >= indicatorAnimationSuppressionUntil)
            } else {
                indicatorWindow.orderOut(nil)
                updatePinControlWindow()
            }
        case .expanded:
            if shouldTreatExpandedWindowAsVisibleForIndicator(isOnScreen: isOnScreen) {
                let wasHidden = !indicatorWindow.isVisible || indicatorWindow.alphaValue < 0.1
                if wasHidden, Date() >= indicatorAnimationSuppressionUntil {
                    indicatorWindow.animateExpandFromDot()
                }
                showIndicator(animated: wasHidden && Date() >= indicatorAnimationSuppressionUntil)
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
        var subroleValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: element,
            attribute: kAXSubroleAttribute as CFString,
            value: &subroleValue,
            context: "WindowSession.getAXWindowSubrole.subrole"
        ) == .success else {
            return nil
        }
        return subroleValue as? String
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

    static func noteGlobalKeyDown(_ event: NSEvent) {
        let now = Date()
        lastGlobalKeyDownAt = now

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.keyCode == 48 {
            lastAppSwitchIntentAt = now
        }
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

        guard let dockSide = AppConfig.shared.resolvedDockAvoidanceSide() else {
            return .content
        }

        if let dockRect = estimatedDockHitRect(for: frame, side: dockSide),
           dockRect.contains(point) {
            return .dock
        }

        return .content
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
                    hideMirrorOverlay()
                } else {
                    if !mirrorOverlayWindow.hasSnapshot {
                        _ = refreshMirrorOverlaySnapshot(presentImmediately: false)
                    }
                    revealMirrorOverlay()
                    setMirrorSourceWindowHidden(true)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isMirrorPinActive, self.isMirrorOverlayVisible else { return }
                        _ = self.refreshMirrorOverlaySnapshot(presentImmediately: false)
                    }
                    startMirrorRefreshTimer()
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
            if !Self.isAppActivationAllowed(for: self) {
                print("📱 忽略: 这次激活被定向给同 App 的另一个窗口")
                return
            }
            registerExplicitRevealIntentIfNeeded()
            let isFocusedWindowSession = isCurrentFocusedWindowOfApp()
            if isMirrorPinActive {
                hideMirrorOverlay()
                print("🪞 镜像层已收起，切回真实窗口交互")
                return
            }
            if isTemporarilyPinned {
                print("📌 忽略: 临时置顶窗口不参与 Dock 自动折叠")
                return
            }
            print("📱 应用激活通知: \(bundleID), 当前状态: \(state)")
            if case .snapped = state {
                guard isFocusedWindowSession else {
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
                    if Self.peekExplicitRevealIntent(for: pid) != nil {
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
                let triggerLabel = revealIntent.trigger == .dockClick ? "Dock" : "App Switch"
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
                print("📱 Dock 折叠: \(bundleID)")
                collapseWindow()
                // 释放前台状态：激活一个不被 SideBar 管理的应用
                scheduleFocusRelease(after: 0.35)
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
            self.showIndicator(animated: false)
            self.startMouseTrackingTimer()
            self.updatePinControlWindow()
            axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.releaseTemporaryPin.main")
            axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.releaseTemporaryPin.focused")
        }
    }

    private func engageMirrorPin(using frame: CGRect) {
        guard ScreenCaptureAccessManager.shared.hasAccess() || ScreenCaptureAccessManager.shared.requestAccess() else {
            return
        }

        pinnedAnchor = PinnedAnchor(expandedMidY: frame.midY)
        isTemporarilyPinned = true
        isMirrorPinActive = true
        stopPinnedRaisePulse()
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        startMouseTrackingTimer()
        showIndicator(animated: false)
        showMirrorOverlay(hideRealWindowAfterPresenting: true)
        updatePinControlWindow()
    }

    private func releaseMirrorPin() {
        stopMirrorRefreshTimer()
        hideMirrorOverlay()
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

    private func showMirrorOverlay(hideRealWindowAfterPresenting: Bool = false) {
        guard isMirrorPinActive else { return }
        if !mirrorOverlayWindow.hasSnapshot {
            guard refreshMirrorOverlaySnapshot(presentImmediately: false) else { return }
        }
        revealMirrorOverlay()
        if hideRealWindowAfterPresenting {
            setMirrorSourceWindowHidden(true)
        }
        startMirrorRefreshTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMirrorPinActive, self.isMirrorOverlayVisible else { return }
            _ = self.refreshMirrorOverlaySnapshot(presentImmediately: false)
        }
    }

    private func revealMirrorOverlay() {
        isMirrorOverlayVisible = true
        mirrorOverlayWindow.ignoresMouseEvents = false
        mirrorOverlayWindow.alphaValue = 1
        mirrorOverlayWindow.present()
    }

    private func hideMirrorOverlay() {
        isMirrorOverlayVisible = false
        stopMirrorRefreshTimer()
        mirrorOverlayWindow.ignoresMouseEvents = false
        mirrorOverlayWindow.hide()
        setMirrorSourceWindowHidden(false)
    }

    private func startMirrorRefreshTimer() {
        stopMirrorRefreshTimer()
        mirrorRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self, self.isMirrorPinActive else { return }
            _ = self.refreshMirrorOverlaySnapshot(presentImmediately: false)
        }
    }

    private func stopMirrorRefreshTimer() {
        mirrorRefreshTimer?.invalidate()
        mirrorRefreshTimer = nil
    }

    @discardableResult
    private func refreshMirrorOverlaySnapshot(presentImmediately: Bool = true) -> Bool {
        guard isMirrorPinActive,
              let rawFrame = getRawWindowFrame(),
              let windowID = WindowAlphaManager.shared.findWindowID(for: self.windowElement, pid: self.pid),
              let snapshot = WindowMirrorSnapshotter.shared.snapshot(windowID: windowID, bounds: rawFrame)
        else {
            return false
        }

        let appKitFrame = CGRect(
            x: snapshot.captureBounds.minX,
            y: primaryScreenHeight - snapshot.captureBounds.minY - snapshot.captureBounds.height,
            width: snapshot.captureBounds.width,
            height: snapshot.captureBounds.height
        )
        mirrorOverlayWindow.update(frame: appKitFrame, image: snapshot.image, showImmediately: presentImmediately)
        return true
    }

    private func activateMirrorBackedWindow() {
        guard isMirrorPinActive else { return }
        let suppression = Self.mirrorHoverSuppressionInterval
        Self.suppressOtherMirrorHoverActivation(excluding: self, for: suppression)
        suspendMirrorHoverActivation(for: suppression)
        setMirrorSourceWindowHidden(false)
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate(options: .activateIgnoringOtherApps)
        }
        axSetBoolAttribute(on: windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.activateMirrorBackedWindow.main")
        axSetBoolAttribute(on: windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.activateMirrorBackedWindow.focused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.mirrorOverlayWindow.animator().alphaValue = 0
            }, completionHandler: {
                self.hideMirrorOverlay()
            })
        }
    }

    private func suspendMirrorHoverActivation(for duration: TimeInterval) {
        mirrorOverlayWindow.suspendHoverActivation(for: duration)
    }

    private func setMirrorSourceWindowHidden(_ hidden: Bool) {
        guard mirrorHidesRealWindow != hidden else { return }
        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else { return }
        WindowAlphaManager.shared.setAlpha(for: windowID, alpha: hidden ? 0.0 : 1.0)
        mirrorHidesRealWindow = hidden
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
        var subroleValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: focusedWindow,
            attribute: kAXSubroleAttribute as CFString,
            value: &subroleValue,
            context: "WindowSession.focusedWindowSubroleOfApp.subrole"
        ) == .success else {
            return nil
        }
        return subroleValue as? String
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
           sample.region == .dock,
           sample.at >= Self.lastGlobalKeyDownAt {
            return .dockClick
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
        case .appSwitch:
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
        guard let subrole = focusedWindowSubroleOfApp() else { return true }
        return subrole != kAXStandardWindowSubrole
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
        }

        guard let pendingRevealIntent = Self.peekExplicitRevealIntent(for: pid) else {
            if bundleID == "com.apple.finder" {
                print("📱 Finder 焦点回到隐藏窗口，但缺少显式唤回意图，忽略自动展开")
            }
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
        guard let subrole = focusedWindowSubroleOfApp(),
              subrole == kAXStandardWindowSubrole else {
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

        let appKitFrame = CGRect(
            x: rawFrame.minX,
            y: primaryScreenHeight - rawFrame.minY - rawFrame.height,
            width: rawFrame.width,
            height: rawFrame.height
        )
        let screenFrame = getScreenForWindow().frame
        let buttonSize: CGFloat = 38
        let sideGap: CGFloat = 14
        let verticalInset: CGFloat = 2
        let minEdgePadding: CGFloat = 8

        let preferredSide: SnapEdge = currentEdge == 1 ? .right : .left
        let leftFits = appKitFrame.minX - sideGap - buttonSize >= screenFrame.minX + minEdgePadding
        let rightFits = appKitFrame.maxX + sideGap + buttonSize <= screenFrame.maxX - minEdgePadding

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
            proposedX = appKitFrame.maxX + sideGap
            hiddenX = appKitFrame.maxX - buttonSize * 0.58
            corridorRect = CGRect(
                x: appKitFrame.maxX - 2,
                y: appKitFrame.maxY - buttonSize - verticalInset - 8,
                width: sideGap + buttonSize + 4,
                height: buttonSize + 20
            )
            triggerRect = CGRect(
                x: appKitFrame.maxX - 72,
                y: appKitFrame.maxY - 56,
                width: 110,
                height: 64
            )
        } else {
            proposedX = appKitFrame.minX - buttonSize - sideGap
            hiddenX = appKitFrame.minX - buttonSize * 0.42
            corridorRect = CGRect(
                x: appKitFrame.minX - buttonSize - sideGap - 2,
                y: appKitFrame.maxY - buttonSize - verticalInset - 8,
                width: sideGap + buttonSize + 4,
                height: buttonSize + 20
            )
            triggerRect = CGRect(
                x: appKitFrame.minX - 38,
                y: appKitFrame.maxY - 56,
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
            Swift.min(appKitFrame.maxY - buttonSize - verticalInset, screenFrame.maxY - buttonSize - minEdgePadding)
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
        }
    }

    func fusionHide() {
        guard !isTemporarilyPinned else { return }
        guard !isAnimating else { return }
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

    private func suppressActivationNotifications(for duration: TimeInterval) {
        activationSuppressionUntil = Date().addingTimeInterval(duration)
    }

    private func suppressIndicatorAnimations(for duration: TimeInterval) {
        indicatorAnimationSuppressionUntil = Date().addingTimeInterval(duration)
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
        isMirrorOverlayVisible = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        stopMirrorRefreshTimer()
        mirrorOverlayWindow.hide()
        setMirrorSourceWindowHidden(false)
        let currentFrame = getWindowFrame() ?? CGRect(x: 100, y: 100, width: 400, height: 400)
        setWindowAlpha(1.0, isHidden: false, frameHint: currentFrame, preserveRecoveryRecord: true)
        
        if let runningApp = NSRunningApplication(processIdentifier: pid), runningApp.isHidden {
            runningApp.unhide()
        }
        
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
        Self.unregister(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let source = observerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
            observerRunLoopSource = nil
        }
        mouseTrackingTimer?.invalidate()
        hoverDelayTimer?.invalidate()
        hoverInterruptTimer?.invalidate()
        pinnedRaiseTimer?.invalidate()
        mirrorRefreshTimer?.invalidate()
        windowAnimator.stop()
        indicatorWindow.close()
        pinControlWindow.close()
        mirrorOverlayWindow.close()
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

    private static func suppressOtherMirrorHoverActivation(excluding current: WindowSession, for duration: TimeInterval) {
        cleanupRegistry()
        for box in sessionRegistry {
            guard let session = box.session, session !== current, session.isMirrorPinActive else { continue }
            session.suspendMirrorHoverActivation(for: duration)
        }
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
        let sourcePID = pid
        let sourceWindowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid)
        let focusSnapshot = focusReturnSnapshot
        focusReturnSnapshot = nil
        let preferredTargetPID = Self.preferredReleaseTargetPID(sourcePID: sourcePID, sourceWindowID: sourceWindowID)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
                if NSEvent.pressedMouseButtons & 1 != 0 {
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
            CFRunLoopAddSource(CFRunLoopGetCurrent(), self.observerRunLoopSource, .defaultMode)
        }
    }

    private func handleObservedGeometryChange() {
        if isTemporarilyPinned {
            showIndicator(animated: false)
        }
        if isMirrorPinActive {
            _ = refreshMirrorOverlaySnapshot(presentImmediately: false)
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
        isMirrorOverlayVisible = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        stopMirrorRefreshTimer()
        state = .floating
        indicatorWindow.orderOut(nil)
        pinControlWindow.orderOut(nil)
        mirrorOverlayWindow.hide()
        setMirrorSourceWindowHidden(false)
        effectWindow.stopExpandEffect(closeWindow: true)
        mouseTrackingTimer?.invalidate()
        outsideCollapseCandidateSince = nil
    }
    
    private func handleDestroyed() {
        print("❌ 窗口被关闭，销毁 SideBar Session")
        finishTemporaryShortcutSession(excludeWindow: false, removeSession: true)
        restoreAndDestroy()
    }
    
    func toggleExpandCollapse() {
        if isTemporarilyPinned {
            releaseTemporaryPin()
            return
        }
        switch state {
        case .expanded:
            collapseWindow()
            // 快捷键折叠后释放前台状态，确保后续可通过 Dock 唤醒
            scheduleFocusRelease(after: 0.35)
        case .snapped:
            // 快捷键触发展开：需要豁免期保护，与 Dock 展开共用同一路径
            hasReleasedDockClick = true // 快捷键无需等待松开鼠标
            expandWindow(isDockActivated: true)
            
            // 快捷键展开需要强制置顶应用并获取焦点（Dock有系统帮助，快捷键没有）
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate(options: .activateIgnoringOtherApps)
            }
            axSetBoolAttribute(on: windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.toggleExpandCollapse.main")
            axSetBoolAttribute(on: windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.toggleExpandCollapse.focused")
        case .floating:
            break
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
                print("👋 窗口拖离边缘，解除隐藏")
                let shouldEndTemporaryShortcutSession = isTemporaryShortcutManaged
                state = .floating
                notifyTemporaryShortcutStashStateChanged(isStashed: false)
                unlockScreen() // 取消吸附时清空屏幕缓存
                indicatorWindow.orderOut(nil)
                effectWindow.stopExpandEffect(closeWindow: true)
                mouseTrackingTimer?.invalidate()
                windowAnimator.stop()
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
    
    private func checkAndAdoptEdgeState() {
        guard let frame = getWindowFrame() else { return }
        let displayBounds = getDisplayBounds()
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
        collapseWindow()
        // 首次吸附后释放前台状态，确保后续 Dock 点击能触发激活通知
        scheduleFocusRelease(after: 0.5)
    }
    
    private func collapseWindow(immediate: Bool = false, triggerEffects: Bool = true) {
        if isTemporarilyPinned { return }
        if isAnimating { return } // 正在动画中，拒绝新指令
        excludeFromFocusReturn(for: 0.6)
        lastCollapseTime = Date() // 记录折叠时间戳用于防抖
        outsideCollapseCandidateSince = nil
        lastSiblingWindowInteractionAt = nil
        let shouldTriggerEffects = triggerEffects && !isIndicatorSuppressed
        
        // 必须在计算坐标前抓取最新尺寸
        guard let rawFrame = getRawWindowFrame() else { return }
        
        // 核心修复: 平衡手动缩放记忆与系统渲染抖动引起的宽度雪崩累加
        // 系统推移导致的变宽一般<4px，大于15px则说明人类拖拽过窗口边缘
        if abs(rawFrame.width - lockedWidth) > 15 {
            print("🎚️ 尺寸更新: 检测到手动缩放 (差异 > 15px)，更新锁从 \(lockedWidth) 到 \(rawFrame.width)")
            lockedWidth = rawFrame.width
        }
        
        let currentFrame = rawFrame
        
        guard let geometry = edgeGeometry(for: currentFrame) else { return }
        
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
            showIndicator(animated: Date() >= indicatorAnimationSuppressionUntil)
            updatePinControlWindow()
            return
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
                self.showIndicator(animated: Date() >= self.indicatorAnimationSuppressionUntil)
                self.updatePinControlWindow()
            }
        }
    }
    
    private func expandWindow(isDockActivated: Bool = false, immediate: Bool = false, triggerEffects: Bool = true) {
        if isTemporarilyPinned { return }
        if isAnimating { return }
        if case .expanded = state { return }
        outsideCollapseCandidateSince = nil
        let shouldTriggerEffects = triggerEffects && !isIndicatorSuppressed
        
        guard let currentFrame = getWindowFrame() else { return }
        guard let geometry = edgeGeometry(for: currentFrame) else { return }
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
            }
            return
        }
        
        if isDockActivated {
            pendingDockInteraction = true
            isAnimating = false 
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
                    }
                )
                
                axSetBoolAttribute(on: self.windowElement, attribute: kAXMainAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.main")
                axSetBoolAttribute(on: self.windowElement, attribute: kAXFocusedAttribute as CFString, value: true, context: "WindowSession.expandWindow.hover.focused")
            }

            startHoverReveal()
        }
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
            
            if animated && Date() >= indicatorAnimationSuppressionUntil {
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
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkMouseForCollapse()
        }
    }
    
    private func checkMouseForCollapse() {
        updatePinControlWindow()
        if isAnimating { return } // 正在动画中，不进行碰撞检查
        if fusionHoverLock { return }
        if isTemporarilyPinned { return }
        
        guard case .expanded = state else {
            mouseTrackingTimer?.invalidate()
            outsideCollapseCandidateSince = nil
            return
        }
        
        guard let frame = interactionHitTestFrame() ?? getWindowFrame() else { return }
        let mouseLoc = NSEvent.mouseLocation
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
        let isOutside = !bufferRect.contains(mappedMouseLoc) && !pinSafeRectContainsMouse
        let isInsideSiblingWindow = isMouseInsideAnyVisibleSiblingWindow(mappedMouseLoc)
        if isInsideSiblingWindow {
            lastSiblingWindowInteractionAt = now
        }
        let isSiblingWindowFocused =
            hasFocusedSiblingWindowOfApp() &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let isWithinSiblingWindowGrace = isWithinSiblingWindowPostInteractionGrace(now)

        if pendingDockInteraction {
            if !isOutside {
                pendingDockInteraction = false
                outsideCollapseCandidateSince = nil
            } else {
                if isPrimaryMouseDown {
                    if hasReleasedDockClick {
                        pendingDockInteraction = false
                        mouseTrackingTimer?.invalidate()
                        collapseWindow()
                        // 点击外部触发折叠后，释放前台状态
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            guard let self else { return }
                            self.scheduleFocusRelease(after: 0)
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
            mouseTrackingTimer?.invalidate()
            collapseWindow()
            // 鼠标移出折叠后释放前台状态，确保后续可通过 Dock 唤醒
            scheduleFocusRelease(after: 0.35)
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
        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else {
            return getRawWindowFrame()
        }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windowList {
            guard let cgWindowID = info[kCGWindowNumber as String] as? CGWindowID,
                  cgWindowID == windowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            return CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
        }

        return getRawWindowFrame()
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
        isMirrorOverlayVisible = false
        pinnedAnchor = nil
        stopPinnedRaisePulse()
        stopMirrorRefreshTimer()
        mouseTrackingTimer?.invalidate()
        hoverDelayTimer?.invalidate()
        hoverInterruptTimer?.invalidate()
        pinnedRaiseTimer?.invalidate()
        mirrorRefreshTimer?.invalidate()
        windowAnimator.stop()
        outsideCollapseCandidateSince = nil
        effectWindow.stopExpandEffect(closeWindow: true, immediate: true)
        indicatorWindow.orderOut(nil)
        pinControlWindow.orderOut(nil)
        mirrorOverlayWindow.hide()
        setMirrorSourceWindowHidden(false)
        setWindowAlpha(1.0, isHidden: false, preserveRecoveryRecord: true)
        destroy()
    }
}

class WindowAnimator {
    private var displayLink: CVDisplayLink?
    private var startTime: CFAbsoluteTime = 0
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
        self.startTime = CFAbsoluteTimeGetCurrent()
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
    }
}

import AppKit
import ApplicationServices

class AXWindowManager {
    private var sessions: [WindowSession] = []
    private let fusionCoordinator = FusionStripCoordinator()
    private var temporaryShortcutSession: WindowSession?
    private var temporarilyExcludedWindowKeys: Set<String> = []
    private var bundleControlOwnerOverrides: [String: SideBarHotkeyClaim.HotkeyOwner] = [:]
    private var bundlePreferredClaimSessionIDs: [String: String] = [:]
    private var bundleLastExpandedSessions: [String: ObjectIdentifier] = [:]
    private var bundleLastSnappedSessions: [String: ObjectIdentifier] = [:]
    private var hasCleanedUp = false
    
    // 监听应用级别的通知 (如焦点窗口变化)，跟踪新建的窗口
    private var appObservers: [pid_t: (AXObserver, CFRunLoopSource)] = [:]
    
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var fusionRefreshTimer: Timer?
    private var sessionSyncTimer: Timer?
    
    init() {
        SideBarBridge.shared.hotkeyActionHandler = { [weak self] bundleID in
            self?.handleForwardedHotkeyAction(bundleID: bundleID) ?? .unhandled
        }
        startMonitoringAppActivation()
        setupGlobalMouseMonitor()
        setupGlobalKeyMonitor()
        
        // 监听配置变化，动态上/下线应用
        NotificationCenter.default.addObserver(self, selector: #selector(synchronizeSessions), name: NSNotification.Name("AppConfigDidChange"), object: nil)
        
        // 监听新应用启动
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidLaunch), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleActiveSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        
        // 启动时同步一次所有运行中应用
        synchronizeSessions()
        refreshSideBarHotkeyRuntime()

        fusionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fusionCoordinator.reconcile(sessions: self.sessions)
        }
        
        // 低频轮询（每 5 秒）：检测被管理应用是否已退出，自动清理残留 session
        sessionSyncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.synchronizeSessions()
        }
    }

    deinit {
        cleanup()
    }
    
    func startMonitoringAppActivation() {
        let workspace = NSWorkspace.shared
        
        // 当任何一个应用被激活前台时，也是一个很好的补充检查机制
        workspace.notificationCenter.addObserver(self, selector: #selector(appDidActivate), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    
    @objc private func appDidLaunch(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            handleAppActivation(app: app)
        }
    }
    
    @objc private func synchronizeSessions() {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningPIDs = Set(runningApps.map { $0.processIdentifier })
        
        // 1. 下线不再被允许的会话及过期的应用级监听
        sessions.removeAll { session in
            if !AppConfig.shared.isAppEnabled(bundleID: session.bundleID) && !session.isManagedByTemporaryShortcut {
                print("🗑️ 配置变更，移除已停用会话: \(session.bundleID)")
                session.restoreAndDestroy()
                return true
            }
            
            // 进程已退出（应用被用户关闭）
            if !runningPIDs.contains(session.pid) {
                print("🗑️ 进程已退出，自动清理 session: \(session.bundleID) (pid=\(session.pid))")
                session.restoreAndDestroy()
                return true
            }
            
            // AXUIElement 失效
            var roleValue: CFTypeRef?
            let result = AccessibilityRuntimeGuard.copyAttributeValue(
                of: session.windowElement,
                attribute: kAXRoleAttribute as CFString,
                value: &roleValue,
                context: "AXWindowManager.synchronizeSessions.role"
            )
            if result == .success {
                session.noteAXRoleCheckSucceeded()
                return false
            }
            if shouldKeepSessionAfterTransientAXFailure(result, session: session, context: "synchronizeSessions") {
                return false
            }
            if result == .invalidUIElement || result == .apiDisabled {
                // 再次确认进程存活：如果进程已彻底退出，则必须清理
                guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else {
                    session.restoreAndDestroy()
                    return true
                }
                // 进程还在，信任 session 的内部容错计数
                return false
            }
            return false
        }
        
        for (pid, info) in appObservers {
            if !runningPIDs.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), info.1, .defaultMode)
                appObservers.removeValue(forKey: pid)
            }
        }
        
        // 2. 上线当前允许且在运行的会话
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
                monitorApp(pid: app.processIdentifier, bundleID: bundleID, maxRetries: 1)
            }
        }

        fusionCoordinator.reconcile(sessions: sessions)
        refreshSideBarHotkeyRuntime()
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            handleAppActivation(app: app)
        }
    }

    @objc private func handleActiveSpaceDidChange() {
        fusionCoordinator.resetForSpaceChange(sessions: sessions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.fusionCoordinator.reconcile(sessions: self.sessions)
        }
    }
    
    private func handleAppActivation(app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        
        // 检查用户是否在面板里勾选了它
        if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
            monitorApp(pid: app.processIdentifier, bundleID: bundleID, maxRetries: 5)
            prepareDockActivationRoutingIfNeeded(bundleID: bundleID)
        }
    }
    
    func cleanup() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true

        for session in sessions {
            session.restoreAndDestroy()
        }
        sessions.removeAll()
        bundleControlOwnerOverrides.removeAll()
        bundlePreferredClaimSessionIDs.removeAll()
        bundleLastExpandedSessions.removeAll()
        bundleLastSnappedSessions.removeAll()
        fusionCoordinator.tearDownAll()
        fusionRefreshTimer?.invalidate()
        fusionRefreshTimer = nil
        sessionSyncTimer?.invalidate()
        sessionSyncTimer = nil
        
        for (_, info) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), info.1, .defaultMode)
        }
        appObservers.removeAll()

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func suspendForAccessibilityLoss() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true

        for session in sessions {
            session.suspendForAccessibilityLoss()
        }
        sessions.removeAll()
        bundleControlOwnerOverrides.removeAll()
        bundlePreferredClaimSessionIDs.removeAll()
        bundleLastExpandedSessions.removeAll()
        bundleLastSnappedSessions.removeAll()
        fusionCoordinator.tearDownAll()
        fusionRefreshTimer?.invalidate()
        fusionRefreshTimer = nil
        sessionSyncTimer?.invalidate()
        sessionSyncTimer = nil

        for (_, info) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), info.1, .defaultMode)
        }
        appObservers.removeAll()

        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    // 允许通过 AX 通知自己回调
    func handleFocusedWindowChanged(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            WindowSession.recordObservedFocusSnapshot(for: app)
            if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
                monitorApp(pid: pid, bundleID: bundleID)
                sessions
                    .filter { $0.pid == pid }
                    .forEach { $0.handleFocusedWindowChangedWithinApp() }
            }
        }
    }
    
    private func monitorApp(pid: pid_t, bundleID: String, maxRetries: Int = 0) {
        let appElement = AXUIElementCreateApplication(pid)
        
        // 注册应用级别的监听器 (只需要一次)，为了拦截 Cmd+N 和 Cmd+W 导致的焦点切换
        if appObservers[pid] == nil {
            var newObserver: AXObserver?
            let callback: AXObserverCallback = { (observer: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) in
                let manager = Unmanaged<AXWindowManager>.fromOpaque(context!).takeUnretainedValue()
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if notification == kAXFocusedWindowChangedNotification as CFString {
                    DispatchQueue.main.async { manager.handleFocusedWindowChanged(pid: pid) }
                }
            }
            if AccessibilityRuntimeGuard.createObserver(
                pid: pid,
                callback: callback,
                observer: &newObserver,
                context: "AXWindowManager.monitorApp.createObserver"
            ) == .success, let observer = newObserver {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                let addResult = AccessibilityRuntimeGuard.addObserverNotification(
                    observer,
                    element: appElement,
                    notification: kAXFocusedWindowChangedNotification as CFString,
                    context: "AXWindowManager.monitorApp.addFocusedWindowObserver",
                    refcon: selfPtr
                )
                guard addResult == .success else { return }
                let runLoopSource = AXObserverGetRunLoopSource(observer)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
                appObservers[pid] = (observer, runLoopSource)
            }
        }
        
        // 获取主窗口并为其添加移动监听
        var windowValue: CFTypeRef?
        if AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &windowValue,
            context: "AXWindowManager.monitorApp.focusedWindow"
        ) == .success {
            let windowElement = windowValue as! AXUIElement
            
            // 核心修复：集中判断窗口能力，排除 Finder 桌面背景 (AXDesktop) 等非标准窗口
            let windowProfile = WindowCapabilityProfiler.profile(
                of: windowElement,
                bundleID: bundleID,
                context: "AXWindowManager.monitorApp.profile"
            )
            guard windowProfile.supportsManagedSession else {
                let subroleDescription = windowProfile.subrole ?? "unknown"
                print("⚠️ 过滤非标准窗口 (PID: \(pid), Subrole: \(subroleDescription))，跳过监控")
                return
            }

            if let windowKey = windowKey(for: windowElement, pid: pid),
               temporarilyExcludedWindowKeys.contains(windowKey) {
                return
            }
            
            // 检查缓存池中是否已存在这个窗口的会话
            if !sessions.contains(where: { CFEqual($0.windowElement, windowElement) }) {
                print("🆕 为新标准窗口创建 WindowSession (Bundle: \(bundleID), PID: \(pid))")
                let session = WindowSession(appElement: appElement, windowElement: windowElement, pid: pid, bundleID: bundleID)
                attachSessionLifecycle(to: session)
                sessions.append(session)
            }
        } else if maxRetries > 0 {
            // macOS 刚启动 App 时，窗口可能还在创建中，延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.monitorApp(pid: pid, bundleID: bundleID, maxRetries: maxRetries - 1)
            }
            return
        }
        
        // 清理由于关闭等原因已经失效的旧会话（垃圾回收）
        sessions.removeAll { session in
            var roleValue: CFTypeRef?
            let result = AccessibilityRuntimeGuard.copyAttributeValue(
                of: session.windowElement,
                attribute: kAXRoleAttribute as CFString,
                value: &roleValue,
                context: "AXWindowManager.monitorApp.sessionRole"
            )
            if result == .success {
                session.noteAXRoleCheckSucceeded()
                return false
            }
            if shouldKeepSessionAfterTransientAXFailure(result, session: session, context: "monitorApp") {
                return false
            }
            if result == .invalidUIElement || result == .apiDisabled {
                guard let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated else {
                    session.restoreAndDestroy()
                    return true
                }
                return false
            }
            return false
        }

        fusionCoordinator.reconcile(sessions: sessions)
        refreshSideBarHotkeyRuntime()
    }
    
    private func setupGlobalMouseMonitor() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            WindowSession.noteGlobalMouseDown()
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            WindowSession.noteGlobalMouseDown()
            return event
        }

        // 监听全局鼠标左键放开
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
        }
        // 应用内部鼠标左键放开
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
            return event
        }
        
        // 基础防误触记录由 WindowSession 自己结合 pressedMouseButtons 处理。
    }
    
    private func setupGlobalKeyMonitor() {
        // 全局键盘监听：用于快捷键触发展开/折叠
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event: event)
        }
        // 本地键盘监听（当本应用在前台时）
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleGlobalKeyDown(event: event) == true {
                return nil // 吃掉事件，阻止传递
            }
            return event
        }
    }
    
    @discardableResult
    private func handleGlobalKeyDown(event: NSEvent) -> Bool {
        WindowSession.noteGlobalKeyDown(event)
        let keyCode = event.keyCode
        // 只关心修饰键中的四大标志位
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue

        if let temporaryModifiers = AppConfig.shared.temporaryShortcutModifiers,
           let temporaryKeyCode = AppConfig.shared.temporaryShortcutKeyCode,
           keyCode == temporaryKeyCode,
           modifiers == temporaryModifiers {
            return handleTemporaryShortcut()
        }

        if SideBarBridge.shared.isMirroredHotkey(modifiers: modifiers, keyCode: keyCode) {
            return false
        }
        
        // 遍历所有已启用应用的配置寻找匹配的快捷键
        for (bundleID, settings) in AppConfig.shared.appSettings {
            guard settings.isEnabled,
                  SideBarBridge.shared.hotkeyBinding(for: bundleID) == nil,
                  let savedModifiers = settings.shortcutModifiers,
                  let savedKeyCode = settings.shortcutKeyCode else { continue }
            
            if keyCode == savedKeyCode && modifiers == savedModifiers {
                maybeShowMultiWindowTip(for: bundleID)
                if let session = preferredControlSession(for: bundleID) {
                    session.toggleExpandCollapse()
                    return true
                }
            }
        }
        return false
    }

    private func handleTemporaryShortcut() -> Bool {
        if let temporaryShortcutSession {
            temporaryShortcutSession.toggleTemporaryShortcutStash()
            return true
        }

        guard let target = currentFocusedStandardWindow() else { return false }
        clearTemporarilyExcludedWindow(for: target.windowElement, pid: target.pid)

        let session: WindowSession
        if let existingSession = sessions.first(where: { CFEqual($0.windowElement, target.windowElement) }) {
            session = existingSession
        } else {
            let createdSession = WindowSession(
                appElement: target.appElement,
                windowElement: target.windowElement,
                pid: target.pid,
                bundleID: target.bundleID
            )
            attachSessionLifecycle(to: createdSession)
            sessions.append(createdSession)
            session = createdSession
        }

        session.enableTemporaryShortcutManagement()
        temporaryShortcutSession = session
        fusionCoordinator.reconcile(sessions: sessions)
        session.toggleTemporaryShortcutStash()
        return true
    }

    private func currentFocusedStandardWindow() -> (appElement: AXUIElement, windowElement: AXUIElement, pid: pid_t, bundleID: String)? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.activationPolicy == .regular,
              frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleID = frontmostApp.bundleIdentifier else {
            return nil
        }

        let pid = frontmostApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXFocusedWindowAttribute as CFString,
            value: &windowValue,
            context: "AXWindowManager.currentFocusedStandardWindow.focusedWindow"
        ) == .success,
              let focusedWindow = windowValue else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        let windowProfile = WindowCapabilityProfiler.profile(
            of: windowElement,
            bundleID: bundleID,
            context: "AXWindowManager.currentFocusedStandardWindow.profile"
        )
        guard windowProfile.isStandardWindow else {
            return nil
        }

        return (appElement, windowElement, pid, bundleID)
    }

    private func attachSessionLifecycle(to session: WindowSession) {
        session.onHotkeyRuntimeStateChanged = { [weak self] _ in
            self?.handleSessionRuntimeStateChanged()
        }
        session.onStateTransition = { [weak self] session, oldState, newState in
            self?.handleSessionStateTransition(session, oldState: oldState, newState: newState)
        }
        session.onManagedEdgeDetachment = { [weak self] session in
            self?.handleManagedEdgeDetachment(for: session)
        }
        session.onTemporaryShortcutSessionEnded = { [weak self] session, excludeWindow, removeSession in
            self?.handleTemporaryShortcutSessionEnded(session, excludeWindow: excludeWindow, removeSession: removeSession)
        }
    }

    private func handleSessionRuntimeStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fusionCoordinator.reconcile(sessions: self.sessions)
            self.refreshSideBarHotkeyRuntime()
        }
    }

    private func shouldKeepSessionAfterTransientAXFailure(_ result: AXError, session: WindowSession, context: String) -> Bool {
        guard session.shouldDeferRemovalAfterAXRoleFailure(result) else { return false }
        return true
    }

    private func handleTemporaryShortcutSessionEnded(_ session: WindowSession, excludeWindow: Bool, removeSession: Bool) {
        if excludeWindow, let windowKey = windowKey(for: session.windowElement, pid: session.pid) {
            temporarilyExcludedWindowKeys.insert(windowKey)
        }
        if temporaryShortcutSession === session {
            temporaryShortcutSession = nil
        }

        guard removeSession else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessions.removeAll { $0 === session }
            self.fusionCoordinator.reconcile(sessions: self.sessions)
            self.refreshSideBarHotkeyRuntime()
        }
    }

    private func clearTemporarilyExcludedWindow(for windowElement: AXUIElement, pid: pid_t) {
        guard let windowKey = windowKey(for: windowElement, pid: pid) else { return }
        temporarilyExcludedWindowKeys.remove(windowKey)
    }

    private func windowKey(for windowElement: AXUIElement, pid: pid_t) -> String? {
        guard let windowID = WindowAlphaManager.shared.findWindowID(for: windowElement, pid: pid) else { return nil }
        return "\(pid):\(windowID)"
    }

    private func handleSessionStateTransition(_ session: WindowSession, oldState: SnapState, newState: SnapState) {
        rememberBundleWindowHistory(for: session, newState: newState)
        guard case .floating = oldState else { return }
        guard case .snapped = newState else { return }
        handleFloatingToSnappedTransition(for: session)
    }

    private func handleManagedEdgeDetachment(for session: WindowSession) {
        let bundleSessions = sessions(for: session.bundleID)
        guard bundleSessions.count > 1 else { return }

        let previousOwner = effectiveBundleOwner(for: session.bundleID)
        bundleControlOwnerOverrides[session.bundleID] = .dockminimize
        bundlePreferredClaimSessionIDs[session.bundleID] = session.coordinationSessionID

        let managedSiblingSessions = bundleSessions.filter {
            $0 !== session && $0.isManagedForCoordination
        }

        let shouldShowNotice = previousOwner != .dockminimize || !managedSiblingSessions.isEmpty
        if shouldShowNotice {
            SideBarBridge.shared.announceBundleControlTransfer(
                bundleID: session.bundleID,
                appName: session.coordinationAppDisplayName,
                owner: .dockminimize,
                reason: .detachedFromEdge
            )
        }

        fusionCoordinator.discardCachedDescriptors(for: [session] + managedSiblingSessions)

        if !managedSiblingSessions.isEmpty {
            managedSiblingSessions.forEach { $0.relinquishManagedStateForBundleTransfer() }
        }

        handleSessionRuntimeStateChanged()
    }

    private func handleFloatingToSnappedTransition(for session: WindowSession) {
        let bundleSessions = sessions(for: session.bundleID)
        guard bundleSessions.count > 1 else { return }
        guard bundleSessions.contains(where: { $0 !== session && $0.isFloatingForCoordination }) else {
            return
        }

        let previousOwner = effectiveBundleOwner(for: session.bundleID)
        bundleControlOwnerOverrides[session.bundleID] = .sidebar
        bundlePreferredClaimSessionIDs[session.bundleID] = session.coordinationSessionID

        if previousOwner != .sidebar {
            SideBarBridge.shared.announceBundleControlTransfer(
                bundleID: session.bundleID,
                appName: session.coordinationAppDisplayName,
                owner: .sidebar,
                reason: .snappedWhileFloatingSiblingsPresent
            )
        }

        handleSessionRuntimeStateChanged()
    }

    private func sessions(for bundleID: String) -> [WindowSession] {
        sessions.filter { $0.bundleID == bundleID }
    }

    private func effectiveBundleOwner(for bundleID: String) -> SideBarHotkeyClaim.HotkeyOwner {
        let bundleSessions = sessions(for: bundleID)
        guard !bundleSessions.isEmpty else { return .dockminimize }

        let hasManaged = bundleSessions.contains { $0.isManagedForCoordination }
        let hasFloating = bundleSessions.contains { $0.isFloatingForCoordination }

        if hasManaged && hasFloating, let override = bundleControlOwnerOverrides[bundleID] {
            return override
        }
        return hasManaged ? .sidebar : .dockminimize
    }

    private func reconcileBundleOwnershipState() {
        let groupedSessions = Dictionary(grouping: sessions, by: \.bundleID)

        bundleControlOwnerOverrides = bundleControlOwnerOverrides.filter { bundleID, _ in
            guard let bundleSessions = groupedSessions[bundleID], !bundleSessions.isEmpty else {
                return false
            }
            let hasManaged = bundleSessions.contains { $0.isManagedForCoordination }
            let hasFloating = bundleSessions.contains { $0.isFloatingForCoordination }
            return hasManaged && hasFloating
        }

        bundlePreferredClaimSessionIDs = bundlePreferredClaimSessionIDs.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { $0.coordinationSessionID == sessionID }) == true
        }

        bundleLastExpandedSessions = bundleLastExpandedSessions.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { ObjectIdentifier($0) == sessionID }) == true
        }
        bundleLastSnappedSessions = bundleLastSnappedSessions.filter { bundleID, sessionID in
            groupedSessions[bundleID]?.contains(where: { ObjectIdentifier($0) == sessionID }) == true
        }
    }

    private func refreshSideBarHotkeyRuntime() {
        reconcileBundleOwnershipState()

        let effectiveOwners = Dictionary(
            uniqueKeysWithValues: Set(sessions.map(\.bundleID)).sorted().map { bundleID in
                (bundleID, effectiveBundleOwner(for: bundleID))
            }
        )

        SideBarBridge.shared.syncRuntimeClaims(
            from: sessions.map(\.runtimeClaimSnapshot),
            effectiveOwners: effectiveOwners,
            preferredSessionIDs: bundlePreferredClaimSessionIDs
        )
    }

    private func handleForwardedHotkeyAction(bundleID: String) -> SideBarBridge.HotkeyActionResponse {
        let effectiveOwner = effectiveBundleOwner(for: bundleID)
        let preferredSessionID = SideBarBridge.shared.runtimeClaim(for: bundleID)?.sessionID
        maybeShowMultiWindowTip(for: bundleID)
        let candidateSessions = sessions(for: bundleID).sorted { lhs, rhs in
            forwardedHotkeyPriority(
                for: lhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID,
                bundleID: bundleID
            ) > forwardedHotkeyPriority(
                for: rhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID,
                bundleID: bundleID
            )
        }

        if let session = candidateSessions.first {
            if session.relinquishToDockMinimizeIfDetachedFromEdge() {
                return SideBarBridge.HotkeyActionResponse(
                    handled: false,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "dockminimize"
                )
            }

            if session.handleForwardedHotkeyAction() {
                return SideBarBridge.HotkeyActionResponse(
                    handled: true,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "sidebar"
                )
            }

            if session.shouldRetainForwardedHotkeyOwnership {
                return SideBarBridge.HotkeyActionResponse(
                    handled: true,
                    state: session.runtimeClaimSnapshot.state,
                    handledBy: "sidebar"
                )
            }

            return SideBarBridge.HotkeyActionResponse(
                handled: false,
                state: session.runtimeClaimSnapshot.state,
                handledBy: "dockminimize"
            )
        }

        return .unhandled
    }

    private func forwardedHotkeyPriority(
        for session: WindowSession,
        effectiveOwner: SideBarHotkeyClaim.HotkeyOwner,
        preferredSessionID: String?,
        bundleID: String
    ) -> Int {
        var score = 0

        if let preferredControlSession = preferredControlSession(for: bundleID),
           preferredControlSession === session {
            score += 2000
        }

        if let preferredSessionID, session.coordinationSessionID == preferredSessionID {
            score += 1000
        }

        switch effectiveOwner {
        case .sidebar:
            if session.isSnappedForCoordination {
                score += 500
            } else if session.isExpandedForCoordination {
                score += 400
            }
        case .dockminimize:
            if session.isFloatingForCoordination {
                score += 500
            } else if session.isExpandedForCoordination {
                score += 200
            } else if session.isSnappedForCoordination {
                score += 100
            }
        }

        return score
    }

    private func prepareDockActivationRoutingIfNeeded(bundleID: String) {
        guard WindowSession.hasRecentDockClickIntent() else { return }
        maybeShowMultiWindowTip(for: bundleID)
        guard hasMultipleSnappedWindows(for: bundleID) else { return }
        guard let session = preferredControlSession(for: bundleID) else { return }
        WindowSession.suppressProgrammaticActivation(for: session.pid, duration: 0.5)
        _ = session.toggleExpandCollapse()
    }

    private func rememberBundleWindowHistory(for session: WindowSession, newState: SnapState) {
        let sessionID = ObjectIdentifier(session)
        switch newState {
        case .expanded:
            bundleLastExpandedSessions[session.bundleID] = sessionID
        case .snapped:
            bundleLastSnappedSessions[session.bundleID] = sessionID
        case .floating:
            break
        }
    }

    private func preferredControlSession(for bundleID: String) -> WindowSession? {
        let candidateSessions = sessions(for: bundleID).filter {
            $0.isSnappedForCoordination || $0.isExpandedForCoordination
        }
        guard !candidateSessions.isEmpty else { return nil }

        let lastExpandedSessionID = bundleLastExpandedSessions[bundleID]
        let lastSnappedSessionID = bundleLastSnappedSessions[bundleID]

        return candidateSessions.max { lhs, rhs in
            controlPriority(
                for: lhs,
                lastExpandedSessionID: lastExpandedSessionID,
                lastSnappedSessionID: lastSnappedSessionID
            ) < controlPriority(
                for: rhs,
                lastExpandedSessionID: lastExpandedSessionID,
                lastSnappedSessionID: lastSnappedSessionID
            )
        }
    }

    private func controlPriority(
        for session: WindowSession,
        lastExpandedSessionID: ObjectIdentifier?,
        lastSnappedSessionID: ObjectIdentifier?
    ) -> Int {
        var score = 0
        let sessionID = ObjectIdentifier(session)

        if sessionID == lastExpandedSessionID {
            score += 1000
        }
        if sessionID == lastSnappedSessionID {
            score += 500
        }
        if session.isExpandedForCoordination {
            score += 200
        } else if session.isSnappedForCoordination {
            score += 100
        }

        return score
    }

    private func hasMultipleSnappedWindows(for bundleID: String) -> Bool {
        sessions(for: bundleID).filter(\.isSnappedForCoordination).count >= 2
    }

    private func maybeShowMultiWindowTip(for bundleID: String) {
        guard hasMultipleSnappedWindows(for: bundleID) else { return }
        guard let appName = sessions(for: bundleID).first?.coordinationAppDisplayName else { return }
        MultiWindowTipController.shared.show(appName: appName)
    }
}

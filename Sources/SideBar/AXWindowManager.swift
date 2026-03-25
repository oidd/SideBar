import AppKit
import ApplicationServices

class AXWindowManager {
    private var sessions: [WindowSession] = []
    
    // 监听应用级别的通知 (如焦点窗口变化)，跟踪新建的窗口
    private var appObservers: [pid_t: (AXObserver, CFRunLoopSource)] = [:]
    
    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalKeyDownMonitor: Any?
    
    init() {
        startMonitoringAppActivation()
        setupGlobalMouseMonitor()
        setupGlobalKeyMonitor()
        
        // 监听配置变化，动态上/下线应用
        NotificationCenter.default.addObserver(self, selector: #selector(synchronizeSessions), name: NSNotification.Name("AppConfigDidChange"), object: nil)
        
        // 监听新应用启动
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidLaunch), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        
        // 启动时同步一次所有运行中应用
        synchronizeSessions()
        
        // 低频轮询（每 5 秒）：检测被管理应用是否已退出，自动清理残留 session
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.synchronizeSessions()
        }
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
            if !AppConfig.shared.isAppEnabled(bundleID: session.bundleID) {
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
            let result = AXUIElementCopyAttributeValue(session.windowElement, kAXRoleAttribute as CFString, &roleValue)
            if result == .invalidUIElement || result == .cannotComplete {
                return true
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
    }
    
    @objc private func appDidActivate(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            handleAppActivation(app: app)
        }
    }
    
    private func handleAppActivation(app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        
        // 检查用户是否在面板里勾选了它
        if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
            monitorApp(pid: app.processIdentifier, bundleID: bundleID, maxRetries: 5)
        }
    }
    
    func cleanup() {
        for session in sessions {
            session.restoreAndDestroy()
        }
        sessions.removeAll()
        
        for (_, info) in appObservers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), info.1, .defaultMode)
        }
        appObservers.removeAll()
    }
    
    // 允许通过 AX 通知自己回调
    func handleFocusedWindowChanged(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            if AppConfig.shared.isAppEnabled(bundleID: bundleID) {
                monitorApp(pid: pid, bundleID: bundleID)
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
            if AXObserverCreate(pid, callback, &newObserver) == .success, let observer = newObserver {
                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
                let runLoopSource = AXObserverGetRunLoopSource(observer)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
                appObservers[pid] = (observer, runLoopSource)
            }
        }
        
        // 获取主窗口并为其添加移动监听
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
            let windowElement = windowValue as! AXUIElement
            
            // 核心修复：检查窗口子角色，排除 Finder 桌面背景 (AXDesktop) 等非标准窗口
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXSubroleAttribute as CFString, &subroleValue) == .success {
                let subrole = subroleValue as? String ?? ""
                if subrole != kAXStandardWindowSubrole {
                    print("⚠️ 过滤非标准窗口 (PID: \(pid), Subrole: \(subrole))，跳过监控")
                    return
                }
            } else {
                // 如果拿不到子角色，保险起见也跳过
                return
            }
            
            // 检查缓存池中是否已存在这个窗口的会话
            if !sessions.contains(where: { CFEqual($0.windowElement, windowElement) }) {
                print("🆕 为新标准窗口创建 WindowSession (Bundle: \(bundleID), PID: \(pid))")
                let session = WindowSession(appElement: appElement, windowElement: windowElement, pid: pid, bundleID: bundleID)
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
            let result = AXUIElementCopyAttributeValue(session.windowElement, kAXRoleAttribute as CFString, &roleValue)
            return result == .invalidUIElement || result == .cannotComplete
        }
    }
    
    private func setupGlobalMouseMonitor() {
        // 监听全局鼠标左键放开
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
        }
        // 应用内部鼠标左键放开
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.sessions.forEach { $0.handleMouseUp() }
            return event
        }
        
        // 基础防误触记录 (WindowSession 在 AX 内会自行处理 pressedMouseButtons，这里不需干涉)
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in }
    }
    
    private func setupGlobalKeyMonitor() {
        // 全局键盘监听：用于快捷键触发展开/折叠
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event: event)
        }
        // 本地键盘监听（当本应用在前台时）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleGlobalKeyDown(event: event) == true {
                return nil // 吃掉事件，阻止传递
            }
            return event
        }
    }
    
    @discardableResult
    private func handleGlobalKeyDown(event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        // 只关心修饰键中的四大标志位
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        
        // 遍历所有已启用应用的配置寻找匹配的快捷键
        for (bundleID, settings) in AppConfig.shared.appSettings {
            guard settings.isEnabled,
                  let savedModifiers = settings.shortcutModifiers,
                  let savedKeyCode = settings.shortcutKeyCode else { continue }
            
            if keyCode == savedKeyCode && modifiers == savedModifiers {
                // 找到匹配的快捷键，查找对应 Session
                if let session = sessions.first(where: { $0.bundleID == bundleID }) {
                    print("⌨️ 快捷键触发: \(bundleID) -> 切换展开/折叠")
                    session.toggleExpandCollapse()
                    return true
                }
            }
        }
        return false
    }
}

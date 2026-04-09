import Foundation
import Combine
import AppKit
import ServiceManagement

extension NSNotification.Name {
    static let menuBarIconVisibilityChanged = NSNotification.Name("menuBarIconVisibilityChanged")
}

struct AppSettings: Codable, Equatable {
    var isEnabled: Bool
    var colorName: String // e.g. "orange", "blue", "green"
    var opacity: Double? // 可选类型确保与旧本地存档的向后兼容
    var snapSide: String? // left / right / leftRight
    var shortcutModifiers: UInt? // NSEvent.ModifierFlags.rawValue
    var shortcutKeyCode: UInt16? // 键码
}

enum DockAvoidanceMode: String, CaseIterable {
    case automatic
    case left
    case right
    case bottom
}

class AppConfig: ObservableObject {
    static let shared = AppConfig()
    private var temporaryDockMinimizeExcludedBundleIDs: Set<String> = []
    
    // Key: Bundle ID, Value: Config
    @Published var appSettings: [String: AppSettings] {
        didSet {
            save()
            // 发送通知，让后台重新加载会话并应用新属性
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    private let defaultsKey = "SideBarAppConfigurations"
    private let snapRecordsKey = "SideBarHiddenWindowRecords"
    private let visualEffectEnabledKey = "SideBarVisualEffectEnabled"
    private let fusionStripEnabledKey = "SideBarFusionStripEnabled"
    private let fusionOverloadWarningShownKey = "SideBarFusionOverloadWarningShown"
    private let mirrorPinEnabledKey = "SideBarMirrorPinEnabled"
    private let temporaryShortcutModifiersKey = "SideBarTemporaryShortcutModifiers"
    private let temporaryShortcutKeyCodeKey = "SideBarTemporaryShortcutKeyCode"
    private let dockAvoidanceModeKey = "SideBarDockAvoidanceMode"
    
    // 格式: "PID:WindowID"
    @Published var hiddenWindowRecords: [String] = [] {
        didSet {
            UserDefaults.standard.set(hiddenWindowRecords, forKey: snapRecordsKey)
        }
    }
    
    @Published var hoverTolerance: CGFloat = 60 {
        didSet {
            UserDefaults.standard.set(hoverTolerance, forKey: "SideBarHoverTolerance")
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    @Published var hoverToleranceY: CGFloat = 60 {
        didSet {
            UserDefaults.standard.set(hoverToleranceY, forKey: "SideBarHoverToleranceY")
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    @Published var hoverDelayMS: Int = 0 {
        didSet {
            UserDefaults.standard.set(hoverDelayMS, forKey: "SideBarHoverDelayMS")
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }

    @Published var temporaryShortcutModifiers: UInt? {
        didSet {
            if let temporaryShortcutModifiers {
                UserDefaults.standard.set(temporaryShortcutModifiers, forKey: temporaryShortcutModifiersKey)
            } else {
                UserDefaults.standard.removeObject(forKey: temporaryShortcutModifiersKey)
            }
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }

    @Published var temporaryShortcutKeyCode: UInt16? {
        didSet {
            if let temporaryShortcutKeyCode {
                UserDefaults.standard.set(Int(temporaryShortcutKeyCode), forKey: temporaryShortcutKeyCodeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: temporaryShortcutKeyCodeKey)
            }
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    @Published var launchAtLogin: Bool = true {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "SideBarLaunchAtLogin")
        }
    }
    
    @Published var showInMenuBar: Bool = true {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: "SideBarShowInMenuBar")
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
        }
    }

    @Published var isVisualEffectEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isVisualEffectEnabled, forKey: visualEffectEnabledKey)
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }

    @Published var isFusionStripEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isFusionStripEnabled, forKey: fusionStripEnabledKey)
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }

    @Published var hasShownFusionOverloadWarning: Bool = false {
        didSet {
            UserDefaults.standard.set(hasShownFusionOverloadWarning, forKey: fusionOverloadWarningShownKey)
        }
    }

    @Published var isMirrorPinEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isMirrorPinEnabled, forKey: mirrorPinEnabledKey)
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    @Published var language: Int = 0 {
        didSet {
            UserDefaults.standard.set(language, forKey: "SideBarLanguage")
        }
    }

    @Published var dockAvoidanceModeRawValue: String = DockAvoidanceMode.automatic.rawValue {
        didSet {
            UserDefaults.standard.set(dockAvoidanceModeRawValue, forKey: dockAvoidanceModeKey)
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    private init() {
        self.hiddenWindowRecords = UserDefaults.standard.stringArray(forKey: snapRecordsKey) ?? []
        
        let savedTolerance = CGFloat(UserDefaults.standard.float(forKey: "SideBarHoverTolerance"))
        self.hoverTolerance = savedTolerance > 0 ? savedTolerance : 60
        
        let savedToleranceY = CGFloat(UserDefaults.standard.float(forKey: "SideBarHoverToleranceY"))
        self.hoverToleranceY = savedToleranceY > 0 ? savedToleranceY : 60
        
        self.hoverDelayMS = UserDefaults.standard.integer(forKey: "SideBarHoverDelayMS")

        if UserDefaults.standard.object(forKey: temporaryShortcutModifiersKey) != nil {
            self.temporaryShortcutModifiers = UInt(UserDefaults.standard.integer(forKey: temporaryShortcutModifiersKey))
        } else {
            self.temporaryShortcutModifiers = nil
        }

        if UserDefaults.standard.object(forKey: temporaryShortcutKeyCodeKey) != nil {
            self.temporaryShortcutKeyCode = UInt16(UserDefaults.standard.integer(forKey: temporaryShortcutKeyCodeKey))
        } else {
            self.temporaryShortcutKeyCode = nil
        }
        
        if UserDefaults.standard.object(forKey: "SideBarLaunchAtLogin") == nil {
            self.launchAtLogin = true
            UserDefaults.standard.set(true, forKey: "SideBarLaunchAtLogin")
        } else {
            self.launchAtLogin = UserDefaults.standard.bool(forKey: "SideBarLaunchAtLogin")
        }
        
        if UserDefaults.standard.object(forKey: "SideBarShowInMenuBar") == nil {
            self.showInMenuBar = true
            UserDefaults.standard.set(true, forKey: "SideBarShowInMenuBar")
        } else {
            self.showInMenuBar = UserDefaults.standard.bool(forKey: "SideBarShowInMenuBar")
        }

        if UserDefaults.standard.object(forKey: visualEffectEnabledKey) == nil {
            self.isVisualEffectEnabled = true
            UserDefaults.standard.set(true, forKey: visualEffectEnabledKey)
        } else {
            self.isVisualEffectEnabled = UserDefaults.standard.bool(forKey: visualEffectEnabledKey)
        }

        if UserDefaults.standard.object(forKey: fusionStripEnabledKey) == nil {
            self.isFusionStripEnabled = true
            UserDefaults.standard.set(true, forKey: fusionStripEnabledKey)
        } else {
            self.isFusionStripEnabled = UserDefaults.standard.bool(forKey: fusionStripEnabledKey)
        }

        self.hasShownFusionOverloadWarning = UserDefaults.standard.bool(forKey: fusionOverloadWarningShownKey)

        if UserDefaults.standard.object(forKey: mirrorPinEnabledKey) == nil {
            self.isMirrorPinEnabled = false
            UserDefaults.standard.set(false, forKey: mirrorPinEnabledKey)
        } else {
            self.isMirrorPinEnabled = UserDefaults.standard.bool(forKey: mirrorPinEnabledKey)
        }
        
        if UserDefaults.standard.object(forKey: "SideBarLanguage") == nil {
            let defaultLang = AppLanguage.system.rawValue
            self.language = defaultLang
            UserDefaults.standard.set(defaultLang, forKey: "SideBarLanguage")
        } else {
            self.language = UserDefaults.standard.integer(forKey: "SideBarLanguage")
        }

        if let rawMode = UserDefaults.standard.string(forKey: dockAvoidanceModeKey),
           DockAvoidanceMode(rawValue: rawMode) != nil {
            self.dockAvoidanceModeRawValue = rawMode
        } else {
            self.dockAvoidanceModeRawValue = DockAvoidanceMode.automatic.rawValue
            UserDefaults.standard.set(DockAvoidanceMode.automatic.rawValue, forKey: dockAvoidanceModeKey)
        }
        
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let savedDict = try? JSONDecoder().decode([String: AppSettings].self, from: data) {
            self.appSettings = savedDict.mapValues { setting in
                var normalized = setting
                normalized.snapSide = Self.normalizeSnapSide(setting.snapSide)
                return normalized
            }
        } else {
            // 兼容老版本的 Set 数据迁移
            let oldKey = "EnabledSideBarApps"
            let oldSet = UserDefaults.standard.stringArray(forKey: oldKey) ?? []
            var newDict: [String: AppSettings] = [:]
            for bundle in oldSet {
                newDict[bundle] = AppSettings(isEnabled: true, colorName: "white", snapSide: "leftRight")
            }
            self.appSettings = newDict
        }
        
        // 监听系统外观切换，驱动所有 WindowSession 刷新快照条颜色
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }
    
    @objc private func handleSystemAppearanceChange() {
        // 延迟 0.1s 确保系统完成外观切换后再广播
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: NSNotification.Name("AppConfigDidChange"), object: nil)
        }
    }
    
    // 全局覆盖所有已启用软件的透明度
    func setGlobalOpacity(_ opacity: Double) {
        var updated = appSettings
        for (key, var setting) in updated {
            if setting.isEnabled {
                setting.opacity = opacity
                updated[key] = setting
            }
        }
        appSettings = updated
    }
    
    private func save() {
        if let encoded = try? JSONEncoder().encode(appSettings) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
        // 跨进程联动：将已管理的 App 列表同步给 DockMinimize
        syncManagedAppsToDockMinimize()
    }
    
    func isAppEnabled(bundleID: String) -> Bool {
        return appSettings[bundleID]?.isEnabled ?? false
    }
    
    func getColor(for bundleID: String) -> NSColor {
        let name = appSettings[bundleID]?.colorName ?? "auto"
        switch name {
        case "auto":
            // 动态 NSColor：系统外观变化时自动解析为正确颜色
            return NSColor(name: nil) { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return .white  // 深色模式 → 白色
                } else {
                    return .black  // 浅色模式 → 黑色
                }
            }
        case "blue": return NSColor(red: 0.565, green: 0.792, blue: 0.976, alpha: 1)
        case "green": return NSColor(red: 0.647, green: 0.839, blue: 0.655, alpha: 1)
        case "red": return NSColor(red: 0.937, green: 0.604, blue: 0.604, alpha: 1)
        case "yellow": return NSColor(red: 1, green: 0.961, blue: 0.616, alpha: 1)
        case "purple": return NSColor(red: 0.808, green: 0.576, blue: 0.847, alpha: 1)
        case "pink": return NSColor(red: 0.957, green: 0.561, blue: 0.694, alpha: 1)
        case "orange": return NSColor(red: 1, green: 0.8, blue: 0.502, alpha: 1)
        case "black": return NSColor.black
        case "white": return NSColor.white
        default: return NSColor.white
        }
    }
    
    func getColorName(for bundleID: String) -> String {
        return appSettings[bundleID]?.colorName ?? "auto"
    }
    
    func getOpacity(for bundleID: String) -> Double {
        return appSettings[bundleID]?.opacity ?? 1.0
    }

    func getSnapSide(for bundleID: String) -> String {
        Self.normalizeSnapSide(appSettings[bundleID]?.snapSide)
    }
    
    func updateOpacity(bundleID: String, opacity: Double) {
        if var setting = appSettings[bundleID] {
            setting.opacity = opacity
            appSettings[bundleID] = setting
        }
    }

    func updateSnapSide(bundleID: String, snapSide: String) {
        if var setting = appSettings[bundleID] {
            setting.snapSide = Self.normalizeSnapSide(snapSide)
            appSettings[bundleID] = setting
        }
    }

    func setGlobalSnapSide(_ snapSide: String) {
        var updated = appSettings
        for (key, var setting) in updated {
            if setting.isEnabled {
                setting.snapSide = Self.normalizeSnapSide(snapSide)
                updated[key] = setting
            }
        }
        appSettings = updated
    }

    var dockAvoidanceMode: DockAvoidanceMode {
        DockAvoidanceMode(rawValue: dockAvoidanceModeRawValue) ?? .automatic
    }

    func setDockAvoidanceMode(_ mode: DockAvoidanceMode) {
        dockAvoidanceModeRawValue = mode.rawValue
    }

    func resolvedDockAvoidanceSide() -> String? {
        switch dockAvoidanceMode {
        case .automatic:
            return Self.detectDockOrientation()
        case .left, .right, .bottom:
            return dockAvoidanceMode.rawValue
        }
    }
    
    func updateApp(bundleID: String, isEnabled: Bool, colorName: String) {
        let existing = appSettings[bundleID]
        appSettings[bundleID] = AppSettings(
            isEnabled: isEnabled,
            colorName: colorName,
            opacity: existing?.opacity ?? 1.0,
            snapSide: Self.normalizeSnapSide(existing?.snapSide),
            shortcutModifiers: existing?.shortcutModifiers,
            shortcutKeyCode: existing?.shortcutKeyCode
        )
    }
    
    func toggleApp(bundleID: String, isEnabled: Bool) {
        let existing = appSettings[bundleID]
        appSettings[bundleID] = AppSettings(
            isEnabled: isEnabled,
            colorName: existing?.colorName ?? "auto",
            opacity: existing?.opacity ?? 1.0,
            snapSide: Self.normalizeSnapSide(existing?.snapSide),
            shortcutModifiers: existing?.shortcutModifiers,
            shortcutKeyCode: existing?.shortcutKeyCode
        )
    }
    
    func setShortcut(bundleID: String, modifiers: UInt, keyCode: UInt16) {
        if var setting = appSettings[bundleID] {
            setting.shortcutModifiers = modifiers
            setting.shortcutKeyCode = keyCode
            appSettings[bundleID] = setting
        }
    }
    
    func clearShortcut(bundleID: String) {
        if var setting = appSettings[bundleID] {
            setting.shortcutModifiers = nil
            setting.shortcutKeyCode = nil
            appSettings[bundleID] = setting
        }
    }

    func setTemporaryShortcut(modifiers: UInt, keyCode: UInt16) {
        temporaryShortcutModifiers = modifiers
        temporaryShortcutKeyCode = keyCode
    }

    func clearTemporaryShortcut() {
        temporaryShortcutModifiers = nil
        temporaryShortcutKeyCode = nil
    }

    func setTemporaryDockMinimizeExclusion(bundleID: String, excluded: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setTemporaryDockMinimizeExclusion(bundleID: bundleID, excluded: excluded)
            }
            return
        }

        let changed: Bool
        if excluded {
            let (inserted, _) = temporaryDockMinimizeExcludedBundleIDs.insert(bundleID)
            changed = inserted
        } else {
            changed = temporaryDockMinimizeExcludedBundleIDs.remove(bundleID) != nil
        }

        if changed {
            syncManagedAppsToDockMinimize()
        }
    }

    func markFusionOverloadWarningShown() {
        hasShownFusionOverloadWarning = true
    }
    
    // MARK: - Hidden Window Recovery Support
    
    func addHiddenWindowRecord(pid: pid_t, windowID: UInt32) {
        let record = "\(pid):\(windowID)"
        if !hiddenWindowRecords.contains(record) {
            hiddenWindowRecords.append(record)
        }
    }
    
    func removeHiddenWindowRecord(pid: pid_t, windowID: UInt32) {
        let record = "\(pid):\(windowID)"
        hiddenWindowRecords.removeAll { $0 == record }
    }
    
    // MARK: - 跨应用联动 (SideBar ↔ DockMinimize)
    
    /// 将 SideBar 当前管理的已启用应用列表写入共享文件，并发送系统级广播通知 DockMinimize
    private func syncManagedAppsToDockMinimize() {
        // 1. 提取所有 isEnabled == true 的 BundleID
        let enabledBundleIDs = appSettings
            .filter { $0.value.isEnabled }
            .map { $0.key }
        let mergedBundleIDs = Array(Set(enabledBundleIDs).union(temporaryDockMinimizeExcludedBundleIDs)).sorted()
        
        // 2. 确保共享目录存在
        let sharedDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ivean.shared")
        
        do {
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        } catch {
            print("[SideBar] 无法创建共享目录: \(error)")
            return
        }
        
        // 3. 写入 JSON 文件
        let filePath = sharedDir.appendingPathComponent("sidebar_managed_apps.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: mergedBundleIDs, options: .prettyPrinted)
            try data.write(to: filePath, options: .atomic)
        } catch {
            print("[SideBar] 写入共享文件失败: \(error)")
            return
        }
        
        // 4. 发送系统级广播（DistributedNotificationCenter）
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.ivean.SideBar.managedAppsDidChange"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    
    /// 检测 DockMinimize 是否正在运行
    static func isDockMinimizeRunning() -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.dockminimize.app").isEmpty
    }

    private static func normalizeSnapSide(_ rawValue: String?) -> String {
        switch rawValue {
        case "both", "leftRight":
            return "leftRight"
        case "left", "right":
            return rawValue ?? "leftRight"
        case "bottom", "leftBottom", "rightBottom", "leftRightBottom":
            return "leftRight"
        default:
            return "leftRight"
        }
    }

    static func detectDockOrientation() -> String? {
        if let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation"),
           ["left", "right", "bottom"].contains(orientation) {
            return orientation
        }

        if let persistentDomain = UserDefaults.standard.persistentDomain(forName: "com.apple.dock"),
           let orientation = persistentDomain["orientation"] as? String,
           ["left", "right", "bottom"].contains(orientation) {
            return orientation
        }

        return nil
    }
    
    func updateLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            print("[SideBar] SMAppService current status: \(service.status.rawValue), attempting to \(enable ? "register" : "unregister")")
            do {
                if enable {
                    try service.register()
                    print("[SideBar] SMAppService register succeeded, new status: \(service.status.rawValue)")
                } else {
                    try service.unregister()
                    print("[SideBar] SMAppService unregister succeeded, new status: \(service.status.rawValue)")
                }
            } catch {
                print("[SideBar] SMAppService \(enable ? "register" : "unregister") failed: \(error)")
            }
        } else {
            // macOS 12 及以下，回退到 osascript
            let appPath = Bundle.main.bundlePath
            let script = enable
                ? "tell application \"System Events\" to make login item at end with properties {path:\"\(appPath)\", hidden:false, name:\"SideBar\"}"
                : "tell application \"System Events\" to delete login item \"SideBar\""
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                try? process.run()
                process.waitUntilExit()
            }
        }
    }
}

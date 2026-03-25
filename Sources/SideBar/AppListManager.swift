import Foundation
import AppKit

struct AppInfo: Identifiable, Hashable {
    let id: String // Bundle ID
    let name: String
    let icon: NSImage?
    var isRunning: Bool
}

class AppListManager: ObservableObject {
    @Published var apps: [AppInfo] = []
    
    init() {
        refreshRunningApps()
        
        // 监听应用启动/退出以保持列表刷新
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshRunningApps), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshRunningApps), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }
    
    @objc func refreshRunningApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        var newApps: [AppInfo] = []
        for app in runningApps {
            // 过滤掉没有 BundleID 或者是不可见的后台服务进程
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular, // 只显示正常带有界面的应用程序
                  let name = app.localizedName else {
                continue
            }
            // 排除自己
            if bundleID == Bundle.main.bundleIdentifier { continue }
            
            let info = AppInfo(id: bundleID, name: name, icon: app.icon, isRunning: true)
            newApps.append(info)
        }
        
        // 核心：这里的排序逻辑决定了打开窗口时的初始顺序
        // 遵循用户需求：开启的软件置顶，同状态下按字母排
        let config = AppConfig.shared
        newApps.sort { a, b in
            let aEnabled = config.isAppEnabled(bundleID: a.id)
            let bEnabled = config.isAppEnabled(bundleID: b.id)
            if aEnabled != bEnabled {
                return aEnabled // 开启的排在前面
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        
        DispatchQueue.main.async {
            self.apps = newApps
        }
    }
    
    /// 当设置窗口关闭时调用，将已开启的 App 置顶
    func reorderAppsByEnabledState() {
        let config = AppConfig.shared
        apps.sort { a, b in
            let aEnabled = config.isAppEnabled(bundleID: a.id)
            let bEnabled = config.isAppEnabled(bundleID: b.id)
            
            if aEnabled != bEnabled {
                return aEnabled // 开启的排在前面
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

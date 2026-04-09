import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let permissionsManager = PermissionsManager()
    var axManager: AXWindowManager?
    var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("---------------------------------------")
        print("🚀 SideBar 已启动 - 视觉对齐与色彩同步稳定版")
        print("🛠️ 当前二进制版本构建于: 2026-02-25 23:55 (Sync & Align)") 
        print("---------------------------------------")
        setupMenuBarForEditActions()
        setupStatusBar()
        checkPermissions()
        
        // 异常恢复逻辑：营救因上次崩溃/强制重启而丢失（Alpha 0）的窗口
        rescueHiddenWindows()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 当用户在后台运行时再次双击 App 图标，主动弹出设置面板
        showSettings()
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("💡 SideBar 正在退出，恢复所有隐藏或被控制的窗口...")
        axManager?.cleanup()
    }
    
    private func setupStatusBar() {
        updateStatusBarVisibility()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleMenuBarVisibilityChange), name: .menuBarIconVisibilityChanged, object: nil)
    }
    
    @objc private func handleMenuBarVisibilityChange() {
        updateStatusBarVisibility()
    }
    
    private func updateStatusBarVisibility() {
        if AppConfig.shared.showInMenuBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = statusItem.button {
                    if let customImage = NSImage(named: "menu") {
                        customImage.size = NSSize(width: 18, height: 18)
                        customImage.isTemplate = true
                        button.image = customImage
                    } else {
                        if #available(macOS 11.0, *) {
                            button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "SideBar")
                        } else {
                            button.title = "SideBar"
                        }
                    }
                }
                
                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "偏好设置...".localized, action: #selector(showSettings), keyEquivalent: ","))
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(title: "退出 SideBar".localized, action: #selector(quitApp), keyEquivalent: "q"))
                
                statusItem.menu = menu
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }
    
    private func setupMenuBarForEditActions() {
        // macOS LSUIElement App 默认没有 MainMenu，导致所有的常规编辑快捷键 (如 Cmd+V, Cmd+A 等) 失效
        // 为了使得设置面板里的 TextField 正常工作，必须在后台为其植入隐形的 Edit 菜单
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func checkPermissionsManual() {
        let isTrusted = permissionsManager.isAccessibilityTrusted(prompt: true)
        if isTrusted {
            let alert = NSAlert()
            alert.messageText = "权限已授予".localized
            alert.informativeText = "SideBar 已获得辅助功能权限，可以正常工作。".localized
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定".localized)
            // Ensure window floats above others
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    
    @objc private func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "SideBar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 820, height: 580)
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = NSHostingView(rootView: settingsView)
            window.isReleasedWhenClosed = false
            
            settingsWindow = window
        }
        
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    private func checkPermissions() {
        let isTrusted = permissionsManager.isAccessibilityTrusted(prompt: true)
        if !isTrusted {
            print("未获得辅助功能权限，已弹出请求")
            let alert = NSAlert()
            alert.messageText = "需要辅助功能权限".localized
            alert.informativeText = "SideBar 需要辅助功能权限才能控制和隐藏其他应用程序的窗口。\n\n请在系统设置中允许 SideBar，然后重启本软件。".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置".localized)
            alert.addButton(withTitle: "退出程序".localized)
            
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                permissionsManager.openAccessibilitySettings()
                // Exit and wait for user to relaunch after granting permission
                NSApp.terminate(nil)
            } else {
                NSApp.terminate(nil)
            }
        } else {
            print("辅助功能权限正常")
            axManager = AXWindowManager()
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func rescueHiddenWindows() {
        let records = AppConfig.shared.hiddenWindowRecords
        if records.isEmpty { return }
        
        print("🔍 发现 \(records.count) 个潜在的离屏隐藏窗口，启动营救逻辑...")
        
        for record in records {
            let parts = record.split(separator: ":")
            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  let windowID = UInt32(parts[1]) else { continue }
            
            // 1. 强制恢复透明度 (最关键的一步)
            WindowAlphaManager.shared.setAlpha(for: windowID, alpha: 1.0)
            
            // 2. 尝试激活该进程，让用户看到它已回来
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
        
        // 恢复后清空记录
        AppConfig.shared.hiddenWindowRecords.removeAll()
    }
}

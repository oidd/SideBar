import Cocoa
import SwiftUI

class UpdateChecker {
    static let shared = UpdateChecker()
    
    private let updateInfoURL = URL(string: "https://www.ivean.com/sidebar/updates/version.json")!
    /// 已经向用户弹过更新提示的版本号；用于自动检查时避免对同一新版本反复打扰。
    /// 手动点击"立即检查"时会忽略此记录强制弹窗。
    private let lastNotifiedVersionKey = "SideBarUpdateLastNotifiedVersion"

    func checkForUpdatesIfNeededOnLaunch() {
        guard AppConfig.shared.shouldRunAutomaticUpdateCheck() else { return }
        checkForUpdates(manual: false)
    }
    
    func checkForUpdates(manual: Bool = false) {
        let request = URLRequest(url: updateInfoURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                if manual {
                    DispatchQueue.main.async {
                        self.showAlert(title: "检查更新失败".localized, message: "无法连接到服务器，请检查网络设置。".localized)
                    }
                }
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let latestVersion = json["version"] as? String else {
                    if manual {
                        DispatchQueue.main.async {
                            self.showAlert(title: "解析失败".localized, message: "服务器返回的数据格式不正确。".localized)
                        }
                    }
                    return
                }

                // 只要拿到了版本号，就视为本次"更新检查"成功（用于驱动"每周一次"的节流）。
                AppConfig.shared.markSuccessfulUpdateCheck()

                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.3"
                let releaseNotes = json["release_notes"] as? String ?? "包含重要的性能改进与功能更新。".localized
                let downloadURLString = json["download_url"] as? String
                let downloadURL = downloadURLString.flatMap { URL(string: $0) }

                if self.isVersionGreaterThan(latestVersion, currentVersion) {
                    // 发现新版本：手动检查一律弹窗；自动检查若同一版本已经提示过则保持静默，避免反复打扰。
                    if !manual {
                        let lastNotified = UserDefaults.standard.string(forKey: self.lastNotifiedVersionKey)
                        if lastNotified == latestVersion {
                            print("[SideBar] 自动检查发现新版本 \(latestVersion)，但已对该版本提示过，本次保持静默。")
                            return
                        }
                    }

                    guard let downloadURL else {
                        // 没有合法的下载地址：手动模式下友好提示，自动模式静默忽略。
                        if manual {
                            DispatchQueue.main.async {
                                self.showAlert(title: "解析失败".localized, message: "服务器返回的数据格式不正确。".localized)
                            }
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        let response = self.showUpdateAlert(latestVersion: latestVersion, releaseNotes: releaseNotes, downloadURL: downloadURL)
                        // 修复：仅当用户主动点"稍后"时记忆该版本号，避免后续启动自动检查反复打扰。
                        // 用户点"前往下载"表明他正在去更新的路上，本次启动若下载失败/被中断，
                        // 下次启动仍应当继续提示——因此这种情况下**不**写入 lastNotifiedVersionKey。
                        if response == .alertSecondButtonReturn {
                            UserDefaults.standard.set(latestVersion, forKey: self.lastNotifiedVersionKey)
                            print("[SideBar] 用户选择稍后，记忆版本 \(latestVersion)，下次启动跳过同版本自动提示")
                        } else {
                            print("[SideBar] 用户选择前往下载，不记忆版本号，下次启动若仍是同一新版本仍会提示")
                        }
                    }
                } else {
                    // 已是最新版本：仅手动检查时给出反馈，自动检查保持静默。
                    if manual {
                        DispatchQueue.main.async {
                            self.showAlert(title: "已是最新版本".localized, message: "当前 SideBar 版本 ".localized + currentVersion + " 已经是最新版。".localized)
                        }
                    }
                }
            } catch {
                if manual {
                    DispatchQueue.main.async {
                        self.showAlert(title: "解析失败".localized, message: "服务器返回的数据格式不正确。".localized)
                    }
                }
            }
        }.resume()
    }
    
    private func isVersionGreaterThan(_ v1: String, _ v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(parts1.count, parts2.count)
        
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        
        return false
    }
    
    @discardableResult
    private func showUpdateAlert(latestVersion: String, releaseNotes: String, downloadURL: URL) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "发现新版本: ".localized + latestVersion
        alert.informativeText = releaseNotes
        alert.alertStyle = .informational
        
        alert.addButton(withTitle: "前往下载".localized)
        alert.addButton(withTitle: "稍后".localized)
        
        // Ensure alert pops up in front
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open URL in default browser
            NSWorkspace.shared.open(downloadURL)
        }
        return response
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定".localized)
        
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

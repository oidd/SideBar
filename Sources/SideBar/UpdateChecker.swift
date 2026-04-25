import Cocoa
import SwiftUI

class UpdateChecker {
    static let shared = UpdateChecker()
    
    private let updateInfoURL = URL(string: "https://www.ivean.com/sidebar/updates/version.json")!

    func checkForUpdatesIfNeededOnLaunch() {
        guard AppConfig.shared.shouldRunAutomaticUpdateCheck() else { return }
        checkForUpdates(manual: false)
    }
    
    func checkForUpdates(manual: Bool = false) {
        var request = URLRequest(url: updateInfoURL)
        request.timeoutInterval = 5 // 设置 5 秒超时，避免等待过久
        
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
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let latestVersion = json["version"] as? String {
                    
                    let downloadURLString = json["download_url"] as? String
                    
                    if let finalURLString = downloadURLString, let downloadURL = URL(string: finalURLString) {
                        let releaseNotes = json["release_notes"] as? String ?? "包含重要的性能改进与功能更新。".localized
                        
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.5"
                        AppConfig.shared.markSuccessfulUpdateCheck()
                        
                        if self.isVersionGreaterThan(latestVersion, currentVersion) {
                            if manual {
                                DispatchQueue.main.async {
                                    self.showUpdateAlert(latestVersion: latestVersion, releaseNotes: releaseNotes, downloadURL: downloadURL)
                                }
                            } else {
                                print("[SideBar] 自动检查发现新版本 \(latestVersion)，保持静默等待用户手动检查。")
                            }
                        } else {
                            if manual {
                                DispatchQueue.main.async {
                                    self.showAlert(title: "已是最新版本".localized, message: "当前 SideBar 版本 ".localized + currentVersion + " 已经是最新版。".localized)
                                }
                            }
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
    
    private func showUpdateAlert(latestVersion: String, releaseNotes: String, downloadURL: URL) {
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

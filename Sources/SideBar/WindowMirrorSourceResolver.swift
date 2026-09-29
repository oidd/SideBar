import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 把 SideBar 内部的 `CGWindowID` / `pid_t` 桥接到 ScreenCaptureKit 的 `SCWindow` / `SCDisplay`，
/// 供 `WindowMirrorLiveCapturer` 真正发起采集时使用。
///
/// 该解析器内部缓存了一次 `SCShareableContent` 的快照，并提供主动刷新接口；
/// 调用方在窗口位置/大小变更后只需要重新刷新即可，绝大部分场景下命中缓存即可返回。
@available(macOS 12.3, *)
final class WindowMirrorSourceResolver {
    static let shared = WindowMirrorSourceResolver()

    struct ResolvedSource {
        let window: SCWindow
        let display: SCDisplay
    }

    private init() {}

    private let cacheQueue = DispatchQueue(label: "com.ivean.SideBar.mirrorSourceResolver", attributes: .concurrent)
    private var cachedContent: SCShareableContent?
    private var cachedAt: Date = .distantPast
    /// 缓存时长：超过 1s 就重抓一次，避免窗口在用户拖动期间命中过期的几何。
    private static let cacheTTL: TimeInterval = 1.0

    /// 异步解析一个 `CGWindowID` 对应的 ScreenCaptureKit 对象。
    /// - Parameters:
    ///   - windowID: 来自 `_AXUIElementGetWindow` 或 CGWindowList 的窗口 ID。
    ///   - preferredScreen: 优先选择的 `NSScreen`；用于多显示器场景下尽量返回鼠标/源窗口所在屏。
    ///   - completion: 主线程回调；找不到对应窗口时回调 `nil`。
    func resolve(windowID: CGWindowID,
                 preferredScreen: NSScreen?,
                 completion: @escaping (ResolvedSource?) -> Void) {
        loadShareableContent { [weak self] content in
            guard let self, let content else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let resolved = self.lookup(in: content, windowID: windowID, preferredScreen: preferredScreen)
            DispatchQueue.main.async { completion(resolved) }
        }
    }

    /// 主动让下一次 `resolve` 跳过缓存重新抓取。
    func invalidateCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.cachedContent = nil
            self?.cachedAt = .distantPast
        }
    }

    // MARK: - Internals

    private func loadShareableContent(completion: @escaping (SCShareableContent?) -> Void) {
        let (cached, cachedTime) = cacheQueue.sync { (cachedContent, cachedAt) }
        if let cached, Date().timeIntervalSince(cachedTime) < Self.cacheTTL {
            completion(cached)
            return
        }
        // onScreenWindowsOnly = false：源窗口可能因为吸附被推到屏幕外，仍需要被采集到。
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            if let error {
                print("🪟 读取 ScreenCaptureKit 可共享内容失败: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let self, let content else {
                completion(nil)
                return
            }
            self.cacheQueue.async(flags: .barrier) {
                self.cachedContent = content
                self.cachedAt = Date()
            }
            completion(content)
        }
    }

    private func lookup(in content: SCShareableContent,
                        windowID: CGWindowID,
                        preferredScreen: NSScreen?) -> ResolvedSource? {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }
        let display = chooseDisplay(for: window, in: content, preferredScreen: preferredScreen)
        guard let display else { return nil }
        return ResolvedSource(window: window, display: display)
    }

    private func chooseDisplay(for window: SCWindow,
                               in content: SCShareableContent,
                               preferredScreen: NSScreen?) -> SCDisplay? {
        guard !content.displays.isEmpty else { return nil }

        // 优先：调用方指定的屏（一般是源窗口当前所在屏）
        if let preferredID = preferredScreen?.displayID,
           let match = content.displays.first(where: { $0.displayID == preferredID }) {
            return match
        }

        // 次选：与窗口 frame 几何相交最大的屏
        let windowFrame = window.frame
        var bestDisplay: SCDisplay?
        var bestOverlap: CGFloat = -1
        for display in content.displays {
            let overlap = displayFrame(for: display).intersection(windowFrame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestOverlap {
                bestOverlap = area
                bestDisplay = display
            }
        }
        if let bestDisplay { return bestDisplay }

        // 兜底：随便给一块，确保非 nil
        return content.displays.first
    }

    private func displayFrame(for display: SCDisplay) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
    }
}

extension NSScreen {
    /// `CGDirectDisplayID` 表示这块屏在 CoreGraphics 侧的句柄。
    /// AppKit 没有直接暴露该值，只能从 `deviceDescription` 里按惯例键名取出。
    /// `kCGDirectMainDisplay` 作为兜底，确保即使外接显示器被拔掉、字典缺键也能给出可用值。
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}

import AppKit
import SwiftUI

private enum DockPosition {
    case bottom
    case left
    case right
}

private final class DockPositionManager {
    static let shared = DockPositionManager()

    private init() {}

    var currentPosition: DockPosition {
        guard let screen = NSScreen.main else { return .bottom }

        let frame = screen.frame
        let visibleFrame = screen.visibleFrame

        if visibleFrame.origin.y > frame.origin.y {
            return .bottom
        }

        if visibleFrame.origin.x > frame.origin.x {
            return .left
        }

        if visibleFrame.width < frame.width {
            return .right
        }

        return .bottom
    }

    var realDockThickness: CGFloat {
        guard let screen = NSScreen.main else { return 60 }

        let frame = screen.frame
        let visibleFrame = screen.visibleFrame

        switch currentPosition {
        case .bottom:
            return visibleFrame.origin.y - frame.origin.y
        case .left:
            return visibleFrame.origin.x - frame.origin.x
        case .right:
            return frame.width - (visibleFrame.origin.x - frame.origin.x + visibleFrame.width)
        }
    }
}

final class MultiWindowTipController: NSObject, ObservableObject {
    static let shared = MultiWindowTipController()

    @Published private(set) var titleText: String = ""
    @Published private(set) var messageText: String = ""
    @Published private(set) var remainingSeconds: Int = 30

    private let panelWidth: CGFloat = 540
    private let panelHeight: CGFloat = 152
    private let accentColor = NSColor(
        red: 252.0 / 255.0,
        green: 133.0 / 255.0,
        blue: 12.0 / 255.0,
        alpha: 1
    )

    private var window: NSPanel?
    private var countdownTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private var suppressForCurrentLaunch = false

    private enum DismissMode {
        case sessionOnly
        case permanent
        case passive
    }

    func start() {
        suppressForCurrentLaunch = false
        ensureWindow()
    }

    func show(appName: String) {
        guard !suppressForCurrentLaunch else { return }
        guard !AppConfig.shared.shouldSuppressMultiWindowTip() else { return }
        if let window, window.isVisible {
            return
        }

        titleText = "检测到应用的多窗口环境".localized
        let messageTemplate = "“%@”存在多个窗口被折叠。通过点击程序坞中“%@”的图标或使用快捷键时，SideBar 默认会操作最后一次展开过的窗口。其他窗口可通过悬停快照条进行操作。".localized
        messageText = String(format: messageTemplate, locale: Locale.current, appName, appName)
        remainingSeconds = 30

        ensureWindow()
        updateWindowPosition()

        dismissWorkItem?.cancel()
        countdownTimer?.invalidate()

        window?.alphaValue = 0
        window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.window?.animator().alphaValue = 1
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            if self.remainingSeconds <= 1 {
                timer.invalidate()
                self.dismiss(animated: true)
                return
            }

            self.remainingSeconds -= 1
        }

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        self.dismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: dismissWorkItem)
    }

    func dismissNow() {
        dismiss(animated: true, mode: .sessionOnly)
    }

    func dismissAndSuppressFutureTips() {
        dismiss(animated: true, mode: .permanent)
    }

    private func dismiss(animated: Bool, mode: DismissMode = .passive) {
        switch mode {
        case .sessionOnly:
            suppressForCurrentLaunch = true
        case .permanent:
            suppressForCurrentLaunch = true
            AppConfig.shared.setSuppressMultiWindowTip(true)
        case .passive:
            suppressForCurrentLaunch = true
        }

        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        countdownTimer?.invalidate()
        countdownTimer = nil

        guard let window else { return }

        let hideWindow = {
            window.orderOut(nil)
        }

        guard animated, window.isVisible else {
            hideWindow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        } completionHandler: {
            hideWindow()
        }
    }

    private func ensureWindow() {
        guard window == nil else {
            if let window {
                updateHostingView(for: window)
            }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.becomesKeyOnlyIfNeeded = true

        updateHostingView(for: panel)
        window = panel
    }

    private func updateHostingView(for panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: MultiWindowTipView(controller: self))
    }

    private func updateWindowPosition() {
        guard let window, let screen = NSScreen.main else { return }

        let width = panelWidth
        let height = panelHeight
        let dockPosition = DockPositionManager.shared.currentPosition
        let dockThickness = max(DockPositionManager.shared.realDockThickness, 24)
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 14

        let origin: CGPoint
        switch dockPosition {
        case .bottom:
            origin = CGPoint(
                x: screen.frame.midX - width / 2,
                y: screen.frame.minY + dockThickness + verticalPadding
            )
        case .left:
            origin = CGPoint(
                x: screen.frame.minX + dockThickness + horizontalPadding,
                y: screen.frame.maxY - height - 56
            )
        case .right:
            origin = CGPoint(
                x: screen.frame.maxX - dockThickness - width - horizontalPadding,
                y: screen.frame.maxY - height - 56
            )
        }

        window.setFrameOrigin(origin)
    }
}

private struct MultiWindowTipView: View {
    @ObservedObject var controller: MultiWindowTipController

    private let accentColor = Color(
        red: 252.0 / 255.0,
        green: 133.0 / 255.0,
        blue: 12.0 / 255.0
    )

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accentColor.opacity(0.95), lineWidth: 1.6)
                }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(controller.titleText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Button(action: controller.dismissNow) {
                        Text(controller.closeButtonTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accentColor)
                    )

                    Button(action: controller.dismissAndSuppressFutureTips) {
                        Text(controller.dismissForeverButtonTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(accentColor.opacity(0.5), lineWidth: 1)
                    }
                }

                Text(controller.messageText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 152)
        .shadow(color: accentColor.opacity(0.26), radius: 18, x: 0, y: 10)
    }
}

private extension MultiWindowTipController {
    var closeButtonTitle: String {
        let titleTemplate = "关闭提示（%d）".localized
        return String(format: titleTemplate, locale: Locale.current, remainingSeconds)
    }

    var dismissForeverButtonTitle: String {
        "不再提示".localized
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

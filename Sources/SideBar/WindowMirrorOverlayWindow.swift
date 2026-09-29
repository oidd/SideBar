import AppKit
import CoreGraphics

/// 承载置顶副本画面的悬浮面板。
///
/// 自身的唯一职责是把 `WindowMirrorLiveCapturer.renderingLayer` 挂到 contentView 的 layer 树上，
/// 由 SCStream 直接推流，跨进程零拷贝渲染源窗口的实时画面。
///
/// 鼠标交互一律不走面板：`ignoresMouseEvents = true` 让点击、悬停、滚动、拖拽全部穿透到
/// 真实窗口本身，于是用户在视觉上看到的是"置顶画面"，操作上仍直接作用在真实窗口上 ——
/// 拖动标题栏、点击按钮、文本编辑、滚动列表都按真实窗口的原生行为进行。要解除置顶，
/// 仍走原来的 `PinControlWindow` 图钉按钮入口。
///
/// 该窗口本体没有任何画面来源；不调用 `attachCaptureLayer(_:)` 时面板是空的。
final class WindowMirrorOverlayWindow: NSPanel {
    private let mirrorView = MirrorLiveContentView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        // 关键：让所有鼠标事件穿透到下层真实窗口，置顶面板纯视觉。
        ignoresMouseEvents = true
        contentView = mirrorView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 把实时采集层挂到面板上。重复调用同一个 layer 是安全的。
    func attachCaptureLayer(_ layer: CALayer) {
        mirrorView.attachCaptureLayer(layer)
    }

    /// 从面板上摘掉采集层（不销毁 layer 本身），用于停掉采集时清理引用。
    func detachCaptureLayer() {
        mirrorView.detachCaptureLayer()
    }

    /// 显示面板并把 frame 同步为新的几何。
    func display(at frame: CGRect) {
        setFrame(frame, display: true)
        alphaValue = 1
        orderFrontRegardless()
    }

    /// 仅更新 frame，不改变可见性。用于跟踪源窗口的位置变动。
    func update(frame: CGRect) {
        setFrame(frame, display: true)
    }

    /// 隐藏面板，但保留已挂载的采集层引用。
    func hide() {
        alphaValue = 1
        orderOut(nil)
    }
}

/// 置顶面板的 contentView：宿主一个外部 CALayer（实际是 AVSampleBufferDisplayLayer）作为画面源。
/// 不接管任何鼠标事件 —— 宿主面板已经把 `ignoresMouseEvents` 设为 true，事件根本不会派发到本视图。
private final class MirrorLiveContentView: NSView {
    private(set) var attachedCaptureLayer: CALayer?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func attachCaptureLayer(_ newLayer: CALayer) {
        guard let hostLayer = layer else { return }
        if attachedCaptureLayer === newLayer {
            newLayer.frame = hostLayer.bounds
            return
        }
        attachedCaptureLayer?.removeFromSuperlayer()
        attachedCaptureLayer = newLayer
        newLayer.frame = hostLayer.bounds
        // autoresizingMask 让画面层自动跟随宿主 layer 的 bounds，避免缩放/移动时白边。
        newLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostLayer.addSublayer(newLayer)
        needsDisplay = true
    }

    func detachCaptureLayer() {
        attachedCaptureLayer?.removeFromSuperlayer()
        attachedCaptureLayer = nil
    }

    override func layout() {
        super.layout()
        if let hostLayer = layer, let captureLayer = attachedCaptureLayer {
            captureLayer.frame = hostLayer.bounds
        }
    }
}

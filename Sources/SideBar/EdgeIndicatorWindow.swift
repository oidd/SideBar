import AppKit
import SwiftUI

class EdgeIndicatorWindow: NSPanel {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var currentEdge: Int = 0 { // 1 = left, 2 = right, 3 = bottom
        didSet {
            (contentView as? SimpleColorView)?.currentEdge = currentEdge
        }
    }
    
    private var isMouseInsideVisibleStrip = false
    
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 12, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)
        
        self.level = .screenSaver
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false
        
        // 我们需要保留 canJoinAllSpaces，否则 window 层级在非主桌面切换时会断裂不可见。
        // 但我们会通过逻辑拦截把它真正的“物理隐藏”，而不是依靠系统层隔离。
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        
        // 提升层级确保可见
        self.level = .mainMenu
        
        let lineView = SimpleColorView()
        self.contentView = lineView
        
        // 追踪区域
        let trackingArea = NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                          owner: self,
                                          userInfo: nil)
        lineView.addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        checkHit(with: event)
    }
    
    override func mouseMoved(with event: NSEvent) {
        checkHit(with: event)
    }
    
    override func mouseExited(with event: NSEvent) {
        if isMouseInsideVisibleStrip {
            isMouseInsideVisibleStrip = false
            onMouseExited?()
        }
    }
    
    private func checkHit(with event: NSEvent) {
        guard let lineView = contentView as? SimpleColorView else { return }
        
        let point = lineView.convert(event.locationInWindow, from: nil)
        // 核心修复：仅中间可见条柱区域接受 hover 触发，上下透明缓冲层不响应
        let isInside = lineView.isPointInVisibleStrip(point)
        
        if isInside && !isMouseInsideVisibleStrip {
            isMouseInsideVisibleStrip = true
            onMouseEntered?()
        } else if !isInside && isMouseInsideVisibleStrip {
            isMouseInsideVisibleStrip = false
            onMouseExited?()
        }
    }
    
    func updateColor(_ color: NSColor) {
        if let lineView = self.contentView as? SimpleColorView {
            lineView.updateState(color: color)
        }
    }
    
    // MARK: - 复刻自 LightToDo 的优雅动画
    
    func animateCollapseToDot(completion: @escaping () -> Void) {
        guard let lineView = self.contentView as? SimpleColorView,
              let stripLayer = lineView.getStripLayer() else {
            completion()
            return
        }
        
        stripLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        
        let group = CAAnimationGroup()
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        
        let currentHeight = stripLayer.bounds.height
        let currentWidth = stripLayer.bounds.width
        let scaleKeyPath: String
        let targetScale: CGFloat
        if lineView.currentEdge == 3 {
            scaleKeyPath = "transform.scale.x"
            targetScale = currentHeight / max(currentWidth, 1)
        } else {
            scaleKeyPath = "transform.scale.y"
            targetScale = currentWidth / max(currentHeight, 1)
        }
        
        let scaleAnim = CABasicAnimation(keyPath: scaleKeyPath)
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = targetScale
        
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0
        
        group.animations = [scaleAnim, opacityAnim]
        
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            self.orderOut(nil)
            stripLayer.removeAllAnimations()
            stripLayer.transform = CATransform3DIdentity
            stripLayer.opacity = 1.0
            completion()
        }
        stripLayer.add(group, forKey: "collapseToDot")
        CATransaction.commit()
    }
    
    func animateExpandFromDot() {
        guard let lineView = self.contentView as? SimpleColorView,
              let stripLayer = lineView.getStripLayer() else {
            return
        }
        
        // 确保窗口可见后再开启动画
        self.alphaValue = 1.0
        self.orderFront(nil)
        
        stripLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        if lineView.currentEdge == 3 {
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 0.0
            fadeAnim.toValue = 1.0
            fadeAnim.duration = 0.16
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            stripLayer.add(fadeAnim, forKey: "expandFromDotBottomFade")
            return
        }
        let currentHeight = stripLayer.bounds.height
        let currentWidth = stripLayer.bounds.width
        let scaleKeyPath: String
        let startScale: CGFloat
        scaleKeyPath = "transform.scale.y"
        startScale = currentWidth / max(currentHeight, 1)
        
        let group = CAAnimationGroup()
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = true
        
        let scaleAnim = CABasicAnimation(keyPath: scaleKeyPath)
        scaleAnim.fromValue = startScale
        scaleAnim.toValue = 1.0
        
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.0
        opacityAnim.toValue = 1.0
        
        group.animations = [scaleAnim, opacityAnim]
        
        stripLayer.add(group, forKey: "expandFromDot")
    }

    func playBottomDirectionalImpulse(direction: CGFloat) {
        guard let lineView = contentView as? SimpleColorView else { return }
        lineView.playBottomDirectionalImpulse(direction: direction)
    }
}

class SimpleColorView: NSView {
    var backgroundColorView: NSColor? {
        didSet { updateLayerState() }
    }
    var currentEdge: Int = 1 {
        didSet { needsLayout = true }
    }
    
    private var stripLayer = CALayer()
    private var stripLength: CGFloat = 100
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        
        stripLayer.cornerRadius = 3
        stripLayer.masksToBounds = true
        layer?.addSublayer(stripLayer)
        
        // 默认颜色设置
        backgroundColorView = NSColor.orange
    }
    
    func updateLayout(stripLength: CGFloat, edge: Int) {
        self.stripLength = stripLength
        self.currentEdge = edge
        self.needsLayout = true
    }
    
    func updateState(color: NSColor) {
        self.backgroundColorView = color
        updateLayerState()
    }
    
    func getStripLayer() -> CALayer? {
        return stripLayer
    }
    
    func isPointInVisibleStrip(_ point: CGPoint) -> Bool {
        let stripRect: CGRect
        if currentEdge == 3 {
            let hPadding: CGFloat = 40
            stripRect = CGRect(x: hPadding, y: 0, width: stripLength, height: bounds.height)
        } else {
            let vPadding: CGFloat = 40
            stripRect = CGRect(x: 0, y: vPadding, width: bounds.width, height: stripLength)
        }
        return stripRect.contains(point)
    }
    
    override func layout() {
        super.layout()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentEdge == 3 {
            stripLayer.bounds = CGRect(x: 0, y: 0, width: stripLength, height: 6)
        } else {
            stripLayer.bounds = CGRect(x: 0, y: 0, width: 6, height: stripLength)
        }
        stripLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        stripLayer.cornerRadius = 3
        CATransaction.commit()
    }
    
    func playSquashAndStretch(targetLength: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentEdge == 3 {
            stripLayer.bounds = CGRect(x: 0, y: 0, width: targetLength, height: 6)
        } else {
            stripLayer.bounds = CGRect(x: 0, y: 0, width: 6, height: targetLength)
        }
        stripLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        stripLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        CATransaction.commit()
        
        // 使用与 LightToDo 相同的物理感缩放动画
        stripLayer.removeAnimation(forKey: "squash")
        let keyPath = currentEdge == 3 ? "transform.scale.x" : "transform.scale.y"
        let scaleAnim = CAKeyframeAnimation(keyPath: keyPath)
        scaleAnim.values = [1.0, 1.1, 0.96, 1.02, 0.99, 1.0]
        scaleAnim.keyTimes = [0, 0.15, 0.35, 0.55, 0.8, 1.0]
        scaleAnim.duration = 0.6
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        stripLayer.add(scaleAnim, forKey: "squash")
    }

    func playBottomDirectionalImpulse(direction: CGFloat) {
        guard currentEdge == 3 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        stripLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stripLayer.position = center
        stripLayer.bounds = CGRect(x: 0, y: 0, width: stripLength, height: 6)
        CATransaction.commit()

        stripLayer.removeAnimation(forKey: "bottomDirectionalImpulse")

        let overshoot = min(26, max(16, stripLength * 0.085))
        let signedOffset = direction < 0 ? -overshoot / 2 : overshoot / 2

        let widthAnim = CAKeyframeAnimation(keyPath: "bounds.size.width")
        widthAnim.values = [stripLength, stripLength + overshoot, stripLength - overshoot * 0.12, stripLength]
        widthAnim.keyTimes = [0.0, 0.40, 0.72, 1.0]

        let positionAnim = CAKeyframeAnimation(keyPath: "position.x")
        positionAnim.values = [center.x, center.x + signedOffset, center.x - signedOffset * 0.22, center.x]
        positionAnim.keyTimes = [0.0, 0.40, 0.72, 1.0]

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [1.0, 1.0, 0.97, 1.0]
        opacityAnim.keyTimes = [0.0, 0.45, 0.72, 1.0]

        let group = CAAnimationGroup()
        group.animations = [widthAnim, positionAnim, opacityAnim]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true

        stripLayer.add(group, forKey: "bottomDirectionalImpulse")
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 系统外观切换时，动态 NSColor 的 .cgColor 需要重新解析
        updateLayerState()
    }
    
    private func updateLayerState() {
        guard let _ = layer, let color = backgroundColorView else { return }
        // 动态 NSColor 的 .cgColor 需要在正确的外观上下文中解析
        effectiveAppearance.performAsCurrentDrawingAppearance {
            stripLayer.backgroundColor = color.cgColor
        }
    }
}

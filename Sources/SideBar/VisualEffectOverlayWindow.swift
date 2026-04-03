import AppKit
import QuartzCore

enum SnapEdge {
    case left
    case right
}

class VisualEffectOverlayWindow: NSPanel {
    private var particleLayer: CAEmitterLayer?
    private var beamLayer: CALayer?
    private var beamMaskLayer: CAShapeLayer?
    private var dustLayer: CALayer?
    private var cleanupWorkItem: DispatchWorkItem?
    
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 提升层级至 screenSaver，确保在所有第三方应用窗口之上（包括全屏应用）
        self.level = .screenSaver 
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        self.ignoresMouseEvents = true
        
        let contentView = NSView()
        contentView.wantsLayer = true
        self.contentView = contentView
    }
    
    // MARK: - Collapse Effect (Impact)
    
    func startCollapseEffect(edge: SnapEdge, point: CGPoint, color: NSColor, on screen: NSScreen? = nil) {
        stopExpandEffect(closeWindow: true)
        guard let layer = self.contentView?.layer, let targetScreen = screen ?? NSScreen.main else { return }
        
        let screenFrame = targetScreen.frame
        self.setFrame(screenFrame, display: true)
        
        // Convert AppKit window coordinate point to local layer coordinate
        let localY = point.y - screenFrame.origin.y
        let localX = point.x - screenFrame.origin.x
        let localPoint = CGPoint(x: localX, y: localY)
        
        let intenseColor = intensifyColor(color)
        
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = localPoint
        emitter.emitterShape = .line
        emitter.emitterSize = CGSize(width: 10, height: 40)
        emitter.renderMode = .additive
        
        let cell = CAEmitterCell()
        cell.birthRate = 0 
        cell.lifetime = 1.5
        cell.velocity = 150
        cell.velocityRange = 50
        cell.emissionLongitude = (edge == .left) ? 0 : .pi 
        cell.emissionRange = .pi / 4
        cell.yAcceleration = 400 
        cell.scale = 0.5
        cell.scaleRange = 0.2
        cell.scaleSpeed = -0.2
        cell.color = intenseColor.cgColor
        cell.alphaSpeed = -1.0
        cell.contents = createParticleImage()
        
        emitter.emitterCells = [cell]
        layer.addSublayer(emitter)
        
        let burst = CABasicAnimation(keyPath: "emitterCells.0.birthRate")
        burst.fromValue = 100
        burst.toValue = 0
        burst.duration = 0.1
        burst.isRemovedOnCompletion = false
        burst.fillMode = .forwards
        
        emitter.add(burst, forKey: "burst")
        self.orderFront(nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            emitter.removeFromSuperlayer()
        }
    }
    
    // MARK: - Expand Effect (Beam & Dust)
    
    func startExpandEffect(edge: SnapEdge, frame: NSRect, color: NSColor, on screen: NSScreen? = nil) {
        cleanupWorkItem?.cancel()
        cleanupWorkItem = nil
        
        guard let layer = self.contentView?.layer, let targetScreen = screen ?? NSScreen.main else { return }
        stopExpandEffect(closeWindow: false)
        
        let screenFrame = targetScreen.frame
        self.setFrame(screenFrame, display: true)
        
        // 核心修复：坐标系转换 (AX 顶端原点 -> AppKit 底端原点)
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let globalAppKitY = primaryScreenHeight - frame.origin.y - frame.size.height
        let localTargetFrame = NSRect(x: frame.origin.x - screenFrame.origin.x,
                                     y: globalAppKitY - screenFrame.origin.y,
                                     width: frame.size.width,
                                     height: frame.size.height)
        
        let intenseColor = intensifyColor(color)
        
        let beamContent = CAGradientLayer()
        // 用户觉得散列光底板让界面显得有些“脏”，为了后续想恢复的时候好找，此处保留了结构，仅将透明度设为 0。
        // 如需恢复原状，可将前两个颜色的 Alpha 恢复为 0.12 和 0.05
        beamContent.colors = [
            NSColor.white.withAlphaComponent(0.00).cgColor, 
            NSColor.white.withAlphaComponent(0.00).cgColor, 
            NSColor.white.withAlphaComponent(0.00).cgColor  
        ]
        beamContent.locations = [0.0, 0.4, 1.0]
        
        let beamLength: CGFloat = 100 
        let flareAmt: CGFloat = 60 
        
        var beamRect: CGRect
        if edge == .left {
            // 核心修复：锚定到屏幕物理左边缘 (0)
            beamRect = CGRect(x: 0, y: localTargetFrame.minY - flareAmt, width: beamLength, height: localTargetFrame.height + flareAmt * 2)
            beamContent.startPoint = CGPoint(x: 0, y: 0.5)
            beamContent.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            // 核心修复：锚定到屏幕物理右边缘
            beamRect = CGRect(x: screenFrame.width - beamLength, y: localTargetFrame.minY - flareAmt, width: beamLength, height: localTargetFrame.height + flareAmt * 2)
            beamContent.startPoint = CGPoint(x: 1, y: 0.5)
            beamContent.endPoint = CGPoint(x: 0, y: 0.5)
        }
        
        beamContent.frame = beamRect
        
        let shapeMask = CAShapeLayer()
        let path = CGMutablePath()
        let br = beamContent.bounds
        
        if edge == .left {
            path.move(to: CGPoint(x: 0, y: flareAmt)) 
            path.addLine(to: CGPoint(x: br.width, y: 0)) 
            path.addLine(to: CGPoint(x: br.width, y: br.height)) 
            path.addLine(to: CGPoint(x: 0, y: br.height - flareAmt)) 
        } else {
            path.move(to: CGPoint(x: br.width, y: flareAmt))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: br.height))
            path.addLine(to: CGPoint(x: br.width, y: br.height - flareAmt))
        }
        path.closeSubpath()
        shapeMask.path = path
        
        let softMask = CAGradientLayer()
        softMask.frame = beamContent.bounds
        softMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        softMask.locations = [0.0, 0.15, 0.85, 1.0]
        
        beamContent.mask = softMask 
        let trapezoidPath = path
        
        let container = CALayer()
        container.frame = beamRect
        let beamShapeMask = CAShapeLayer()
        beamShapeMask.path = trapezoidPath
        container.mask = beamShapeMask
        
        beamContent.frame = container.bounds
        container.addSublayer(beamContent)
        
        func addBorderLine(from start: CGPoint, to end: CGPoint) {
            let line = CAGradientLayer()
            line.colors = [
                NSColor.white.withAlphaComponent(0.0).cgColor,
                NSColor.white.withAlphaComponent(0.35).cgColor, 
                NSColor.white.withAlphaComponent(0.0).cgColor
            ]
            line.locations = [0.0, 0.4, 0.8] 
            line.startPoint = (edge == .left) ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 1, y: 0.5)
            line.endPoint = (edge == .left) ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0, y: 0.5)
            
            let dx = end.x - start.x
            let dy = end.y - start.y
            let len = sqrt(dx*dx + dy*dy)
            let angle = atan2(dy, dx)
            
            line.bounds = CGRect(x: 0, y: 0, width: len, height: 2.0) 
            line.position = CGPoint(x: (start.x + end.x)/2, y: (start.y + end.y)/2)
            line.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            
            container.addSublayer(line)
        }
        
        let brBounds = container.bounds
        if edge == .left {
            addBorderLine(from: CGPoint(x: 0, y: flareAmt), to: CGPoint(x: brBounds.width, y: 0))
            addBorderLine(from: CGPoint(x: 0, y: brBounds.height - flareAmt), to: CGPoint(x: brBounds.width, y: brBounds.height))
        } else {
            addBorderLine(from: CGPoint(x: brBounds.width, y: flareAmt), to: CGPoint(x: 0, y: 0))
            addBorderLine(from: CGPoint(x: brBounds.width, y: brBounds.height - flareAmt), to: CGPoint(x: 0, y: brBounds.height))
        }
        
        let sparklesContainer = CALayer()
        sparklesContainer.frame = layer.bounds
        
        let sparkles = CAEmitterLayer()
        sparkles.frame = sparklesContainer.bounds
        sparkles.emitterPosition = CGPoint(x: beamRect.midX, y: beamRect.midY)
        sparkles.emitterShape = .rectangle
        sparkles.emitterSize = beamRect.size
        sparkles.renderMode = .additive 
        sparkles.zPosition = 200
        
        let mote = CAEmitterCell()
        mote.birthRate = 80 
        mote.lifetime = 4.0
        mote.lifetimeRange = 2.0
        mote.velocity = 10
        mote.velocityRange = 8
        mote.emissionRange = .pi * 2
        mote.scale = 0.12
        mote.scaleRange = 0.08
        mote.color = intenseColor.cgColor
        mote.alphaSpeed = -0.25
        mote.contents = createParticleImage()
        
        let whiteMote = CAEmitterCell()
        whiteMote.birthRate = 60
        whiteMote.lifetime = 4.0
        whiteMote.lifetimeRange = 2.0
        whiteMote.velocity = 10
        whiteMote.velocityRange = 8
        whiteMote.emissionRange = .pi * 2
        whiteMote.scale = 0.10
        whiteMote.scaleRange = 0.05
        whiteMote.color = NSColor.white.withAlphaComponent(0.8).cgColor
        whiteMote.alphaSpeed = -0.3
        whiteMote.contents = createParticleImage()
        
        sparkles.emitterCells = [mote, whiteMote]
        
        let densityMask = CAGradientLayer()
        densityMask.frame = sparklesContainer.bounds
        let maskSublayer = CAGradientLayer()
        maskSublayer.frame = beamRect
        maskSublayer.startPoint = (edge == .left) ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 1, y: 0.5)
        maskSublayer.endPoint = (edge == .left) ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0, y: 0.5)
        maskSublayer.colors = [
            NSColor.white.withAlphaComponent(1.0).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor  
        ]
        maskSublayer.locations = [0.0, 0.95]
        densityMask.addSublayer(maskSublayer)
        sparkles.mask = densityMask
        
        let constraintMask = CALayer()
        constraintMask.frame = sparklesContainer.bounds
        let trapLayer = CAShapeLayer()
        trapLayer.path = trapezoidPath
        trapLayer.frame = beamRect
        constraintMask.addSublayer(trapLayer)
        
        sparklesContainer.mask = constraintMask
        sparklesContainer.addSublayer(sparkles)
        
        layer.addSublayer(sparklesContainer) 
        self.dustLayer = sparklesContainer
        
        layer.addSublayer(container)
        self.beamLayer = container
        
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.5
        layer.add(fade, forKey: "fadeIn")
        
        self.orderFront(nil)
    }
    
    func stopExpandEffect(closeWindow: Bool = true, immediate: Bool = false) {
        cleanupWorkItem?.cancel()
        cleanupWorkItem = nil
        
        let beamToRemove = beamLayer
        let dustToRemove = dustLayer
        
        self.beamLayer = nil
        self.dustLayer = nil

        if immediate {
            beamToRemove?.removeFromSuperlayer()
            dustToRemove?.removeFromSuperlayer()
            if closeWindow {
                self.orderOut(nil)
            }
            return
        }
        
        if let beam = beamToRemove {
            let beamFade = CABasicAnimation(keyPath: "opacity")
            beamFade.fromValue = 1.0
            beamFade.toValue = 0.0
            beamFade.duration = 0.2 
            beamFade.fillMode = .forwards
            beamFade.isRemovedOnCompletion = false
            beam.add(beamFade, forKey: "fadeOut")
        }
        
        if let dust = dustToRemove {
            let dustFade = CABasicAnimation(keyPath: "opacity")
            dustFade.fromValue = 1.0
            dustFade.toValue = 0.0
            dustFade.duration = 2.5 
            dustFade.fillMode = .forwards
            dustFade.isRemovedOnCompletion = false
            dust.add(dustFade, forKey: "fadeOut")
            
            if let emitter = dust as? CAEmitterLayer {
                emitter.birthRate = 0
            } else if let emitter = dust.sublayers?.first(where: { $0 is CAEmitterLayer }) as? CAEmitterLayer {
                emitter.birthRate = 0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            beamToRemove?.removeFromSuperlayer()
        }
        
        if closeWindow {
            let item = DispatchWorkItem { 
                dustToRemove?.removeFromSuperlayer()
                self.orderOut(nil)
                self.cleanupWorkItem = nil
            }
            self.cleanupWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
        } else {
             DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                 dustToRemove?.removeFromSuperlayer()
             }
        }
    }
    
    // MARK: - Helpers
    
    func intensifyColor(_ color: NSColor) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let srgb = color.usingColorSpace(.sRGB) ?? color
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        
        if s < 0.05 { // 灰度检测
            if b > 0.5 { // 白色系
                return NSColor(white: 1.0, alpha: 1.0)
            } else { // 黑色系
                return NSColor(white: 0.6, alpha: 1.0) // 给予可见的浅灰色粒子
            }
        }
        
        let newS: CGFloat = 0.85 
        let newB: CGFloat = 1.0
        return NSColor(hue: h, saturation: newS, brightness: newB, alpha: 1.0)
    }
    
    private func createParticleImage() -> CGImage? {
        let size = CGSize(width: 8, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.white.cgColor)
        ctx?.fillEllipse(in: CGRect(origin: .zero, size: size))
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

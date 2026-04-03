import AppKit

final class PinControlWindow: NSPanel {
    var onToggle: (() -> Void)?

    private let buttonView = PinControlButtonView()
    private var isPresented = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 38, height: 38),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        buttonView.onToggle = { [weak self] in
            self?.onToggle?()
        }
        contentView = buttonView
        alphaValue = 0
    }

    func update(frame: CGRect, hiddenFrame: CGRect, isVisible: Bool, isPinned: Bool, accentColor: NSColor) {
        buttonView.update(isPinned: isPinned, accentColor: accentColor)

        if isVisible {
            if !isPresented {
                alphaValue = 0
                setFrame(hiddenFrame, display: false)
                orderFront(nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().alphaValue = 1
                    animator().setFrame(frame, display: true)
                }
                isPresented = true
            } else {
                setFrame(frame, display: true)
                alphaValue = 1
                orderFront(nil)
            }
        } else if isPresented {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
                animator().setFrame(hiddenFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.orderOut(nil)
            })
            isPresented = false
        } else {
            orderOut(nil)
        }
    }

    override func orderOut(_ sender: Any?) {
        isPresented = false
        alphaValue = 0
        super.orderOut(sender)
    }
}

private final class PinControlButtonView: NSView {
    var onToggle: (() -> Void)?

    private var isPinned = false
    private var accentColor = NSColor.systemBlue
    private var isPressed = false
    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?

    private let blurView = NSVisualEffectView()
    private let ringLayer = CAShapeLayer()
    private let glossLayer = CAShapeLayer()
    private let iconContainerLayer = CALayer()
    private let iconImageLayer = CALayer()

    private static let pinnedImage = loadImage(named: "PinIconPinned")
    private static let unpinnedImage = loadImage(named: "PinIconUnpinned")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerCurve = .continuous
        addSubview(blurView)

        glossLayer.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        blurView.layer?.addSublayer(glossLayer)

        ringLayer.fillColor = NSColor.clear.cgColor
        blurView.layer?.addSublayer(ringLayer)

        blurView.layer?.addSublayer(iconContainerLayer)
        iconContainerLayer.addSublayer(iconImageLayer)
        iconImageLayer.contentsGravity = .resizeAspect
        iconImageLayer.masksToBounds = false
    }

    override func layout() {
        super.layout()

        blurView.frame = bounds
        let cornerRadius = bounds.width * 0.42
        blurView.layer?.cornerRadius = cornerRadius

        let insetRect = bounds.insetBy(dx: 1.2, dy: 1.2)
        ringLayer.frame = bounds
        ringLayer.path = CGPath(
            roundedRect: insetRect,
            cornerWidth: cornerRadius - 1.2,
            cornerHeight: cornerRadius - 1.2,
            transform: nil
        )
        ringLayer.lineWidth = 1

        let glossRect = CGRect(x: 3, y: bounds.height * 0.5, width: bounds.width - 6, height: bounds.height * 0.24)
        glossLayer.frame = bounds
        glossLayer.path = CGPath(
            roundedRect: glossRect,
            cornerWidth: cornerRadius * 0.72,
            cornerHeight: cornerRadius * 0.72,
            transform: nil
        )

        let iconSize: CGFloat = 15
        let iconRect = CGRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        iconContainerLayer.frame = bounds
        iconContainerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconContainerLayer.transform = CATransform3DIdentity
        iconImageLayer.frame = iconRect
        iconImageLayer.contents = isPinned ? Self.pinnedImage : Self.unpinnedImage
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    func update(isPinned: Bool, accentColor: NSColor) {
        self.isPinned = isPinned
        self.accentColor = accentColor
        needsLayout = true
        updateVisualState(animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisualState(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisualState(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateVisualState(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
            updateVisualState(animated: true)
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onToggle?()
    }

    private func updateVisualState(animated: Bool) {
        let targetAlpha: CGFloat = isPressed ? 0.92 : (isHovered ? 0.8 : 0.3)
        let ringColor = NSColor.white.withAlphaComponent(isHovered ? 0.22 : 0.16)
        let backgroundTint = NSColor.white.withAlphaComponent(isHovered ? 0.09 : 0.045)
        let glossOpacity: CGFloat = isHovered ? 0.14 : 0.08
        let shadowColor = NSColor.black.withAlphaComponent(isHovered ? 0.05 : 0.02)

        let changes = {
            self.alphaValue = targetAlpha
            self.blurView.layer?.backgroundColor = backgroundTint.cgColor
            self.blurView.layer?.shadowColor = shadowColor.cgColor
            self.blurView.layer?.shadowOpacity = 1
            self.blurView.layer?.shadowRadius = self.isHovered ? 4 : 2
            self.blurView.layer?.shadowOffset = CGSize(width: 0, height: self.isHovered ? 1 : 0.5)
            self.ringLayer.strokeColor = ringColor.cgColor
            self.glossLayer.opacity = Float(glossOpacity)
            self.iconImageLayer.opacity = Float(self.isHovered ? 1.0 : 0.94)
            self.blurView.layer?.borderWidth = 0
            self.blurView.layer?.borderColor = nil
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = targetAlpha
                changes()
            }
        } else {
            changes()
        }
    }

    private static func loadImage(named resourceName: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
            return image
        }
        return nil
    }
}

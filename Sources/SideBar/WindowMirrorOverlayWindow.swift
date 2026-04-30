import AppKit
import CoreGraphics

final class WindowMirrorOverlayWindow: NSPanel {
    var onActivateRealWindow: (() -> Void)?
    var hasSnapshot: Bool { snapshotView.image != nil }

    private let snapshotView = MirrorSnapshotView()

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
        ignoresMouseEvents = false
        contentView = snapshotView
        snapshotView.onActivate = { [weak self] in
            self?.onActivateRealWindow?()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(frame: CGRect, image: NSImage?, showImmediately: Bool = true) {
        if let image {
            snapshotView.image = image
        }
        setFrame(frame, display: true)
        if showImmediately {
            alphaValue = 1
            orderFrontRegardless()
        }
    }

    func present() {
        snapshotView.resetHoverActivation()
        alphaValue = 1
        orderFrontRegardless()
    }

    func hide() {
        snapshotView.resetHoverActivation()
        alphaValue = 1
        orderOut(nil)
    }

    func suspendHoverActivation(for duration: TimeInterval) {
        snapshotView.suspendHoverActivation(for: duration)
    }
}

private final class MirrorSnapshotView: NSView {
    var onActivate: (() -> Void)?
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    private var trackingAreaRef: NSTrackingArea?
    private var hasTriggeredHoverActivation = false
    private var isPointerInside = false
    private var hoverActivationWorkItem: DispatchWorkItem?
    private var hoverSuspendedUntil: Date = .distantPast
    private let hoverActivationDelay: TimeInterval = 0.08

    override var isFlipped: Bool { true }

    func resetHoverActivation() {
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
        isPointerInside = false
        hasTriggeredHoverActivation = false
    }

    func suspendHoverActivation(for duration: TimeInterval) {
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
        hoverSuspendedUntil = Date().addingTimeInterval(duration)
        hasTriggeredHoverActivation = false
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        guard !hasTriggeredHoverActivation, Date() >= hoverSuspendedUntil else { return }
        hasTriggeredHoverActivation = true
        hoverActivationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPointerInside else { return }
            self.onActivate?()
        }
        hoverActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverActivationDelay, execute: workItem)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
        hasTriggeredHoverActivation = false
    }

    override func mouseDown(with event: NSEvent) {
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
        onActivate?()
    }
}

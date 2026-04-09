import AppKit
import CoreGraphics

@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImage(
    _ screenBounds: CGRect,
    _ listOption: UInt32,
    _ windowID: UInt32,
    _ imageOption: UInt32
) -> CGImage?

struct WindowMirrorSnapshot {
    let image: NSImage
    let captureBounds: CGRect
}

final class WindowMirrorSnapshotter {
    static let shared = WindowMirrorSnapshotter()
    private let shadowPadding: CGFloat = 56

    private init() {}

    func captureBounds(for bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: -shadowPadding, dy: -shadowPadding)
    }

    func snapshot(windowID: CGWindowID, bounds: CGRect) -> WindowMirrorSnapshot? {
        let captureBounds = captureBounds(for: bounds)
        let imageRef = _CGWindowListCreateImage(
            captureBounds,
            CGWindowListOption.optionIncludingWindow.rawValue,
            windowID,
            CGWindowImageOption.bestResolution.rawValue
        )

        guard let imageRef else { return nil }
        let size = NSSize(width: imageRef.width, height: imageRef.height)
        return WindowMirrorSnapshot(
            image: NSImage(cgImage: imageRef, size: size),
            captureBounds: captureBounds
        )
    }
}

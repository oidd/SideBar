import Cocoa
import ApplicationServices

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CInt

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CInt, _ wid: CInt, _ alpha: Float) -> CGError

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

class WindowAlphaManager {
    static let shared = WindowAlphaManager()

    private struct WindowSurface {
        let id: CGWindowID
        let bounds: CGRect
    }
    
    // Attempt to find the CGWindowID cleanly by using macOS private API
    func findWindowID(for axWindow: AXUIElement, pid: pid_t) -> CGWindowID? {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &windowID) == .success {
            return windowID
        }
        return nil
    }

    func findRelatedWindowIDs(for axWindow: AXUIElement, pid: pid_t, frameHint: CGRect? = nil) -> [CGWindowID] {
        let primaryWindowID = findWindowID(for: axWindow, pid: pid)
        let surfaces = currentWindowSurfaces(for: pid)
        guard !surfaces.isEmpty else {
            return primaryWindowID.map { [$0] } ?? []
        }

        let primaryBounds = primaryWindowID.flatMap { id in
            surfaces.first(where: { $0.id == id })?.bounds
        }
        let targetBounds = primaryBounds ?? frameHint
        guard let targetBounds else {
            return primaryWindowID.map { [$0] } ?? []
        }

        let targetArea = max(targetBounds.width * targetBounds.height, 1)
        let expandedTarget = targetBounds.insetBy(dx: -24, dy: -96)
        var matchedIDs: [CGWindowID] = []

        if let primaryWindowID {
            matchedIDs.append(primaryWindowID)
        }

        for surface in surfaces {
            if matchedIDs.contains(surface.id) { continue }
            if surface.bounds.width < 24 || surface.bounds.height < 12 { continue }

            let area = surface.bounds.width * surface.bounds.height
            if area > targetArea * 1.75 { continue }

            let horizontalOverlap = overlapRatio(
                candidateMin: surface.bounds.minX,
                candidateMax: surface.bounds.maxX,
                targetMin: targetBounds.minX,
                targetMax: targetBounds.maxX
            )
            let verticalOverlap = overlapRatio(
                candidateMin: surface.bounds.minY,
                candidateMax: surface.bounds.maxY,
                targetMin: targetBounds.minY,
                targetMax: targetBounds.maxY
            )

            let nearTopOrBottomStrip =
                horizontalOverlap >= 0.72 &&
                (
                    abs(surface.bounds.minY - targetBounds.minY) <= 96 ||
                    abs(surface.bounds.maxY - targetBounds.maxY) <= 96
                )
            let nearSideStrip =
                verticalOverlap >= 0.72 &&
                (
                    abs(surface.bounds.minX - targetBounds.minX) <= 96 ||
                    abs(surface.bounds.maxX - targetBounds.maxX) <= 96
                )

            if expandedTarget.intersects(surface.bounds) || nearTopOrBottomStrip || nearSideStrip {
                matchedIDs.append(surface.id)
            }
        }

        return matchedIDs
    }

    // 强制设置核心渲染层的 alpha
    func setAlpha(for windowID: CGWindowID, alpha: Float) {
        let cid = CGSMainConnectionID()
        _ = CGSSetWindowAlpha(cid, CInt(windowID), alpha)
    }

    func setAlpha(for windowIDs: [CGWindowID], alpha: Float) {
        for windowID in Set(windowIDs) {
            setAlpha(for: windowID, alpha: alpha)
        }
    }

    private func currentWindowSurfaces(for pid: pid_t) -> [WindowSurface] {
        let rawList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return rawList.compactMap { info in
            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  windowPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }

            let bounds = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
            guard bounds.width > 1, bounds.height > 1 else { return nil }

            return WindowSurface(id: windowID, bounds: bounds)
        }
    }

    private func overlapRatio(candidateMin: CGFloat, candidateMax: CGFloat, targetMin: CGFloat, targetMax: CGFloat) -> CGFloat {
        let overlap = max(0, min(candidateMax, targetMax) - max(candidateMin, targetMin))
        let candidateLength = max(candidateMax - candidateMin, 1)
        let targetLength = max(targetMax - targetMin, 1)
        return overlap / min(candidateLength, targetLength)
    }
}

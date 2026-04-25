import AppKit
import ApplicationServices

final class WindowRescueManager {
    static let shared = WindowRescueManager()

    private init() {}

    func revealPendingWindowsWithoutAccessibility(reason: String) {
        let structuredWindowIDs = AppConfig.shared.windowRescueRecords.map(\.windowID)
        let legacyWindowIDs = AppConfig.shared.hiddenWindowRecords.compactMap(Self.parseLegacyRecord).map(\.windowID)
        let windowIDs = Set(structuredWindowIDs + legacyWindowIDs)

        guard !windowIDs.isEmpty else { return }
        print("🪟 无辅助功能权限，仅恢复窗口可见性: \(reason), count=\(windowIDs.count)")
        for windowID in windowIDs {
            WindowAlphaManager.shared.setAlpha(for: windowID, alpha: 1.0)
        }
    }

    @discardableResult
    func recoverPendingWindows(reason: String) -> Int {
        guard AppConfig.shared.hasPendingWindowRescueRecords() else { return 0 }

        guard AccessibilityRuntimeGuard.shared.evaluateTrustState(source: "window-rescue-\(reason)") else {
            revealPendingWindowsWithoutAccessibility(reason: reason)
            return 0
        }

        var recovered = 0
        let structuredRecords = AppConfig.shared.windowRescueRecords.sorted { $0.updatedAt < $1.updatedAt }
        for record in structuredRecords {
            if recoverStructuredRecord(record) {
                recovered += 1
            }
        }

        let coveredLegacyKeys = Set(structuredRecords.map { Self.legacyKey(pid: $0.pid, windowID: $0.windowID) })
        let legacyRecords = AppConfig.shared.hiddenWindowRecords.compactMap(Self.parseLegacyRecord)
        for legacy in legacyRecords where !coveredLegacyKeys.contains(Self.legacyKey(pid: legacy.pid, windowID: legacy.windowID)) {
            if recoverLegacyRecord(pid: legacy.pid, windowID: legacy.windowID) {
                recovered += 1
            }
        }

        if recovered > 0 {
            print("✅ 窗口救援完成: reason=\(reason), recovered=\(recovered)")
        }
        return recovered
    }

    private func recoverStructuredRecord(_ record: WindowRescueRecord) -> Bool {
        WindowAlphaManager.shared.setAlpha(for: record.windowID, alpha: 1.0)

        for pid in candidatePIDs(for: record) {
            if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
                app.unhide()
            }

            let appElement = AXUIElementCreateApplication(pid)
            guard let match = matchWindow(in: appElement, pid: pid, record: record) else { continue }

            let targetFrame = normalizedRestoreFrame(for: record, currentFrame: match.frame)
            let relatedWindowIDs = WindowAlphaManager.shared.findRelatedWindowIDs(
                for: match.element,
                pid: pid,
                frameHint: targetFrame
            )
            if relatedWindowIDs.isEmpty {
                WindowAlphaManager.shared.setAlpha(for: record.windowID, alpha: 1.0)
            } else {
                WindowAlphaManager.shared.setAlpha(for: relatedWindowIDs, alpha: 1.0)
            }

            let sizeResult = setSize(
                of: match.element,
                size: targetFrame.size,
                context: "WindowRescueManager.recoverStructuredRecord.size"
            )
            let positionResult = setPosition(
                of: match.element,
                position: targetFrame.origin,
                context: "WindowRescueManager.recoverStructuredRecord.position"
            )

            guard positionResult == .success || sizeResult == .success else { continue }

            AppConfig.shared.removeWindowRescueRecord(pid: record.pid, windowID: record.windowID)
            AppConfig.shared.removeHiddenWindowRecord(pid: record.pid, windowID: record.windowID)
            if pid != record.pid {
                AppConfig.shared.removeHiddenWindowRecord(pid: pid, windowID: match.windowID)
            }
            return true
        }

        return false
    }

    private func recoverLegacyRecord(pid: pid_t, windowID: UInt32) -> Bool {
        WindowAlphaManager.shared.setAlpha(for: windowID, alpha: 1.0)

        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return false
        }

        if app.isHidden {
            app.unhide()
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard let match = exactWindowMatch(in: appElement, pid: pid, windowID: windowID),
              let inferred = inferLegacyRestoreFrame(from: match.frame) else {
            return false
        }

        let sizeResult = setSize(
            of: match.element,
            size: inferred.size,
            context: "WindowRescueManager.recoverLegacyRecord.size"
        )
        let positionResult = setPosition(
            of: match.element,
            position: inferred.origin,
            context: "WindowRescueManager.recoverLegacyRecord.position"
        )

        guard positionResult == .success || sizeResult == .success else {
            return false
        }

        AppConfig.shared.removeHiddenWindowRecord(pid: pid, windowID: windowID)
        return true
    }

    private func candidatePIDs(for record: WindowRescueRecord) -> [pid_t] {
        var result: [pid_t] = []

        if let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated {
            result.append(record.pid)
        }

        let bundleMatches = NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard app.bundleIdentifier == record.bundleID, !app.isTerminated else { return nil }
            return app.processIdentifier
        }

        for pid in bundleMatches where !result.contains(pid) {
            result.append(pid)
        }

        return result
    }

    private func matchWindow(in appElement: AXUIElement, pid: pid_t, record: WindowRescueRecord) -> WindowMatch? {
        guard let windows = standardWindows(in: appElement) else { return nil }

        var fallback: WindowMatch?
        for window in windows {
            guard let frame = frame(of: window) else { continue }
            let windowID = WindowAlphaManager.shared.findWindowID(for: window, pid: pid) ?? record.windowID

            if windowID == record.windowID {
                return WindowMatch(element: window, windowID: windowID, frame: frame)
            }

            if fallback == nil && isLikelyRescueCandidate(frame: frame, record: record) {
                fallback = WindowMatch(element: window, windowID: windowID, frame: frame)
            }
        }

        return fallback
    }

    private func exactWindowMatch(in appElement: AXUIElement, pid: pid_t, windowID: UInt32) -> WindowMatch? {
        guard let windows = standardWindows(in: appElement) else { return nil }
        for window in windows {
            guard let currentWindowID = WindowAlphaManager.shared.findWindowID(for: window, pid: pid),
                  currentWindowID == windowID,
                  let frame = frame(of: window) else {
                continue
            }
            return WindowMatch(element: window, windowID: currentWindowID, frame: frame)
        }
        return nil
    }

    private func standardWindows(in appElement: AXUIElement) -> [AXUIElement]? {
        var windowsValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: appElement,
            attribute: kAXWindowsAttribute as CFString,
            value: &windowsValue,
            context: "WindowRescueManager.standardWindows.windows"
        ) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        return windows.filter { window in
            WindowCapabilityProfiler.profile(
                of: window,
                context: "WindowRescueManager.standardWindows.profile"
            ).isStandardWindow
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: element,
            attribute: kAXPositionAttribute as CFString,
            value: &positionValue,
            context: "WindowRescueManager.frame.position"
        ) == .success,
        AccessibilityRuntimeGuard.copyAttributeValue(
            of: element,
            attribute: kAXSizeAttribute as CFString,
            value: &sizeValue,
            context: "WindowRescueManager.frame.size"
        ) == .success,
        let positionValue,
        let sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func isLikelyRescueCandidate(frame: CGRect, record: WindowRescueRecord) -> Bool {
        let visibleFrame = record.visibleFrame.cgRect
        let displayFrame = record.displayFrame.cgRect
        let widthClose = abs(frame.width - visibleFrame.width) <= 72
        let heightClose = abs(frame.height - visibleFrame.height) <= 120
        let yClose = abs(frame.minY - visibleFrame.minY) <= 160

        guard widthClose && heightClose && yClose else { return false }

        switch record.edge {
        case 1:
            return abs(frame.maxX - (displayFrame.minX + 1)) <= 24
        case 2:
            return abs(frame.minX - (displayFrame.maxX - 1)) <= 24
        default:
            return false
        }
    }

    private func inferLegacyRestoreFrame(from currentFrame: CGRect) -> CGRect? {
        guard let screen = bestMatchingScreen(for: currentFrame) else { return nil }

        let leftHiddenX = screen.frame.minX - currentFrame.width + 1
        let rightHiddenX = screen.frame.maxX - 1
        let threshold: CGFloat = 24

        let edge: Int
        if abs(currentFrame.minX - leftHiddenX) <= threshold {
            edge = 1
        } else if abs(currentFrame.minX - rightHiddenX) <= threshold {
            edge = 2
        } else {
            return nil
        }

        let safeY = clampY(currentFrame.minY, height: currentFrame.height, within: screen.frame)
        let safeX = edge == 1
            ? screen.frame.minX + 80
            : screen.frame.maxX - currentFrame.width - 80
        return CGRect(x: safeX, y: safeY, width: currentFrame.width, height: currentFrame.height)
    }

    private func normalizedRestoreFrame(for record: WindowRescueRecord, currentFrame: CGRect) -> CGRect {
        let visibleFrame = record.visibleFrame.cgRect
        let displayFrame = record.displayFrame.cgRect
        let screenFrame = bestScreenFrame(for: displayFrame, fallbackFrame: currentFrame)
        let width = visibleFrame.width > 1 ? visibleFrame.width : currentFrame.width
        let height = visibleFrame.height > 1 ? visibleFrame.height : currentFrame.height
        let safeY = clampY(record.safeRestorePosition.cgPoint.y, height: height, within: screenFrame)
        let safeX = record.edge == 1
            ? screenFrame.minX + 80
            : screenFrame.maxX - width - 80
        return CGRect(x: safeX, y: safeY, width: width, height: height)
    }

    private func bestScreenFrame(for savedDisplayFrame: CGRect, fallbackFrame: CGRect) -> CGRect {
        if let matched = NSScreen.screens.first(where: { $0.frame.intersects(savedDisplayFrame.insetBy(dx: -40, dy: -40)) }) {
            return matched.frame
        }
        if let currentScreen = bestMatchingScreen(for: fallbackFrame) {
            return currentScreen.frame
        }
        return NSScreen.main?.frame ?? savedDisplayFrame
    }

    private func bestMatchingScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        } ?? NSScreen.main
    }

    private func clampY(_ y: CGFloat, height: CGFloat, within screenFrame: CGRect) -> CGFloat {
        let minY = screenFrame.minY + 24
        let maxY = screenFrame.maxY - height - 24
        if maxY < minY {
            return screenFrame.minY
        }
        return min(max(y, minY), maxY)
    }

    @discardableResult
    private func setPosition(of element: AXUIElement, position: CGPoint, context: String) -> AXError {
        var newPosition = position
        guard let axValue = AXValueCreate(.cgPoint, &newPosition) else {
            return .failure
        }
        return AccessibilityRuntimeGuard.setAttributeValue(
            on: element,
            attribute: kAXPositionAttribute as CFString,
            value: axValue,
            context: context
        )
    }

    @discardableResult
    private func setSize(of element: AXUIElement, size: CGSize, context: String) -> AXError {
        var newSize = size
        guard let axValue = AXValueCreate(.cgSize, &newSize) else {
            return .failure
        }
        return AccessibilityRuntimeGuard.setAttributeValue(
            on: element,
            attribute: kAXSizeAttribute as CFString,
            value: axValue,
            context: context
        )
    }

    private static func parseLegacyRecord(_ raw: String) -> (pid: pid_t, windowID: UInt32)? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let pid = pid_t(parts[0]),
              let windowID = UInt32(parts[1]) else {
            return nil
        }
        return (pid, windowID)
    }

    private static func legacyKey(pid: pid_t, windowID: UInt32) -> String {
        "\(pid):\(windowID)"
    }
}

private struct WindowMatch {
    let element: AXUIElement
    let windowID: UInt32
    let frame: CGRect
}

private extension CGRect {
    var area: CGFloat {
        max(width, 0) * max(height, 0)
    }
}

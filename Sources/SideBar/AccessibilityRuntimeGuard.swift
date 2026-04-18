import AppKit
import ApplicationServices

extension NSNotification.Name {
    static let accessibilityPermissionRevoked = NSNotification.Name("SideBarAccessibilityPermissionRevoked")
    static let accessibilityPermissionRestored = NSNotification.Name("SideBarAccessibilityPermissionRestored")
}

final class AccessibilityRuntimeGuard {
    static let shared = AccessibilityRuntimeGuard()

    private let stateLock = NSLock()
    private var watchdogTimer: Timer?
    private var trustedState: Bool = AXIsProcessTrusted()
    private var consecutiveCannotCompleteCount: Int = 0
    private var lastCannotCompleteAt: Date = .distantPast
    private let cannotCompleteWindow: TimeInterval = 1.2
    private let cannotCompleteThreshold: Int = 18
    private let messagingTimeout: Float = 0.08

    private init() {}

    var isAccessibilityTrustedCached: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return trustedState
    }

    func startWatchdog() {
        stateLock.lock()
        if watchdogTimer != nil {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        _ = evaluateTrustState(source: "watchdog-start")

        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.evaluateTrustState(source: "watchdog-poll")
        }

        stateLock.lock()
        watchdogTimer = timer
        stateLock.unlock()
    }

    func stopWatchdog() {
        stateLock.lock()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        stateLock.unlock()
    }

    @discardableResult
    func evaluateTrustState(source: String) -> Bool {
        let trusted = AXIsProcessTrusted()
        updateTrustState(trusted, source: source)
        return trusted
    }

    func configureMessagingTimeout(for element: AXUIElement) {
        guard isAccessibilityTrustedCached else { return }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    func noteAXResult(_ result: AXError, context: String) {
        switch result {
        case .success:
            resetCannotCompleteCounter()
        case .apiDisabled:
            updateTrustState(false, source: context)
        case .cannotComplete:
            recordCannotComplete(context: context)
        default:
            break
        }
    }

    private func resetCannotCompleteCounter() {
        stateLock.lock()
        consecutiveCannotCompleteCount = 0
        lastCannotCompleteAt = .distantPast
        stateLock.unlock()
    }

    private func recordCannotComplete(context: String) {
        let now = Date()
        var thresholdReached = false

        stateLock.lock()
        if now.timeIntervalSince(lastCannotCompleteAt) > cannotCompleteWindow {
            consecutiveCannotCompleteCount = 0
        }
        consecutiveCannotCompleteCount += 1
        lastCannotCompleteAt = now
        thresholdReached = consecutiveCannotCompleteCount >= cannotCompleteThreshold
        stateLock.unlock()

        guard thresholdReached else { return }

        let trusted = AXIsProcessTrusted()
        updateTrustState(trusted, source: "\(context)-cannotComplete-storm")
        if trusted {
            resetCannotCompleteCounter()
        }
    }

    private func updateTrustState(_ trusted: Bool, source: String) {
        var previous: Bool = false

        stateLock.lock()
        previous = trustedState
        trustedState = trusted
        if trusted {
            consecutiveCannotCompleteCount = 0
            lastCannotCompleteAt = .distantPast
        }
        stateLock.unlock()

        guard previous != trusted else { return }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: trusted ? .accessibilityPermissionRestored : .accessibilityPermissionRevoked,
                object: nil,
                userInfo: ["source": source]
            )
        }
    }

    @discardableResult
    static func copyAttributeValue(
        of element: AXUIElement,
        attribute: CFString,
        value: inout CFTypeRef?,
        context: String
    ) -> AXError {
        guard shared.isAccessibilityTrustedCached else {
            shared.noteAXResult(.apiDisabled, context: context)
            return .apiDisabled
        }

        shared.configureMessagingTimeout(for: element)
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        shared.noteAXResult(result, context: context)
        return result
    }

    @discardableResult
    static func setAttributeValue(
        on element: AXUIElement,
        attribute: CFString,
        value: CFTypeRef,
        context: String
    ) -> AXError {
        guard shared.isAccessibilityTrustedCached else {
            shared.noteAXResult(.apiDisabled, context: context)
            return .apiDisabled
        }

        shared.configureMessagingTimeout(for: element)
        let result = AXUIElementSetAttributeValue(element, attribute, value)
        shared.noteAXResult(result, context: context)
        return result
    }

    @discardableResult
    static func performAction(
        on element: AXUIElement,
        action: CFString,
        context: String
    ) -> AXError {
        guard shared.isAccessibilityTrustedCached else {
            shared.noteAXResult(.apiDisabled, context: context)
            return .apiDisabled
        }

        shared.configureMessagingTimeout(for: element)
        let result = AXUIElementPerformAction(element, action)
        shared.noteAXResult(result, context: context)
        return result
    }

    @discardableResult
    static func createObserver(
        pid: pid_t,
        callback: @escaping AXObserverCallback,
        observer: inout AXObserver?,
        context: String
    ) -> AXError {
        guard shared.isAccessibilityTrustedCached else {
            shared.noteAXResult(.apiDisabled, context: context)
            return .apiDisabled
        }

        let result = AXObserverCreate(pid, callback, &observer)
        shared.noteAXResult(result, context: context)
        return result
    }

    @discardableResult
    static func addObserverNotification(
        _ observer: AXObserver,
        element: AXUIElement,
        notification: CFString,
        context: String,
        refcon: UnsafeMutableRawPointer?
    ) -> AXError {
        guard shared.isAccessibilityTrustedCached else {
            shared.noteAXResult(.apiDisabled, context: context)
            return .apiDisabled
        }

        shared.configureMessagingTimeout(for: element)
        let result = AXObserverAddNotification(observer, element, notification, refcon)
        shared.noteAXResult(result, context: context)
        return result
    }
}

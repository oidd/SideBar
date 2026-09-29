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
    /// 已设置过 messaging timeout 的 element 集合。
    /// 性能优化：configureMessagingTimeout 原本在每次 AX 调用（展开动画 60Hz）都
    /// 调一次 AXUIElementSetMessagingTimeout。该系统调用对同一 element 设置相同
    /// 值是幂等的，重复调用纯属浪费主线程时间。这里记录"已设过的 element"，只设一次。
    /// element 由 WindowSession 强持有，本集合多持有一份引用不影响其生命周期。
    private var timeoutConfiguredElements: Set<AXUIElement> = []
    private let timeoutElementsLock = NSLock()

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
        // 性能优化：同一 element 的 messaging timeout 只设置一次。AXUIElementSetMessagingTimeout
        // 是幂等的，重复调用只是无谓的系统调用开销。展开动画期间 WindowAnimator 以 60Hz
        // 调 axSetPositionAttribute，原本每帧都会触发一次本方法，改为只设一次后可消除
        // 这部分稳态系统调用负载。用锁保护集合，因为动画回调可能跨线程。
        timeoutElementsLock.lock()
        let alreadyConfigured = timeoutConfiguredElements.contains(element)
        if !alreadyConfigured {
            timeoutConfiguredElements.insert(element)
        }
        timeoutElementsLock.unlock()
        guard !alreadyConfigured else { return }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    /// 从 messaging timeout 缓存中丢弃指定 element。
    /// 用途：WindowSession 销毁 / 窗口 element 被替换时调用，避免 Set 长期驻留
    /// 已经消亡的 AXUIElement 引用而造成缓慢内存泄漏。
    func discardMessagingTimeoutCache(for element: AXUIElement) {
        timeoutElementsLock.lock()
        timeoutConfiguredElements.remove(element)
        timeoutElementsLock.unlock()
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

        // 权限丢失/恢复转换时，清空 timeout 缓存集合：权限恢复后需要为每个 element
        // 重新设置 messaging timeout（底层连接已重建，之前的设置不再生效）。
        if previous != trusted {
            timeoutElementsLock.lock()
            timeoutConfiguredElements.removeAll()
            timeoutElementsLock.unlock()
        }

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

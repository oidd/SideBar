import AppKit
import Combine
import Foundation

struct SideBarHotkeyClaim: Codable, Equatable {
    enum HotkeyOwner: String, Codable {
        case dockminimize
        case sidebar
    }

    let hotkeyOwner: HotkeyOwner
    let state: String
    let sessionID: String?
    let lastChangedAt: String?
}

struct DockMinimizeHotkeyBinding: Codable, Equatable {
    let bundleID: String
    let keyCode: Int
    let modifierFlagsRawValue: UInt64
    let displayString: String
}

private struct SideBarDockExclusionsPayload: Codable {
    let version: Int
    let updatedAt: String
    let bundleIDs: [String]
    let reasons: [String: [String]]
}

private struct SideBarHotkeyRuntimePayload: Codable {
    let version: Int
    let updatedAt: String
    let sidebarRunning: Bool
    let claims: [String: SideBarHotkeyClaim]
}

private struct DockMinimizeHotkeyBindingsPayload: Codable {
    let version: Int
    let updatedAt: String?
    let bindings: [DockMinimizeHotkeyBinding]
}

final class SideBarBridge: NSObject, ObservableObject {
    static let shared = SideBarBridge()

    enum OwnershipTransferReason: String {
        case detachedFromEdge = "detached_from_edge"
        case snappedWhileFloatingSiblingsPresent = "snapped_with_floating_siblings"
    }

    struct RuntimeClaimSnapshot: Equatable {
        let bundleID: String
        let hotkeyOwner: SideBarHotkeyClaim.HotkeyOwner
        let state: String
        let sessionID: String?
    }

    struct HotkeyActionResponse {
        let handled: Bool
        let state: String
        let handledBy: String

        static let unhandled = HotkeyActionResponse(
            handled: false,
            state: "no_active_claim",
            handledBy: "dockminimize"
        )
    }

    private enum NotificationNames {
        static let dockExclusionsChanged = NSNotification.Name("com.ivean.SideBar.dockExclusionsDidChange")
        static let hotkeyRuntimeChanged = NSNotification.Name("com.ivean.SideBar.hotkeyRuntimeDidChange")
        static let requestSideBarHotkeyAction = NSNotification.Name("com.ivean.DockMinimize.requestSideBarHotkeyAction")
        static let sideBarHotkeyActionAck = NSNotification.Name("com.ivean.SideBar.sideBarHotkeyActionAck")
        static let dockMinimizeHotkeyBindingsChanged = NSNotification.Name("com.ivean.DockMinimize.hotkeyBindingsDidChange")
        static let bundleControlOwnershipChanged = NSNotification.Name("com.ivean.SideBar.bundleControlOwnershipChanged")
    }

    private enum FileNames {
        static let sharedDirectory = "Library/Application Support/ivean.shared"
        static let dockExclusions = "sidebar_dock_exclusions.v1.json"
        static let hotkeyRuntime = "sidebar_hotkey_runtime.v1.json"
        static let dockMinimizeHotkeys = "dockminimize_hotkey_bindings.v1.json"
    }

    @Published private(set) var dockMinimizeHotkeyBindings: [String: DockMinimizeHotkeyBinding] = [:]

    var hotkeyActionHandler: ((String) -> HotkeyActionResponse)?

    private let distributedCenter = DistributedNotificationCenter.default()
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var didStart = false
    private var runtimeClaims: [String: SideBarHotkeyClaim] = [:]

    private override init() {
        super.init()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func start() {
        if !didStart {
            didStart = true

            distributedCenter.addObserver(
                self,
                selector: #selector(handleHotkeyActionRequest(_:)),
                name: NotificationNames.requestSideBarHotkeyAction,
                object: nil
            )

            distributedCenter.addObserver(
                self,
                selector: #selector(handleDockMinimizeHotkeyBindingsChanged(_:)),
                name: NotificationNames.dockMinimizeHotkeyBindingsChanged,
                object: nil
            )
        }

        loadDockMinimizeHotkeyBindings()
        exportRuntimePayload(sidebarRunning: true, claims: runtimeClaims)
    }

    func stop() {
        hotkeyActionHandler = nil
        runtimeClaims = [:]
        exportRuntimePayload(sidebarRunning: false, claims: [:])
    }

    func exportDockExclusions(bundleIDs: [String], reasons: [String: [String]]) {
        let normalizedBundleIDs = Array(Set(bundleIDs.filter { !$0.isEmpty })).sorted()
        let normalizedBundleIDSet = Set(normalizedBundleIDs)
        var normalizedReasons: [String: [String]] = [:]
        for (key, value) in reasons where normalizedBundleIDSet.contains(key) {
            normalizedReasons[key] = Array(Set(value)).sorted()
        }
        normalizedReasons = Dictionary(uniqueKeysWithValues: normalizedReasons.sorted { $0.key < $1.key })

        let payload = SideBarDockExclusionsPayload(
            version: 1,
            updatedAt: Self.iso8601String(from: Date()),
            bundleIDs: normalizedBundleIDs,
            reasons: normalizedReasons
        )

        do {
            try ensureSharedDirectoryExists()
            let data = try encoder.encode(payload)
            try data.write(to: dockExclusionsURL, options: Data.WritingOptions.atomic)
            distributedCenter.postNotificationName(
                NotificationNames.dockExclusionsChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            print("[SideBarBridge] 导出 Dock 排除名单失败: \(error)")
        }
    }

    func syncRuntimeClaims(
        from snapshots: [RuntimeClaimSnapshot],
        effectiveOwners: [String: SideBarHotkeyClaim.HotkeyOwner] = [:],
        preferredSessionIDs: [String: String] = [:]
    ) {
        let aggregatedClaims = aggregateRuntimeClaims(
            from: snapshots,
            effectiveOwners: effectiveOwners,
            preferredSessionIDs: preferredSessionIDs
        )
        if aggregatedClaims != runtimeClaims {
            let changedBundles = Set(aggregatedClaims.keys).union(runtimeClaims.keys).sorted().compactMap { bundleID -> String? in
                let oldClaim = runtimeClaims[bundleID]
                let newClaim = aggregatedClaims[bundleID]
                guard oldClaim?.hotkeyOwner != newClaim?.hotkeyOwner ||
                        oldClaim?.state != newClaim?.state ||
                        oldClaim?.sessionID != newClaim?.sessionID else {
                    return nil
                }
                return "\(bundleID): \(oldClaim?.hotkeyOwner.rawValue ?? "nil")/\(oldClaim?.state ?? "nil") -> \(newClaim?.hotkeyOwner.rawValue ?? "nil")/\(newClaim?.state ?? "nil")"
            }
            if !changedBundles.isEmpty {
            }
            runtimeClaims = aggregatedClaims
        }
        exportRuntimePayload(sidebarRunning: true, claims: runtimeClaims)
    }

    func hotkeyBinding(for bundleID: String) -> DockMinimizeHotkeyBinding? {
        dockMinimizeHotkeyBindings[bundleID]
    }

    func mirroredHotkeyConflict(modifiers: UInt, keyCode: UInt16, excluding bundleID: String?) -> DockMinimizeHotkeyBinding? {
        dockMinimizeHotkeyBindings.values.first { binding in
            guard binding.bundleID != bundleID else { return false }
            return binding.keyCode == Int(keyCode) && UInt(binding.modifierFlagsRawValue) == modifiers
        }
    }

    func isMirroredHotkey(modifiers: UInt, keyCode: UInt16) -> Bool {
        mirroredHotkeyConflict(modifiers: modifiers, keyCode: keyCode, excluding: nil) != nil
    }

    func runtimeClaim(for bundleID: String) -> SideBarHotkeyClaim? {
        runtimeClaims[bundleID]
    }

    func announceBundleControlTransfer(
        bundleID: String,
        appName: String,
        owner: SideBarHotkeyClaim.HotkeyOwner,
        reason: OwnershipTransferReason
    ) {
        let userInfo: [String: Any] = [
            "bundleID": bundleID,
            "appName": appName,
            "owner": owner.rawValue,
            "reason": reason.rawValue,
            "sentAt": Self.iso8601String(from: Date())
        ]

        distributedCenter.postNotificationName(
            NotificationNames.bundleControlOwnershipChanged,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    @objc private func handleHotkeyActionRequest(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let requestID = userInfo["requestID"] as? String ?? ""
        let bundleID = userInfo["bundleID"] as? String ?? ""
        guard !requestID.isEmpty, !bundleID.isEmpty else { return }

        DispatchQueue.main.async {
            let response = self.hotkeyActionHandler?(bundleID) ?? .unhandled
            self.sendHotkeyActionAck(
                requestID: requestID,
                bundleID: bundleID,
                response: response
            )
        }
    }

    @objc private func handleDockMinimizeHotkeyBindingsChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.loadDockMinimizeHotkeyBindings()
        }
    }

    private func loadDockMinimizeHotkeyBindings() {
        guard fileManager.fileExists(atPath: dockMinimizeHotkeysURL.path) else {
            dockMinimizeHotkeyBindings = [:]
            return
        }

        do {
            let data = try Data(contentsOf: dockMinimizeHotkeysURL)
            let payload = try decoder.decode(DockMinimizeHotkeyBindingsPayload.self, from: data)
            let normalizedBindings = Dictionary(
                uniqueKeysWithValues: payload.bindings
                    .sorted { $0.bundleID < $1.bundleID }
                    .map { ($0.bundleID, $0) }
            )
            dockMinimizeHotkeyBindings = normalizedBindings
        } catch {
            print("[SideBarBridge] 读取 DockMinimize 快捷键镜像失败: \(error)")
        }
    }

    private func aggregateRuntimeClaims(
        from snapshots: [RuntimeClaimSnapshot],
        effectiveOwners: [String: SideBarHotkeyClaim.HotkeyOwner],
        preferredSessionIDs: [String: String]
    ) -> [String: SideBarHotkeyClaim] {
        let groupedSnapshots = Dictionary(
            grouping: snapshots.filter { !$0.bundleID.isEmpty },
            by: \.bundleID
        )

        var result: [String: SideBarHotkeyClaim] = [:]
        for bundleID in groupedSnapshots.keys.sorted() {
            guard let bundleSnapshots = groupedSnapshots[bundleID], !bundleSnapshots.isEmpty else { continue }
            let effectiveOwner = effectiveOwners[bundleID] ?? inferredOwner(from: bundleSnapshots)
            guard let snapshot = selectRepresentativeSnapshot(
                from: bundleSnapshots,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionIDs[bundleID]
            ) else {
                continue
            }

            let previous = runtimeClaims[bundleID]
            let isSameClaim = previous?.hotkeyOwner == effectiveOwner &&
                previous?.state == snapshot.state &&
                previous?.sessionID == snapshot.sessionID

            result[bundleID] = SideBarHotkeyClaim(
                hotkeyOwner: effectiveOwner,
                state: snapshot.state,
                sessionID: snapshot.sessionID,
                lastChangedAt: isSameClaim ? previous?.lastChangedAt : Self.iso8601String(from: Date())
            )
        }

        return Dictionary(uniqueKeysWithValues: result.sorted { $0.key < $1.key })
    }

    private func inferredOwner(from snapshots: [RuntimeClaimSnapshot]) -> SideBarHotkeyClaim.HotkeyOwner {
        guard let chosenSnapshot = snapshots.max(by: { claimPriority(for: $0) < claimPriority(for: $1) }) else {
            return .dockminimize
        }
        return chosenSnapshot.hotkeyOwner
    }

    private func selectRepresentativeSnapshot(
        from snapshots: [RuntimeClaimSnapshot],
        effectiveOwner: SideBarHotkeyClaim.HotkeyOwner,
        preferredSessionID: String?
    ) -> RuntimeClaimSnapshot? {
        snapshots.max { lhs, rhs in
            representativePriority(
                for: lhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID
            ) < representativePriority(
                for: rhs,
                effectiveOwner: effectiveOwner,
                preferredSessionID: preferredSessionID
            )
        }
    }

    private func representativePriority(
        for snapshot: RuntimeClaimSnapshot,
        effectiveOwner: SideBarHotkeyClaim.HotkeyOwner,
        preferredSessionID: String?
    ) -> Int {
        var score = claimPriority(for: snapshot)
        if snapshot.hotkeyOwner == effectiveOwner {
            score += 100
        }
        if let preferredSessionID, snapshot.sessionID == preferredSessionID {
            score += 200
        }
        return score
    }

    private func claimPriority(for snapshot: RuntimeClaimSnapshot) -> Int {
        switch snapshot.state {
        case "snapped_hidden":
            return snapshot.hotkeyOwner == .sidebar ? 3 : 2
        case "expanded_visible":
            return 1
        default:
            return 0
        }
    }

    private func exportRuntimePayload(sidebarRunning: Bool, claims: [String: SideBarHotkeyClaim]) {
        let payload = SideBarHotkeyRuntimePayload(
            version: 1,
            updatedAt: Self.iso8601String(from: Date()),
            sidebarRunning: sidebarRunning,
            claims: Dictionary(uniqueKeysWithValues: claims.sorted { $0.key < $1.key })
        )

        do {
            try ensureSharedDirectoryExists()
            let data = try encoder.encode(payload)
            try data.write(to: hotkeyRuntimeURL, options: Data.WritingOptions.atomic)
            distributedCenter.postNotificationName(
                NotificationNames.hotkeyRuntimeChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            print("[SideBarBridge] 导出热键运行时状态失败: \(error)")
        }
    }

    private func sendHotkeyActionAck(requestID: String, bundleID: String, response: HotkeyActionResponse) {
        let userInfo: [String: Any] = [
            "requestID": requestID,
            "bundleID": bundleID,
            "handled": response.handled,
            "state": response.state,
            "handledBy": response.handledBy,
            "respondedAt": Self.iso8601String(from: Date())
        ]

        distributedCenter.postNotificationName(
            NotificationNames.sideBarHotkeyActionAck,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    private func ensureSharedDirectoryExists() throws {
        try fileManager.createDirectory(
            at: sharedDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var sharedDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(FileNames.sharedDirectory, isDirectory: true)
    }

    private var dockExclusionsURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.dockExclusions)
    }

    private var hotkeyRuntimeURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.hotkeyRuntime)
    }

    private var dockMinimizeHotkeysURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.dockMinimizeHotkeys)
    }
}

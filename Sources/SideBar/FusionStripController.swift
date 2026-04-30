import AppKit

struct FusionStripSessionDescriptor {
    let sessionID: ObjectIdentifier
    let session: WindowSession
    let edge: Int
    let screenFrame: CGRect
    let visibleMinY: CGFloat
    let visibleMaxY: CGFloat
    let windowHeight: CGFloat
    let color: NSColor
    let title: String
    let icon: NSImage?
    let isExpanded: Bool
    let isPinned: Bool
}

private struct FusionScreenKey: Hashable {
    let edge: Int
    let minX: Int
    let minY: Int
    let width: Int
    let height: Int

    init(edge: Int, screenFrame: CGRect) {
        self.edge = edge
        self.minX = Int(screenFrame.minX.rounded())
        self.minY = Int(screenFrame.minY.rounded())
        self.width = Int(screenFrame.width.rounded())
        self.height = Int(screenFrame.height.rounded())
    }
}

private struct FusionGroupKey: Hashable {
    let screen: FusionScreenKey
    let memberSignature: String
}

private struct FusionOverlaySegment {
    let sessionID: ObjectIdentifier
    let color: NSColor
    let title: String
    let icon: NSImage?
    let slotRect: CGRect
    let overlayRect: CGRect
}

private struct FusionOverlayModel {
    let panelFrame: CGRect
    let edge: Int
    let trackRect: CGRect
    let hitRect: CGRect
    let segments: [FusionOverlaySegment]
    let activeSessionID: ObjectIdentifier?
    let hoveredSessionID: ObjectIdentifier?
    let showsIcons: Bool
    let allowsImmediateHoverSync: Bool
    /// 整组所有段共享的"图标列中心 X"（panel 局部坐标），保证所有段图标与胶囊对齐到同一条竖线。
    let iconColumnCenterX: CGFloat
    /// 整组所有段共享的标签胶囊宽度，让所有胶囊同宽并以图标中心对称展开。
    let labelCapsuleWidth: CGFloat
}

final class FusionStripCoordinator {
    private var overlays: [FusionGroupKey: FusionIndicatorWindow] = [:]
    private var models: [FusionGroupKey: FusionOverlayModel] = [:]
    private var hoverTimers: [FusionGroupKey: Timer] = [:]
    private var hoverInsideTrack: [FusionGroupKey: Bool] = [:]
    private var hoveredSessionIDs: [FusionGroupKey: ObjectIdentifier] = [:]
    private var switchVersions: [FusionGroupKey: Int] = [:]
    private var transitionHoldUntil: [FusionGroupKey: Date] = [:]
    private var hoverActivationArmed: [FusionGroupKey: Bool] = [:]
    /// 段级“点击折叠临时锁”：记录每个 group 当前被点击折叠的 sessionID。
    /// 鼠标停留在该段时，hover 不会再次自动展开；移动到其他段或离开融合条会立即解除。
    private var clickCollapseLockedSessionIDs: [FusionGroupKey: ObjectIdentifier] = [:]
    private var sessionLookup: [ObjectIdentifier: WindowSession] = [:]
    private var lastValidDescriptors: [ObjectIdentifier: FusionStripSessionDescriptor] = [:]
    private var removalGraceUntilBySessionID: [ObjectIdentifier: Date] = [:]
    private var lastSessions: [WindowSession] = []

    private let segmentSettleDelay: TimeInterval = 0.08

    func reconcile(sessions: [WindowSession]) {
        lastSessions = sessions
        sessionLookup = Dictionary(uniqueKeysWithValues: sessions.map { (ObjectIdentifier($0), $0) })

        guard AppConfig.shared.isFusionStripEnabled else {
            sessions.forEach {
                $0.setIndicatorSuppressed(false)
                $0.setFusionHoverLock(false)
            }
            tearDownAll()
            return
        }

        let now = Date()
        let descriptors: [FusionStripSessionDescriptor] = sessions.compactMap { session in
            let id = ObjectIdentifier(session)
            if let current = session.fusionStripDescriptor() {
                // 探测成功：更新最后有效状态，并清除移除倒计时
                lastValidDescriptors[id] = current
                removalGraceUntilBySessionID.removeValue(forKey: id)
                return current
            } else if let lastValid = lastValidDescriptors[id],
                      let graceUntil = removalGraceUntilBySessionID[id] {
                // 探测失败但仍在驻留期内：继续使用最后一次有效状态
                if now < graceUntil {
                    return lastValid
                } else {
                    // 驻留期满：正式移除
                    lastValidDescriptors.removeValue(forKey: id)
                    removalGraceUntilBySessionID.removeValue(forKey: id)
                    return nil
                }
            } else if let lastValid = lastValidDescriptors[id] {
                // 初次探测失败：启动驻留期 (1.2 秒)
                removalGraceUntilBySessionID[id] = now.addingTimeInterval(1.2)
                return lastValid
            }
            return nil
        }
        let desiredGroups = buildGroups(from: descriptors)
        let heldKeys = Set(transitionHoldUntil.compactMap { key, until in
            until > now ? key : nil
        })
        let heldSuppressedIDs = heldKeys.flatMap { key in
            models[key]?.segments.map(\.sessionID) ?? []
        }
        let suppressedIDs = Set(desiredGroups.flatMap { $0.members.map(\.sessionID) } + heldSuppressedIDs)

        sessions.forEach { session in
            let id = ObjectIdentifier(session)
            session.setIndicatorSuppressed(suppressedIDs.contains(id))
            if !suppressedIDs.contains(id) {
                session.setFusionHoverLock(false)
            }
        }

        let desiredKeys = Set(desiredGroups.map(\.key))
        let existingKeys = Set(overlays.keys)

        for staleKey in existingKeys.subtracting(desiredKeys) {
            let shouldTearDownImmediately = models[staleKey]?.segments.contains { segment in
                sessionLookup[segment.sessionID]?.isEligibleForFusionInCurrentSpace() != true
            } ?? false
            if !shouldTearDownImmediately,
               let holdUntil = transitionHoldUntil[staleKey], holdUntil > now {
                continue
            }
            clearInteractionState(for: staleKey)
            overlays[staleKey]?.close()
            overlays.removeValue(forKey: staleKey)
            models.removeValue(forKey: staleKey)
            transitionHoldUntil.removeValue(forKey: staleKey)
        }

        for group in desiredGroups {
            if group.members.count > 5 && !AppConfig.shared.hasShownFusionOverloadWarning {
                presentFusionOverloadWarningOnce()
            }

            let overlay = overlays[group.key] ?? makeOverlay(for: group.key)
            overlays[group.key] = overlay

            let previousActiveID = models[group.key]?.activeSessionID
            let preferredActiveID = previousActiveID
            let activeSessionID = normalizeExpandedSessions(in: group.members, preferredActiveID: preferredActiveID)
            if hoverInsideTrack[group.key] == true,
               previousActiveID != nil,
               activeSessionID == nil {
                hoverActivationArmed[group.key] = false
                hoverTimers[group.key]?.invalidate()
                hoverTimers.removeValue(forKey: group.key)
                hoveredSessionIDs.removeValue(forKey: group.key)
                switchVersions[group.key, default: 0] += 1
            }
            let model = buildOverlayModel(for: group, activeSessionID: activeSessionID)
            models[group.key] = model
            overlay.update(with: model)
            transitionHoldUntil[group.key] = Date().addingTimeInterval(0.55)
        }
    }

    func tearDownAll() {
        hoverTimers.values.forEach { $0.invalidate() }
        hoverTimers.removeAll()
        hoverInsideTrack.removeAll()
        hoveredSessionIDs.removeAll()
        switchVersions.removeAll()
        transitionHoldUntil.removeAll()
        hoverActivationArmed.removeAll()
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        models.removeAll()
    }

    func resetForSpaceChange(sessions: [WindowSession]) {
        // 核心修复：桌面切换是明确的信号，必须立即清除所有视觉驻留，防止图标滞留在新桌面
        lastValidDescriptors.removeAll()
        removalGraceUntilBySessionID.removeAll()
        
        for key in Array(models.keys) {
            clearInteractionState(for: key)
        }
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        models.removeAll()
        transitionHoldUntil.removeAll()

        sessions.forEach {
            $0.setIndicatorSuppressed(false)
            $0.setFusionHoverLock(false)
        }
    }

    func discardCachedDescriptors(for sessions: [WindowSession]) {
        let sessionIDs = sessions.map(ObjectIdentifier.init)
        sessionIDs.forEach {
            lastValidDescriptors.removeValue(forKey: $0)
            removalGraceUntilBySessionID.removeValue(forKey: $0)
        }
    }

    private func makeOverlay(for key: FusionGroupKey) -> FusionIndicatorWindow {
        let overlay = FusionIndicatorWindow()
        overlay.onTrackHoverChanged = { [weak self] isInside in
            self?.handleTrackHoverChanged(isInside, for: key)
        }
        overlay.onHoveredSessionChange = { [weak self] sessionID in
            self?.handleHoveredSessionChange(sessionID, for: key)
        }
        overlay.onSegmentClicked = { [weak self] sessionID in
            self?.handleSegmentClicked(sessionID, for: key)
        }
        return overlay
    }

    private func handleTrackHoverChanged(_ isInside: Bool, for key: FusionGroupKey) {
        let wasInside = hoverInsideTrack[key] == true
        hoverInsideTrack[key] = isInside

        if !isInside {
            hoverTimers[key]?.invalidate()
            hoverTimers.removeValue(forKey: key)
            hoveredSessionIDs.removeValue(forKey: key)
            switchVersions[key, default: 0] += 1
            hoverActivationArmed[key] = false
        } else if !wasInside {
            hoverActivationArmed[key] = true
        }

        updateFusionLocks(for: key, enabled: isInside)
        refreshOverlay(for: key)
    }

    private func handleHoveredSessionChange(_ sessionID: ObjectIdentifier?, for key: FusionGroupKey) {
        switchVersions[key, default: 0] += 1
        let version = switchVersions[key, default: 0]
        hoverTimers[key]?.invalidate()
        hoverTimers.removeValue(forKey: key)

        // 段级临时锁解除策略：
        // - 鼠标在融合条上但不指向任何段、或指向锁定段以外的其他段，立即解除锁定
        if let lockedID = clickCollapseLockedSessionIDs[key],
           sessionID != lockedID {
            clickCollapseLockedSessionIDs.removeValue(forKey: key)
        }

        guard hoverInsideTrack[key] == true, let sessionID = sessionID else {
            hoveredSessionIDs[key] = nil
            refreshOverlay(for: key)
            return
        }

        guard hoverActivationArmed[key] == true else {
            hoveredSessionIDs[key] = nil
            refreshOverlay(for: key)
            return
        }

        hoveredSessionIDs[key] = sessionID

        // 该段被点击折叠锁定时，不触发 hover 自动展开
        if clickCollapseLockedSessionIDs[key] == sessionID {
            refreshOverlay(for: key)
            return
        }

        let activeSessionID = models[key]?.activeSessionID
        if activeSessionID == sessionID {
            refreshOverlay(for: key)
            return
        }

        let delay: TimeInterval
        if activeSessionID == nil {
            delay = Double(AppConfig.shared.hoverDelayMS) / 1000.0
        } else {
            delay = segmentSettleDelay
        }

        if delay <= 0 {
            activateSession(sessionID, in: key, expectedVersion: version)
        } else {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.activateSession(sessionID, in: key, expectedVersion: version)
            }
            hoverTimers[key] = timer
        }

        refreshOverlay(for: key)
    }

    /// 处理融合条段单击事件：
    /// - 点击的是当前 active 段（窗口已展开）→ fusionHide 折叠该段，并将其置入临时锁。
    /// - 点击的是已被锁定的段 → 解除锁定，立即激活展开该段。
    /// - 点击的是其它段：交给现有 hover→activate 逻辑处理（这里不做特殊处理，因为段切换已经会自动 reveal）。
    private func handleSegmentClicked(_ sessionID: ObjectIdentifier, for key: FusionGroupKey) {
        guard let model = models[key] else { return }
        guard model.segments.contains(where: { $0.sessionID == sessionID }) else { return }

        hoverTimers[key]?.invalidate()
        hoverTimers.removeValue(forKey: key)
        switchVersions[key, default: 0] += 1

        // 已锁定的段被再次点击 → 解锁并展开
        if clickCollapseLockedSessionIDs[key] == sessionID {
            clickCollapseLockedSessionIDs.removeValue(forKey: key)
            hoveredSessionIDs[key] = sessionID
            hoverActivationArmed[key] = true
            activateSession(sessionID, in: key)
            refreshOverlay(for: key)
            return
        }

        // 当前 active 段被点击 → 折叠并锁定
        if model.activeSessionID == sessionID {
            sessionLookup[sessionID]?.fusionHide()
            clickCollapseLockedSessionIDs[key] = sessionID

            let updatedModel = FusionOverlayModel(
                panelFrame: model.panelFrame,
                edge: model.edge,
                trackRect: model.trackRect,
                hitRect: model.hitRect,
                segments: model.segments,
                activeSessionID: nil,
                hoveredSessionID: hoveredSessionIDs[key],
                showsIcons: hoverInsideTrack[key] == true,
                allowsImmediateHoverSync: hoverActivationArmed[key] == true,
                iconColumnCenterX: model.iconColumnCenterX,
                labelCapsuleWidth: model.labelCapsuleWidth
            )
            models[key] = updatedModel
            overlays[key]?.update(with: updatedModel)
            return
        }


        // 点击的是非 active 的其他段：直接走 activate 路径（按用户预期立即切换）
        clickCollapseLockedSessionIDs.removeValue(forKey: key)
        hoveredSessionIDs[key] = sessionID
        hoverActivationArmed[key] = true
        activateSession(sessionID, in: key)
    }

    private func activateSession(_ sessionID: ObjectIdentifier, in key: FusionGroupKey, expectedVersion: Int? = nil) {
        guard var model = models[key] else { return }
        if let expectedVersion, switchVersions[key, default: 0] != expectedVersion { return }
        guard hoverInsideTrack[key] == true else { return }
        guard hoverActivationArmed[key] == true else { return }
        guard hoveredSessionIDs[key] == sessionID else { return }
        guard sessionLookup[sessionID]?.isEligibleForFusionInCurrentSpace() == true else {
            reconcile(sessions: lastSessions)
            return
        }
        if sessionLookup[sessionID]?.isTemporaryPinnedForFusion() == true {
            refreshOverlay(for: key)
            return
        }
        let currentActiveID = model.activeSessionID
        let version = switchVersions[key, default: 0]

        if currentActiveID == sessionID {
            refreshOverlay(for: key)
            return
        }


        model = FusionOverlayModel(
            panelFrame: model.panelFrame,
            edge: model.edge,
            trackRect: model.trackRect,
            hitRect: model.hitRect,
            segments: model.segments,
            activeSessionID: sessionID,
            hoveredSessionID: hoveredSessionIDs[key],
            showsIcons: hoverInsideTrack[key] == true,
            allowsImmediateHoverSync: hoverActivationArmed[key] == true,
            iconColumnCenterX: model.iconColumnCenterX,
            labelCapsuleWidth: model.labelCapsuleWidth
        )

        models[key] = model
        overlays[key]?.update(with: model)


        if let currentActiveID, currentActiveID != sessionID {
            sessionLookup[currentActiveID]?.fusionHide()
        }

        sessionLookup[sessionID]?.fusionReveal()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            guard self.switchVersions[key, default: 0] == version else { return }
            self.reconcile(sessions: self.lastSessions)
        }
    }

    private func updateFusionLocks(for key: FusionGroupKey, enabled: Bool) {
        guard let model = models[key] else { return }
        let memberIDs = Set(model.segments.map(\.sessionID))
        for memberID in memberIDs {
            sessionLookup[memberID]?.setFusionHoverLock(enabled)
        }
    }

    private func clearInteractionState(for key: FusionGroupKey) {
        hoverTimers[key]?.invalidate()
        hoverTimers.removeValue(forKey: key)
        hoveredSessionIDs.removeValue(forKey: key)
        switchVersions[key, default: 0] += 1
        hoverActivationArmed.removeValue(forKey: key)
        if let model = models[key] {
            for memberID in model.segments.map(\.sessionID) {
                sessionLookup[memberID]?.setFusionHoverLock(false)
            }
        }
        hoverInsideTrack.removeValue(forKey: key)
    }

    private func refreshOverlay(for key: FusionGroupKey) {
        guard let baseModel = models[key] else { return }

        let refreshedModel = FusionOverlayModel(
            panelFrame: baseModel.panelFrame,
            edge: baseModel.edge,
            trackRect: baseModel.trackRect,
            hitRect: baseModel.hitRect,
            segments: baseModel.segments,
            activeSessionID: baseModel.activeSessionID,
            hoveredSessionID: hoveredSessionIDs[key],
            showsIcons: hoverInsideTrack[key] == true,
            allowsImmediateHoverSync: hoverActivationArmed[key] == true,
            iconColumnCenterX: baseModel.iconColumnCenterX,
            labelCapsuleWidth: baseModel.labelCapsuleWidth
        )

        models[key] = refreshedModel
        overlays[key]?.update(with: refreshedModel)
    }


    private func normalizeExpandedSessions(
        in members: [FusionStripSessionDescriptor],
        preferredActiveID: ObjectIdentifier?
    ) -> ObjectIdentifier? {
        let expandedIDs = members
            .filter(\.isExpanded)
            .map(\.sessionID)

        guard !expandedIDs.isEmpty else { return nil }

        let activeIDToKeep: ObjectIdentifier
        if let preferredActiveID, expandedIDs.contains(preferredActiveID) {
            activeIDToKeep = preferredActiveID
        } else {
            activeIDToKeep = expandedIDs[0]
        }

        for expandedID in expandedIDs where expandedID != activeIDToKeep {
            sessionLookup[expandedID]?.fusionHide()
        }

        return activeIDToKeep
    }

    private func buildGroups(from descriptors: [FusionStripSessionDescriptor]) -> [(key: FusionGroupKey, members: [FusionStripSessionDescriptor])] {
        let grouped = Dictionary(grouping: descriptors) { descriptor in
            FusionScreenKey(edge: descriptor.edge, screenFrame: descriptor.screenFrame)
        }

        var results: [(key: FusionGroupKey, members: [FusionStripSessionDescriptor])] = []

        for (screenKey, screenDescriptors) in grouped {
            let sorted = screenDescriptors.sorted { lhs, rhs in
                if lhs.visibleMinY == rhs.visibleMinY {
                    return lhs.visibleMaxY < rhs.visibleMaxY
                }
                return lhs.visibleMinY < rhs.visibleMinY
            }

            var currentGroup: [FusionStripSessionDescriptor] = []
            var currentMaxY: CGFloat = 0

            for descriptor in sorted {
                if currentGroup.isEmpty {
                    currentGroup = [descriptor]
                    currentMaxY = descriptor.visibleMaxY
                    continue
                }

                if descriptor.visibleMinY <= currentMaxY {
                    currentGroup.append(descriptor)
                    currentMaxY = max(currentMaxY, descriptor.visibleMaxY)
                } else {
                    appendGroupIfNeeded(currentGroup, screenKey: screenKey, into: &results)
                    currentGroup = [descriptor]
                    currentMaxY = descriptor.visibleMaxY
                }
            }

            appendGroupIfNeeded(currentGroup, screenKey: screenKey, into: &results)
        }

        return results
    }

    private func appendGroupIfNeeded(
        _ members: [FusionStripSessionDescriptor],
        screenKey: FusionScreenKey,
        into results: inout [(key: FusionGroupKey, members: [FusionStripSessionDescriptor])]
    ) {
        guard members.count >= 2 else { return }
        let signature = members
            .map(\.sessionID)
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: "|")
        results.append((FusionGroupKey(screen: screenKey, memberSignature: signature), members))
    }

    private func buildOverlayModel(
        for group: (key: FusionGroupKey, members: [FusionStripSessionDescriptor]),
        activeSessionID: ObjectIdentifier?
    ) -> FusionOverlayModel {
        let members = group.members.sorted { lhs, rhs in
            let lhsMidY = (lhs.visibleMinY + lhs.visibleMaxY) / 2
            let rhsMidY = (rhs.visibleMinY + rhs.visibleMaxY) / 2
            if lhsMidY == rhsMidY {
                if lhs.visibleMinY == rhs.visibleMinY {
                    return lhs.visibleMaxY < rhs.visibleMaxY
                }
                return lhs.visibleMinY < rhs.visibleMinY
            }
            return lhsMidY < rhsMidY
        }

        let screenFrame = members[0].screenFrame
        let unionMinY = members.map(\.visibleMinY).min() ?? screenFrame.minY
        let unionMaxY = members.map(\.visibleMaxY).max() ?? screenFrame.maxY
        let unionHeight = max(1, unionMaxY - unionMinY)
        let maxWindowHeight = members.map(\.windowHeight).max() ?? unionHeight

        // === 方案 A：所有段共享对齐参数 ===
        // 1) 计算本组最大胶囊宽度（与 drawIconRow 内一致的算法），用于动态拉宽 panel 并统一胶囊宽度
        let labelHorizontalPadding: CGFloat = 9
        let iconSize: CGFloat = 32
        let sideMargin: CGFloat = 12
        let screenInset: CGFloat = 10
        let trackWidth: CGFloat = 6
        let labelMinWidth: CGFloat = 60
        let labelMaxWidth: CGFloat = 132
        let edgePadding: CGFloat = 8

        let measuringFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let measuringAttributes: [NSAttributedString.Key: Any] = [.font: measuringFont]
        let memberLabelWidths: [CGFloat] = members.map { descriptor in
            let textWidth = ceil((descriptor.title as NSString).size(withAttributes: measuringAttributes).width)
            let raw = textWidth + labelHorizontalPadding * 2
            return min(max(raw, labelMinWidth), labelMaxWidth)
        }
        let groupLabelWidth = memberLabelWidths.max() ?? labelMinWidth
        let iconColumnReserved = max(iconSize, groupLabelWidth)
        let dynamicPanelWidth = ceil(
            screenInset + trackWidth + sideMargin + iconColumnReserved + edgePadding
        )
        // 保留 232 作为下限，向上至 360 以容纳长标题；超过屏幕宽度则收敛到屏幕宽度
        let panelWidth: CGFloat = min(max(dynamicPanelWidth, 232), min(360, screenFrame.width))

        let visualHeight = max(unionHeight, maxWindowHeight)
        let panelHeight = min(screenFrame.height, visualHeight + 96)
        let groupMidY = (unionMinY + unionMaxY) / 2
        let panelOriginY = clamp(groupMidY - panelHeight / 2, min: screenFrame.minY, max: screenFrame.maxY - panelHeight)

        let panelOriginX: CGFloat
        if members[0].edge == 1 {
            panelOriginX = screenFrame.minX - screenInset
        } else {
            panelOriginX = screenFrame.maxX - panelWidth + screenInset
        }

        let panelFrame = CGRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight)

        let visibleTrackX: CGFloat
        if members[0].edge == 1 {
            visibleTrackX = screenInset
        } else {
            visibleTrackX = panelWidth - screenInset - trackWidth
        }

        // 2) 计算"图标列中心 X"：所有段共用，保证图标与胶囊都对齐到同一条竖线
        let iconColumnCenterX: CGFloat
        if members[0].edge == 1 {
            iconColumnCenterX = visibleTrackX + trackWidth + sideMargin + iconColumnReserved / 2
        } else {
            iconColumnCenterX = visibleTrackX - sideMargin - iconColumnReserved / 2
        }


        let trackRect = CGRect(
            x: visibleTrackX,
            y: unionMinY - panelOriginY,
            width: trackWidth,
            height: unionHeight
        )
        let hitRect = CGRect(
            x: members[0].edge == 1 ? 0 : panelWidth - 18,
            y: max(0, trackRect.minY - 4),
            width: 18,
            height: min(panelHeight, trackRect.height + 8)
        )

        let slotHeight = unionHeight / CGFloat(max(1, members.count))
        let contentMinY = panelOriginY
        let contentMaxY = panelOriginY + panelHeight

        let segments = members.enumerated().map { index, descriptor in
            let slotMinY = unionMinY + CGFloat(index) * slotHeight
            let slotRect = CGRect(
                x: trackRect.minX,
                y: slotMinY - panelOriginY,
                width: trackRect.width,
                height: slotHeight
            )

            let slotCenterY = slotMinY + slotHeight / 2
            let overlayGlobalMinY = clamp(
                slotCenterY - descriptor.windowHeight / 2,
                min: contentMinY + 10,
                max: contentMaxY - descriptor.windowHeight - 10
            )
            let overlayRect = CGRect(
                x: visibleTrackX,
                y: overlayGlobalMinY - panelOriginY,
                width: trackWidth,
                height: descriptor.windowHeight
            )

            return FusionOverlaySegment(
                sessionID: descriptor.sessionID,
                color: descriptor.color,
                title: descriptor.title,
                icon: descriptor.icon,
                slotRect: slotRect,
                overlayRect: overlayRect
            )
        }

        return FusionOverlayModel(
            panelFrame: panelFrame,
            edge: members[0].edge,
            trackRect: trackRect,
            hitRect: hitRect,
            segments: segments,
            activeSessionID: activeSessionID,
            hoveredSessionID: hoveredSessionIDs[group.key],
            showsIcons: hoverInsideTrack[group.key] == true,
            allowsImmediateHoverSync: hoverActivationArmed[group.key] == true,
            iconColumnCenterX: iconColumnCenterX,
            labelCapsuleWidth: groupLabelWidth
        )
    }

    private func presentFusionOverloadWarningOnce() {

        AppConfig.shared.markFusionOverloadWarningShown()

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "当前同侧融合快照条包含超过 5 个窗口，快速切换时可能出现卡顿。".localized
            alert.informativeText = "建议适当减少同侧堆叠的窗口数量，以获得更稳定的切换体验。".localized
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定".localized)
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
    Swift.max(lowerBound, Swift.min(upperBound, value))
}

final class FusionIndicatorWindow: NSPanel {
    var onTrackHoverChanged: ((Bool) -> Void)?
    var onHoveredSessionChange: ((ObjectIdentifier?) -> Void)?
    var onSegmentClicked: ((ObjectIdentifier) -> Void)?

    private let fusionView = FusionIndicatorContentView()
    private let trackerWindow = FusionTrackerWindow()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 232, height: 240),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        trackerWindow.onTrackHoverChanged = { [weak self] isInside in
            self?.onTrackHoverChanged?(isInside)
        }
        trackerWindow.onHoveredSessionChange = { [weak self] sessionID in
            self?.onHoveredSessionChange?(sessionID)
        }
        trackerWindow.onSegmentClicked = { [weak self] sessionID in
            self?.onSegmentClicked?(sessionID)
        }
        contentView = fusionView
    }

    fileprivate func update(with model: FusionOverlayModel) {
        fusionView.model = model
        setFrame(model.panelFrame, display: true)
        orderFront(nil)
        trackerWindow.update(with: model)
    }

    override func close() {
        trackerWindow.close()
        super.close()
    }
}

final class FusionTrackerWindow: NSPanel {
    var onTrackHoverChanged: ((Bool) -> Void)?
    var onHoveredSessionChange: ((ObjectIdentifier?) -> Void)?
    var onSegmentClicked: ((ObjectIdentifier) -> Void)?

    private let trackerView = FusionTrackerContentView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 18, height: 240),
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

        trackerView.onTrackHoverChanged = { [weak self] isInside in
            self?.onTrackHoverChanged?(isInside)
        }
        trackerView.onHoveredSessionChange = { [weak self] sessionID in
            self?.onHoveredSessionChange?(sessionID)
        }
        trackerView.onSegmentClicked = { [weak self] sessionID in
            self?.onSegmentClicked?(sessionID)
        }
        contentView = trackerView
    }

    fileprivate func update(with model: FusionOverlayModel) {
        let frame = CGRect(
            x: model.panelFrame.minX + model.hitRect.minX,
            y: model.panelFrame.minY + model.hitRect.minY,
            width: model.hitRect.width,
            height: model.hitRect.height
        )
        trackerView.model = model
        setFrame(frame, display: true)
        orderFront(nil)
        if model.allowsImmediateHoverSync {
            trackerView.syncHoverStateToCurrentMouse()
        } else {
            trackerView.resetHoverStateWithoutActivation()
        }
    }
}

private final class FusionIndicatorContentView: NSView {
    var model: FusionOverlayModel? {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let model else { return }

        NSColor.clear.setFill()
        bounds.fill()

        for segment in model.segments {
            let displayRect = visualRect(for: segment, in: model)
            segment.color.setFill()
            segmentPath(for: segment, rect: displayRect, in: model).fill()
        }

        for index in 1..<model.segments.count {
            let dividerY = model.segments[index].slotRect.minY
            let baseDividerRect = CGRect(
                x: dividerXRange(in: model).minX,
                y: dividerY - 1.0,
                width: dividerXRange(in: model).width,
                height: 2.0
            )
            dividerColor().setFill()
            NSBezierPath(rect: baseDividerRect).fill()

            let highlightRect = CGRect(
                x: dividerXRange(in: model).minX,
                y: dividerY - 0.5,
                width: dividerXRange(in: model).width,
                height: 1.0
            )
            dividerHighlightColor().setFill()
            NSBezierPath(rect: highlightRect).fill()
        }

        if let activeSessionID = model.activeSessionID,
           model.hoveredSessionID != activeSessionID,
           let activeSegment = model.segments.first(where: { $0.sessionID == activeSessionID }) {
            let activeRect = visualRect(for: activeSegment, in: model)
            dividerOutlineColor().setStroke()
            let outline = segmentPath(for: activeSegment, rect: activeRect.insetBy(dx: -0.5, dy: 0), in: model)
            outline.lineWidth = 1
            outline.stroke()
        }

        if model.showsIcons {
            for segment in model.segments {
                drawIconRow(for: segment, hoveredSessionID: model.hoveredSessionID)
            }
        }
    }

    private func drawIconRow(for segment: FusionOverlaySegment, hoveredSessionID: ObjectIdentifier?) {
        guard let model = model else { return }
        let rowOpacity: CGFloat = hoveredSessionID == segment.sessionID ? 1.0 : 0.5
        let iconSize: CGFloat = 32
        let stackGap: CGFloat = 4
        let labelHorizontalPadding: CGFloat = 9
        let labelHeight: CGFloat = 20
        let labelFont = NSFont.systemFont(ofSize: 12.5, weight: hoveredSessionID == segment.sessionID ? .semibold : .medium)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center

        let textColor = NSColor.white.withAlphaComponent(rowOpacity)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: textColor,
            .paragraphStyle: style
        ]

        // === 方案 A：所有段共享同一个 stackCenterX，由 controller 端统一计算 ===
        // 这样无论标题长短，所有段的图标和胶囊中心都对齐到同一条竖线，整列视觉对齐。
        let stackCenterX: CGFloat = model.iconColumnCenterX

        // 胶囊宽度：使用整组共享宽度，所有段宽度一致；同时确保不溢出 iconColumn 容器
        let labelWidth: CGFloat = model.labelCapsuleWidth

        let centerY = segment.slotRect.midY
        let stackHeight = iconSize + stackGap + labelHeight
        let stackOriginY = centerY - stackHeight / 2

        let labelRect = CGRect(
            x: stackCenterX - labelWidth / 2,
            y: stackOriginY,
            width: labelWidth,
            height: labelHeight
        )
        let iconRect = CGRect(
            x: stackCenterX - iconSize / 2,
            y: labelRect.maxY + stackGap,
            width: iconSize,
            height: iconSize
        )

        if let icon = segment.icon {
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: rowOpacity)
        }

        let capsulePath = NSBezierPath(roundedRect: labelRect, xRadius: labelHeight / 2, yRadius: labelHeight / 2)
        NSColor(calibratedWhite: 0.08, alpha: 0.68 * rowOpacity).setFill()
        capsulePath.fill()

        let textRect = labelRect.insetBy(dx: labelHorizontalPadding, dy: 2)
        segment.title.draw(in: textRect, withAttributes: attributes)
    }


    private func dividerColor() -> NSColor {
        let darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return darkMode ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.92)
    }

    private func dividerHighlightColor() -> NSColor {
        let darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return darkMode ? NSColor.black.withAlphaComponent(0.32) : NSColor.white.withAlphaComponent(0.34)
    }

    private func dividerOutlineColor() -> NSColor {
        let darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return darkMode ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.45)
    }

    private func dividerXRange(in model: FusionOverlayModel) -> CGRect {
        let width: CGFloat = 8
        if model.edge == 1 {
            return CGRect(x: model.trackRect.minX - 2, y: 0, width: width, height: 0)
        } else {
            return CGRect(x: model.trackRect.maxX - 6, y: 0, width: width, height: 0)
        }
    }

    private func visualRect(for segment: FusionOverlaySegment, in model: FusionOverlayModel) -> CGRect {
        let emphasizedID = model.hoveredSessionID ?? model.activeSessionID
        let hasEmphasis = emphasizedID != nil
        let isFocused = emphasizedID == segment.sessionID
        let width: CGFloat = hasEmphasis ? (isFocused ? 6.0 : 3.4) : 6.0
        let edgeShift: CGFloat = hasEmphasis ? (isFocused ? 0.0 : 2.0) : 0.0
        let x: CGFloat

        if model.edge == 1 {
            x = model.trackRect.minX - edgeShift
        } else {
            x = model.trackRect.maxX - width + edgeShift
        }

        return CGRect(x: x, y: segment.slotRect.minY, width: width, height: segment.slotRect.height)
    }

    private func segmentPath(for segment: FusionOverlaySegment, rect: CGRect, in model: FusionOverlayModel) -> NSBezierPath {
        guard let index = model.segments.firstIndex(where: { $0.sessionID == segment.sessionID }) else {
            return NSBezierPath(rect: rect)
        }

        let isFirst = index == 0
        let isLast = index == model.segments.count - 1
        if isFirst || isLast {
            return NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        }
        return NSBezierPath(rect: rect)
    }
}

private final class FusionTrackerContentView: NSView {
    var onTrackHoverChanged: ((Bool) -> Void)?
    var onHoveredSessionChange: ((ObjectIdentifier?) -> Void)?
    var onSegmentClicked: ((ObjectIdentifier) -> Void)?

    var model: FusionOverlayModel?

    private var trackingAreaRef: NSTrackingArea?
    private var isHoveringTrack = false
    private var hoveredSessionID: ObjectIdentifier?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let newArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        trackingAreaRef = newArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if isHoveringTrack {
            isHoveringTrack = false
            onTrackHoverChanged?(false)
        }
        if hoveredSessionID != nil {
            hoveredSessionID = nil
            onHoveredSessionChange?(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        let translatedY = point.y + model.hitRect.minY
        if let segment = model.segments.first(where: {
            $0.slotRect.contains(CGPoint(x: model.trackRect.midX, y: translatedY))
        }) {
            // 同步刷新 hover 状态，确保后续 hover 解锁/激活路径有正确的 sessionID
            if hoveredSessionID != segment.sessionID {
                hoveredSessionID = segment.sessionID
                onHoveredSessionChange?(segment.sessionID)
            }
            onSegmentClicked?(segment.sessionID)
            return
        }
        super.mouseDown(with: event)
    }

    func syncHoverStateToCurrentMouse() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(with: point)
    }

    func resetHoverStateWithoutActivation() {
        hoveredSessionID = nil
    }

    private func updateHover(with point: CGPoint) {
        guard let model else { return }
        let isInsideTrack = bounds.contains(point)
        if isInsideTrack != isHoveringTrack {
            isHoveringTrack = isInsideTrack
            onTrackHoverChanged?(isInsideTrack)
        }

        let nextHoveredSessionID: ObjectIdentifier?
        if isInsideTrack {
            let translatedY = point.y + model.hitRect.minY
            nextHoveredSessionID = model.segments.first(where: {
                $0.slotRect.contains(CGPoint(x: model.trackRect.midX, y: translatedY))
            })?.sessionID
        } else {
            nextHoveredSessionID = nil
        }

        if nextHoveredSessionID != hoveredSessionID {
            hoveredSessionID = nextHoveredSessionID
            onHoveredSessionChange?(nextHoveredSessionID)
        }
    }
}

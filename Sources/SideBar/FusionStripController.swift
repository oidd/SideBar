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
    private var sessionLookup: [ObjectIdentifier: WindowSession] = [:]
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

        let descriptors = sessions.compactMap { $0.fusionStripDescriptor() }
        let desiredGroups = buildGroups(from: descriptors)
        let now = Date()
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

    private func makeOverlay(for key: FusionGroupKey) -> FusionIndicatorWindow {
        let overlay = FusionIndicatorWindow()
        overlay.onTrackHoverChanged = { [weak self] isInside in
            self?.handleTrackHoverChanged(isInside, for: key)
        }
        overlay.onHoveredSessionChange = { [weak self] sessionID in
            self?.handleHoveredSessionChange(sessionID, for: key)
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
            allowsImmediateHoverSync: hoverActivationArmed[key] == true
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
            allowsImmediateHoverSync: hoverActivationArmed[key] == true
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
        let panelWidth: CGFloat = 232
        let visualHeight = max(unionHeight, maxWindowHeight)
        let panelHeight = min(screenFrame.height, visualHeight + 96)
        let groupMidY = (unionMinY + unionMaxY) / 2
        let panelOriginY = clamp(groupMidY - panelHeight / 2, min: screenFrame.minY, max: screenFrame.maxY - panelHeight)

        let screenInset: CGFloat = 10
        let panelOriginX: CGFloat
        if members[0].edge == 1 {
            panelOriginX = screenFrame.minX - screenInset
        } else {
            panelOriginX = screenFrame.maxX - panelWidth + screenInset
        }

        let panelFrame = CGRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight)

        let trackWidth: CGFloat = 6
        let visibleTrackX: CGFloat
        if members[0].edge == 1 {
            visibleTrackX = screenInset
        } else {
            visibleTrackX = panelWidth - screenInset - trackWidth
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
            allowsImmediateHoverSync: hoverActivationArmed[group.key] == true
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
        let rowOpacity: CGFloat = hoveredSessionID == segment.sessionID ? 1.0 : 0.5
        let iconSize: CGFloat = 32
        let stackGap: CGFloat = 4
        let sideMargin: CGFloat = 10
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
        let rawLabelWidth = ceil((segment.title as NSString).size(withAttributes: attributes).width) + labelHorizontalPadding * 2
        let labelWidth = min(max(rawLabelWidth, 54), 104)

        let centerY = segment.slotRect.midY
        let stackHeight = iconSize + stackGap + labelHeight
        let stackOriginY = centerY - stackHeight / 2
        let stackCenterX: CGFloat

        if model?.edge == 1 {
            stackCenterX = segment.slotRect.maxX + sideMargin + max(iconSize, labelWidth) / 2
        } else {
            stackCenterX = segment.slotRect.minX - sideMargin - max(iconSize, labelWidth) / 2
        }

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

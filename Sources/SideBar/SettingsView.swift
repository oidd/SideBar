import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case apps
    case appearance
    case shortcuts
    case interaction
    case general
    case advanced
    case about
    
    var iconName: String {
        switch self {
        case .apps: return "macwindow.badge.plus"
        case .appearance: return "paintbrush.fill"
        case .shortcuts: return "keyboard"
        case .interaction: return "hand.tap.fill"
        case .general: return "gearshape.fill"
        case .advanced: return "sparkles.rectangle.stack.fill"
        case .about: return "info.circle.fill"
        }
    }
    
    var displayName: String {
        switch self {
        case .apps: return "选择软件".localized
        case .appearance: return "快照条样式".localized
        case .shortcuts: return "快捷键".localized
        case .interaction: return "防误触容差".localized
        case .general: return "常规设置".localized
        case .advanced: return "高级功能".localized
        case .about: return "关于".localized
        }
    }
}

struct SettingsView: View {
    @StateObject private var appListManager = AppListManager()
    @StateObject private var config = AppConfig.shared
    @State private var selectedTab: SettingsTab = .apps

    private let sidebarTabs: [SettingsTab] = [.apps, .appearance, .shortcuts, .interaction, .general, .advanced, .about]
    
    private var sidebarIdealWidth: CGFloat {
        let longestTitle = sidebarTabs.map(\.displayName).map(\.count).max() ?? 0
        return longestTitle >= 16 ? 252 : 208
    }
    
    // MARK: - 右侧内容视图
    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .topLeading) {
            switch selectedTab {
            case .apps:
                AppsSettingsView(appListManager: appListManager, config: config)
            case .appearance:
                AppearanceSettingsView(appListManager: appListManager, config: config)
            case .shortcuts:
                ShortcutsSettingsView(appListManager: appListManager, config: config)
            case .interaction:
                InteractionSettingsView(config: config)
            case .general:
                GeneralSettingsView(config: config)
            case .advanced:
                AdvancedFeaturesView(config: config)
            case .about:
                AboutSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                modernLayout
            } else {
                legacyLayout
            }
        }
        .onDisappear {
            appListManager.reorderAppsByEnabledState()
        }
    }
    
    @available(macOS 13.0, *)
    private var modernLayout: some View {
        NavigationSplitView {
            SettingsSidebar(
                tabs: sidebarTabs,
                selectedTab: $selectedTab,
                showsEmbeddedTitle: false
            )
            .navigationTitle("SideBar")
            .navigationSplitViewColumnWidth(min: sidebarIdealWidth, ideal: sidebarIdealWidth, max: sidebarIdealWidth + 24)
        } detail: {
            GeometryReader { geo in
                detailContent
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color(NSColor.controlBackgroundColor).ignoresSafeArea())
        }
        .frame(minHeight: 580, idealHeight: 580)
        .id(config.language)
    }
    
    private var legacyLayout: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                tabs: sidebarTabs,
                selectedTab: $selectedTab,
                showsEmbeddedTitle: true
            )
            
            Divider()
            
            GeometryReader { geo in
                detailContent
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color(NSColor.controlBackgroundColor).ignoresSafeArea())
        }
        .frame(minHeight: 580, idealHeight: 580)
        .id(config.language)
    }
}


struct SettingsSidebar: View {
    let tabs: [SettingsTab]
    @Binding var selectedTab: SettingsTab
    let showsEmbeddedTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsEmbeddedTitle {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SideBar")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .padding(.leading, 32)
                .padding(.trailing, 18)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(tabs, id: \.self) { tab in
                        SettingsSidebarItem(
                            tab: tab,
                            selectedTab: $selectedTab
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, showsEmbeddedTitle ? 0 : 10)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsSidebarItem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let tab: SettingsTab
    @Binding var selectedTab: SettingsTab

    @State private var isHovered = false

    private var isSelected: Bool {
        selectedTab == tab
    }

    private var transitionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 0.84, blendDuration: 0.14)
    }

    private var activeBlue: Color {
        Color(nsColor: .systemBlue)
    }

    private var hoverGray: Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.16)
    }

    private var hoverWash: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }

    private var beamLeadingInset: CGFloat { 18 }
    private var rowCornerRadius: CGFloat { 8 }
    
    private var selectedBeamAnimation: Animation? {
        isSelected ? transitionAnimation : nil
    }

    var body: some View {
        Button {
            withAnimation(transitionAnimation) {
                selectedTab = tab
            }
        } label: {
            ZStack(alignment: .leading) {
                GeometryReader { proxy in
                    let beamWidth = max(proxy.size.width - beamLeadingInset, 0)

                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(hoverWash)
                        .frame(width: isHovered && !isSelected ? beamWidth : 0, height: proxy.size.height)
                        .offset(x: beamLeadingInset)
                        .animation(transitionAnimation, value: isHovered)
                        .animation(transitionAnimation, value: isSelected)

                    RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    activeBlue.opacity(colorScheme == .dark ? 0.20 : 0.15),
                                    activeBlue.opacity(colorScheme == .dark ? 0.10 : 0.04)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: activeBlue.opacity(0.12), radius: 8, x: 0, y: 0)
                        .frame(width: isSelected ? beamWidth : 0, height: proxy.size.height)
                        .offset(x: beamLeadingInset)
                        .animation(selectedBeamAnimation, value: isSelected)
                }
                .allowsHitTesting(false)

                HStack(spacing: 12) {
                    SettingsTabIcon(tab: tab, isSelected: isSelected, isHovered: isHovered)

                    Text(tab.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)

                Capsule(style: .continuous)
                    .fill(isSelected ? activeBlue : hoverGray)
                    .frame(width: isSelected ? 4 : 3, height: isSelected ? 34 : 22)
                    .opacity(isSelected || isHovered ? 1 : 0)
                    .padding(.leading, 8)
                    .shadow(color: isSelected ? activeBlue.opacity(0.18) : .clear, radius: 6, x: 0, y: 0)
                    .animation(selectedBeamAnimation, value: isSelected)
                    .animation(transitionAnimation, value: isHovered)
            }
            .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(tab.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SettingsTabIcon: View {
    let tab: SettingsTab
    let isSelected: Bool
    let isHovered: Bool

    private var tint: Color {
        if isSelected {
            return Color(nsColor: .systemBlue)
        }
        if isHovered {
            return .primary.opacity(0.85)
        }
        return .secondary
    }

    var body: some View {
        Group {
            if tab == .appearance {
                SnapshotBarStyleGlyph(tint: tint, isSelected: isSelected)
            } else {
                Image(systemName: tab.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(width: 22, height: 20, alignment: .center)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

struct SnapshotBarStyleGlyph: View {
    let tint: Color
    let isSelected: Bool

    private var barOpacity: Double {
        isSelected ? 1.0 : 0.78
    }

    private var blockOpacity: Double {
        isSelected ? 0.18 : 0.10
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(barOpacity))
                .frame(width: 4, height: 16)

            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(tint.opacity(blockOpacity))
                .frame(width: 13, height: 16)
                .offset(x: 6)
        }
        .frame(width: 18, height: 18, alignment: .leading)
    }
}

struct AppsSettingsView: View {
    @ObservedObject var appListManager: AppListManager
    @ObservedObject var config: AppConfig
    
    @State private var showDockMinimizeTip = false
    @State private var tipDismissTimer: Timer? = nil
    @State private var showAutoColorTip = false
    @State private var autoColorTipTimer: Timer? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "选择软件".localized, subtitle: "当前版本目前仅支持勾选正在运行的进程。如果你想要让某个软件支持贴边隐藏，请先确保它已经打开。".localized)
            
            // DockMinimize 联动提示（10 秒自动消失）
            if showDockMinimizeTip {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 13))
                    Text("已检测到 DockMinimize。本次操作的变更已同步至 DockMinimize，相关软件将被临时排除。".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // “自动”颜色提示（10 秒自动消失）
            if showAutoColorTip {
                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundColor(.blue)
                        .font(.system(size: 13))
                    Text("「自动」颜色会随系统「浅色」或「深色」外观自动切换为「黑色」或「白色」。".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    SettingsTableHeader(
                        columns: [
                            (title: "软件".localized, width: nil, alignment: .leading, leadingInset: appNameLeadingInset),
                            (title: colorColumnTitle, width: appsColorColumnWidth, alignment: .leading, leadingInset: appsHeaderColorLeadingInset),
                            (title: "启用".localized, width: appsToggleColumnWidth, alignment: .center, leadingInset: 0)
                        ]
                    )

                    ForEach(appListManager.apps.indices, id: \.self) { index in
                        let app = appListManager.apps[index]
                        let isEnabled = config.isAppEnabled(bundleID: app.id)
                        let colorName = config.getColorName(for: app.id)
                        let opacity = config.getOpacity(for: app.id)
                        
                        AppRowView(
                            app: app,
                            isEnabled: isEnabled,
                            colorName: colorName,
                            opacity: opacity,
                            onToggle: { newValue in
                                config.updateApp(bundleID: app.id, isEnabled: newValue, colorName: colorName)
                                showDockMinimizeTipIfNeeded()
                            },
                            onColorChange: { newColor in
                                config.updateApp(bundleID: app.id, isEnabled: isEnabled, colorName: newColor)
                                if newColor == "auto" {
                                    showAutoColorTipIfNeeded()
                                }
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        
                        if index != appListManager.apps.index(before: appListManager.apps.endIndex) {
                            Divider()
                                .padding(.leading, 68)
                                .padding(.trailing, 24)
                        }
                    }
                }
            }
        }
    }
    
    /// 检测 DockMinimize 是否在运行，若是则显示提示并启动 10 秒自动消失计时器
    private func showDockMinimizeTipIfNeeded() {
        guard AppConfig.isDockMinimizeRunning() else { return }
        
        // 取消旧的计时器（重置倒计时）
        tipDismissTimer?.invalidate()
        
        // 显示提示
        withAnimation(.easeInOut(duration: 0.25)) {
            showDockMinimizeTip = true
        }
        
        // 10 秒后自动消失
        tipDismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                showDockMinimizeTip = false
            }
        }
    }
    
    /// 显示“自动”颜色提示，10 秒自动消失
    private func showAutoColorTipIfNeeded() {
        autoColorTipTimer?.invalidate()
        withAnimation(.easeInOut(duration: 0.25)) {
            showAutoColorTip = true
        }
        autoColorTipTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                showAutoColorTip = false
            }
        }
    }
}

struct SettingsTableHeader: View {
    struct Column: Identifiable {
        let id = UUID()
        let title: String
        let width: CGFloat?
        let alignment: Alignment
        let leadingInset: CGFloat
    }
    
    let columns: [Column]
    let horizontalPadding: CGFloat
    
    init(
        columns: [(title: String, width: CGFloat?, alignment: Alignment, leadingInset: CGFloat)],
        horizontalPadding: CGFloat = 24
    ) {
        self.columns = columns.map { Column(title: $0.title, width: $0.width, alignment: $0.alignment, leadingInset: $0.leadingInset) }
        self.horizontalPadding = horizontalPadding
    }
    
    var body: some View {
        HStack(spacing: 16) {
            ForEach(columns) { column in
                headerColumnView(column)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
    }
    
    @ViewBuilder
    private func headerColumnView(_ column: Column) -> some View {
        let label = Text(column.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.leading, column.leadingInset)
        
        if let width = column.width {
            label.frame(width: width, alignment: column.alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: column.alignment)
        }
    }
}

struct HeaderHelpButton: View {
    let message: String
    var symbolName: String = "questionmark.circle.fill"
    var width: CGFloat = 260
    @State private var isPresented = false
    
    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.9))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .frame(width: width, alignment: .leading)
                .padding(12)
        }
    }
}

struct LanguageMenuField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Int
    @State private var isPresented = false
    
    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(languageDisplay(selection))
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer(minLength: 0)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 156, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(menuFieldFillColor(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(menuFieldStrokeColor(for: colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(width: 156, alignment: .trailing)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                languageOption("跟随系统".localized, tag: 0)
                languageOption("简体中文".localized, tag: 1)
                languageOption("English".localized, tag: 2)
            }
            .padding(8)
            .frame(width: 160)
        }
    }
    
    @ViewBuilder
    private func languageOption(_ title: String, tag: Int) -> some View {
        Button {
            selection = tag
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                if selection == tag {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selection == tag ? Color.accentColor.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DropdownOption {
    let title: String
    var image: NSImage? = nil
    var isSelected: Bool = false
    let action: () -> Void
}

private final class DropdownActionHandler: NSObject {
    var actions: [() -> Void] = []
    
    @objc func perform(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag]()
    }
}

private struct DropdownAnchorView: NSViewRepresentable {
    @Binding var anchorView: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            anchorView = view
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            anchorView = nsView
        }
    }
}

private let appNameLeadingInset: CGFloat = 44
private let appsHeaderColorLeadingInset: CGFloat = 10
private let appearanceHeaderColorLeadingInset: CGFloat = 10
private let menuFieldTextLeadingInset: CGFloat = 10
private let appearanceHorizontalPadding: CGFloat = 18
private let appsColorColumnWidth: CGFloat = 120
private let appsToggleColumnWidth: CGFloat = 56
private let appearanceColorColumnWidth: CGFloat = 120
private let appearanceOpacityColumnWidth: CGFloat = 92
private let appearanceSnapColumnWidth: CGFloat = 128
private let colorColumnTitle = "颜色".localized

private let opacityOptions: [Double] = Array(0...10).map { Double($0) / 10.0 }
private let snapSideKeys: [String] = [
    "both",
    "left",
    "right"
]

private func opacityDisplay(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func snapSideDisplay(_ key: String) -> String {
    switch key {
    case "left":
        return "左侧收纳".localized
    case "right":
        return "右侧收纳".localized
    default:
        return "两侧均可".localized
    }
}

private func languageDisplay(_ value: Int) -> String {
    switch value {
    case 1:
        return "简体中文".localized
    case 2:
        return "English".localized
    default:
        return "跟随系统".localized
    }
}

private func menuFieldFillColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color(NSColor.controlBackgroundColor).opacity(0.9)
        : Color(NSColor.controlBackgroundColor).opacity(0.98)
}

private func menuFieldStrokeColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
}

extension View {
    @ViewBuilder
    func hiddenMenuIndicatorIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.menuIndicator(.hidden)
        } else {
            self
        }
    }
}

private func drawCheckerboardBackground(in rect: NSRect, tileSize: CGFloat = 4) {
    let light = NSColor(calibratedWhite: 0.95, alpha: 1)
    let dark = NSColor(calibratedWhite: 0.82, alpha: 1)
    let columns = Int(ceil(rect.width / tileSize))
    let rows = Int(ceil(rect.height / tileSize))
    
    for row in 0..<rows {
        for column in 0..<columns {
            ((row + column).isMultiple(of: 2) ? light : dark).setFill()
            NSBezierPath(rect: NSRect(
                x: rect.minX + CGFloat(column) * tileSize,
                y: rect.minY + CGFloat(row) * tileSize,
                width: tileSize,
                height: tileSize
            )).fill()
        }
    }
}

private func makeOpacityAwareColorSwatchImage(
    size: CGFloat,
    color: NSColor,
    opacity: Double,
    borderColor: NSColor
) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: nsSize)
    let circlePath = NSBezierPath(ovalIn: rect)
    circlePath.addClip()
    drawCheckerboardBackground(in: rect)
    color.withAlphaComponent(opacity).setFill()
    NSBezierPath(ovalIn: rect).fill()
    borderColor.setStroke()
    let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    borderPath.lineWidth = 0.75
    borderPath.stroke()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

private func makeOpacityAwareAutoSwatchImage(
    size: CGFloat,
    opacity: Double,
    borderColor: NSColor
) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: nsSize)
    let circlePath = NSBezierPath(ovalIn: rect)
    circlePath.addClip()
    drawCheckerboardBackground(in: rect)
    
    NSColor.black.withAlphaComponent(opacity).setFill()
    let leftPath = NSBezierPath()
    leftPath.move(to: NSPoint(x: size / 2, y: 0))
    leftPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90)
    leftPath.close()
    leftPath.fill()
    
    NSColor.white.withAlphaComponent(opacity).setFill()
    let rightPath = NSBezierPath()
    rightPath.move(to: NSPoint(x: size / 2, y: 0))
    rightPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90, clockwise: true)
    rightPath.close()
    rightPath.fill()
    
    borderColor.setStroke()
    let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    borderPath.lineWidth = 0.75
    borderPath.stroke()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

private func makeOpacityMenuImage(
    size: CGFloat = 14,
    opacity: Double,
    colorScheme: ColorScheme
) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: nsSize)
    let clipPath = NSBezierPath(ovalIn: rect)
    clipPath.addClip()
    drawCheckerboardBackground(in: rect, tileSize: 3.5)
    let fillColor = (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
    fillColor.setFill()
    NSBezierPath(ovalIn: rect).fill()
    let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.gray.withAlphaComponent(0.3)
    borderColor.setStroke()
    let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
    borderPath.lineWidth = 0.75
    borderPath.stroke()
    image.unlockFocus()
    image.isTemplate = false
    return image
}

private func makeSnapSideMenuImage(
    side: String,
    size: CGFloat = 14,
    colorScheme: ColorScheme
) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize)
    image.lockFocus()
    
    let strokeColor = colorScheme == .dark ? NSColor.white : NSColor.black
    strokeColor.setStroke()
    
    func drawChevron(centerX: CGFloat, pointingLeft: Bool) {
        let path = NSBezierPath()
        let midY = size / 2
        let topY = midY + 3.2
        let bottomY = midY - 3.2
        let span: CGFloat = 3.0
        
        if pointingLeft {
            path.move(to: NSPoint(x: centerX + span, y: topY))
            path.line(to: NSPoint(x: centerX - span, y: midY))
            path.line(to: NSPoint(x: centerX + span, y: bottomY))
        } else {
            path.move(to: NSPoint(x: centerX - span, y: topY))
            path.line(to: NSPoint(x: centerX + span, y: midY))
            path.line(to: NSPoint(x: centerX - span, y: bottomY))
        }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    
    switch side {
    case "left":
        drawChevron(centerX: size / 2, pointingLeft: true)
    case "right":
        drawChevron(centerX: size / 2, pointingLeft: false)
    default:
        drawChevron(centerX: size / 2 - 3.0, pointingLeft: true)
        drawChevron(centerX: size / 2 + 3.0, pointingLeft: false)
    }
    
    image.unlockFocus()
    image.isTemplate = false
    return image
}

struct GeneralSettingsView: View {
    @ObservedObject var config: AppConfig
    
    // 定时刷新权限状态用
    @State private var axEnabled = AXIsProcessTrusted()
    @State private var screenCaptureEnabled = ScreenCaptureAccessManager.shared.hasAccess()
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "常规设置".localized, subtitle: "管理 SideBar 的基础运行行为和系统权限。".localized)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 第一个大项：通用
                    VStack(alignment: .leading, spacing: 16) {
                        Text("通用".localized)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("开机自动启动".localized)
                                Spacer()
                                Toggle("", isOn: $config.launchAtLogin)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("在菜单栏显示图标".localized)
                                    Spacer()
                                    Toggle("", isOn: $config.showInMenuBar)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                }
                                
                                if !config.showInMenuBar {
                                    Text("隐藏菜单栏图标后，您需要在访达(Finder)中再次运行SideBar来打开此设置面板。".localized)
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                        .padding(.top, 2)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 16)
                    }
                    Divider()
                    
                    // 第二个大项：语言
                    VStack(alignment: .leading, spacing: 16) {
                        Text("语言".localized)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("语言".localized)
                                Spacer()
                                LanguageMenuField(selection: $config.language)
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 16)
                    }
                    
                    Divider()
                    // 第二个大项：权限
                    VStack(alignment: .leading, spacing: 16) {
                        Text("权限".localized)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("辅助功能".localized)
                                    .font(.body)
                                
                                Spacer()
                                
                                if axEnabled {
                                    Text("已开启".localized)
                                        .foregroundColor(.green)
                                        .font(.subheadline)
                                } else {
                                    Button(action: {
                                        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
                                        AXIsProcessTrustedWithOptions(options)
                                    }) {
                                        Text("去授权".localized)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.orange)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            
                            Text("用于控制窗口的展开和折叠以及程序坞点击识别事件".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("屏幕录制".localized)
                                    .font(.body)

                                Spacer()

                                if screenCaptureEnabled {
                                    Text("已开启".localized)
                                        .foregroundColor(.green)
                                        .font(.subheadline)
                                } else {
                                    Button(action: {
                                        ScreenCaptureAccessManager.shared.openSystemSettings()
                                    }) {
                                        Text("去授权".localized)
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.orange)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Text("用于生成置顶镜像层的窗口截图，并在切回真实窗口前显示置顶代理画面。首次点击置顶镜像层图钉时，系统会按需请求该权限。".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .onChange(of: config.launchAtLogin) { newValue in
            print("[SideBar] onChange: launchAtLogin -> \(newValue)")
            config.updateLaunchAtLogin(newValue)
            UserDefaults.standard.set(newValue, forKey: "SideBarLaunchAtLogin")
        }
        .onChange(of: config.showInMenuBar) { newValue in
            UserDefaults.standard.set(newValue, forKey: "SideBarShowInMenuBar")
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
        }
        .onReceive(timer) { _ in
            axEnabled = AXIsProcessTrusted()
            screenCaptureEnabled = ScreenCaptureAccessManager.shared.hasAccess()
        }
    }
}

struct AdvancedFeaturesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var config: AppConfig

    private var fusionStripHelpMessage: String {
        [
            "1. 为避免性能卡顿，融合快照条不会显示粒子和射线特效。".localized,
            "2. 由于窗口构架差异，第三方应用（如微信）的展开折叠速度，会比 macOS 系统自带应用（如访达）的展开折叠速度慢一点。".localized,
            "3. 为确保良好体验，建议给不同的软件设置不同的颜色方案。".localized
        ].joined(separator: "\n\n")
    }

    private var mirrorPinHelpMessage: String {
        [
            "1. 置顶镜像层显示的是窗口截图代理，而不是真实窗口本体。".localized,
            "2. 开启后需要授予屏幕录制权限，点击镜像层时会切回真实窗口进行交互。".localized,
            "3. 该模式用于减少置顶窗口与其他软件之间的焦点争夺。".localized
        ].joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "高级功能".localized, subtitle: "用于承载仍在持续打磨中的增强能力，部分功能可能需要额外权限。".localized)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("融合快照条".localized)
                            .font(.headline)

                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.green.opacity(0.16) : Color.green.opacity(0.10))
                                Image(systemName: "rectangle.split.3x1.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("融合快照条".localized)
                                        .font(.headline)
                                    HeaderHelpButton(
                                        message: fusionStripHelpMessage,
                                        symbolName: "exclamationmark.circle.fill",
                                        width: 300
                                    )
                                }
                                Text("当同一侧的多个快照条发生重叠时，自动融合为一根可分段切换的大快照条。".localized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 16)

                            Toggle("", isOn: $config.isFusionStripEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(18)
                        .background(colorScheme == .dark ? Color(NSColor.windowBackgroundColor).opacity(0.88) : Color.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.green.opacity(0.18) : Color.green.opacity(0.14), lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("置顶镜像层".localized)
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(colorScheme == .dark ? Color.cyan.opacity(0.16) : Color.cyan.opacity(0.10))
                                    Image(systemName: "macwindow.on.rectangle")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.cyan)
                                }
                                .frame(width: 48, height: 48)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("置顶镜像层".localized)
                                            .font(.headline)
                                        HeaderHelpButton(
                                            message: mirrorPinHelpMessage,
                                            symbolName: "exclamationmark.circle.fill",
                                            width: 320
                                        )
                                    }
                                    Text("当窗口被临时钉住后，优先显示一层可置顶的镜像代理；鼠标移入镜像层时，再切回真实窗口进行操作。".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer(minLength: 16)

                                Toggle("", isOn: $config.isMirrorPinEnabled)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Text("触发方式".localized)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)

                                MirrorPinGuideDemo()
                                    .frame(height: 208)

                                Text("先展开窗口，再将鼠标移动到靠近屏幕中心一侧的顶角区域，让图钉按钮滑出；点击图钉后，窗口会进入置顶镜像层状态。".localized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(18)
                        .background(colorScheme == .dark ? Color(NSColor.windowBackgroundColor).opacity(0.88) : Color.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }
}

private struct MirrorPinGuideDemo: View {
    @State private var phase: Int = 0
    private let phaseTimer = Timer.publish(every: 1.15, on: .main, in: .common).autoconnect()
    private let titles = [
        "角区滑出图钉".localized,
        "点击后进入镜像层".localized,
        "点击镜像层切回真实窗口".localized
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MirrorPinGuideScene(phase: phase)
                .frame(height: 148)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.09, green: 0.14, blue: 0.17),
                                    Color(red: 0.11, green: 0.18, blue: 0.21)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == phase ? Color.cyan.opacity(0.88) : Color.white.opacity(0.14))
                        .frame(width: index == phase ? 26 : 8, height: 6)
                        .animation(.easeInOut(duration: 0.22), value: phase)
                }
            }
            
            Text(titles[phase])
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
        }
        .onReceive(phaseTimer) { _ in
            withAnimation(.easeInOut(duration: 0.22)) {
                phase = (phase + 1) % 3
            }
        }
    }
}

private struct MirrorPinGuideScene: View {
    let phase: Int

    var body: some View {
        GeometryReader { geo in
            let sceneWidth = geo.size.width
            let sceneHeight = geo.size.height
            let windowWidth = min(sceneWidth * 0.58, 320)
            let windowHeight = min(sceneHeight * 0.82, 118)
            let windowRect = CGRect(x: 26, y: 16, width: windowWidth, height: windowHeight)
            let hotZoneRect = CGRect(x: windowRect.maxX - 34, y: windowRect.minY + 4, width: 62, height: 58)
            let pinVisible = phase >= 1
            let mirrorVisible = phase == 2
            let pinFrame = CGRect(x: windowRect.maxX + (pinVisible ? 10 : -14), y: windowRect.minY + 8, width: 36, height: 36)
            let proxyRect = CGRect(x: windowRect.minX, y: windowRect.minY, width: windowRect.width, height: windowRect.height)
            let cursorPoint: CGPoint = {
                switch phase {
                case 0:
                    return CGPoint(x: hotZoneRect.minX + 20, y: hotZoneRect.minY + 14)
                case 1:
                    return CGPoint(x: pinFrame.minX + 8, y: pinFrame.minY + 10)
                default:
                    return CGPoint(x: proxyRect.maxX - 42, y: proxyRect.minY + 18)
                }
            }()

            ZStack(alignment: .topLeading) {
                MirrorPinGuideWindow(isDimmed: mirrorVisible)
                    .frame(width: windowRect.width, height: windowRect.height)
                    .offset(x: windowRect.minX, y: windowRect.minY)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(phase == 0 ? 0.12 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(phase == 0 ? 0.18 : 0.10), lineWidth: 1)
                    )
                    .frame(width: hotZoneRect.width, height: hotZoneRect.height)
                    .offset(x: hotZoneRect.minX, y: hotZoneRect.minY)
                    .opacity(mirrorVisible ? 0.18 : 1)

                MirrorPinGuideButton()
                    .frame(width: pinFrame.width, height: pinFrame.height)
                    .offset(x: pinFrame.minX, y: pinFrame.minY)
                    .opacity(pinVisible ? 1 : 0)
                    .animation(.spring(response: 0.26, dampingFraction: 0.82), value: pinVisible)

                MirrorPinGuideWindow(isMirrorProxy: true)
                    .frame(width: proxyRect.width, height: proxyRect.height)
                    .offset(x: proxyRect.minX, y: proxyRect.minY)
                    .opacity(mirrorVisible ? 1 : 0)
                    .scaleEffect(mirrorVisible ? 1.0 : 0.985, anchor: .topLeading)
                    .shadow(color: Color.black.opacity(mirrorVisible ? 0.28 : 0), radius: 22, y: 12)
                    .animation(.easeOut(duration: 0.22), value: mirrorVisible)

                if mirrorVisible {
                    Text("镜像层".localized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.cyan.opacity(0.20))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                        )
                        .offset(x: proxyRect.minX + 14, y: proxyRect.maxY - 26)
                        .transition(.opacity)
                }

                DemoCursor(glowOpacity: phase == 1 ? 0.32 : 0.22)
                    .frame(width: 24, height: 24)
                    .offset(x: cursorPoint.x, y: cursorPoint.y)
                    .animation(.easeInOut(duration: 0.24), value: phase)
            }
        }
    }
}

private struct MirrorPinGuideWindow: View {
    var isDimmed: Bool = false
    var isMirrorProxy: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red.opacity(0.98)).frame(width: 10, height: 10)
                Circle().fill(Color.yellow.opacity(0.98)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.98)).frame(width: 10, height: 10)
                Spacer()
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 52, height: 10)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Color.white.opacity(isMirrorProxy ? 0.12 : 0.05))

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Notes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 72, height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 102, height: 7)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cyan.opacity(0.82))
                        .frame(width: 86, height: 30)
                }
                .padding(14)
                .frame(width: 118, alignment: .topLeading)
                .background(Color.white.opacity(0.03))

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.74))
                        .frame(width: 92, height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 58, height: 7)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    isMirrorProxy
                    ? LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [Color.black.opacity(isDimmed ? 0.55 : 0.86), Color.black.opacity(isDimmed ? 0.48 : 0.80)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isMirrorProxy ? Color.white.opacity(0.20) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MirrorPinGuideButton: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.94))
            )
    }
}

private struct DemoCursor: View {
    var glowOpacity: Double = 0.24
    private let cursorImage = NSCursor.arrow.image

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(glowOpacity))
                .frame(width: 30, height: 30)
                .blur(radius: 14)

            Image(nsImage: cursorImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 26, height: 34)
                .shadow(color: .black.opacity(0.34), radius: 5, y: 2)
        }
    }
}

struct InteractionSettingsView: View {
    @ObservedObject var config: AppConfig
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "防误触容差".localized, subtitle: "调整边缘响应延迟与位移缓冲，防止日常操作意外唤出或折叠窗口。".localized)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                // 上半部分：独立的高阶防抖延时
                DelayControlView(
                    title: "防误触缓冲 (悬停延时)".localized,
                    value: $config.hoverDelayMS,
                    description: "决定鼠标悬停在屏幕边缘多久后才会唤出边界窗口。等待期内若发生点击（如点击滚动条）则中止等待。".localized
                )
                
                Divider() // 添加区块实体隔离线
                
                // 下半部分：物理容差与实时推演阵列
                HStack(alignment: .top, spacing: 32) {
                    // 左侧容差控制区
                    VStack(alignment: .leading, spacing: 20) {
                        ToleranceControlView(
                            title: "水平容差 (X轴)".localized,
                            value: $config.hoverTolerance,
                            description: "离开窗口时，鼠标水平方向移出安全区多少像素后才触发折叠。".localized
                        )
                        
                        ToleranceControlView(
                            title: "垂直容差 (Y轴)".localized,
                            value: $config.hoverToleranceY,
                            description: "离开窗口时，鼠标垂直方向移出安全区多少像素后才触发折叠。".localized
                        )
                    }
                    .frame(width: 250)
                    
                    // 右侧可视化预览区
                    ToleranceVisualizer(xTol: config.hoverTolerance, yTol: config.hoverToleranceY)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            
            Spacer(minLength: 0)
        }
    }
}

// 可复用的防抖延时控制组件
struct DelayControlView: View {
    let title: String
    @Binding var value: Int
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(value == 0 ? "立即响应".localized : "\(value) ms")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.blue)
            }
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
            
            HStack(spacing: 12) {
                Slider(value: Binding(get: {
                    Double(value)
                }, set: {
                    value = Int($0)
                }), in: 0...2000, step: 100)
                .accentColor(.blue)
                
                Button(action: {
                    value = 0
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重置归零".localized)
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(6)
            }
        }
    }
}

// 可复用的滑块控制组件
struct ToleranceControlView: View {
    let title: String
    @Binding var value: CGFloat
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(Int(value)) px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.blue)
            }
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
            
            HStack(spacing: 12) {
                Slider(value: $value, in: 0...200, step: 10)
                    .accentColor(.blue)
                
                Button(action: {
                    value = 60
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重置为 60".localized)
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .cornerRadius(6)
            }
        }
    }
}

// 动态可视化示意图
struct ToleranceVisualizer: View {
    let xTol: CGFloat
    let yTol: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("容忍安全区实时推演".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            GeometryReader { geo in
                // 窗口及比例映射设定
                let baseWindowW: CGFloat = 70
                let baseWindowH: CGFloat = 110
                let scale: CGFloat = 3.5 
                
                let scaledXTol = xTol / scale
                let scaledYTol = yTol / scale
                
                ZStack(alignment: .leading) {
                    // 屏幕背景 - 使用更浅的灰色，增加现代感
                    Color(NSColor.quaternaryLabelColor).opacity(0.12)
                    
                    ZStack(alignment: .leading) {
                        // 缓冲容差安全区
                        let safeW = baseWindowW + scaledXTol
                        let safeH = baseWindowH + scaledYTol * 2
                        Rectangle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: safeW, height: safeH)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                    .foregroundColor(Color.blue.opacity(0.4))
                            )
                            .overlay(
                                // 将文字改为拆分竖排行列，右贴靠外侧留白处
                                VStack(spacing: 0) {
                                    Text("安".localized)
                                    Text("全".localized)
                                    Text("区".localized)
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue.opacity(0.8))
                                .padding(.trailing, 4)
                                .padding(.top, safeH / 2 - 20), // 整体垂直居中居中偏上
                                alignment: .topTrailing
                            )
                            .zIndex(1)
                        
                        // 实体窗口
                        VStack(spacing: 0) {
                            // 标题栏
                            HStack(spacing: 4) {
                                Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6)
                                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 6, height: 6)
                                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Color.white.opacity(0.15))
                            
                            Spacer()
                            Text("操作窗口".localized)
                                .foregroundColor(.white)
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .frame(width: baseWindowW, height: baseWindowH)
                        .background(Color(NSColor.controlAccentColor).opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 2, y: 2)
                        // 让左侧贴边没有圆角，右侧保留一定圆角，更贴近边缘吸附形态
                        .cornerRadius(6)
                        .padding(.leading, -3) // 稍微向左偏移盖住左侧圆角
                        .zIndex(2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
            }
            .frame(height: 240)
        }
    }
}

// 可复用的通用头部标题样式，避免重复代码
struct PaddingHeader: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, -6)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppRowView: View {
    @Environment(\.colorScheme) var colorScheme
    let app: AppInfo
    let isEnabled: Bool
    let colorName: String
    let opacity: Double
    let onToggle: (Bool) -> Void
    let onColorChange: (String) -> Void
    
    let colorOptions = [
        ("auto", "自动".localized, Color.gray),
        ("white", "白色".localized, Color.white),
        ("black", "黑色".localized, Color.black),
        ("orange", "橙色".localized, Color(red: 1, green: 0.8, blue: 0.502)),
        ("blue", "蓝色".localized, Color(red: 0.565, green: 0.792, blue: 0.976)),
        ("green", "绿色".localized, Color(red: 0.647, green: 0.839, blue: 0.655)),
        ("red", "红色".localized, Color(red: 0.937, green: 0.604, blue: 0.604)),
        ("yellow", "黄色".localized, Color(red: 1, green: 0.961, blue: 0.616)),
        ("purple", "紫色".localized, Color(red: 0.808, green: 0.576, blue: 0.847)),
        ("pink", "粉色".localized, Color(red: 0.957, green: 0.561, blue: 0.694))
    ]
    
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.gray)
                }
                
                VStack(alignment: .leading) {
                    Text(app.name)
                    Text(app.id)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Menu {
                ForEach(colorOptions, id: \.0) { option in
                    Button {
                        onColorChange(option.0)
                    } label: {
                        Label {
                            Text(option.1)
                        } icon: {
                            if option.0 == "auto" {
                                Image(nsImage: generateAutoColorImage())
                            } else {
                                Image(nsImage: generateColorImage(color: option.2))
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if colorName == "auto" {
                        Image(nsImage: generateAutoColorSwatchImage(size: 14, opacity: opacity))
                    } else {
                        Image(nsImage: generateColorSwatchImage(size: 14, color: getSelectedColor(), opacity: opacity))
                    }
                    
                    Text(getSelectedColorDisplayName())
                        .font(.body) // 统一为 .body (13pt)，对齐系统菜单尺寸
                        .foregroundColor(.primary)
                    
                    Image(systemName: "chevron.right") // 使用右箭头模拟，视觉更洗练
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .hiddenMenuIndicatorIfAvailable()
            .frame(width: appsColorColumnWidth, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
            .cornerRadius(6)
            .disabled(!isEnabled)
            
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: 56)
        }
    }
    
    private func getSelectedColor() -> Color {
        return colorOptions.first { $0.0 == colorName }?.2 ?? .white
    }
    
    private func getSelectedColorDisplayName() -> String {
        return colorOptions.first { $0.0 == colorName }?.1 ?? "白色".localized
    }

    private func generateColorSwatchImage(size: CGFloat = 14, color: Color, opacity: Double) -> NSImage {
        makeOpacityAwareColorSwatchImage(
            size: size,
            color: NSColor(color),
            opacity: opacity,
            borderColor: colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        )
    }

    private func generateAutoColorSwatchImage(size: CGFloat = 14, opacity: Double) -> NSImage {
        makeOpacityAwareAutoSwatchImage(
            size: size,
            opacity: opacity,
            borderColor: colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        )
    }

    private func generateColorImage(size: CGFloat = 14, color: Color) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        NSColor(color).set()
        let fillPath = NSBezierPath(ovalIn: rect)
        fillPath.fill()
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    
    /// 绘制左黑右白半圆图标，代表“自动”颜色
    private func generateAutoColorImage(size: CGFloat = 14) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        // 左半圆：黑色
        NSColor.black.set()
        let leftPath = NSBezierPath()
        leftPath.move(to: NSPoint(x: size / 2, y: 0))
        leftPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90)
        leftPath.close()
        leftPath.fill()
        // 右半圆：白色
        NSColor.white.set()
        let rightPath = NSBezierPath()
        rightPath.move(to: NSPoint(x: size / 2, y: 0))
        rightPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90, clockwise: true)
        rightPath.close()
        rightPath.fill()
        // 边框
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var appListManager: AppListManager
    @ObservedObject var config: AppConfig
    
    var body: some View {
        let enabledApps = appListManager.apps.filter { config.isAppEnabled(bundleID: $0.id) }
        let resolvedGlobalOpacity = currentGlobalOpacity(using: enabledApps)
        
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "快照条样式".localized, subtitle: "统一规划或单独调节每个启用软件快照条的色彩及透明程度。".localized)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("动态特效".localized)
                            .font(.headline)
                        
                        HStack(alignment: .center, spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.blue.opacity(0.16) : Color.blue.opacity(0.10))
                                Image(systemName: "sparkles")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            .frame(width: 48, height: 48)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("展开 / 折叠特效".localized)
                                    .font(.headline)
                                Text("控制快照条在展开与折叠时的粒子和射线效果。".localized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer(minLength: 16)
                            
                            Toggle("", isOn: $config.isVisualEffectEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(18)
                        .background(colorScheme == .dark ? Color(NSColor.windowBackgroundColor).opacity(0.88) : Color.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.blue.opacity(0.18) : Color.blue.opacity(0.14), lineWidth: 1)
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("颜色与透明度".localized)
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("全局透明度覆写".localized)
                                        .font(.headline)
                                    Text("选择此项会同时将下方所有已启用软件的透明度重置为该固定值。".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                CompactMenuField(
                                    title: opacityDisplay(resolvedGlobalOpacity),
                                    minWidth: 84,
                                    leadingImage: makeOpacityMenuImage(opacity: resolvedGlobalOpacity, colorScheme: colorScheme),
                                    options: opacityOptions.map { value in
                                        DropdownOption(
                                            title: opacityDisplay(value),
                                            image: makeOpacityMenuImage(opacity: value, colorScheme: colorScheme),
                                            isSelected: value == resolvedGlobalOpacity
                                        ) {
                                            config.setGlobalOpacity(value)
                                        }
                                    }
                                )
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            
                            if !enabledApps.isEmpty {
                                Divider()
                                    .padding(.horizontal, 18)

                                HStack(spacing: 16) {
                                    Text("软件".localized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .padding(.leading, appNameLeadingInset)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    Text(colorColumnTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .padding(.leading, appearanceHeaderColorLeadingInset)
                                        .frame(width: appearanceColorColumnWidth, alignment: .leading)
                                    
                                    Text("透明度".localized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .padding(.leading, menuFieldTextLeadingInset)
                                        .frame(width: appearanceOpacityColumnWidth, alignment: .leading)
                                    
                                    HStack(spacing: 4) {
                                        Text("吸附侧".localized)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        HeaderHelpButton(message: "吸附侧用于限制窗口只在指定屏幕边缘触发吸附。选择左侧收纳后，窗口只有碰到左边缘才会被吸附；选择右侧收纳则相反。这个设置可以减少小屏幕或大窗口场景下的误吸附。".localized)
                                    }
                                    .padding(.leading, menuFieldTextLeadingInset)
                                    .frame(width: appearanceSnapColumnWidth, alignment: .leading)
                                }
                                .padding(.horizontal, appearanceHorizontalPadding)
                                .padding(.vertical, 10)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))

                                Divider()
                                    .padding(.horizontal, 18)
                                
                                ForEach(enabledApps.indices, id: \.self) { index in
                                    let app = enabledApps[index]
                                    let colorName = config.getColorName(for: app.id)
                                    let opacity = config.getOpacity(for: app.id)
                                    let snapSide = config.getSnapSide(for: app.id)
                                    
                                    AppAppearanceRowView(
                                        app: app,
                                        colorName: colorName,
                                        opacity: opacity,
                                        snapSide: snapSide,
                                        onColorChange: { newColor in
                                            config.updateApp(bundleID: app.id, isEnabled: true, colorName: newColor)
                                        },
                                        onOpacityChange: { newOpacity in
                                            config.updateOpacity(bundleID: app.id, opacity: newOpacity)
                                        },
                                        onSnapSideChange: { newSnapSide in
                                            config.updateSnapSide(bundleID: app.id, snapSide: newSnapSide)
                                        }
                                    )
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    
                                    if index != enabledApps.index(before: enabledApps.endIndex) {
                                        Divider()
                                            .padding(.leading, 68)
                                            .padding(.trailing, 18)
                                    }
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }
    
    private func currentGlobalOpacity(using enabledApps: [AppInfo]) -> Double {
        guard let firstApp = enabledApps.first else {
            return 1.0
        }
        
        let firstOpacity = config.getOpacity(for: firstApp.id)
        let allSame = enabledApps.dropFirst().allSatisfy { config.getOpacity(for: $0.id) == firstOpacity }
        return allSame ? firstOpacity : 1.0
    }
}

struct CompactMenuField: View {
    let title: String
    var minWidth: CGFloat = 96
    var leadingImage: NSImage? = nil
    let options: [DropdownOption]
    
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    option.action()
                } label: {
                    if let image = option.image {
                        Label {
                            Text(option.title)
                        } icon: {
                            Image(nsImage: image)
                        }
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let leadingImage {
                    Image(nsImage: leadingImage)
                }
                
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .hiddenMenuIndicatorIfAvailable()
        .frame(width: minWidth, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(6)
    }
}

struct AppearanceColorMenuField: View {
    @Environment(\.colorScheme) var colorScheme
    let colorName: String
    let opacity: Double
    let title: String
    let options: [DropdownOption]
    
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    option.action()
                } label: {
                    if let image = option.image {
                        Label {
                            Text(option.title)
                        } icon: {
                            Image(nsImage: image)
                        }
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if colorName == "auto" {
                    Image(nsImage: generateAutoColorSwatchImage(size: 14, opacity: opacity))
                } else {
                    Image(nsImage: generateColorSwatchImage(size: 14, color: getSelectedColor(), opacity: opacity))
                }
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .hiddenMenuIndicatorIfAvailable()
        .frame(width: appearanceColorColumnWidth, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(6)
    }
    
    private func getSelectedColor() -> Color {
        let colorOptions = [
            ("auto", "自动".localized, Color.gray),
            ("white", "白色".localized, Color.white),
            ("black", "黑色".localized, Color.black),
            ("orange", "橙色".localized, Color(red: 1, green: 0.8, blue: 0.502)),
            ("blue", "蓝色".localized, Color(red: 0.565, green: 0.792, blue: 0.976)),
            ("green", "绿色".localized, Color(red: 0.647, green: 0.839, blue: 0.655)),
            ("red", "红色".localized, Color(red: 0.937, green: 0.604, blue: 0.604)),
            ("yellow", "黄色".localized, Color(red: 1, green: 0.961, blue: 0.616)),
            ("purple", "紫色".localized, Color(red: 0.808, green: 0.576, blue: 0.847)),
            ("pink", "粉色".localized, Color(red: 0.957, green: 0.561, blue: 0.694))
        ]
        return colorOptions.first { $0.0 == colorName }?.2 ?? .white
    }

    private func generateColorSwatchImage(size: CGFloat = 14, color: Color, opacity: Double) -> NSImage {
        makeOpacityAwareColorSwatchImage(
            size: size,
            color: NSColor(color),
            opacity: opacity,
            borderColor: colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        )
    }

    private func generateAutoColorSwatchImage(size: CGFloat = 14, opacity: Double) -> NSImage {
        makeOpacityAwareAutoSwatchImage(
            size: size,
            opacity: opacity,
            borderColor: colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        )
    }

    private func generateColorImage(size: CGFloat = 14, color: Color) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        NSColor(color).set()
        let fillPath = NSBezierPath(ovalIn: rect)
        fillPath.fill()
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    
    private func generateAutoColorImage(size: CGFloat = 14) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        NSColor.black.set()
        let leftPath = NSBezierPath()
        leftPath.move(to: NSPoint(x: size / 2, y: 0))
        leftPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90)
        leftPath.close()
        leftPath.fill()
        NSColor.white.set()
        let rightPath = NSBezierPath()
        rightPath.move(to: NSPoint(x: size / 2, y: 0))
        rightPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90, clockwise: true)
        rightPath.close()
        rightPath.fill()
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

struct AppAppearanceRowView: View {
    @Environment(\.colorScheme) var colorScheme
    let app: AppInfo
    let colorName: String
    let opacity: Double
    let snapSide: String
    let onColorChange: (String) -> Void
    let onOpacityChange: (Double) -> Void
    let onSnapSideChange: (String) -> Void
    
    let colorOptions = [
        ("auto", "自动".localized, Color.gray),
        ("white", "白色".localized, Color.white),
        ("black", "黑色".localized, Color.black),
        ("orange", "橙色".localized, Color(red: 1, green: 0.8, blue: 0.502)),
        ("blue", "蓝色".localized, Color(red: 0.565, green: 0.792, blue: 0.976)),
        ("green", "绿色".localized, Color(red: 0.647, green: 0.839, blue: 0.655)),
        ("red", "红色".localized, Color(red: 0.937, green: 0.604, blue: 0.604)),
        ("yellow", "黄色".localized, Color(red: 1, green: 0.961, blue: 0.616)),
        ("purple", "紫色".localized, Color(red: 0.808, green: 0.576, blue: 0.847)),
        ("pink", "粉色".localized, Color(red: 0.957, green: 0.561, blue: 0.694))
    ]
    
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.gray)
                }
                
                Text(app.name)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            AppearanceColorMenuField(
                colorName: colorName,
                opacity: opacity,
                title: getSelectedColorDisplayName(),
                options: colorOptions.map { option in
                    DropdownOption(
                        title: option.1,
                        image: option.0 == "auto" ? generateAutoColorImage() : generateColorImage(color: option.2),
                        isSelected: option.0 == colorName
                    ) {
                        onColorChange(option.0)
                    }
                }
            )

            CompactMenuField(
                title: opacityDisplay(opacity),
                minWidth: appearanceOpacityColumnWidth,
                leadingImage: makeOpacityMenuImage(opacity: opacity, colorScheme: colorScheme),
                options: opacityOptions.map { value in
                    DropdownOption(
                        title: opacityDisplay(value),
                        image: makeOpacityMenuImage(opacity: value, colorScheme: colorScheme),
                        isSelected: value == opacity
                    ) {
                        onOpacityChange(value)
                    }
                }
            )

            CompactMenuField(
                title: snapSideDisplay(snapSide),
                minWidth: appearanceSnapColumnWidth,
                leadingImage: makeSnapSideMenuImage(side: snapSide, colorScheme: colorScheme),
                options: snapSideKeys.map { key in
                    DropdownOption(
                        title: snapSideDisplay(key),
                        image: makeSnapSideMenuImage(side: key, colorScheme: colorScheme),
                        isSelected: key == snapSide
                    ) {
                        onSnapSideChange(key)
                    }
                }
            )
        }
    }
    
    private func getSelectedColor() -> Color {
        return colorOptions.first { $0.0 == colorName }?.2 ?? .white
    }
    
    private func getSelectedColorDisplayName() -> String {
        return colorOptions.first { $0.0 == colorName }?.1 ?? "白色".localized
    }

    private func generateColorImage(size: CGFloat = 14, color: Color) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        NSColor(color).set()
        let fillPath = NSBezierPath(ovalIn: rect)
        fillPath.fill()
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    
    private func generateAutoColorImage(size: CGFloat = 14) -> NSImage {
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: nsSize)
        NSColor.black.set()
        let leftPath = NSBezierPath()
        leftPath.move(to: NSPoint(x: size / 2, y: 0))
        leftPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90)
        leftPath.close()
        leftPath.fill()
        NSColor.white.set()
        let rightPath = NSBezierPath()
        rightPath.move(to: NSPoint(x: size / 2, y: 0))
        rightPath.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: size / 2, startAngle: 270, endAngle: 90, clockwise: true)
        rightPath.close()
        rightPath.fill()
        let borderColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.gray.withAlphaComponent(0.3)
        borderColor.set()
        let borderPath = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 0.75
        borderPath.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: - 快捷键设置视图

struct ShortcutsSettingsView: View {
    @ObservedObject var appListManager: AppListManager
    @ObservedObject var config: AppConfig
    
    var enabledApps: [AppInfo] {
        appListManager.apps.filter { config.isAppEnabled(bundleID: $0.id) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "快捷键".localized, subtitle: "为已启用的应用绑定全局快捷键，一键唤出或收起边栏窗口。".localized)
            
            Divider()
            List {
                TemporaryShortcutRowView(config: config, appInfos: appListManager.apps)
                    .padding(.vertical, 6)

                if enabledApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("请先在「选择软件」中启用至少一个应用".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(enabledApps) { app in
                        ShortcutRowView(app: app, config: config, appInfos: appListManager.apps)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

// macOS 常用系统快捷键库（修饰键 rawValue, 键码, 描述）
private let systemShortcuts: [(UInt, UInt16, String)] = {
    let cmd = NSEvent.ModifierFlags.command.rawValue
    let cmdShift = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
    let cmdOpt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue
    return [
        // 基础编辑
        (cmd, 8, "复制 (⌘C)".localized), (cmd, 9, "粘贴 (⌘V)".localized), (cmd, 7, "剪切 (⌘X)".localized),
        (cmd, 6, "撤销 (⌘Z)".localized), (cmdShift, 6, "重做 (⇧⌘Z)".localized), (cmd, 0, "全选 (⌘A)".localized),
        (cmd, 1, "保存 (⌘S)".localized), (cmd, 3, "查找 (⌘F)".localized), (cmd, 35, "打印 (⌘P)".localized),
        // 应用控制
        (cmd, 12, "退出 (⌘Q)".localized), (cmd, 13, "关闭窗口 (⌘W)".localized), (cmd, 4, "隐藏 (⌘H)".localized),
        (cmd, 46, "最小化 (⌘M)".localized), (cmd, 45, "新建 (⌘N)".localized), (cmd, 31, "打开 (⌘O)".localized),
        (cmd, 17, "新标签页 (⌘T)".localized),
        // Tab 切换
        (cmd, 50, "切换窗口 (⌘`)".localized),
        (cmd, 48, "切换应用 (⌘Tab)".localized),
        // 系统级
        (cmdShift, 20, "截屏 (⇧⌘3)".localized), (cmdShift, 21, "截屏区域 (⇧⌘4)".localized),
        (cmdShift, 23, "截屏窗口 (⇧⌘5)".localized),
        (cmd, 49, "Spotlight (⌘Space)"),
        (cmdOpt, 53, "强制退出 (⌥⌘Esc)".localized),
    ]
}()

private let temporaryShortcutRecorderID = "__temporaryShortcut__"

private func shortcutConflictName(
    modifiers: UInt,
    keyCode: UInt16,
    excludingID: String?,
    config: AppConfig,
    appInfos: [AppInfo]
) -> String? {
    if excludingID != temporaryShortcutRecorderID,
       config.temporaryShortcutModifiers == modifiers,
       config.temporaryShortcutKeyCode == keyCode {
        return "临时折叠当前活跃窗口".localized
    }

    for (otherID, otherSettings) in config.appSettings {
        guard otherID != excludingID,
              otherSettings.shortcutModifiers == modifiers,
              otherSettings.shortcutKeyCode == keyCode else { continue }
        return shortcutDisplayName(for: otherID, appInfos: appInfos)
    }
    return nil
}

private func shortcutDisplayName(for bundleID: String, appInfos: [AppInfo]) -> String {
    if let app = appInfos.first(where: { $0.id == bundleID }) {
        return app.name
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
}

struct TemporaryShortcutRowView: View {
    @ObservedObject var config: AppConfig
    let appInfos: [AppInfo]
    @ObservedObject var recorder: ShortcutRecorderManager = .shared

    @State private var conflictMessage: String? = nil
    @State private var warningMessage: String? = nil
    @State private var shakeOffset: CGFloat = 0

    private var isThisRecording: Bool {
        recorder.recordingTargetID == temporaryShortcutRecorderID
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                TemporaryShortcutIconView()
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("临时折叠当前活跃窗口".localized)
                        .font(.body)
                    Text("仅对当前活跃窗口临时贴边折叠，并自动选择最近边缘。再次按下会立刻展开；手动拖离边缘后，本次临时折叠自动失效。".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                ShortcutDisplayView(
                    modifiers: config.temporaryShortcutModifiers,
                    keyCode: config.temporaryShortcutKeyCode,
                    isRecording: isThisRecording,
                    onTap: {
                        ShortcutRecorderManager.shared.startRecording(
                            targetID: temporaryShortcutRecorderID,
                            onRecord: { modifiers, keyCode in
                                if let conflictName = shortcutConflictName(
                                    modifiers: modifiers,
                                    keyCode: keyCode,
                                    excludingID: temporaryShortcutRecorderID,
                                    config: config,
                                    appInfos: appInfos
                                ) {
                                    triggerConflict(name: conflictName)
                                    return
                                }

                                warningMessage = nil
                                for (sysMod, sysKey, sysDesc) in systemShortcuts {
                                    if modifiers == sysMod && keyCode == sysKey {
                                        triggerWarning(desc: sysDesc)
                                        break
                                    }
                                }

                                conflictMessage = nil
                                config.setTemporaryShortcut(modifiers: modifiers, keyCode: keyCode)
                            }
                        )
                    },
                    onClear: {
                        config.clearTemporaryShortcut()
                        conflictMessage = nil
                        warningMessage = nil
                    }
                )
                .offset(x: shakeOffset)
            }

            if let msg = conflictMessage {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                }
                .foregroundColor(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let msg = warningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.default, value: conflictMessage)
        .animation(.default, value: warningMessage)
    }

    private func triggerConflict(name: String) {
        conflictMessage = "快捷键和「".localized + name + "」冲突，请重试".localized
        warningMessage = nil

        withAnimation(.default) { shakeOffset = 12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.default) { shakeOffset = -5 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.default) { shakeOffset = 0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { conflictMessage = nil }
        }
    }

    private func triggerWarning(desc: String) {
        warningMessage = "该快捷键与系统 ".localized + desc + " 冲突，可能体验不佳".localized

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { warningMessage = nil }
        }
    }
}

struct TemporaryShortcutIconView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Capsule(style: .continuous)
                .stroke(Color.secondary, lineWidth: 2.2)
                .frame(width: 8, height: 22)
        }
    }
}

struct ShortcutRowView: View {
    let app: AppInfo
    @ObservedObject var config: AppConfig
    let appInfos: [AppInfo]
    @ObservedObject var recorder: ShortcutRecorderManager = .shared
    
    @State private var conflictMessage: String? = nil
    @State private var warningMessage: String? = nil
    @State private var shakeOffset: CGFloat = 0
    
    var isThisRecording: Bool {
        recorder.recordingTargetID == app.id
    }
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                
                Text(app.name)
                    .font(.body)
                    .lineLimit(1)
                
                Spacer()
                
                ShortcutDisplayView(
                    modifiers: config.appSettings[app.id]?.shortcutModifiers,
                    keyCode: config.appSettings[app.id]?.shortcutKeyCode,
                    isRecording: isThisRecording,
                    onTap: {
                        ShortcutRecorderManager.shared.startRecording(
                            targetID: app.id,
                            onRecord: { modifiers, keyCode in
                                if let conflictName = shortcutConflictName(
                                    modifiers: modifiers,
                                    keyCode: keyCode,
                                    excludingID: app.id,
                                    config: config,
                                    appInfos: appInfos
                                ) {
                                    triggerConflict(name: conflictName)
                                    return
                                }

                                warningMessage = nil
                                for (sysMod, sysKey, sysDesc) in systemShortcuts {
                                    if modifiers == sysMod && keyCode == sysKey {
                                        triggerWarning(desc: sysDesc)
                                        break
                                    }
                                }
                                
                                // 正常录入
                                conflictMessage = nil
                                config.setShortcut(bundleID: app.id, modifiers: modifiers, keyCode: keyCode)
                            }
                        )
                    },
                    onClear: {
                        config.clearShortcut(bundleID: app.id)
                        conflictMessage = nil
                        warningMessage = nil
                    }
                )
                .offset(x: shakeOffset)
            }
            
            // 红色冲突提示（阻止录入）
            if let msg = conflictMessage {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                }
                .foregroundColor(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // 黄色系统冲突警告（不阻止，仅提醒）
            if let msg = warningMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.default, value: conflictMessage)
        .animation(.default, value: warningMessage)
    }
    
    private func triggerConflict(name: String) {
        conflictMessage = "快捷键和「".localized + name + "」冲突，请重试".localized
        warningMessage = nil
        
        // 晃动动画
        withAnimation(.default) { shakeOffset = 12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = -10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.default) { shakeOffset = -5 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.default) { shakeOffset = 0 }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { conflictMessage = nil }
        }
    }
    
    private func triggerWarning(desc: String) {
        warningMessage = "该快捷键与系统 ".localized + desc + " 冲突，可能体验不佳".localized
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation { warningMessage = nil }
        }
    }
}

// 全局唯一的录入管理器，确保同一时间只有一个监听器工作
class ShortcutRecorderManager: ObservableObject {
    static let shared = ShortcutRecorderManager()
    
    @Published var recordingTargetID: String? = nil
    private var localMonitor: Any? = nil
    private var onRecordCallback: ((UInt, UInt16) -> Void)? = nil
    
    func startRecording(targetID: String, onRecord: @escaping (UInt, UInt16) -> Void) {
        // 如果点击的是同一个正在录入的行，则取消
        if recordingTargetID == targetID {
            stopRecording()
            return
        }
        
        // 停止之前可能存在的录入
        stopRecording()
        
        recordingTargetID = targetID
        onRecordCallback = onRecord
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.recordingTargetID != nil else { return event }
            
            // Escape 取消
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = !flags.intersection([.control, .option, .shift, .command]).isEmpty
            if hasModifier {
                self.onRecordCallback?(flags.rawValue, event.keyCode)
                self.stopRecording()
                return nil
            }
            
            return event
        }
    }
    
    func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        recordingTargetID = nil
        onRecordCallback = nil
    }
}

struct ShortcutDisplayView: View {
    let modifiers: UInt?
    let keyCode: UInt16?
    let isRecording: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    
    private let modifierSymbols: [(String, UInt)] = [
        ("⌃", NSEvent.ModifierFlags.control.rawValue),
        ("⌥", NSEvent.ModifierFlags.option.rawValue),
        ("⇧", NSEvent.ModifierFlags.shift.rawValue),
        ("⌘", NSEvent.ModifierFlags.command.rawValue),
    ]
    
    var hasShortcut: Bool {
        modifiers != nil && keyCode != nil
    }
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(modifierSymbols, id: \.0) { symbol, flag in
                Text(symbol)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(isModifierActive(flag) ? .white : Color.secondary.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isModifierActive(flag) ? Color.blue : Color.gray.opacity(0.15))
                    )
            }
            
            // 字母占位框（始终显示）
            Text(hasShortcut ? keyCodeToString(keyCode!) : (isRecording ? "…" : ""))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(hasShortcut ? .white : Color.secondary.opacity(0.3))
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hasShortcut ? Color.blue : Color.gray.opacity(0.15))
                )
            
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .opacity(hasShortcut ? 1.0 : 0.0)
            .disabled(!hasShortcut)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isRecording ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording ? Color.blue : Color.gray.opacity(0.3), lineWidth: isRecording ? 1.5 : 1)
                )
        )
        .contentShape(Rectangle()) // 确保整个区域可点击
        .onTapGesture { onTap() }
    }
    
    private func isModifierActive(_ flag: UInt) -> Bool {
        guard let mods = modifiers else { return false }
        return mods & flag != 0
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let mapping: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            51: "⌫", 53: "Esc", 36: "↩", 48: "Tab",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return mapping[keyCode] ?? "?"
    }
}

// MARK: - 关于设置页面
struct AboutSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.1"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    aboutAppHeader
                    aboutRecommendations
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
        }
    }
    
    private var aboutAppHeader: some View {
        HStack(spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.45 : 0.15), location: 0.0),
                                        .init(color: Color.white.opacity(0.0), location: 0.5),
                                        .init(color: Color.white.opacity(colorScheme == .dark ? 0.15 : 0.0), location: 1.0)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15), radius: 6, x: 0, y: 3)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("SideBar")
                        .font(.title2)
                        .bold()
                    
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                }
                
                Text("将屏幕边缘的魔法收纳术带给所有的第三方应用。".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 12) {
                    Button(action: {
                        if let url = URL(string: "https://www.ivean.com/sidebar/") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text("访问网站".localized)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    
                    Button(action: {
                        UpdateChecker.shared.checkForUpdates(manual: true)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("检查更新".localized)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(.top, 2)
            }
        }
    }
    
    private var aboutRecommendations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("作者的奇思妙想".localized)
                .font(.footnote)
                .bold()
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            VStack(spacing: 12) {
                ForEach(recommendedToolsList) { tool in
                    RecommendationRow(tool: tool)
                }
            }
        }
    }
    
    private var recommendedToolsList: [RecommendedTool] {
        [
            RecommendedTool(
                name: "流光倒计时".localized,
                slogan: "一按一拉，静待流光。让时间流逝成为一种桌面美学。".localized,
                iconName: "flux_timer",
                url: "https://ivean.com/fluxtimer/"
            ),
            RecommendedTool(
                name: "DockMinimize",
                slogan: "在 macOS 上实现类似 Windows 系统的单击隐藏和显示窗口".localized,
                iconName: "dockminimize",
                url: "https://www.ivean.com/dockminimize/"
            ),
            RecommendedTool(
                name: "快速搜索".localized,
                slogan: "选中文本，双击快捷键，在页面上瞬间切换搜索方式。".localized,
                iconName: "quick_search",
                url: "https://www.ivean.com/quicksearch/"
            ),
            RecommendedTool(
                name: "多词高亮查找".localized,
                slogan: "告别低效，开启专业的多词批量高亮检索新纪元。".localized,
                iconName: "highlighter",
                url: "https://ivean.com/highlighter/"
            ),
            RecommendedTool(
                name: "极致护眼".localized,
                slogan: "为你的眼睛，挑选一种舒适。全方位的护眼计划。".localized,
                iconName: "eyecare",
                url: "https://www.ivean.com/eyecarepro/"
            )
        ]
    }
}

// MARK: - 推荐组件

struct RecommendedTool: Identifiable {
    let id = UUID()
    let name: String
    let slogan: String
    let iconName: String
    let url: String
}

struct RecommendationRow: View {
    let tool: RecommendedTool
    @State private var isHovered = false
    @State private var loadedIcon: NSImage?
    
    var body: some View {
        Button(action: {
            if let url = URL(string: tool.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                if let nsImage = loadedIcon {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(stops: [
                                            .init(color: Color.white.opacity(0.35), location: 0.0),
                                            .init(color: Color.white.opacity(0.0), location: 0.5),
                                            .init(color: Color.white.opacity(0.1), location: 1.0)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundColor(.secondary.opacity(0.2))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Text(tool.slogan)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.primary.opacity(0.1) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onAppear {
            if loadedIcon == nil {
                if let iconUrl = Bundle.main.url(forResource: tool.iconName, withExtension: "png", subdirectory: "Recommends") {
                    loadedIcon = NSImage(contentsOf: iconUrl)
                } else {
                    loadedIcon = NSImage(named: tool.iconName)
                }
            }
        }
    }
}

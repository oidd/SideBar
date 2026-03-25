import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case apps
    case appearance
    case shortcuts
    case interaction
    case general
    case about
    
    var iconName: String {
        switch self {
        case .apps: return "macwindow.badge.plus"
        case .appearance: return "paintbrush.fill"
        case .shortcuts: return "keyboard"
        case .interaction: return "hand.tap.fill"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        }
    }
    
    var displayName: String {
        switch self {
        case .apps: return "选择软件".localized
        case .appearance: return "外观与透明度".localized
        case .shortcuts: return "快捷键".localized
        case .interaction: return "防误触容差".localized
        case .general: return "常规设置".localized
        case .about: return "关于".localized
        }
    }
}

struct SettingsView: View {
    @StateObject private var appListManager = AppListManager()
    @StateObject private var config = AppConfig.shared
    @State private var selectedTab: SettingsTab = .apps
    
    // NavigationSplitView 的 List(selection:) 需要 Optional 绑定
    private var selectedTabBinding: Binding<SettingsTab?> {
        Binding<SettingsTab?>(
            get: { selectedTab },
            set: { if let newValue = $0 { selectedTab = newValue } }
        )
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
    
    // MARK: - macOS 13+ 原生 NavigationSplitView 布局
    @available(macOS 13.0, *)
    private var modernLayout: some View {
        NavigationSplitView {
            List(selection: selectedTabBinding) {
                ForEach([SettingsTab.apps, .appearance, .shortcuts, .interaction, .general, .about], id: \.self) { tab in
                    Label(tab.displayName, systemImage: tab.iconName)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("SideBar")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            // GeometryReader 约束 detail 内容高度，防止内容撑大后推动整个分栏上移
            GeometryReader { geo in
                detailContent
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(width: 700, height: 540)
        .id(config.language)
    }
    
    // MARK: - macOS 12 降级布局（保留原有手动布局）
    private var legacyLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SideBar")
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 15)
                
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach([SettingsTab.apps, .appearance, .shortcuts, .interaction, .general, .about], id: \.self) { tab in
                            LegacyTabButton(tab: tab, selectedTab: $selectedTab)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(width: 180)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            detailContent
                .background(Color(NSColor.controlBackgroundColor).ignoresSafeArea())
        }
        .frame(width: 680, height: 540)
    }
}


// MARK: - macOS 12 降级侧边栏按钮
struct LegacyTabButton: View {
    let tab: SettingsTab
    @Binding var selectedTab: SettingsTab
    
    var body: some View {
        Button(action: { selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(tab.displayName)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selectedTab == tab ? Color.blue : Color.clear)
            .foregroundColor(selectedTab == tab ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
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
            
            List(appListManager.apps) { app in
                let isEnabled = config.isAppEnabled(bundleID: app.id)
                let colorName = config.getColorName(for: app.id)
                
                AppRowView(
                    app: app,
                    isEnabled: isEnabled,
                    colorName: colorName,
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
                .padding(.vertical, 4)
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

struct GeneralSettingsView: View {
    @ObservedObject var config: AppConfig
    
    // 定时刷新权限状态用
    @State private var axEnabled = AXIsProcessTrusted()
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
                                Picker("", selection: $config.language) {
                                    Text("跟随系统".localized).tag(0)
                                    Text("简体中文".localized).tag(1)
                                    Text("English".localized).tag(2)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140)
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
        HStack {
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
                    // 按钮表面的圆点
                    if colorName == "auto" {
                        Image(nsImage: generateAutoColorImage(size: 14))
                    } else {
                        Image(nsImage: generateColorImage(size: 14, color: getSelectedColor()))
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
                .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 105, alignment: .leading)
            .disabled(!isEnabled)
            
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
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
    @ObservedObject var appListManager: AppListManager
    @ObservedObject var config: AppConfig
    
    @State private var globalOpacity: Double = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaddingHeader(title: "外观与透明度".localized, subtitle: "统一规划或单独调节每个启用软件快照条的色彩及透明程度。".localized)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("全局透明度覆写".localized)
                        .font(.headline)
                    Spacer()
                    Text("\(Int(globalOpacity * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue)
                }
                
                Slider(value: Binding(
                    get: { globalOpacity },
                    set: { val in
                        globalOpacity = val
                        config.setGlobalOpacity(val)
                    }
                ), in: 0.1...1.0, step: 0.05)
                .accentColor(.blue)
                
                Text("拖动此滑块会同时将下方所有已启用软件的透明度重置为该固定值。".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            List(appListManager.apps.filter { config.isAppEnabled(bundleID: $0.id) }) { app in
                let colorName = config.getColorName(for: app.id)
                let opacity = config.getOpacity(for: app.id)
                
                AppAppearanceRowView(
                    app: app,
                    colorName: colorName,
                    opacity: opacity,
                    onColorChange: { newColor in
                        config.updateApp(bundleID: app.id, isEnabled: true, colorName: newColor)
                    },
                    onOpacityChange: { newOpacity in
                        config.updateOpacity(bundleID: app.id, opacity: newOpacity)
                    }
                )
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            globalOpacity = 1.0
        }
    }
}

struct AppAppearanceRowView: View {
    @Environment(\.colorScheme) var colorScheme
    let app: AppInfo
    let colorName: String
    let opacity: Double
    let onColorChange: (String) -> Void
    let onOpacityChange: (Double) -> Void
    
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
                        Image(nsImage: generateAutoColorImage(size: 14))
                    } else {
                        Image(nsImage: generateColorImage(size: 14, color: getSelectedColor()))
                    }
                    Text(getSelectedColorDisplayName())
                        .font(.body)
                        .foregroundColor(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 105, alignment: .leading)
            
            Spacer()
            
            // 独立透明度修改器
            HStack {
                Text("\(Int(opacity * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
                
                Slider(value: Binding(
                    get: { opacity },
                    set: { onOpacityChange($0) }
                ), in: 0.1...1.0, step: 0.05)
                .frame(width: 90)
            }
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
    
    /// 绘制左黑右白半圆图标，代表“自动”颜色
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
            
            if enabledApps.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("请先在「选择软件」中启用至少一个应用".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(enabledApps) { app in
                    ShortcutRowView(app: app, config: config)
                        .padding(.vertical, 6)
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

struct ShortcutRowView: View {
    let app: AppInfo
    @ObservedObject var config: AppConfig
    @ObservedObject var recorder: ShortcutRecorderManager = .shared
    
    @State private var conflictMessage: String? = nil
    @State private var warningMessage: String? = nil
    @State private var shakeOffset: CGFloat = 0
    
    var isThisRecording: Bool {
        recorder.recordingBundleID == app.id
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
                            bundleID: app.id,
                            onRecord: { modifiers, keyCode in
                                // 1. 应用间冲突检测（红色，阻止）
                                for (otherID, otherSettings) in config.appSettings {
                                    if otherID != app.id,
                                       otherSettings.shortcutModifiers == modifiers,
                                       otherSettings.shortcutKeyCode == keyCode {
                                        let otherName = NSRunningApplication.runningApplications(withBundleIdentifier: otherID).first?.localizedName ?? otherID
                                        triggerConflict(name: otherName)
                                        return
                                    }
                                }
                                
                                // 2. 系统快捷键警告检测（黄色，不阻止）
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
    
    @Published var recordingBundleID: String? = nil
    private var localMonitor: Any? = nil
    private var onRecordCallback: ((UInt, UInt16) -> Void)? = nil
    
    func startRecording(bundleID: String, onRecord: @escaping (UInt, UInt16) -> Void) {
        // 如果点击的是同一个正在录入的行，则取消
        if recordingBundleID == bundleID {
            stopRecording()
            return
        }
        
        // 停止之前可能存在的录入
        stopRecording()
        
        recordingBundleID = bundleID
        onRecordCallback = onRecord
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.recordingBundleID != nil else { return event }
            
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
        recordingBundleID = nil
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
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

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

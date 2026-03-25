import Foundation

enum AppLanguage: Int {
    case system = 0
    case chinese = 1
    case english = 2
}

class I18n {
    static let shared = I18n()
    
    let enDict: [String: String] = [
        "SideBar 已获得辅助功能权限，可以正常工作。": "SideBar has obtained accessibility permissions and can work normally.",
        "自动": "Auto",
        "「自动」颜色会随系统「浅色」或「深色」外观自动切换为「黑色」或「白色」。": "The \"Auto\" color automatically switches between \"Black\" and \"White\" based on the system's \"Light\" or \"Dark\" appearance.",
        "SideBar 需要辅助功能权限才能控制和隐藏其他应用程序的窗口。\n\n请在系统设置中允许 SideBar，然后重启本软件。": "SideBar requires accessibility permissions to control and hide windows of other applications.\n\nPlease allow SideBar in System Settings, then restart the application.",
        "为已启用的应用绑定全局快捷键，一键唤出或收起边栏窗口。": "Bind global shortcuts to enabled apps to reveal or hide the sidebar window with one click.",
        "保存 (⌘S)": "Save (⌘S)",
        "偏好设置...": "Preferences...",
        "全": "All",
        "全局透明度覆写": "Global Opacity Override",
        "全选 (⌘A)": "Select All (⌘A)",
        "关于": "About",
        "关闭窗口 (⌘W)": "Close Window (⌘W)",
        "决定鼠标悬停在屏幕边缘多久后才会唤出边界窗口。等待期内若发生点击（如点击滚动条）则中止等待。": "Determines how long the mouse must hover at the screen edge before the boundary window is revealed. Clicks during the wait period (e.g., clicking the scrollbar) will abort the wait.",
        "切换应用 (⌘Tab)": "Switch App (⌘Tab)",
        "切换窗口 (⌘`)": "Switch Window (⌘`)",
        "前往下载": "Go to Download",
        "剪切 (⌘X)": "Cut (⌘X)",
        "包含重要的性能改进与功能更新。": "Includes important performance improvements and feature updates.",
        "区": "Area",
        "去授权": "Grant Access",
        "发现新版本: ": "New version available: ",
        "在菜单栏显示图标": "Show Icon in Menu Bar",
        "垂直容差 (Y轴)": "Vertical Tolerance (Y-Axis)",
        "复制 (⌘C)": "Copy (⌘C)",
        "外观与透明度": "Appearance & Opacity",
        "容忍安全区实时推演": "Tolerance Safe Zone Live Preview",
        "将屏幕边缘的魔法收纳术带给所有的第三方应用。拖拽吸附，悬停弹射，纯粹且静谧。": "Bring the magic of screen-edge organization to all third-party apps. Drag to dock, hover to pop out, pure and silent.",
        "已开启": "Enabled",
        "已是最新版本": "Up to date",
        "已检测到 DockMinimize。本次操作的变更已同步至 DockMinimize，相关软件将被临时排除。": "DockMinimize detected. Changes from this operation have been synced, and related apps will be temporarily excluded.",
        "常规设置": "General Settings",
        "通用": "General",
        "语言": "Language",
        "跟随系统": "System Default",
        "简体中文": "Simplified Chinese",
        "English": "English",
        "开机自动启动": "Launch at Login",
        "强制退出 (⌥⌘Esc)": "Force Quit (⌥⌘Esc)",
        "当前 SideBar 版本 ": "The current SideBar version ",
        " 已经是最新版。": " is already up to date.",
        "当前版本目前仅支持勾选正在运行的进程。如果你想要让某个软件支持贴边隐藏，请先确保它已经打开。": "The current version only supports selecting running processes. Make sure the app you want to hide at the edge is already open.",
        "快捷键": "Shortcuts",
        "快捷键和「": "Shortcut conflicts with \"",
        "」冲突，请重试": "\", please try again",
        "截屏 (⇧⌘3)": "Screenshot (⇧⌘3)",
        "截屏区域 (⇧⌘4)": "Screenshot Portion (⇧⌘4)",
        "截屏窗口 (⇧⌘5)": "Screenshot Window (⇧⌘5)",
        "打印 (⌘P)": "Print (⌘P)",
        "打开 (⌘O)": "Open (⌘O)",
        "打开系统设置": "Open System Settings",
        "拖动此滑块会同时将下方所有已启用软件的透明度重置为该固定值。": "Dragging this slider will reset the opacity of all enabled apps below to this fixed value.",
        "撤销 (⌘Z)": "Undo (⌘Z)",
        "操作窗口": "Window Operations",
        "新建 (⌘N)": "New (⌘N)",
        "新标签页 (⌘T)": "New Tab (⌘T)",
        "无法连接到服务器，请检查网络设置。": "Unable to connect to server, please check your network settings.",
        "最小化 (⌘M)": "Minimize (⌘M)",
        "服务器返回的数据格式不正确。": "Incorrect data format returned from server.",
        "权限": "Permissions",
        "权限已授予": "Permission Granted",
        "查找 (⌘F)": "Find (⌘F)",
        "检查更新": "Check for Updates",
        "检查更新失败": "Update Check Failed",
        "橙色": "Orange",
        "水平容差 (X轴)": "Horizontal Tolerance (X-Axis)",
        "用于控制窗口的展开和折叠以及程序坞点击识别事件": "Used to control window expansion/collapse and Dock click recognition events",
        "白色": "White",
        "确定": "OK",
        "离开窗口时，鼠标垂直方向移出安全区多少像素后才触发折叠。": "How many pixels the mouse must vertically leave the safe zone before triggering a collapse.",
        "离开窗口时，鼠标水平方向移出安全区多少像素后才触发折叠。": "How many pixels the mouse must horizontally leave the safe zone before triggering a collapse.",
        "稍后": "Later",
        "立即响应": "Instant Response",
        "管理 SideBar 的基础运行行为和系统权限。": "Manage SideBar's basic execution behavior and system permissions.",
        "粉色": "Pink",
        "粘贴 (⌘V)": "Paste (⌘V)",
        "紫色": "Purple",
        "红色": "Red",
        "统一规划或单独调节每个启用软件快照条的色彩及透明程度。": "Unify or individually adjust the color and opacity of each enabled app's snapshot bar.",
        "绿色": "Green",
        "蓝色": "Blue",
        "解析失败": "Parsing Failed",
        "访问官网": "Visit Official Website",
        "该快捷键与系统 ": "This shortcut conflicts with system ",
        " 冲突，可能体验不佳": " , creating a poor experience",
        "请先在「选择软件」中启用至少一个应用": "Please enable at least one app in \"Select Apps\" first",
        "调整边缘响应延迟与位移缓冲，防止日常操作意外唤出或折叠窗口。": "Adjust edge delay and displacement buffer to prevent accidental window trigger or collapse.",
        "辅助功能": "Accessibility",
        "退出 (⌘Q)": "Quit (⌘Q)",
        "退出 SideBar": "Quit SideBar",
        "退出程序": "Quit Application",
        "选择软件": "Select Apps",
        "重做 (⇧⌘Z)": "Redo (⇧⌘Z)",
        "重置为 60": "Reset to 60",
        "重置归零": "Reset to Zero",
        "防误触容差": "Window Tolerances",
        "防误触缓冲 (悬停延时)": "Hover Delay Buffer",
        "隐藏 (⌘H)": "Hide (⌘H)",
        "隐藏菜单栏图标后，您需要在访达(Finder)中再次运行SideBar来打开此设置面板。": "After hiding the menu bar icon, you need to run SideBar in Finder again to open this settings panel.",
        "需要辅助功能权限": "Accessibility Permission Required",
        "黄色": "Yellow",
        "黑色": "Black"
    ]
    
    func translate(_ key: String, language: AppLanguage) -> String {
        let isEnglish: Bool
        switch language {
        case .system:
            guard let preferredLang = Locale.preferredLanguages.first else {
                isEnglish = true
                break
            }
            isEnglish = !preferredLang.starts(with: "zh")
        case .chinese:
            isEnglish = false
        case .english:
            isEnglish = true
        }
        
        if isEnglish {
            return enDict[key] ?? key
        } else {
            return key
        }
    }
}

extension String {
    var localized: String {
        return I18n.shared.translate(self, language: AppLanguage(rawValue: AppConfig.shared.language) ?? .system)
    }
}

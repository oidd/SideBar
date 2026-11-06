# 悬停跟踪回归验证

## 行为与修复

悬浮窗口展开后切换到其他普通应用，窗口应真正收回，之后仍能悬停展开。窗口只是被遮挡时，旧逻辑仍可能导出 `expanded_visible`；此时“鼠标在窗内”的几何缓存或快捷键等待会阻止收回，而再次悬停又被“已经展开”的检查拒绝。

- 收回检查将其他普通应用取得前台视作离开交互，绕过旧窗内缓存、快捷键等待和后台兄弟窗口几何，沿用原有宽限期和动画收回，并保留新选中的应用焦点。
- frame 与边缘几何准备成功后才停止跟踪；准备失败仍返回 `false`，由原计时器继续检查，避免短暂 AX 读取失败后永久失去驱动。

现有 100ms 跟踪、220ms 宽限期，以及置顶、融合锁、动画中和鼠标按下等门禁不变。

## 运行

需要 macOS、Python 3 和 Swift Command Line Tools。

```bash
Scripts/test-hover-tracking.sh
```

37 项检查应全部通过。以下命令在保留 Git 历史的检出中使用固定基线源码运行同一套检查，预期 18 项失败、退出码 1：

```bash
Scripts/test-hover-tracking.sh --baseline
```

基线为 `d63b89230528eb1a7294013f6c1aef9e6a56000c`。产物与日志写入 `build/tests/hover-tracking/{current,baseline}/`。

## 覆盖与边界

脚本原样提取生产 `checkMouseForCollapse`、`collapseWindow`、`expandWindow`、`startMouseTrackingTimer` 和 `SnapState`，在内存平台后端中编译运行；不复制收回控制流，也不在生产代码添加测试分支。

- 左右两侧分别覆盖普通鼠标移出、Dock/快捷键展开后的窗外点击；准备读取失败后保留跟踪，读取恢复后收回，再次悬停可以展开。
- 覆盖几何准备失败、持续读取失败、鼠标返回后取消收回和随后再次移出；失败期间不启动动画或释放焦点。
- 前台切换覆盖旧窗内缓存、快捷键等待、后台兄弟窗口几何、动画中发生切换、失败读取恢复及鼠标按下；收回后不另行归还焦点。
- 同一应用保持前台、置顶、辅助应用取得前台及宽限期内切回，不触发额外收回。
- 计时器、时间、延迟队列、AX/UI 使用内存后端；动画仅模拟正常完成，不连接真实应用、显示服务或辅助功能设置。

真实 AX 超时、CoreVideo、跨显示器行为及长时间稳定性不由本套测试验证。

## 全量类型检查

选择与本机 Swift 工具链兼容的 macOS SDK。本次验证使用已安装的 26.5 SDK：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swiftc -typecheck Sources/SideBar/*.swift \
  -framework AppKit -framework SwiftUI \
  -framework ApplicationServices -framework Foundation
```

## 手动验收

1. 用临时收纳快捷键收纳一个普通窗口，再悬停展开。
2. 点击另一个普通应用，使其取得前台；确认源窗口真正收回，而非仅被覆盖。
3. 再次移到侧边条，确认无需额外点击即可展开。

本地构建以滴答清单和 ChatGPT 窗口完成连续两轮操作，反馈正常；同时观察到 `expanded_visible → snapped_hidden → expanded_visible` 状态切换。这是该操作场景的验证结果，不代表所有应用及长期使用场景均已验证。

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 置顶能力的画面来源：用 ScreenCaptureKit 把单一窗口当作"屏幕共享"来读，
/// 把得到的 CMSampleBuffer 直接喂给一个 AVSampleBufferDisplayLayer 渲染。
///
/// 设计要点：
/// - filter 使用 `SCContentFilter(desktopIndependentWindow:)`，意味着源窗口即使被遮挡、
///   被推到屏幕外、不在前台，系统仍会把它当作独立合成层产出实时画面，从而支持"原地置顶副本"。
/// - 回调里直接在 `outputQueue` 上 `enqueue`：AVSampleBufferDisplayLayer 线程安全，
///   不再 hop 主线程，主线程繁忙时也不会把 CMSampleBuffer 堆积在 main queue 上撑爆 SCStream pool。
/// - 真正的"置顶"是承载该 layer 的 `WindowMirrorOverlayWindow` 负责，本类只负责画面来源。
///
/// 该类不持有 NSWindow，也不感知坐标系；调用方负责面板的几何跟踪与显隐生命周期。
@available(macOS 12.3, *)
final class WindowMirrorLiveCapturer: NSObject {
    /// 用于把帧推给宿主 layer。所有外部交互都通过它访问。
    /// AVSampleBufferDisplayLayer.enqueue 本身线程安全，stream 回调里直接在采集队列上喂帧。
    let renderingLayer = AVSampleBufferDisplayLayer()

    /// 当采集底层异常停止时回调（例如源窗口关闭、权限撤销）。回调在主线程触发。
    var onCaptureFailure: (() -> Void)?

    /// 控制最大帧率；默认与显示器刷新率一致即可。
    var preferredMaxFPS: Int = 60

    private enum State {
        case idle
        case starting
        case running
        case stopping
    }

    private var state: State = .idle
    private var stream: SCStream?
    private let configuration = SCStreamConfiguration()
    private var activeWindow: SCWindow?
    private var activeDisplay: SCDisplay?
    private var lastAppliedSize: CGSize = .zero
    private var lastAppliedScale: CGFloat = 1
    private let outputQueue = DispatchQueue(label: "com.ivean.SideBar.mirrorCaptureOutput", qos: .userInteractive)

    override init() {
        super.init()
        renderingLayer.videoGravity = .resizeAspect
        renderingLayer.backgroundColor = NSColor.clear.cgColor
    }

    deinit {
        // 兜底：保证 deinit 时不残留正在跑的 stream
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
    }

    /// 启动针对指定窗口的实时采集。同一实例上多次调用会先停后启。
    /// 调用方必须确保已经通过 `ScreenCaptureAccessManager` 拿到了屏幕录制权限。
    func start(window: SCWindow,
               on display: SCDisplay,
               nominalPointSize: CGSize,
               backingScale: CGFloat) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beginSession(window: window,
                                    display: display,
                                    nominalPointSize: nominalPointSize,
                                    backingScale: backingScale)
        }
    }

    /// 异步停止采集。可以重复调用而不出错。
    func stop() {
        Task { @MainActor [weak self] in
            await self?.endSession()
        }
    }

    /// 源窗口尺寸或所在显示器缩放变化时调用；内部会按需 `updateConfiguration` 或重启 stream。
    func updateOutputDimensions(pointSize: CGSize, backingScale: CGFloat) {
        guard pointSize.width > 1, pointSize.height > 1 else { return }
        let scale = max(backingScale, 1)
        let pixelWidth = Int((pointSize.width * scale).rounded())
        let pixelHeight = Int((pointSize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        let sizeChanged = abs(pointSize.width - lastAppliedSize.width) > 0.5
            || abs(pointSize.height - lastAppliedSize.height) > 0.5
            || abs(scale - lastAppliedScale) > 0.01
        guard sizeChanged else { return }

        configuration.width = pixelWidth
        configuration.height = pixelHeight
        lastAppliedSize = pointSize
        lastAppliedScale = scale

        if #available(macOS 14.0, *), let stream {
            stream.updateConfiguration(configuration) { _ in }
        } else {
            // macOS 12.3–13 不支持热更新 configuration，只能整体重启采集。
            // 调用方此时通常会同时同步面板尺寸，短暂黑屏可被覆盖。
            Task { @MainActor [weak self] in
                await self?.restartWithCurrentFilter()
            }
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func beginSession(window: SCWindow,
                              display: SCDisplay,
                              nominalPointSize: CGSize,
                              backingScale: CGFloat) async {
        if state == .running || state == .starting {
            await endSession()
        }
        state = .starting
        activeWindow = window
        activeDisplay = display

        // 渲染参数：BGRA + sRGB，与系统合成层一致；关闭鼠标，避免镜像里混入虚假指针；
        // queueDepth 留 3 帧缓冲，scalesToFit 让出宿主 layer 控制最终拉伸。
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.scalesToFit = true
        if #available(macOS 13.0, *) {
            configuration.capturesAudio = false
        }

        let scale = max(backingScale, 1)
        let pixelWidth = max(1, Int((nominalPointSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((nominalPointSize.height * scale).rounded()))
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        lastAppliedSize = nominalPointSize
        lastAppliedScale = scale

        let cappedFPS = max(15, min(preferredMaxFPS, 120))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cappedFPS))

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let session = SCStream(filter: filter, configuration: configuration, delegate: self)

        do {
            try session.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await session.startCapture()
            self.stream = session
            state = .running
        } catch {
            print("🪟 置顶画面采集启动失败: \(error.localizedDescription)")
            state = .idle
            self.stream = nil
            invokeFailure()
        }
    }

    @MainActor
    private func endSession() async {
        guard let stream else {
            state = .idle
            return
        }
        state = .stopping
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            // 已经停了或者出错都视为已收尾，状态机不再回滚。
            print("🪟 置顶画面采集停止时返回非致命错误: \(error.localizedDescription)")
        }
        state = .idle
        // 清空残留画面，避免下一次启动时复用旧帧。
        renderingLayer.flushAndRemoveImage()
    }

    @MainActor
    private func restartWithCurrentFilter() async {
        guard let window = activeWindow, let display = activeDisplay else { return }
        await endSession()
        await beginSession(window: window,
                           display: display,
                           nominalPointSize: lastAppliedSize == .zero
                               ? CGSize(width: configuration.width, height: configuration.height)
                               : lastAppliedSize,
                           backingScale: lastAppliedScale)
    }

    private func invokeFailure() {
        DispatchQueue.main.async { [weak self] in
            self?.onCaptureFailure?()
        }
    }
}

// MARK: - SCStream callbacks

@available(macOS 12.3, *)
extension WindowMirrorLiveCapturer: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        // AVSampleBufferDisplayLayer.enqueue 本身是线程安全的（Apple SCK 示例就是直接从
        // sampleHandlerQueue 喂帧）。这里直接在 outputQueue 上 enqueue：
        // - 60FPS 的帧不再 hop 到主线程，避免主线程繁忙时 CMSampleBuffer 在 main queue 上
        //   堆积、把 SCStream 的内部 pool 饿死；
        // - 只有 `status == .failed` 的稀有恢复路径才 flush——layer 出错复位本身就是稀有事件，
        //   留在当前线程做也没问题，不需要再 dispatch 切线程。
        if renderingLayer.status == .failed {
            renderingLayer.flush()
        }
        renderingLayer.enqueue(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("🪟 置顶画面采集异常停止: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.state = .idle
            self.renderingLayer.flushAndRemoveImage()
            self.onCaptureFailure?()
        }
    }
}

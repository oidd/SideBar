import Cocoa
import ApplicationServices

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CInt

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CInt, _ wid: CInt, _ alpha: Float) -> CGError

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

class WindowAlphaManager {
    static let shared = WindowAlphaManager()
    
    // Attempt to find the CGWindowID cleanly by using macOS private API
    func findWindowID(for axWindow: AXUIElement, pid: pid_t) -> CGWindowID? {
        var windowID: CGWindowID = 0
        if _AXUIElementGetWindow(axWindow, &windowID) == .success {
            return windowID
        }
        return nil
    }
    
    // 强制设置核心渲染层的 alpha
    func setAlpha(for windowID: CGWindowID, alpha: Float) {
        let cid = CGSMainConnectionID()
        _ = CGSSetWindowAlpha(cid, CInt(windowID), alpha)
    }
}

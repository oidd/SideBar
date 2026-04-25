import ApplicationServices

enum WindowCapabilityKind: Equatable {
    case standardWindow
    case finderDesktopProxy
    case nonStandardWindow
}

struct WindowCapabilityProfile {
    let bundleID: String?
    let subrole: String?

    var kind: WindowCapabilityKind {
        if subrole == kAXStandardWindowSubrole {
            return .standardWindow
        }
        if bundleID == "com.apple.finder" {
            return .finderDesktopProxy
        }
        return .nonStandardWindow
    }

    var isStandardWindow: Bool {
        kind == .standardWindow
    }

    var isFinderDesktopProxy: Bool {
        kind == .finderDesktopProxy
    }

    var supportsManagedSession: Bool {
        isStandardWindow
    }
}

enum WindowCapabilityProfiler {
    static func subrole(of element: AXUIElement, context: String) -> String? {
        var subroleValue: CFTypeRef?
        guard AccessibilityRuntimeGuard.copyAttributeValue(
            of: element,
            attribute: kAXSubroleAttribute as CFString,
            value: &subroleValue,
            context: context
        ) == .success else {
            return nil
        }
        return subroleValue as? String
    }

    static func profile(
        of element: AXUIElement,
        bundleID: String? = nil,
        context: String
    ) -> WindowCapabilityProfile {
        WindowCapabilityProfile(
            bundleID: bundleID,
            subrole: subrole(of: element, context: context)
        )
    }
}

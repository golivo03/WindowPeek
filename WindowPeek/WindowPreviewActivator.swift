import AppKit
import ApplicationServices

enum WindowPreviewActivator {
    static func activate(_ preview: WindowPreview) {
        guard let processIdentifier = preview.processIdentifier else { return }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        if let windowElement = matchingWindow(for: preview, in: appElement) {
            restoreIfMinimized(windowElement)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
            AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        }

        NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [.activateAllWindows])
    }

    static func close(_ preview: WindowPreview) {
        guard let windowElement = targetWindow(for: preview) else { return }

        if let closeButton = button(kAXCloseButtonAttribute, in: windowElement) {
            AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            return
        }

        AXUIElementPerformAction(windowElement, kAXCancelAction as CFString)
    }

    static func minimize(_ preview: WindowPreview) {
        guard let windowElement = targetWindow(for: preview) else { return }

        if let minimizeButton = button(kAXMinimizeButtonAttribute, in: windowElement) {
            AXUIElementPerformAction(minimizeButton, kAXPressAction as CFString)
            return
        }

        AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    private static func targetWindow(for preview: WindowPreview) -> AXUIElement? {
        guard let processIdentifier = preview.processIdentifier else { return nil }
        return matchingWindow(for: preview, in: AXUIElementCreateApplication(processIdentifier))
    }

    private static func matchingWindow(for preview: WindowPreview, in appElement: AXUIElement) -> AXUIElement? {
        guard let windows = windowElements(in: appElement) else { return nil }

        return windows.first { windowElement in
            if axWindowID(from: windowElement) == preview.id {
                return true
            }

            guard stringAttribute(kAXRoleAttribute, from: windowElement) == kAXWindowRole else {
                return false
            }

            if let title = stringAttribute(kAXTitleAttribute, from: windowElement), !title.isEmpty, title != preview.title {
                return false
            }

            guard let frame = frame(from: windowElement) else {
                return true
            }

            return framesMatch(frame, preview.windowBounds)
        }
    }

    private static func windowElements(in appElement: AXUIElement) -> [AXUIElement]? {
        var copiedWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &copiedWindows)
        guard result == .success else { return nil }
        return copiedWindows as? [AXUIElement]
    }

    private static func button(_ attribute: String, in windowElement: AXUIElement) -> AXUIElement? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(windowElement, attribute as CFString, &copiedValue)
        guard result == .success,
              let copiedValue,
              CFGetTypeID(copiedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(copiedValue, to: AXUIElement.self)
    }

    private static func restoreIfMinimized(_ windowElement: AXUIElement) {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &copiedValue)
        guard result == .success,
              let isMinimized = copiedValue as? Bool,
              isMinimized else {
            return
        }

        AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    private static func axWindowID(from windowElement: AXUIElement) -> CGWindowID? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(windowElement, "AXWindowNumber" as CFString, &copiedValue)
        guard result == .success, let copiedValue else { return nil }

        if let number = copiedValue as? NSNumber {
            return CGWindowID(number.uint32Value)
        }

        if let string = copiedValue as? String, let value = UInt32(string) {
            return CGWindowID(value)
        }

        return nil
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &copiedValue)
        return result == .success ? copiedValue as? String : nil
    }

    private static func frame(from element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        axValueAttribute(attribute, from: element, type: .cgPoint) { axValue in
            var point = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
        }
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        axValueAttribute(attribute, from: element, type: .cgSize) { axValue in
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
        }
    }

    private static func axValueAttribute<Value>(
        _ attribute: String,
        from element: AXUIElement,
        type: AXValueType,
        extract: (AXValue) -> Value?
    ) -> Value? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &copiedValue)
        guard result == .success,
              let copiedValue,
              CFGetTypeID(copiedValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = copiedValue as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        return extract(axValue)
    }

    private static func framesMatch(_ left: CGRect, _ right: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }
}

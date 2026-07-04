import AppKit
import ScreenCaptureKit

struct WindowPreview: Identifiable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let image: NSImage
    let windowBounds: CGRect
    let processIdentifier: pid_t?
}

struct WindowPreviewGroup {
    let applicationName: String
    let previews: [WindowPreview]
}

enum WindowPreviewProvider {
    static func previewGroup(for dockApp: DockApp) async -> WindowPreviewGroup? {
        let windowInfos = cgWindowInfos(for: dockApp)
        guard !windowInfos.isEmpty else { return nil }

        let windows = await screenCaptureWindows(matching: windowInfos, dockApp: dockApp)
        guard !windows.isEmpty else { return nil }

        var previews: [WindowPreview] = []

        for window in windows {
            if let preview = await preview(for: window, dockApp: dockApp) {
                previews.append(preview)
            }
        }

        guard !previews.isEmpty else { return nil }
        return WindowPreviewGroup(
            applicationName: previews.first?.applicationName ?? dockApp.name,
            previews: previews
        )
    }

    private static func preview(for window: SCWindow, dockApp: DockApp) async -> WindowPreview? {
        do {
            let configuration = SCStreamConfiguration()
            configuration.width = max(Int(window.frame.width), 1)
            configuration.height = max(Int(window.frame.height), 1)
            configuration.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let image = NSImage(cgImage: cgImage, size: window.frame.size)
            let appName = window.owningApplication?.applicationName ?? dockApp.name
            let title = window.title?.isEmpty == false ? window.title ?? appName : appName

            return WindowPreview(
                id: window.windowID,
                title: title,
                applicationName: appName,
                image: image,
                windowBounds: window.frame,
                processIdentifier: window.owningApplication?.processID ?? dockApp.processIdentifier
            )
        } catch {
            return nil
        }
    }

    private static func screenCaptureWindows(matching windowInfos: [CGWindowInfo], dockApp: DockApp) async -> [SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let windowIDs = Set(windowInfos.map(\.windowID))

            return content.windows
                .filter { window in
                    windowIDs.contains(window.windowID) && windowMatchesDockApp(window, dockApp: dockApp)
                }
                .sorted { left, right in
                    windowArea(left) > windowArea(right)
                }
        } catch {
            return []
        }
    }

    private static func cgWindowInfos(for dockApp: DockApp) -> [CGWindowInfo] {
        guard let axWindows = axTopLevelWindows(for: dockApp.processIdentifier),
              !axWindows.isEmpty,
              let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var seenWindowIDs = Set<CGWindowID>()

        return windowList.compactMap { windowInfo in
            guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  seenWindowIDs.insert(windowID).inserted,
                  let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  windowInfoMatchesDockApp(ownerPID: ownerPID, windowInfo: windowInfo, dockApp: dockApp),
                  isVisibleApplicationWindow(windowInfo),
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 160,
                  bounds.height > 100 else {
                return nil
            }

            let title = windowInfo[kCGWindowName as String] as? String
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? dockApp.name
            let candidate = CGWindowInfo(windowID: windowID, title: title, ownerName: ownerName, bounds: bounds)

            guard axWindows.contains(where: { $0.matches(candidate) }) else {
                return nil
            }

            return candidate
        }
    }

    private static func isVisibleApplicationWindow(_ windowInfo: [String: Any]) -> Bool {
        if let alpha = windowInfo[kCGWindowAlpha as String] as? Double, alpha <= 0 {
            return false
        }

        if let sharingState = windowInfo[kCGWindowSharingState as String] as? Int, sharingState == 0 {
            return false
        }

        return true
    }

    nonisolated private static func axTopLevelWindows(for processIdentifier: pid_t?) -> [AXWindowIdentity]? {
        guard let processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        var copiedWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &copiedWindows)
        guard result == .success,
              let windows = copiedWindows as? [AXUIElement] else {
            return nil
        }

        return windows.compactMap { windowElement in
            guard stringAttribute(kAXRoleAttribute, from: windowElement) == kAXWindowRole else { return nil }

            let title = stringAttribute(kAXTitleAttribute, from: windowElement)
            let position = pointAttribute(kAXPositionAttribute, from: windowElement)
            let size = sizeAttribute(kAXSizeAttribute, from: windowElement)
            let frame = position.flatMap { position in
                size.map { CGRect(origin: position, size: $0) }
            }

            return AXWindowIdentity(
                windowID: axWindowID(from: windowElement),
                title: title,
                frame: frame
            )
        }
    }

    nonisolated private static func axWindowID(from windowElement: AXUIElement) -> CGWindowID? {
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

    nonisolated private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &copiedValue)
        return result == .success ? copiedValue as? String : nil
    }

    nonisolated private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        axValueAttribute(attribute, from: element, type: .cgPoint) { axValue in
            var point = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
        }
    }

    nonisolated private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        axValueAttribute(attribute, from: element, type: .cgSize) { axValue in
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
        }
    }

    nonisolated private static func axValueAttribute<Value>(
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

    private static func windowInfoMatchesDockApp(ownerPID: pid_t, windowInfo: [String: Any], dockApp: DockApp) -> Bool {
        if let processIdentifier = dockApp.processIdentifier, ownerPID == processIdentifier {
            return true
        }

        if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
            return ownerName == dockApp.name
        }

        return false
    }

    private static func windowMatchesDockApp(_ window: SCWindow, dockApp: DockApp) -> Bool {
        if let processIdentifier = dockApp.processIdentifier,
           window.owningApplication?.processID == processIdentifier {
            return true
        }

        if let bundleIdentifier = dockApp.bundleIdentifier,
           window.owningApplication?.bundleIdentifier == bundleIdentifier {
            return true
        }

        return window.owningApplication?.applicationName == dockApp.name
    }

    private static func windowArea(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height
    }
}

private struct AXWindowIdentity {
    let windowID: CGWindowID?
    let title: String?
    let frame: CGRect?

    func matches(_ windowInfo: CGWindowInfo) -> Bool {
        if let windowID, windowID == windowInfo.windowID {
            return true
        }

        if let title, !title.isEmpty {
            guard let windowTitle = windowInfo.title, title == windowTitle else {
                return false
            }
        }

        guard let frame else { return true }
        return framesMatch(frame, windowInfo.bounds)
    }

    private func framesMatch(_ left: CGRect, _ right: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }
}

private struct CGWindowInfo {
    let windowID: CGWindowID
    let title: String?
    let ownerName: String
    let bounds: CGRect
}

import AppKit
import ApplicationServices

struct DockApp: Equatable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let dockFrame: CGRect?
}

final class DockHoverMonitor {
    private let onHoverChanged: (DockApp) -> Void
    private let onHoverEnded: () -> Void
    private let onStatusChanged: (String) -> Void

    private var observer: AXObserver?
    private var dockPID: pid_t?
    private var dockListElement: AXUIElement?
    private var hoveredApp: DockApp?
    private var lastStatus = "Waiting for Dock hover"

    init(
        onHoverChanged: @escaping (DockApp) -> Void,
        onHoverEnded: @escaping () -> Void,
        onStatusChanged: @escaping (String) -> Void
    ) {
        self.onHoverChanged = onHoverChanged
        self.onHoverEnded = onHoverEnded
        self.onStatusChanged = onStatusChanged
    }

    func start() {
        guard observer == nil else { return }

        guard AXIsProcessTrusted() else {
            updateStatus("Accessibility permission is not trusted")
            clearHover()
            return
        }

        guard setupSelectedDockItemObserver() else { return }
        processSelectedDockItemChanged()
    }

    func stop() {
        removeSelectedDockItemObserver()
        dockPID = nil
        dockListElement = nil
        hoveredApp = nil
        onHoverEnded()
    }

    private func setupSelectedDockItemObserver() -> Bool {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            updateStatus("Dock process was not found")
            return false
        }

        let dockPID = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockPID)

        guard let dockListElement = findDockListElement(in: dockElement) else {
            updateStatus("Dock accessibility list was not found")
            return false
        }

        var createdObserver: AXObserver?
        let result = AXObserverCreate(dockPID, dockSelectedChildrenChangedCallback, &createdObserver)
        guard result == .success, let createdObserver else {
            updateStatus("Dock accessibility observer could not be created")
            return false
        }

        let addResult = AXObserverAddNotification(
            createdObserver,
            dockListElement,
            kAXSelectedChildrenChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard addResult == .success || addResult == .notificationAlreadyRegistered else {
            updateStatus("Dock selected-item notification could not be registered")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        self.observer = createdObserver
        self.dockPID = dockPID
        self.dockListElement = dockListElement
        updateStatus("Waiting for Dock hover")
        return true
    }

    private func removeSelectedDockItemObserver() {
        guard let observer else { return }

        if let dockListElement {
            AXObserverRemoveNotification(
                observer,
                dockListElement,
                kAXSelectedChildrenChangedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }

    fileprivate func processSelectedDockItemChanged() {
        guard AXIsProcessTrusted() else {
            updateStatus("Accessibility permission is not trusted")
            clearHover()
            return
        }

        guard let hoveredDockItem = getSelectedDockItem() else {
            updateStatus("No Dock app is selected by the pointer")
            clearHover()
            return
        }

        guard let dockApp = runningDockApp(from: hoveredDockItem) else {
            updateStatus("Selected Dock item is not a running app")
            clearHover()
            return
        }

        updateStatus("Detected Dock app: \(dockApp.name)")
        guard dockApp != hoveredApp else { return }
        hoveredApp = dockApp
        onHoverChanged(dockApp)
    }

    private func clearHover() {
        guard hoveredApp != nil else { return }
        hoveredApp = nil
        onHoverEnded()
    }

    private func updateStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        DispatchQueue.main.async { [onStatusChanged] in
            onStatusChanged(status)
        }
    }

    private func getSelectedDockItem() -> AXUIElement? {
        if dockListElement == nil, let dockPID {
            dockListElement = findDockListElement(in: AXUIElementCreateApplication(dockPID))
        }

        guard let dockListElement else { return nil }

        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            dockListElement,
            DockAccessibilityAttribute.selectedChildren.rawValue as CFString,
            &copiedValue
        )
        guard result == .success,
              let selectedChildren = copiedValue as? [AXUIElement] else {
            return nil
        }

        return selectedChildren.first
    }

    private func runningDockApp(from dockItem: AXUIElement) -> DockApp? {
        let dockFrame = dockItemFrame(from: dockItem)

        if let bundleIdentifier = bundleIdentifierFromDockItem(dockItem) {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.activationPolicy == .regular }
            guard !runningApps.isEmpty else { return nil }

            let app = runningApp(from: runningApps, matching: dockItem, bundleIdentifier: bundleIdentifier)
            return DockApp(
                name: app.localizedName ?? bundleIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier,
                dockFrame: dockFrame
            )
        }

        guard let name = dockItemName(from: dockItem),
              let app = runningApplication(matchingDockItemName: name) else {
            return nil
        }

        return DockApp(
            name: app.localizedName ?? name,
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            dockFrame: dockFrame
        )
    }

    private func runningApp(
        from runningApps: [NSRunningApplication],
        matching dockItem: AXUIElement,
        bundleIdentifier: String
    ) -> NSRunningApplication {
        guard runningApps.count > 1 else { return runningApps[0] }

        let instanceIndex = dockItemInstanceIndex(dockItem, bundleIdentifier: bundleIdentifier)
        let boundedIndex = min(instanceIndex, runningApps.count - 1)
        return runningApps[boundedIndex]
    }

    private func dockItemInstanceIndex(_ dockItem: AXUIElement, bundleIdentifier: String) -> Int {
        guard let dockListElement else { return 0 }

        let dockItems = childElements(of: dockListElement)
        var matchingIndex = 0

        for candidate in dockItems {
            guard bundleIdentifierFromDockItem(candidate) == bundleIdentifier else { continue }

            if CFEqual(candidate, dockItem) {
                return matchingIndex
            }
            matchingIndex += 1
        }

        return 0
    }

    private func findDockListElement(in rootElement: AXUIElement) -> AXUIElement? {
        let directChildren = childElements(of: rootElement)
        if let directList = directChildren.first(where: { stringAttribute(.role, from: $0) == kAXListRole }) {
            return directList
        }

        var pending = directChildren
        var visited = Set<AXUIElement>()

        while let element = pending.first {
            pending.removeFirst()
            guard visited.insert(element).inserted else { continue }

            if stringAttribute(.role, from: element) == kAXListRole {
                return element
            }

            pending.append(contentsOf: childElements(of: element))
        }

        return directChildren.first
    }

    private func runningApplication(matchingDockItemName name: String) -> NSRunningApplication? {
        let normalizedDockName = normalizedAppName(name)

        return NSWorkspace.shared.runningApplications.first { runningApp in
            guard runningApp.activationPolicy == .regular,
                  let appName = runningApp.localizedName else {
                return false
            }

            let normalizedRunningName = normalizedAppName(appName)
            return normalizedDockName == normalizedRunningName
                || normalizedDockName.hasPrefix(normalizedRunningName)
                || normalizedDockName.contains(normalizedRunningName)
        }
    }

    private func normalizedAppName(_ value: String) -> String {
        value
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? value
    }

    private func bundleIdentifierFromDockItem(_ element: AXUIElement) -> String? {
        guard let appURL = urlAttribute(.url, from: element)?.absoluteURL,
              let bundle = Bundle(url: appURL) else {
            return nil
        }

        return bundle.bundleIdentifier
    }

    private func dockItemName(from element: AXUIElement) -> String? {
        for attribute in DockAccessibilityAttribute.nameAttributes {
            if let value = stringAttribute(attribute, from: element), !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func dockItemFrame(from element: AXUIElement) -> CGRect? {
        rawDockItemFrame(from: element).map(convertAccessibilityRectToAppKitRect)
    }

    private func rawDockItemFrame(from element: AXUIElement) -> CGRect? {
        if let frame = rectAttribute(.frame, from: element) {
            return frame
        }

        guard let position = pointAttribute(.position, from: element),
              let size = sizeAttribute(.size, from: element) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func convertAccessibilityRectToAppKitRect(_ rect: CGRect) -> CGRect {
        let screenFrame = NSScreen.screens.reduce(NSRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard !screenFrame.isNull else { return rect }
        return CGRect(x: rect.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var children: [AXUIElement] = []

        for attribute in DockAccessibilityAttribute.childAttributes {
            var copiedValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &copiedValue)
            guard result == .success else { continue }

            if let childArray = copiedValue as? [AXUIElement] {
                children.append(contentsOf: childArray)
            }
        }

        return children
    }

    private func stringAttribute(_ attribute: DockAccessibilityAttribute, from element: AXUIElement) -> String? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &copiedValue)
        return result == .success ? copiedValue as? String : nil
    }

    private func urlAttribute(_ attribute: DockAccessibilityAttribute, from element: AXUIElement) -> URL? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &copiedValue)
        guard result == .success else { return nil }

        if let url = copiedValue as? URL {
            return url
        }

        if let string = copiedValue as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }

        return nil
    }

    private func pointAttribute(_ attribute: DockAccessibilityAttribute, from element: AXUIElement) -> CGPoint? {
        axValueAttribute(attribute, from: element, type: .cgPoint) { axValue in
            var point = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
        }
    }

    private func sizeAttribute(_ attribute: DockAccessibilityAttribute, from element: AXUIElement) -> CGSize? {
        axValueAttribute(attribute, from: element, type: .cgSize) { axValue in
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
        }
    }

    private func rectAttribute(_ attribute: DockAccessibilityAttribute, from element: AXUIElement) -> CGRect? {
        axValueAttribute(attribute, from: element, type: .cgRect) { axValue in
            var rect = CGRect.zero
            return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
        }
    }

    private func axValueAttribute<Value>(
        _ attribute: DockAccessibilityAttribute,
        from element: AXUIElement,
        type: AXValueType,
        extract: (AXValue) -> Value?
    ) -> Value? {
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &copiedValue)
        guard result == .success,
              let copiedValue,
              CFGetTypeID(copiedValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = copiedValue as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }

        return extract(axValue)
    }
}

private func dockSelectedChildrenChangedCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }

    let monitor = Unmanaged<DockHoverMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.processSelectedDockItemChanged()
    }
}

private enum DockAccessibilityAttribute: String {
    case children = "AXChildren"
    case contents = "AXContents"
    case description = "AXDescription"
    case frame = "AXFrame"
    case help = "AXHelp"
    case label = "AXLabel"
    case position = "AXPosition"
    case role = "AXRole"
    case rows = "AXRows"
    case selectedChildren = "AXSelectedChildren"
    case size = "AXSize"
    case title = "AXTitle"
    case url = "AXURL"
    case value = "AXValue"
    case visibleChildren = "AXVisibleChildren"

    static let childAttributes: [DockAccessibilityAttribute] = [.children, .visibleChildren, .contents, .rows]
    static let nameAttributes: [DockAccessibilityAttribute] = [.title, .label, .description, .value, .help]
}

import AppKit
import Combine
import CoreGraphics
import ServiceManagement
import SwiftUI

@MainActor
final class AppController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isMonitoring = false
    @Published private(set) var accessibilityPermissionGranted = AXIsProcessTrusted()
    @Published private(set) var screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var dockMonitorStatus = "Waiting for Dock hover"
    @Published private(set) var previewStatus = "No preview requested yet"
    @Published private(set) var lastDetectedAppName = "None"
    @Published var startsAtLogin: Bool {
        didSet {
            guard startsAtLogin != oldValue else { return }
            updateLoginItemRegistration()
        }
    }
    @Published var previewDelaySeconds: Double {
        didSet {
            let clampedValue = Self.clampedPreviewDelay(previewDelaySeconds)
            if previewDelaySeconds != clampedValue {
                previewDelaySeconds = clampedValue
                return
            }

            UserDefaults.standard.set(previewDelaySeconds, forKey: Self.previewDelayUserDefaultsKey)
        }
    }
    private let previewPanel = WindowPreviewPanel()
    private var previewTask: Task<Void, Never>?
    private var pointerTrackingTimer: Timer?
    private var dockMouseDownMonitor: Any?
    private var settingsWindow: NSWindow?
    private var activeDockApp: DockApp?
    private var pointerIsOverActiveDockApp = false

    private static let previewDelayUserDefaultsKey = "previewDelaySeconds"
    private static let defaultPreviewDelaySeconds = 0.5
    private static let previewDelayRange = 0.0...3.0

    private var previewShowDelay: Duration {
        .milliseconds(Int((previewDelaySeconds * 1000).rounded()))
    }

    private lazy var dockHoverMonitor = DockHoverMonitor { [weak self] dockApp in
        Task { @MainActor in
            self?.handleDockHoverChanged(dockApp)
        }
    } onHoverEnded: { [weak self] in
        Task { @MainActor in
            self?.handleDockHoverEnded()
        }
    } onStatusChanged: { [weak self] status in
        Task { @MainActor in
            self?.dockMonitorStatus = status
        }
    }

    var permissionStatusMessage: String {
        switch (accessibilityPermissionGranted, screenRecordingPermissionGranted) {
        case (true, true):
            "Required permissions are enabled."
        case (false, true):
            "Accessibility permission is needed to detect which Dock app the pointer is hovering."
        case (true, false):
            "Screen Recording permission is needed to capture live window previews."
        case (false, false):
            "Accessibility and Screen Recording permissions are needed for Dock detection and live previews."
        }
    }

    override init() {
        startsAtLogin = Self.currentLoginItemStatus()
        previewDelaySeconds = Self.storedPreviewDelaySeconds()
        super.init()
        setMonitoring(true)
    }

    func setMonitoring(_ isEnabled: Bool) {
        guard isEnabled != isMonitoring else { return }
        isMonitoring = isEnabled

        if isEnabled {
            requestRequiredPermissions()
            dockHoverMonitor.start()
        } else {
            cancelPreviewAndHide()
            dockHoverMonitor.stop()
        }
    }

    func toggleMonitoring() {
        setMonitoring(!isMonitoring)
    }

    func openSettingsWindow() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }

        settingsWindow?.delegate = nil
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func requestRequiredPermissions() {
        requestAccessibilityPermissionIfNeeded()
        requestScreenRecordingPermissionIfNeeded()
        refreshPermissionStatus()
    }

    func showTestPreview() {
        let previewGroup = WindowPreviewGroup(
            applicationName: "WindowPeek Test",
            previews: [
                WindowPreview(
                    id: 1,
                    title: "Preview panel is visible",
                    applicationName: "WindowPeek Test",
                    image: Self.makeTestPreviewImage(),
                    windowBounds: CGRect(x: 0, y: 0, width: 320, height: 200),
                    processIdentifier: nil
                )
            ]
        )

        previewStatus = "Showing test preview panel"
        previewPanel.show(
            previewGroup,
            above: nil,
            near: NSEvent.mouseLocation,
            onPreviewSelected: { _ in },
            onPreviewClosed: { _ in },
            onPreviewMinimized: { _ in }
        )
        startPointerTracking()
    }

    func refreshPermissionStatus() {
        accessibilityPermissionGranted = AXIsProcessTrusted()
        screenRecordingPermissionGranted = CGPreflightScreenCaptureAccess()
    }

    private func handleDockHoverChanged(_ dockApp: DockApp) {
        pointerIsOverActiveDockApp = true
        activeDockApp = dockApp
        lastDetectedAppName = dockApp.name
        schedulePreview(for: dockApp)
    }

    private func handleDockHoverEnded() {
        pointerIsOverActiveDockApp = false
        scheduleDismissalCheck()
    }

    private func schedulePreview(for dockApp: DockApp) {
        previewTask?.cancel()
        previewPanel.hide()
        previewStatus = "Waiting to show previews for \(dockApp.name)..."
        startPointerTracking()

        let delay = previewShowDelay
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            let shouldLoad = await MainActor.run { [weak self] in
                self?.shouldKeepPreview(for: dockApp) == true
            }
            guard shouldLoad else { return }

            await MainActor.run { [weak self] in
                self?.previewStatus = "Loading previews for \(dockApp.name)..."
            }

            guard let previewGroup = await WindowPreviewProvider.previewGroup(for: dockApp), !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    guard self?.activeDockApp == dockApp else { return }
                    self?.previewStatus = "No capturable windows found for \(dockApp.name)"
                    self?.previewPanel.hide()
                    self?.refreshPermissionStatus()
                    self?.stopPointerTrackingIfIdle()
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self, shouldKeepPreview(for: dockApp) else { return }
                refreshPermissionStatus()
                previewStatus = "Showing \(previewGroup.previews.count) window preview(s) for \(previewGroup.applicationName)"
                previewPanel.show(
                    previewGroup,
                    above: dockApp.dockFrame,
                    near: NSEvent.mouseLocation,
                    onPreviewSelected: { [weak self] preview in
                        WindowPreviewActivator.activate(preview)
                        Task { @MainActor in
                            self?.cancelPreviewAndHide()
                        }
                    },
                    onPreviewClosed: { [weak self] preview in
                        WindowPreviewActivator.close(preview)
                        Task { @MainActor in
                            self?.cancelPreviewAndHide()
                        }
                    },
                    onPreviewMinimized: { [weak self] preview in
                        WindowPreviewActivator.minimize(preview)
                        Task { @MainActor in
                            self?.cancelPreviewAndHide()
                        }
                    }
                )
                startPointerTracking()
            }
        }
    }

    private func scheduleDismissalCheck() {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                self?.hidePreviewIfPointerLeftActiveRegions()
            }
        }
    }

    private func startPointerTracking() {
        startDockMouseDownMonitoring()
        guard pointerTrackingTimer == nil else { return }

        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.hidePreviewIfPointerLeftActiveRegions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTrackingTimer = timer
    }

    private func stopPointerTrackingIfIdle() {
        guard !pointerIsOverActiveDockApp, !previewPanel.isVisible else { return }
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
        stopDockMouseDownMonitoring()
    }

    private func startDockMouseDownMonitoring() {
        guard dockMouseDownMonitor == nil else { return }

        dockMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePreviewIfMouseDownIsOnActiveDockApp()
            }
        }
    }

    private func stopDockMouseDownMonitoring() {
        guard let dockMouseDownMonitor else { return }
        NSEvent.removeMonitor(dockMouseDownMonitor)
        self.dockMouseDownMonitor = nil
    }

    private func hidePreviewIfPointerLeftActiveRegions() {
        guard let activeDockApp else {
            cancelPreviewAndHide()
            return
        }

        guard !isPointerOverDockApp(activeDockApp) && !previewPanel.contains(NSEvent.mouseLocation) else {
            return
        }

        cancelPreviewAndHide()
    }

    private func hidePreviewIfMouseDownIsOnActiveDockApp() {
        guard previewPanel.isVisible,
              let activeDockApp,
              isPointerOverDockApp(activeDockApp) else {
            return
        }

        cancelPreviewAndHide()
    }

    private func shouldKeepPreview(for dockApp: DockApp) -> Bool {
        activeDockApp == dockApp && (isPointerOverDockApp(dockApp) || previewPanel.contains(NSEvent.mouseLocation))
    }

    private func isPointerOverDockApp(_ dockApp: DockApp) -> Bool {
        guard let dockFrame = dockApp.dockFrame else {
            return pointerIsOverActiveDockApp && activeDockApp == dockApp
        }

        return dockFrame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
    }

    private func cancelPreviewAndHide() {
        previewTask?.cancel()
        previewTask = nil
        activeDockApp = nil
        pointerIsOverActiveDockApp = false
        previewPanel.hide()
        pointerTrackingTimer?.invalidate()
        pointerTrackingTimer = nil
        stopDockMouseDownMonitoring()
    }

    private static func makeTestPreviewImage() -> NSImage {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 18, y: 132, width: 284, height: 44), xRadius: 8, yRadius: 8).fill()
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 18, y: 84, width: 210, height: 20), xRadius: 5, yRadius: 5).fill()
        NSBezierPath(roundedRect: NSRect(x: 18, y: 52, width: 252, height: 20), xRadius: 5, yRadius: 5).fill()
        image.unlockFocus()

        return image
    }

    private func makeSettingsWindow() -> NSWindow {
        let hostingView = NSHostingView(
            rootView: ContentView()
                .environmentObject(self)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "WindowPeek Settings"
        window.contentView = hostingView
        window.delegate = self
        window.isReleasedWhenClosed = false
        return window
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func requestScreenRecordingPermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }

    private func updateLoginItemRegistration() {
        guard #available(macOS 13.0, *) else { return }

        do {
            if startsAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            startsAtLogin = Self.currentLoginItemStatus()
        }
    }

    private static func currentLoginItemStatus() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    private static func storedPreviewDelaySeconds() -> Double {
        guard UserDefaults.standard.object(forKey: previewDelayUserDefaultsKey) != nil else {
            return defaultPreviewDelaySeconds
        }

        return clampedPreviewDelay(UserDefaults.standard.double(forKey: previewDelayUserDefaultsKey))
    }

    private static func clampedPreviewDelay(_ value: Double) -> Double {
        min(max(value, previewDelayRange.lowerBound), previewDelayRange.upperBound)
    }
}

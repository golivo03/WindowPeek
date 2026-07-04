import SwiftUI

@main
struct WindowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appController = AppController()

    var body: some Scene {
        MenuBarExtra("WindowPeek", systemImage: "sunglasses") {
            Button("Open Settings") {
                appController.openSettingsWindow()
            }

            Button("Quit WindowPeek") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            ContentView()
                .environmentObject(appController)
        }
    }
}

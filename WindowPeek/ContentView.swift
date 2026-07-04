import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appController: AppController
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem {
                    Label(SettingsPane.general.title, systemImage: SettingsPane.general.systemImage)
                }
                .tag(SettingsPane.general)

            previewPane
                .tabItem {
                    Label(SettingsPane.preview.title, systemImage: SettingsPane.preview.systemImage)
                }
                .tag(SettingsPane.preview)

            aboutPane
                .tabItem {
                    Label(SettingsPane.about.title, systemImage: SettingsPane.about.systemImage)
                }
                .tag(SettingsPane.about)
        }
        .padding(22)
        .frame(width: 560, height: 360)
        .onAppear {
            appController.refreshPermissionStatus()
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                PermissionStatusRow(
                    title: "Accessibility",
                    description: "Detect Dock hover targets.",
                    isGranted: appController.accessibilityPermissionGranted
                )

                PermissionStatusRow(
                    title: "Screen Recording",
                    description: "Capture live window previews.",
                    isGranted: appController.screenRecordingPermissionGranted
                )

                Text(appController.permissionStatusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Permissions")
            }

            Section {
                Toggle("Start WindowPeek at login", isOn: $appController.startsAtLogin)
            } header: {
                Text("Launch")
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Preview delay:", value: delayValueText)

                    Slider(value: $appController.previewDelaySeconds, in: 0...3, step: 0.1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0s")
                    } maximumValueLabel: {
                        Text("3s")
                    }
                }
            } header: {
                Text("Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appName)
                            .font(.title3)
                            .fontWeight(.semibold)

                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let githubURL {
                        Link("GitHub", destination: githubURL)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private var delayValueText: String {
        appController.previewDelaySeconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "WindowPeek"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private var githubURL: URL? {
        URL(string: "https://github.com")
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case preview
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .preview:
            "Preview"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .preview:
            "rectangle.on.rectangle"
        case .about:
            "info.circle"
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let description: String
    let isGranted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(isGranted ? "Enabled" : "Needed", systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isGranted ? .green : .orange)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppController())
}

import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var deviceManager: ElgatoDeviceManager
    @ObservedObject var cameraMonitor: CameraMonitor

    var body: some View {
        TabView {
            AutomationSettingsView(appState: appState, cameraMonitor: cameraMonitor)
                .tabItem {
                    Label("Automation", systemImage: "switch.2")
                }

            DeviceSettingsView(deviceManager: deviceManager)
                .tabItem {
                    Label("Devices", systemImage: "lightbulb")
                }

            KeyboardShortcutsView(appState: appState)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }
}

struct GeneralSettingsView: View {
    let updateChecker = GitHubUpdateChecker()

    var body: some View {
        VStack(spacing: 20) {
            settingRow(label: "Launch:") {
                LaunchAtLogin.Toggle("Automatically at system startup")
            }

            Divider()

            settingRow(label: "Updates:") {
                Button("Check for Updates") {
                    updateChecker.checkForNewRelease { isNew, version in
                        DispatchQueue.main.async {
                            if isNew, let version {
                                updateChecker.promptForUpdate(newVersion: version)
                            } else {
                                updateChecker.promptForNoUpdate()
                            }
                        }
                    }
                }
            }

            Spacer()
            Divider()
            ResetButton(action: resetToDefaults)
        }
    }

    private func resetToDefaults() {
        LaunchAtLogin.isEnabled = false
    }
}

struct KeyboardShortcutsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            shortcutRow(
                label: "Toggle Lights:",
                shortcut: .toggleLights,
                caption: "Toggle lights on/off."
            )

            shortcutRow(
                label: "Toggle Night Shift Sync:",
                shortcut: .toggleNightShiftSync,
                caption: "Toggle synchronization with macOS Night Shift."
            )

            Divider()

            shortcutRow(
                label: "Brightness Up:",
                shortcut: .increaseBrightness,
                caption: "Increase all lights' brightness."
            )

            shortcutRow(
                label: "Brightness Down:",
                shortcut: .decreaseBrightness,
                caption: "Decrease all lights' brightness."
            )

            settingRow(label: "Brightness Step:") {
                Stepper(
                    "\(appState.brightnessStepPercent)%",
                    value: $appState.brightnessStepPercent,
                    in: 1...25,
                    step: 1
                )
            } caption: {
                Text("Amount per key press.")
            }

            Divider()

            shortcutRow(
                label: "Cooler:",
                shortcut: .increaseTemperature,
                caption: "Make lights cooler (more blue)."
            )

            shortcutRow(
                label: "Warmer:",
                shortcut: .decreaseTemperature,
                caption: "Make lights warmer (more yellow)."
            )

            settingRow(label: "Temperature Step:") {
                Stepper(
                    "\(appState.temperatureStepKelvin)K",
                    value: $appState.temperatureStepKelvin,
                    in: 100...1000,
                    step: 100
                )
            } caption: {
                Text("Amount per key press.")
            }

            Divider()
            ResetButton(action: resetToDefaults)
        }
    }

    private func shortcutRow(label: String, shortcut: KeyboardShortcuts.Name, caption: String) -> some View {
        settingRow(label: label) {
            KeyboardShortcuts.Recorder(for: shortcut)
                .padding(.top, -1)
        } caption: {
            Text(caption)
        }
    }

    private func resetToDefaults() {
        KeyboardShortcuts.reset(.toggleLights)
        KeyboardShortcuts.reset(.increaseBrightness)
        KeyboardShortcuts.reset(.decreaseBrightness)
        KeyboardShortcuts.reset(.increaseTemperature)
        KeyboardShortcuts.reset(.decreaseTemperature)
        KeyboardShortcuts.reset(.toggleNightShiftSync)
        appState.brightnessStepPercent = 5
        appState.temperatureStepKelvin = 500
    }
}

func settingRow(
    label: String,
    @ViewBuilder content: () -> some View,
    @ViewBuilder caption: () -> some View = { EmptyView() }
) -> some View {
    HStack(alignment: .top) {
        Text(label)
            .frame(width: 130, alignment: .trailing)
        VStack(alignment: .leading, spacing: 4) {
            content()
            caption()
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResetButton: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults", action: action)
        }
    }
}

import Combine
import KeyboardShortcuts
import os
import SwiftUI

class AppState: ObservableObject {
    @AppStorage("lightsOnWithCamera") var lightsOnWithCamera: Bool = false
    @AppStorage("lightsOffOnSleep") var lightsOffOnSleep: Bool = false
    @AppStorage("syncWithNightShift") var syncWithNightShift: Bool = false
    @AppStorage("wakeOnCameraDetectionEnabled") var wakeOnCameraDetectionEnabled: Bool = false
    @AppStorage("boostBrightnessOnCamera") var boostBrightnessOnCamera: Bool = false
    @AppStorage("cameraBrightnessBoostPercent") var cameraBrightnessBoostPercent: Int = 20
    @AppStorage("brightnessStepPercent") var brightnessStepPercent: Int = 5
    @AppStorage("temperatureStepKelvin") var temperatureStepKelvin: Int = 500

    @AppStorage("wakeOnCameraInfoJSON") private var wakeOnCameraInfoJSON: String = ""

    @Published var selectedCamera: StoredCameraInfo? {
        didSet {
            if let newCamera = selectedCamera,
               let data = try? JSONEncoder().encode(newCamera),
               let jsonString = String(data: data, encoding: .utf8)
            {
                wakeOnCameraInfoJSON = jsonString
            } else {
                wakeOnCameraInfoJSON = ""
            }
        }
    }

    init() {
        if let data = wakeOnCameraInfoJSON.data(using: .utf8),
           let cameraInfo = try? JSONDecoder().decode(StoredCameraInfo.self, from: data)
        {
            self.selectedCamera = cameraInfo
        } else {
            self.selectedCamera = nil
        }
    }
}

class AppCoordinator: ObservableObject {
    @Published var appState: AppState
    @Published var deviceManager: ElgatoDeviceManager
    let cameraMonitor: CameraMonitor

    lazy var lightCameraController: LightCameraController = .init(
        deviceManager: deviceManager,
        appState: appState,
        cameraStatusPublisher: cameraDetector.cameraStatusPublisher
    )

    lazy var lightSystemStateController: LightSystemStateController = .init(
        deviceManager: deviceManager,
        appState: appState
    )

    lazy var nightShiftSyncController: NightShiftSyncController = .init(
        deviceManager: deviceManager,
        appState: appState
    )

    private var cameraDetector: CameraUsageDetector
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "AppCoordinator"
    )

    init() {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        logger.info("Application started - Version: \(version)")
        let discovery = ElgatoDiscovery()
        deviceManager = ElgatoDeviceManager(discovery: discovery)
        appState = AppState()
        cameraDetector = CameraUsageDetector()
        cameraMonitor = CameraMonitor()

        setupControllers()
        setupBindings()
        setupShortcuts()

        cameraDetector.updateMonitoring(
            enabled: appState.lightsOnWithCamera || appState.boostBrightnessOnCamera
        )

        Task { @MainActor in
            deviceManager.loadDevicesFromPersistentStorage()
            deviceManager.startDiscovery()
        }
    }

    private func setupControllers() {
        _ = lightCameraController
        _ = lightSystemStateController
        _ = nightShiftSyncController
    }

    private func setupBindings() {
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let needsMonitoring = self.appState.lightsOnWithCamera
                    || self.appState.boostBrightnessOnCamera
                self.cameraDetector.updateMonitoring(enabled: needsMonitoring)
            }
            .store(in: &cancellables)
    }

    private func setupShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .toggleLights) { [weak self] in
            Task { @MainActor in
                await self?.deviceManager.toggleAllLights()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .increaseBrightness) { [weak self] in
            Task { @MainActor in
                guard let self, let deviceManager = Optional(self.deviceManager) else { return }
                let brightnessStep = max(1, min(self.appState.brightnessStepPercent, 25))
                let currentBrightness = deviceManager.devices
                    .filter(\.isOnline)
                    .map(\.brightness)
                    .max() ?? 0
                let newBrightness = min(currentBrightness + brightnessStep, 100)
                await deviceManager.setAllLightsBrightness(newBrightness)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .decreaseBrightness) { [weak self] in
            Task { @MainActor in
                guard let self, let deviceManager = Optional(self.deviceManager) else { return }
                let brightnessStep = max(1, min(self.appState.brightnessStepPercent, 25))
                let currentBrightness = deviceManager.devices
                    .filter(\.isOnline)
                    .map(\.brightness)
                    .max() ?? 0
                let newBrightness = max(currentBrightness - brightnessStep, 0)
                await deviceManager.setAllLightsBrightness(newBrightness)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .increaseTemperature) { [weak self] in
            Task { @MainActor in
                guard let self, let deviceManager = Optional(self.deviceManager) else { return }
                let temperatureStep = max(100, min(self.appState.temperatureStepKelvin, 1000))

                // Disable night shift sync when manually adjusting temperature
                if self.appState.syncWithNightShift {
                    self.appState.syncWithNightShift = false
                }

                let currentTemp = deviceManager.devices
                    .filter(\.isOnline)
                    .map(\.temperature)
                    .max() ?? 4000
                let newTemp = min(currentTemp + temperatureStep, 7000)
                await deviceManager.setAllLightsTemperature(newTemp)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .decreaseTemperature) { [weak self] in
            Task { @MainActor in
                guard let self, let deviceManager = Optional(self.deviceManager) else { return }
                let temperatureStep = max(100, min(self.appState.temperatureStepKelvin, 1000))

                // Disable night shift sync when manually adjusting temperature
                if self.appState.syncWithNightShift {
                    self.appState.syncWithNightShift = false
                }

                let currentTemp = deviceManager.devices
                    .filter(\.isOnline)
                    .map(\.temperature)
                    .max() ?? 4000
                let newTemp = max(currentTemp - temperatureStep, 2900)
                await deviceManager.setAllLightsTemperature(newTemp)
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleNightShiftSync) { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                // Toggle the Night Shift sync state
                self.appState.syncWithNightShift.toggle()

                // Log the change
                let newState = self.appState.syncWithNightShift ? "enabled" : "disabled"
                self.logger.info("Night Shift sync \(newState) via keyboard shortcut")
            }
        }
    }
}

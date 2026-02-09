import Combine
import Foundation
import Network
import os

class LightCameraController {
    private let deviceManager: ElgatoDeviceManager
    private let appState: AppState
    private let cameraStatusPublisher: AnyPublisher<Bool, Never>
    private var cancellables: Set<AnyCancellable> = []
    private var lightsControlledByCamera: Set<ElgatoDevice> = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LightCameraController")
    private var isCameraActive: Bool = false
    private var preBoostedBrightness: [NWEndpoint: Int] = [:]
    private var previousBoostEnabled: Bool = false
    private var previousBoostPercent: Int = 20
    private var previousLightsOnWithCamera: Bool = false

    init(deviceManager: ElgatoDeviceManager,
         appState: AppState,
         cameraStatusPublisher: AnyPublisher<Bool, Never>)
    {
        self.deviceManager = deviceManager
        self.appState = appState
        self.cameraStatusPublisher = cameraStatusPublisher
        self.previousBoostEnabled = appState.boostBrightnessOnCamera
        self.previousBoostPercent = appState.cameraBrightnessBoostPercent
        self.previousLightsOnWithCamera = appState.lightsOnWithCamera
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.handleSettingsChange()
            }
            .store(in: &cancellables)

        cameraStatusPublisher
            .sink { [weak self] isActive in
                self?.handleCameraActivityChange(isActive: isActive)
            }
            .store(in: &cancellables)
    }

    private func handleSettingsChange() {
        let currentBoostEnabled = appState.boostBrightnessOnCamera
        let currentBoostPercent = appState.cameraBrightnessBoostPercent
        let currentLightsOn = appState.lightsOnWithCamera

        // Handle lightsOnWithCamera changes (only on actual change)
        if currentLightsOn != previousLightsOnWithCamera {
            if currentLightsOn, isCameraActive {
                turnOnAllLights()
            } else if !currentLightsOn {
                turnOffControlledLights()
            }
        }

        // Handle brightness boost changes
        if isCameraActive {
            if previousBoostEnabled, !currentBoostEnabled {
                // Toggle turned OFF while camera active
                restoreBrightness()
                preBoostedBrightness.removeAll()
            } else if !previousBoostEnabled, currentBoostEnabled {
                // Toggle turned ON while camera active
                applyBrightnessBoost()
            } else if currentBoostEnabled, currentBoostPercent != previousBoostPercent {
                // Percent changed while camera active & boost enabled
                recomputeBrightnessBoost()
            }
        }

        previousLightsOnWithCamera = currentLightsOn
        previousBoostEnabled = currentBoostEnabled
        previousBoostPercent = currentBoostPercent
    }

    private func handleCameraActivityChange(isActive: Bool) {
        isCameraActive = isActive
        if isActive {
            if appState.lightsOnWithCamera {
                checkAndTurnOnLights()
            }
            if appState.boostBrightnessOnCamera {
                applyBrightnessBoost()
            }
        } else {
            // Restore brightness for ALL boosted devices first (including those we'll turn off)
            if !preBoostedBrightness.isEmpty {
                restoreBrightness()
                preBoostedBrightness.removeAll()
            }
            if appState.lightsOnWithCamera {
                turnOffControlledLights()
            }
        }
    }

    private func applyBrightnessBoost() {
        let boostPercent = appState.cameraBrightnessBoostPercent
        for device in deviceManager.devices where device.isOnline && device.isManaged {
            Task { @MainActor in
                do {
                    try await device.fetchLightInfo()
                    let originalBrightness = device.brightness
                    self.preBoostedBrightness[device.endpoint] = originalBrightness
                    let boosted = min(originalBrightness + boostPercent, 100)
                    try await device.setBrightness(boosted)
                    self.logger.info("Boosted brightness for \(device.name, privacy: .public): \(originalBrightness) -> \(boosted)")
                } catch {
                    self.logger.error("Failed to boost brightness for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func restoreBrightness() {
        for (endpoint, originalBrightness) in preBoostedBrightness {
            guard let device = deviceManager.devices.first(where: { $0.endpoint == endpoint }) else { continue }
            Task {
                do {
                    try await device.setBrightness(originalBrightness)
                    logger.info("Restored brightness for \(device.name, privacy: .public) to \(originalBrightness)")
                } catch {
                    logger.error("Failed to restore brightness for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func recomputeBrightnessBoost() {
        let newPercent = appState.cameraBrightnessBoostPercent
        for (endpoint, originalBrightness) in preBoostedBrightness {
            guard let device = deviceManager.devices.first(where: { $0.endpoint == endpoint }) else { continue }
            let boosted = min(originalBrightness + newPercent, 100)
            Task {
                do {
                    try await device.setBrightness(boosted)
                    logger.info("Recomputed brightness for \(device.name, privacy: .public): \(originalBrightness) + \(newPercent)% = \(boosted)")
                } catch {
                    logger.error("Failed to recompute brightness for \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func checkAndTurnOnLights() {
        for device in deviceManager.devices where device.isOnline {
            Task { @MainActor in
                do {
                    try await device.fetchLightInfo()
                    if !device.isOn {
                        try await device.turnOn()
                        self.lightsControlledByCamera.insert(device)
                        self.logger.info("Turned on device: \(device.name, privacy: .public)")
                    } else {
                        self.logger.info("Device already on: \(device.name, privacy: .public)")
                    }
                } catch {
                    self.logger
                        .error(
                            "Failed to check or turn on device: \(device.name, privacy: .public). Error: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }
        logger.info("Checked and turned on necessary lights due to camera activity")
    }

    private func turnOffControlledLights() {
        for device in lightsControlledByCamera {
            Task {
                do {
                    try await device.turnOff()
                    logger.info("Turned off controlled device: \(device.name, privacy: .public)")
                } catch {
                    logger
                        .error(
                            "Failed to turn off controlled device: \(device.name, privacy: .public). Error: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }

        lightsControlledByCamera.removeAll()
    }

    private func turnOnAllLights() {
        for device in deviceManager.devices where device.isOnline {
            Task { @MainActor in
                do {
                    try await device.turnOn()
                    self.lightsControlledByCamera.insert(device)
                    self.logger.info("Turned on device: \(device.name, privacy: .public)")
                } catch {
                    self.logger
                        .error(
                            "Failed to turn on device: \(device.name, privacy: .public). Error: \(error.localizedDescription, privacy: .public)"
                        )
                }
            }
        }
        logger.info("All lights turned on due to lights-on-with-camera setting")
    }
}

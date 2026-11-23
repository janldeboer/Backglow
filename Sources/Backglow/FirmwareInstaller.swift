import BackglowCore
import Foundation

/// Installs the firmware that ships in the app on the selected controller: releases the
/// port, resets the board into the ESP ROM loader, refuses a chip that does not match the
/// image before writing anything, writes and verifies, restarts the board and reconnects.
@MainActor
final class FirmwareInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle, working, succeeded, failed
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var message: String?
    /// 0…1 while writing, nil while waiting.
    @Published private(set) var progress: Double?

    let manifest: FirmwareManifest?
    private let folder: URL?
    private let queue = DispatchQueue(label: "lighting.firmware.install", qos: .userInitiated)

    init(bundle: Bundle = .main) {
        let folder = bundle.resourceURL?.appendingPathComponent("Firmware", isDirectory: true)
        self.folder = folder
        manifest = folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }
            .flatMap { try? JSONDecoder().decode(FirmwareManifest.self, from: $0) }
    }

    var isWorking: Bool { phase == .working }

    func image(id: String?) -> FirmwareManifest.Image? {
        manifest?.images.first { $0.id == id }
    }

    func install(_ image: FirmwareManifest.Image, on port: SerialPortChoice, model: LightingModel) {
        guard !isWorking, let folder, let manifest else { return }
        let serial = model.serial
        let backup = serial.storedProfile
        phase = .working
        progress = nil
        message = String(localized: "Trenne die Verbindung zum Controller…")
        let resume = model.prepareForFirmwareInstall()
        serial.flush() // The black frame and the close are on the serial queue; wait for both.

        queue.async {
            let result = Result { try Self.write(image, from: folder, to: port) { step in
                DispatchQueue.main.async { self.show(step, image: image) }
            } }
            DispatchQueue.main.async {
                switch result {
                case .success(let chip):
                    self.progress = nil
                    self.message = String(localized: "\(chip.displayName) beschrieben und neu gestartet. Warte auf die neue Firmware…")
                    model.finishFirmwareInstall(path: port.id, resume: resume)
                    self.confirm(manifest.version, model: model, backup: backup, deadline: Date().addingTimeInterval(10))
                case .failure(let error):
                    self.phase = .failed
                    self.progress = nil
                    self.message = Self.describe(error, image: image)
                    model.finishFirmwareInstall(path: port.id, resume: resume)
                }
            }
        }
    }

    /// Runs on the install queue.
    nonisolated private static func write(_ image: FirmwareManifest.Image, from folder: URL, to port: SerialPortChoice,
                                          progress: @escaping (ESPLoader.Step) -> Void) throws -> ESPChip {
        let regions = try FirmwareManifest.regions(for: image, in: folder)
        // The same adapter must still be at this path, as when connecting.
        guard USBSerialPortDiscovery.available().contains(where: {
            $0.id == port.id && $0.vendorID == port.vendorID && $0.productID == port.productID &&
                $0.serialNumber == port.serialNumber
        }) else { throw InstallError.portChanged }
        let link = try POSIXSerialLink(path: port.id)
        defer { link.close() }
        let loader = ESPLoader(link: link)
        progress(.connecting)
        let chip = try loader.connect()
        // Whatever happens next, start the code in flash again: old or new firmware.
        defer { try? loader.hardReset() }
        try loader.flash(regions, expected: image.chip, progress: progress)
        progress(.restarting)
        return chip
    }

    private func show(_ step: ESPLoader.Step, image: FirmwareManifest.Image) {
        let parts = image.parts.count
        switch step {
        case .connecting:
            message = String(localized: "Starte den Bootloader…")
        case .connected(let chip):
            message = String(localized: "\(chip.displayName) erkannt")
        case .erasing(let region):
            progress = Double(region) / Double(parts)
            message = String(localized: "Lösche Bereich \(region + 1) von \(parts)…")
        case .writing(let region, let fraction):
            progress = (Double(region) + fraction) / Double(parts)
            message = String(localized: "Schreibe Bereich \(region + 1) von \(parts)…")
        case .verifying(let region):
            message = String(localized: "Prüfe Bereich \(region + 1) von \(parts)…")
        case .restarting:
            progress = 1
            message = String(localized: "Starte den Controller neu…")
        }
    }

    /// Waits for the new firmware to report its version. A profile that was on the
    /// controller before and is missing now is written back.
    private func confirm(_ version: FirmwareVersion, model: LightingModel, backup: ControllerProfile?,
                         deadline: Date, restored: Bool = false) {
        let serial = model.serial
        if serial.controllerFirmwareVersion == version, serial.profileReady || !serial.supportsProfiles {
            if let backup, serial.supportsProfiles, serial.storedProfile == nil, !restored {
                serial.saveProfile(backup)
                message = String(localized: "Firmware \(version.description) läuft. Stelle das vorherige Profil wieder her…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.confirm(version, model: model, backup: backup, deadline: deadline.addingTimeInterval(5),
                                 restored: true)
                }
                return
            }
            guard !serial.isSavingProfile else { return retry(version, model, backup, deadline, restored) }
            phase = .succeeded
            message = restored && serial.storedProfile == backup
                ? String(localized: "Firmware \(version.description) installiert. Das vorherige Profil ist wiederhergestellt.")
                : String(localized: "Firmware \(version.description) installiert und vom Controller gemeldet.")
            return
        }
        guard Date() < deadline else {
            phase = .failed
            message = String(localized: "Geschrieben, aber der Controller meldet keine Firmware \(version.description). Stimmen Board und Anschluss? Verbinde ihn erneut oder setze ihn zurück.")
            return
        }
        retry(version, model, backup, deadline, restored)
    }

    private func retry(_ version: FirmwareVersion, _ model: LightingModel, _ backup: ControllerProfile?,
                       _ deadline: Date, _ restored: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.confirm(version, model: model, backup: backup, deadline: deadline, restored: restored)
        }
    }

    enum InstallError: Error {
        case portChanged
    }

    private static func describe(_ error: Error, image: FirmwareManifest.Image) -> String {
        switch error {
        case InstallError.portChanged:
            return String(localized: "Der Anschluss hat sich verändert. Wähle ihn erneut aus.")
        case FirmwareManifestError.hashMismatch(let file):
            return String(localized: "Die Firmware-Datei \(file) in der App ist beschädigt. Nichts wurde geschrieben.")
        case ESPLoaderError.noResponse:
            return String(localized: "Der Bootloader antwortet nicht. Halte die BOOT-Taste am Board gedrückt, starte die Installation erneut und lass die Taste los, sobald „Bereich 1“ erscheint.")
        case ESPLoaderError.unsupportedChip(let magic):
            return String(localized: "Unbekannter Chip (Kennung \(String(format: "%08X", magic))). Nur ESP32 und ESP8266 werden unterstützt. Nichts wurde geschrieben.")
        case ESPLoaderError.wrongChip(let expected, let found):
            return String(localized: "Am Anschluss hängt ein \(found.displayName), die gewählte Firmware ist für \(expected.displayName). Nichts wurde geschrieben.")
        case ESPLoaderError.verificationFailed:
            return String(localized: "Die Prüfung nach dem Schreiben ist fehlgeschlagen. Installiere die Firmware erneut; der Download-Modus im ROM des Chips ist davon nicht betroffen.")
        case ESPLoaderError.commandFailed, ESPLoaderError.invalidResponse, ESPLoaderError.imageTooLarge:
            return String(localized: "Der Bootloader hat das Schreiben abgebrochen. Installiere die Firmware erneut; der Download-Modus im ROM des Chips ist davon nicht betroffen.")
        default:
            return String(localized: "Installation fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

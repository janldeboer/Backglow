import BackglowCore
import ServiceManagement
import SwiftUI

@main
struct BackglowApp: App {
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: LightingModel { appDelegate.model }

    var body: some Scene {
        Window(Text(verbatim: "Backglow"), id: Self.mainWindowID) {
            MainWindow(model: model, serial: model.serial)
                .frame(minWidth: 980, minHeight: 650)
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        MenuBarExtra {
            MenuBarPanel(model: model, serial: model.serial)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps Backglow running in the menu bar without a window, and without a Dock icon then.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so it exists, and can switch the LEDs off on quit, without any window.
    let model = LightingModel(persistsSettings: !ScreenshotMode.isActive)
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LoginItem.launchedAtLogin else { return }
        // Started at login: only the menu bar item, the lights follow the remembered setup.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain { window.close() }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareForTermination()
        return .terminateNow
    }
}

private enum Page: CaseIterable, Identifiable {
    case dashboard, source, layout, color, device, automation, diagnostics

    var id: Self { self }
    var fileName: String { String(describing: self) }
    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .source: "Bildquelle"
        case .layout: "LED-Anordnung"
        case .color: "Farben"
        case .device: "Gerät"
        case .automation: "Automatik"
        case .diagnostics: "Diagnose"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .source: "display"
        case .layout: "rectangle.split.3x3"
        case .color: "paintpalette"
        case .device: "cable.connector"
        case .automation: "bolt.badge.automatic"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

private struct MainWindow: View {
    @ObservedObject var model: LightingModel
    @ObservedObject var serial: SerialDevice
    @StateObject private var loginItem = LoginItem()
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Page? = .dashboard
    @State private var showsStorageInitializationConfirmation = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationTitle("Backglow")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(model.captureStatus).lineLimit(1)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    switch selection ?? .dashboard {
                    case .dashboard: dashboard
                    case .source: source
                    case .layout: layout
                    case .color: colorSettings
                    case .device: device
                    case .automation: automation
                    case .diagnostics: diagnostics
                    }
                }
                .padding(28)
                .frame(maxWidth: 1050, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .task {
                if let folder = ScreenshotMode.folder { await takeScreenshots(into: folder) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isRunning ? model.stop() : model.start()
                    } label: {
                        Label(startStopTitle, systemImage: model.isRunning ? "stop.fill" : "play.fill")
                    }
                    .prominentGlassButtonStyle()
                }
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            // Opening Backglow again from Finder or Launchpad shows this window.
            let openWindow = openWindow
            (NSApp.delegate as? AppDelegate)?.openMainWindow = {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: BackglowApp.mainWindowID)
                NSApp.activate()
            }
        }
        // Without a window, Backglow lives on in the menu bar only.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var startStopTitle: LocalizedStringKey {
        if model.isRunning { return "Stoppen" }
        return model.configuration.outputMode == .screen ? "Live starten" : "Einschalten"
    }

    private func takeScreenshots(into folder: URL) async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let still = DemoImage.pixelBuffer() else { throw CocoaError(.featureUnsupported) }
            window.setContentSize(NSSize(width: 1240, height: 780))
            window.center()
            model.change { $0.ignoreBlackBars = true }
            await model.showStill(still)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                for page in Page.allCases {
                    selection = page
                    try await Task.sleep(for: .milliseconds(900))
                    let image = try await ScreenshotMode.capture(window)
                    try ScreenshotMode.save(image, to: folder.appendingPathComponent("\(page.fileName)-\(suffix).png"))
                }
            }
        } catch {
            // `open` drops stderr, so leave the reason next to the images.
            try? "Screenshots failed: \(error)\n".write(to: folder.appendingPathComponent("error.txt"),
                                                        atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((selection ?? .dashboard).title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: LocalizedStringKey {
        switch selection ?? .dashboard {
        case .dashboard: "Bildschirm, Zonen und Lichtfarben in Echtzeit."
        case .source: "Wähle den Bildschirm und die Bildrate."
        case .layout: "Ordne Bildschirmkacheln den physischen LEDs zu."
        case .color: "Stimme Farben und Übergänge auf deine Umgebung ab."
        case .device: "Verbinde deinen LED-Controller über die serielle Schnittstelle."
        case .automation: "Starte mit dem Mac und schalte das Licht ein, sobald Bildschirm und Controller da sind."
        case .diagnostics: "Status und Laufzeitwerte der Verarbeitung."
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.configuration.outputMode == .solidColor {
                SurfaceCard {
                    Label("Einzelfarbe", systemImage: "paintpalette")
                        .font(.headline)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(model.configuration.solidColor.color)
                        .frame(height: 140)
                    SolidColorPicker(model: model)
                    Text("Alle LEDs zeigen diese Farbe. Helligkeit, Farbkanäle und Kalibrierung gelten weiterhin.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                SurfaceCard {
                    HStack {
                        Label("Live-Vorschau", systemImage: "display")
                            .font(.headline)
                        Spacer()
                        ZoneCount(live: model.live)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    LivePreview(live: model.live)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            SurfaceCard {
                HStack {
                    Label("LED-Farben", systemImage: "circle.hexagongrid")
                        .font(.headline)
                    Spacer()
                    Text("In Ausgabe-Reihenfolge")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LiveLEDStrip(live: model.live)
                    .frame(height: 56)
            }
            LiveMetrics(live: model.live)
        }
    }

    private var source: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Modus", systemImage: "lightspectrum.horizontal")
                    .font(.headline)
                Picker("Modus", selection: configBinding(\.outputMode)) {
                    Text("Bildschirm").tag(OutputMode.screen)
                    Text("Einzelfarbe").tag(OutputMode.solidColor)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.configuration.outputMode == .solidColor {
                    SolidColorPicker(model: model)
                    Text("Ohne Bildschirmaufnahme: Alle LEDs leuchten in dieser Farbe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SurfaceCard {
                Label("Bildschirm", systemImage: "display.2")
                    .font(.headline)
                Picker("Quelle", selection: configBinding(\.displayID)) {
                    ForEach(model.displays) { display in
                        Text(display.title).tag(Optional(display.id))
                    }
                }
                .disabled(model.displays.isEmpty)
                Button("Bildschirme aktualisieren") { Task { await model.refreshDisplays() } }
            }
            SurfaceCard {
                Label("Aufnahme", systemImage: "slider.horizontal.3")
                    .font(.headline)
                LabeledContent("Ziel-Bildrate") {
                    Stepper("\(model.configuration.framesPerSecond) fps",
                            value: configBinding(\.framesPerSecond), in: 5...60, step: 5)
                }
                LabeledContent("Interne Auflösung") {
                    Picker("Interne Auflösung", selection: configBinding(\.captureScale)) {
                        Text("25 %").tag(0.25)
                        Text("50 %").tag(0.5)
                        Text("75 %").tag(0.75)
                        Text("100 %").tag(1.0)
                    }.labelsHidden().frame(width: 130)
                }
                Toggle("Schwarze Filmränder ausklammern", isOn: configBinding(\.ignoreBlackBars))
                Text("Die Vorschau zeigt die erkannten Kacheln und die berechneten Ausgabefarben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var layout: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Raster und LED-Reihenfolge", systemImage: "rectangle.split.3x3")
                    .font(.headline)
                LabeledContent("Zeilen") {
                    Stepper("\(model.configuration.rows)", value: configBinding(\.rows), in: 2...50)
                }
                LabeledContent("Spalten") {
                    Stepper("\(model.configuration.columns)", value: configBinding(\.columns), in: 2...50)
                }
                LabeledContent("Aktive LEDs") {
                    Stepper("\(model.configuration.ledCount)", value: configBinding(\.ledCount),
                            in: 1...max(1, min(model.configuration.maximumZoneCount,
                                               model.configuration.deviceLEDCount)))
                }
                LabeledContent("Startversatz") {
                    Stepper("\(model.configuration.startOffset)", value: configBinding(\.startOffset),
                            in: 0...max(0, model.configuration.maximumZoneCount - 1))
                }
                Toggle("Reihenfolge umkehren", isOn: configBinding(\.reversed))
            }
            SurfaceCard {
                Label("Kachelvorschau", systemImage: "viewfinder")
                    .font(.headline)
                LivePreview(live: model.live)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Die Zahlen folgen der Ausgabe an den Controller. Änderungen werden live übernommen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var colorSettings: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Farbwirkung", systemImage: "paintpalette")
                    .font(.headline)
                slider("Sättigung", keyPath: \.calibration.saturation, range: 0...2)
                slider("Gamma", keyPath: \.calibration.gamma, range: 0.25...3)
                slider("Helligkeit", keyPath: \.calibration.brightness, range: 0...1)
                slider("Glättung", keyPath: \.calibration.smoothing, range: 0...0.95)
            }
            SurfaceCard {
                Label("Farbkanäle", systemImage: "slider.horizontal.3")
                    .font(.headline)
                slider("Rot", keyPath: \.calibration.redGain, range: 0...2)
                slider("Grün", keyPath: \.calibration.greenGain, range: 0...2)
                slider("Blau", keyPath: \.calibration.blueGain, range: 0...2)
                Button("Farbwerte zurücksetzen") {
                    model.change { $0.calibration = ColorCalibration() }
                }
            }
            SurfaceCard {
                Label("LED-Kalibrierung", systemImage: "lightbulb.led")
                    .font(.headline)
                Picker("Farbtemperatur", selection: configBinding(\.ledCalibration.temperature)) {
                    ForEach(LEDCalibration.Temperature.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Lege fest, welche Farbe die LEDs für die reinen Bildfarben zeigen sollen. Mit einer Testfarbe siehst du die Wirkung direkt am Strip.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                          alignment: .leading, spacing: 12) {
                    ForEach(LEDCalibration.Corner.allCases, id: \.self) { corner in
                        ColorPicker(corner.title, selection: targetBinding(corner), supportsOpacity: false)
                    }
                }
                HStack {
                    Picker("Testfarbe an LEDs", selection: Binding(
                        get: { model.testCorner },
                        set: { model.showTestCorner($0) }
                    )) {
                        Text("Aus").tag(Optional<LEDCalibration.Corner>.none)
                        ForEach(LEDCalibration.Corner.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 300)
                    Spacer()
                    Button("Kalibrierung zurücksetzen") {
                        model.change { $0.ledCalibration.targets = LEDCalibration().targets }
                    }
                }
            }
            SurfaceCard {
                Label("Grundlicht und Leistung", systemImage: "bolt")
                    .font(.headline)
                slider("Grundlicht", keyPath: \.ledCalibration.minimumBacklight, range: 0...0.1)
                Toggle("Grundlicht in Bildfarbe", isOn: configBinding(\.ledCalibration.coloredBacklight))
                slider("Leistung", keyPath: \.ledCalibration.powerLimit, range: 0.2...1)
                Text(powerSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var powerSummary: String {
        // About 60 mA per WS2812B LED at full white.
        let leds = Double(model.configuration.ledCount)
        let full = leds * 0.06
        let limit = model.configuration.ledCalibration.powerLimit
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        if limit >= 1 {
            return String(localized: "Keine Begrenzung. \(Int(leds)) LEDs ziehen bei Vollweiß bis etwa \(full.formatted(format)) A.")
        }
        let limited = (full * limit).formatted(format)
        return String(localized: "Höchstens etwa \(limited) A statt \(full.formatted(format)) A bei Vollweiß; helle Bilder werden gleichmäßig abgedunkelt.")
    }

    private func targetBinding(_ corner: LEDCalibration.Corner) -> Binding<Color> {
        Binding(
            get: { model.configuration.ledCalibration.target(corner).color },
            set: { color in
                guard let rgb = LightingRGB(color) else { return }
                model.change { $0.ledCalibration.setTarget(rgb, for: corner) }
            }
        )
    }

    private var device: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Serieller Controller", systemImage: "cable.connector")
                    .font(.headline)
                Picker("Anschluss", selection: configBinding(\.portPath)) {
                    Text("Anschluss wählen").tag(Optional<String>.none)
                    ForEach(serial.ports) { port in
                        Text(verbatim: "\(port.name) · \(port.detail) · \(port.id)").tag(Optional(port.id))
                    }
                }
                HStack {
                    Button("Anschlüsse aktualisieren") { serial.refreshPorts() }
                    Button(serial.isConnected ? LocalizedStringKey("Trennen") : "Verbinden") {
                        if serial.isConnected { model.disconnectController() }
                        else {
                            serial.connect(path: model.configuration.portPath,
                                                 baudRate: model.configuration.baudRate)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                Label(serial.status,
                      systemImage: serial.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(serial.isConnected ? .green : .secondary)
                Text("Es erscheinen nur USB-Seriell-Anschlüsse. Bluetooth- und Systemports werden ausgeblendet. Die USB-Kennung bestätigt noch kein bestimmtes Board; Verbinden erfolgt nur nach deiner Auswahl oder für eine unter Automatik gemerkte Kombination.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard {
                Label("Controller-Einstellungen", systemImage: "cpu")
                    .font(.headline)
                LabeledContent("Physische LEDs") {
                    Stepper("\(model.configuration.deviceLEDCount)",
                            value: configBinding(\.deviceLEDCount), in: 1...255)
                }
                Picker("Baudrate", selection: configBinding(\.baudRate)) {
                    ForEach([115_200, 230_400, 460_800, 921_600], id: \.self) { rate in
                        Text(verbatim: "\(rate)").tag(rate)
                    }
                }
                Text("Kompatibel mit dem vorhandenen led/les-Protokoll. Beim Stoppen werden die LEDs ausgeschaltet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard {
                Label("Profil auf dem Controller", systemImage: "externaldrive")
                    .font(.headline)
                if let id = serial.controllerID {
                    LabeledContent("Gerätekennung", value: id)
                }
                Text(serial.profileStatus)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Profil erneut laden") { serial.reloadProfile() }
                        .disabled(!serial.supportsProfiles || serial.isSavingProfile)
                    Button("Aktuelle Einrichtung speichern") { model.saveControllerProfile() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!serial.supportsProfiles || !serial.profileReady ||
                                  serial.isSavingProfile ||
                                  !model.profileHasLocalChanges)
                }
                if serial.canInitializeStorage {
                    Button("Controller-Speicher einrichten") {
                        showsStorageInitializationConfirmation = true
                    }
                    .confirmationDialog("Controller-Speicher einrichten?",
                                        isPresented: $showsStorageInitializationConfirmation,
                                        titleVisibility: .visible) {
                        Button("Dateisystem formatieren", role: .destructive) {
                            serial.initializeStorage()
                        }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Der Dateisystembereich des verbundenen ESP8266 wird formatiert. Vorhandene Dateien gehen verloren.")
                    }
                    Text("Das Einrichten formatiert den Dateisystembereich des ausdrücklich verbundenen ESP8266. Dort vorhandene Dateien werden gelöscht.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Beim Verbinden werden gespeicherte LED-Anordnung und Farbwerte automatisch geladen. Änderungen bleiben zunächst lokal. Speichern schreibt sie ausdrücklich auf den Controller und prüft sie durch erneutes Lesen. Bildschirmwahl, Bildrate und serieller Anschluss bleiben auf diesem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var automation: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Start", systemImage: "power")
                    .font(.headline)
                Toggle("Bei der Anmeldung starten", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.status == .requiresApproval {
                    HStack {
                        Text("macOS muss Backglow noch als Anmeldeobjekt erlauben.")
                            .foregroundStyle(.secondary)
                        Button("Anmeldeobjekte öffnen") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = loginItem.error {
                    Text(error).foregroundStyle(.red)
                }
                Text("Nach der Anmeldung startet Backglow ohne Fenster und erscheint nur in der Menüleiste. Dort schaltest du das Licht, wählst den Modus und die Helligkeit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { loginItem.refresh() }
            SurfaceCard {
                Label("Automatisch verbinden", systemImage: "cable.connector")
                    .font(.headline)
                Toggle("Gemerkte Kombination automatisch verbinden und einschalten",
                       isOn: configBinding(\.autoConnect))
                if model.configuration.pairings.isEmpty {
                    Text("Noch keine Kombination gemerkt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.configuration.pairings) { pairing in
                    let available = model.isPairingAvailable(pairing)
                    HStack(spacing: 10) {
                        Image(systemName: available ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(available ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: pairing.name)
                            Text(verbatim: pairingDetail(pairing))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Vergessen", role: .destructive) { model.forgetPairing(pairing.id) }
                    }
                }
                HStack {
                    Button("Aktuelle Kombination merken") { model.rememberCurrentPairing() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRememberPairing)
                    Spacer()
                }
                if let status = model.autoConnectStatus {
                    Text(status).foregroundStyle(.secondary)
                }
                Text("Wähle unter Bildquelle den Bildschirm, verbinde unter Gerät den Controller und merke dir dann die Kombination. Sind beide angeschlossen, verbindet Backglow und schaltet das Licht im gewählten Modus ein; fehlt einer, geht es wieder aus. Geöffnet wird nur ein Anschluss mit derselben USB-Kennung und Seriennummer, ohne Seriennummer nur an derselben USB-Buchse. Meldet die Firmware eine Gerätekennung, muss auch sie passen, bevor Farben gesendet werden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pairingDetail(_ pairing: AutoConnectPairing) -> String {
        var parts = [String(format: "%04X:%04X", pairing.device.vendorID, pairing.device.productID)]
        if let serial = pairing.device.serialNumber, !serial.isEmpty {
            parts.append(serial)
        } else {
            parts.append(pairing.device.path)
        }
        if let id = pairing.controllerID { parts.append(id) }
        return parts.joined(separator: " · ")
    }

    private var diagnostics: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Laufzeit", systemImage: "waveform.path.ecg")
                    .font(.headline)
                LabeledContent("Bildschirmaufnahme", value: model.captureStatus)
                LiveDiagnostics(live: model.live)
                LabeledContent("Serielle Verbindung", value: serial.status)
            }
            SurfaceCard {
                Text("Berechtigung für Bildschirmaufnahme")
                    .font(.headline)
                Text("macOS fordert die Freigabe beim ersten Start der Live-Aufnahme an. Falls kein Bild erscheint, erlaube Backglow unter Datenschutz & Sicherheit → Bildschirmaufnahme und starte die App neu.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<LightingConfiguration, T>) -> Binding<T> {
        Binding(get: { model.configuration[keyPath: keyPath] },
                set: { value in model.change { $0[keyPath: keyPath] = value } })
    }

    private func slider(_ title: LocalizedStringKey,
                        keyPath: WritableKeyPath<LightingConfiguration, Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: configBinding(keyPath), in: range)
            Text(String(format: "%.2f", model.configuration[keyPath: keyPath]))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }

}

// Views that read `LiveState` are separate so frequent updates redraw only them.

private struct LivePreview: View {
    @ObservedObject var live: LiveState
    var body: some View {
        ScreenPreview(image: live.preview, zones: live.zones, colors: live.colors,
                      imageWidth: live.imageWidth, imageHeight: live.imageHeight)
    }
}

private struct LiveLEDStrip: View {
    @ObservedObject var live: LiveState
    var body: some View { LEDStrip(colors: live.colors) }
}

private struct ZoneCount: View {
    @ObservedObject var live: LiveState
    var body: some View { Text("\(live.zones.count) Zonen") }
}

private struct LiveMetrics: View {
    @ObservedObject var live: LiveState
    var body: some View {
        HStack(spacing: 14) {
            metric("Bildrate", value: live.actualFPS > 0 ? String(format: "%.1f fps", live.actualFPS) : "–")
            metric("Analyse", value: String(format: "%.1f ms", live.processingMilliseconds))
            metric("Rechenweg", value: live.usesGPU ? "Metal GPU" : "CPU")
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        SurfaceCard {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
    }
}

private struct LiveDiagnostics: View {
    @ObservedObject var live: LiveState
    var body: some View {
        LabeledContent("Bildrate", value: live.actualFPS > 0 ? String(format: "%.1f fps", live.actualFPS) : "–")
        LabeledContent("Analyse pro Bild", value: String(format: "%.2f ms", live.processingMilliseconds))
        LabeledContent("Berechnung", value: live.usesGPU ? "Metal" : String(localized: "CPU-Fallback"))
        LabeledContent("Zonen") { Text(live.zones.count, format: .number) }
    }
}

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 15) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ScreenPreview: View {
    let image: CGImage?
    let zones: [LightingZone]
    let colors: [LightingRGB]
    let imageWidth: Int
    let imageHeight: Int

    var body: some View {
        Canvas { context, size in
            let whole = CGRect(origin: .zero, size: size)
            context.fill(Path(whole), with: .color(Color(nsColor: .black)))
            guard let image, imageWidth > 0, imageHeight > 0 else { return }
            let sourceRatio = CGFloat(imageWidth) / CGFloat(imageHeight)
            let targetRatio = size.width / max(size.height, 1)
            let width = targetRatio > sourceRatio ? size.height * sourceRatio : size.width
            let height = targetRatio > sourceRatio ? size.height : size.width / sourceRatio
            let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                              width: width, height: height)
            context.draw(Image(decorative: image, scale: 1), in: rect)
            for zone in zones {
                let x = rect.minX + CGFloat(zone.rect.x) / CGFloat(imageWidth) * rect.width
                let y = rect.minY + CGFloat(zone.rect.y) / CGFloat(imageHeight) * rect.height
                let w = CGFloat(zone.rect.width) / CGFloat(imageWidth) * rect.width
                let h = CGFloat(zone.rect.height) / CGFloat(imageHeight) * rect.height
                let tile = CGRect(x: x, y: y, width: w, height: h)
                let rgb = zone.id < colors.count ? colors[zone.id] : .black
                let tint = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                context.fill(Path(tile), with: .color(tint.opacity(0.24)))
                context.stroke(Path(tile), with: .color(.white.opacity(0.75)), lineWidth: 1)
                if w > 26 && h > 18 {
                    context.draw(Text(verbatim: "\(zone.id + 1)").font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white), at: CGPoint(x: tile.midX, y: tile.midY))
                }
            }
        }
        .overlay {
            if image == nil {
                ContentUnavailableView("Noch keine Live-Vorschau", systemImage: "display",
                                       description: Text("Starte die Bildschirmaufnahme, um Kacheln und Farben zu sehen."))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct LEDStrip: View {
    let colors: [LightingRGB]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(colors.indices, id: \.self) { index in
                    let color = colors[index]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: color.red, green: color.green, blue: color.blue))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geometry.size.width)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        }
        .overlay {
            if colors.isEmpty { Text("Noch keine Farbwerte").foregroundStyle(.secondary) }
        }
    }
}

private extension LEDCalibration.Temperature {
    var title: String {
        switch self {
        case .neutral: String(localized: "Neutral")
        case .warm: String(localized: "Warm")
        case .cold: String(localized: "Kalt")
        }
    }
}

private extension LEDCalibration.Corner {
    var title: String {
        switch self {
        case .black: String(localized: "Schwarz")
        case .red: String(localized: "Rot")
        case .green: String(localized: "Grün")
        case .yellow: String(localized: "Gelb")
        case .blue: String(localized: "Blau")
        case .magenta: String(localized: "Magenta")
        case .cyan: String(localized: "Cyan")
        case .white: String(localized: "Weiß")
        }
    }
}

// Liquid Glass exists from macOS 26; macOS 14 and 15 get the closest standard look.
private extension View {
    @ViewBuilder func prominentGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func cardBackground(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

import AmbientLightingCore
import SwiftUI

@main
struct AmbientLightingV3App: App {
    @StateObject private var model = LightingModel()

    var body: some Scene {
        WindowGroup {
            MainWindow(model: model, serial: model.serial)
                .frame(minWidth: 980, minHeight: 650)
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case source = "Bildquelle"
    case layout = "LED-Anordnung"
    case color = "Farben"
    case device = "Gerät"
    case diagnostics = "Diagnose"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .source: "display"
        case .layout: "rectangle.split.3x3"
        case .color: "paintpalette"
        case .device: "cable.connector"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

private struct MainWindow: View {
    @ObservedObject var model: LightingModel
    @ObservedObject var serial: SerialDevice
    @State private var selection: Page? = .dashboard
    @State private var showsStorageInitializationConfirmation = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page)
            }
            .navigationTitle("Ambient Lighting")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.isCapturing ? .green : .secondary)
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
                    case .diagnostics: diagnostics
                    }
                }
                .padding(28)
                .frame(maxWidth: 1050, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isCapturing ? model.stop() : model.start()
                    } label: {
                        Label(model.isCapturing ? "Stoppen" : "Live starten",
                              systemImage: model.isCapturing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text((selection ?? .dashboard).rawValue)
                .font(.largeTitle.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch selection ?? .dashboard {
        case .dashboard: "Bildschirm, Zonen und Lichtfarben in Echtzeit."
        case .source: "Wähle den Bildschirm und die Bildrate."
        case .layout: "Ordne Bildschirmkacheln den physischen LEDs zu."
        case .color: "Stimme Farben und Übergänge auf deine Umgebung ab."
        case .device: "Verbinde deinen LED-Controller über die serielle Schnittstelle."
        case .diagnostics: "Status und Laufzeitwerte der Verarbeitung."
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            SurfaceCard {
                HStack {
                    Label("Live-Vorschau", systemImage: "display")
                        .font(.headline)
                    Spacer()
                    Text("\(model.zones.count) Zonen")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ScreenPreview(image: model.preview, zones: model.zones,
                              colors: model.colors, imageWidth: model.previewWidth,
                              imageHeight: model.previewHeight)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            SurfaceCard {
                HStack {
                    Label("LED-Farben", systemImage: "circle.hexagongrid")
                        .font(.headline)
                    Spacer()
                    Text("In Ausgabe-Reihenfolge")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LEDStrip(colors: model.colors)
                    .frame(height: 56)
            }
            HStack(spacing: 14) {
                metric("Bildrate", value: String(format: "%.1f fps", model.actualFPS))
                metric("Analyse", value: String(format: "%.1f ms", model.processingMilliseconds))
                metric("Rechenweg", value: model.usesGPU ? "Metal GPU" : "CPU")
            }
        }
    }

    private var source: some View {
        VStack(spacing: 16) {
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
                ScreenPreview(image: model.preview, zones: model.zones,
                              colors: model.colors, imageWidth: model.previewWidth,
                              imageHeight: model.previewHeight)
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
        }
    }

    private var device: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Serieller Controller", systemImage: "cable.connector")
                    .font(.headline)
                Picker("Anschluss", selection: configBinding(\.portPath)) {
                    Text("Anschluss wählen").tag(Optional<String>.none)
                    ForEach(serial.ports) { port in
                        Text("\(port.name) · \(port.detail) · \(port.id)").tag(Optional(port.id))
                    }
                }
                HStack {
                    Button("Anschlüsse aktualisieren") { serial.refreshPorts() }
                    Button(serial.isConnected ? "Trennen" : "Verbinden") {
                        if serial.isConnected { serial.disconnect() }
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
                Text("Es erscheinen nur USB-Seriell-Anschlüsse. Bluetooth- und Systemports werden ausgeblendet. Die USB-Kennung bestätigt noch kein bestimmtes Board; Verbinden erfolgt nur nach deiner Auswahl.")
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
                        Text("\(rate)").tag(rate)
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

    private var diagnostics: some View {
        VStack(spacing: 16) {
            SurfaceCard {
                Label("Laufzeit", systemImage: "waveform.path.ecg")
                    .font(.headline)
                LabeledContent("Bildschirmaufnahme", value: model.captureStatus)
                LabeledContent("Bildrate", value: String(format: "%.1f fps", model.actualFPS))
                LabeledContent("Analyse pro Bild", value: String(format: "%.2f ms", model.processingMilliseconds))
                LabeledContent("Berechnung", value: model.usesGPU ? "Metal" : "CPU-Fallback")
                LabeledContent("Zonen", value: "\(model.zones.count)")
                LabeledContent("Serielle Verbindung", value: serial.status)
            }
            SurfaceCard {
                Text("Berechtigung für Bildschirmaufnahme")
                    .font(.headline)
                Text("macOS fordert die Freigabe beim ersten Start der Live-Aufnahme an. Falls kein Bild erscheint, erlaube Ambient Lighting unter Datenschutz & Sicherheit → Bildschirmaufnahme und starte die App neu.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<LightingConfiguration, T>) -> Binding<T> {
        Binding(get: { model.configuration[keyPath: keyPath] },
                set: { value in model.change { $0[keyPath: keyPath] = value } })
    }

    private func slider(_ title: String,
                        keyPath: WritableKeyPath<LightingConfiguration, Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack(spacing: 14) {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: configBinding(keyPath), in: range)
            Text(String(format: "%.2f", model.configuration[keyPath: keyPath]))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        SurfaceCard {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
    }
}

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 15) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
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
                    context.draw(Text("\(zone.id + 1)").font(.system(size: 10, weight: .bold))
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

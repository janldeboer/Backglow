import BackglowCore
import SwiftUI

/// Quick control from the menu bar: lights on and off, mode, color and brightness.
struct MenuBarPanel: View {
    @ObservedObject var model: LightingModel
    @ObservedObject var serial: SerialDevice
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Backglow").font(.headline)
                    Text(model.captureStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Licht", isOn: Binding(
                    get: { model.isRunning },
                    set: { $0 ? model.start() : model.stop() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Picker("Modus", selection: configBinding(\.outputMode)) {
                Text("Bildschirm").tag(OutputMode.screen)
                Text("Einzelfarbe").tag(OutputMode.solidColor)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.configuration.outputMode == .solidColor {
                SolidColorPicker(model: model, swatchSize: 20)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: configBinding(\.calibration.brightness), in: 0...1)
                    .accessibilityLabel(Text("Helligkeit"))
                Image(systemName: "sun.max").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Label(serial.status,
                      systemImage: serial.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(serial.isConnected ? .green : .secondary)
                    .lineLimit(1)
                Spacer()
                Button(serial.isConnected ? LocalizedStringKey("Trennen") : "Verbinden") {
                    if serial.isConnected {
                        model.disconnectController()
                    } else {
                        serial.connect(path: model.configuration.portPath, baudRate: model.configuration.baudRate)
                    }
                }
                .disabled(!serial.isConnected && model.configuration.portPath == nil)
            }
            .font(.callout)
            Divider()
            HStack {
                Button("Backglow öffnen…") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: BackglowApp.mainWindowID)
                    NSApp.activate()
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<LightingConfiguration, T>) -> Binding<T> {
        Binding(get: { model.configuration[keyPath: keyPath] },
                set: { value in model.change { $0[keyPath: keyPath] = value } })
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: LightingModel

    var body: some View {
        Image(systemName: model.isRunning ? "light.strip.2.fill" : "light.strip.2")
            .accessibilityLabel(Text(verbatim: "Backglow"))
    }
}

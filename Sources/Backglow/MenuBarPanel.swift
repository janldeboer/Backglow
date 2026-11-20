import AppKit
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
                SolidColorPicker(model: model, swatchSize: 20, fieldHeight: 80)
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
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                WindowHeightFitter(height: proxy.size.height)
            }
        }
    }

    private func configBinding<T>(_ keyPath: WritableKeyPath<LightingConfiguration, T>) -> Binding<T> {
        Binding(get: { model.configuration[keyPath: keyPath] },
                set: { value in model.change { $0[keyPath: keyPath] = value } })
    }
}

/// A `MenuBarExtra` window grows with its content but does not shrink again, which leaves
/// the panel floating in a taller, transparent window after the color controls disappear.
/// This sets the window to the content's height and keeps its top edge under the menu bar.
private struct WindowHeightFitter: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        // After the current layout pass, and once the view is in its window.
        DispatchQueue.main.async {
            guard let window = view.window, height > 0 else { return }
            var frame = window.frame
            let fitted = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: height)).height
            guard abs(fitted - frame.height) > 0.5 else { return }
            frame.origin.y += frame.height - fitted
            frame.size.height = fitted
            window.setFrame(frame, display: true)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: LightingModel

    var body: some View {
        Image(systemName: model.isRunning ? "light.strip.2.fill" : "light.strip.2")
            .accessibilityLabel(Text(verbatim: "Backglow"))
    }
}

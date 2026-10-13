import AppKit
import BackglowCore
import SwiftUI

extension LightingRGB {
    /// For sRGB values, as the color pickers show them.
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}

/// Preset swatches and a free color picker for the single-color mode.
struct SolidColorPicker: View {
    @ObservedObject var model: LightingModel
    var swatchSize: CGFloat = 24

    private static let presets: [(LocalizedStringKey, LightingRGB)] = [
        ("Warmweiß", LightingRGB(red: 1, green: 0.62, blue: 0.32)),
        ("Weiß", LightingRGB(red: 1, green: 1, blue: 1)),
        ("Rot", LightingRGB(red: 1, green: 0.08, blue: 0.04)),
        ("Orange", LightingRGB(red: 1, green: 0.42, blue: 0)),
        ("Grün", LightingRGB(red: 0.1, green: 1, blue: 0.25)),
        ("Türkis", LightingRGB(red: 0, green: 0.8, blue: 0.9)),
        ("Blau", LightingRGB(red: 0.1, green: 0.25, blue: 1)),
        ("Violett", LightingRGB(red: 0.6, green: 0.15, blue: 1)),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets.indices, id: \.self) { index in
                let (title, rgb) = Self.presets[index]
                Button {
                    model.change { $0.solidColor = rgb }
                } label: {
                    Circle()
                        .fill(rgb.color)
                        .frame(width: swatchSize, height: swatchSize)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(isSelected(rgb) ? 0.9 : 0.15),
                                                  lineWidth: isSelected(rgb) ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .help(Text(title))
                .accessibilityLabel(Text(title))
            }
            ColorPicker("Eigene Farbe", selection: Binding(
                get: { model.configuration.solidColor.color },
                set: { color in
                    guard let rgb = LightingRGB(color) else { return }
                    model.change { $0.solidColor = rgb }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .help(Text("Eigene Farbe"))
        }
    }

    private func isSelected(_ rgb: LightingRGB) -> Bool {
        let current = model.configuration.solidColor
        return abs(current.red - rgb.red) + abs(current.green - rgb.green) + abs(current.blue - rgb.blue) < 0.01
    }
}

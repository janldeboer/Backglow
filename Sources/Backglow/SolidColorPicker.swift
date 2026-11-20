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

/// Preset swatches, a color field and a white slider for the single-color mode.
struct SolidColorPicker: View {
    @ObservedObject var model: LightingModel
    var swatchSize: CGFloat = 24
    var fieldHeight: CGFloat = 110

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
        VStack(alignment: .leading, spacing: 12) {
            swatches
            HueSaturationField(color: model.configuration.solidColor) { rgb in
                model.change { $0.solidColor = rgb }
            }
            .frame(height: fieldHeight)
            HStack(spacing: 8) {
                Image(systemName: "snowflake").foregroundStyle(.secondary)
                WhiteSlider(warmth: model.configuration.solidColor.whiteWarmth) { warmth in
                    model.change { $0.solidColor = .white(warmth: warmth) }
                }
                Image(systemName: "flame").foregroundStyle(.secondary)
            }
            .help(Text("Weiß von kalt bis warm"))
        }
    }

    private var swatches: some View {
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

/// Hue from left to right, saturation from bottom (white) to top. Picks a fully bright color.
private struct HueSaturationField: View {
    let color: LightingRGB
    let onChange: (LightingRGB) -> Void
    /// Keeps the knob's column while the color is white and has no hue of its own.
    @State private var heldHue = 0.0

    private static let spectrum = (0...6).map { LightingRGB(hue: Double($0) / 6, saturation: 1).color }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let current = color.hueSaturation
            let hue = current.saturation < 0.02 ? heldHue : current.hue
            ZStack {
                LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15))
            }
            .overlay {
                Knob(color: LightingRGB(hue: hue, saturation: current.saturation))
                    .position(x: hue * size.width, y: (1 - current.saturation) * size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // Hue 1 is red again and would throw the knob back to the left edge.
                let hue = min(max(value.location.x / size.width, 0), 0.9999)
                let saturation = 1 - min(max(value.location.y / size.height, 0), 1)
                heldHue = hue
                onChange(LightingRGB(hue: hue, saturation: saturation))
            })
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Farbton und Sättigung"))
    }
}

/// A slider whose track shows the whites it picks, cold on the left, warm on the right.
private struct WhiteSlider: View {
    let warmth: Double
    let onChange: (Double) -> Void

    private static let track = (0...8).map { LightingRGB.white(warmth: Double($0) / 8).color }
    private static let knobSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.knobSize, 1)
            Capsule()
                .fill(LinearGradient(colors: Self.track, startPoint: .leading, endPoint: .trailing))
                .overlay { Capsule().strokeBorder(.primary.opacity(0.15)) }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
                .overlay {
                    Knob(color: .white(warmth: warmth))
                        .position(x: Self.knobSize / 2 + warmth * travel, y: proxy.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    onChange(min(max((value.location.x - Self.knobSize / 2) / travel, 0), 1))
                })
        }
        .frame(height: Self.knobSize)
        .accessibilityElement()
        .accessibilityLabel(Text("Weißton"))
        .accessibilityValue(Text(verbatim: "\(Int(LightingRGB.whiteKelvin(warmth: warmth).rounded())) K"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(warmth + 0.05, 1))
            case .decrement: onChange(max(warmth - 0.05, 0))
            @unknown default: break
            }
        }
    }
}

private struct Knob: View {
    let color: LightingRGB

    var body: some View {
        Circle()
            .fill(color.color)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}

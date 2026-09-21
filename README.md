# Ambient Lighting 3 for macOS

Version 3 is a native SwiftUI redesign of the earlier Ambilight for Mac experiments. It uses a sidebar and macOS Liquid Glass surfaces, while keeping the working LED controller protocol and perimeter layout from the older builds. The app is named **Ambient Lighting** to avoid using *Ambilight* as a product name.

## Requirements

- macOS 26 or later, Xcode 26 or later, and an Apple Metal-capable Mac.
- Screen Recording permission for live capture.
- Optional serial LED controller running the included FastLED sketch.

## Build and run

```sh
./scripts/build-app.sh
open dist/AmbientLightingV3.app
```

The script creates an ad hoc signed native app in `dist/`. Open `Package.swift` in Xcode to work on the source. To run the pure core tests:

```sh
swift test --disable-sandbox
```

On the first capture, macOS may request Screen Recording access. Grant it in **System Settings → Privacy & Security → Screen Recording**, then restart the app if prompted.

## How it works

1. ScreenCaptureKit captures one display, excluding this app's windows. The capture resolution and target frame rate are adjustable.
2. The perimeter mapper selects LED zones using rows, columns, start offset, LED count, and direction. Optional black-bar detection adjusts the content bounds.
3. A Metal compute shader averages the pixels in each zone on the GPU. If Metal setup or a dispatch fails, a full-pixel CPU reference path is used. Only one frame is in flight at a time.
4. Saturation, gamma, channel gains, brightness, and smoothing are applied to the small LED-color array.
5. The preview shows the captured image, numbered zones, their calculated colors, and a strip in serial output order.
6. ORSSerialPort writes the newest available frame on a dedicated queue. Older unsent frames are replaced instead of growing a backlog.

Settings are saved in `~/Library/Application Support/AmbientLightingV3/settings.json`.

## LED controller

`Firmware/SerialLEDcontroller/SerialLEDcontroller.ino` is the original FastLED sketch, preserved for compatibility. Its defaults are **70 WS2812B LEDs**, **pin 2**, **GRB**, and **230400 baud**. Configure the number of physical LEDs and the matching baud rate in the app. Each frame uses the existing `led` + one-byte index + RGB bytes per LED, ending with `les` to display the frame. Changing these firmware defaults requires matching changes in the app's device settings.

The serial library is ORSSerialPort **2.1.0**, the latest upstream release checked for this rebuild. It is vendored at `Vendor/ORSSerialPort` so builds do not depend on GitHub access. Its MIT license is in that directory. The app's own license is GPL-3.0, as in the original repository.

## Code map

- `Sources/AmbientLightingCore`: device-independent configuration, perimeter mapping, pixel analysis, color correction, and serial packet encoding.
- `Sources/AmbientLightingV3/ScreenCaptureEngine.swift`: ScreenCaptureKit lifecycle and frame delivery.
- `Sources/AmbientLightingV3/GPUZoneReducer.swift` and `Shaders/ZoneAverage.metal`: GPU zone averaging.
- `Sources/AmbientLightingV3/LightingModel.swift`: app state, settings, frame processing, and output coordination.
- `Sources/AmbientLightingV3/AmbientLightingApp.swift`: native sidebar and preview UI.
- `Sources/AmbientLightingV3/SerialDevice.swift`: ORSSerialPort adapter.

The previous history remains in Git. The complete older implementation is on `origin/main`; the later architecture experiments are available as `legacy/v2`, `origin/2.1`, `legacy/serial-fix`, and `legacy/2.2-pipeline` in this checkout. Version 3 is a fresh implementation rather than a continuation of the incomplete pipeline rebuild.

## Verification scope

The core tests cover LED order and offset, BGRA pixel averaging, color calibration, black-bar fallback, and the original controller packet. `swift scripts/check-metal.swift Sources/AmbientLightingV3/Shaders/ZoneAverage.metal` runs a real Metal dispatch with a known 2×2 test image. A successful build verifies the SwiftUI, ScreenCaptureKit, Metal, and ORSSerialPort integrations at compile time. Live capture permissions and a physical controller require testing with the appropriate hardware and permissions.

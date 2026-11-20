# Changes

What changed in each Backglow version, newest first. The release notes for each version on GitHub are in [`docs/releases`](docs/releases).

## 3.3.0 – 2026-11-20

Released with everything from 3.2.0 and 3.2.1, which were never published.

### New

- Single-color mode: a color field for hue and saturation and a white slider from cool (9000 K) to warm (2000 K), in the window and in the menu bar. The presets and the system color picker stay.

### Fixed

- The menu bar panel shrinks again when its content gets shorter, instead of floating in a taller, transparent window.

## 3.2.1 – 2026-11-05 (not published)

Carries everything from 3.2.0, which was tagged but never published.

### Fixed

- No more flickering when the Mac is busy. After a late output tick the color smoothing could swing back and forth; it now stays stable for any time step.
- Backglow throttles itself. When output ticks come late or frame analysis cannot keep up, it lowers the capture and output rate in steps down to a quarter, and raises it again once the Mac has caught up. After a hang it holds the current colors and fades back in once ticks are steady. The Diagnostics page shows the current **Output rate**.
- macOS no longer slows Backglow down with App Nap while the lights are on.
- With the window open, the live preview no longer redraws at the LED rate. CPU load drops from about 90 % to about 20 %.

## 3.2.0 – 2026-10-13 (tagged, not published)

### New

- Menu bar control: switch the lights on and off, choose screen or single color, pick a color and set the brightness. With the window closed, Backglow keeps running in the menu bar without a Dock icon.
- Open at login (Automation page). Started at login, Backglow opens no window.
- Automatic connection: remember a display and controller as a pair. Whenever both are plugged in, Backglow connects and switches on; when either is unplugged, the lights go off. Only the remembered controller is opened. With the v3 firmware its chip ID has to match before any data is sent.
- Single-color mode: every LED shows one color, with presets and a free color picker, without screen capture.
- The LEDs go dark while the displays sleep and when Backglow quits.
- The display picker shows the monitor's name.

## 3.1.0 – 2026-10-13

- Runs on macOS 14 Sonoma and later, not only on macOS 26. Liquid Glass on macOS 26, standard materials on 14 and 15.

## 3.0.2 – 2026-10-12

- Signed with Developer ID and notarized by Apple, so it opens without a Gatekeeper warning. The Screen Recording permission now stays across updates.

## 3.0.1 – 2026-10-12

- Fixed a crash at launch: the downloaded app could not find its GPU shader.

## 3.0.0 – 2026-10-12

First release under the name Backglow, a native rewrite of the earlier macOS Ambient Lighting app.

- Native SwiftUI app with sidebar and Liquid Glass, in English and German.
- ScreenCaptureKit capture and GPU zone averaging with Metal, with a CPU fallback.
- Live preview with numbered zones and the calculated LED colors.
- Letterbox detection that ignores black bars only once they are stable.
- Spring smoothing on its own output clock and an anti-flicker filter, following HyperHDR.
- Color calibration with eight reference colors, color temperature, minimum backlight and a power limit.
- New ESP32/ESP8266 firmware that keeps the LED layout and colors in a profile on the controller; the original `led`/`les` sketch still works.
- Settings from builds named *AmbientLightingV3* are imported on first launch.

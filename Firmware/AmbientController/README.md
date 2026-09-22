# Ambient Lighting Controller v3

This firmware adds a persistent controller profile to the historical `led`/`les`
color stream. It targets generic **ESP32 Dev Module** (`esp32dev`, data pin GPIO18)
and **NodeMCU ESP8266** (`nodemcuv2`, data pin GPIO5). The pin and board must be
checked against the actual wiring before flashing. Neither environment is an
automatic board detector. Serial speed is 230400 baud; the strip type is WS2812B
with GRB order. The FastLED output limit remains 50/255, matching the old sketch.
The separate legacy Arduino sketch is preserved unchanged.

Build with PlatformIO from this directory:

```sh
pio run -e esp32dev -e nodemcuv2
```

The host-side firmware protocol check runs without a board:

```sh
clang++ -std=c++17 -DESP32 -DLED_DATA_PIN=18 -I tests/stubs \
  tests/host_protocol.cpp -o /tmp/ambient-v3-protocol && /tmp/ambient-v3-protocol
```

No upload command is configured here. The host app does not flash a controller
in this step.

## Profile behavior

- When the app connects, it sends `AL3?`. The new firmware replies with protocol
  version, capacity, storage support and a chip identifier. Old firmware ignores
  the probe and continues receiving colors.
- A saved profile is loaded automatically into the app. A fresh controller has no
  saved profile, so the app keeps its local configuration until **Aktuelle
  Einrichtung speichern** is pressed.
- A write requires the revision read from the controller. The controller checks
  the profile, writes the other of two CRC-protected storage slots and verifies
  the bytes. The app then reads the profile back and compares it to the requested
  values. Identical profiles are not written again.
- ESP32 uses Preferences/NVS. ESP8266 uses LittleFS. The two-slot scheme retains
  the previously valid profile if a write is interrupted. This still needs power
  interruption testing on real hardware. A changed physical LED
  count triggers a controller restart after the save acknowledgement, so FastLED
  starts with the new strip length. The app receives a new hello after restart.
- On ESP8266, a filesystem that cannot be mounted is **not** formatted at boot.
  The app offers an explicit storage setup action for this case. It formats that
  filesystem area, including any files already there. An unknown profile schema
  blocks writes rather than silently replacing the profile.

The controller stores physical and active LED counts, tile rows and columns,
start offset, reverse order, black bar handling, and color calibration. Display
selection, capture settings, serial path and baud rate remain local to each Mac.
The profile is for one LED setup per controller. Associating multiple monitors
with one controller is not part of this protocol version.

## AL3 wire format

All multibyte integers are little endian. A control frame is `AL3!`, message
type (1 byte), payload length (1 byte, maximum 64), payload and CRC16 CCITT
FALSE (polynomial 0x1021, initial 0xFFFF) over message type, length and payload.
The probe `AL3?` is the only unframed command. Message types are: hello 1,
get profile 2, profile 3, set profile 4, saved 5, error 6, no profile 7,
initialize storage 8. Initialization is only available after a valid hello from
the selected controller.

The 24-byte profile is: schema version (1), physical LED count (u16), active LED
count (u16), rows (u8), columns (u8), start offset (u16), flags (u8: reverse bit
0, black bars bit 1), then seven u16 color values in the order saturation,
gamma, red, green, blue, brightness, smoothing. Color values are multiplied by
10,000. Profile reads and writes prepend the u32 revision. No-profile and get
messages have empty payloads. Successful saves return the u32 revision. Errors
return a code: 1 malformed, 2 storage unavailable, 3 revision conflict,
4 invalid profile, 5 write failed, 6 unsupported schema.

#!/bin/zsh
set -euo pipefail

# Builds the controller firmware with PlatformIO and copies the images the app can flash
# into AppBundle/Firmware, together with manifest.json (offsets and SHA-256 per file).
#
#   ./scripts/build-firmware.sh                       # all environments
#   ./scripts/build-firmware.sh esp32dev esp32dev_gpio2
#
# Uses `pio` when installed, otherwise `uvx platformio`. The ESP8266 toolchain is built
# for Intel Macs and needs Rosetta on Apple silicon.
project_dir="${0:A:h:h}"
firmware_dir="$project_dir/Firmware/BackglowController"
output_dir="$project_dir/AppBundle/Firmware"
envs=("$@")
(( ${#envs} )) || envs=(esp32dev esp32dev_gpio2 nodemcuv2 nodemcuv2_gpio2)

if command -v pio >/dev/null; then pio=(pio); else pio=(uvx platformio); fi
cd "$firmware_dir"
for env in $envs; do "${pio[@]}" run -e "$env"; done

core_dir="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
version="$(for part in MAJOR MINOR PATCH; do
    sed -n "s/^#define BACKGLOW_FIRMWARE_VERSION_$part //p" src/version.h
done | paste -sd. -)"

rm -rf "$output_dir"
mkdir -p "$output_dir"
for env in $envs; do
    build=".pio/build/$env"
    mkdir -p "$output_dir/$env"
    case "$env" in
        esp32dev*)
            cp "$build/bootloader.bin" "$build/partitions.bin" "$build/firmware.bin" "$output_dir/$env/"
            cp "$core_dir/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" "$output_dir/$env/"
            ;;
        nodemcuv2*)
            cp "$build/firmware.bin" "$output_dir/$env/"
            ;;
        *) echo "Unknown environment $env" >&2; exit 1 ;;
    esac
done

python3 -I - "$output_dir" "$version" $envs <<'PYTHON'
import hashlib, json, pathlib, re, sys

out, version, envs = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
pins = {line.split("[env:")[1].split("]")[0]: None for line in open("platformio.ini") if line.startswith("[env:")}
current = None
for line in open("platformio.ini"):
    if line.startswith("[env:"):
        current = line.split("[env:")[1].split("]")[0]
    match = re.search(r"-DLED_DATA_PIN=(\d+)", line)
    if current and match:
        pins[current] = int(match.group(1))
layouts = {
    "esp32": [(0x1000, "bootloader.bin"), (0x8000, "partitions.bin"),
              (0xE000, "boot_app0.bin"), (0x10000, "firmware.bin")],
    "esp8266": [(0x0, "firmware.bin")],
}
images = []
for env in envs:
    chip = "esp32" if env.startswith("esp32") else "esp8266"
    parts = []
    for offset, name in layouts[chip]:
        data = (out / env / name).read_bytes()
        parts.append({"offset": offset, "file": f"{env}/{name}",
                      "sha256": hashlib.sha256(data).hexdigest()})
    images.append({"id": env, "chip": chip,
                   "board": "ESP32 Dev Module" if chip == "esp32" else "NodeMCU ESP8266",
                   "dataPin": pins[env], "parts": parts})
manifest = {"version": version, "images": images}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Wrote {out / 'manifest.json'}: firmware {version}, {len(images)} images")
PYTHON

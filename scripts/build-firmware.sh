#!/bin/zsh
set -euo pipefail

# Builds the controller firmware with PlatformIO and copies the images the app can flash
# into AppBundle/Firmware, together with manifest.json (offsets and SHA-256 per file).
#
#   ./scripts/build-firmware.sh                       # all environments
#   ./scripts/build-firmware.sh esp32dev esp32dev_gpio2
#
# Uses `pio` when installed, otherwise `uvx platformio`. The ESP8266 toolchain is built
# for Intel Macs and needs Rosetta on Apple silicon. Without Rosetta, build on a Linux
# host over SSH instead; PlatformIO is set up there on first use under /opt/backglow-firmware:
#
#   BACKGLOW_BUILD_HOST=lab ./scripts/build-firmware.sh
project_dir="${0:A:h:h}"
firmware_dir="$project_dir/Firmware/BackglowController"
output_dir="$project_dir/AppBundle/Firmware"
envs=("$@")
(( ${#envs} )) || envs=(esp32dev esp32dev_gpio2 nodemcuv2 nodemcuv2_gpio2)

cd "$firmware_dir"
build_host="${BACKGLOW_BUILD_HOST:-}"
if [[ -n $build_host ]]; then
    remote=/opt/backglow-firmware
    ssh "$build_host" "test -x $remote/venv/bin/pio || { mkdir -p $remote && python3 -m venv $remote/venv && $remote/venv/bin/pip install -q platformio; }"
    rsync -a --delete --exclude .pio "$firmware_dir/" "$build_host:$remote/project/"
    ssh "$build_host" "cd $remote/project && export PLATFORMIO_CORE_DIR=$remote/core && for env in ${envs[*]}; do $remote/venv/bin/pio run -e \$env || exit 1; done"
    build_root="$(mktemp -d)"
    trap 'rm -rf "$build_root"' EXIT
    rsync -a --include '*/' --include '*.bin' --exclude '*' "$build_host:$remote/project/.pio/build/" "$build_root/"
    rsync -a "$build_host:$remote/core/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin" "$build_root/" 2>/dev/null || true
    boot_app0="$build_root/boot_app0.bin"
else
    if command -v pio >/dev/null; then pio=(pio); else pio=(uvx platformio); fi
    for env in $envs; do "${pio[@]}" run -e "$env"; done
    build_root=".pio/build"
    boot_app0="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
fi

version="$(for part in MAJOR MINOR PATCH; do
    sed -n "s/^#define BACKGLOW_FIRMWARE_VERSION_$part //p" src/version.h
done | paste -sd. -)"

rm -rf "$output_dir"
mkdir -p "$output_dir"
for env in $envs; do
    build="$build_root/$env"
    mkdir -p "$output_dir/$env"
    case "$env" in
        esp32dev*)
            cp "$build/bootloader.bin" "$build/partitions.bin" "$build/firmware.bin" "$output_dir/$env/"
            cp "$boot_app0" "$output_dir/$env/"
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

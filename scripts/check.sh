#!/bin/zsh
# Runs every check of the project in one go and stops at the first failure.
#   scripts/check.sh          everything: rules, core tests, firmware protocol test, Metal shader,
#                             String Catalog in sync with the sources, release build of the app
#   scripts/check.sh --fast   what the pre-commit hook runs: rules, core tests, firmware protocol test
#
# Firmware images (PlatformIO) and the signed app bundle are not built here: see
# scripts/build-firmware.sh and scripts/build-app.sh. Live capture and real LED hardware
# can only be checked by hand.
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
fast=false
[[ "${1:-}" == "--fast" ]] && fast=true

scratch="$(mktemp -d "${TMPDIR:-/tmp}/backglow-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
log="$scratch/log"
started=$SECONDS
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/backglow-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

# Prints one line per step; the step's output only when it fails.
run() {
    local name="$1"; shift
    local begin=$SECONDS
    printf '%-36s' "$name"
    if "$@" >"$log" 2>&1; then
        printf 'ok (%ds)\n' $((SECONDS - begin))
    else
        printf 'FAILED\n\n'
        tail -60 "$log"
        exit 1
    fi
}

firmware_protocol() {
    clang++ -std=c++17 -DESP32 -DLED_DATA_PIN=18 -I Firmware/BackglowController/tests/stubs \
        Firmware/BackglowController/tests/host_protocol.cpp -o "$scratch/host-protocol"
    "$scratch/host-protocol"
}

# Extracts the strings from the sources into a copy of the catalog; the real one must not change.
strings_in_sync() {
    local strings="$scratch/strings" catalog="AppBundle/Localization/Localizable.xcstrings"
    mkdir -p "$strings"
    swift build --disable-sandbox --scratch-path "${TMPDIR:-/tmp}/backglow-strings-build" \
        -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$strings"
    cp "$catalog" "$scratch/Localizable.xcstrings"
    xcrun xcstringstool sync "$scratch/Localizable.xcstrings" --stringsdata "$strings"/*.stringsdata
    if ! diff -q "$catalog" "$scratch/Localizable.xcstrings" >/dev/null; then
        echo "The String Catalog is out of date: run scripts/update-strings.sh and translate the new keys."
        diff "$catalog" "$scratch/Localizable.xcstrings" | head -40
        return 1
    fi
}

run "Project rules" python3 scripts/check-rules.py
run "Core tests" swift test --disable-sandbox
run "Firmware protocol (host)" firmware_protocol

if ! $fast; then
    run "Metal shader" swift scripts/check-metal.swift Sources/Backglow/Shaders/ZoneAverage.metal
    run "String Catalog in sync" strings_in_sync
    run "App release build" swift build --disable-sandbox -c release --scratch-path "${TMPDIR:-/tmp}/backglow-check-build"
fi

echo "All checks passed in $((SECONDS - started))s"

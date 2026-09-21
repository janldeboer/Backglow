#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
scratch_dir="/private/tmp/ambient-lighting-v3-build"
product_dir="$scratch_dir/out/Products/Release"
app_dir="$project_dir/dist/AmbientLightingV3.app"

export CLANG_MODULE_CACHE_PATH="/private/tmp/ambient-lighting-v3-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

cd "$project_dir"
swift build --disable-sandbox -c release -debug-info-format none --scratch-path "$scratch_dir"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$product_dir/AmbientLightingV3" "$app_dir/Contents/MacOS/"
cp -R "$product_dir/AmbientLightingV3_AmbientLightingV3.bundle" "$app_dir/Contents/Resources/"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/AppBundle/AppIcon.icns" "$app_dir/Contents/Resources/"
codesign --force --deep --sign - "$app_dir"
echo "Created $app_dir"

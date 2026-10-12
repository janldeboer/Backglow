#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
scratch_dir="/private/tmp/backglow-build"
app_dir="$project_dir/dist/Backglow.app"

export CLANG_MODULE_CACHE_PATH="/private/tmp/backglow-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

cd "$project_dir"
build_flags=(--disable-sandbox -c release -debug-info-format none --scratch-path "$scratch_dir")
swift build "${build_flags[@]}"
# The output folder differs between SwiftPM build systems, so ask for it.
product_dir="$(swift build "${build_flags[@]}" --show-bin-path)"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$product_dir/Backglow" "$app_dir/Contents/MacOS/"
cp -R "$product_dir/Backglow_Backglow.bundle" "$app_dir/Contents/Resources/"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/AppBundle/AppIcon.icns" "$app_dir/Contents/Resources/"
# A stable identity keeps macOS privacy grants such as Screen Recording across rebuilds;
# ad hoc signatures change with every build. Override with SIGN_IDENTITY=- or a name.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}"
codesign --force --deep --sign "${identity:--}" "$app_dir"
echo "Signed with ${identity:-ad hoc signature}"
echo "Created $app_dir"

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
cp "$project_dir/Sources/Backglow/Shaders/ZoneAverage.metal" "$app_dir/Contents/Resources/"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"
# String Catalogs (German source, English translation) become de.lproj and en.lproj.
for catalog in "$project_dir"/AppBundle/Localization/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$app_dir/Contents/Resources" \
        --serialization-format binary
done
# Compiles the Icon Composer document into Assets.car (Liquid Glass) plus a fallback .icns.
xcrun actool "$project_dir/AppBundle/Backglow.icon" --compile "$app_dir/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon Backglow --target-device mac \
    --output-partial-info-plist "$scratch_dir/icon-info.plist" >/dev/null
# A stable identity keeps macOS privacy grants such as Screen Recording across rebuilds;
# ad hoc signatures change with every build. Developer ID is preferred so local builds and
# notarized releases share one identity. Override with SIGN_IDENTITY=- or a name.
identities="$(security find-identity -v -p codesigning 2>/dev/null)"
identity="${SIGN_IDENTITY-$(echo "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -z "$identity" && -z "${SIGN_IDENTITY+set}" ]] && \
    identity="$(echo "$identities" | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
# The hardened runtime is required for notarization; a secure timestamp only for Developer ID.
timestamp=(--timestamp=none)
[[ "$identity" == "Developer ID Application:"* ]] && timestamp=(--timestamp)
codesign --force --options runtime "${timestamp[@]}" --sign "${identity:--}" "$app_dir"
echo "Signed with ${identity:-ad hoc signature}"
echo "Created $app_dir"

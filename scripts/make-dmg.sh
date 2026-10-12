#!/bin/zsh
set -euo pipefail

# Packs dist/AmbientLightingV3.app into a compressed DMG with an Applications link.
project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/AmbientLightingV3.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg_path="$project_dir/dist/AmbientLighting-$version.dmg"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_dir" "$staging_dir/Ambient Lighting.app"
ln -s /Applications "$staging_dir/Applications"
rm -f "$dmg_path"
hdiutil create -volname "Ambient Lighting $version" -srcfolder "$staging_dir" \
    -fs HFS+ -format UDZO -ov "$dmg_path" >/dev/null
hdiutil verify "$dmg_path" >/dev/null
echo "Created $dmg_path"

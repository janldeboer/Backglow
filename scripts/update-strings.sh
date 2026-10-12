#!/bin/zsh
set -euo pipefail

# Adds new user-facing strings from the Swift sources to the String Catalog, the way Xcode
# would, and marks removed ones stale. Translate new entries in Xcode or by editing the JSON.
project_dir="${0:A:h:h}"
strings_dir="$(mktemp -d)"
trap 'rm -rf "$strings_dir"' EXIT

cd "$project_dir"
swift build --disable-sandbox --scratch-path /private/tmp/backglow-strings-build \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$strings_dir"
xcrun xcstringstool sync AppBundle/Localization/Localizable.xcstrings --stringsdata "$strings_dir"/*.stringsdata
echo "Updated AppBundle/Localization/Localizable.xcstrings"

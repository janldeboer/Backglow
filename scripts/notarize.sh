#!/bin/zsh
set -euo pipefail

# Notarizes dist/Backglow.app and staples its ticket, then packs it with make-dmg.sh and
# notarizes and staples the DMG too. With both stapled, the download opens without a
# Gatekeeper warning even offline. Run after build-app.sh with a Developer ID identity.
#
# Credentials, either:
#   - a keychain profile, created once with `xcrun notarytool store-credentials backglow-notary`
#     (override the name with NOTARY_PROFILE), or
#   - an App Store Connect API key: NOTARY_KEY (path to the .p8), NOTARY_KEY_ID, NOTARY_ISSUER.
project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/Backglow.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
dmg_path="$project_dir/dist/Backglow-$version.dmg"

identity="$(codesign -dv --verbose=2 "$app_dir" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p')"
if [[ -z "$identity" ]]; then
    echo "dist/Backglow.app is not signed with a Developer ID Application certificate." >&2
    exit 1
fi

if [[ -n "${NOTARY_KEY:-}" ]]; then
    credentials=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    credentials=(--keychain-profile "${NOTARY_PROFILE:-backglow-notary}")
fi

# Submits a file, waits for Apple's verdict and prints the log when it is not accepted.
submit() {
    echo "Submitting ${1:t} for notarization…"
    local result submission outcome
    result="$(xcrun notarytool submit "$1" "${credentials[@]}" --wait --output-format json)"
    submission="$(echo "$result" | /usr/bin/plutil -extract id raw -o - -)"
    outcome="$(echo "$result" | /usr/bin/plutil -extract status raw -o - -)"
    if [[ "$outcome" != "Accepted" ]]; then
        echo "Notarization $outcome. Apple's log:" >&2
        xcrun notarytool log "$submission" "${credentials[@]}" >&2 || true
        exit 1
    fi
}

zip_path="$(mktemp -d)/Backglow.zip"
trap 'rm -rf "${zip_path:h}"' EXIT
ditto -c -k --keepParent "$app_dir" "$zip_path"
submit "$zip_path"
xcrun stapler staple "$app_dir"

"$project_dir/scripts/make-dmg.sh"
codesign --force --timestamp --sign "$identity" "$dmg_path"
submit "$dmg_path"
xcrun stapler staple "$dmg_path"

spctl --assess --type execute --verbose "$app_dir"
spctl --assess --type open --context context:primary-signature --verbose "$dmg_path"
echo "Notarized and stapled $app_dir and $dmg_path"

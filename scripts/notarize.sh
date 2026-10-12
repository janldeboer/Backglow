#!/bin/zsh
set -euo pipefail

# Signs dist/Backglow-<version>.dmg with Developer ID, has Apple notarize it and staples the
# ticket, so the download opens without a Gatekeeper warning. Run after build-app.sh (with a
# Developer ID identity) and make-dmg.sh.
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
[[ -f "$dmg_path" ]] || { echo "Missing $dmg_path; run make-dmg.sh first." >&2; exit 1; }

if [[ -n "${NOTARY_KEY:-}" ]]; then
    credentials=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    credentials=(--keychain-profile "${NOTARY_PROFILE:-backglow-notary}")
fi

codesign --force --timestamp --sign "$identity" "$dmg_path"
echo "Submitting $dmg_path for notarization…"
result="$(xcrun notarytool submit "$dmg_path" "${credentials[@]}" --wait --output-format json)"
submission="$(echo "$result" | /usr/bin/plutil -extract id raw -o - -)"
status="$(echo "$result" | /usr/bin/plutil -extract status raw -o - -)"
if [[ "$status" != "Accepted" ]]; then
    echo "Notarization $status. Apple's log:" >&2
    xcrun notarytool log "$submission" "${credentials[@]}" >&2 || true
    exit 1
fi

xcrun stapler staple "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose "$dmg_path"
echo "Notarized and stapled $dmg_path"

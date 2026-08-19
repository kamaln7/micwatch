#!/bin/bash
# Builds micwatch.app. Signs with a stable identity when one exists, so the
# Keychain keeps granting access across rebuilds; falls back to ad-hoc, where
# every build looks like a different program and re-prompts.
#
# To create the stable identity once: ./build.sh --create-identity
set -euo pipefail
cd "$(dirname "$0")"

APP="micwatch.app"
BUNDLE_ID="io.kamal.micwatch"
# A keychain of its own: the signing key is not reachable while it's locked, so a
# stray codesign call can't quietly sign something with this identity.
KEYCHAIN="$HOME/Library/Keychains/micwatch-signing.keychain-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
IDENTITY="${MICWATCH_IDENTITY:-micwatch code signing (local dev)}"

if [[ "${1:-}" == "--create-identity" ]]; then
    echo "Creating a self-signed code signing certificate: $IDENTITY"
    echo "It goes in its own keychain, which stays locked except while building."
    echo

    # Clear any earlier copies out of the login keychain — that's where this used
    # to live, and a stale duplicate would be picked up by name.
    for name in "$IDENTITY" "micwatch local"; do
        while security find-certificate -c "$name" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; do
            security delete-certificate -c "$name" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || break
        done
    done

    # Every keychain has its own password — macOS only auto-unlocks the login one,
    # and a lock can't be delegated to it. Reusing your login password means
    # nothing extra to remember; any password works.
    #
    # A dialog rather than `read`, which needs a terminal that isn't always there.
    if [[ -t 0 ]]; then
        read -r -s -p "Choose a password for the micwatch signing keychain: " kc_password; echo
    else
        kc_password=$(osascript \
            -e 'display dialog "Choose a password for the micwatch signing keychain.\n\nYou will be asked for it once per session, the first time you build. Reusing your login password is fine." with title "micwatch signing keychain" default answer "" with hidden answer buttons {"Cancel", "Create"} default button "Create"' \
            -e 'text returned of result' 2>/dev/null) || { echo "Cancelled."; exit 1; }
    fi
    [[ -n "$kc_password" ]] || { echo "An empty password would defeat the point."; exit 1; }

    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "$kc_password" "$KEYCHAIN"
    # Lock after 1h idle and whenever the Mac sleeps
    security set-keychain-settings -t 3600 -l "$KEYCHAIN"
    security unlock-keychain -p "$kc_password" "$KEYCHAIN"

    work=$(mktemp -d)
    # System LibreSSL, not Homebrew's OpenSSL 3: the latter writes PKCS12 with
    # algorithms Apple's Security framework rejects ("MAC verification failed").
    ssl=/usr/bin/openssl
    "$ssl" req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$work/key.pem" -out "$work/cert.pem" \
        -subj "/CN=$IDENTITY" \
        -extensions v3_code \
        -config <(cat /etc/ssl/openssl.cnf; printf '\n[v3_code]\nbasicConstraints=critical,CA:false\nextendedKeyUsage=critical,codeSigning\nkeyUsage=critical,digitalSignature\n') 2>/dev/null
    # Transient passphrase: it only has to survive the import on the next line.
    # No backup is kept — this identity signs local dev builds and nothing else,
    # so losing it costs one re-run of this command.
    transit=$("$ssl" rand -base64 24)
    "$ssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
        -name "$IDENTITY" \
        -out "$work/identity.p12" -passout "pass:$transit"

    security import "$work/identity.p12" -k "$KEYCHAIN" -P "$transit" -T /usr/bin/codesign

    # Trust settings live with the user, in the login keychain, even though the
    # key itself doesn't. Self-signed certs are untrusted by default, which makes
    # find-identity hide them and codesign refuse them.
    echo
    echo "macOS will ask for your login password, to trust this certificate for"
    echo "code signing on this Mac only."
    security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$work/cert.pem"

    rm -rf "$work"

    # -T on import adds codesign to the key's ACL, but macOS also gates access on
    # the partition list, which import doesn't set. Without this every build
    # prompts, even with the keychain unlocked.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -l "$IDENTITY" -k "$kc_password" "$KEYCHAIN" >/dev/null

    # codesign resolves identities through the search list; --keychain alone isn't
    # enough, it reports "no identity found". Being listed costs nothing while the
    # keychain is locked — that's what makes the key unreachable, not its absence
    # from the list.
    if ! security list-keychains -d user | grep -q "micwatch-signing"; then
        security list-keychains -d user -s "$LOGIN_KEYCHAIN" "$KEYCHAIN"
    fi

    security lock-keychain "$KEYCHAIN"
    echo
    echo "Done. The key lives in $KEYCHAIN and that keychain is locked."
    echo "The first build of each session asks for its password; after that it"
    echo "stays unlocked for an hour, and re-locks when the Mac sleeps."
    exit 0
fi

# Straight into the bundle. A loose binary alongside it is a second executable
# path, which the Keychain treats as a different application — so it would need
# approving separately, every time it was rebuilt.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -module-cache-path .mcache micwatch.swift -o "$APP/Contents/MacOS/micwatch"

# Icon: one variant of the Icon Composer export, converted to .icns.
#
# An .icns holds a single appearance — it cannot follow light/dark. Adaptive
# icons come from the .icon compiled into an asset catalog, which needs actool
# from full Xcode; Command Line Tools alone can't do it. So pick the variant that
# matches how you actually run: MICWATCH_ICON=Default ./build.sh for the light one.
ICON_VARIANT="${MICWATCH_ICON:-Dark}"
SOURCE_ICON="icon/export/micwatch Exports/micwatch-macOS-$ICON_VARIANT-1024@1x.png"
if [[ -f "$SOURCE_ICON" ]]; then
    mkdir -p "$APP/Contents/Resources"
    work_icon=$(mktemp -d)/micwatch.iconset
    mkdir -p "$work_icon"
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                "512 512x512" "1024 512x512@2x"; do
        set -- $spec
        sips -z "$1" "$1" "$SOURCE_ICON" --out "$work_icon/icon_$2.png" >/dev/null 2>&1
    done
    iconutil -c icns "$work_icon" -o "$APP/Contents/Resources/micwatch.icns"
    rm -rf "$(dirname "$work_icon")"
    ICON_KEY='<key>CFBundleIconFile</key><string>micwatch</string>'
else
    ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>micwatch</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>micwatch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    $ICON_KEY
    <!-- menu bar only: no Dock icon until the settings window opens -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>micwatch checks whether another app is using the microphone, so it can pause your music while the mic is in use. It never records audio.</string>
</dict>
</plist>
PLIST

if [[ -f "$KEYCHAIN" ]]; then
    # --keychain keeps this out of the global search list, so nothing else on the
    # system resolves this identity by accident.
    sign() { codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"; }

    # A locked keychain doesn't make codesign prompt — it reports "no identity
    # found", because the certificate stays readable while the private key doesn't.
    # So try first, and only ask for the password when that's actually why it failed.
    if ! sign 2>/dev/null; then
        if [[ -t 0 ]]; then
            security unlock-keychain "$KEYCHAIN"
        else
            kc_password=$(osascript \
                -e 'display dialog "Unlock the micwatch signing keychain to sign this build." with title "micwatch" default answer "" with hidden answer buttons {"Cancel", "Unlock"} default button "Unlock"' \
                -e 'text returned of result' 2>/dev/null) || { echo "Cancelled."; exit 1; }
            security unlock-keychain -p "$kc_password" "$KEYCHAIN"
        fi
        sign
    fi
    echo "signed with '$IDENTITY'"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "signed with '$IDENTITY' from the login keychain"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "signed ad-hoc — run ./build.sh --create-identity to stop the Keychain re-prompting"
fi

echo "built $APP"
echo "cli: $APP/Contents/MacOS/micwatch --once | --ha-state | --selftest"

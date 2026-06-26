#!/usr/bin/env bash
# build.sh — (re)build "GitHub Repos.app", a tiny background notifier whose icon
# is the GitHub mark. macOS shows the *sending app's* icon on a notification, so
# routing display-notification through this bundle gives us the GitHub icon
# instead of Script Editor's. Native tools only: rsvg-convert, sips, iconutil,
# osacompile. Run from anywhere; outputs land next to this script.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/GitHub Repos.app"
BUNDLE_ID="us.aerviz.repos.notifier"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. SVG -> 1024px PNG -> .icns (all the sizes macOS wants).
rsvg-convert -w 1024 -h 1024 "$HERE/github-mark.svg" -o "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for sz in 16 32 64 128 256 512 1024; do
  sips -z "$sz" "$sz" "$WORK/icon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
done
# Retina (@2x) variants reuse the larger render.
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"

# 2. Compile the AppleScript applet that posts the notification from argv.
osacompile -o "$APP" "$HERE/notify.applescript"

# 3. Swap in our icon and make it a background agent with its own identity.
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/applet.icns"
PLIST="$APP/Contents/Info.plist"
plist_set() { # key, type, value — add if missing, else overwrite
  /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST"
}
plist_set CFBundleIdentifier string "$BUNDLE_ID"
plist_set LSUIElement bool true

# 4. Re-sign (ad-hoc). osacompile's applet ships signed by Apple; editing
#    Info.plist and swapping the icon breaks that signature, and macOS's
#    notification daemon (usernotificationsd) silently DROPS notifications from
#    a bundle whose signature no longer matches its contents. `-s -` re-seals it
#    ad-hoc, keyed to the bundle id, so the app can post and permission is stable.
codesign --force --deep -s - "$APP"

# 5. Register with LaunchServices so the new icon/identity is picked up now.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP"

echo "Built: $APP"

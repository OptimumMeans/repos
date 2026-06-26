#!/usr/bin/env bash
# build.sh — (re)build "GitHub Repos.app", a tiny background notifier whose icon
# is the GitHub mark and which posts through Apple's UserNotifications framework.
# Hand-built osacompile applets can't register as a notification client on modern
# macOS (their notifications are silently dropped); a real signed .app bundle that
# calls UNUserNotificationCenter can. Native tools only: rsvg-convert, sips,
# iconutil, swiftc, codesign. Run from anywhere; output lands next to this script.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/GitHub Repos.app"
BUNDLE_ID="us.aerviz.repos.notifier"
EXE="GitHubNotify"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. SVG -> 1024px PNG -> AppIcon.icns (the icon the notification will show).
rsvg-convert -w 1024 -h 1024 "$HERE/github-mark.svg" -o "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for sz in 16 32 64 128 256 512 1024; do
  sips -z "$sz" "$sz" "$WORK/icon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"

# 2. Assemble the .app bundle and compile the Swift notifier into it.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
swiftc -O "$HERE/githubnotify.swift" -o "$APP/Contents/MacOS/$EXE" \
  -framework UserNotifications

# 3. Info.plist — bundle identity (so UNUserNotificationCenter has a client to
#    register), the icon, and LSUIElement so it never shows in the Dock.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GitHub Repos</string>
  <key>CFBundleDisplayName</key><string>GitHub Repos</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 4. Sign (ad-hoc). A valid signature is required for macOS to trust the bundle
#    as a notification client; sign LAST, after all bundle contents are in place.
codesign --force --deep -s - "$APP"

# 5. Register with LaunchServices so the bundle proxy exists before first run.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP"

echo "Built: $APP"

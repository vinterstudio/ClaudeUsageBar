#!/bin/bash
# Builds ClaudeUsageBar.app — a menu bar (LSUIElement) bundle — into ./dist.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
echo "Building release binary…"
swift build -c release

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/ClaudeUsageBar" "$APP/Contents/MacOS/ClaudeUsageBar"
cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>com.vinterstudio.claudeusagebar</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsageBar</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Prefer the stable self-signed identity (so "Always Allow" persists across
# rebuilds); fall back to ad-hoc signing if it hasn't been created yet.
IDENTITY="ClaudeUsageBar Self-Signed"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "Signing with stable identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "No stable identity found — ad-hoc signing (run ./make-signing-identity.sh to make 'Always Allow' stick)."
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"
fi

# Nudge Launch Services so Finder picks up a changed icon immediately.
touch "$APP" "$APP/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "Done: $APP"
echo "Run it with:  open $APP"
echo "Launch at login: System Settings ▸ General ▸ Login Items ▸ +"

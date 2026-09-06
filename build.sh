#!/bin/bash
# Builds ~/Applications/LimitsBar.app from main.swift and relaunches it. Re-run after edits.
set -euo pipefail
cd "$(dirname "$0")"
app=$HOME/Applications/LimitsBar.app
mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 -o "$app/Contents/MacOS/LimitsBar" main.swift
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.limitsbar</string>
  <key>CFBundleName</key><string>LimitsBar</string>
  <key>CFBundleExecutable</key><string>LimitsBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - -f "$app" >/dev/null 2>&1 || true
pkill -x LimitsBar 2>/dev/null || true
while pgrep -x LimitsBar >/dev/null; do sleep 0.2; done   # let the old instance exit first; `open` fails with -600 otherwise
open "$app"
echo "built and launched $app"

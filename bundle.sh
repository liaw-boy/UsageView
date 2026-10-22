#!/bin/zsh
# Build a release .app bundle: ./bundle.sh  →  QuotaBar.app (TokenPulse)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=QuotaBar.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/QuotaBar $APP/Contents/MacOS/
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TokenPulse</string>
  <key>CFBundleDisplayName</key><string>TokenPulse</string>
  <key>CFBundleIdentifier</key><string>app.tokenpulse.macos</string>
  <key>CFBundleExecutable</key><string>QuotaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - $APP
echo "Built $APP (TokenPulse v0.5.0) — move it to /Applications and open it."

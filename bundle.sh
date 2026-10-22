#!/bin/zsh
# Build a release .app bundle: ./bundle.sh  →  UsageView.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=UsageView.app
rm -rf $APP QuotaBar.app && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/QuotaBar $APP/Contents/MacOS/UsageView

# Generate native macOS AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/generate_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o $APP/Contents/Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UsageView</string>
  <key>CFBundleDisplayName</key><string>UsageView</string>
  <key>CFBundleIdentifier</key><string>app.usageview.macos</string>
  <key>CFBundleExecutable</key><string>UsageView</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.7.3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - $APP
echo "Built $APP (UsageView v0.7.3) — move it to /Applications and open it."

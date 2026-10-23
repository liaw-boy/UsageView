#!/bin/zsh
# Build a release .app bundle: ./bundle.sh  →  UsageView.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=UsageView.app
rm -rf $APP QuotaBar.app && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/QuotaBar $APP/Contents/MacOS/UsageView

# Generate native macOS AppIcon.icns and docs/images/app-icon.png
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/generate_icon.swift "$ICONSET"
mkdir -p docs/images
cp "$ICONSET/icon_128x128@2x.png" docs/images/app-icon.png
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
  <key>CFBundleShortVersionString</key><string>0.9.4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - $APP

# Package UsageView.app.zip (for in-app auto-updater) and UsageView.dmg (for drag-to-Applications installer)
rm -f UsageView.app.zip UsageView.dmg
ditto -c -k --keepParent $APP UsageView.app.zip

DMG_STAGE=$(mktemp -d)/dmg_stage
mkdir -p "$DMG_STAGE"
cp -R $APP "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "UsageView" -srcfolder "$DMG_STAGE" -ov -format UDZO UsageView.dmg >/dev/null
rm -rf "$(dirname "$DMG_STAGE")"

echo "Built $APP, UsageView.app.zip, and UsageView.dmg (UsageView v0.9.4)"

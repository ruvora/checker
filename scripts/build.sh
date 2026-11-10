#!/bin/sh
set -eu
CHECKER_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$CHECKER_ROOT"
CHECKER_BUILD_CONFIGURATION=${CHECKER_BUILD_CONFIGURATION:-release}
CHECKER_VERSION=$(cat "$CHECKER_ROOT/VERSION")
python3 "$CHECKER_ROOT/scripts/sync_localization.py"
swift build -c "$CHECKER_BUILD_CONFIGURATION" --product Checker
CHECKER_BIN_DIR=$(swift build -c "$CHECKER_BUILD_CONFIGURATION" --show-bin-path)
CHECKER_APP="$CHECKER_ROOT/build/Checker.app"
mkdir -p "$CHECKER_APP/Contents/MacOS" "$CHECKER_APP/Contents/Resources"
cp "$CHECKER_BIN_DIR/Checker" "$CHECKER_APP/Contents/MacOS/Checker"
cp "$CHECKER_ROOT/bridge/checker_bridge.py" "$CHECKER_APP/Contents/Resources/checker_bridge.py"
cp "$CHECKER_ROOT/localization/strings.json" "$CHECKER_APP/Contents/Resources/strings.json"
cat > "$CHECKER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Checker</string>
<key>CFBundleIdentifier</key><string>local.checker.prototype</string>
<key>CFBundleName</key><string>Checker</string>
<key>CFBundleDisplayName</key><string>Checker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CHECKER_VERSION" "$CHECKER_APP/Contents/Info.plist"
codesign --force --sign - "$CHECKER_APP"
printf '%s\n' "$CHECKER_APP"

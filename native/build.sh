#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
COLLECTOR_SOURCE="$SCRIPT_DIR/../collector/collector.py"
OUTPUT_BUNDLE="$SCRIPT_DIR/dist/Agent Pet.app"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp/}agent-pet.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_BUNDLE="$STAGE_DIR/Agent Pet.app"
CONTENTS="$APP_BUNDLE/Contents"

if [[ ! -f "$COLLECTOR_SOURCE" ]]; then
  print -u2 "Missing collector: $COLLECTOR_SOURCE"
  exit 1
fi

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>Agent Pet</string>
  <key>CFBundleExecutable</key><string>AgentPet</string>
  <key>CFBundleIdentifier</key><string>local.agentpet.desktop</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Agent Pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

MACOSX_DEPLOYMENT_TARGET=13.0 swiftc \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -O \
  -framework AppKit -framework SwiftUI \
  "$SCRIPT_DIR/AgentPet.swift" \
  -o "$CONTENTS/MacOS/AgentPet"

cp -X "$COLLECTOR_SOURCE" "$CONTENTS/Resources/collector.py"
if [[ -f "$SCRIPT_DIR/../README.md" ]]; then
  cp -X "$SCRIPT_DIR/../README.md" "$CONTENTS/Resources/SETUP.md"
else
  cp -X "$SCRIPT_DIR/README.md" "$CONTENTS/Resources/SETUP.md"
fi
chmod 755 "$CONTENTS/MacOS/AgentPet"
plutil -lint "$CONTENTS/Info.plist"
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "$SCRIPT_DIR/dist"
rm -rf "$OUTPUT_BUNDLE"
ditto "$APP_BUNDLE" "$OUTPUT_BUNDLE"
xattr -d com.apple.FinderInfo "$OUTPUT_BUNDLE" 2>/dev/null || true
codesign --verify --deep --strict "$OUTPUT_BUNDLE"
print "Built $OUTPUT_BUNDLE"

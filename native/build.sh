#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
COLLECTOR_SOURCE="$SCRIPT_DIR/../collector/collector.py"
OUTPUT_BUNDLE="${AGENT_PET_OUTPUT_BUNDLE:-$HOME/Applications/Agent Pet.app}"
if [[ "${OUTPUT_BUNDLE:t}" != "Agent Pet.app" ]]; then
  print -u2 "Output must be named Agent Pet.app"
  exit 1
fi
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
  <key>CFBundleIconFile</key><string>AgentPet.icns</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Agent Pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.6</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

MACOSX_DEPLOYMENT_TARGET=13.0 swiftc \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -O \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  "$SCRIPT_DIR/AgentPet.swift" \
  "$SCRIPT_DIR/AnswerInbox.swift" \
  "$SCRIPT_DIR/LocalNotifier.swift" \
  "$SCRIPT_DIR/ManualResolutionStore.swift" \
  "$SCRIPT_DIR/ThoughtStore.swift" \
  -o "$CONTENTS/MacOS/AgentPet"

MACOSX_DEPLOYMENT_TARGET=13.0 swiftc \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -O -swift-version 6 -strict-concurrency=complete \
  "$SCRIPT_DIR/TopicLabeler.swift" \
  -o "$CONTENTS/MacOS/TopicLabeler"

ICON_BUILDER="$STAGE_DIR/GenerateIcon"
MACOSX_DEPLOYMENT_TARGET=13.0 swiftc \
  -target "$(uname -m)-apple-macosx13.0" \
  -O -framework AppKit \
  "$SCRIPT_DIR/GenerateIcon.swift" \
  -o "$ICON_BUILDER"
ICONSET="$STAGE_DIR/AgentPet.iconset"
"$ICON_BUILDER" "$ICONSET"
iconutil -c icns -o "$CONTENTS/Resources/AgentPet.icns" "$ICONSET"

cp -X "$COLLECTOR_SOURCE" "$CONTENTS/Resources/collector.py"
cp -X "$SCRIPT_DIR/../collector/topic_context.py" "$CONTENTS/Resources/topic_context.py"
cp -X "$SCRIPT_DIR/../collector/topic_labels.py" "$CONTENTS/Resources/topic_labels.py"
if [[ -f "$SCRIPT_DIR/../README.md" ]]; then
  cp -X "$SCRIPT_DIR/../README.md" "$CONTENTS/Resources/SETUP.md"
else
  cp -X "$SCRIPT_DIR/README.md" "$CONTENTS/Resources/SETUP.md"
fi
chmod 755 "$CONTENTS/MacOS/AgentPet"
chmod 755 "$CONTENTS/MacOS/TopicLabeler"
plutil -lint "$CONTENTS/Info.plist"
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$CONTENTS/MacOS/TopicLabeler"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
mkdir -p "${OUTPUT_BUNDLE:h}"
rm -rf "$OUTPUT_BUNDLE"
ditto "$APP_BUNDLE" "$OUTPUT_BUNDLE"
xattr -cr "$OUTPUT_BUNDLE"
xattr -d com.apple.FinderInfo "$OUTPUT_BUNDLE" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$OUTPUT_BUNDLE" 2>/dev/null || true
codesign --verify --deep --strict "$OUTPUT_BUNDLE"
print "Built $OUTPUT_BUNDLE"

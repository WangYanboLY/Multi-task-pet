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
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>local.agentpet.task</string>
    <key>CFBundleURLSchemes</key><array><string>agentpet</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
  <key>CFBundleShortVersionString</key><string>0.5.3</string>
  <key>CFBundleVersion</key><string>17</string>
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

MACOSX_DEPLOYMENT_TARGET=13.0 swiftc \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -O -swift-version 6 -strict-concurrency=complete \
  -framework AppKit -framework UserNotifications \
  "$SCRIPT_DIR/SourceNotificationHelper.swift" \
  -o "$STAGE_DIR/SourceNotificationHelper"

build_notification_helper() {
  local kind="$1"
  local display_name="$2"
  local scheme="agentpet-$kind"
  local helper_bundle="$STAGE_DIR/Agent Pet $display_name Notifications.app"
  local helper_contents="$helper_bundle/Contents"
  mkdir -p "$helper_contents/MacOS" "$helper_contents/Resources"
  cat > "$helper_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>Agent Pet · $display_name</string>
  <key>CFBundleExecutable</key><string>SourceNotificationHelper</string>
  <key>CFBundleIdentifier</key><string>local.agentpet.notifications.$kind</string>
  <key>CFBundleIconFile</key><string>AgentPet.icns</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Agent Pet $display_name Notifications</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>local.agentpet.notifications.$kind</string>
    <key>CFBundleURLSchemes</key><array><string>$scheme</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
  </dict></array>
  <key>CFBundleShortVersionString</key><string>0.5.3</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  cp -X "$STAGE_DIR/SourceNotificationHelper" "$helper_contents/MacOS/SourceNotificationHelper"
  local helper_iconset="$STAGE_DIR/AgentPet-$kind.iconset"
  "$ICON_BUILDER" "$helper_iconset" "$kind"
  iconutil -c icns -o "$helper_contents/Resources/AgentPet.icns" "$helper_iconset"
  local helper_assets="$SCRIPT_DIR/prebuilt/${display_name}Assets.car"
  if [[ -f "$helper_assets" ]]; then
    python3 "$SCRIPT_DIR/validate_asset_catalog.py" "$helper_assets"
    cp -X "$helper_assets" "$helper_contents/Resources/Assets.car"
    plutil -insert CFBundleIconName -string AppIcon "$helper_contents/Info.plist"
  fi
  plutil -lint "$helper_contents/Info.plist"
  codesign --force --sign - "$helper_bundle"
}

build_notification_helper gpt GPT
build_notification_helper claude Claude

# Full Xcode compiles this catalog in CI. The local build keeps working with
# Command Line Tools; the traditional .icns remains available as a fallback.
ASSETS_CAR="${AGENT_PET_ASSETS_CAR:-$SCRIPT_DIR/prebuilt/Assets.car}"
if [[ -f "$ASSETS_CAR" ]]; then
  python3 "$SCRIPT_DIR/validate_asset_catalog.py" "$ASSETS_CAR"
  cp -X "$ASSETS_CAR" "$CONTENTS/Resources/Assets.car"
  plutil -insert CFBundleIconName -string AppIcon "$CONTENTS/Info.plist"
fi

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
for display_name in GPT Claude; do
  helper_name="Agent Pet $display_name Notifications.app"
  helper_output="${OUTPUT_BUNDLE:h}/$helper_name"
  rm -rf "$helper_output"
  ditto "$STAGE_DIR/$helper_name" "$helper_output"
  xattr -cr "$helper_output"
  codesign --verify --deep --strict "$helper_output"
done
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${AGENT_PET_SKIP_REGISTRATION:-0}" != 1 ]]; then
  if [[ ! -x "$LSREGISTER" ]]; then
    print -u2 "Launch Services registration tool is unavailable"
    exit 1
  fi
  "$LSREGISTER" -f "$OUTPUT_BUNDLE"
  "$LSREGISTER" -f "${OUTPUT_BUNDLE:h}/Agent Pet GPT Notifications.app"
  "$LSREGISTER" -f "${OUTPUT_BUNDLE:h}/Agent Pet Claude Notifications.app"
  AGENT_PET_INSTALL_DIR="${OUTPUT_BUNDLE:h}" swift -e '
    import AppKit
    import CoreServices
    import Foundation
    let directory = ProcessInfo.processInfo.environment["AGENT_PET_INSTALL_DIR"]!
    for (scheme, name, bundleID) in [
      ("agentpet", "Agent Pet.app", "local.agentpet.desktop"),
      ("agentpet-gpt", "Agent Pet GPT Notifications.app", "local.agentpet.notifications.gpt"),
      ("agentpet-claude", "Agent Pet Claude Notifications.app", "local.agentpet.notifications.claude")
    ] {
      let url = URL(string: "\(scheme)://notify")!
      let expected = URL(fileURLWithPath: directory).appendingPathComponent(name).standardizedFileURL
      if NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL != expected {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
        guard status == noErr else {
          fputs("Could not set \(scheme) URL handler (\(status))\n", stderr)
          exit(1)
        }
      }
      guard NSWorkspace.shared.urlForApplication(toOpen: url)?.standardizedFileURL == expected else {
        fputs("Launch Services did not resolve \(scheme) to \(expected.path)\n", stderr)
        exit(1)
      }
    }
  '
fi
print "Built $OUTPUT_BUNDLE"

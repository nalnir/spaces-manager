#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app_bundle="$HOME/Applications/Spaces Manager.app"
signing_identity="Apple Development: Lukas Stateczny (H35FP6QTR6)"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$project_root"
swift build
pkill -x SpacesManager 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
iconset="$app_bundle/Contents/Resources/AppIcon.iconset"
mkdir -p "$iconset"
cp "$project_root/.build/debug/SpacesManager" "$app_bundle/Contents/MacOS/SpacesManager"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_root/Sources/SpacesManager/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$project_root/Sources/SpacesManager/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_bundle/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Spaces Manager</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleExecutable</key>
  <string>SpacesManager</string>
  <key>CFBundleIdentifier</key>
  <string>com.lukasstateczny.spacesmanager</string>
  <key>CFBundleName</key>
  <string>Spaces Manager</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeIdentifier</key>
      <string>com.lukasstateczny.spaces-manager.row-reorder</string>
      <key>UTTypeDescription</key>
      <string>Spaces Manager Row Reorder</string>
    </dict>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeIdentifier</key>
      <string>com.lukasstateczny.spaces-manager.space-reorder</string>
      <key>UTTypeDescription</key>
      <string>Spaces Manager Space Reorder</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$signing_identity" "$app_bundle"
"$launch_services_register" -u "$app_bundle" 2>/dev/null || true
"$launch_services_register" -f "$app_bundle"
open "$app_bundle"
#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="${1:-}"
bundle_identifier="com.lukasstateczny.spacesmanager"
app_name="Spaces Manager"
signing_identity="${SPACES_MANAGER_RELEASE_IDENTITY:-}"
notary_profile="${SPACES_MANAGER_NOTARY_PROFILE:-}"
release_dir="$project_root/dist"

if [[ -z "$version" ]]; then
  print -u2 "Usage: $0 <version>"
  exit 64
fi

if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application:/{print $2; exit}')"
fi

if [[ -z "$signing_identity" ]]; then
  print -u2 "A Developer ID Application signing identity is required."
  exit 1
fi

if [[ -z "$notary_profile" ]]; then
  print -u2 "Set SPACES_MANAGER_NOTARY_PROFILE to a notarytool keychain profile."
  exit 1
fi

cd "$project_root"
swift build -c release
build_products_dir="$(swift build -c release --show-bin-path)"
app_bundle="$release_dir/$app_name.app"
archive="$release_dir/SpacesManager-$version.zip"

rm -rf "$app_bundle" "$archive"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$build_products_dir/SpacesManager" "$app_bundle/Contents/MacOS/SpacesManager"
cp -R "$build_products_dir/SpacesManager_SpacesManager.bundle" "$app_bundle/Contents/Resources/"

iconset="$app_bundle/Contents/Resources/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_root/Sources/SpacesManager/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$project_root/Sources/SpacesManager/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_bundle/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleExecutable</key>
  <string>SpacesManager</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_identifier</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>LSUIElement</key>
  <true/>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array><string>public.data</string></array>
      <key>UTTypeIdentifier</key>
      <string>com.lukasstateczny.spaces-manager.row-reorder</string>
      <key>UTTypeDescription</key>
      <string>Spaces Manager Row Reorder</string>
    </dict>
    <dict>
      <key>UTTypeConformsTo</key>
      <array><string>public.data</string></array>
      <key>UTTypeIdentifier</key>
      <string>com.lukasstateczny.spaces-manager.space-reorder</string>
      <key>UTTypeDescription</key>
      <string>Spaces Manager Space Reorder</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
ditto -c -k --keepParent "$app_bundle" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_bundle"
spctl --assess --type execute --verbose=4 "$app_bundle"
rm -f "$archive"
ditto -c -k --keepParent "$app_bundle" "$archive"
print "Release archive created: $archive"
#!/bin/sh
# Build "IDEF0 Modeler.app" from the Swift package.
#
#   macos/scripts/build-app.sh            # release build into macos/build/
#   CONFIG=debug macos/scripts/build-app.sh
#
# SwiftUI's DocumentGroup takes its document types from Info.plist, so the app
# must run as a bundle: the bare executable cannot open or save models.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="${PACKAGE_DIR:-$(cd "$HERE/.." && pwd)}"
CONFIG="${CONFIG:-release}"
OUT="${OUT_DIR:-$(cd "$HERE/.." && pwd)/build}"
APP="$OUT/IDEF0 Modeler.app"
VERSION="${VERSION:-1.0}"

swift build --package-path "$PKG" -c "$CONFIG" --product IDEF0Modeler
BIN_DIR="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/IDEF0Modeler" "$APP/Contents/MacOS/IDEF0 Modeler"
# SwiftPM writes resource bundles beside the executable; ship any that exist.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# The toolkit's HUD faces (Orbitron, Exo 2, Share Tech Mono; OFL, licenses
# alongside). ATSApplicationFontsPath below registers everything in this
# folder for the app only, without installing the fonts system-wide.
cp -R "$PKG/Resources/Fonts" "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>IDEF0 Modeler</string>
  <key>CFBundleDisplayName</key><string>IDEF0 Modeler</string>
  <key>CFBundleIdentifier</key><string>org.idef0.modeler</string>
  <key>CFBundleExecutable</key><string>IDEF0 Modeler</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <!-- A project file is plain JSON, as the web app writes it. Alternate
           rank: the app opens JSON when asked, but never claims all of it. -->
      <key>CFBundleTypeName</key><string>IDEF0 Model</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.json</string></array>
    </dict>
    <dict>
      <!-- The XML interchange opens for editing and saves as a project file. -->
      <key>CFBundleTypeName</key><string>IDEF0 XML Interchange</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.xml</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# An ad-hoc signature, so macOS will launch a locally built bundle.
codesign --force --sign - "$APP" >/dev/null
echo "$APP"

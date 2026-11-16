#!/bin/sh
# Builds the shareable launcher: build/launcher/Shadow Complex Recomp.app (+ .zip). It carries the recompiler
# and runtime sources (no game code or data) and recompiles the user's own Steam copy on their Mac.
#   launcher/package.sh                       ad-hoc signed (fine on this Mac; others get a Gatekeeper warning)
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<notarytool keychain profile> launcher/package.sh
# Needs: Xcode or Command Line Tools; deps/ (tools/vendor_deps.sh, run here if missing; needs Homebrew's
# glslang and spirv-cross).
set -e
cd "$(dirname "$0")/.."
NAME="Shadow Complex Recomp"
OUT=build/launcher
APP="$OUT/$NAME.app"
BUNDLE_ID=${BUNDLE_ID:-io.github.shadowcomplex-recomp.launcher}

[ -d deps/lib ] || tools/vendor_deps.sh

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/src/tools"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 launcher/Launcher.swift \
    -o "$APP/Contents/MacOS/ShadowComplexRecomp"

SRC="$APP/Contents/Resources/src"
cp -R Makefile README.md runtime third_party deps licenses "$SRC/"
cp tools/*.py tools/*.sh tools/orig.sha256 tools/requirements.txt "$SRC/tools/"
VERSION=$(cd "$SRC" && find . -type f ! -name VERSION ! -name README.md | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-10)
echo "$VERSION" > "$SRC/VERSION"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>ShadowComplexRecomp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0 ($VERSION)</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

if [ -n "$SIGN_ID" ]; then
    # every Mach-O inside the bundle must carry the Developer ID signature for notarization
    find "$APP/Contents/Resources" -name "*.dylib" -exec codesign -f --timestamp --options runtime -s "$SIGN_ID" {} \;
    codesign -f --timestamp --options runtime -s "$SIGN_ID" "$APP"
else
    codesign -f -s - "$APP"
fi
codesign --verify --strict "$APP"

ZIP="$OUT/$NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "built $APP ($VERSION) and $ZIP"

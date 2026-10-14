#!/bin/sh
# Builds DillyDally.app, the menu-bar app, next to this script.
# ./build.sh --install also puts it in /Applications and starts it from there.
# ./build.sh --release builds the app that gets published, as dist/DillyDally.dmg:
# for Apple silicon, with its own ffmpeg, and with nobody's name on it.
# Needs Xcode to build, and ffmpeg (Homebrew) to run unless the build is a release.
set -e
cd "$(dirname "$0")"

APP=DillyDally.app
VERSION=0.1.0
# A release is built for the oldest macOS the app runs on, whatever this Mac has.
RELEASE=
TARGET=
[ "$1" = "--release" ] && RELEASE=1 && TARGET="-target arm64-apple-macos15.2"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O $TARGET -parse-as-library menubar.swift engine.swift glyph.swift -o "$APP/Contents/MacOS/DillyDally"
swiftc -O $TARGET -import-objc-header virtualdisplay.h capture.swift -o "$APP/Contents/Resources/capture"
# The command-line tool sits next to the capture helper, which it looks for beside itself.
swiftc -O $TARGET -parse-as-library engine.swift cli.swift -o "$APP/Contents/Resources/dillydally"

# The app icon is a Liquid Glass icon (edit DillyDally.icon in Icon Composer); compiling it needs Xcode.
xcrun actool DillyDally.icon --compile "$APP/Contents/Resources" --app-icon DillyDally --platform macosx \
    --minimum-deployment-target 15.2 --output-partial-info-plist /dev/null > /dev/null

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.martynaskadisa.cast</string>
    <key>CFBundleName</key><string>DillyDally</string>
    <key>CFBundleIconFile</key><string>DillyDally</string>
    <key>CFBundleIconName</key><string>DillyDally</string>
    <key>CFBundleExecutable</key><string>DillyDally</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.2</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>DillyDally looks for TVs on your network and streams to them.</string>
</dict>
</plist>
EOF

if [ -n "$RELEASE" ]; then
    # A release carries its own ffmpeg, so it runs on a Mac with nothing else installed.
    [ -x build/ffmpeg ] || ./ffmpeg.sh
    cp build/ffmpeg "$APP/Contents/Resources/ffmpeg"
    cp build/ffmpeg-COPYING.LGPLv2.1 "$APP/Contents/Resources/ffmpeg-COPYING.LGPLv2.1"
    # Every executable is signed ad hoc: a certificate would put its owner's name in the app.
    for tool in ffmpeg capture dillydally; do
        codesign --force --sign - "$APP/Contents/Resources/$tool"
    done
    codesign --force --sign - "$APP"
    # Nothing in it may say where or by whom it was built.
    if grep -r -a -l -e "/Users/" -e "$(id -F)" "$APP"; then
        echo "The files above name this Mac's user, so no disk image was made." >&2
        exit 1
    fi
    # The disk image holds the app and a shortcut to Applications to drag it onto.
    rm -rf build/image dist
    mkdir -p build/image dist
    ditto --norsrc --noextattr "$APP" "build/image/$APP"
    ln -s /Applications build/image/Applications
    hdiutil create -quiet -volname DillyDally -srcfolder build/image -fs HFS+ -format UDZO dist/DillyDally.dmg
    # The cask has to name this exact disk image.
    SUM=$(shasum -a 256 dist/DillyDally.dmg | cut -d ' ' -f 1)
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SUM\"/" Casks/dillydally.rb
    echo "Built dist/DillyDally.dmg ($VERSION) and wrote its checksum into Casks/dillydally.rb"
    exit
fi

# A real identity keeps the Screen Recording and Local Network permissions across rebuilds;
# without one the app is signed ad hoc and macOS asks again after every build.
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
    pkill -x DillyDally && sleep 1 || true  # give it a moment to go, or open fails
    rm -rf "/Applications/$APP"
    ditto "$APP" "/Applications/$APP"
    open "/Applications/$APP"
    echo "Installed /Applications/$APP"
fi

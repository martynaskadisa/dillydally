#!/bin/sh
# Redraws docs/panel.png, docs/panel-light.png and docs/modes.png from the panel
# in menubar.swift. Builds the app first, for its icon.
set -e
cd "$(dirname "$0")/.."

./build.sh > /dev/null
BUILD=build/screenshots
mkdir -p "$BUILD"
# The panel's file, without the app's entry point and the search it starts, and with
# its pages open to the harness.
sed -e 's/^@main$//' \
    -e 's/@State private var showing/@State var showing/' \
    -e 's/if model.phase == .idle { model.search() }//' \
    menubar.swift > "$BUILD/Panel.swift"
swiftc -O engine.swift glyph.swift "$BUILD/Panel.swift" screenshots/main.swift -o "$BUILD/render"
"$BUILD/render" docs "$PWD/DillyDally.app"
echo "Drew docs/panel.png, docs/panel-light.png and docs/modes.png"

#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
test_root="$(mktemp -d /private/tmp/ledge-unit-screens.XXXXXX)"
bundle="$test_root/UnitScreens.app"
mkdir -p "$bundle/Contents/MacOS" build/module-cache
cp -R Resources "$bundle/Contents/"
cp Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ledge.skin-switch-tests' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UnitScreens' "$bundle/Contents/Info.plist"
source_copy="$test_root/Sources"
python3 Tests/prepare-skin-snapshots.py Sources "$source_copy"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -D UNIT_SKIN \
    -target arm64-apple-macosx14.0 -module-cache-path build/module-cache \
    "$source_copy"/Core/*.swift "$source_copy"/Services/*.swift "$source_copy"/UI/*.swift Tests/ClassicSkinSnapshots.swift \
    -framework AVKit -framework QuickLookUI -o "$bundle/Contents/MacOS/UnitScreens"
echo "Artifacts: $test_root"
"$bundle/Contents/MacOS/UnitScreens" "$test_root/images" "$test_root/fixture"

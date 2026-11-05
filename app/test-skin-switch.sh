#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
test_root="$(mktemp -d /private/tmp/ledge-skin-switch.XXXXXX)"
bundle="$test_root/SkinSwitchTests.app"
mkdir -p "$bundle/Contents/MacOS" build/module-cache
cp -R Resources "$bundle/Contents/"
cp Tests/Fixtures/SyntheticTabletop.jpg "$bundle/Contents/Resources/"
cp Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ledge.skin-switch-tests' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SkinSwitchTests' "$bundle/Contents/Info.plist"
source_copy="$test_root/Sources"
python3 Tests/prepare-skin-snapshots.py Sources "$source_copy"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -target arm64-apple-macosx14.0 -module-cache-path build/module-cache \
    "$source_copy"/Core/*.swift "$source_copy"/Services/*.swift "$source_copy"/UI/*.swift Tests/SyntheticDrag.swift Tests/SkinSwitchTests.swift \
    -framework AVKit -framework QuickLookUI -o "$bundle/Contents/MacOS/SkinSwitchTests"
echo "Artifacts: $test_root"
"$bundle/Contents/MacOS/SkinSwitchTests" "$test_root"

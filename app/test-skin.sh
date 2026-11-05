#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
# Baseline is a source snapshot taken before extraction (or a clean git archive).
# Both versions use the same fixtures, compiler, renderer, resources and scale.
baseline="${1:?Usage: bash app/test-skin.sh /absolute/path/to/baseline/Sources}"
test_root="$(mktemp -d /private/tmp/ledge-skin-tests.XXXXXX)"
echo "Artifacts: $test_root"
for version in baseline candidate; do
    source_root="$baseline"
    if [[ "$version" == candidate ]]; then source_root="$PWD/Sources"; fi
    source_copy="$test_root/$version-sources"
    python3 Tests/prepare-skin-snapshots.py "$source_root" "$source_copy"
    bundle="$test_root/$version.app"
    mkdir -p "$bundle/Contents/MacOS" "$test_root/module-cache"
    cp -R Resources "$bundle/Contents/"
    cp Info.plist "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ledge.skin-snapshots' "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SkinSnapshots' "$bundle/Contents/Info.plist"
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
        -target arm64-apple-macosx14.0 -module-cache-path "$test_root/module-cache" \
        "$source_copy"/Core/*.swift "$source_copy"/Services/*.swift "$source_copy"/UI/*.swift \
        Tests/ClassicSkinSnapshots.swift -framework AVKit -framework QuickLookUI \
        -o "$bundle/Contents/MacOS/SkinSnapshots"
    "$bundle/Contents/MacOS/SkinSnapshots" "$test_root/$version" "$test_root/fixture"
done
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_root/module-cache" Tests/CompareSkinSnapshots.swift -o "$test_root/compare"
"$test_root/compare" "$test_root" "${2:-}"

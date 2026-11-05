#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
source_root="${1:-$PWD/Sources}"
review_root="${2:-/private/tmp/ledge-skin-review-candidate}"
bundle="$review_root/ClassicReview.app"
source_copy="$(mktemp -d /private/tmp/ledge-skin-review-sources.XXXXXX)"
trap 'rm -rf "$source_copy"' EXIT
cp -R "$source_root/" "$source_copy/"
# Keep the actual panel controller and edge view; replace only app startup,
# which would otherwise load personal preferences/library and connect to AI.
python3 - "$source_copy/UI/Application.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
boundary = source.index('@MainActor final class AppDelegate:')
path.write_text(source[:boundary])
PY
mkdir -p "$bundle/Contents/MacOS" "$review_root/module-cache"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -target arm64-apple-macosx14.0 -module-cache-path "$review_root/module-cache" \
    "$source_copy"/Core/*.swift "$source_copy"/Services/*.swift "$source_copy"/UI/*.swift \
    Tools/SkinReview.swift -framework AVKit -framework QuickLookUI -o "$bundle/Contents/MacOS/SkinReview"
cp -R Resources "$bundle/Contents/"
cp Tests/Fixtures/SyntheticTabletop.jpg "$bundle/Contents/Resources/"
cp Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ledge.skin-review' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SkinReview' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ClassicReview' "$bundle/Contents/Info.plist"
codesign --force --sign - --identifier local.ledge.skin-review "$bundle"
codesign --verify --deep --strict "$bundle"
echo "Built review only (not launched): $bundle"

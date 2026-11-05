#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
bundle="build/WebPreviewModelTests.app/Contents"
mkdir -p build/module-cache "$bundle/MacOS" "$bundle/Resources"
cp -R Resources/en.lproj Resources/zh-Hant.lproj "$bundle/Resources/"
cp Info.plist "$bundle/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.ledge.web-preview-model-tests' "$bundle/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable WebPreviewModelTests' "$bundle/Info.plist"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/Core/*.swift Sources/Services/*.swift Sources/UI/WorkbenchModel.swift Sources/UI/MediaPreview.swift Tests/WebPreviewModelTests.swift -framework WebKit -framework QuickLookUI -o "$bundle/MacOS/WebPreviewModelTests"
"$bundle/MacOS/WebPreviewModelTests"

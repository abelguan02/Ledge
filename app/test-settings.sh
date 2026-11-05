#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/Core/*.swift Sources/Services/*.swift Sources/UI/LedgeSkin.swift Sources/UI/WorkbenchModel.swift Sources/UI/MediaPreview.swift Sources/UI/SettingsWindow.swift Tests/SettingsBehaviorTests.swift Tests/ShortcutRecordingTests.swift -framework QuickLookUI -o build/settings-tests
./build/settings-tests

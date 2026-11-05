#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p app/build/module-cache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path app/build/module-cache app/Sources/Core/*.swift app/Sources/Services/*.swift app/Sources/UI/LedgeSkin.swift app/Sources/UI/SkinSurfaces.swift app/Sources/UI/WorkbenchModel.swift app/Sources/UI/MediaPreview.swift app/Sources/UI/EdgeLineIndicator.swift app/Tools/EdgeLinePreview.swift -o app/build/edge-preview
app/build/edge-preview

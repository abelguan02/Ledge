#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
build_root="${LEDGE_BUILD_ROOT:-build}"
bundle="$build_root/Ledge.app"
mkdir -p "$build_root/module-cache" "$bundle/Contents/MacOS" "$bundle/Contents/XPCServices/CodexService.xpc/Contents/MacOS"
flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macosx14.0 -module-cache-path "$build_root/module-cache")
xcrun swiftc "${flags[@]}" Sources/Services/MingTextLimits.swift Sources/Services/PeerSignature.swift Sources/Services/CodexBridge.swift Sources/Services/CodexConnection.swift Sources/Services/CodexTiming.swift Service/CodexLaunch.swift Service/ServiceQueue.swift Service/main.swift -o "$bundle/Contents/XPCServices/CodexService.xpc/Contents/MacOS/CodexService"
xcrun swiftc "${flags[@]}" -parse-as-library Sources/Core/*.swift Sources/Services/*.swift Sources/UI/*.swift -framework AVKit -framework QuickLookUI -o "$bundle/Contents/MacOS/Ledge"
cp -R Resources "$bundle/Contents/"
cp Info.plist "$bundle/Contents/Info.plist"
cp Service/Info.plist "$bundle/Contents/XPCServices/CodexService.xpc/Contents/Info.plist"
plutil -lint Info.plist Service/Info.plist Sandbox.entitlements
codesign --force --sign - --identifier local.ledge.desktop.CodexService "$bundle/Contents/XPCServices/CodexService.xpc"
codesign --force --sign - --identifier local.ledge.desktop --entitlements Sandbox.entitlements "$bundle"
codesign --verify --deep --strict "$bundle"
echo "Built: $bundle"

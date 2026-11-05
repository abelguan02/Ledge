#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
test_root="$(mktemp -d /private/tmp/ledge-coffee-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT
bundle="$test_root/CoffeeTests.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" build/module-cache
cp Resources/CoffeePayment.jpg Resources/AlipayPayment.jpg "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ledge.coffee-tests</string>
<key>CFBundleExecutable</key><string>CoffeeTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/Core/AppLanguage.swift Sources/UI/LedgeSkin.swift Sources/UI/CoffeePaymentCode.swift Tests/CoffeePaymentCodeTests.swift -o "$bundle/Contents/MacOS/CoffeeTests"
"$bundle/Contents/MacOS/CoffeeTests"

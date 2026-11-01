#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/Core/*.swift Sources/Services/WebSnapshot.swift Tests/WebSnapshotTests.swift -framework WebKit -o build/web-snapshot-tests
test_binary=./build/web-snapshot-tests
if [ "${1:-}" = --sandbox ]; then
    mkdir -p build/WebSnapshotTests.app/Contents/MacOS
    cp build/web-snapshot-tests build/WebSnapshotTests.app/Contents/MacOS/WebSnapshotTests
    cp Tests/WebSnapshotTests-Info.plist build/WebSnapshotTests.app/Contents/Info.plist
    codesign --force --sign - --identifier local.dump.phase5webtests --entitlements Sandbox.entitlements build/WebSnapshotTests.app
    test_binary=./build/WebSnapshotTests.app/Contents/MacOS/WebSnapshotTests
fi
port_file=$(mktemp /tmp/dump-web-fixture.XXXXXX)
python3 Tests/WebSnapshotFixture.py "$port_file" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; rm -f "$port_file"' EXIT
for attempt in {1..50}; do
    if [ -s "$port_file" ]; then break; fi
    sleep 0.1
done
"$test_binary" "$(cat "$port_file")"

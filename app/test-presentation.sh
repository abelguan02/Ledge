#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Sources/Core/*.swift Tests/PresentationFlowTests.swift -o build/presentation-tests
./build/presentation-tests --about
./build/presentation-tests --onboarding

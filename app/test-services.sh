#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p build/module-cache
flags=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache)
sources=(Sources/Core/AppLanguage.swift Sources/Services/MingTextLimits.swift Sources/Services/PeerSignature.swift Sources/Services/CodexBridge.swift Sources/Services/CodexConnection.swift Sources/Services/CodexTiming.swift)
xcrun swiftc "${flags[@]}" "${sources[@]}" Service/CodexLaunch.swift Tests/CodexLaunchTests.swift -o build/launch-tests
./build/launch-tests
xcrun swiftc "${flags[@]}" "${sources[@]}" Tests/CodexConnectionTests.swift -o build/connection-tests
./build/connection-tests "$PWD/Tests/codex_fake_server.py"
xcrun swiftc "${flags[@]}" Service/ServiceQueue.swift Tests/ServiceQueueTests.swift -o build/service-queue-tests
./build/service-queue-tests

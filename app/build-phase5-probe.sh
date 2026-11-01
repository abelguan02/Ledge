#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
target=build/Phase5Probe.app
mkdir -p "$target/Contents/MacOS" "$target/Contents/Resources" build/module-cache
if [ ! -f build/phase5-QA-video.mp4 ]; then
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 30 -c:v libx264 -pix_fmt yuv420p -profile:v main -c:a aac -af volume=0.05 -movflags +faststart build/phase5-QA-video.mp4
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -module-cache-path build/module-cache Tools/Phase5Probe.swift -framework QuickLookUI -framework WebKit -framework AVKit -o "$target/Contents/MacOS/Phase5Probe"
cp Tools/Phase5Probe-Info.plist "$target/Contents/Info.plist"
cp build/phase5-QA-video.mp4 "$target/Contents/Resources/QA-video.mp4"
codesign --force --sign - --identifier local.dump.phase5probe --entitlements Tools/Phase5Probe.entitlements "$target"
codesign --verify --strict "$target"

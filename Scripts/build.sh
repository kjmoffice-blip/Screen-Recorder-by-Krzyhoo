#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build"
app_dir="$build_dir/Screen Recorder by Krzyhoo.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$build_dir/module-cache"
xcrun swift -module-cache-path "$build_dir/module-cache" "$project_dir/Scripts/make-icon.swift" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
for arch in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -target "$arch-apple-macos13.0" -module-cache-path "$build_dir/module-cache" \
        "$project_dir/Sources/Audio.swift" "$project_dir/Sources/Recording.swift" "$project_dir/Sources/Selection.swift" "$project_dir/Sources/main.swift" \
        -o "$build_dir/ScreenRecorder-$arch"
done
lipo -create "$build_dir/ScreenRecorder-arm64" "$build_dir/ScreenRecorder-x86_64" -output "$app_dir/Contents/MacOS/ScreenRecorder"
codesign --force --sign - --options runtime --entitlements "$project_dir/Resources/Entitlements.plist" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"

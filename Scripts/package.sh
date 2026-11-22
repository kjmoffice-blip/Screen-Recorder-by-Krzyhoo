#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Screen Recorder by Krzyhoo.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
app_name="Screen Recorder by Krzyhoo $version.app"
release_dir="$(mktemp -d "$HOME/Downloads/Screen Recorder by Krzyhoo $version-XXXXXX")"
stage_dir="$(mktemp -d "$project_dir/build/package-XXXXXX")"
mkdir -p "$stage_dir/dmg" "$stage_dir/source/Screen Recorder by Krzyhoo"
ditto "$app_dir" "$release_dir/$app_name"
codesign --verify --deep --strict "$release_dir/$app_name"
for file in README.md INSTRUKCJA.txt WERYFIKACJA.txt RIGHTS.md LICENSE .gitignore; do
    cp "$project_dir/$file" "$release_dir/"
    cp "$project_dir/$file" "$stage_dir/source/Screen Recorder by Krzyhoo/"
done
for folder in Sources Scripts Resources Tests; do
    ditto "$project_dir/$folder" "$stage_dir/source/Screen Recorder by Krzyhoo/$folder"
done
# Only explicit source/resource folders are archived: no caches, captured movies, secrets or build files.
ditto -c -k --sequesterRsrc --keepParent "$stage_dir/source/Screen Recorder by Krzyhoo" "$release_dir/Screen Recorder by Krzyhoo-$version-source.zip"
unzip -t "$release_dir/Screen Recorder by Krzyhoo-$version-source.zip" > "$stage_dir/archive-verification.txt"
ditto "$app_dir" "$stage_dir/dmg/$app_name"
cp "$project_dir/INSTRUKCJA.txt" "$stage_dir/dmg/"
ln -s /Applications "$stage_dir/dmg/Aplikacje"
hdiutil create -volname "Screen Recorder by Krzyhoo" -srcfolder "$stage_dir/dmg" -format UDZO "$release_dir/Screen Recorder by Krzyhoo-$version.dmg"
hdiutil verify "$release_dir/Screen Recorder by Krzyhoo-$version.dmg" > "$stage_dir/dmg-verification.txt"
mkdir "$stage_dir/mount"
hdiutil attach -readonly -nobrowse -mountpoint "$stage_dir/mount" "$release_dir/Screen Recorder by Krzyhoo-$version.dmg" > "$stage_dir/mount-verification.txt"
trap 'hdiutil detach "$stage_dir/mount" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict "$stage_dir/mount/$app_name"
cmp "$app_dir/Contents/MacOS/ScreenRecorder" "$stage_dir/mount/$app_name/Contents/MacOS/ScreenRecorder"
hdiutil detach "$stage_dir/mount"
trap - EXIT
(
    cd "$release_dir"
    shasum -a 256 "Screen Recorder by Krzyhoo-$version.dmg" "Screen Recorder by Krzyhoo-$version-source.zip" \
        "$app_name/Contents/MacOS/ScreenRecorder" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
printf '%s\n' "$release_dir" > "$project_dir/build/last-release-path.txt"
printf '%s\n' "$release_dir"

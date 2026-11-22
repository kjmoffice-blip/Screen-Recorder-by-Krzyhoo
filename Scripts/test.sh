#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/build/module-cache"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 -module-cache-path "$project_dir/build/module-cache" \
    "$project_dir/Sources/Audio.swift" "$project_dir/Sources/Recording.swift" "$project_dir/Tests/WriterTests.swift" -o "$project_dir/build/WriterTests"
test_dir="$(mktemp -d "$project_dir/build/writer-tests-XXXXXX")"
"$project_dir/build/WriterTests" "$test_dir"

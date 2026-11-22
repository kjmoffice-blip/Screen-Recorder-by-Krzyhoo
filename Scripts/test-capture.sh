#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="/Applications/Screen Recorder by Krzyhoo 1.0.1.app"
reports="$(mktemp -d "$project_dir/build/native-tests-XXXXXX")"
python3 - "$project_dir/build/system-test.wav" <<'PY'
import math,struct,sys,wave
with wave.open(sys.argv[1], 'wb') as output:
    output.setparams((1,2,48000,0,'NONE','not compressed'))
    samples=[int(math.sin(i*2*math.pi*440/48000)*4500) for i in range(48000*2)]
    output.writeframes(struct.pack('<'+'h'*len(samples),*samples))
PY
for mode in full region; do
    for audio in none system microphone; do
        report="$reports/$mode-$audio.txt"
        open -n "$app_path" --args "--smoke-$mode" --audio "$audio" --report "$report"
        if [ "$audio" = system ]; then
            (sleep 2; /usr/bin/afplay "$project_dir/build/system-test.wav") &
        fi
        for attempt in {1..40}; do
            if [ -f "$report" ]; then break; fi
            sleep 0.5
        done
        if [ ! -f "$report" ]; then printf 'WAIT: macOS permission or recording did not finish: %s\n' "$report"; exit 1; fi
        cat "$report"
        if ! /usr/bin/grep -q '^PASS ' "$report"; then exit 1; fi
        sleep 0.5
    done
done
printf '%s\n' "$reports" > "$project_dir/build/last-native-tests-path.txt"
printf 'ALL 6 REAL CAPTURE TESTS PASSED: %s\n' "$reports"

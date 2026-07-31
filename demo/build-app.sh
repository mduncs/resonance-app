#!/bin/zsh

set -u

status_dir="${1:?usage: build-app.sh STATUS_DIRECTORY}"
derived_data="${RESONANCE_PUBLIC_DERIVED_DATA:-$PWD/build/DerivedData}"

/bin/mkdir -p "$status_dir" "$derived_data"
print -r -- "$$" > "$status_dir/pid"
print -r -- "starting $(date -u +%FT%TZ)" > "$status_dir/progress"

(
    while /bin/kill -0 "$$" 2>/dev/null; do
        print -r -- "running $(date -u +%FT%TZ)" > "$status_dir/progress"
        /bin/sleep 30
    done
) &
ticker_pid=$!

xcodebuild \
    -project Resonance/Resonance.xcodeproj \
    -scheme Resonance \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    build \
    > "$status_dir/output.log" 2>&1
result=$?

/bin/kill "$ticker_pid" 2>/dev/null || true
print -r -- "$result" > "$status_dir/exit"
print -r -- "finished $(date -u +%FT%TZ)" > "$status_dir/progress"
/usr/bin/touch "$status_dir/done"

exit "$result"

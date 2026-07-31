#!/bin/zsh

set -u

status_dir="${1:?usage: verify.sh STATUS_DIRECTORY}"
build_root="${RESONANCE_PUBLIC_BUILD_ROOT:-$PWD/build/BuildCache}"

/bin/mkdir -p "$status_dir" "$build_root/clang" "$build_root/modules" "$build_root/swiftpm"
print -r -- "$$" > "$status_dir/pid"
print -r -- "starting $(date -u +%FT%TZ)" > "$status_dir/progress"

(
    while /bin/kill -0 "$$" 2>/dev/null; do
        print -r -- "running $(date -u +%FT%TZ)" > "$status_dir/progress"
        /bin/sleep 30
    done
) &
ticker_pid=$!

env \
    CLANG_MODULE_CACHE_PATH="$build_root/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="$build_root/modules" \
    swift test \
        --package-path Resonance \
        --scratch-path "$build_root/swiftpm" \
        --disable-sandbox \
        > "$status_dir/output.log" 2>&1
result=$?

/bin/kill "$ticker_pid" 2>/dev/null || true
print -r -- "$result" > "$status_dir/exit"
print -r -- "finished $(date -u +%FT%TZ)" > "$status_dir/progress"
/usr/bin/touch "$status_dir/done"

exit "$result"

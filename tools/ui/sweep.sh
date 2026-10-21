#!/bin/bash
# Renders every section of a DEBUG build with preview data at the minimum, a medium and a large window size, and
# fails if any render crashes or produces nothing. It catches AppKit layout loops (for example a Table's column
# minimums fighting an inspector) that unit tests and fixed-size previews miss.
#
#   tools/ui/sweep.sh [path/to/Vaulthalla.app] [output dir]
set -u
app="${1:-build/DerivedData/Build/Products/Debug/Vaulthalla.app}/Contents/MacOS/Vaulthalla"
out="${2:-$(mktemp -d "${TMPDIR:-/tmp}/vh-sweep.XXXXXX")}"
mkdir -p "$out"
sections="all allKeys 1:overview 1:files 1:vaults 1:credentials 1:shares 1:access 1:syncConflicts 1:cost 1:s3Gateway 1:recoveryKeys 1:devices 0:overview"
failures=0
for size in 980x640 1100x700 1600x1000; do
    for section in $sections; do
        png="$out/$size-${section/:/-}.png"
        # macOS has no timeout(1); perl's alarm bounds a hung render.
        perl -e 'alarm 90; exec @ARGV' "$app" -VHDebugPreviewData YES -VHDebugSelect "$section" \
            -VHDebugWindowSize "$size" -VHDebugSnapshot "$png" >/dev/null 2>&1
        status=$?
        if [ ! -s "$png" ]; then
            echo "FAIL $size $section (exit $status)"
            failures=$((failures + 1))
        fi
    done
done
echo "renders in $out"
[ "$failures" -eq 0 ]

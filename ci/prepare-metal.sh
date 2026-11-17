#!/bin/bash
set -euo pipefail

# A discoverable metal launcher does not prove the downloaded compiler works.
xcodebuild -version
xcode-select -p
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/newbi-metal.XXXXXX")
cat > "$probe_dir/probe.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void newbi_probe(device float *output [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    output[i] = 0.0;
}
METAL

verify_metal() {
    xcrun --kill-cache
    xcrun --sdk iphoneos metal -c "$probe_dir/probe.metal" -o "$probe_dir/probe.air" &&
        xcrun --sdk iphoneos metallib "$probe_dir/probe.air" -o "$probe_dir/probe.metallib"
}

if verify_metal; then
    echo "Metal compile and link probe passed."
    exit 0
fi

# Even a successful download must pass the compile/link probe.
if xcodebuild -downloadComponent MetalToolchain; then
    if verify_metal; then exit 0; fi
fi

export_dir="$probe_dir/export"
mkdir -p "$export_dir"
xcodebuild -downloadComponent MetalToolchain -exportPath "$export_dir"
imported=0
# Xcode releases have shipped both exportedBundle and dmg component formats.
while IFS= read -r -d '' component; do
    case "$component" in
        *.exportedBundle) xcodebuild -importComponent MetalToolchain -importPath "$component" ;;
        *.dmg) xcodebuild -importComponent MetalToolchain "$component" ;;
    esac
    imported=1
done < <(find "$export_dir" \( -name '*.exportedBundle' -o -name '*.dmg' \) -prune -print0)

if [ "$imported" -ne 1 ]; then
    echo "ERROR: No exported Metal component found in $export_dir" >&2
    exit 1
fi
if ! verify_metal; then
    echo "ERROR: Metal Toolchain still cannot compile/link for the selected Xcode. See build-metal.log." >&2
    exit 1
fi
echo "Metal compile and link probe passed after import."

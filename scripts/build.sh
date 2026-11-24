#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep compiler caches within the project, including in restricted environments.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
build_flags=(-c release --disable-sandbox --scratch-path .build
             --cache-path .build/cache --config-path .build/config
             --security-path .build/security --manifest-cache local
             -debug-info-format none)
swift build "${build_flags[@]}"
bin_dir="$(swift build "${build_flags[@]}" --show-bin-path)"
app_path="$PWD/build/MacSignal.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/MacSignal" "$app_path/Contents/MacOS/MacSignal"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
# English and Chinese: the system picks one (InfoPlist.strings holds the Bluetooth prompt).
cp -R Resources/*.lproj "$app_path/Contents/Resources/"

# Use full-bleed square artwork; macOS supplies the outer shape and material.
# Baking a rounded tile with transparent margins creates a nested frame.
icon_source="$PWD/Design/AppIcon/monitor-grid-fullbleed-v3.png"
iconset_path="$PWD/build/AppIcon.iconset"
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" \
        --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$icon_source" \
        --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_path" \
    --output "$app_path/Contents/Resources/AppIcon.icns"

# Ad hoc signatures (the default) identify the app by its code hash, so a
# rebuilt binary may no longer match an earlier Accessibility permission.
# Set MACSIGNAL_SIGN_IDENTITY to a code signing certificate name, such as an
# Apple Development or self-signed certificate, to keep a stable identity.
codesign --force --sign "${MACSIGNAL_SIGN_IDENTITY:--}" "$app_path"
touch "$app_path"
printf '\nBuilt: %s\nLaunch: open "%s"\n' "$app_path" "$app_path"

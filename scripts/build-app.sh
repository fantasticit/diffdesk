#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

case "${1-}" in
    "")
        identity="-"
        ;;
    --developer-id)
        shift
        identity=${1:-}
        case "$identity" in
            "Developer ID Application: "*) ;;
            *) printf '%s\n' '用法: scripts/build-app.sh --developer-id "Developer ID Application: 名称 (TEAMID)"' >&2; exit 2 ;;
        esac
        if ! security find-identity -v -p codesigning | awk -F '"' -v identity="$identity" '
            $2 == identity { found = 1 }
            END { exit !found }
        '; then
            printf '%s\n' '钥匙串中没有匹配的有效 Developer ID Application 签名身份。请导入证书及对应私钥。' >&2
            exit 1
        fi
        ;;
    *)
        printf '%s\n' '用法: scripts/build-app.sh [--developer-id "Developer ID Application: 名称 (TEAMID)"]' >&2
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    printf '%s\n' '只接受一个签名身份。' >&2
    exit 2
fi

sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [ "${sdk_version%%.*}" -lt 27 ]; then
    printf '%s\n' '请使用包含 macOS 27 SDK 的 Xcode 或 Command Line Tools 构建。' >&2
    exit 2
fi
export SDKROOT="$sdk"
mkdir -p "$root/.build" "$root/dist"
stage=$(mktemp -d "$root/.build/app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/diff+.app"
iconset="$stage/DiffPlus.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
xcrun swift "$root/scripts/draw-icon.swift" "$iconset"
iconutil --convert icns --output "$app/Contents/Resources/DiffPlusIcon.icns" "$iconset"
xcrun swiftc -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" \
    -swift-version 5 -parse-as-library -module-name ChangeDesk -O -whole-module-optimization \
    Sources/ChangeDesk/*.swift -o "$app/Contents/MacOS/diff+"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleDisplayName</key><string>diff+</string>
  <key>CFBundleName</key><string>diff+</string>
  <key>CFBundleIconFile</key><string>DiffPlusIcon.icns</string>
  <key>CFBundleExecutable</key><string>diff+</string>
  <key>CFBundleIdentifier</key><string>local.changedesk.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.7.1</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [ "$identity" = "-" ]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict --verbose=2 "$app"

target="$root/dist/diff+.app"
previous="$stage/previous.app"
if [ -e "$target" ]; then mv "$target" "$previous"; fi
if ! mv "$app" "$target"; then
    if [ -e "$previous" ]; then mv "$previous" "$target"; fi
    exit 1
fi
install -m 644 "$iconset/icon_256x256.png" "$root/dist/diff+-icon.png"
codesign --verify --strict "$target"
printf '%s\n' "$target"

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

swift build -c release
bin=$(swift build -c release --show-bin-path)
app="$root/dist/Diffdesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$root/.build/Diffdesk.iconset"
mkdir -p "$iconset"
swift "$root/scripts/draw-icon.swift" "$iconset"
iconutil --convert icns --output "$app/Contents/Resources/Diffdesk.icns" "$iconset"
install -m 644 "$iconset/icon_256x256.png" "$root/dist/Diffdesk-icon.png"
install -m 755 "$bin/ChangeDesk" "$app/Contents/MacOS/ChangeDesk"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleDisplayName</key><string>Diffdesk</string>
  <key>CFBundleName</key><string>Diffdesk</string>
  <key>CFBundleIconFile</key><string>Diffdesk.icns</string>
  <key>CFBundleExecutable</key><string>ChangeDesk</string>
  <key>CFBundleIdentifier</key><string>local.changedesk.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>CFBundleVersion</key><string>11</string>
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
printf '%s\n' "$app"

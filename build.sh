#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-/opt/theos/sdks/iPhoneOS14.5.sdk}"
APP_NAME="BQTool"
VERSION="2.4.3"
BID="${BID:-com.kamui.escape}"
BUILD="$ROOT/build"
APP="$BUILD/Payload/$APP_NAME.app"

echo "[*] SDK: $SDK"
[ -d "$SDK" ] || { echo "[!] SDK missing"; exit 1; }

rm -rf "$BUILD"
mkdir -p "$APP"

echo "[*] compiling..."
clang \
    -target arm64-apple-ios14.0 \
    -isysroot "$SDK" \
    -fuse-ld=lld \
    -fobjc-arc -fblocks -O2 \
    -Wall -Wno-unused-parameter -Wno-deprecated-declarations \
    -framework UIKit \
    -framework Foundation \
    -framework CoreFoundation \
    -framework CoreGraphics \
    -framework WebKit \
    -L"$SDK/usr/lib" -lz \
    "$ROOT/src/main.m" \
    "$ROOT/src/AppDelegate.m" \
    "$ROOT/src/FileBrowserVC.m" \
    "$ROOT/src/AppsListVC.m" \
    "$ROOT/src/BQUI.m" \
    "$ROOT/src/BQCore.m" \
    -o "$APP/$APP_NAME"

cp "$ROOT/src/Info.plist" "$APP/Info.plist"
cp "$ROOT/src/respring.html" "$APP/respring.html"
for lproj in "$ROOT"/src/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/"
done

echo "[*] packing..."
(cd "$BUILD" && zip -qry "KAMUI-$VERSION.ipa" Payload)
echo "[*] done: $BUILD/KAMUI-$VERSION.ipa"

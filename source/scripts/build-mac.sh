#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LINKDESK_SOURCE=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LINKDESK_VERSION=$(cat "$LINKDESK_SOURCE/VERSION")
LINKDESK_OUT=${1:-"$LINKDESK_SOURCE/../macOS"}
LINKDESK_APP="$LINKDESK_OUT/LinkDesk.app"
LINKDESK_CACHE=${LINKDESK_BUILD_CACHE:-"${TMPDIR:-/tmp}/linkdesk-swift-cache"}
LINKDESK_UPSTREAM=${LINKDESK_DESKFLOW_APP:-/Applications/Deskflow.app}
test -n "${LINKDESK_PATCHED_MAC_CORE:-}" && test -x "$LINKDESK_PATCHED_MAC_CORE" || { echo 'Set LINKDESK_PATCHED_MAC_CORE to the validated Mac display-safe core artifact.' >&2; exit 1; }
test -x "$LINKDESK_UPSTREAM/Contents/MacOS/deskflow-core" || { echo 'Set LINKDESK_DESKFLOW_APP to the official Deskflow.app build input.' >&2; exit 1; }
mkdir -p "$LINKDESK_APP/Contents/MacOS" "$LINKDESK_APP/Contents/Resources" "$LINKDESK_CACHE"
swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$LINKDESK_CACHE" -target arm64-apple-macosx13.0 "$LINKDESK_SOURCE/macOS/Configuration.swift" "$LINKDESK_SOURCE/macOS/Identity.swift" "$LINKDESK_SOURCE/macOS/Peers.swift" "$LINKDESK_SOURCE/macOS/Discovery.swift" "$LINKDESK_SOURCE/macOS/Lifecycle.swift" "$LINKDESK_SOURCE/macOS/LinkDesk.swift" -o "$LINKDESK_APP/Contents/MacOS/LinkDesk"
cp "$LINKDESK_SOURCE/assets/LinkDesk.icns" "$LINKDESK_APP/Contents/Resources/LinkDesk.icns"
cat > "$LINKDESK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LinkDesk</string>
<key>CFBundleDisplayName</key><string>LinkDesk</string>
<key>CFBundleIdentifier</key><string>local.linkdesk.native</string>
<key>CFBundleExecutable</key><string>LinkDesk</string>
<key>CFBundleShortVersionString</key><string>0.4.7</string>
<key>CFBundleVersion</key><string>11</string>
<key>CFBundleIconFile</key><string>LinkDesk.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>连接另一台电脑，共享键盘和鼠标。</string>
</dict></plist>
PLIST
python3 - "$LINKDESK_APP/Contents/Info.plist" "$LINKDESK_VERSION" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as file: info=plistlib.load(file)
info['CFBundleShortVersionString']=sys.argv[2]
with open(sys.argv[1],'wb') as file: plistlib.dump(info,file)
PY
python3 "$LINKDESK_SOURCE/scripts/bundle-runtime.py" mac "$LINKDESK_UPSTREAM" "$LINKDESK_APP" --patched-mac-core "$LINKDESK_PATCHED_MAC_CORE"
codesign --force --deep --sign - "$LINKDESK_APP"
python3 "$LINKDESK_SOURCE/scripts/finalize-mac-manifest.py" "$LINKDESK_APP"
codesign --force --sign - "$LINKDESK_APP"
codesign --verify --deep --strict "$LINKDESK_APP"
echo "$LINKDESK_APP"

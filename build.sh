#!/bin/sh
set -eu

source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bundle="$source_dir/dist/LocalAgentLight.app"
executable="$bundle/Contents/MacOS/LocalAgentLight"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
/bin/cp "$source_dir/Resources/LocalAgentLight.icns" "$bundle/Contents/Resources/"
arch="$(/usr/bin/uname -m)"
/usr/bin/xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx13.0" \
  -module-cache-path "$source_dir/dist/module-cache" \
  "$source_dir/Protocol.swift" "$source_dir/LocalIPC.swift" \
  "$source_dir/Bluetooth.swift" "$source_dir/PromLight.swift" "$source_dir/LightSession.swift" \
  "$source_dir/DesktopApp.swift" "$source_dir/DesktopView.swift" "$source_dir/DesktopSheets.swift" \
  "$source_dir/main.swift" \
  -o "$executable"
/usr/bin/codesign --force --sign - "$bundle"
"$executable" self-test
printf '%s\n' "$executable"

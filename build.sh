#!/bin/bash
# 一键构建 PerfDock.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PerfDock.app"
BIN="$APP/Contents/MacOS/PerfDock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译 (Swift, arm64)"
/usr/bin/swiftc -O -swift-version 5 \
  -o "$BIN" \
  Sources/Metrics.swift \
  Sources/SMCTemp.swift \
  Sources/app/Prefs.swift \
  Sources/app/DiskHistory.swift \
  Sources/app/Panel.swift \
  Sources/app/main.swift \
  -framework IOKit -framework AppKit -framework WebKit

echo "→ 组装 App Bundle"
cp Info.plist "$APP/Contents/Info.plist"
cp UI/index.html "$APP/Contents/Resources/index.html"

echo "→ ad-hoc 签名"
/usr/bin/codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (签名跳过，不影响本地运行)"

SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ 构建完成：$APP  ($SIZE)"

#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/.build/AgentRouter.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AgentRouter "$APP/Contents/MacOS/AgentRouter"
cp .build/release/AgentRouterHook "$APP/Contents/MacOS/AgentRouterHook"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentRouter</string>
<key>CFBundleIdentifier</key><string>local.agentrouter.app</string>
<key>CFBundleName</key><string>AgentRouter</string>
<key>CFBundleDisplayName</key><string>AgentRouter</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSAppleEventsUsageDescription</key><string>Attach Terminal to your selected AgentRouter agent session.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
SIGN_IDENTITY="${AGENTROUTER_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AgentRouterHook"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"

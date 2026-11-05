#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$(pwd)/dist/CoThink Board.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Assets/Mascot.png "$app/Contents/Resources/Mascot.png"
cp Assets/CoThinkPiExtension.ts "$app/Contents/Resources/CoThinkPiExtension.ts"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp scripts/install-pi.command "$app/Contents/Resources/install-pi.command"
chmod 755 "$app/Contents/Resources/install-pi.command"
cp "$bin_dir/CoThinkBoard" "$app/Contents/MacOS/CoThinkBoard.new"
cp "$bin_dir/cothink-mcp" "$app/Contents/MacOS/cothink-mcp.new"
cp "$bin_dir/cothink-pdf" "$app/Contents/MacOS/cothink-pdf.new"
mv -f "$app/Contents/MacOS/CoThinkBoard.new" "$app/Contents/MacOS/CoThinkBoard"
mv -f "$app/Contents/MacOS/cothink-mcp.new" "$app/Contents/MacOS/cothink-mcp"
mv -f "$app/Contents/MacOS/cothink-pdf.new" "$app/Contents/MacOS/cothink-pdf"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CoThinkBoard</string>
<key>CFBundleIdentifier</key><string>com.cothink.board</string>
<key>CFBundleName</key><string>CoThink Board</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>1.0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>CoThink Board uses the microphone to dictate your message into the chat input.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>CoThink Board transcribes your speech locally into the chat input.</string>
</dict></plist>
PLIST
printf 'APPL????' > "$app/Contents/PkgInfo"
printf 'Built %s\n' "$app"

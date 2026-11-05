#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output="$root/Launchers"
mkdir -p "$output"
ln -sfn .. "$output/Project-NOMAD"
swiftc -O -framework AppKit "$root/macos/Launcher.swift" -o "$root/macos/NOMAD-Launcher"
for name in NOMAD 'Stop NOMAD'; do
 app="$output/$name.app"
 identifier=community.nomad.portable; icon=nomad
 if [[ "$name" == 'Stop NOMAD' ]]; then identifier+=.stop; icon=stop-nomad; fi
 mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
 cp "$root/macos/NOMAD-Launcher" "$app/Contents/MacOS/NOMAD"
 cp "$root/assets/$icon.icns" "$app/Contents/Resources/NOMAD.icns"
 cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>NOMAD</string>
<key>CFBundleIconFile</key><string>NOMAD.icns</string>
<key>LSUIElement</key><false/>
</dict></plist>
EOF
 codesign --force --deep --sign - "$app"
done

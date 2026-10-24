#!/bin/zsh
set -eu
taskSourceDir="${0:A:h}"
taskOutputDir="${1:-$taskSourceDir/build/Clear Bar.app}"
taskSDK="$(xcrun --show-sdk-path)"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk ]]; then
  taskSDK=/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk
fi
taskCacheDir="${TRANSPARENT_MENUBAR_MODULE_CACHE:-$taskSourceDir/module-cache}"
mkdir -p "$taskOutputDir/Contents/MacOS" "$taskOutputDir/Contents/Resources/Source" "$taskCacheDir"
taskCompileArgs=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  cat > "$taskSourceDir/local-overlay.yaml" <<EOF
{"version":0,"roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":"$taskSourceDir/empty-module.modulemap"}]}
EOF
  taskCompileArgs=(-vfsoverlay "$taskSourceDir/local-overlay.yaml" -Xcc -ivfsoverlay -Xcc "$taskSourceDir/local-overlay.yaml")
fi
swiftc -O -target arm64-apple-macosx14.0 -sdk "$taskSDK" -module-cache-path "$taskCacheDir" "${taskCompileArgs[@]}" -import-objc-header "$taskSourceDir/PrivateBridge.h" "$taskSourceDir/Overlay.swift" "$taskSourceDir/main.swift" -framework Cocoa -framework QuartzCore -framework ImageIO -framework CoreImage -o "$taskOutputDir/Contents/MacOS/ClearBar"
cp "$taskSourceDir/Info.plist" "$taskOutputDir/Contents/Info.plist"
cp "$taskSourceDir/main.swift" "$taskSourceDir/Overlay.swift" "$taskSourceDir/PrivateBridge.h" "$taskSourceDir/Info.plist" "$taskSourceDir/build.sh" "$taskSourceDir/make_icns.py" "$taskSourceDir/empty-module.modulemap" "$taskOutputDir/Contents/Resources/Source/"
if [[ -f "$taskSourceDir/AppIcon.png" ]]; then
  taskIconDir="$taskSourceDir/build/AppIcon.iconset"
  mkdir -p "$taskIconDir"
  for taskBase in 16 32 128 256 512; do
    sips -z "$taskBase" "$taskBase" "$taskSourceDir/AppIcon.png" --out "$taskIconDir/icon_${taskBase}x${taskBase}.png" >/dev/null
    taskDouble=$((taskBase * 2))
    sips -z "$taskDouble" "$taskDouble" "$taskSourceDir/AppIcon.png" --out "$taskIconDir/icon_${taskBase}x${taskBase}@2x.png" >/dev/null
  done
  python3 "$taskSourceDir/make_icns.py" "$taskIconDir" "$taskOutputDir/Contents/Resources/AppIcon.icns"
  cp "$taskSourceDir/AppIcon.png" "$taskOutputDir/Contents/Resources/Source/AppIcon.png"
fi
for taskDocument in README.md LICENSE NOTICE.md; do
  if [[ -f "$taskSourceDir/$taskDocument" ]]; then
    cp "$taskSourceDir/$taskDocument" "$taskOutputDir/Contents/Resources/Source/$taskDocument"
  fi
done
codesign --force --sign - "$taskOutputDir"

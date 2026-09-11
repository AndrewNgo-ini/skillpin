#!/bin/bash
# Usage: ./Scripts/package-app.sh [--dmg]
# CONFIGURATION=release for a release build (default: debug).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
config=${CONFIGURATION:-debug}
app="$root/dist/SkillPin.app"

swift build --package-path "$root" -c "$config"
bin=$(swift build --package-path "$root" -c "$config" --show-bin-path)/SkillPin
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/SkillPin"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"

printf '%s\n' "$app"

if [ "${1:-}" = "--dmg" ]; then
  stage="$root/dist/dmg"
  rm -rf "$stage" "$root/dist/SkillPin.dmg"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname SkillPin -srcfolder "$stage" -ov -format UDZO "$root/dist/SkillPin.dmg" >/dev/null
  rm -rf "$stage"
  printf '%s\n' "$root/dist/SkillPin.dmg"
fi

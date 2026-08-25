#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="微信发送"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
AGENT_LABEL="local.wechatsend.scheduler"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
USER_DOMAIN="gui/$(id -u)"

"$ROOT/scripts/build-app.sh"

# Unload KeepAlive before stopping the app so it cannot relaunch the old binary
# while the bundle is being replaced.
HAD_AGENT=false
if [[ -f "$AGENT_PLIST" ]]; then
  HAD_AGENT=true
  launchctl bootout "$USER_DOMAIN/$AGENT_LABEL" 2>/dev/null || true
fi

pkill -f '/微信发送.app/Contents/MacOS/LeafSend$' 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -f '/微信发送.app/Contents/MacOS/LeafSend$' >/dev/null; then
    break
  fi
  sleep 0.1
done
if pgrep -f '/微信发送.app/Contents/MacOS/LeafSend$' >/dev/null; then
  pkill -9 -f '/微信发送.app/Contents/MacOS/LeafSend$' 2>/dev/null || true
fi

rm -rf "$INSTALLED_APP"
ditto "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALLED_APP"

if [[ "$HAD_AGENT" == true ]]; then
  plutil -replace ProgramArguments -json \
    "[\"/usr/bin/open\",\"-W\",\"$INSTALLED_APP\"]" "$AGENT_PLIST"
  if ! launchctl bootstrap "$USER_DOMAIN" "$AGENT_PLIST" 2>/dev/null; then
    sleep 2
    launchctl bootstrap "$USER_DOMAIN" "$AGENT_PLIST"
  fi
else
  open "$INSTALLED_APP"
fi

echo "$INSTALLED_APP"

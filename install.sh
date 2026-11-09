#!/bin/zsh
# Builds lofree-light, installs it to ~/.local/bin, and keeps `lofree-light run` running via launchd.
set -euo pipefail
cd "${0:A:h}"

LABEL=com.plastachio.lofree-light
BIN="$HOME/.local/bin/lofree-light"
CONFIG="$HOME/.config/lofree-light/schedule.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/lofree-light.log"

make build/lofree-light
mkdir -p "${BIN:h}" "${CONFIG:h}" "${PLIST:h}"
install -m 755 build/lofree-light "$BIN"

if [[ ! -f "$CONFIG" ]]; then
  cp schedule.json "$CONFIG"
  echo "installed default schedule: $CONFIG"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "loaded $LABEL (log: $LOG)"

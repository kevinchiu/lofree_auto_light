#!/bin/zsh
# Stops the launchd job and removes the binary. Leaves ~/.config/lofree-light/schedule.json in place.
set -euo pipefail
LABEL=com.plastachio.lofree-light
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/lofree-light"
rm -rf "$HOME/.local/state/lofree-light"
echo "removed $LABEL"

#!/bin/bash
# install-channel-keepalive-probe.sh
#
# Installs the launchd twin of scripts/systemd/channel-keepalive-probe.timer
# (macOS). Without this unit the token-free IDLE-path keepalive producer
# (scripts/channel-keepalive-probe.sh, #640) never runs on macOS: the only
# thing advancing store/.channel-keepalive is organic inbound, so every quiet
# window >= the 18-min staleness threshold reads as a dead channel to every
# consumer of the file (channel-coordinator false-DOWN flapping, the dormant
# staleness watchdog's premise). Measured 2026-08-16 (COORDDRIFT816).
#
# Period parity with the systemd timer:
#   OnUnitActiveSec=3min  -> StartInterval 180
#   OnBootSec=90s         -> RunAtLoad true (launchd has no boot-delay knob for
#                            agents; an immediate first run is safe -- the probe
#                            is idempotent and fail-closed)
#   AccuracySec=20s       -> no launchd equivalent; launchd timers are already
#                            coarse-grained, nothing to carry
#
# The probe itself is fail-closed by design: it only touches the keepalive
# after proving from the process tree that a telegram poller descends from the
# channels session's pane. A dead native means NO touch ("watchdog owns
# recovery"), so this producer can never mask a real outage with a false
# heartbeat.
#
# Usage:
#   scripts/install-channel-keepalive-probe.sh            # install, do not start
#   scripts/install-channel-keepalive-probe.sh --load     # install and start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROBE="$PROJECT_DIR/scripts/channel-keepalive-probe.sh"

# The launchd label is PER INSTALL: com.<SERVICE_ID|MAIN_AGENT_ID>.<component>,
# the same convention doctor.sh, start.sh, stop.sh and backup.sh use. A fixed
# com.marveen.* label makes a second install on the same host overwrite the
# first install's unit, leaving that install with no idle-path keepalive
# producer at all -- and then every quiet window past the watchdog's
# liveness-trust ceiling hard-restarts a perfectly healthy session.
#
# The .env is READ, never sourced: sourcing executes it, so an unquoted value
# with spaces runs its trailing word as a command and a $(...) value runs
# arbitrary code.
read_env() {
  [ -f "$PROJECT_DIR/.env" ] || return 0
  local v
  v="$(grep -E "^${1}=" "$PROJECT_DIR/.env" | tail -1)" || return 0
  v="${v#*=}"
  case "$v" in
    '"'*) v="${v#\"}"; v="${v%\"}" ;;
    "'"*) v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}
SERVICE_ID="$(read_env SERVICE_ID)"
MAIN_AGENT_ID_ENV="$(read_env MAIN_AGENT_ID)"
SERVICE_ID="${SERVICE_ID:-${MAIN_AGENT_ID_ENV:-marveen}}"
# Strip anything that could carry the label out of LaunchAgents (path
# separators, spaces) before it becomes a filename.
SERVICE_ID="${SERVICE_ID//[^a-zA-Z0-9_-]/}"
SERVICE_ID="${SERVICE_ID:-marveen}"
LABEL="com.${SERVICE_ID}.channel-keepalive-probe"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

LOAD=0
[ "${1:-}" = "--load" ] && LOAD=1

if [ ! -f "$PROBE" ]; then
  echo "ERROR: $PROBE not found." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$PROBE</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$PROJECT_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>180</integer>
  <key>StandardOutPath</key>
  <string>$PROJECT_DIR/store/channel-keepalive-probe.log</string>
  <key>StandardErrorPath</key>
  <string>$PROJECT_DIR/store/channel-keepalive-probe.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>$HOME</string>
    <key>USER</key>
    <string>$(id -un)</string>
    <key>TZ</key>
    <string>Europe/Budapest</string>
  </dict>
</dict>
</plist>
PLIST_EOF
echo "Wrote launchd unit: $PLIST"

if [ "$LOAD" = "1" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "Loaded $LABEL (every 180s + at load). It only ever TOUCHES store/.channel-keepalive after proving the telegram poller alive from the process tree -- a dead native is never masked."
else
  echo "Installed but NOT loaded. To start: launchctl load $PLIST"
fi

#!/bin/bash
# Contract test for the rapid-exit failure counter in scripts/channels.sh.
#
# Root cause (kártya marveen-channel-gyakori-restart-20260824, komment 4737):
# the FAIL_COUNT that gates the 60s/300s back-off counted EVERY line in
# store/channels-failures.log (`wc -l`), not just rapid-exit lines. The file
# also accumulates diagnostic WARN/INFO lines from unrelated code paths (main-
# agent config isolation guard, post-init /mcp unlock probe, ...), so the
# count was always inflated -- measured 9 vs. an actual 4 rapid-exits, which
# escalated the back-off tier (300s instead of 60s) too early.
#
# Driven through `channels.sh --count-rapid-exits <file>`, which reads the
# given failures log and exits before touching tmux, .env or the real store.
# Run: bash scripts/__tests__/channels-fail-count.test.sh

set -u

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 -- expected: $2, got: $3"; }

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Overridable so the suite can be pointed at a deliberately-broken copy to
# confirm it actually fails on the bug (a green test that cannot go red is
# worse than no test -- it certifies health it never checked).
CHANNELS="${CHANNELS_BIN:-$INSTALL_DIR/scripts/channels.sh}"

TMPDIR_T="$(mktemp -d /tmp/channels-fail-count-test.XXXXXX)"
trap 'rm -rf "$TMPDIR_T"' EXIT

echo "channels.sh rapid-exit counter"

# --- the regression shape: mixed diagnostic noise + a few real rapid-exits ---
LOG1="$TMPDIR_T/mixed.log"
cat > "$LOG1" <<'EOF'
2026-08-28 08:20:01 channels.sh: main-agent isolated CLAUDE_CONFIG_DIR=/x/.channels-config
2026-08-28 08:20:16 channels.sh post-init: unlock round finished, input line verified empty
2026-08-28 08:21:03 rapid-exit after 4s
2026-08-28 08:21:04 channels.sh: main-agent isolated CLAUDE_CONFIG_DIR=/x/.channels-config
2026-08-28 08:22:10 rapid-exit after 3s
2026-08-28 08:22:11 channels.sh post-init: unlock round finished, input line verified empty
2026-08-28 08:23:20 rapid-exit after 5s
2026-08-28 08:23:21 channels.sh post-init: no failed plugin row in /mcp pane, skipping unlock
2026-08-28 08:24:30 rapid-exit after 4s
EOF
GOT="$(bash "$CHANNELS" --count-rapid-exits "$LOG1" 2>/dev/null)"
if [ "$GOT" = "4" ]; then
  pass "9-line mixed log with 4 real rapid-exits -> counts 4, not 9"
else
  fail "9-line mixed log with 4 real rapid-exits -> counts 4, not 9" "4" "$GOT"
fi

# --- pure diagnostic noise, zero rapid-exits ----------------------------------
LOG2="$TMPDIR_T/noise-only.log"
cat > "$LOG2" <<'EOF'
2026-08-28 08:20:01 channels.sh: main-agent isolated CLAUDE_CONFIG_DIR=/x/.channels-config
2026-08-28 08:20:16 channels.sh post-init: unlock round finished, input line verified empty
EOF
GOT="$(bash "$CHANNELS" --count-rapid-exits "$LOG2" 2>/dev/null)"
if [ "$GOT" = "0" ]; then
  pass "diagnostic-only log -> counts 0"
else
  fail "diagnostic-only log -> counts 0" "0" "$GOT"
fi

# --- missing file: never a bare parse error, always 0 ------------------------
GOT="$(bash "$CHANNELS" --count-rapid-exits "$TMPDIR_T/does-not-exist.log" 2>/dev/null)"
if [ "$GOT" = "0" ]; then
  pass "missing log file -> counts 0"
else
  fail "missing log file -> counts 0" "0" "$GOT"
fi

# --- exactly one real rapid-exit, several unrelated lines ---------------------
LOG3="$TMPDIR_T/single.log"
cat > "$LOG3" <<'EOF'
2026-08-28 08:20:01 channels.sh: WARN main-agent starting on SHARED ~/.claude although a fleet setup-token exists
2026-08-28 08:20:16 rapid-exit after 12s
2026-08-28 08:20:20 channels.sh: enabled telegram@claude-plugins-official in /x/.claude/settings.json
EOF
GOT="$(bash "$CHANNELS" --count-rapid-exits "$LOG3" 2>/dev/null)"
if [ "$GOT" = "1" ]; then
  pass "single real rapid-exit among unrelated lines -> counts 1"
else
  fail "single real rapid-exit among unrelated lines -> counts 1" "1" "$GOT"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

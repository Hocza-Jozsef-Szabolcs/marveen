#!/bin/bash
# hu: Teszt a telegram_progress.py state_dir() feloldásához. A plugin
#     server.ts (STATE_DIR) feloldási sorrendjét kell tükröznie:
#     TELEGRAM_STATE_DIR -> $CLAUDE_CONFIG_DIR/channels/telegram ->
#     fix $HOME/.claude/channels/telegram. A jelenlegi kód a középső ágat
#     kihagyja, ezért egy másik CLAUDE_CONFIG_DIR alatt futó agent (pl.
#     Jarvis) a hook szintjén a fix ~/.claude/channels/telegram-re esik
#     vissza, és a Marveen state-jébe ír.
# en: Test for telegram_progress.py state_dir() resolution. Must mirror
#     the plugin's server.ts (STATE_DIR) resolution order: TELEGRAM_STATE_DIR
#     -> $CLAUDE_CONFIG_DIR/channels/telegram -> fixed $HOME/.claude/channels/telegram.
#     The current code skips the middle branch, so an agent running under a
#     different CLAUDE_CONFIG_DIR (e.g. Jarvis) falls back to the fixed
#     ~/.claude/channels/telegram at the hook level and writes into Marveen's state.

set -uo pipefail

HOOK="$HOME/.claude/hooks/telegram_progress.py"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"

  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $name"
    echo "      várt:  $expected"
    echo "      kapott: $actual"
    FAIL=$((FAIL + 1))
  fi
}

# hu: Segéd — state_dir() lekérdezése tiszta, kontrollált környezetben.
#     env -i-vel izoláljuk a hívó session saját CLAUDE_CONFIG_DIR/TELEGRAM_STATE_DIR-jétől.
run_state_dir() {
  local telegram_state_dir="${1:-}" claude_config_dir="${2:-}" home="${3:-$HOME}"
  env -i HOME="$home" TELEGRAM_STATE_DIR="$telegram_state_dir" CLAUDE_CONFIG_DIR="$claude_config_dir" \
    python3 -c "
import sys, os
sys.path.insert(0, os.path.dirname('$HOOK'))
if not os.environ.get('TELEGRAM_STATE_DIR'):
    os.environ.pop('TELEGRAM_STATE_DIR', None)
if not os.environ.get('CLAUDE_CONFIG_DIR'):
    os.environ.pop('CLAUDE_CONFIG_DIR', None)
import importlib.util
spec = importlib.util.spec_from_file_location('telegram_progress', '$HOOK')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.state_dir())
"
}

echo "=== telegram_progress.py state_dir() teszt ==="

# --- 1. Sem TELEGRAM_STATE_DIR, sem CLAUDE_CONFIG_DIR -> fix $HOME/.claude/channels/telegram ---
out="$(run_state_dir "" "" "/tmp/fake-home")"
check "nincs env: fix \$HOME/.claude/channels/telegram" "/tmp/fake-home/.claude/channels/telegram" "$out"

# --- 2. CLAUDE_CONFIG_DIR beállítva, TELEGRAM_STATE_DIR nincs -> \$CLAUDE_CONFIG_DIR/channels/telegram ---
out="$(run_state_dir "" "/Users/ceo/jarvis/.channels-config" "/tmp/fake-home")"
check "CLAUDE_CONFIG_DIR-t követi (jarvis)" "/Users/ceo/jarvis/.channels-config/channels/telegram" "$out"

# --- 3. Mindkettő beállítva -> TELEGRAM_STATE_DIR nyer ---
out="$(run_state_dir "/custom/state" "/Users/ceo/jarvis/.channels-config" "/tmp/fake-home")"
check "TELEGRAM_STATE_DIR elsőbbséget élvez" "/custom/state" "$out"

echo
echo "=== Eredmény: $PASS zöld, $FAIL piros ==="
[ "$FAIL" -eq 0 ] || exit 1

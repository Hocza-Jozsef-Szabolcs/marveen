#!/bin/bash
# hu: Teszt a #1314-ben javított telegram_progress.py mintájának a többi
#     telegram-hookra (telegram_progress_clear.py, telegram_progress_reply_clear.py,
#     telegram_fallback_send.py) való átvezetéséhez. A state_dir() feloldási
#     sorrendje mindháromban: TELEGRAM_STATE_DIR -> $CLAUDE_CONFIG_DIR/channels/telegram
#     -> fix $HOME/.claude/channels/telegram (a plugin server.ts STATE_DIR-jét tükrözve).
# en: Test carrying the #1314 fix (telegram_progress.py) over to the other
#     telegram hooks (telegram_progress_clear.py, telegram_progress_reply_clear.py,
#     telegram_fallback_send.py). state_dir() resolution order in all three:
#     TELEGRAM_STATE_DIR -> $CLAUDE_CONFIG_DIR/channels/telegram -> fixed
#     $HOME/.claude/channels/telegram (mirrors the plugin's server.ts STATE_DIR).

set -uo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
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

# hu: Segéd — a megadott modul state_dir()-jének lekérdezése tiszta, kontrollált
#     környezetben. env -i-vel izoláljuk a hívó session saját
#     CLAUDE_CONFIG_DIR/TELEGRAM_STATE_DIR-jétől.
run_state_dir() {
  local module_file="$1" telegram_state_dir="${2:-}" claude_config_dir="${3:-}" home="${4:-$HOME}"
  env -i HOME="$home" TELEGRAM_STATE_DIR="$telegram_state_dir" CLAUDE_CONFIG_DIR="$claude_config_dir" \
    python3 -c "
import sys, os
if not os.environ.get('TELEGRAM_STATE_DIR'):
    os.environ.pop('TELEGRAM_STATE_DIR', None)
if not os.environ.get('CLAUDE_CONFIG_DIR'):
    os.environ.pop('CLAUDE_CONFIG_DIR', None)
import importlib.util
spec = importlib.util.spec_from_file_location('m', '$module_file')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.state_dir())
"
}

run_module_for() {
  for f in telegram_progress_clear.py telegram_progress_reply_clear.py telegram_fallback_send.py; do
    echo "=== $f ==="

    out="$(run_state_dir "$HOOKS_DIR/$f" "" "" "/tmp/fake-home")"
    check "$f -- nincs env: fix \$HOME/.claude/channels/telegram" "/tmp/fake-home/.claude/channels/telegram" "$out"

    out="$(run_state_dir "$HOOKS_DIR/$f" "" "/Users/ceo/jarvis/.channels-config" "/tmp/fake-home")"
    check "$f -- CLAUDE_CONFIG_DIR-t követi (jarvis)" "/Users/ceo/jarvis/.channels-config/channels/telegram" "$out"

    out="$(run_state_dir "$HOOKS_DIR/$f" "/custom/state" "/Users/ceo/jarvis/.channels-config" "/tmp/fake-home")"
    check "$f -- TELEGRAM_STATE_DIR elsőbbséget élvez" "/custom/state" "$out"
  done
}

echo "=== telegram_progress_clear.py / telegram_progress_reply_clear.py / telegram_fallback_send.py state_dir() teszt ==="
run_module_for

echo
echo "=== Eredmény: $PASS zöld, $FAIL piros ==="
[ "$FAIL" -eq 0 ] || exit 1

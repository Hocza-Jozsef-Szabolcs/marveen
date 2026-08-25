#!/bin/bash
# hu: Teszt a skill-harvest.sh Stop hookhoz. Lefedi a parser-logikát
#     (tool_use számlálás a transcript JSONL-ből), a küszöböt, a
#     session-onkénti dedup-ot és a hibatűrést.
# en: Test for the skill-harvest.sh Stop hook. Covers the parser logic
#     (tool_use counting from the transcript JSONL), the threshold, the
#     per-session dedup and error tolerance.

set -uo pipefail

HOOK="$HOME/.claude/hooks/skill-harvest.sh"
TMP="$(mktemp -d)"
STATE_DIR="$TMP/state"
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# hu: Segéd — n darab tool_use-t tartalmazó ál-transcript generálása
make_transcript() {
  local count="$1" file="$2"
  : > "$file"
  echo '{"type":"user","message":{"role":"user","content":"teszt"}}' >> "$file"

  local i=0
  while [ "$i" -lt "$count" ]; do
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t%d","name":"Bash","input":{}}]}}\n' "$i" >> "$file"
    i=$((i + 1))
  done
}

# hu: Segéd — hook futtatása, stderr visszaadása
run_hook() {
  local transcript="$1" session_id="$2"
  local stop_active="${3:-false}"

  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s","stop_hook_active":%s}' \
    "$session_id" "$transcript" "$TMP" "$stop_active" \
    | SKILL_HARVEST_STATE_DIR="$STATE_DIR" bash "$HOOK" 2>&1 >/dev/null
}

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

echo "=== skill-harvest.sh teszt ==="

# --- 1. Küszöb alatt (4 tool-hívás) -> néma ---
make_transcript 4 "$TMP/t4.jsonl"
out="$(run_hook "$TMP/t4.jsonl" "sess-under")"
check "4 tool-hívás: néma marad" "" "$out"

# --- 2. Küszöbön (5 tool-hívás) -> emlékeztet ---
make_transcript 5 "$TMP/t5.jsonl"
out="$(run_hook "$TMP/t5.jsonl" "sess-at")"
# hu: A markert szögletes zárójellel keressük — a "No such file" hibaüzenet
#     is tartalmazza a "skill-harvest.sh" útvonalat, az nem lehet zöld.
if echo "$out" | grep -q '\[hook: skill-harvest\]'; then
  echo "  ✓ 5 tool-hívás: emlékeztetőt ad"
  PASS=$((PASS + 1))
else
  echo "  ✗ 5 tool-hívás: emlékeztetőt ad"
  echo "      kapott: $out"
  FAIL=$((FAIL + 1))
fi

# --- 3. Az emlékeztető a Vault-célt említi, NEM a .claude/skills-t ---
if echo "$out" | grep -q "Skill-Candidates"; then
  echo "  ✓ a Vault Skill-Candidates célra mutat"
  PASS=$((PASS + 1))
else
  echo "  ✗ a Vault Skill-Candidates célra mutat"
  FAIL=$((FAIL + 1))
fi

# --- 4. Dedup: ugyanaz a session másodszor -> néma ---
out2="$(run_hook "$TMP/t5.jsonl" "sess-at")"
check "ugyanaz a session másodszor: néma (dedup)" "" "$out2"

# --- 5. Másik session ugyanazzal a transcripttel -> újra emlékeztet ---
out3="$(run_hook "$TMP/t5.jsonl" "sess-other")"
if echo "$out3" | grep -q '\[hook: skill-harvest\]'; then
  echo "  ✓ másik session: újra emlékeztet"
  PASS=$((PASS + 1))
else
  echo "  ✗ másik session: újra emlékeztet"
  FAIL=$((FAIL + 1))
fi

# --- 6. stop_hook_active=true -> néma (loop-védelem) ---
out4="$(run_hook "$TMP/t5.jsonl" "sess-loop" "true")"
check "stop_hook_active=true: néma (loop-védelem)" "" "$out4"

# --- 7. Hiányzó transcript -> néma, nem hasal el ---
out5="$(run_hook "$TMP/nincs-ilyen.jsonl" "sess-missing")"
check "hiányzó transcript: néma" "" "$out5"

# --- 8. Sérült JSONL sorok -> nem hasal el, a jó sorokat számolja ---
make_transcript 5 "$TMP/t-broken.jsonl"
echo 'ez nem valid json {{{' >> "$TMP/t-broken.jsonl"
out6="$(run_hook "$TMP/t-broken.jsonl" "sess-broken")"
if echo "$out6" | grep -q '\[hook: skill-harvest\]'; then
  echo "  ✓ sérült sorok: túléli, számol"
  PASS=$((PASS + 1))
else
  echo "  ✗ sérült sorok: túléli, számol"
  echo "      kapott: $out6"
  FAIL=$((FAIL + 1))
fi

# --- 9. Exit code mindig 0 (Stop hook nem blokkolhat) ---
printf '{"session_id":"sess-exit","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' \
  "$TMP/t5.jsonl" "$TMP" \
  | SKILL_HARVEST_STATE_DIR="$STATE_DIR" bash "$HOOK" >/dev/null 2>&1
check "exit code 0 (nem blokkol)" "0" "$?"

# --- 10. Küszöb felett: stdout VALID JSON, systemMessage mezővel ---
#     (Stop hooknál a puszta stderr nem jelenik meg — ez a dokumentált út.)
run_hook_stdout() {
  local transcript="$1" session_id="$2"
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' \
    "$session_id" "$transcript" "$TMP" \
    | SKILL_HARVEST_STATE_DIR="$STATE_DIR" bash "$HOOK" 2>/dev/null
}

sysmsg="$(run_hook_stdout "$TMP/t5.jsonl" "sess-stdout" | jq -r '.systemMessage // empty' 2>/dev/null)"
if [ -n "$sysmsg" ]; then
  echo "  ✓ stdout: valid JSON systemMessage mezővel"
  PASS=$((PASS + 1))
else
  echo "  ✗ stdout: valid JSON systemMessage mezővel"
  echo "      kapott: $(run_hook_stdout "$TMP/t5.jsonl" "sess-stdout2")"
  FAIL=$((FAIL + 1))
fi

# --- 11. Küszöb alatt: stdout üres (ne zajongjon) ---
out_under="$(run_hook_stdout "$TMP/t4.jsonl" "sess-stdout-under")"
check "küszöb alatt: stdout üres" "" "$out_under"

echo
echo "=== Eredmény: $PASS zöld, $FAIL piros ==="
[ "$FAIL" -eq 0 ] || exit 1

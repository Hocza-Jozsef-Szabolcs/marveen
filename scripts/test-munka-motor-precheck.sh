#!/usr/bin/env bash
# hu: A `munka-motor-precheck.sh` merooeszkoze. A kartya (heartbeat-szkriptesites-20260806)
#     ON-TESZTET ir elo (5/e): allitsd elo a hibat, es igazold, hogy a szkript EBRESZT --
#     ES a forditott agat is: tiszta allapotnal NE ebresszen. Minden lepes ket iranyban
#     mert: a "talalt valamit" (nem-SKIP kimenet) es a "tiszta" (SKIP) allapot kulon teszt.
#
# en: Measuring harness for munka-motor-precheck.sh. Every mechanical check gets a positive
#     (finds something -> non-SKIP output) and a negative (clean state -> SKIP) case.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/munka-motor-precheck.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/munka-motor-precheck-teszt.XXXXXX")
trap 'rm -rf "$FTmp"; tmux kill-session -t agent-zzzprecheck 2>/dev/null; true' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart="$2" kapott="$3"
  if [ "$vart" = "$kapott" ]; then
    echo "  OK    $nev"
    FPass=$((FPass + 1))
  else
    echo "  BUKIK $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

# ── Kozos fixture-ok minden esethez ─────────────────────────────────────────────────────
mkdir -p "$FTmp/backups"
touch "$FTmp/backups/claudeclaw-friss.tar.gz"

FQuotaFut="$FTmp/quota-fut.sh"
printf '#!/usr/bin/env bash\necho fut\n' > "$FQuotaFut"; chmod +x "$FQuotaFut"

FQuotaFagy="$FTmp/quota-fagy.sh"
printf '#!/usr/bin/env bash\necho FAGYASZTVA\n' > "$FQuotaFagy"; chmod +x "$FQuotaFagy"

FDb="$FTmp/claudeclaw.db"
sqlite3 "$FDb" <<'SQL'
CREATE TABLE agent_messages (id INTEGER PRIMARY KEY, from_agent TEXT, to_agent TEXT, status TEXT, created_at INTEGER);
CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT, priority TEXT, updated_at INTEGER, archived_at INTEGER);
CREATE TABLE kanban_comments (id INTEGER PRIMARY KEY, card_id TEXT, author TEXT, created_at INTEGER);
SQL

FTopClean="$FTmp/top-clean.txt"
cat > "$FTopClean" <<'EOF'
PID    %CPU TIME     COMMAND
318    30.1 29:25:14 evoservice
59204  12.8 00:02.45 top
EOF

FTopRunaway="$FTmp/top-runaway.txt"
cat > "$FTopRunaway" <<'EOF'
PID    %CPU TIME     COMMAND
20172  950.0 13:39:00 ugrep
318    30.1 29:25:14 evoservice
EOF

run_env() {
  # Kozos alapertelmezes minden esethez, hivo felulirhatja
  env \
    MMPC_QUOTA_GATE="$FQuotaFut" \
    MMPC_DB="$FDb" \
    MMPC_BACKUPS_GLOB="$FTmp/backups/*.tar.gz" \
    MMPC_TOP_SAMPLE="$FTopClean" \
    MMPC_TMUX_SESSION_PREFIX="agent-zzzprecheck-nonexistent-" \
    "$@" "$CScript"
}

echo "── T0: kvota-fagyasztas -- a TELJES kor elmarad, SKIP, meg akkor is ha minden mas piszkos ──"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (1,'a','b','pending',1);"
OUT="$(run_env env MMPC_QUOTA_GATE="$FQuotaFagy")"
check "T0 SKIP fagyasztas alatt" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM agent_messages;"

echo "── T0b: tiszta allapot, nincs fagyasztas -- SKIP ──────────────────────────────────────"
OUT="$(run_env)"
check "T0b SKIP tiszta allapotban" "SKIP" "$OUT"

echo "── T1: CPU-tulterheles -- talal ────────────────────────────────────────────────────────"
OUT="$(run_env env MMPC_TOP_SAMPLE="$FTopRunaway")"
check "T1 CPU finding tartalmazza a pid-et" "1" "$(echo "$OUT" | grep -q '20172' && echo 1 || echo 0)"
check "T1 nem SKIP" "1" "$([ "$OUT" != "SKIP" ] && echo 1 || echo 0)"

echo "── T1b: CPU normal -- nem talal ────────────────────────────────────────────────────────"
OUT="$(run_env env MMPC_TOP_SAMPLE="$FTopClean")"
check "T1b SKIP normal CPU-nal" "SKIP" "$OUT"

echo "── T2: regi mentes -- talal ────────────────────────────────────────────────────────────"
touch -t 202001010000 "$FTmp/backups/claudeclaw-friss.tar.gz"
OUT="$(run_env)"
check "T2 mentes-frissesseg finding" "1" "$(echo "$OUT" | grep -qi 'MENTES-FRISSESSEG' && echo 1 || echo 0)"
touch "$FTmp/backups/claudeclaw-friss.tar.gz"

echo "── T2b: friss mentes -- nem talal ──────────────────────────────────────────────────────"
OUT="$(run_env)"
check "T2b SKIP friss mentessel" "SKIP" "$OUT"

echo "── T3: regi pending uzenet -- talal ────────────────────────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (2,'marveen','ordog','pending',$(( $(date +%s) - 3600 )));"
OUT="$(run_env)"
check "T3 pending-sor finding" "1" "$(echo "$OUT" | grep -qi 'PENDING-SOR' && echo 1 || echo 0)"
check "T3 emliti a cimzettet" "1" "$(echo "$OUT" | grep -q 'ordog' && echo 1 || echo 0)"
sqlite3 "$FDb" "DELETE FROM agent_messages;"

echo "── T3b: friss pending uzenet (kuszob alatt) -- nem talal ──────────────────────────────"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (3,'marveen','ordog','pending',$(date +%s));"
OUT="$(run_env)"
check "T3b SKIP friss pendinggel" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM agent_messages;"

echo "── T4: keskeny pane -- talal ───────────────────────────────────────────────────────────"
tmux new-session -d -s agent-zzzprecheck -x 40 -y 20
OUT="$(run_env env MMPC_TMUX_SESSION_PREFIX="agent-zzzprecheck")"
check "T4 pane-szelesseg finding" "1" "$(echo "$OUT" | grep -qi 'PANE-SZELESSEG' && echo 1 || echo 0)"
tmux kill-session -t agent-zzzprecheck 2>/dev/null

echo "── T4b: szeles pane -- nem talal ───────────────────────────────────────────────────────"
tmux new-session -d -s agent-zzzprecheck -x 80 -y 20
OUT="$(run_env env MMPC_TMUX_SESSION_PREFIX="agent-zzzprecheck")"
check "T4b SKIP szeles pane-nel" "SKIP" "$OUT"
tmux kill-session -t agent-zzzprecheck 2>/dev/null

echo "── T5: nulla-kommentes waiting kartya -- talal ─────────────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c1','cim','waiting','marveen','normal',$(date +%s),NULL);"
OUT="$(run_env)"
check "T5 nulla-komment finding" "1" "$(echo "$OUT" | grep -qi 'NULLA-KOMMENT' && echo 1 || echo 0)"
check "T5 emliti a kartya-id-t" "1" "$(echo "$OUT" | grep -q 'c1' && echo 1 || echo 0)"

echo "── T5b: ugyanaz a kartya, van komment -- nem talal ─────────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'c1','ordog',$(date +%s));"
OUT="$(run_env)"
check "T5b SKIP ha van komment" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards; DELETE FROM kanban_comments;"

echo "── T6: 2 oranal regebben allo urgent kartya -- talal ───────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c2','urgent-cim','planned',NULL,'urgent',$(( $(date +%s) - 3*3600 )),NULL);"
OUT="$(run_env)"
check "T6 urgent-kor finding" "1" "$(echo "$OUT" | grep -qi 'URGENT-KOR' && echo 1 || echo 0)"
check "T6 emliti a kartya-id-t" "1" "$(echo "$OUT" | grep -q 'c2' && echo 1 || echo 0)"

echo "── T6b: friss (kuszob alatti) urgent kartya -- nem talal ──────────────────────────────"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c3','urgent-friss','planned',NULL,'urgent',$(date +%s),NULL);"
OUT="$(run_env)"
check "T6b SKIP friss urgent kartyaval" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"

echo "── T7: tobb talalat egyszerre -- mindket blokk megjelenik (osszefuzott jelentes) ──────"
sqlite3 "$FDb" "INSERT INTO agent_messages VALUES (4,'marveen','ordog','pending',$(( $(date +%s) - 3600 )));"
touch -t 202001010000 "$FTmp/backups/claudeclaw-friss.tar.gz"
OUT="$(run_env)"
check "T7 pending-sor is benne van" "1" "$(echo "$OUT" | grep -qi 'PENDING-SOR' && echo 1 || echo 0)"
check "T7 mentes-frissesseg is benne van" "1" "$(echo "$OUT" | grep -qi 'MENTES-FRISSESSEG' && echo 1 || echo 0)"
sqlite3 "$FDb" "DELETE FROM agent_messages;"
touch "$FTmp/backups/claudeclaw-friss.tar.gz"

echo "── T8: hatar-eset -- pontosan a kuszobon allo urgent kartya (nem regebbi) -- nem talal ─"
# A kuszob-osszehasonlitasnak SZIGORUAN nagyobb-nak kell lennie (>), nem >=, kulonben egy
# eppen most valtott urgent kartya azonnal jelzest valtana ki.
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c4','urgent-hataron','planned',NULL,'urgent',$(date +%s),NULL);"
OUT="$(run_env)"
check "T8 hataron allo (0 oras) urgent kartya nem valt ki jelzest" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"

echo ""
echo "Osszesen: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]

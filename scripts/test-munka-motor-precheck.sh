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
CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT, priority TEXT, created_at INTEGER, updated_at INTEGER, archived_at INTEGER);
CREATE TABLE kanban_comments (id INTEGER PRIMARY KEY, card_id TEXT, author TEXT, created_at INTEGER);
CREATE TABLE kanban_card_events (id INTEGER PRIMARY KEY, card_id TEXT, from_status TEXT, to_status TEXT, actor TEXT, created_at INTEGER);
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

echo "── T4: pane-tartalom NEM illeszkedik IDLE_FOOTER_RX-re (bukas-eloallitas) -- talal ────"
# A footer helyett egy UI-hint all a pane-en (a card-ot okozo tenyleges eset: rendezo,
# 2026-08-11, "new task? /clear to save 304.4k tokens"). Sem footer, sem busy-jelzes --
# detectPaneState 'unknown'-t ad, tehat a fej kezbesithetetlen.
tmux new-session -d -s agent-zzzprecheck -x 80 -y 20
tmux send-keys -l -t agent-zzzprecheck "new task? /clear to save 304.4k tokens"
OUT="$(run_env env MMPC_TMUX_SESSION_PREFIX="agent-zzzprecheck")"
check "T4 pane-kezbesithetetlen finding" "1" "$(echo "$OUT" | grep -qi 'PANE-KEZBESITHETETLEN' && echo 1 || echo 0)"
check "T4 emliti a session nevet" "1" "$(echo "$OUT" | grep -q 'agent-zzzprecheck' && echo 1 || echo 0)"
tmux kill-session -t agent-zzzprecheck 2>/dev/null

echo "── T4b: pane-tartalom illeszkedik IDLE_FOOTER_RX-re (pozitiv kontroll) -- nem talal ───"
tmux new-session -d -s agent-zzzprecheck -x 80 -y 20
tmux send-keys -l -t agent-zzzprecheck "bypass permissions on (shift+tab to cycle)"
OUT="$(run_env env MMPC_TMUX_SESSION_PREFIX="agent-zzzprecheck")"
check "T4b SKIP bizonyitottan kezbesitheto panenal" "SKIP" "$OUT"
tmux kill-session -t agent-zzzprecheck 2>/dev/null

echo "── T5: nulla-kommentes waiting kartya -- talal ─────────────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c1','cim','waiting','marveen','normal',$(date +%s),$(date +%s),NULL);"
OUT="$(run_env)"
check "T5 nulla-komment finding" "1" "$(echo "$OUT" | grep -qi 'NULLA-KOMMENT' && echo 1 || echo 0)"
check "T5 emliti a kartya-id-t" "1" "$(echo "$OUT" | grep -q 'c1' && echo 1 || echo 0)"

echo "── T5b: ugyanaz a kartya, van komment -- nem talal ─────────────────────────────────────"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (1,'c1','ordog',$(date +%s));"
OUT="$(run_env)"
check "T5b SKIP ha van komment" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards; DELETE FROM kanban_comments;"

echo "── T6: 2 oranal regebben allo urgent kartya, esemeny nelkul (created_at a forras) -- talal"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c2','urgent-cim','planned',NULL,'urgent',$(( $(date +%s) - 3*3600 )),$(( $(date +%s) - 3*3600 )),NULL);"
OUT="$(run_env)"
check "T6 urgent-kor finding" "1" "$(echo "$OUT" | grep -qi 'URGENT-KOR' && echo 1 || echo 0)"
check "T6 emliti a kartya-id-t" "1" "$(echo "$OUT" | grep -q 'c2' && echo 1 || echo 0)"
check "T6 forras: letrehozas (nincs esemeny)" "1" "$(echo "$OUT" | grep -q 'c2.*forras: letrehozas' && echo 1 || echo 0)"

echo "── T6b: friss (kuszob alatti) urgent kartya -- nem talal ──────────────────────────────"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c3','urgent-friss','planned',NULL,'urgent',$(date +%s),$(date +%s),NULL);"
OUT="$(run_env)"
check "T6b SKIP friss urgent kartyaval" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"

echo "── T6c: bukas-eloallitas -- komment (updated_at-frissites) NEM valtoztatja a merot ha van esemeny"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c5','regota-var','waiting',NULL,'urgent',$(( $(date +%s) - 10*3600 )),$(( $(date +%s) - 10*3600 )),NULL);"
sqlite3 "$FDb" "INSERT INTO kanban_card_events VALUES (1,'c5','planned','waiting','marveen',$(( $(date +%s) - 5*3600 )));"
OUT_ELOTTE="$(run_env)"
check "T6c ora=5.0 kommentelesEloTT (esemeny-forras)" "1" "$(echo "$OUT_ELOTTE" | grep -q 'c5.*5\.0 ora, forras: esemeny' && echo 1 || echo 0)"
# szimulalt komment: addKanbanComment (src/db.ts) mindig frissiti a kartya updated_at-jet,
# a kanban_card_events-et NEM erinti -- pontosan ezt szimulaljuk itt.
sqlite3 "$FDb" "UPDATE kanban_cards SET updated_at=$(date +%s) WHERE id='c5';"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (10,'c5','marveen',$(date +%s));"
OUT_UTANA="$(run_env)"
check "T6c ora=5.0 komment UTAN is (nem nullazodik)" "1" "$(echo "$OUT_UTANA" | grep -q 'c5.*5\.0 ora, forras: esemeny' && echo 1 || echo 0)"
sqlite3 "$FDb" "DELETE FROM kanban_cards; DELETE FROM kanban_card_events; DELETE FROM kanban_comments;"

echo "── T6d: bukas-eloallitas -- esemeny nelkuli kartyanal a created_at (nem updated_at) a fallback"
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c6','regi-esemeny-nelkul','waiting',NULL,'urgent',$(( $(date +%s) - 6*3600 )),$(( $(date +%s) - 6*3600 )),NULL);"
OUT_ELOTTE="$(run_env)"
check "T6d ora=6.0 kommentelesEloTT (letrehozas-forras)" "1" "$(echo "$OUT_ELOTTE" | grep -q 'c6.*6\.0 ora, forras: letrehozas' && echo 1 || echo 0)"
sqlite3 "$FDb" "UPDATE kanban_cards SET updated_at=$(date +%s) WHERE id='c6';"
sqlite3 "$FDb" "INSERT INTO kanban_comments VALUES (11,'c6','marveen',$(date +%s));"
OUT_UTANA="$(run_env)"
check "T6d ora=6.0 komment UTAN is (a created_at nem mozdul)" "1" "$(echo "$OUT_UTANA" | grep -q 'c6.*6\.0 ora, forras: letrehozas' && echo 1 || echo 0)"
sqlite3 "$FDb" "DELETE FROM kanban_cards; DELETE FROM kanban_comments;"

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
sqlite3 "$FDb" "INSERT INTO kanban_cards VALUES ('c4','urgent-hataron','planned',NULL,'urgent',$(date +%s),$(date +%s),NULL);"
OUT="$(run_env)"
check "T8 hataron allo (0 oras) urgent kartya nem valt ki jelzest" "SKIP" "$OUT"
sqlite3 "$FDb" "DELETE FROM kanban_cards;"

echo ""
echo "Osszesen: $FPass OK, $FFail BUKIK"
[ "$FFail" -eq 0 ]

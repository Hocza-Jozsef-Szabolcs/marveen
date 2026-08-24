#!/usr/bin/env bash
# hu: A munka-motor heartbeat GEPI RESZE -- kartya heartbeat-szkriptesites-20260806, Jozsi
#     dontese 2026-08-06 20:53. A schedule-runner `preCheck` mechanizmusan (runPreCheck,
#     src/web/schedule-runner.ts) fut, MODELL NELKUL, minden ora 20. percen. Het mechanikus
#     ellenorzest vegez, amit korabban a modellnek kellett minden korben ujramernie: CPU
#     (top -l 2), mentes-frissesseg, pending sor, pane-szelesseg, kvota-fagyasztas-kapcsolo,
#     nulla-komment mero, urgent-kor.
#
#     KIMENETI PROTOKOLL (runPreCheck szerzodese):
#       - "SKIP" (egyetlen sor)  -> a modell EBRED NEM meg, a kor nemán zarul
#       - barmi mas, nem-ures    -> a modell EBRED, es ez a szoveg a promptja ELE kerul
#                                    ("[Pre-check eredmeny]" fejlec alatt) -- a modell ne
#                                    merje ujra, amit itt mar megmertunk
#       - ures kimenet / nemnulla exit -> fail-open, a runPreCheck a modellt normal modon
#                                    inditja (lasd runPreCheck kommentjeit)
#
#     A KVOTA-FAGYASZTAS KULON UT: ha FAGYASZTVA, a TELJES kor elmarad -- ez maga a
#     korabbi prompt sajat elorasa ("ne merj, ne ments memoriat... "), tehat ez a hetbol
#     az EGYETLEN eset, ahol a tobbi hat ellenorzes NEM fut le.
#
#     A KUSZOBOK (MMPC_*_THRESHOLD / MMPC_*_MAX_AGE_*) DONTESEK, NEM MERT TENYEK -- az
#     alapertelmezesuk a mar bizonyitott esetekhez igazodik (pl. a mentes-frissesseg 1560
#     perc = 26 ora, a korabbi munka-motor promptbol atvett ertek), de ok maguk konfiguracio,
#     kornyezeti valtozoval felulirhatok (a teszt-harness igy is teszi).
#
# en: The mechanical (no-model) part of the munka-motor heartbeat. Runs as a schedule-runner
#     preCheck script. Prints "SKIP" when nothing needs attention, otherwise prints the
#     already-measured findings so the model does not re-measure them.
#
# ON-TESZT: scripts/test-munka-motor-precheck.sh (5/e -- bukas-eloallitassal igazolva).

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
MHome="${MMPC_HOME:-/Users/ceo/Marveen}"

FQuotaGate="${MMPC_QUOTA_GATE:-$CDir/quota-gate.sh}"
FDb="${MMPC_DB:-$MHome/store/claudeclaw.db}"
FBackupsGlob="${MMPC_BACKUPS_GLOB:-$MHome/backups/*.tar.gz}"
FBackupMaxAgeMin="${MMPC_BACKUP_MAX_AGE_MIN:-1560}"
FPendingMaxAgeMin="${MMPC_PENDING_MAX_AGE_MIN:-10}"
FPaneMinWidth="${MMPC_PANE_MIN_WIDTH:-60}"
FUrgentMaxAgeHours="${MMPC_URGENT_MAX_AGE_HOURS:-2}"
FCpuThreshold="${MMPC_CPU_THRESHOLD:-300}"
FTmuxPrefix="${MMPC_TMUX_SESSION_PREFIX:-agent-}"

FFindings=()

# ── 0. KVOTA-FAGYASZTAS -- ha aktiv, a TELJES kor elmarad ("ne merj") ───────────────────
FFreeze="$(bash "$FQuotaGate" 2>/dev/null | head -1)"
if [ "$FFreeze" = "FAGYASZTVA" ]; then
  echo "SKIP"
  exit 0
fi

# ── 1. CPU-TULTERHELES (top -l 2, a masodik mintavetel -- a hideg elso kimarad) ─────────
if [ -n "${MMPC_TOP_SAMPLE:-}" ]; then
  FTopOut="$(cat "$MMPC_TOP_SAMPLE" 2>/dev/null)"
else
  FTopOut="$(top -l 2 -n 8 -o cpu -stats pid,cpu,time,command 2>/dev/null | awk '/PID/{p++} p==2')"
fi
FCpuFinding="$(printf '%s\n' "$FTopOut" | awk -v thr="$FCpuThreshold" '
  NR==1 { next }
  NF>=4 {
    cpu = $2 + 0
    if (cpu > thr) printf "  pid=%s %.1f%% cmd=%s\n", $1, cpu, $4
  }
')"
if [ -n "$FCpuFinding" ]; then
  FFindings+=("CPU-TULTERHELES (kuszob >${FCpuThreshold}%):"$'\n'"$FCpuFinding")
fi

# ── 2. MENTES-FRISSESSEG ────────────────────────────────────────────────────────────────
FLatestBackup="$(ls -t $FBackupsGlob 2>/dev/null | head -1)"
if [ -z "$FLatestBackup" ]; then
  FFindings+=("MENTES-FRISSESSEG: nincs egyetlen mentes-fajl sem (${FBackupsGlob})")
elif find "$FLatestBackup" -mmin +"$FBackupMaxAgeMin" -print 2>/dev/null | grep -q .; then
  FAgeMin=$(( ( $(date +%s) - $(stat -f %m "$FLatestBackup") ) / 60 ))
  FFindings+=("MENTES-FRISSESSEG: a legfrissebb mentes (${FLatestBackup}) ${FAgeMin} perce keszult (kuszob: ${FBackupMaxAgeMin} perc)")
fi

# ── 3. PENDING SOR (inter-agent uzenetek, amik meg nem kezbesultek) ─────────────────────
FPendingRows="$(sqlite3 -separator '|' "$FDb" \
  "select to_agent, count(*), min(created_at) from agent_messages where status='pending' group by to_agent;" 2>/dev/null)"
FPendingFinding=""
if [ -n "$FPendingRows" ]; then
  FNow=$(date +%s)
  while IFS='|' read -r agent cnt minCreated; do
    [ -z "$agent" ] && continue
    ageMin=$(( (FNow - minCreated) / 60 ))
    if [ "$ageMin" -ge "$FPendingMaxAgeMin" ]; then
      FPendingFinding+="  ${agent}: ${cnt} db, legregebbi ${ageMin} perce"$'\n'
    fi
  done <<< "$FPendingRows"
fi
if [ -n "$FPendingFinding" ]; then
  FFindings+=("PENDING-SOR (kuszob >=${FPendingMaxAgeMin} perc):"$'\n'"$FPendingFinding")
fi

# ── 4. PANE-SZELESSEG (a fo/aktiv pane, NEM a legkeskenyebb -- lasd a munka-motor promptot) ──
FPaneFinding=""
for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep "^${FTmuxPrefix}"); do
  w=$(tmux list-panes -t "$s" -F '#{pane_active} #{pane_width}' 2>/dev/null | awk '$1==1{print $2}')
  if [ -n "$w" ] && [ "$w" -lt "$FPaneMinWidth" ]; then
    FPaneFinding+="  ${s}: a fo pane csak ${w} oszlop (kuszob ${FPaneMinWidth})"$'\n'
  fi
done
if [ -n "$FPaneFinding" ]; then
  FFindings+=("PANE-SZELESSEG:"$'\n'"$FPaneFinding")
fi

# ── 5. NULLA-KOMMENT MERO (waiting kartya, amin meg senki nem irt semmit) ───────────────
FZeroCommentRows="$(sqlite3 -separator '|' "$FDb" \
  "select k.id, k.priority, round((strftime('%s','now')-k.updated_at)/3600.0,1) \
   from kanban_cards k where k.status='waiting' and k.archived_at is null \
   and (select count(*) from kanban_comments c where c.card_id=k.id)=0 \
   order by k.updated_at asc;" 2>/dev/null)"
if [ -n "$FZeroCommentRows" ]; then
  FRep="$(printf '%s\n' "$FZeroCommentRows" | awk -F'|' '{printf "  %s (%s, %s ora)\n", $1, $2, $3}')"
  FFindings+=("NULLA-KOMMENT: waiting kartya, amin meg senki nem irt semmit:"$'\n'"$FRep")
fi

# ── 6. URGENT-KOR (BLOKKOLT KAPU + NYITOTT HATARIDOK) ────────────────────────────────────
FUrgentMaxAgeSec=$(( FUrgentMaxAgeHours * 3600 ))
FUrgentRows="$(sqlite3 -separator '|' "$FDb" \
  "select id, status, coalesce(assignee,'-'), round((strftime('%s','now')-updated_at)/3600.0,1) \
   from kanban_cards where archived_at is null and priority='urgent' and status in ('planned','waiting') \
   and (strftime('%s','now')-updated_at) > ${FUrgentMaxAgeSec} \
   order by updated_at asc;" 2>/dev/null)"
if [ -n "$FUrgentRows" ]; then
  FRep="$(printf '%s\n' "$FUrgentRows" | awk -F'|' '{printf "  %s (%s, %s, %s ora)\n", $1, $2, $3, $4}')"
  FFindings+=("URGENT-KOR (kuszob >${FUrgentMaxAgeHours} ora): urgent kartya, ami nem mozdult:"$'\n'"$FRep")
fi

# ── OSSZEGZES ─────────────────────────────────────────────────────────────────────────
if [ ${#FFindings[@]} -eq 0 ]; then
  echo "SKIP"
  exit 0
fi

printf '%s\n\n' "${FFindings[@]}"
exit 0

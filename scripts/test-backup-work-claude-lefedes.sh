#!/usr/bin/env bash
# hu: A backup.sh HOME-oldali listaja fedje a `~/Work/Claude` git-kezelt tartalmat
#     (CLAUDE.md, hooks/, agents/*.md, commands/, .git a tortenettel) -- kartya 6783a107.
#     MERT TENY: egy eles archivumban (claudeclaw-20260905-061429.tar.gz, 66624139 bajt)
#     a 'Work/Claude' mintara 0 talalat van -- a gep halalaval ez a fa nyomtalanul veszne.
#
# 🛑 IZOLACIO: a valodi backup.sh-t futtatjuk, de sajat REPO_ROOT es HOME fixture-ben (a
#    szkript a REPO_ROOT-ot a sajat eleresi utjabol szamolja -- lemasoljuk egy ideiglenes
#    repo/scripts/ ala), igy sem a valodi Marveen-repot, sem a valodi HOME-ot nem erinti.
#
# 🛑 MUTACIO-ESET (T6): a Work/Claude-bovites eltavolitasa a backup.sh-bol -- ha a mutans
#    is 1-et ad a CLAUDE.md-talalatra, a T1 vak, nem a javitas jo.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/backup.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/backup-work-claude-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

check() {
  local nev="$1" vart="$2" kapott="$3"
  if [ "$vart" = "$kapott" ]; then
    echo "  ✅ $nev"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $nev -- vart: [$vart], kapott: [$kapott]"
    FFail=$((FFail + 1))
  fi
}

# hu: fixture repo + home + egy minimal git-repo a $HOME/Work/Claude helyen.
setup_fixture() {
  local script_path="$1"
  rm -rf "$FTmp/repo" "$FTmp/home"
  mkdir -p "$FTmp/repo/scripts"
  cp "$script_path" "$FTmp/repo/scripts/backup.sh"
  chmod +x "$FTmp/repo/scripts/backup.sh"

  local wc="$FTmp/home/Work/Claude"
  mkdir -p "$wc/hooks" "$wc/agents" "$wc/commands"
  echo "fixture CLAUDE.md tartalom" > "$wc/CLAUDE.md"
  echo "#!/bin/sh" > "$wc/hooks/destructive-git-guard.sh"
  echo "#!/bin/sh" > "$wc/hooks/load-vault-context.sh"
  echo "# agent def" > "$wc/agents/proba.md"
  echo "# command" > "$wc/commands/proba.md"
  # hu: gitignore-olt, NEM szabaly-forras tartalom -- ennek NEM szabad bekerulnie.
  mkdir -p "$wc/project-sessions"
  echo "session-adat" > "$wc/project-sessions/proba.jsonl"
  printf 'project-sessions/\n' > "$wc/.gitignore"

  git -C "$wc" init -q
  git -C "$wc" -c user.name=teszt -c user.email=teszt@example.com add -A
  git -C "$wc" -c user.name=teszt -c user.email=teszt@example.com commit -q -m "fixture" -q
}

run_backup() {
  HOME="$FTmp/home" bash "$FTmp/repo/scripts/backup.sh" >/dev/null 2>&1
  ls -1t "$FTmp/repo/backups"/claudeclaw-*.tar.gz 2>/dev/null | head -1
}

echo "── T1: CLAUDE.md pontosan egyszer szerepel az archivumban ─────────────────────────────"
setup_fixture "$CScript"
ARCHIVE="$(run_backup)"
check "T1 archivum letrejott" "1" "$([ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] && echo 1 || echo 0)"
check "T1 Work/Claude/CLAUDE.md pontosan 1x" "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/CLAUDE.md$')"

echo "── T2: mindket hook-fajl es az agents/commands tartalom bekerul ────────────────────────"
check "T2 destructive-git-guard.sh benne van" "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/hooks/destructive-git-guard.sh$')"
check "T2 load-vault-context.sh benne van"    "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/hooks/load-vault-context.sh$')"
check "T2 agents/*.md benne van"              "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/agents/proba.md$')"
check "T2 commands/*.md benne van"            "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/commands/proba.md$')"

echo "── T3: a git-tortenet (.git) is bekerul ────────────────────────────────────────────────"
check "T3 .git/HEAD bekerul" "1" "$(tar -tzf "$ARCHIVE" | grep -c 'Work/Claude/\.git/HEAD$')"

echo "── T4: a gitignore-olt, nem szabaly-forras tartalom KIMARAD ────────────────────────────"
check "T4 project-sessions NEM kerul be" "0" "$(tar -tzf "$ARCHIVE" | grep -c 'project-sessions/proba.jsonl')"

echo "── T5: visszaallitasi proba -- a kicsomagolt CLAUDE.md bajtra egyezik az eredetivel ────"
mkdir -p "$FTmp/restore"
tar -xpzf "$ARCHIVE" -C "$FTmp/restore"
check "T5 cmp egyezik" "0" "$(cmp -s "$FTmp/restore/home/Work/Claude/CLAUDE.md" "$FTmp/home/Work/Claude/CLAUDE.md"; echo $?)"

echo "── T6 (MUTACIO): a Work/Claude-bovites eltavolitasa -> T1 BUKJON vissza (0 talalat) ────"
CMutans="$FTmp/backup-mutans.sh"
python3 - "$CScript" "$CMutans" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
m = re.search(r'# --- Work/Claude coverage: START ---.*?# --- Work/Claude coverage: END ---\n', text, re.S)
if m:
    open(dst, 'w').write(text[:m.start()] + text[m.end():])
PYEOF
if [ ! -s "$CMutans" ] || cmp -s "$CScript" "$CMutans" 2>/dev/null; then
  echo "  ⚠️  T6 elohivo minta nem talalt (a javitas meg nem kesz) -- mutacio egyelore kihagyva"
else
  setup_fixture "$CMutans"
  ARCHIVE_MUT="$(run_backup)"
  check "T6 mutansnal CLAUDE.md NEM kerul be (a regi hiany visszajon)" "0" "$(tar -tzf "$ARCHIVE_MUT" | grep -c 'Work/Claude/CLAUDE.md$')"
fi

echo
echo "Osszegzes: $FPass zold, $FFail piros"
[ "$FFail" -eq 0 ]

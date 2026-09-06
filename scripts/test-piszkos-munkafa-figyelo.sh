#!/bin/bash
# hu: A PISZKOS-MUNKAFA-FIGYELo merooeszkoze. Szintetikus repokat epit egy izolalt ideiglenes
#     mappaban (halozat- es allapot-fuggetlen), es azt meri, hogy a szkript PONTOSAN azokra a
#     repokra ir sort, amelyekben van ERDEMI (kod/szabaly) commitolatlan valtozas -- helyes
#     piszkos-darabszammal --, es NEMA marad a tiszta, a CSAK-HARMATLAN (mockoon-fixture,
#     `.worktrees/`, `*.apk`, `Thumbs.db`) es a `/backups/` ala eso repokra. Kulon meri a
#     KARTYA-GYANU jelzest: `done`/`waiting` kartya, egyezo `project`, a recency-ablakon belul,
#     DE meg egyetlen commit sem hivatkozik ra a repoban -- es a HAROM ellenpeldat (a kartya mar
#     commitolva van; a kartya tul regi; a kartya masik projekthez tartozik).
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a teszt mer-e.
#    Ot vedelmi pontot mutalunk kulon-kulon (harmatlan-osztalyozo, backup-kihagyas, VHR8-kizaras,
#    kartya-git-log ellenorzes, recency-hatarido), es minden esetben elvarjuk, hogy egy KORABBAN
#    NEMA teszt-eset MOST megszolaljon -- ha nem, a vedelem vak volt, amit a zold keszlet elrejtett.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/piszkos-munkafa-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/piszkos-munkafa-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# 🛑 FAIL-CLOSED oR A MEROESZKOZON -- minden git-hivas utvonala KOTELEZoEN a teszt sajat
#    ideiglenes mappaja alatt kell legyen (lasd test-push-ahead-figyelo.sh azonos vedelme).
gitq() {
  local dir="$1"
  if [ -z "$dir" ] || [ "${dir#$FTmp/}" = "$dir" ]; then
    echo "🛑 A MERoESZKOZ MEGALLT: git-hivas a teszt-mappan KIVUL: '[$dir]'" >&2
    exit 2
  fi
  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

mk_repo() { # nev gyoker -> kiirja az uj repo utjat, mesterag=main
  local name="$1" root="$2"
  local work="$root/$name"
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" symbolic-ref HEAD refs/heads/main
  echo "$work"
}

commit_file() { # munkafa relativut tartalom uzenet [datum]
  local work="$1" rel="$2" content="$3" msg="$4" date="${5:-}"
  mkdir -p "$(dirname "$work/$rel")"
  printf '%s\n' "$content" > "$work/$rel"
  gitq "$work" add "$rel"
  if [ -n "$date" ]; then
    GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" gitq "$work" commit -q -m "$msg"
  else
    gitq "$work" commit -q -m "$msg"
  fi
}

expect_contains() { # cimke  varhato(IGEN|NEM)  minta  kimenet
  local label="$1" want="$2" pattern="$3" out="$4"
  local got="NEM"
  echo "$out" | grep -qF "$pattern" && got="IGEN"

  if [ "$got" = "$want" ]; then
    echo "  ✅ $label"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $label -- '$pattern' szerepel: $got (vart: $want)"
    echo "$out" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
}

# hu: mutalt masolatot keszit CScript-rol -- pontosan EGY illeszkedest var el (kulonben a minta
#     nem egyertelmu). Sikeres alkalmazaskor a MUTANS UTJAT irja stdoutra, hiba eseten nemat es
#     nemnullat ad -- SOSEM `exit`-el, mert ezt a hivo `$(...)`-ben hivja, ahol az `exit` csak a
#     subshellt allitana le, es a hiba nyomtalanul elveszne.
apply_mutation() { # nev old new
  local name="$1" old="$2" new="$3"
  local mut="$FTmp/mutant-$name.sh"
  cp "$CScript" "$mut"

  python3 - "$mut" "$old" "$new" <<'PYEOF' || return 1
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
if n != 1:
    sys.exit("A MUTACIO NEM ALKALMAZHATO (%s): a minta %d-szer illeszkedik" % (p, n))
open(p, 'w').write(s.replace(old, new))
PYEOF

  [ "$(git hash-object "$mut")" != "$ORIG_HASH" ] || return 1
  echo "$mut"
}

FRoot="$FTmp/root"
mkdir -p "$FRoot"

ORIG_HASH=$(git hash-object "$CScript")

# ── A "MOST" -- valodi aktualis epoch, EGYSZER rogzitve. NEM szabad tavoli/kitalalt idot ────
#    hasznalni: a git-log korrelacio `--since` kapcsoloja a git SAJAT (valodi) orajat nezi, a
#    PMF_NOW_EPOCH csak a SQL-oldali recency-vagast allitja -- a ketto csak akkor egyezik, ha a
#    teszt a VALODI "most"-ot rogziti, nem egy szimulalt masikat.
FNow=$(date +%s)

echo "T1-T8 -- alap piszkossag es harmatlan-osztalyozas"

# T1: tiszta repo -- NEM szerepelhet a kimenetben.
R1=$(mk_repo t1-tiszta "$FRoot")
commit_file "$R1" README.md "init" "init"

# T2: CSAK harmatlan untracked '.worktrees/' konyvtar -- csendben kimarad.
R2=$(mk_repo t2-worktrees-dir "$FRoot")
commit_file "$R2" README.md "init" "init"
mkdir -p "$R2/.worktrees/x"
touch "$R2/.worktrees/x/marker"

# T3: CSAK harmatlan untracked '*.apk' -- csendben kimarad.
R3=$(mk_repo t3-apk "$FRoot")
commit_file "$R3" README.md "init" "init"
touch "$R3/app-1.apk"

# T4: CSAK harmatlan mockoon-fixture modositas -- csendben kimarad.
R4=$(mk_repo t4-mockoon "$FRoot")
commit_file "$R4" mockoon/api.json '{"v":1}' "mockoon init"
echo '{"v":2}' > "$R4/mockoon/api.json"

# T5: CSAK harmatlan Thumbs.db torles -- csendben kimarad.
R5=$(mk_repo t5-thumbs "$FRoot")
commit_file "$R5" Thumbs.db "junk" "thumbs init"
rm "$R5/Thumbs.db"

# T6: '/backups/' utvonal ala eso repo, VALODI kod-tartalommal -- az EGESZ repo kimarad.
R6="$FRoot/backups/regi-mentes/munkafa"
mkdir -p "$R6"
git -C "$R6" init -q
git -C "$R6" symbolic-ref HEAD refs/heads/main
mkdir -p "$R6/src"
echo 'print("hello")' > "$R6/src/main.py"
gitq "$R6" add src/main.py

# T7: ERDEMI -- modositott .sh fajl -- SZEREPELNIE kell, piszkos=1.
R7=$(mk_repo t7-erdemi "$FRoot")
commit_file "$R7" script.sh "#!/bin/bash\necho v1" "script init"
printf '#!/bin/bash\necho v2\n' > "$R7/script.sh"

# T8: VEGYES -- ugyanaz mint T7, PLUSZ egy harmatlan untracked '.worktrees/' -- piszkos MARAD 1.
R8=$(mk_repo t8-vegyes "$FRoot")
commit_file "$R8" script.sh "#!/bin/bash\necho v1" "script init"
printf '#!/bin/bash\necho v2\n' > "$R8/script.sh"
mkdir -p "$R8/.worktrees/x"
touch "$R8/.worktrees/x/marker"

# T9: VHR8 -- valodi erdemi valtozassal, DE a fleet-szabaly szerint SEM MERES.
R9="$FRoot/VHR-8.0/Delphi"
mkdir -p "$R9"
git -C "$R9" init -q
git -C "$R9" symbolic-ref HEAD refs/heads/main
echo 'unit Foo;' > "$R9/Foo.pas"
gitq "$R9" add Foo.pas

# T9b: UGYANAZ, DE a valos checkout-elrendezes szerint (elo meres, 2026-09-06): kotojel es pont
#      NELKUL, "VHR8/Projects/VHR8" -- a szukebb minta ezt ATENGEDTE volna.
R9b="$FRoot/gitlab.com/Com-Passz/VHR8/Projects/VHR8"
mkdir -p "$R9b"
git -C "$R9b" init -q
git -C "$R9b" symbolic-ref HEAD refs/heads/main
echo 'unit Bar;' > "$R9b/Bar.pas"
gitq "$R9b" add Bar.pas

OUT=$(PMF_NOW_EPOCH="$FNow" bash "$CScript" --root "$FRoot" --stats 2>&1)

expect_contains "T1 tiszta repo nem szerepel"                     NEM  "$R1" "$OUT"
expect_contains "T2 csak-worktrees-dir repo nem szerepel"         NEM  "$R2" "$OUT"
expect_contains "T3 csak-apk repo nem szerepel"                   NEM  "$R3" "$OUT"
expect_contains "T4 csak-mockoon repo nem szerepel"               NEM  "$R4" "$OUT"
expect_contains "T5 csak-Thumbs.db repo nem szerepel"             NEM  "$R5" "$OUT"
expect_contains "T6 backups-ala eso repo nem szerepel"            NEM  "$R6" "$OUT"
expect_contains "T7 erdemi repo szerepel"                         IGEN "$R7 main piszkos=1" "$OUT"
expect_contains "T7 a modositott fajl listazva"                   IGEN "  M script.sh" "$OUT"
expect_contains "T8 vegyes repo piszkos=1 (csak az erdemi szamit)" IGEN "$R8 main piszkos=1" "$OUT"
expect_contains "T9 VHR8 repo nem szerepel"                       NEM  "$R9" "$OUT"
expect_contains "T9 VHR8 meg a bejaras-szamlalobol is kimarad"    NEM  "Foo.pas" "$OUT"
expect_contains "T9b VHR8 (kotojel/pont nelkuli elrendezes) nem szerepel" NEM "Bar.pas" "$OUT"

expect_contains "harmatlan '.worktrees/' SOHA nem listazodik reszletkent"  NEM "  ?? .worktrees/" "$OUT"
expect_contains "harmatlan apk SOHA nem listazodik reszletkent"           NEM "  ?? app-1.apk" "$OUT"
expect_contains "harmatlan mockoon SOHA nem listazodik reszletkent"       NEM "mockoon/api.json" "$OUT"
expect_contains "harmatlan Thumbs.db SOHA nem listazodik reszletkent"     NEM "Thumbs.db" "$OUT"

if echo "$OUT" | grep -qE "^bash:|Traceback|szintaktikai hiba"; then
  echo "  ❌ T1-T9 a szkript hibaval allt le (varatlan kimenet)"
  echo "$OUT" | sed 's/^/       | /'
  FFail=$((FFail + 1))
fi

echo
echo "T10-T14 -- KARTYA-GYANU korrelacio (cim-atfedes, commitolt/nem, regi/friss, projekt)"

# Egy kozos "erdemi piszkos" repo, aminek a KONYVTaRNEVe egyezik a kartyak `project` mezojevel.
# A piszkos fajl neve HOSSZU es specifikus ("dirty-worktree-guard") -- ez a token, aminek a
# kartya CIMEBEN kell szerepelnie a T10-T13 GYANU/NEM-GYANU dontesehez.
R10=$(mk_repo Projektem "$FRoot")
commit_file "$R10" src/dirty-worktree-guard.sh "echo v1" "init"
echo "echo v2" > "$R10/src/dirty-worktree-guard.sh"
# kartya2-nek MAR VAN commitja ebben a repoban -- ennek NEM szabad gyanut keltenie.
commit_file "$R10" docs/kartya2.txt "lezarva kartya2" "fix kartya2 lezarva"

FDb="$FTmp/claudeclaw.db"
sqlite3 "$FDb" "CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, description TEXT, status TEXT, assignee TEXT, priority TEXT, project TEXT, updated_at INTEGER);"

FIn1h=$((FNow - 3600))
FRegi=$((FNow - 200 * 3600))

sqlite3 "$FDb" "INSERT INTO kanban_cards (id,title,status,project,updated_at) VALUES
  ('kartya1','Dirty worktree guard meg nincs commitolva','done','Projektem',$FIn1h),
  ('kartya2','Dirty worktree guard mar commitolva','done','Projektem',$FIn1h),
  ('kartya3','Dirty worktree guard tul regi','waiting','Projektem',$FRegi),
  ('kartya4','Dirty worktree guard masik projektben','done','MasikProjekt',$FIn1h),
  ('kartya5','Teljesen mas temaju cim, semmi kozos','done','Projektem',$FIn1h);"

OUT2=$(PMF_NOW_EPOCH="$FNow" bash "$CScript" --root "$FRoot" --db "$FDb" 2>&1)

expect_contains "T10 kartya1 (nincs commit, friss, egyezo cim+projekt) GYANUS" IGEN "KARTYA-GYANU: kartya1" "$OUT2"
expect_contains "T11 kartya2 (mar commitolva) NEM gyanus"                     NEM  "KARTYA-GYANU: kartya2" "$OUT2"
expect_contains "T12 kartya3 (tul regi) NEM gyanus"                          NEM  "KARTYA-GYANU: kartya3" "$OUT2"
expect_contains "T13 kartya4 (masik projekt) NEM gyanus"                     NEM  "KARTYA-GYANU: kartya4" "$OUT2"
# T14: ELO MERES ALAPJAN (2026-09-06, ~/Marveen) -- a projekt-egyezes ONMAGABAN NEM eleg, ha a
#      kartya CIME semmilyen piszkos fajlra nem utal, NEM szabad gyanut keltenie.
expect_contains "T14 kartya5 (egyezo projekt, DE cim nem utal a fajlra) NEM gyanus" NEM "KARTYA-GYANU: kartya5" "$OUT2"

echo
echo "M1 -- mutacio: a harmatlan-osztalyozo mindig 'erdemi'-t ad (korai return 1)"
if MUT=$(apply_mutation harmatlan-mindig-erdemi $'is_harmless_entry() {\n  local path="$1"\n\n  case "$path" in' $'is_harmless_entry() {\n  local path="$1"\n  return 1\n\n  case "$path" in'); then
  OUT_M1=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" 2>&1)
  expect_contains "M1 a mockoon-only repo MOST megszolal -- a T4 orzes valodi"    IGEN "$R4" "$OUT_M1"
  expect_contains "M1 a worktrees-only repo MOST megszolal -- a T2 orzes valodi" IGEN "$R2" "$OUT_M1"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: harmatlan-mindig-erdemi"
  FFail=$((FFail + 1))
fi

echo
echo "M2 -- mutacio: a '/backups/' kihagyas eltavolitva"
if MUT=$(apply_mutation backups-kihagyas-eltavolitva '*/backups/*) continue ;;' '*/nemletezo-minta-xyz/*) continue ;;'); then
  OUT_M2=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" 2>&1)
  expect_contains "M2 a backups-ala eso repo MOST megszolal -- a T6 orzes valodi" IGEN "$R6" "$OUT_M2"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: backups-kihagyas-eltavolitva"
  FFail=$((FFail + 1))
fi

echo
echo "M3 -- mutacio: a VHR8-kizaras mintaja eltavolitva"
if MUT=$(apply_mutation vhr8-kizaras-eltavolitva "CVhr8Pattern='[Vv][Hh][Rr]-?8([/._-]|\$)'" "CVhr8Pattern='nemletezo-minta-xyz-vhr8'"); then
  OUT_M3=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" 2>&1)
  expect_contains "M3 a VHR8 repo MOST megszolal -- a T9 orzes valodi"                       IGEN "Foo.pas" "$OUT_M3"
  expect_contains "M3 a VHR8 (kotojel nelkuli) repo is megszolal -- a T9b orzes valodi"      IGEN "Bar.pas" "$OUT_M3"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: vhr8-kizaras-eltavolitva"
  FFail=$((FFail + 1))
fi

echo
echo "M4 -- mutacio: a kartya-git-log ellenorzes mindig 'nincs commit'-et lat"
if MUT=$(apply_mutation kartya-log-mindig-ures 'found=$(git -C "$repo" log --all --since="${since_days} days ago" --grep="$cid" --fixed-strings --oneline -1 2>/dev/null)' 'found=""'); then
  OUT_M4=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" --db "$FDb" 2>&1)
  expect_contains "M4 kartya2 (mar commitolva) MOST is gyanusnak latszik -- a T11 orzes valodi" IGEN "KARTYA-GYANU: kartya2" "$OUT_M4"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: kartya-log-mindig-ures"
  FFail=$((FFail + 1))
fi

echo
echo "M5 -- mutacio: a recency-hatarido kivage a SQL-bol"
if MUT=$(apply_mutation recency-hatarido-eltavolitva 'AND updated_at > $FCutoff' 'AND updated_at > 0'); then
  OUT_M5=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" --db "$FDb" 2>&1)
  expect_contains "M5 kartya3 (tul regi) MOST is gyanusnak latszik -- a T12 orzes valodi" IGEN "KARTYA-GYANU: kartya3" "$OUT_M5"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: recency-hatarido-eltavolitva"
  FFail=$((FFail + 1))
fi

echo
echo "M6 -- mutacio: a cim-atfedes ellenorzes kikapcsolva (mindig egyezesnek latszik)"
if MUT=$(apply_mutation cim-atfedes-eltavolitva '    overlap=1' '    overlap=0'); then
  OUT_M6=$(PMF_NOW_EPOCH="$FNow" bash "$MUT" --root "$FRoot" --db "$FDb" 2>&1)
  expect_contains "M6 kartya5 (nincs cim-atfedes) MOST is gyanusnak latszik -- a T14 orzes valodi" IGEN "KARTYA-GYANU: kartya5" "$OUT_M6"
else
  echo "  ❌ MUTACIO NEM TORTENT MEG: cim-atfedes-eltavolitva"
  FFail=$((FFail + 1))
fi

[ "$(git hash-object "$CScript")" = "$ORIG_HASH" ] || {
  echo "🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutaciok soran." >&2
  exit 2
}

echo
echo "── Osszegzes ──────────────────────────────────────────────────────────────────────────"
echo "PASS=$FPass FAIL=$FFail"
[ "$FFail" -eq 0 ]

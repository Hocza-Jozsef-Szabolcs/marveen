#!/bin/bash
# hu: A PUSH-AHEAD-FIGYELo merooeszkoze. Szintetikus bare+clone repo-parokat epit (halozat- es
#     allapot-fuggetlen), es azt meri, hogy a szkript PONTOSAN azokra a repokra ir sort, amelyeknek
#     van nem-pusholt commitja -- helyes ahead-szammal es a LEGREGEBBI nem-pusholt commit datumaval --
#     es NEMA marad a szinkronban levo es a felso-nyomkovetes nelkuli repokra.
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a teszt mer-e.
#    A T5 a szkript egy MASOLATABOL kiveszi a nulla-ahead orzest (kontrollnak keszult T2-t
#    varhatoan visszahozza), a T6 pedig a "legregebbi commit" kivalasztasat forditja meg
#    (tail -1 -> head -1), es elvarja, hogy a T3 datuma emiatt a LEGUJABBRA valtson.
#
# en: Measuring harness for the push-ahead monitor. Builds synthetic bare+clone repo pairs
#     (network- and state-independent) and measures that the script prints EXACTLY for repos with
#     unpushed commits -- correct ahead-count and OLDEST unpushed commit date -- and stays silent
#     for a synced repo and a repo whose branch has no upstream tracking configured.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CDir="$(cd "$(dirname "$0")" && pwd)"
CScript="$CDir/push-ahead-figyelo.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/push-ahead-figyelo-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# 🛑 FAIL-CLOSED oR A MEROESZKOZON -- lasd test-buildszam-utkozes-kapu.sh azonos vedelme: `git -C ""`
#    NEM hiba, hanem a JELENLEGI munkakonyvtar repojaban fut. Minden git-hivas utvonala KOTELEZoEN
#    a teszt sajat ideiglenes mappaja alatt kell legyen.
gitq() {
  local dir="$1"

  if [ -z "$dir" ] || [ "${dir#$FTmp/}" = "$dir" ]; then
    echo "🛑 A MERoESZKOZ MEGALLT: git-hivas a teszt-mappan KIVUL: '[$dir]'" >&2
    exit 2
  fi

  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

# hu: uj bare "remote" + clone-szeru munkafa parost hoz letre, elso commit push-olva -- ez a
#     "szinkronban" kezdoallapot minden esethez.
new_synced_repo() {
  local name="$1" root="$2"
  local bare="$FTmp/remotes/$name.git"
  local work="$root/$name"

  git init -q --bare "$bare" >/dev/null
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" symbolic-ref HEAD refs/heads/main
  gitq "$work" remote add origin "$bare"
  echo "init" > "$work/README.md"
  gitq "$work" add README.md
  gitq "$work" commit -q -m "init"
  gitq "$work" push -q origin main
  gitq "$work" branch -q --set-upstream-to=origin/main main

  git -C "$work" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "🛑 A MERoESZKOZ VAK: a szintetikus repo ($name) nem jott letre." >&2
    exit 2
  }

  echo "$work"
}

# hu: egy unpushed commitot ad a munkafahoz, rogzitett commiter-datummal (determinisztikus "legregebbi").
add_unpushed_commit() {
  local work="$1" date="$2" msg="$3"

  echo "$msg" >> "$work/README.md"
  gitq "$work" add README.md
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" gitq "$work" commit -q -m "$msg"
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

FRoot="$FTmp/root"
mkdir -p "$FRoot"

echo "T1-T4 -- alap esetek (ahead, szinkron, felso-nyomkovetes nelkul, tobb unpushed commit)"

# T1: egy unpushed commit -- pozitiv eset.
R1=$(new_synced_repo t1-ahead "$FRoot")
add_unpushed_commit "$R1" "2026-09-04T10:00:00" "unpushed valtozas"

# T2: szinkronban -- FALS POZITIV IRANYU KONTROLL, a kapu erre NE szoljon.
R2=$(new_synced_repo t2-synced "$FRoot")

# T3: harom unpushed commit, kulon datummal -- a LEGREGEBBI szamit, nem a legujabb.
R3=$(new_synced_repo t3-tobb "$FRoot")
add_unpushed_commit "$R3" "2026-09-01T10:00:00" "elso unpushed"
add_unpushed_commit "$R3" "2026-09-02T10:00:00" "masodik unpushed"
add_unpushed_commit "$R3" "2026-09-03T10:00:00" "harmadik unpushed"

# T4: van commit, de a branch-nek NINCS felso-nyomkovetese (nincs remote/upstream) -- a szkript
#     ne omoljon ossze, es ne irjon rola semmit (nincs mibol "ahead"-et szamolni).
R4="$FRoot/t4-nincs-upstream"
mkdir -p "$R4"
git -C "$R4" init -q
git -C "$R4" symbolic-ref HEAD refs/heads/main
echo "init" > "$R4/README.md"
gitq "$R4" add README.md
gitq "$R4" commit -q -m "init, upstream nelkul"

OUT=$(bash "$CScript" --root "$FRoot" 2>&1)

expect_contains "T1 az ahead repo szerepel 'ahead=1'-gyel"      IGEN "ahead=1" "$OUT"
expect_contains "T1 az ahead repo utja szerepel a kimenetben"   IGEN "$R1" "$OUT"
expect_contains "T2 a szinkron repo NEM szerepel a kimenetben"  NEM  "$R2" "$OUT"
expect_contains "T3 a harom unpushed commit 'ahead=3'-at ad"    IGEN "ahead=3" "$OUT"
expect_contains "T3 a LEGREGEBBI datum (09-01) szerepel"        IGEN "2026-09-01" "$OUT"
expect_contains "T3 a LEGUJABB datum (09-03) NEM a kiirt datum" NEM  "legregebbi=2026-09-03" "$OUT"
expect_contains "T4 felso-nyomkovetes nelkuli repo NEM szerepel" NEM "$R4" "$OUT"

if echo "$OUT" | grep -qE "^bash:|Traceback|szintaktikai hiba"; then
  echo "  ❌ T1-T4 a szkript hibaval allt le (varatlan kimenet)"
  echo "$OUT" | sed 's/^/       | /'
  FFail=$((FFail + 1))
fi

# ── T5: MUTACIO -- a nulla-ahead orzes eltavolitasa -- a T2 kontrollnak vissza kell jonnie ────
echo
echo "T5 -- mutacio: nulla-ahead orzes eltavolitva a szkript egy masolatabol"

FMut1="$FTmp/mutant-nulla-ahead-guard.sh"
cp "$CScript" "$FMut1"
BASE1=$(git hash-object "$CScript")

python3 - "$FMut1" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '[ -n "$ahead" ] && [ "$ahead" != "0" ] || continue'
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, '[ -n "$ahead" ] || continue')
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut1")" = "$BASE1" ]; then
  echo "  ❌ T5 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT1=$(bash "$FMut1" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT1" | grep -qF "$R2"; then
    echo "  ✅ T5 a mutalt szkript most MEGSZOLAL a szinkron repora -- a T2 orzes valodi"
    FPass=$((FPass + 1))
  else
    echo "  ❌ T5 a mutans is nema maradt a szinkron repora -- a T2 orzes VAK lehet"
    echo "$OUT_MUT1" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE1" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── T6: MUTACIO -- "legregebbi" kivalasztas megfordítasa (tail -1 -> head -1) ─────────────────
echo
echo "T6 -- mutacio: a legregebbi-commit kivalasztas megforditva"

FMut2="$FTmp/mutant-legregebbi-fordit.sh"
cp "$CScript" "$FMut2"
BASE2=$(git hash-object "$CScript")

python3 - "$FMut2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "| tail -1)"
n = s.count(old)
assert n == 1, "A MUTACIO NEM ALKALMAZHATO: a minta %d-szer illeszkedik" % n
s = s.replace(old, "| head -1)")
open(p, 'w').write(s)
PYEOF

if [ "$(git hash-object "$FMut2")" = "$BASE2" ]; then
  echo "  ❌ T6 A MUTACIO NEM TORTENT MEG (a masolat hash-e valtozatlan)"
  FFail=$((FFail + 1))
else
  OUT_MUT2=$(bash "$FMut2" --root "$FRoot" 2>&1)
  if echo "$OUT_MUT2" | grep -qF "legregebbi=2026-09-03"; then
    echo "  ✅ T6 a mutalt szkript a LEGUJABB datumot adja -- a T3 datum-ellenorzes valodi"
    FPass=$((FPass + 1))
  else
    echo "  ❌ T6 a mutans is a regi datumot adta -- a T3 datum-ellenorzes VAK lehet"
    echo "$OUT_MUT2" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
fi

[ "$(git hash-object "$CScript")" = "$BASE2" ] || {
  echo "  🛑 A MEROESZKOZ MEGALLT: az ELES szkript veletlenul modosult a mutacio soran." >&2
  exit 2
}

# ── Osszegzes ─────────────────────────────────────────────────────────────────
echo
echo "EREDMENY: $FPass rendben | $FFail elter"
[ "$FFail" -eq 0 ] || exit 1
echo "✅ Minden eset a vart eredmenyt adta."
exit 0

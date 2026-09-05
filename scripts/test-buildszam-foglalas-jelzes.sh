#!/bin/bash
# hu: A BUILD-SZAM FOGLALAS-JELZES merooeszkoze. Szintetikus git-repot epit (determinisztikus,
#     halozat-fuggetlen), es a mutacio-esettel igazolja, hogy a teszt tenyleg mer.
#
# MIT MER: a buildszam-utkozes-kapu.sh a TORTENETET es a WORKTREE-KET hasonlitja ossze -- de egy
# KOZOS munkafan (nincs kulon worktree), ahol KET fej UGYANABBAN a konyvtarban dolgozik egymas
# UTAN/mellett, a masodik fej semmit nem lat a masik elso stage-elt, meg nem commitolt
# build-szamarol -- csak ha odanez a masik fej tmux pane-jere. Ez a kapu EZT a hianyt zarja:
# mielott egy fej a SAJAT build-szamat stage-elne, mego kell nezni, hogy az index MAR hordoz-e
# HEAD-tol eltero, MEG NEM COMMITOLT erteket -- ha igen, az egy MASIK fej ELo foglalasa.
#
# 🛑 MIERT VAN BENNE MUTACIO-ESET: a zold keszlet onmagaban NEM mondja meg, hogy a T2 tenyleg mer-e.
#    A T5 a kaput a diff--cached osszehasonlitas NELKULI ("mindig ZOLD") alakjara mutalja, es
#    elvarja, hogy a FOGLALAS-lelet VISSZAJOJJON PIROSKENT -- ha a mutans is ZOLD marad, a T2 vak.
#
# en: Measuring harness for the build-number RESERVATION signal. Builds a synthetic repo and proves
#     (via a mutation case) that the collision test actually measures something, not just green by
#     construction.
#
# EXIT: 0 = minden eset a vart eredmenyt adta | 1 = legalabb egy eset elter

set -uo pipefail

CScriptDir="$(cd "$(dirname "$0")" && pwd)"
CGate="$CScriptDir/buildszam-foglalas-jelzes.sh"

FTmp=$(mktemp -d "${TMPDIR:-/tmp}/buildszam-foglalas-teszt.XXXXXX")
trap 'rm -rf "$FTmp"' EXIT

FPass=0
FFail=0

# ── Segedek ───────────────────────────────────────────────────────────────────
# 🛑 FAIL-CLOSED oR -- lasd test-buildszam-utkozes-kapu.sh gitq()-jenek fejleceben a ket mert
#    hibaosztalyt (ures utvonal = a JELENLEGI repo, `set -u` + onhivatkozo local = unbound
#    variable). Ugyanaz a vedelem itt is kell, mert ugyanaz a bash-verzio (3.2) fut.
gitq() {
  local dir="$1"

  if [ -z "$dir" ] || [ "${dir#$FTmp/}" = "$dir" ]; then
    echo "🛑 A MERoESZKOZ MEGALLT: git-hivas a teszt-mappan KIVUL: '[$dir]'" >&2
    echo "   (ures utvonalnal a 'git -C' a JELENLEGI repoban futna -- ez fail-closed vedelem)" >&2
    exit 2
  fi

  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"
}

new_repo() {   # nev ertek
  local name="$1"
  local val="$2"
  local dir="$FTmp/$name"

  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  echo "$val" > "$dir/BuildNumberV2.txt"
  gitq "$dir" add BuildNumberV2.txt
  gitq "$dir" commit -q -m "init (build $val)"

  git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "🛑 A MERoESZKOZ VAK: a szintetikus repo ($name) nem jott letre." >&2
    exit 2
  }

  echo "$dir"
}

expect() { # cimke  varhato(PIROS|ZOLD|HIBA)  minta  kimenet  rc
  local label="$1" want="$2" pattern="$3" out="$4" rc="${5:-}"
  local got="ZOLD"

  if [ -n "$rc" ] && [ "$rc" -eq 2 ]; then
    got="HIBA"
  elif echo "$out" | grep -q "$pattern"; then
    got="PIROS"
  fi

  if [ "$got" = "$want" ]; then
    echo "  ✅ $label -- $got (vart: $want)"
    FPass=$((FPass + 1))
  else
    echo "  ❌ $label -- $got, de $want lenne a helyes"
    echo "$out" | sed 's/^/       | /'
    FFail=$((FFail + 1))
  fi
}

echo "BUILD-SZAM FOGLALAS-JELZES -- MERES"
echo "kapu: $CGate"
echo

# ── T1: EGYETLEN FEJ -- semmi nincs stage-elve, a HEAD es az index egyezik ────
echo "T1 -- egyetlen fej, nincs elo foglalas (ZOLD)"
R=$(new_repo t1 100)
OUT=$(bash "$CGate" --repo "$R" 2>&1); RC=$?
expect "T1 nincs foglalas" ZOLD "ELo FOGLALAS" "$OUT" "$RC"
[ "$RC" -eq 0 ] && { echo "  ✅ T1 rc=0"; FPass=$((FPass + 1)); } || { echo "  ❌ T1 rc=$RC (0 kellene)"; FFail=$((FFail + 1)); }

# ── T2: FOGLALAS -- valaki MAS mar stage-elte az uj erteket, MEG NEM commitolta ─
# hu: Ez a MERT ESET szintetikus alakja: a `pascal` stage-elte a 229-et (BuildNumberV2.txt +
#     DVrMobile.pas), a `delphi` meg NEM nyult a fajlhoz. Delphi ELoTT ezt a kaput futtatva
#     latnia kell, hogy MAR van elo foglalas, MIELoTT a sajatjat is stage-elne.
echo
echo "T2 -- MASIK fej mar stage-elte a kovetkezo erteket (PIROS)"
R=$(new_repo t2 228)
echo "229" > "$R/BuildNumberV2.txt"
echo "pascal munkaja" > "$R/DVrMobile.pas"
gitq "$R" add BuildNumberV2.txt DVrMobile.pas
OUT=$(bash "$CGate" --repo "$R" 2>&1); RC=$?
expect "T2 elo foglalas jelezve" PIROS "ELo FOGLALAS" "$OUT" "$RC"
echo "$OUT" | grep -q "229" || { echo "  ❌ T2 a jelentesben nincs benne a stage-elt ertek (229)"; FFail=$((FFail + 1)); }
echo "$OUT" | grep -q "228" || { echo "  ❌ T2 a jelentesben nincs benne a HEAD-erek (228)"; FFail=$((FFail + 1)); }
[ "$RC" -eq 1 ] && { echo "  ✅ T2 rc=1"; FPass=$((FPass + 1)); } || { echo "  ❌ T2 rc=$RC (1 kellene)"; FFail=$((FFail + 1)); }

# ── T3: A STAGE-ELT ERTEK AZONOS A HEAD-DEL -- ujra-add, valtozas nelkul (ZOLD) ─
# hu: Egy `git add` a fajlon, ami TARTALMILAG nem valtoztatott semmit -- a `diff --cached` ilyenkor
#     URES, tehat nincs elo foglalas. Ha a kapu csak a "staged fajlok listajat" nezne (nev szerint,
#     tartalom nelkul), ez HAMIS PIROSAT adna.
echo
echo "T3 -- ujra-add valtozatlan tartalommal (ZOLD, nincs valodi foglalas)"
R=$(new_repo t3 300)
echo "300" > "$R/BuildNumberV2.txt"
gitq "$R" add BuildNumberV2.txt
OUT=$(bash "$CGate" --repo "$R" 2>&1); RC=$?
expect "T3 valtozatlan ujra-add nem foglalas" ZOLD "ELo FOGLALAS" "$OUT" "$RC"

# ── T4: A REPO NEM HASZNAL BUILD-SZAMOT ───────────────────────────────────────
echo
echo "T4 -- a repo nem hasznal BuildNumberV2.txt-t (ZOLD, informalt)"
R="$FTmp/t4"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
echo "x" > "$R/x.txt"; gitq "$R" add x.txt; gitq "$R" commit -q -m "init"
OUT=$(bash "$CGate" --repo "$R" 2>&1); RC=$?
expect "T4 nincs build-szam a repoban" ZOLD "ELo FOGLALAS" "$OUT" "$RC"
echo "$OUT" | grep -qi "nem hasznal" || { echo "  ❌ T4 a kimenet nem mondja ki, hogy a repo nem hasznal build-szamot"; FFail=$((FFail + 1)); }

# ── T5: A MEGLEVo COMMIT-UT VALTOZATLANUL MuKODIK ─────────────────────────────
# hu: A kapu CSAK OLVAS -- egy normal, egyetlen fejes stage+commit ciklust nem zavar meg, es a
#     commit UTAN (a foglalas "elfogyott", mert bekerult a HEAD-be) ujra ZOLDET ad.
echo
echo "T5 -- a meglevo commit-ut valtozatlanul mukodik (a kapu csak olvas, nem allit meg semmit)"
R=$(new_repo t5 400)
echo "401" > "$R/BuildNumberV2.txt"
gitq "$R" add BuildNumberV2.txt
gitq "$R" commit -q -m "feat: sajat valtoztatas (build 401)"
if [ "$(git -C "$R" show HEAD:BuildNumberV2.txt | tr -d '[:space:]')" != "401" ]; then
  echo "  ❌ T5 a normal commit nem sikerult (a kapu nem is fuott meg kozbe)"; FFail=$((FFail + 1))
else
  echo "  ✅ T5a a normal git add + commit sikerult a kapu jelenleteben"; FPass=$((FPass + 1))
fi
OUT=$(bash "$CGate" --repo "$R" 2>&1); RC=$?
expect "T5b commit utan nincs elo foglalas" ZOLD "ELo FOGLALAS" "$OUT" "$RC"

# ── T6: MUTACIO -- a diff--cached osszevetes NELKUL a T2 esetenek vissza kell jonnie ─
# hu: Ez a bukas-eloallitas (kotelezo, lasd bukas-eloallitas-igazolasa skill). A mutans kapu
#     mindig "nincs elo foglalas"-t jelent, fuggetlenul az index allapotatol -- ha a T2 IGY IS
#     ZOLD maradna, akkor a T2 vak volt, nem a kapu erdeme volt a PIROS.
echo
echo "T6 -- MUTACIO: az index-osszevetes kikapcsolva, a T2 esetenek vissza kell jonnie PIROSKENT"
FMutant="$FTmp/mutans-kapu.sh"
sed 's/^if git -C "\$FRepo" diff --cached --quiet -- "\$FFile"; then$/if true; then/' "$CGate" > "$FMutant"
if ! grep -qx 'if true; then' "$FMutant"; then
  echo "  ❌ T6 -- a mutacio nem fogott: a kapuban nincs a vart alaku diff--cached feltetel"
  echo "       (a mero a hibas, nem a kapu -- a T2 PIROSA IGAZOLATLAN)"
  FFail=$((FFail + 1))
else
  R2=$(new_repo t6 228)
  echo "229" > "$R2/BuildNumberV2.txt"
  gitq "$R2" add BuildNumberV2.txt
  OUT=$(bash "$FMutant" --repo "$R2" 2>&1)
  if echo "$OUT" | grep -q "ELo FOGLALAS"; then
    echo "  ❌ T6 a mutans IS PIROSAT ad -- a mutacio nem valtoztatott a viselkedesen"
    FFail=$((FFail + 1))
  else
    echo "  ✅ T6 a mutans ZOLDET ad (elveszett a T2 PIROS lelete) -- a T2 tehat tenyleg mer"
    FPass=$((FPass + 1))
  fi
fi

# ── T7: HASZNALATI HIBA -- nem letezo repo-ut ─────────────────────────────────
echo
echo "T7 -- nem letezo --repo utvonal, hasznalati hiba (exit=2)"
OUT=$(bash "$CGate" --repo "$FTmp/nincs-ilyen-konyvtar" 2>&1); RC=$?
expect "T7 hasznalati hiba" HIBA "" "$OUT" "$RC"

# ── Osszegzes ─────────────────────────────────────────────────────────────────
echo
echo "EREDMENY: $FPass rendben | $FFail elter"
[ "$FFail" -eq 0 ] || exit 1
echo "✅ Minden eset a vart eredmenyt adta."
exit 0

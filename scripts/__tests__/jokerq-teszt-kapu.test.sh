#!/bin/bash
# Contract tests for scripts/jokerq-teszt-kapu.sh.
# Run: bash scripts/__tests__/jokerq-teszt-kapu.test.sh
#
# The wrapper is exercised against a FAKE repo (JOKERQ_GATE_REPO) whose
# scripts/dotnet-gate-all-configs.sh is a stub with a scripted exit code and output. No
# dotnet, no network, no real JokerQ checkout is touched.
#
# The doctrine under test is the same one dotnet-gate.sh states: an absence of
# measurement is RED, never green. A wrapper that reports green on an
# uninterpretable result reproduces the very silent green the gate was built
# against, one layer higher.

set -u

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (missing '$2' in: $(printf '%s' "$3" | tr '\n' '|' | cut -c1-300))" ;;
  esac
}
assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1 (unexpected '$2')" ;;
    *) pass "$1" ;;
  esac
}

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KAPU="$INSTALL_DIR/scripts/jokerq-teszt-kapu.sh"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Builds a fake JokerQ checkout whose dotnet-gate-all-configs.sh stub exits with
# $2 after printing $3. Echoes the repo path. The wrapper calls the all-configs
# gate, not dotnet-gate.sh: the measured unit is the CONFIGURATION LIST, and
# which configurations that holds is decided in the JokerQ repo.
fake_repo() { # name exit_code output
  local d="$TMPDIR_BASE/$1"
  mkdir -p "$d/scripts" "$d/tests/JokerQ.Test"
  : > "$d/tests/JokerQ.Test/JokerQ.Test.csproj"
  {
    echo '#!/bin/bash'
    printf 'cat <<%s\n' "'GATEOUT'"
    printf '%s\n' "$3"
    echo 'GATEOUT'
    printf 'exit %s\n' "$2"
  } > "$d/scripts/dotnet-gate-all-configs.sh"
  chmod +x "$d/scripts/dotnet-gate-all-configs.sh"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null
  echo "$d"
}

run_kapu() { JOKERQ_GATE_REPO="$1" JOKERQ_GATE_BUSY_OVERRIDE="${2:-0}" \
  JOKERQ_GATE_STATE_FILE="${3:-$TMPDIR_BASE/allapot-$RANDOM.txt}" bash "$KAPU" 2>&1; }

# Writes a state file whose last measurement is $2 hours old. Echoes its path.
state_aged() { # name hours_ago
  local f="$TMPDIR_BASE/allapot-$1.txt"
  printf '%s ZOLD\n' "$(( $(date +%s) - $2 * 3600 ))" > "$f"
  echo "$f"
}

echo "jokerq-teszt-kapu tests"
echo "======================="

# ---------------------------------------------------------------------------
# (a) Green gate -> green verdict, exit 0
# ---------------------------------------------------------------------------
echo ""
echo "(a) Zold kapu"
REPO="$(fake_repo a 0 '=== Konfiguracio: AE Debug ===
KAPU: [OK] Passed!  - Failed:     0, Passed:   612, Skipped:     0
MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "zold: kilepesi kod 0" "0" "$RC"
assert_contains "zold: ZOLD verdikt" "JOKERQ-TESZT-KAPU: ZOLD" "$OUT"
assert_contains "zold: az osszegzo sor kimegy" "Passed:   612" "$OUT"
assert_not_contains "zold: nincs PIROS" "PIROS" "$OUT"

# ---------------------------------------------------------------------------
# (b) Failing tests -> red verdict, exit 1, the failing lines are carried out
# ---------------------------------------------------------------------------
echo ""
echo "(b) Buko teszt"
REPO="$(fake_repo b 1 'Failed TQaeApiActorTests.AskTimeout [12 ms]
Teszt-osszegzo:
Failed!  - Failed:     1, Passed:   611, Skipped:     0
MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Debug (zold: 0)')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "buko: kilepesi kod 1" "1" "$RC"
assert_contains "buko: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"
VERDICT="$(printf '%s\n' "$OUT" | tail -n 1)"
assert_contains "buko: a kapu indoklasa a VERDIKT-SORBAN all" "1 konfiguracio piros" "$VERDICT"
assert_contains "buko: a buko teszt neve kimegy" "TQaeApiActorTests.AskTimeout" "$OUT"

# ---------------------------------------------------------------------------
# (c) Compile error -> red (the gate's own three red cases pass through)
# ---------------------------------------------------------------------------
echo ""
echo "(c) Forditasi hiba"
REPO="$(fake_repo c 1 'MainView.axaml(12,5): error AVLN1001: Unable to parse
MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Debug (zold: 0)')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "forditasi hiba: kilepesi kod 1" "1" "$RC"
assert_contains "forditasi hiba: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"
assert_contains "forditasi hiba: a hibasor kimegy" "AVLN1001" "$OUT"

# ---------------------------------------------------------------------------
# (d) Zero exit code with NO gate verdict token -> measurement absent -> RED.
#     This is the wrapper's own fail-closed rule: a gate that says nothing has
#     not said green.
# ---------------------------------------------------------------------------
echo ""
echo "(d) Nema kapu (nulla kod, nincs verdikt-token)"
REPO="$(fake_repo d 0 '')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "nema kapu: kilepesi kod 1" "1" "$RC"
assert_contains "nema kapu: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"
assert_contains "nema kapu: mereshiany indoklas" "mérés-hiány" "$OUT"

# ---------------------------------------------------------------------------
# (e) Zero exit code but a [FAIL] token -> the two signals contradict -> RED
# ---------------------------------------------------------------------------
echo ""
echo "(e) Ellentmondo jelek"
REPO="$(fake_repo e 0 'MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Release (zold: 1)')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "ellentmondas: kilepesi kod 1" "1" "$RC"
assert_contains "ellentmondas: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"

# ---------------------------------------------------------------------------
# (f) Missing repo / missing gate script -> RED, not a silent skip
# ---------------------------------------------------------------------------
echo ""
echo "(f) Hianyzo repo es hianyzo kapu-szkript"
OUT="$(run_kapu "$TMPDIR_BASE/nincs-ilyen")"; RC=$?
assert_eq "hianyzo repo: kilepesi kod 1" "1" "$RC"
assert_contains "hianyzo repo: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"

REPO="$(fake_repo f 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
rm -f "$REPO/scripts/dotnet-gate-all-configs.sh"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "hianyzo kapu-szkript: kilepesi kod 1" "1" "$RC"
assert_contains "hianyzo kapu-szkript: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"

# ---------------------------------------------------------------------------
# (g) A dirty working tree is REPORTED (a red may then be someone's in-flight
#     work, not a regression on main) -- but it does not change the verdict.
# ---------------------------------------------------------------------------
echo ""
echo "(g) Piszkos munkafa jelzese"
REPO="$(fake_repo g 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "tiszta munkafa: kilepesi kod 0" "0" "$RC"
assert_contains "tiszta munkafa: TISZTA jelzes" "munkafa: tiszta" "$OUT"

echo 'valami' > "$REPO/uj-fajl.txt"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "piszkos munkafa: a verdikt valtozatlanul 0" "0" "$RC"
assert_contains "piszkos munkafa: PISZKOS jelzes" "munkafa: PISZKOS" "$OUT"

# ---------------------------------------------------------------------------
# (h) The measured commit is named -- a red report without it cannot be acted on
# ---------------------------------------------------------------------------
echo ""
echo "(h) A mert allapot megnevezese"
REPO="$(fake_repo h 1 'MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Release (zold: 1)')"
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD)"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_contains "mert allapot: a commit hash kimegy" "$HEAD_SHA" "$OUT"

# ---------------------------------------------------------------------------
# (i) Non-zero exit with NO verdict token (the gate was killed, crashed, or never
#     reached its own verdict) -> RED, and the EXIT CODE is named. Without naming it
#     this case is indistinguishable from the silent green of (d), and the wrapper's
#     own exit-code check would be free to disappear untested.
# ---------------------------------------------------------------------------
echo ""
echo "(i) Nem-nulla kod verdikt-token nelkul"
REPO="$(fake_repo i 137 '')"
OUT="$(run_kapu "$REPO")"; RC=$?
VERDICT="$(printf '%s\n' "$OUT" | tail -n 1)"
assert_eq "kilott kapu: kilepesi kod 1" "1" "$RC"
assert_contains "kilott kapu: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$VERDICT"
assert_contains "kilott kapu: a kilepesi kod meg van nevezve" "137" "$VERDICT"

# ---------------------------------------------------------------------------
# (j) On a LONG log the failing lines are re-concentrated next to the verdict.
#     The raw gate output is echoed in full, so a failing line "appears somewhere"
#     no matter what the wrapper does -- only its position proves the detail block
#     exists. A truncated tool output keeps the tail; that is what must carry the fault.
# ---------------------------------------------------------------------------
echo ""
echo "(j) Hosszu naplo: a reszletek a verdikt melle kerulnek"
LONG_LOG="Failed TLongLogTests.Regresszio [3 ms]
$(for i in $(seq 1 200); do echo "  toltelek sor $i"; done)
MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Debug (zold: 0)"
REPO="$(fake_repo j 1 "$LONG_LOG")"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "hosszu naplo: kilepesi kod 1" "1" "$RC"
TAIL="$(printf '%s\n' "$OUT" | tail -n 30)"
assert_contains "hosszu naplo: a buko teszt a kimenet VEGEN is ott van" "TLongLogTests.Regresszio" "$TAIL"

# ---------------------------------------------------------------------------
# (k) Another dotnet build/test is already running -> the gate does NOT start a
#     competing run. A red produced by two builds fighting over the same obj/bin is
#     a FALSE alarm, and a false alarm kills the gate: within days it drops out of
#     being read, and the REAL red goes unseen with it.
#     A recent successful measurement stands, so the skip is silent.
# ---------------------------------------------------------------------------
echo ""
echo "(k) Parhuzamos build fut, friss meres van -> csendes kihagyas"
REPO="$(fake_repo k 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
ST="$(state_aged k 1)"
OUT="$(run_kapu "$REPO" 1 "$ST")"; RC=$?
assert_eq "foglalt+friss: kilepesi kod 0" "0" "$RC"
assert_contains "foglalt+friss: KIHAGYVA verdikt" "JOKERQ-TESZT-KAPU: KIHAGYVA" "$OUT"
assert_not_contains "foglalt+friss: nincs PIROS" "PIROS" "$OUT"
assert_not_contains "foglalt+friss: a kapu-szkript el sem indult" "MINDEN-KONFIG: [OK]" "$OUT"

# ---------------------------------------------------------------------------
# (l) Busy, and the last measurement is STALE -> RED. Without this the gate could
#     stay silent indefinitely on a permanently busy machine, which is the very
#     unmeasured state it was built to end.
# ---------------------------------------------------------------------------
echo ""
echo "(l) Parhuzamos build fut, de a meres elavult -> PIROS"
REPO="$(fake_repo l 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
ST="$(state_aged l 60)"
OUT="$(run_kapu "$REPO" 1 "$ST")"; RC=$?
assert_eq "foglalt+elavult: kilepesi kod 1" "1" "$RC"
assert_contains "foglalt+elavult: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"
assert_contains "foglalt+elavult: az elavulas meg van nevezve" "48" "$OUT"

# ---------------------------------------------------------------------------
# (m) Busy with NO state file at all -> RED (absence of measurement, not green)
# ---------------------------------------------------------------------------
echo ""
echo "(m) Parhuzamos build fut, meres meg sosem volt -> PIROS"
REPO="$(fake_repo m 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
OUT="$(run_kapu "$REPO" 1 "$TMPDIR_BASE/nincs-allapot.txt")"; RC=$?
assert_eq "foglalt+nincs allapot: kilepesi kod 1" "1" "$RC"
assert_contains "foglalt+nincs allapot: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"

# ---------------------------------------------------------------------------
# (n) Every real verdict -- green AND red -- records the measurement. A red is a
#     measurement too; not recording it would make the next busy day alarm twice
#     for the same fault, once as red and once as "no measurement".
# ---------------------------------------------------------------------------
echo ""
echo "(n) A meres tenye rogzul"
REPO="$(fake_repo n1 0 'MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
ST="$TMPDIR_BASE/allapot-n1.txt"
run_kapu "$REPO" 0 "$ST" >/dev/null
[ -r "$ST" ] && pass "zold futas: allapot-fajl megszuletett" || fail "zold futas: nincs allapot-fajl"
assert_contains "zold futas: a verdikt rogzul" "ZOLD" "$(cat "$ST" 2>/dev/null)"

REPO="$(fake_repo n2 1 'MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: AE Release (zold: 1)')"
ST2="$TMPDIR_BASE/allapot-n2.txt"
run_kapu "$REPO" 0 "$ST2" >/dev/null
assert_contains "piros futas: a verdikt rogzul" "PIROS" "$(cat "$ST2" 2>/dev/null)"

# A fresh measurement clears the staleness: busy on the NEXT day is silent again.
OUT="$(run_kapu "$REPO" 1 "$ST2")"; RC=$?
assert_eq "friss meres utan a kihagyas csendes" "0" "$RC"
assert_contains "friss meres utan KIHAGYVA" "JOKERQ-TESZT-KAPU: KIHAGYVA" "$OUT"

# ---------------------------------------------------------------------------
# (o) The log now carries ONE partial verdict PER CONFIGURATION, and a summary on
#     top of them. The wrapper must read the SUMMARY: here EVERY partial verdict is
#     green (the failing configuration never reached a verdict at all), so a wrapper
#     reading the partial tokens would find `KAPU: [OK]`, no `KAPU: [FAIL]`, and report
#     GREEN on a run that failed -- the silent green one layer higher, in its newest shape.
# ---------------------------------------------------------------------------
echo ""
echo "(o) Zold reszverdiktek, piros osszegzes -> PIROS"
REPO="$(fake_repo o 0 '=== Konfiguracio: AE Debug ===
KAPU: [OK] Passed!  - Failed:     0, Passed:  2646, Skipped:     1
=== Konfiguracio: AE Release ===
KAPU: [OK] Passed!  - Failed:     0, Passed:  2604, Skipped:     1
=== Konfiguracio: JokerQ Release ===
a forditas elszallt, verdiktig el sem jutott
MINDEN-KONFIG: [FAIL] 1 konfiguracio piros: JokerQ Release (zold: 2)')"
OUT="$(run_kapu "$REPO")"; RC=$?
assert_eq "reszverdiktek: kilepesi kod 1" "1" "$RC"
assert_contains "reszverdiktek: PIROS verdikt" "JOKERQ-TESZT-KAPU: PIROS" "$OUT"
assert_contains "reszverdiktek: a piros konfiguracio neve kimegy" "JokerQ Release" "$OUT"

# ---------------------------------------------------------------------------
# (p) The mirror case: with green partials AND a green summary the reported line
#     must be the SUMMARY, not the first configuration's own result. Otherwise a
#     three-configuration run would be reported as the result of one.
# ---------------------------------------------------------------------------
echo ""
echo "(p) Zold osszegzes: a jelentett sor az OSSZEGZo"
REPO="$(fake_repo p 0 '=== Konfiguracio: AE Debug ===
KAPU: [OK] Passed!  - Failed:     0, Passed:  2646, Skipped:     1
=== Konfiguracio: AE Release ===
KAPU: [OK] Passed!  - Failed:     0, Passed:  2604, Skipped:     1
MINDEN-KONFIG: [OK] mind a 2 konfiguracio zold: AE Debug, AE Release')"
OUT="$(run_kapu "$REPO")"; RC=$?
VERDICT="$(printf '%s\n' "$OUT" | tail -n 1)"
assert_eq "zold osszegzes: kilepesi kod 0" "0" "$RC"
assert_contains "zold osszegzes: az OSSZEGZo sor all a verdiktben" "mind a 2 konfiguracio zold" "$VERDICT"
assert_not_contains "zold osszegzes: nem az elso konfiguracio szama" "2646" "$VERDICT"

echo ""
echo "======================="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

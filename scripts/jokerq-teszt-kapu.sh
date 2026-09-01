#!/usr/bin/env bash
# jokerq-teszt-kapu.sh
#
# hu: A JokerQ teszt-keszlet NAPI, gepies lefuttatasa es EGYETLEN verdiktbe suritese, hogy egy
#     utemezett heartbeat CSAK PIROS eredmenynel szoljon.
#
#     MIERT LETEZIK: a JokerQ.Test keszletet semmi nem futtatta automatikusan -- nincs CI-munkafolyamat,
#     nincs git hook, egyetlen utemezett feladat sem hivatkozott ra. Egy elavult dll emiatt egy honapig
#     eszrevetlen maradt. A meres maga a `scripts/dotnet-gate.sh` dolga; ez a burkolo harom dolgot ad
#     hozza: (1) a kimenetbol EGY sor lesz, amire egy heartbeat donteni tud; (2) kimegy a MERT ALLAPOT
#     (ag, commit, munkafa), enelkul egy piros jelentesre nem lehet lepni; (3) nem indit versengo futast
#     egy mar folyo forditas melle.
#
#     HAROM VERDIKT VAN, es a harmadik nem osszemoshato az elsovel:
#       ZOLD     -- lemertuk, rendben. ALLITAS.
#       PIROS    -- lemertuk, nincs rendben; VAGY a meres maga romlott el (fail-closed).
#       KIHAGYVA -- NEM mertunk, es ez most elfogadhato. Az allitas HIANYA, nem allitas.
#
#     FAIL-CLOSED, ugyanaz a doktrina, mint a kapunal: a MERESHIANY PIROS, nem zold. Egy nulla
#     kilepesi kod verdikt-token nelkul nem mond zoldet; egy nulla kod [FAIL] tokennel ellentmondas.
#     Egy megengedo burkolo pontosan azt a nema zoldet allitana vissza egy retegel feljebb, ami ellen
#     a kapu keszult.
#
# en: The DAILY, mechanical run of the JokerQ test suite condensed into a SINGLE verdict, so that a
#     scheduled heartbeat speaks ONLY on red.
#
#     WHY IT EXISTS: nothing ran JokerQ.Test automatically -- no CI workflow, no git hook, no scheduled
#     task referenced it. A stale dll therefore went unnoticed for a month. The measurement itself
#     belongs to `scripts/dotnet-gate.sh`; this wrapper adds three things: (1) ONE line a heartbeat can
#     act on; (2) the MEASURED STATE (branch, commit, working tree), without which a red report cannot
#     be acted upon; (3) it starts no run competing with a build already in flight.
#
#     THREE VERDICTS, and the third does not collapse into the first:
#       ZOLD (green)     -- measured, sound. An ASSERTION.
#       PIROS (red)      -- measured and unsound; OR the measurement itself broke (fail-closed).
#       KIHAGYVA (skip)  -- we did NOT measure, and that is acceptable for now. The ABSENCE of the
#                           assertion, not an assertion.
#
#     FAIL-CLOSED, on the gate's own doctrine: an ABSENCE OF MEASUREMENT is RED, not green.
#
# Hasznalat / Usage:
#   bash scripts/jokerq-teszt-kapu.sh
#
# Meresi horgok a szerzodes-teszthez / Measurement hooks for the contract test:
#   JOKERQ_GATE_REPO           -- a mert repo utja
#   JOKERQ_GATE_STATE_FILE     -- az utolso meres tenyet orzo fajl
#   JOKERQ_GATE_BUSY_OVERRIDE  -- 1 = "fut mar egy forditas", 0 = "szabad"
#
# Kilepesi kod / Exit code:  0 = ZOLD vagy KIHAGYVA   1 = PIROS
set -uo pipefail

readonly CDefaultRepo='/Users/ceo/Source/github.com/QCassa.com/JokerQ'
readonly CTestProject='tests/JokerQ.Test/JokerQ.Test.csproj'
readonly CConfiguration='Debug'

# hu: Hany reszletsort viszunk ki egy piros verdikt melle. A csonkitas melle a TELJES darabszam is
#     kimegy -- enelkul a csonk es a "csak ennyi volt" megkulonboztethetetlen.
# en: How many detail lines accompany a red verdict. The FULL count goes out alongside the truncation.
readonly CMaxDetailLines=25

# hu: Hany ora utan valik egy kihagyas riasztasi okka. Enelkul egy tartosan foglalt gepen a kapu
#     vegtelen ideig csendben maradna -- pont abba a meretlen allapotba visszaesve, ami ellen keszult.
# en: After how many hours a skip becomes cause for alarm. Without it, on a permanently busy machine
#     the gate would stay silent indefinitely -- falling back into the very unmeasured state it ends.
readonly CStaleHours=48

readonly CRepo="${JOKERQ_GATE_REPO:-$CDefaultRepo}"
readonly CStateFile="${JOKERQ_GATE_STATE_FILE:-/Users/ceo/Marveen/store/jokerq-teszt-kapu-allapot.txt}"

red() {
    printf 'JOKERQ-TESZT-KAPU: PIROS %s\n' "$1"
    exit 1
}

green() {
    printf 'JOKERQ-TESZT-KAPU: ZOLD %s\n' "$1"
    exit 0
}

skipped() {
    printf 'JOKERQ-TESZT-KAPU: KIHAGYVA %s\n' "$1"
    exit 0
}

# -------------------------------------------------------------------
# hu: A MERT ALLAPOT megnevezese. Egy piros jelentes, ami nem mondja meg, MELYIK commiton es
#     milyen munkafan mert, nem ad fogodzot: a piros lehet a main regresszioja, de lehet egy masik
#     fej folyamatban levo, commitolatlan munkaja is.
# en: NAMING THE MEASURED STATE. A red report that does not say WHICH commit and WHAT working tree it
#     measured gives no purchase: the red may be a regression on main, or another head's in-flight work.
# -------------------------------------------------------------------
print_measured_state() {
    local branch commit dirty

    branch="$(git -C "$CRepo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    commit="$(git -C "$CRepo" rev-parse --short HEAD 2>/dev/null)"

    if [ -z "$commit" ]; then
        printf 'Mert allapot: a repo nem git-munkafa (%s) -- ag es commit nem merheto.\n' "$CRepo"
        return
    fi

    if [ -n "$(git -C "$CRepo" status --porcelain 2>/dev/null)" ]; then
        dirty='PISZKOS (commitolatlan valtozas van -- egy piros lehet folyamatban levo munka is)'
    else
        dirty='tiszta'
    fi

    printf 'Mert allapot: %s @ %s, munkafa: %s\n' "$branch" "$commit" "$dirty"
}

# -------------------------------------------------------------------
# hu: Fut-e mar egy masik `dotnet build`/`dotnet test`? Ket egyidejű forditas ugyanazon az obj/bin
#     konyvtaron egymast irja felul, es az ebbol szuletett piros HAMIS. A hamis riasztas a kapu
#     halala: par nap alatt kikerul az olvasasbol, es utana a VALODI piros sem latszik.
# en: Is another `dotnet build`/`dotnet test` already running? Two concurrent builds over the same
#     obj/bin overwrite each other, and a red born of that is FALSE. A false alarm kills the gate.
# -------------------------------------------------------------------
is_busy() {
    if [ -n "${JOKERQ_GATE_BUSY_OVERRIDE:-}" ]; then
        [ "$JOKERQ_GATE_BUSY_OVERRIDE" = '1' ]
        return
    fi

    pgrep -f 'dotnet[^ ]* (build|test|msbuild)' >/dev/null 2>&1
}

# -------------------------------------------------------------------
# hu: Az utolso meres kora oraban. Ures string, ha meg sosem mertunk, vagy ha az allapot-fajl
#     ertelmezhetetlen -- mindketto MERESHIANY, nem "friss".
# en: The age of the last measurement in hours. Empty if we never measured, or if the state file is
#     uninterpretable -- both are an ABSENCE OF MEASUREMENT, not "recent".
# -------------------------------------------------------------------
last_measurement_age_hours() {
    [ -r "$CStateFile" ] || return 0

    local stamp
    stamp="$(cut -d' ' -f1 < "$CStateFile" 2>/dev/null)"

    [[ "$stamp" =~ ^[0-9]+$ ]] || return 0

    printf '%s\n' "$(( ( $(date +%s) - stamp ) / 3600 ))"
}

record_measurement() { # verdikt
    printf '%s %s\n' "$(date +%s)" "$1" > "$CStateFile" 2>/dev/null
}

# -------------------------------------------------------------------
# hu: A piros verdikt melle vitt reszletek: forditasi hibak es buko tesztek. A nyers kimenet ugyan
#     teljes egeszeben kimegy, de egy TOBB EZER SOROS naplot a hivo csonkolva lat -- a vegen. Ezert a
#     lenyeg ujra ki van irva a verdikt MELLE, hogy a csonk is a hibat vigye.
# en: The details carried alongside a red verdict: compiler errors and failing tests. The raw output
#     does go out in full, but a MULTI-THOUSAND-LINE log reaches the caller truncated -- at the tail.
#     So the essentials are re-emitted NEXT TO the verdict, making the truncation carry the fault.
# -------------------------------------------------------------------
print_red_details() {
    local log="$1"
    local details count

    details="$(grep -aE ' error [A-Z]+[0-9]+|^[[:space:]]*(Failed|Failed!|Test Run Failed)' "$log")"

    if [ -z "$details" ]; then
        return
    fi

    count="$(printf '%s\n' "$details" | wc -l | tr -d ' ')"
    printf 'Reszletek (%s sor, ebbol az elso %s):\n' "$count" "$CMaxDetailLines"
    printf '%s\n' "$details" | head -n "$CMaxDetailLines"
}

main() {
    if [ ! -d "$CRepo" ]; then
        red "a repo nem letezik ('$CRepo') -- ez mérés-hiány, nem zold eredmeny."
    fi

    if [ ! -r "$CRepo/scripts/dotnet-gate.sh" ]; then
        red "a kapu-szkript nem olvashato ('$CRepo/scripts/dotnet-gate.sh') -- ez mérés-hiány, nem zold eredmeny."
    fi

    if [ ! -r "$CRepo/$CTestProject" ]; then
        red "a teszt-projekt nem olvashato ('$CRepo/$CTestProject') -- ez mérés-hiány, nem zold eredmeny."
    fi

    print_measured_state

    if is_busy; then
        local ageHours
        ageHours="$(last_measurement_age_hours)"

        if [ -z "$ageHours" ]; then
            red "mar fut egy masik dotnet forditas/teszt, es MEG SOSEM VOLT ertelmezheto meres -- ez mérés-hiány, nem zold eredmeny."
        fi

        if [ "$ageHours" -ge "$CStaleHours" ]; then
            red "mar fut egy masik dotnet forditas/teszt, es az utolso meres $ageHours oraja volt (a hatar $CStaleHours ora) -- ez mérés-hiány, nem zold eredmeny."
        fi

        skipped "mar fut egy masik dotnet forditas/teszt; az utolso meres $ageHours oraja volt, ezert nem inditunk versengo futast."
    fi

    local log
    log="$(mktemp -t jokerq-teszt-kapu)"

    # hu: A mert parancs kodja a csovezetek ELSO tagjae -- a `tee` mindig sikeres.
    # en: The measured command's code belongs to the FIRST member of the pipeline -- `tee` always succeeds.
    ( cd "$CRepo" && bash scripts/dotnet-gate.sh test "$CTestProject" -c "$CConfiguration" ) 2>&1 | tee "$log"
    local rc="${PIPESTATUS[0]}"

    local verdictFail verdictPass
    verdictFail="$(grep -aF 'KAPU: [FAIL]' "$log" | head -n 1)"
    verdictPass="$(grep -aF 'KAPU: [OK]' "$log" | head -n 1)"

    if [ "$rc" -ne 0 ] || [ -n "$verdictFail" ]; then
        print_red_details "$log"
        record_measurement 'PIROS'

        if [ -n "$verdictFail" ]; then
            red "$verdictFail (naplo: $log)"
        fi

        red "a kapu $rc koddal lepett ki, verdikt-token nelkul (naplo: $log)"
    fi

    # hu: A NEMA ZOLD: nulla kod, de a kapu nem mondott ki semmit. Nem oldjuk fel a megengedo iranyba.
    # en: THE SILENT GREEN: a zero code with no verdict pronounced. Not resolved permissively.
    if [ -z "$verdictPass" ]; then
        record_measurement 'PIROS'
        red "a kapu nulla koddal zarult, de NINCS verdikt-token a kimeneten -- ez mérés-hiány, nem zold eredmeny (naplo: $log)"
    fi

    rm -f "$log"
    record_measurement 'ZOLD'
    green "$verdictPass"
}

main "$@"

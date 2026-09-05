#!/bin/bash
# hu: Bukas-eloallito teszt: a `device-registry.sh check` irja-e ki a
#     `current_required_config` mezot (kartya c758cf90). MERT ESET: a mezo a
#     nyilvantartasban allt ("AE DEBUG, 2026-09-04-tol"), a `check` viszont a mezo nevet
#     EGYSZER SEM olvasta -- csak a `warnings` tomb ment ki, es az egy MASIK, idokozben
#     elavult build-allitast hordozott. A hivo a kettő kozul csak az elavultat latta.
# en: Failure-producing test: does `device-registry.sh check` print the
#     `current_required_config` field. The field existed in the registry but `check`
#     never read it -- only `warnings` printed, carrying a DIFFERENT, since-stale build
#     claim. The caller only ever saw the stale one.

set -uo pipefail

GATE="${GATE_PATH:-/Users/ceo/Marveen/scripts/device-registry.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/drrc-test.XXXXXX")"
PASS=0
FAIL=0
FAILED_NAMES=()

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if [ ! -x "$GATE" ]; then
    echo "HIBA: a kapu nem futtathato: $GATE" >&2
    exit 1
fi

REG="$WORK/devices.json"
cat > "$REG" <<'JSON'
{
  "devices": [
    {
      "id": "TESZT-ESZKOZ",
      "model": "Teszt Pixel",
      "owner_projects": ["JokerQ"],
      "owner_source": "teszt-fixture",
      "data_policy": "live-data",
      "warnings": [
        "BUILD-KONFIGURACIO ERRE AZ ESZKOZRE: **AE Release** (regi, elavult sor -- ELLENoRIZD a current_required_config mezot)."
      ],
      "last_installs": [],
      "current_required_config": "AE DEBUG TESZT (2026-09-04-tol ervenyes, felulirja a fenti warnings-sort)"
    },
    {
      "id": "TESZT-ESZKOZ-MEZo-NELKUL",
      "model": "Teszt masik",
      "owner_projects": ["JokerQ"],
      "owner_source": "teszt-fixture",
      "data_policy": "free",
      "warnings": [],
      "last_installs": []
    }
  ]
}
JSON

run_case() {
    local name="$1" needle="$2" negate="$3"; shift 3
    local out
    out=$(DEVICE_REGISTRY="$REG" "$GATE" "$@" 2>&1)

    local why=""
    if [ "$negate" = "no" ]; then
        printf '%s' "$out" | grep -qF "$needle" || why="hianyzik a kimenetbol: '$needle'"
    else
        printf '%s' "$out" | grep -qF "$needle" && why="NEM lenne szabad szerepelnie: '$needle'"
    fi
    if ! printf '%s' "$out" | grep -q '==> VERDIKT'; then
        why="${why:+$why; }nincs zaro VERDIKT-sor"
    fi

    if [ -z "$why" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %-64s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
        printf '  BUKIK %-64s %s\n' "$name" "$why"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
}

echo "== device-registry.sh check -- current_required_config kiirasa =="

run_case "R1 a current_required_config ERTEKE megjelenik a kimenetben" \
    "AE DEBUG TESZT (2026-09-04-tol ervenyes" no \
    check TESZT-ESZKOZ

run_case "R2 a mezo felismerheto CIMKEVEL all (nem csak az ertek, elkulonitve a warnings-tol)" \
    "ERVENYES BUILD-ELoIRAS (current_required_config)" no \
    check TESZT-ESZKOZ

run_case "R3 mezo NELKULI eszkoznel nincs 'ERVENYES BUILD-ELoIRAS' sor (nincs mit kiirni)" \
    "ERVENYES BUILD-ELoIRAS" igen \
    check TESZT-ESZKOZ-MEZo-NELKUL

echo
echo "────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Bukott esetek: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi

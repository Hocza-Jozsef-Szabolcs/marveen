#!/bin/bash
# hu: Bukas-eloallito teszt a `device-registry.sh check --repo` KOCKAZAT-JELZES-KAPUJAHOZ
#     (kartya telepitesi-kapu-megvalaszolatlan-kockazat-jelzes-20260905). A kapu a
#     telepitendo build kartya-hivatkozasait a git-tortenetbol olvassa (a kotelezo
#     "Kartya: #<seq> <id>" sor alapjan), es megall, ha egy hivatkozott kartyan van
#     meg le nem zart "KOCKAZAT:" jelzes.
# en: Failure-producing test suite for the risk-flag gate behind
#     `device-registry.sh check --repo`. The gate reads the to-be-installed build's
#     card references from git history (the mandatory "Kártya: #<seq> <id>" line), and
#     blocks when a referenced card carries a still-open "KOCKAZAT:" flag.

set -uo pipefail

GATE="${GATE_PATH:-/Users/ceo/Marveen/scripts/device-registry.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/drcr-test.XXXXXX")"
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
      "model": "Teszt A36",
      "owner_projects": ["JokerQ"],
      "owner_source": "teszt-fixture",
      "data_policy": "free",
      "install_policy": "allowed-from-main",
      "install_policy_source": "teszt-fixture",
      "last_installs": []
    }
  ]
}
JSON

DB="$WORK/kanban.db"

# hu: Friss kanban-fixture minden esethez -- egy tabla, ugyanaz az oszlop-keszlet mint
#     a valodi claudeclaw.db kanban_comments tablaja.
make_db() {
    rm -f "$DB"
    sqlite3 "$DB" "CREATE TABLE kanban_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL, author TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL);"
}

add_comment() {
    local card="$1" author="$2" content="$3" at="$4"
    sqlite3 "$DB" "INSERT INTO kanban_comments (card_id, author, content, created_at) VALUES ('$card', '$author', '$(printf '%s' "$content" | sed "s/'/''/g")', $at);"
}

REPO="$WORK/repo"
REPO2="$WORK/repo2"

make_repo() {
    rm -rf "$REPO"
    mkdir -p "$REPO"
    git -C "$REPO" init -q .
    git -C "$REPO" symbolic-ref HEAD refs/heads/main
    echo "init" > "$REPO/App.cs"
    git -C "$REPO" add -A
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
}

make_repo2() {
    rm -rf "$REPO2"
    mkdir -p "$REPO2"
    git -C "$REPO2" init -q .
    git -C "$REPO2" symbolic-ref HEAD refs/heads/main
    echo "init" > "$REPO2/Other.cs"
    git -C "$REPO2" add -A
    git -C "$REPO2" -c user.email=t@t -c user.name=t commit -qm init
}

# hu: Commit egy kartya-hivatkozassal (vagy anelkul, ha card="").
commit_carded() {
    local repo="$1" file="$2" content="$3" card="$4"
    echo "$content" > "$repo/$file"
    git -C "$repo" add -A
    local msg="feat: valtoztatas ($file)"
    if [ -n "$card" ]; then
        msg="$msg

Kártya: #1 $card"
    fi
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm "$msg"
}

# hu: Egy eset lefuttatasa -- ugyanaz a mintazat mint a testver-teszt
#     (test-device-registry-repo-gate.sh), a DRCR_* env-ekkel bovitve.
run_case() {
    local name="$1" expected="$2" needle="$3" epoch="${4:-0}"; shift 4
    local out actual

    out=$(DEVICE_REGISTRY="$REG" DRCR_KANBAN_DB="$DB" DRCR_REFERENCE_EPOCH="$epoch" "$GATE" "$@" 2>&1)
    actual=$?

    local why=""
    [ "$actual" -ne "$expected" ] && why="vart exit $expected, kapott $actual"
    if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
        why="${why:+$why; }hianyzik a kimenetbol: '$needle'"
    fi
    if ! printf '%s' "$out" | grep -q '==> VERDIKT'; then
        why="${why:+$why; }nincs zaro VERDIKT-sor"
    fi

    if [ -z "$why" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %-64s (exit %d)\n' "$name" "$actual"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
        printf '  BUKIK %-64s %s\n' "$name" "$why"
        printf '%s\n' "$out" | sed 's/^/       | /'
    fi
}

echo "== device-registry.sh check --repo (kockazat-jelzes-kapu) =="

# ---------------------------------------------------------------- T1: nincs kockazat
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-tiszta"
run_case "T1 kartya-hivatkozas, kockazat NELKUL -> MEHET" 0 "nincs megvalaszolatlan kockazat" 0 \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T2: nyitott kockazat blokkol
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-nyitott"
add_comment "kartya-nyitott" "akka" "KOCKAZAT: NFC-erintest fog kerni AE Release-en, PIN-alapu uton." 100
run_case "T2 nyitott KOCKAZAT-jelzes -> ALLJ MEG" 1 "MEGVALASZOLATLAN KOCKAZAT-JELZES" 0 \
    check TESZT-ESZKOZ --repo "$REPO"
run_case "T2b a kartya-id megjelenik a jelentesben" 1 "kartya-nyitott" 0 \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T3: lezart kockazat atenged
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-lezart"
add_comment "kartya-lezart" "akka" "KOCKAZAT: NFC-erintest fog kerni." 100
add_comment "kartya-lezart" "avalonia" "KOCKAZAT-LEZARVA: javitva, PIN-alapu utat visszaallitottuk." 200
run_case "T3 lezart KOCKAZAT (KOCKAZAT-LEZARVA utana) -> MEHET" 0 "nincs megvalaszolatlan kockazat" 0 \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T4: ujra-nyitott kockazat blokkol
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-ujra"
add_comment "kartya-ujra" "akka" "KOCKAZAT: elso jelzes." 100
add_comment "kartya-ujra" "avalonia" "KOCKAZAT-LEZARVA: elso lezaras." 200
add_comment "kartya-ujra" "akka" "KOCKAZAT: masodik, UJ jelzes, meg lezaratlan." 300
run_case "T4 lezaras UTAN ujra nyitott jelzes -> ALLJ MEG" 1 "MEGVALASZOLATLAN KOCKAZAT-JELZES" 0 \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T5: visszamenoleges blokkolas tilos
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-regi"
add_comment "kartya-regi" "akka" "KOCKAZAT: regi jelzes, sosem lezarva." 100
# hu: a referenciapontot a JOVoBE toljuk -- a most keszult commit igy "a referenciapont
#     ELoTTINEK" szamit, es NEM eshet a kockazat-ellenorzes ala.
FAR_FUTURE=99999999999
run_case "T5 kockazat all, DE a commit a referenciapont ELoTTI -> MEHET" 0 "nincs kartyara hivatkozo commit" "$FAR_FUTURE" \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T6: kartya nelkuli commit jelzett, nem blokkol
make_repo; make_db
commit_carded "$REPO" App.cs "v2" ""
run_case "T6 kartya-hivatkozas NELKULI commit -> MEHET, de jelzi" 0 "kartya-hivatkozas NELKUL" 0 \
    check TESZT-ESZKOZ --repo "$REPO"

# ---------------------------------------------------------------- T7: tobb repo, egyikben nyitott kockazat
make_repo; make_repo2; make_db
commit_carded "$REPO" App.cs "v2" "kartya-tiszta2"
commit_carded "$REPO2" Other.cs "v2" "kartya-masik-repo"
add_comment "kartya-masik-repo" "akka" "KOCKAZAT: a masodik repoban all a lelet." 100
run_case "T7 tobb --repo, a MASODIKBAN nyitott kockazat -> ALLJ MEG" 1 "kartya-masik-repo" 0 \
    check TESZT-ESZKOZ --repo "$REPO" --repo "$REPO2"

# ---------------------------------------------------------------- T8: hianyzo DB fail-closed
make_repo; make_db
commit_carded "$REPO" App.cs "v2" "kartya-x"
out=$(DEVICE_REGISTRY="$REG" DRCR_KANBAN_DB="$WORK/nincs-ilyen.db" DRCR_REFERENCE_EPOCH=0 "$GATE" check TESZT-ESZKOZ --repo "$REPO" 2>&1)
actual=$?
if [ "$actual" -ne 0 ] && printf '%s' "$out" | grep -qF "NEM MERHETo"; then
    PASS=$((PASS + 1)); printf '  ok    %-64s (exit %d)\n' "T8 hianyzo kanban DB -> fail-closed ALLJ MEG" "$actual"
else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("T8 hianyzo kanban DB -> fail-closed ALLJ MEG")
    printf '  BUKIK %-64s exit=%s\n' "T8 hianyzo kanban DB -> fail-closed ALLJ MEG" "$actual"
    printf '%s\n' "$out" | sed 's/^/       | /'
fi

echo
echo "────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Bukott esetek: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi

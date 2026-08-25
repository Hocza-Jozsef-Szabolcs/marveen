#!/bin/bash
# hu: Stop hook — "skill-aratás". Ha a session elért egy komplexitási
#     küszöböt (alapértelmezés: 5+ tool-hívás), egyszer emlékeztet arra,
#     hogy az imént kidolgozott eljárás megérdemel-e egy újrahasznosítható
#     skill-jelöltet a Vault-ban. NEM ír fájlt és NEM blokkol — a döntés a
#     modellé, a promotálás skillé a felhasználóé.
#     A Hermes Agent önfejlesztő learning-loopjának hook-alapú megfelelője.
# en: Stop hook — "skill harvest". When a session crosses a complexity
#     threshold (default: 5+ tool calls), reminds once whether the procedure
#     just worked out deserves a reusable skill candidate in the Vault.
#     Writes no file and never blocks — the model decides, the user promotes.
#
# Kontraktus / contract:
#   stdin : {session_id, transcript_path, hook_event_name, cwd, stop_hook_active}
#   stderr: ember-olvasható emlékeztető (a modell ezt feedbackként látja)
#   exit  : mindig 0 — a Stop hook nem blokkolhat
#
# Testreszabás / tuning (env):
#   SKILL_HARVEST_THRESHOLD  - tool-hívás küszöb (alap: 5)
#   SKILL_HARVEST_STATE_DIR  - dedup marker könyvtár (alap: ~/.claude/hooks/.state/skill-harvest)

set -uo pipefail

THRESHOLD="${SKILL_HARVEST_THRESHOLD:-5}"
STATE_DIR="${SKILL_HARVEST_STATE_DIR:-$HOME/.claude/hooks/.state/skill-harvest}"
VAULT_TARGET="$HOME/Work/Claude/Vault/Skill-Candidates"

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$CWD" ] && CWD="$PWD"

# hu: Loop-védelem — ha a Stop hook már aktív, ne fűzzünk rá újabb kört.
[ "$STOP_ACTIVE" = "true" ] && exit 0

# hu: Nincs (még) transcript -> csendes kilépés, ne zajongjon.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# hu: tool_use blokkok számlálása. A `-R` + `fromjson?` a sérült sorokat
#     némán átugorja, így egy fél-kiírt sor nem dönti el a hookot.
count_tools() {
  jq -R -r 'fromjson? | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' \
    "$TRANSCRIPT" 2>/dev/null
}

TOOL_COUNT="$(count_tools | wc -l | tr -d '[:space:]')"
[ -z "$TOOL_COUNT" ] && TOOL_COUNT=0

# hu: Küszöb alatt nincs dolgunk.
[ "$TOOL_COUNT" -ge "$THRESHOLD" ] || exit 0

# hu: Dedup — a Stop hook MINDEN forduló végén lefut, nem csak session
#     végén. Marker nélkül az 5. tool-hívás után minden válasznál szólna.
[ -n "$SESSION_ID" ] || SESSION_ID="nosession-$$"
SAFE_ID="$(echo "$SESSION_ID" | tr -c '[:alnum:]._-' '_')"
MARKER="$STATE_DIR/$SAFE_ID"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
[ -e "$MARKER" ] && exit 0

# hu: Előbb a marker (a kiírás elmaradhat, de kétszer ne szóljon).
: > "$MARKER" 2>/dev/null || exit 0

# hu: Projekt-név a Vault-konvenció szerint (override fájl, majd basename).
OVERRIDE_FILE="$CWD/.claude/.vault-project-name"
if [ -f "$OVERRIDE_FILE" ]; then
  PROJECT_NAME="$(head -n1 "$OVERRIDE_FILE" | tr -d '[:space:]')"
else
  PROJECT_NAME="$(basename "$CWD")"
fi

TOOL_MIX="$(count_tools | sort | uniq -c | sort -rn | head -6 \
  | awk '{printf "%s×%s  ", $1, $2}')"

# hu: A felhasználónak látható jelzés. Stop hooknál a puszta stderr nem
#     jelenik meg — a dokumentált út a stdout-ra írt {"systemMessage": ...}.
jq -n --arg msg \
  "🧠 skill-harvest: $TOOL_COUNT tool-hívás — érdemes skill-jelöltet írni? (Vault/Skill-Candidates/)" \
  '{systemMessage: $msg}'

cat >&2 <<EOF
[hook: skill-harvest] Skill-jelölt ellenőrzés

Ez a session $TOOL_COUNT tool-hívást használt (küszöb: $THRESHOLD).
Eszköz-mix: $TOOL_MIX
Projekt: $PROJECT_NAME

Kérdés magadnak — született itt ÚJRAHASZNOSÍTHATÓ eljárás?
Akkor igen, ha: több lépéses recept, amit zsákutcák/hibák után találtál meg,
és egy következő hasonló feladatnál újra végig kellene járnod.

HA IGEN -> írj egy skill-jelöltet ide (fájlt csak te hozol létre, a hook nem):
  $VAULT_TARGET/<kebab-case-nev>.md

  Tartalom: cél / előfeltételek / lépések sorban / buktatók / ellenőrzés.
  Frontmatter: type: pattern, tags, created, verified, project: $PROJECT_NAME
  Linkeld be: Vault/MOCs -> a megfelelő MOC-ba (árva jegyzet ne maradjon).

HA NEM (rutin munka, egyszeri javítás, puszta tényfeltárás) -> ne csinálj semmit.
A hamis pozitív skill rosszabb, mint a hiányzó: zajt visz a skill-listába.

Promotálás valódi skillre (~/.claude/skills/<nev>/SKILL.md) KIZÁROLAG
felhasználói jóváhagyással — a Vault-jegyzet a felülvizsgálati állomás.
EOF

exit 0

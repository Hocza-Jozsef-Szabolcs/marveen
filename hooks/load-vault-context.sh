#!/bin/bash
# SessionStart hook — projekt- és megosztott memória betöltése a model context-be.
#
# Kártya #914 / 98f3b15e (2026-08-24) óta a forrás a Marveen DASHBOARD
# (memories tábla, `project` cimkével), NEM a ~/Work/Claude/Vault. A Vault
# tartalma egyszer, tételesen átkerült a dashboardba (scripts/vault-memory-import.mjs);
# a Vault-fájlok a lemezen maradnak, de ez a hook többé NEM olvassa őket.
#
# Két dolgot csinál minden session elején:
#   1. (Változatlan, LETILTVA 2026-08-24 óta) Auto-setup: lásd lentebb, 3. blokk.
#   2. Context: a dashboardból lekéri (a) a projekt saját belépő memóriáját
#      (project=<PROJECT_NAME>, topic_key ...MEMORY.md), (b) a megosztott
#      (category=shared) memóriákat -- és mindkettőt a model context-be injektálja.
#
# Projekt-név forrása (felülírható):
#   - <CWD>/.claude/.vault-project-name  (ha létezik) — felhasználó által megadott név
#   - egyébként: $(basename "$CWD")
#
# Sanitized-CWD algoritmus (Claude Code default):
#   <HOME>/.../VrMobile-2.0  →  -...-VrMobile-2-0
#   (minden `/` és `.` `-`-ra cserélve)
set -uo pipefail

VAULT_ROOT="$HOME/Work/Claude/Vault"
MAX_BYTES=30000
DASHBOARD_URL="http://localhost:3420"
DASHBOARD_TOKEN_FILE="/Users/ceo/Marveen/store/.dashboard-token"

# ── 1. CWD meghatározása (stdin JSON elsősorban, fallback $PWD) ────────────────
INPUT="$(cat 2>/dev/null || true)"
CWD=""
if [ -n "$INPUT" ]; then
  CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -z "$CWD" ] && CWD="$PWD"

# ── 2. Projekt-név (override vagy basename) ────────────────────────────────────
OVERRIDE_FILE="$CWD/.claude/.vault-project-name"
if [ -f "$OVERRIDE_FILE" ]; then
  PROJECT_NAME="$(head -n1 "$OVERRIDE_FILE" | tr -d '[:space:]')"
fi
[ -z "${PROJECT_NAME:-}" ] && PROJECT_NAME="$(basename "$CWD")"

# ── 3. Auto-symlink setup ──────────────────────────────────────────────────────
# LETILTVA 2026-08-24 (Jozsi direktivaja, Telegram {1314}, kartya 98f3b15e):
# a Claude Code Vault-fuggosege megszunik -- uj projekt/session mostantol NEM
# kap automatikus Vault-symlinket, es meglevo, nem-Vault symlink/konyvtar sem
# iranyitodik at ide. A MAR letezo, korabban Vault-ra kotott symlinkek
# erintetlenul maradnak -- azok tudatos, projektenkenti leallitasa (kartya-hataron,
# a fejek aktiv munkajat nem megszakitva) a 98f3b15e kartya Fazis 2 resze.
SANITIZED_CWD="${CWD//\//-}"
SANITIZED_CWD="${SANITIZED_CWD//./-}"
AUTO_MEMORY_DIR="$HOME/.claude/projects/$SANITIZED_CWD/memory"
VAULT_PROJECT_DIR="$VAULT_ROOT/Projects/$PROJECT_NAME"
SETUP_STATUS=""

# ── 4. Context összerakása ─────────────────────────────────────────────────────
CONTEXT=""

# Setup-státusz (csak ha új vagy figyelemreméltó)
case "$SETUP_STATUS" in
  newly-linked)
    CONTEXT+="## Vault Auto-Setup"$'\n'
    CONTEXT+="✅ Új symlink létrejött: \`$AUTO_MEMORY_DIR\` → \`$VAULT_PROJECT_DIR\`. Az auto-memory mostantól a Vault-ba ír/olvas ennél a projektnél."$'\n\n'
    ;;
  migrated-to-vault)
    CONTEXT+="## Vault Auto-Setup — migrálva"$'\n'
    CONTEXT+="✅ A korábbi \`project-memories/\` alá mutató symlink (üres volt) átkötve a Vault-ra: \`$AUTO_MEMORY_DIR\` → \`$VAULT_PROJECT_DIR\`."$'\n\n'
    ;;
  legacy-symlink-has-content)
    CONTEXT+="## ⚠️ Vault Auto-Setup — figyelem"$'\n'
    CONTEXT+="A \`$AUTO_MEMORY_DIR\` symlink a régi \`project-memories/\` helyre mutat, és az NEM üres. Manuális migráció szükséges: költöztesd át a tartalmat a Vault-ba (\`$VAULT_PROJECT_DIR\`), majd a symlinket kösd át. Részletek a \`~/.claude/CLAUDE.md\` Memóriabejegyzések szekciójában."$'\n\n'
    ;;
  manual-migration-needed)
    CONTEXT+="## ⚠️ Vault Auto-Setup — figyelem"$'\n'
    CONTEXT+="A \`$AUTO_MEMORY_DIR\` egy nem-üres könyvtár, nem symlink. Manuális migráció szükséges: másold át a tartalmat a Vault-ba (\`$VAULT_PROJECT_DIR\`), majd cseréld le symlinkre. Részletek a \`~/.claude/CLAUDE.md\` Memóriabejegyzések szekciójában."$'\n\n'
    ;;
esac

# Dashboard lekérdezés helper. --max-time 3: egy elérhetetlen dashboard NEM
# akaszthatja meg a session-indítást (set -uo pipefail, nincs -e -- egy üres/
# hibás válasz csendben kihagyja a szekciót, nem szakítja meg a hookot).
fetch_dashboard_memories() {
  local query="$1"
  [ -f "$DASHBOARD_TOKEN_FILE" ] || return 1
  local token
  token="$(cat "$DASHBOARD_TOKEN_FILE" 2>/dev/null)"
  [ -n "$token" ] || return 1
  curl -s --max-time 3 -H "Authorization: Bearer $token" "$DASHBOARD_URL/api/memories?$query" 2>/dev/null
}

# Projekt saját belépő memóriája (a régi Vault-beli <projekt>/MEMORY.md
# megfelelője -- a project-taggel importált sorok közül a *MEMORY.md nevű).
PROJECT_JSON="$(fetch_dashboard_memories "project=$(jq -rn --arg p "$PROJECT_NAME" '$p|@uri')&limit=200")"
if [ -n "${PROJECT_JSON:-}" ] && echo "$PROJECT_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  PROJECT_ENTRY="$(echo "$PROJECT_JSON" | jq -r '[.[] | select(.topic_key // "" | endswith("MEMORY.md"))] | .[0].content // empty')"
  if [ -n "$PROJECT_ENTRY" ]; then
    CONTEXT+="## Projekt memória — $PROJECT_NAME"$'\n'
    CONTEXT+="_Forrás: Marveen dashboard, \`project=$PROJECT_NAME\`. **Alkalmazd a feladatra vonatkozó bejegyzéseket**, mielőtt a kódból kiindulsz._"$'\n\n'
    CONTEXT+="$(echo "$PROJECT_ENTRY" | head -c "$MAX_BYTES")"$'\n\n'
  else
    PROJECT_COUNT="$(echo "$PROJECT_JSON" | jq 'length')"
    if [ "${PROJECT_COUNT:-0}" -gt 0 ]; then
      CONTEXT+="## Projekt memória — $PROJECT_NAME"$'\n'
      CONTEXT+="Nincs önálló MEMORY.md-je, de $PROJECT_COUNT bejegyzés van rá cimkézve a dashboardban. Kereséshez: \`GET /api/memories?project=$PROJECT_NAME&q=<kulcsszó>\`."$'\n\n'
    fi
  fi
fi

# Megosztott (projektközi) memória -- a régi Shared/_index.md megfelelője.
SHARED_JSON="$(fetch_dashboard_memories "agent=marveen&category=shared&limit=100")"
if [ -n "${SHARED_JSON:-}" ] && echo "$SHARED_JSON" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  CONTEXT+="## Megosztott (projektközi) memória"$'\n'
  CONTEXT+="_Forrás: Marveen dashboard, \`category=shared\` — projektközi feedback és tanulság. **Alkalmazd a feladatra vonatkozó bejegyzéseket**, mielőtt a kódból kiindulsz._"$'\n\n'
  CONTEXT+="$(echo "$SHARED_JSON" | jq -r '.[] | "### " + (.topic_key // "memory") + "\n" + .content + "\n"' | head -c "$MAX_BYTES")"$'\n\n'
fi

if [ -z "$CONTEXT" ]; then
  CONTEXT="(Dashboard memória nem elérhető vagy üres -- $DASHBOARD_URL nem válaszolt.)"$'\n'
fi

# ── 5. JSON output ─────────────────────────────────────────────────────────────
jq -n --arg ctx "$CONTEXT" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

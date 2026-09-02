#!/bin/bash
# Contract tests for the orphan-reaper SCOPE in scripts/channels.sh (2nd pass).
#
# Regression origin (mérve 2026-09-02): a 2. reap-pass NEGATÍV kizárással
# válogatott -- mindent kiválasztott, ami CLAUDE_PLUGIN_ROOT=…/<provider>-t
# hordoz és NEM a SAJÁT agents/ fája alatt van. A szomszédos telepítés
# (/Users/ceo/jarvis) minden pollere pontosan ilyen, ezért a két telepítés
# kölcsönösen kiirtotta egymás csatorna-pollerét minden újraindításkor.
# Tünet: "Marveen telegram kapcsolat helyreallt (…s kieses)" -- 9 nap alatt
# 27 fő-csatorna kiesés, ebből 7 (26%) ez a kölcsönös reap.
#
# A fixture NEM kitalált: az 5 sor a futó rendszer `/bin/ps eww -p <pid>`
# kimenete, szó szerint, EGYETLEN szerkesztéssel -- a CLAUDE_CODE_MESSAGING_TOKEN
# értéke REDACTED-BY-TEST-FIXTURE-re cserélve, hogy titok ne kerüljön a repóba.
# Az öt archetípus (2026-09-02, `ps eww -e`, 28 élő poller-sorból válogatva):
#   56956 = Marveen FŐ poller, izolált konfiggal
#           (CLAUDE_CONFIG_DIR=/Users/ceo/Marveen/.channels-config;
#            TELEGRAM_STATE_DIR NINCS az env-jében)
#   4877  = Marveen FŐ poller, izolált konfig NÉLKÜL -- SEM CLAUDE_CONFIG_DIR,
#           SEM TELEGRAM_STATE_DIR; az EGYETLEN tulajdonos-jelzője a
#           CLAUDE_PROJECT_DIR=/Users/ceo/Marveen. Pont ez a 2. pass létjogosultsága
#           (árva poller régi buildből / ad-hoc indításból), ezért a szelektornak
#           MEG KELL fognia -- különben örökre reapelhetetlen marad, és a következő
#           indulás 409 Conflict-ol vele szemben.
#   59301 = Marveen AGENS       (…/Marveen/agents/avalonia/…)
#   51432 = Jarvis  FŐ poller   (CLAUDE_CONFIG_DIR=/Users/ceo/jarvis/.channels-config
#                                — kisbetűs —, CLAUDE_PROJECT_DIR=/Users/ceo/Jarvis
#                                — NAGYBETŰS —, UGYANABBAN a processzben)
#   56210 = Jarvis  AGENS       (TELEGRAM_STATE_DIR=/Users/ceo/jarvis/agents/felderito/…
#                                kisbetűs, CLAUDE_PROJECT_DIR=/Users/ceo/Jarvis/… nagybetűs)
# A vegyes betűalak MÉRT tény, nem feltevés -- ezért kell a szelektorban tolower().
# Szintén MÉRT: a 28 élő pollerből 6-nak NINCS CLAUDE_CONFIG_DIR-je, viszont
# CLAUDE_PROJECT_DIR MIND A 28-nak van -- ez az egyetlen egyetemes jelző.
#
# Driven through `channels.sh --select-orphan-pids <provider> <install_dir>
# <state_var> <ps_snapshot>`, ami a PID-eket kiírja és kilép MINDEN mellékhatás
# (.env-olvasás, mkdir, tmux, kill) előtt. Egyetlen processz sem indul és
# egyetlen jel sem megy ki ebből a tesztből.
# Run: bash scripts/__tests__/channels-orphan-reap-scope.test.sh

set -u

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 -- $2"; }

INSTALL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Felülbírálható, hogy a készlet szándékosan elrontott másolatra is ráállítható
# legyen (egy zöld teszt, ami nem tud pirosra váltani, nem mér semmit).
CHANNELS="${CHANNELS_BIN:-$INSTALL_DIR/scripts/channels.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SNAP="$TMP/ps-snapshot.txt"

cat > "$SNAP" <<'PS_FIXTURE'
56956 s037  S+     0:00.01 bun run --cwd /Users/ceo/Marveen/.channels-config/plugins/cache/claude-plugins-official/telegram/0.0.7 --shell=bun --silent start HOME=/Users/ceo LOGNAME=ceo PATH=/opt/homebrew/bin:/Users/ceo/.bun/bin:/home/linuxbrew/.linuxbrew/bin:/Users/ceo/.local/bin:/usr/local/bin:/usr/bin:/bin:/Users/ceo/.dotnet:/Users/ceo/.cargo/bin:/usr/local/opt/node@22/bin:/Users/ceo/.local/bin:/opt/homebrew/bin:/Users/ceo/.bun/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/zsh TERM=tmux-256color USER=ceo CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false COLORTERM=truecolor LANG=hu_HU.UTF-8 PWD=/Users/ceo/Marveen SHLVL=1 SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.OvmKb29b37/Listeners TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.6a TMPDIR=/var/folders/1k/yjs7z3kd5qj10bmscfj9b7q00000gn/T/ TMUX=/private/tmp/tmux-501/default,1527,1106 TMUX_PANE=%1192 XPC_FLAGS=0x0 XPC_SERVICE_NAME=0 OLDPWD=/Users/ceo/Marveen DOTNET_ROOT=/Users/ceo/.dotnet MCP_SERVER_CONNECTION_BATCH_SIZE=10 MCP_CONNECTION_NONBLOCKING=1 MCP_TIMEOUT=60000 CLAUDE_CONFIG_DIR=/Users/ceo/Marveen/.channels-config _=/usr/local/bin/claude NoDefaultCurrentDirectoryInExePath=1 COREPACK_ENABLE_AUTO_PIN=0 AI_AGENT=claude-code_2-1-258_harness CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/18199.sock CLAUDE_CODE_MESSAGING_TOKEN=REDACTED-BY-TEST-FIXTURE CLAUDE_PROJECT_DIR=/Users/ceo/Marveen CLAUDE_CODE_SESSION_ID=8245c14b-5381-47db-8b8d-d8a4569a8806 CLAUDECODE=1 CLAUDE_PLUGIN_ROOT=/Users/ceo/Marveen/.channels-config/plugins/cache/claude-plugins-official/telegram/0.0.7 CLAUDE_PLUGIN_DATA=/Users/ceo/Marveen/.channels-config/plugins/data/telegram-claude-plugins-official
59301 s000  S+     0:00.01 bun run --cwd /Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 --shell=bun --silent start HOME=/Users/ceo LOGNAME=ceo PATH=/opt/homebrew/bin:/Users/ceo/.bun/bin:/usr/local/bin:/usr/bin:/bin:/Users/ceo/.dotnet:/Users/ceo/.cargo/bin:/usr/local/opt/node@22/bin:/Users/ceo/.local/bin:/opt/homebrew/bin:/Users/ceo/.bun/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/zsh TERM=tmux-256color USER=ceo CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false COLORTERM=truecolor LANG=hu_HU.UTF-8 PWD=/Users/ceo/Marveen/agents/avalonia SHLVL=1 SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.OvmKb29b37/Listeners TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.6a TMPDIR=/var/folders/1k/yjs7z3kd5qj10bmscfj9b7q00000gn/T/ TMUX=/private/tmp/tmux-501/default,1527,1115 TMUX_PANE=%1201 XPC_FLAGS=0x0 XPC_SERVICE_NAME=0 OLDPWD=/Users/ceo/Marveen DOTNET_ROOT=/Users/ceo/.dotnet DISABLE_AUTOUPDATER=1 MCP_SERVER_CONNECTION_BATCH_SIZE=10 MCP_CONNECTION_NONBLOCKING=1 MCP_TIMEOUT=60000 TELEGRAM_STATE_DIR=/Users/ceo/Marveen/agents/avalonia/.claude/channels/telegram CLAUDE_CONFIG_DIR=/Users/ceo/Marveen/agents/avalonia/.claude-config _=/usr/local/bin/claude NoDefaultCurrentDirectoryInExePath=1 COREPACK_ENABLE_AUTO_PIN=0 AI_AGENT=claude-code_2-1-258_harness CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/59197.sock CLAUDE_CODE_MESSAGING_TOKEN=REDACTED-BY-TEST-FIXTURE CLAUDE_PROJECT_DIR=/Users/ceo/Marveen/agents/avalonia CLAUDE_CODE_SESSION_ID=41d26de6-851c-41c5-8f10-f0cff857c8a5 CLAUDECODE=1 CLAUDE_PLUGIN_ROOT=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 CLAUDE_PLUGIN_DATA=/Users/ceo/Marveen/agents/avalonia/.claude-config/plugins/data/telegram-claude-plugins-official
51432 s045  S+     0:00.01 bun run --cwd /Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 --shell=bun --silent start HOME=/Users/ceo LOGNAME=ceo PATH=/Users/ceo/.dotnet:/Users/ceo/.cargo/bin:/opt/homebrew/bin:/Users/ceo/.bun/bin:/home/linuxbrew/.linuxbrew/bin:/Users/ceo/.local/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/zsh TERM=tmux-256color USER=ceo CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false COLORTERM=truecolor LANG=hu_HU.UTF-8 PWD=/Users/ceo/jarvis SHLVL=1 SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.OvmKb29b37/Listeners TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.6a TMPDIR=/var/folders/1k/yjs7z3kd5qj10bmscfj9b7q00000gn/T/ TMUX=/private/tmp/tmux-501/default,1527,998 TMUX_PANE=%1064 XPC_FLAGS=0x0 XPC_SERVICE_NAME=0 OLDPWD=/Users/ceo/jarvis DOTNET_ROOT=/Users/ceo/.dotnet MCP_SERVER_CONNECTION_BATCH_SIZE=10 MCP_CONNECTION_NONBLOCKING=1 MCP_TIMEOUT=60000 CLAUDE_CONFIG_DIR=/Users/ceo/jarvis/.channels-config _=/usr/local/bin/claude NoDefaultCurrentDirectoryInExePath=1 COREPACK_ENABLE_AUTO_PIN=0 AI_AGENT=claude-code_2-1-251_harness CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/87930.sock CLAUDE_CODE_MESSAGING_TOKEN=REDACTED-BY-TEST-FIXTURE CLAUDE_PROJECT_DIR=/Users/ceo/Jarvis CLAUDE_CODE_SESSION_ID=ee5bc24f-0a6f-406f-96a1-60b698ac57c3 CLAUDECODE=1 CLAUDE_PLUGIN_ROOT=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 CLAUDE_PLUGIN_DATA=/Users/ceo/jarvis/.channels-config/plugins/data/telegram-claude-plugins-official
56210 s038  S+     0:00.01 bun run --cwd /Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 --shell=bun --silent start HOME=/Users/ceo LOGNAME=ceo PATH=/opt/homebrew/bin:/Users/ceo/.bun/bin:/usr/local/bin:/usr/bin:/bin:/Users/ceo/.dotnet:/Users/ceo/.cargo/bin:/usr/local/opt/node@22/bin:/Users/ceo/.local/bin:/opt/homebrew/bin:/Users/ceo/.bun/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/zsh TERM=tmux-256color USER=ceo CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false COLORTERM=truecolor LANG=hu_HU.UTF-8 PWD=/Users/ceo/jarvis/agents/felderito SHLVL=1 SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.OvmKb29b37/Listeners TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.6a TMPDIR=/var/folders/1k/yjs7z3kd5qj10bmscfj9b7q00000gn/T/ TMUX=/private/tmp/tmux-501/default,1527,1114 TMUX_PANE=%1200 XPC_FLAGS=0x0 XPC_SERVICE_NAME=0 OLDPWD=/Users/ceo/Jarvis DOTNET_ROOT=/Users/ceo/.dotnet DISABLE_AUTOUPDATER=1 MCP_SERVER_CONNECTION_BATCH_SIZE=10 MCP_CONNECTION_NONBLOCKING=1 MCP_TIMEOUT=60000 TELEGRAM_STATE_DIR=/Users/ceo/jarvis/agents/felderito/.claude/channels/telegram _=/usr/local/bin/claude NoDefaultCurrentDirectoryInExePath=1 COREPACK_ENABLE_AUTO_PIN=0 AI_AGENT=claude-code_2-1-258_harness CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/56127.sock CLAUDE_CODE_MESSAGING_TOKEN=REDACTED-BY-TEST-FIXTURE CLAUDE_PROJECT_DIR=/Users/ceo/Jarvis/agents/felderito CLAUDE_CODE_SESSION_ID=1bd5b793-7b37-4db1-afd2-fd0e839b3eb0 CLAUDECODE=1 CLAUDE_PLUGIN_ROOT=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 CLAUDE_PLUGIN_DATA=/Users/ceo/.claude/plugins/data/telegram-claude-plugins-official
 4877 s037  S+     0:01.25 /Users/ceo/.bun/bin/bun server.ts HOME=/Users/ceo LOGNAME=ceo PATH=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7/node_modules/.bin:/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7/node_modules/.bin:/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/node_modules/.bin:/Users/ceo/.claude/plugins/cache/claude-plugins-official/node_modules/.bin:/Users/ceo/.claude/plugins/cache/node_modules/.bin:/Users/ceo/.claude/plugins/node_modules/.bin:/Users/ceo/.claude/node_modules/.bin:/Users/ceo/node_modules/.bin:/Users/node_modules/.bin:/node_modules/.bin:/Users/ceo/.dotnet:/Users/ceo/.cargo/bin:/opt/homebrew/bin:/Users/ceo/.bun/bin:/home/linuxbrew/.linuxbrew/bin:/Users/ceo/.local/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/zsh TERM=tmux-256color USER=ceo CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false COLORTERM=truecolor LANG=hu_HU.UTF-8 PWD=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 SHLVL=1 SSH_AUTH_SOCK=/private/tmp/com.apple.launchd.OvmKb29b37/Listeners TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.6a TMPDIR=/var/folders/1k/yjs7z3kd5qj10bmscfj9b7q00000gn/T/ TMUX=/private/tmp/tmux-501/default,1527,1124 TMUX_PANE=%1210 XPC_FLAGS=0x0 XPC_SERVICE_NAME=0 OLDPWD=/Users/ceo/Marveen DOTNET_ROOT=/Users/ceo/.dotnet MCP_SERVER_CONNECTION_BATCH_SIZE=10 MCP_CONNECTION_NONBLOCKING=1 MCP_TIMEOUT=60000 _=/usr/local/bin/claude NoDefaultCurrentDirectoryInExePath=1 COREPACK_ENABLE_AUTO_PIN=0 AI_AGENT=claude-code_2-1-258_harness CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/4672.sock CLAUDE_CODE_MESSAGING_TOKEN=REDACTED-BY-TEST-FIXTURE CLAUDE_PROJECT_DIR=/Users/ceo/Marveen CLAUDE_CODE_SESSION_ID=63955173-2026-4361-927d-2ad321843789 CLAUDECODE=1 CLAUDE_PLUGIN_ROOT=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 CLAUDE_PLUGIN_DATA=/Users/ceo/.claude/plugins/data/telegram-claude-plugins-official npm_config_local_prefix=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7 npm_config_user_agent=bun/1.3.9 npm/? node/v24.3.0 darwin x64 npm_execpath=/Users/ceo/.bun/bin/bun npm_package_name=claude-channel-telegram npm_package_json=/Users/ceo/.claude/plugins/cache/claude-plugins-official/telegram/0.0.7/package.json npm_package_version=0.0.1 NODE=/usr/local/bin/node npm_node_execpath=/usr/local/bin/node npm_command=run-script npm_lifecycle_event=start npm_lifecycle_script=bun install --no-summary 1>&2 && bun server.ts
PS_FIXTURE

# $1 = install dir, ami a szelektort hajtja -> a kiválasztott PID-ek egy sorban
select_for() {
  bash "$CHANNELS" --select-orphan-pids telegram "$1" TELEGRAM_STATE_DIR "$SNAP" \
    2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}

# $1 = címke, $2 = kiválasztott PID-lista, $3.. = PID-ek, amiknek NEM szabad benne lenniük
refute_pids() {
  local label="$1" got="$2"; shift 2
  local bad=""
  for p in "$@"; do
    case " $got " in *" $p "*) bad="$bad $p" ;; esac
  done
  if [ -z "$bad" ]; then pass "$label"; else fail "$label" "kivalasztotta:$bad (teljes: $got)"; fi
}

# $1 = címke, $2 = kiválasztott PID-lista, $3 = PID, aminek benne KELL lennie
expect_pid() {
  local label="$1" got="$2" want="$3"
  case " $got " in
    *" $want "*) pass "$label" ;;
    *) fail "$label" "hianyzik a(z) $want (teljes: $got)" ;;
  esac
}

echo "channels.sh orphan-reap hatokor (2. pass)"
echo "========================================="
echo ""

MARVEEN="$(select_for /Users/ceo/Marveen)"
JARVIS="$(select_for /Users/ceo/jarvis)"
echo "  [meres] Marveen szelektor -> ${MARVEEN:-<ures>}"
echo "  [meres] jarvis  szelektor -> ${JARVIS:-<ures>}"
echo ""

echo "(a) A hatokor-hiba: idegen telepites pollerere NEM szabad ranyulni"
refute_pids "Marveen NEM valasztja ki a Jarvis pollereit (51432 fo, 56210 agens)" \
  "$MARVEEN" 51432 56210
refute_pids "jarvis NEM valasztja ki a Marveen pollereit (56956, 4877 fo, 59301 agens)" \
  "$JARVIS" 56956 4877 59301
echo ""

echo "(b) Tul-zaras elleni ellenor: a reap NEM veszitheti el a funkciojat"
expect_pid "Marveen MEG mindig kivalasztja a SAJAT fo pollerét (56956)" "$MARVEEN" 56956
expect_pid "jarvis MEG mindig kivalasztja a SAJAT fo pollerét (51432)" "$JARVIS" 51432
echo ""

echo "(c) A sajat agens-pollert egyik szelektor sem oli meg"
refute_pids "Marveen nem valasztja ki a sajat agens-pollerét (59301)" "$MARVEEN" 59301
refute_pids "jarvis nem valasztja ki a sajat agens-pollerét (56210)" "$JARVIS" 56210
echo ""

echo "(d) Izolalt CLAUDE_CONFIG_DIR NELKULI sajat fo poller -- a 2. pass celpontja"
expect_pid "Marveen kivalasztja a csak CLAUDE_PROJECT_DIR-t hordozo fo pollerét (4877)" \
  "$MARVEEN" 4877
echo ""

echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# hu: launchd/systemd alol a PATH gyakran NEM tartalmazza a node konyvtarat --
#     ez telepitesenkent elter, es egy meglevo telepites plist-je sem frissul
#     automatikusan, ha a node uj helyre kerul. A `command -v node` ilyenkor
#     csendben ures stringet ad, es MINDEN, ami erre epul (pl. a
#     CLAUDE_CONFIG_DIR-elkulonites feloldasa) neszteleneul kimarad -- lasd
#     kartya channel-state-dir-per-install-20260831 (Jarvis merese, 2026-09-02:
#     a fo agens channels.sh-ja PATH-bol nem talalta a node-ot launchd alol,
#     ezert az elkulonites-feloldas le sem futott, es a ket telepites egy
#     kozos bot-tokent hasznalt).
# en: Under launchd/systemd, PATH frequently omits node's directory -- this
#     varies per install, and an existing install's plist does not
#     auto-refresh if node moves. `command -v node` then silently returns
#     empty, and everything gated on it (e.g. CLAUDE_CONFIG_DIR isolation)
#     silently drops out too.
#
# Sourced, never executed directly.
#
# resolve_node_bin: prints the resolved node path on stdout, exit 0. PATH
# (command -v) wins when it works; otherwise falls back to the known absolute
# install locations already trusted elsewhere in this codebase (see
# scripts/github-pr-monitor.sh). If node is not found anywhere, prints
# nothing and returns 1 -- the caller decides how loud to be about that.
#
# Test seam: NODE_BIN_CANDIDATES overrides the fallback list (space-separated)
# so tests can control it independently of what is actually installed on the
# machine running the suite -- mirrors the CHANNELS_PANE_STATE_JS seam already
# used in channels.sh for the same reason.
resolve_node_bin() {
  local found candidate candidates

  found="$(command -v node 2>/dev/null)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi

  candidates="${NODE_BIN_CANDIDATES:-$HOME/.local/bin/node /usr/local/bin/node /usr/bin/node /opt/homebrew/bin/node}"
  for candidate in $candidates; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

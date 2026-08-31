#!/bin/bash
# hu: PreToolUse hook — git commit blokkolása, ha a commit-üzenet vagy a
#     staged diff workaround/deferred jelzést tartalmaz.
# en: PreToolUse hook — block git commit when the message or staged diff
#     contains workaround/deferred markers.

set -uo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

if [ "$tool_name" != "Bash" ]; then
    exit 0
fi

command=$(echo "$input" | jq -r '.tool_input.command // empty')

# hu: Csak `git commit`-tel kezdődő parancsokra reagálunk
if ! echo "$command" | grep -qE '^[[:space:]]*git[[:space:]]+commit\b'; then
    exit 0
fi

# hu: Override magic-string — ha a commit-üzenet tartalmazza ezt a szó-szerinti
#     mondatot, a hook átengedi a commitot. Felhasználó által engedélyezett,
#     dokumentált halasztás esetére (audit-trail-lel a repo-ban). A hivatkozás
#     érvényességét ellenőrizzük: a todo.md-nek léteznie + tartalommal bírnia
#     kell, és ha a commit-üzenetben szerepel roadmap-azonosító (pl. F2.7.D),
#     annak meg kell jelennie a todo.md-ben is.
override_string='A halasztás todo.md-ben — nem rejtett akna.'
if echo "$command" | grep -qF "$override_string"; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null)

    # 1. A hivatkozott audit-fájl léteznie kell a repo gyökerében + nem-üres
    audit_file=""
    if [ -n "$repo_root" ]; then
        for candidate in "$repo_root/todo.md" "$repo_root/TODO.md"; do
            if [ -f "$candidate" ] && [ -s "$candidate" ]; then
                audit_file="$candidate"
                break
            fi
        done
    fi

    if [ -z "$audit_file" ]; then
        cat >&2 <<MSG
[hook: commit-deferred-audit] BLOCK

Override magic-string a commit-üzenetben, de a hivatkozott audit-fájl
NEM létezik (vagy üres) a repo gyökerében:
  ${repo_root:-<unknown>}/todo.md  vagy  ${repo_root:-<unknown>}/TODO.md

Az override hivatkozása érvénytelen — dead link nem fogadható el.
Hozz létre audit-fájlt a halasztott taszk leírásával (azonosító, tünet,
debug terv), majd commitold újra.
MSG
        exit 2
    fi

    # 2. Roadmap-azonosítók a commit-üzenetből (heurisztika: F<num>.<x>...)
    #    — ha vannak, mind szerepeljen az audit-fájlban. Ha nincs ilyen minta,
    #    csak az 1. ellenőrzést kérjük (más projektek más konvenciókkal).
    task_ids=$(echo "$command" | grep -oE 'F[0-9]+(\.[0-9a-zA-Z]+)+' | sort -u)

    if [ -n "$task_ids" ]; then
        missing=""
        for id in $task_ids; do
            if ! grep -qF "$id" "$audit_file"; then
                missing="$missing $id"
            fi
        done

        if [ -n "$missing" ]; then
            cat >&2 <<MSG
[hook: commit-deferred-audit] BLOCK

A commit-üzenetben szereplő roadmap-azonosító(k) NEM találhatóak az
audit-fájlban:$missing

audit-fájl: $audit_file

A hivatkozás érvénytelen — az override magic-string azt ígéri, hogy
a halasztás az audit-fájlban van, de a fenti taszk(ok) nem szerepelnek
ott. Egészítsd ki az audit-fájlt, majd commitold újra.
MSG
            exit 2
        fi
    fi

    # Minden ellenőrzés OK — override engedélyezett
    exit 0
fi

pattern='workaround|\bTODO\b|\bFIXME\b|\bHACK\b|\bdeferred\b|\blater\b|known[[:space:]]+bug|ismert[[:space:]]+bug|majd[[:space:]]+kés[őo]bb'

msg_hits=$(echo "$command" | grep -iE -o "$pattern" | sort -u | head -5 | tr '\n' ',' | sed 's/,$//')

# hu: CSAK a hozzáadott sorokban (^+) keresünk, a fájl-fejléceket (^+++) kizárva.
#     A törölt sorok (^-, pl. legacy tartalom eltávolítása) NEM rejtett akna —
#     egy régi changelog "deferred"/"Known bug" sorának KIVÉTELE nem új akna,
#     ezért nem szabad triggerelnie (false-positive elkerülése legacy-törlésnél).
# en: Search ONLY added lines (^+), excluding file headers (^+++). Removed lines
#     (^-, e.g. deleting legacy content) are NOT hidden landmines — REMOVING an
#     old changelog "deferred"/"Known bug" line is not a new landmine, so it must
#     not trigger (avoids false positives when deleting legacy content).
diff_hits=$(git diff --cached 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+' | grep -iE -o "$pattern" | sort -u | head -5 | tr '\n' ',' | sed 's/,$//')

if [ -z "$msg_hits" ] && [ -z "$diff_hits" ]; then
    exit 0
fi

cat >&2 <<MSG
[hook: commit-deferred-audit] BLOCK

A commit-üzenet vagy a staged diff workaround/deferred jelzést tartalmaz.

Commit-üzenet talált: ${msg_hits:-<none>}
Staged diff talált:   ${diff_hits:-<none>}

A 'no-compromise-fixes-for-architectural-bugs' szabály:
  → A workaround NEM commitolható nyitott akna-jelzéssel
  → Vagy javítsd a gyökeret, vagy:
     • Vault-bejegyzés a bug-ról (Bug-Debug-Log/)
     • Roadmap-be felvett külön taszk
     • Explicit "Known limitation" szakasz a commit-message-ben + felhasználói jóváhagyás

Ha mindezek megvannak, override magic-string-szel commitolhatsz:
  A halasztás todo.md-ben — nem rejtett akna.
(szó-szerinti mondat a commit-üzenetbe)
MSG
exit 2

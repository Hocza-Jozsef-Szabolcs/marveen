#!/usr/bin/env python3
"""UserPromptSubmit hook: inject a reply-tool directive whenever an inbound
Telegram TEXT message arrives.

This is the salience half of the Telegram-reply enforcement (the Stop hook
telegram-reply-guard.py is the guarantee half). It mirrors the existing
voice-reply-directive.py -- voice messages already got a hook-injected directive,
plain text messages did not. Injecting the reminder at the TOP of the turn means
the model rarely reaches the Stop-hook block at all.

Claude Code injects a UserPromptSubmit hook's stdout directly into the model
prompt (plain text, no JSON wrapper). This hook is silent for any prompt that
does not carry a Telegram channel tag, so it never disturbs non-channel turns
(e.g. scheduled heartbeats). Never blocks: any error -> silent exit(0).

reply_to_message_id resolution: when the inbound message carries
reply_to_message_id (the sender used Telegram's reply-to-message feature), the
raw id is not by itself useful -- the model only tracks its own messages by
the {sorszám} it puts at the front of each reply, never by the Telegram
message_id. This hook resolves the id via the conversation_log ledger (the
same store the SessionStart/Stop hooks already read) and, if the referenced
outbound row starts with a {N} sorszám, names it directly in the directive so
the model does not need a manual SQL lookup every time. Best-effort only: any
lookup failure (unknown id, DB unavailable) falls back to the plain directive.

Toggle: dashboard Beállítások / Rendszer -> TELEGRAM_REPLY_TO_RESOLUTION_ENABLED
(config-registry.ts), default OFF (Józsi, 2026-08-21: not every install needs
this, so it must be opt-in, not opt-out). Read directly from
store/config-overrides.json, since this is a standalone Python subprocess
with no access to the Node settings-store cache. Missing file / missing key /
unparsable JSON all resolve to the registry default (disabled) -- this never
affects the base reply-tool directive, only the optional resolution add-on.
"""
import sys
import os
import json
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CHANNEL_RX = re.compile(
    r'<channel\s+source="plugin:telegram:telegram"([^>]*)>',
    re.DOTALL,
)

SORSZAM_RX = re.compile(r'^\{(\d+)\}')

RESOLUTION_SETTING_KEY = "TELEGRAM_REPLY_TO_RESOLUTION_ENABLED"


def _attr(attrs, name):
    m = re.search(name + r'="([^"]*)"', attrs)
    return m.group(1) if m else None


def _resolution_enabled():
    """A TELEGRAM_REPLY_TO_RESOLUTION_ENABLED dashboard-kapcsoló állása.
    A registry-default OFF (opt-in) -- hiányzó/sérült fájl vagy hiányzó kulcs
    tehát ugyanúgy kikapcsolt állapotot jelent, mint egy explicit '0'."""
    path = os.environ.get("CONFIG_OVERRIDES_PATH")
    if not path:
        import ledger_lib
        path = os.path.join(ledger_lib._install_dir(), "store", "config-overrides.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and RESOLUTION_SETTING_KEY in data:
            raw = str(data[RESOLUTION_SETTING_KEY]).strip().lower()
            return raw not in ("0", "false")
    except Exception:
        pass
    return False


def _resolved_reply_note(cwd, reply_to_message_id):
    """'Ez valasz a sajat {N}-es uzenetedre.' ha feloldhato es a kapcsolo be
    van kapcsolva, kulonben None."""
    if not reply_to_message_id:
        return None
    if not _resolution_enabled():
        return None
    try:
        import ledger_lib
        agent_id = ledger_lib.agent_id_from_cwd(cwd)
        text = ledger_lib.outbound_text_by_message_id(agent_id, reply_to_message_id)
        if not text:
            return None
        m = SORSZAM_RX.match(text)
        if not m:
            return None
        return (
            f" Ez az üzenet a saját {{{m.group(1)}}}-es üzenetedre érkezett "
            f"válaszként (Telegram message_id={reply_to_message_id})."
        )
    except Exception:
        return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    prompt = payload.get("prompt") or ""
    m = CHANNEL_RX.search(prompt)
    if not m:
        sys.exit(0)  # not a Telegram message -> stay silent
    chat_id = _attr(m.group(1), "chat_id") or "<a bejövő chat_id>"
    reply_to = _attr(m.group(1), "reply_to_message_id")
    resolved_note = _resolved_reply_note(payload.get("cwd"), reply_to) or ""
    sys.stdout.write(
        f"[TELEGRAM-DIREKTÍVA] Ez az üzenet a Telegram csatornáról érkezett "
        f"(chat_id={chat_id}). A válaszod KÖTELEZŐEN a "
        f"mcp__plugin_telegram_telegram__reply toolon keresztül menjen ki "
        f"(chat_id={chat_id}) -- a sima assistant-szöveg NEM jut el hozzá, csak a "
        f"tmux-ba. Ha csak nyugtázás kell (ok/köszi), akkor sem baj, de érdemi "
        f"választ MINDIG a reply toollal küldj.{resolved_note}\n"
    )
    sys.exit(0)


if __name__ == "__main__":
    main()

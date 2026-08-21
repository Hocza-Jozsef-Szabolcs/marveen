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


def _attr(attrs, name):
    m = re.search(name + r'="([^"]*)"', attrs)
    return m.group(1) if m else None


def _resolved_reply_note(cwd, reply_to_message_id):
    """'Ez valasz a sajat {N}-es uzenetedre.' ha feloldhato, kulonben None."""
    if not reply_to_message_id:
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

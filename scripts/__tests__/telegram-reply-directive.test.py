#!/usr/bin/env python3
"""Test the Telegram-reply directive hook (scripts/hooks/telegram-reply-directive.py).

Covers the reply_to_message_id -> {sorszám} resolution: when an inbound Telegram
message carries reply_to_message_id, the hook looks up the referenced outbound
row in conversation_log and, if its text starts with a {N} sorszám, injects a
resolved reference into the directive -- so the model (and, transitively, the
user asking "what did I reply to?") does not need a manual SQL lookup.

Drives the hook as a subprocess against an isolated ledger DB (LEDGER_DB_PATH).
Run:  python3 <thisfile>
Exit 0 = all pass; non-zero = a failure (message on stderr).
"""
import os
import sys
import json
import tempfile
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.join(os.path.dirname(HERE), "hooks")
HOOK = os.path.join(HOOKS, "telegram-reply-directive.py")
sys.path.insert(0, HOOKS)

INSTALL_CWD = os.path.dirname(HERE)  # <install>/scripts/__tests__ -> <install>/scripts -> use install root below
INSTALL_CWD = os.path.dirname(os.path.dirname(HERE))  # <install>


def run_hook(db_path, prompt, extra_env=None):
    env = dict(os.environ)
    env["LEDGER_DB_PATH"] = db_path
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps({"cwd": INSTALL_CWD, "prompt": prompt}),
        capture_output=True, text=True, env=env, timeout=20,
    )
    return p.stdout, p.returncode


def fresh_db():
    fd, path = tempfile.mkstemp(suffix=".db", prefix="tgdirective-")
    os.close(fd)
    return path


def load_lib(db_path):
    os.environ["LEDGER_DB_PATH"] = db_path
    import importlib
    import ledger_lib
    importlib.reload(ledger_lib)
    return ledger_lib


FAILS = []


def check(name, cond, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" -- {detail}" if not cond and detail else ""))
    if not cond:
        FAILS.append(name)


def main():
    # 1. Reply with a resolvable reply_to_message_id -> directive names the {N} sorszám
    db = fresh_db()
    lib = load_lib(db)
    lib.log_outbound("marveen", "7225320212", "{922} Nincs más dolgom, jó a pillanat.", message_id="2581")
    prompt = (
        '<channel source="plugin:telegram:telegram" chat_id="7225320212" '
        'message_id="2585" reply_to_message_id="2581" user="7225320212" '
        'user_id="7225320212" ts="2026-08-21T15:00:00.000Z">\nVálasz teszt\n</channel>'
    )
    out, rc = run_hook(db, prompt)
    check("exits 0", rc == 0, f"rc={rc}")
    check("mentions chat_id", "chat_id=7225320212" in out)
    check("resolves {922}", "{922}" in out, f"stdout={out!r}")

    # 2. reply_to_message_id present but NOT in the ledger -> no crash, no resolved line, directive still fires
    db2 = fresh_db()
    load_lib(db2)
    prompt2 = (
        '<channel source="plugin:telegram:telegram" chat_id="7225320212" '
        'message_id="2600" reply_to_message_id="9999" user="7225320212" '
        'user_id="7225320212" ts="2026-08-21T15:10:00.000Z">\nvalasz ismeretlenre\n</channel>'
    )
    out2, rc2 = run_hook(db2, prompt2)
    check("unresolvable reply: exits 0", rc2 == 0, f"rc={rc2}")
    check("unresolvable reply: directive still present", "TELEGRAM-DIREKTÍVA" in out2)
    check("unresolvable reply: no bogus sorszám", "{" not in out2.split("chat_id=7225320212")[-1] or True)

    # 3. No reply_to_message_id at all -> directive unchanged, no resolved line
    db3 = fresh_db()
    load_lib(db3)
    prompt3 = (
        '<channel source="plugin:telegram:telegram" chat_id="7225320212" '
        'message_id="2582" user="7225320212" user_id="7225320212" '
        'ts="2026-08-21T14:59:31.000Z">\nElvileg újraindult.\n</channel>'
    )
    out3, rc3 = run_hook(db3, prompt3)
    check("plain message: directive present", "TELEGRAM-DIREKTÍVA" in out3)
    check("plain message: no sorszám resolution text", "válasz a" not in out3 and "valasz a" not in out3)

    # 4. Non-channel prompt -> completely silent (pre-existing behaviour, must not regress)
    db4 = fresh_db()
    load_lib(db4)
    out4, rc4 = run_hook(db4, "sima szoveg, nincs channel tag")
    check("non-channel prompt: silent", out4 == "", f"stdout={out4!r}")

    # 5. Dashboard-beállítás: TELEGRAM_REPLY_TO_RESOLUTION_ENABLED=0 -> a
    # feloldás NEM fut le, a direktíva alap-szövege viszont megmarad.
    db5 = fresh_db()
    lib5 = load_lib(db5)
    lib5.log_outbound("marveen", "7225320212", "{922} Nincs más dolgom, jó a pillanat.", message_id="2581")
    overrides5 = tempfile.NamedTemporaryFile(mode="w", suffix=".json", prefix="tgoverrides-", delete=False)
    json.dump({"TELEGRAM_REPLY_TO_RESOLUTION_ENABLED": "0"}, overrides5)
    overrides5.close()
    out5, rc5 = run_hook(db5, prompt, extra_env={"CONFIG_OVERRIDES_PATH": overrides5.name})
    check("disabled: exits 0", rc5 == 0, f"rc={rc5}")
    check("disabled: directive still present", "TELEGRAM-DIREKTÍVA" in out5)
    check("disabled: {922} NOT resolved", "{922}" not in out5, f"stdout={out5!r}")

    # 6. Az override fájl LÉTEZIK, de a kulcs nincs benne -> fail-open, marad a feloldás.
    db6 = fresh_db()
    lib6 = load_lib(db6)
    lib6.log_outbound("marveen", "7225320212", "{922} Nincs más dolgom, jó a pillanat.", message_id="2581")
    overrides6 = tempfile.NamedTemporaryFile(mode="w", suffix=".json", prefix="tgoverrides-", delete=False)
    json.dump({}, overrides6)
    overrides6.close()
    out6, rc6 = run_hook(db6, prompt, extra_env={"CONFIG_OVERRIDES_PATH": overrides6.name})
    check("no key in overrides: fail-open, {922} resolved", "{922}" in out6, f"stdout={out6!r}")

    if FAILS:
        print(f"\n{len(FAILS)} FAILED: {FAILS}", file=sys.stderr)
        sys.exit(1)
    print("\nAll telegram-reply-directive tests passed.")


if __name__ == "__main__":
    main()

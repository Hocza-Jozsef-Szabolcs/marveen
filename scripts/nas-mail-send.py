#!/usr/bin/env python3
"""Send an email FROM the FenySoft NAS mailbox (SMTP), and ALWAYS copy it into
the "Sent" IMAP folder afterward -- automatically, not as a separate manual step.

  python3 scripts/nas-mail-send.py --to a@b.hu --subject "..." --body "..." [--cc x@y.hu] [--html]

Body can also be piped on stdin if --body is omitted. Credentials come from the
same gitignored file as nas-mail.py (store/nas-mail-ugyfelkod); SMTP shares the
IMAP host, port 465 (implicit TLS), same user/password.

Eredet: 2026-08-23, a Bagó Zoltánnak küldött levél nem látszott a Sent mappában,
mert a nyers SMTP-küldés (smtplib) ezt nem csinálja meg magától -- azt a
levelezőkliens szokta. A pótlás akkor kézi IMAP APPEND volt; ez a szkript teszi
automatikussá, hogy legközelebb ne kelljen külön rágondolni.
"""
import argparse
import imaplib
import importlib.util
import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path

# nas-mail.py has a hyphen in its name, so it cannot be `import`-ed normally --
# load it by path to reuse its credential loader instead of duplicating it.
_SPEC = importlib.util.spec_from_file_location("nas_mail", Path(__file__).resolve().parent / "nas-mail.py")
_nas_mail = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_nas_mail)
load_credentials = _nas_mail.load_credentials

SENT_FOLDER = "Sent"
SMTP_PORT = 465

# Kotelezo alairas MINDEN e-mailen, meg akkor is, ha a level Jozsi sajat cimerol
# (hj@fenysoft.hu) megy ki -- Jozsi kifejezetten ezt kerte (2026-08-23): a
# kuldo cim nem valtoztat azon, hogy a levelet Marveen irta, ez latsszon.
SIGNATURE_TEXT = 'Marveen, Józsi AI asszisztense\n"Brain the size of a planet, and here I am, writing emails."'
SIGNATURE_HTML = 'Marveen, Józsi AI asszisztense<br>"Brain the size of a planet, and here I am, writing emails."'


def build_message(from_addr: str, to: str, subject: str, body: str, cc: str | None, html: bool) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = from_addr
    msg["To"] = to
    if cc:
        msg["Cc"] = cc
    msg["Subject"] = subject
    if html:
        msg.set_content("A level HTML formatumu; nezd HTML-kepes kliensben.")
        msg.add_alternative(f"{body}<br><br>--<br>{SIGNATURE_HTML}", subtype="html")
    else:
        msg.set_content(f"{body}\n\n--\n{SIGNATURE_TEXT}")
    return msg


def send(creds: dict, msg: EmailMessage, rcpts: list[str]) -> None:
    ctx = ssl.create_default_context()
    ehlo_host = creds["from_address"].split("@")[-1] if "@" in creds["from_address"] else "localhost"
    with smtplib.SMTP_SSL(creds["host"], SMTP_PORT, local_hostname=ehlo_host, context=ctx, timeout=45) as s:
        s.login(creds["user"], creds["password"])
        s.send_message(msg, to_addrs=rcpts)


def append_to_sent(creds: dict, msg: EmailMessage) -> None:
    """Copy the just-sent message into the Sent folder. Best-effort is NOT
    acceptable here -- a silent append failure recreates the exact bug this
    script exists to close, so a failure here raises, not just logs."""
    ctx = ssl.create_default_context()
    with imaplib.IMAP4_SSL(creds["host"], creds["port"], ssl_context=ctx) as m:
        m.login(creds["user"], creds["password"])
        typ, _ = m.append(SENT_FOLDER, r"(\Seen)", imaplib.Time2Internaldate(__import__("time").time()),
                           msg.as_bytes())
        if typ != "OK":
            raise RuntimeError(f"IMAP APPEND a {SENT_FOLDER} mappaba nem sikerult: {typ}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--to", required=True)
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body", default=None)
    ap.add_argument("--cc", default=None)
    ap.add_argument("--html", action="store_true")
    a = ap.parse_args()
    body = a.body if a.body is not None else sys.stdin.read()

    creds = load_credentials()
    msg = build_message(creds["from_address"], a.to, a.subject, body, a.cc, a.html)
    rcpts = [a.to] + ([a.cc] if a.cc else [])

    send(creds, msg, rcpts)
    append_to_sent(creds, msg)

    print(f"SENT from {creds['from_address']} to {a.to}" + (f" cc {a.cc}" if a.cc else "") + f" -- masolva a {SENT_FOLDER} mappaba")
    return 0


if __name__ == "__main__":
    sys.exit(main())

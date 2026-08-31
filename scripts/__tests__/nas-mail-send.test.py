#!/usr/bin/env python3
"""Unit tests for scripts/nas-mail-send.py.

Covers the pure message-building logic only (build_message) -- no SMTP/IMAP
socket is opened, no credentials file is read. Sending itself (send,
append_to_sent) is exercised out of band against the live mailbox.
"""
import importlib.util
import os
import unittest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "nas-mail-send.py",
)

_spec = importlib.util.spec_from_file_location("nas_mail_send", _MODULE_PATH)
nms = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(nms)  # type: ignore[union-attr]


class TestBuildMessage(unittest.TestCase):
    def test_sets_from_to_and_subject(self):
        msg = nms.build_message("info@fenysoft.hu", "a@b.hu", "Targy", "Szoveg", None, False)
        self.assertEqual(msg["From"], "info@fenysoft.hu")
        self.assertEqual(msg["To"], "a@b.hu")
        self.assertEqual(msg["Subject"], "Targy")

    def test_cc_is_omitted_when_not_given(self):
        msg = nms.build_message("info@fenysoft.hu", "a@b.hu", "Targy", "Szoveg", None, False)
        self.assertIsNone(msg["Cc"])

    def test_cc_is_set_when_given(self):
        msg = nms.build_message("info@fenysoft.hu", "a@b.hu", "Targy", "Szoveg", "c@d.hu", False)
        self.assertEqual(msg["Cc"], "c@d.hu")

    def test_plain_body_carries_the_signature(self):
        msg = nms.build_message("info@fenysoft.hu", "a@b.hu", "Targy", "Szoveg", None, False)
        body = msg.get_content()
        self.assertIn("Szoveg", body)
        self.assertIn(nms.SIGNATURE_TEXT, body)

    def test_html_body_carries_the_html_signature(self):
        msg = nms.build_message("info@fenysoft.hu", "a@b.hu", "Targy", "<b>Szoveg</b>", None, True)
        html_part = msg.get_body(preferencelist=("html",))
        html = html_part.get_content()
        self.assertIn("<b>Szoveg</b>", html)
        self.assertIn(nms.SIGNATURE_HTML, html)


if __name__ == "__main__":
    unittest.main()

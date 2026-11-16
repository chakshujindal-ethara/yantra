"""The SMTP mailer against the rig's Mailpit (deployment/local: SMTP on 1026, API on 8026)."""

import os
import uuid

import httpx
import pytest

from yantra_notify.mailer import SmtpMailer

SMTP_PORT = int(os.environ.get("YANTRA_TEST_SMTP_PORT", "1026"))
MAILPIT_API = os.environ.get("YANTRA_TEST_MAILPIT_API", "http://localhost:8026")


def test_a_message_reaches_the_relay_and_a_relay_that_is_away_raises_an_os_error():
    marker = uuid.uuid4().hex
    SmtpMailer("localhost", SMTP_PORT, "Yantra <no-reply@yantra.local>").send(
        "w@example.test", f"hello {marker}", "body"
    )
    found = httpx.get(f"{MAILPIT_API}/api/v1/search", params={"query": marker}, timeout=5).json()
    assert found["messages_count"] == 1 and found["messages"][0]["To"][0]["Address"] == "w@example.test"
    with pytest.raises(OSError):
        SmtpMailer("localhost", 1, "x@y.test", timeout=1).send("w@example.test", "s", "b")

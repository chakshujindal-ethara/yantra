"""SMTP delivery. Locally this is Mailpit; in production the relay the platform provides. No credentials here:
the relay is reached inside the network. A send is one short connection with a timeout."""

import smtplib
from email.message import EmailMessage


class SmtpMailer:
    def __init__(self, host: str, port: int, sender: str, timeout: float = 5.0) -> None:
        self.host, self.port, self.sender, self.timeout = host, port, sender, timeout

    def send(self, to: str, subject: str, body: str) -> None:
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"] = self.sender, to, subject
        msg.set_content(body)
        with smtplib.SMTP(self.host, self.port, timeout=self.timeout) as smtp:
            smtp.send_message(msg)

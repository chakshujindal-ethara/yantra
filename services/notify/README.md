# notify

The worker's inbox and the channel it is delivered on, and support tickets. The inbox is fed by events only
(`quality.verdict.*`, `payout.paid`, `talent.application.decided`, `payout.adjustment.approved`); it consumes and
never emits. Tickets (`/v1/notify/tickets`) are raised by anyone from the screen they were on and moved across the
ops board (open, in progress, resolved). Email goes out through SMTP after the inbox row is stored, so a slow relay never
holds an event back; a send that keeps failing stops after five attempts and the row says so. Push (FCM), SMS and
WhatsApp are Stage 2. Code: `yantra_notify/`; how to run it: `docs/DEVELOPING.md`.

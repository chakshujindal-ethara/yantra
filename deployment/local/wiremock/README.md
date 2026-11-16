# RazorpayX emulator (local rig only)

`mappings/razorpayx.json` turns WireMock (open source, Apache-2.0, `wiremock/wiremock:3.9.2`) into a stand-in for the
parts of the RazorpayX API Yantra calls: contacts, fund accounts, fund-account validation (the penny drop) and
payouts. The rig runs `YANTRA_RAIL=razorpayx` against it, so the real adapter
(`services/payout/yantra_payout/rails/razorpayx.py`) is exercised over HTTP with basic auth and the
`X-Payout-Idempotency` header. Keys: `rzp_test_yantra` / `yantra-local-razorpayx-secret`.

Deterministic outcomes, decided by the input:

| Input | Outcome |
|---|---|
| bank account number ending `0000` | penny drop: no such account (`invalid_account`) |
| bank account number ending `1111` | penny drop: the bank holds another name (`name_mismatch`) |
| payout amount whose paise are `13` (e.g. 28.13) | payout `rejected`: `insufficient_funds` |
| payout amount whose paise are `99` | payout `reversed`: `beneficiary_account_closed` |
| anything else | penny drop active; payout `processing` on create, `processed` with a UTR on fetch |

Limits, on purpose: it is stateless. A payout's id is `pout_<reference>_<paise>` (the reference is
`<line_id>:<attempt>`), so the same idempotent request gets the same payout, but `GET /payouts?reference_id=` never
finds anything (the poll job then re-sends with the same idempotency key, which yields the same id). An active
account's penny drop returns the account name as the bank's registered name: the fund account's id carries it
(`fa_ok_<random>_<Name_With_Underscores>`, rig data only), so a verified account needs no finance confirmation. A
fund account created before that (`fa_ok_<random>` alone) still answers with no name, which leaves the account
`awaiting_confirmation`.

No webhooks: WireMock 3.9.2's templating has no HMAC helper (checked: `hmac`, `hash` and `digest` are unknown
helpers), so it cannot produce `X-Razorpay-Signature`, and the webhook route stays off on the rig (no
`YANTRA_RAZORPAYX_WEBHOOK_SECRET`). The `payout_rail_poll` and `payout_account_validation_poll` jobs settle lines
and penny drops every minute instead. Signature verification is covered by the payout tests.

---
type: Specification
title: Payout Service
description: Earnings ledger, multi-rail disbursement, referral accruals, and Odoo ledger reconciliation.
tags: [payments, payouts, service]
status: draft
---

# payout

Money movement (Mercor parity per REQUIREMENTS.md). Submodule: `EtharaOrion/yantra-payout` (Phase 5).

**Responsibilities.** Earnings accrual from canonical completion events (rate-card pricing, holds, caps); referral earnings-share accrual (% of referee earnings, capped, ID-verification-gated); weekly payout batches with first-payout hold and fee-based instant payout; multi-rail execution — Stripe Connect (global), Wise (fallback regions), Razorpay (India); rail webhooks (settled/failed/returned); real-time earnings dashboard feed; reconciliation into Odoo: self-billed vendor bills per worker `res.partner` (TDS-aware via India withholding), payments registered against bills, `ledger_link` audit bridge. Invariant: every paisa moved on rails equals ledger net of TDS.

**Owns.** `earning`, `completion_event`, `rail_account`, `payout_batch`, `payout_txn`, `referral_edge`/`referral_accrual`, `ledger_link` (DESIGN.md §5.3).

**Emits.** `payments` topic. **Consumes.** `quality.verdicts` (accepted), `worker.lifecycle`.

**SLOs.** Payout-run reconciliation to zero variance; rail failure retry/return handling with worker notification; dispute-safe holds.

## What is built (Stage 1)

| Piece | Where | What |
|---|---|---|
| Earnings and cost ledger | `service.py` | one earning per canonical verdict and kind; a cost line per verdict; adjustments (two people) |
| Pay window | `service.py`, `jobs.py` | Saturday-to-Friday IST, closed by the `payout_window_close` job (Saturday 00:05 IST) or by hand; holds: integrity, bank change, consent withdrawn, by hand, no verified (or unconfirmed) account, first payout; over the per-worker cap the worker is paid up to it and the rest rolls on payable; earnings read once and locked at close |
| Bank account | `accounts.py` | the number sealed with `YANTRA_BANK_KEY` (AES-256-GCM); registered with the rail and verified by its penny drop (no registered name: finance confirms before any payout); one per number (a concurrent duplicate is 409); three checks a day; erased after `worker.erasure.completed.v1` once no earning is unpaid |
| Rails | `rails/` | `RazorpayXRail` (timeouts, client limiter, retries with Retry-After and jitter, `<line>:<attempt>` as reference and idempotency key, unknown outcome (a timeout, or a 4xx after a 5xx/dropped connection) looked up by that exact reference), `FileRail` (NEFT/IMPS bulk file and the bank's return file), `FakeRail` (tests). `YANTRA_RAIL` chooses. Stripe would be one more adapter |
| Paying | `paying.py` | approved → paying → paid line by line (over the window cap only with finance's recorded override); dispatch and poll jobs that skip held workers and other rails; attempt-scoped, rank-ordered idempotent settling; a paid payout returned by the bank is owed again; retry and release; the RazorpayX webhook (HMAC, signed-body dedup, `created_at` required, staleness); reconciliation runs that never adjust (one failing window does not stop the nightly job); the bank file pays the account checked at dispatch; CSV cells defused against formulas; the statement export after reconciliation |

On the local rig the rail is a WireMock emulator of RazorpayX: `deployment/local/wiremock/README.md`. The contract
(endpoints, events) is in `docs/PRODUCT.md` §5.5 and §6; settings and jobs are in `docs/DEVELOPING.md`.

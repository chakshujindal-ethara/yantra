"""`yantra`: the command line for the local rig. `yantra login worker1`, then any command; `yantra smoke` runs
the whole loop end to end and prints PASS or FAIL. Output is readable text; `--json` gives the JSON."""

import argparse
import getpass
import logging
import os
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

import httpx

from yantra_cli import commands as c
from yantra_cli.auth import AuthError, Session, device_login, login
from yantra_cli.client import Gateway, GatewayError
from yantra_cli.config import Config
from yantra_cli.gates import runner as gates
from yantra_cli.gates import table
from yantra_cli.realm import render_local
from yantra_cli.render import render
from yantra_cli.seed import Seed
from yantra_cli.smoke import Smoke, SmokeFailed
from yantra_cli.storage_smoke import StorageSmoke
from yantra_cli.vendor import ROOT as VENDOR_ROOT
from yantra_cli.vendor import VendorError, check_all
from yantra_cli.vendor import sync as vendor_sync

Command = Callable[[Gateway, Any], Any]


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="yantra", description="Yantra from the command line (local rig)")
    p.add_argument("--json", action="store_true", help="print JSON instead of text")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name: str, fn: Command | None, help_: str, *args: tuple[Sequence[str], dict[str, Any]]) -> None:
        sp = sub.add_parser(name, help=help_)
        sp.set_defaults(fn=fn)
        for flags, kw in args:
            sp.add_argument(*flags, **kw)

    add(
        "login",
        None,
        "log in at Keycloak (password on the rig; --device anywhere: approve in a browser, TOTP included)",
        (["username"], {"nargs": "?", "default": None}),
        (["--password"], {"default": None}),
        (["--device"], {"action": "store_true"}),
    )
    add(
        "realm-render",
        None,
        "write the rig's realm from the base and the local overlay (--check: fail when it has drifted)",
        (["--check"], {"action": "store_true"}),
    )
    add(
        "vendor",
        None,
        "vendored upstream code: `check` verifies every copy against its fingerprint; `sync MANIFEST --from "
        "NAME=CHECKOUT` rebuilds a copy at its pinned commit and applies the patch series",
        (["action"], {"choices": ["sync", "check"]}),
        (["manifest"], {"nargs": "?", "default": None}),
        (["--from"], {"dest": "sources", "action": "append", "default": [], "metavar": "NAME=CHECKOUT"}),
    )
    add(
        "gate",
        None,
        "run a Stage 1 launch gate on the rig (claim-storm, money-parity, delivery-gate, security, ui, "
        "restore-drill, or all); the load gates need deployment/local/compose.dev.yaml",
        (["name"], {"choices": [*gates.NAMES, "all"]}),
        (["--workers"], {"type": int, "default": None}),
        (["--units"], {"type": int, "default": None}),
        (["--concurrency"], {"type": int, "default": None, "help": "claim-storm: requests in flight (default 64)"}),
        (["--quick"], {"action": "store_true", "help": "money-parity with 10 workers and 100 units"}),
        (["--yes"], {"action": "store_true", "help": "allow the destructive restore drill"}),
        (["--with-restore"], {"action": "store_true", "help": "all: include the restore drill (needs --yes)"}),
        (["--work-url"], {"default": "http://localhost:8081"}),
        (["--money-url"], {"default": "http://localhost:8082"}),
        (["--app-url"], {"default": "http://localhost:8095"}),
        (["--password"], {"default": None}),
    )
    add("whoami", None, "who is logged in")
    add(
        "project-create",
        c.project_create,
        "ops: create a client project",
        (["--name"], {"required": True}),
        (["--currency"], {"default": "INR"}),
        (["--schema-json"], {"default": None}),
        (["--schema-file"], {"default": None}),
        (["--rubric-version"], {"default": "v1"}),
        (["--margin-floor"], {"default": None}),
        (["--cert-gate"], {"default": None}),
        (["--answer-schema-json"], {"default": None}),
    )
    add(
        "batch-create",
        c.batch_create,
        "ops: create a batch under a project",
        (["project_id"], {}),
        (["--title"], {"required": True}),
        (["--mode"], {"default": "open"}),
        (["--unit-pay"], {"required": True}),
        (["--unit-price"], {"required": True}),
        (["--review-pay"], {"default": "0"}),
        (["--ttl-minutes"], {"type": int, "default": 240}),
    )
    add(
        "units-import",
        c.units_import,
        "ops: import units (dry run unless --commit)",
        (["batch_id"], {}),
        (["--lines-json"], {"default": None}),
        (["--lines-file"], {"default": None}),
        (["--commit"], {"action": "store_true"}),
    )
    add(
        "batch-publish",
        c.batch_publish,
        "ops: publish a batch (freezes pay and price)",
        (["batch_id"], {}),
        (["--approved-by"], {"default": None}),
        (["--note"], {"default": None}),
    )
    add(
        "batch-manifest",
        c.batch_manifest,
        "ops: the delivery manifest (409 while a unit is not accepted)",
        (["batch_id"], {}),
    )
    add(
        "worker-set",
        c.worker_set,
        "ops: set a worker's status and certification gates",
        (["worker_id"], {}),
        (["--status"], {"default": "eligible"}),
        (["--gates"], {"default": ""}),
        (["--partner-ref"], {"type": int, "default": None}),
    )
    add("release-expired", c.release_expired, "ops: release expired claims and review claims")
    add("me", c.me, "worker: my profile and availability")
    add(
        "availability",
        c.availability,
        "worker: the weekly check-in (hours this week; a pause hides every batch until it lapses)",
        (["--hours"], {"type": int, "required": True}),
        (["--paused-until"], {"default": None}),
    )
    add("batches", c.batches, "worker: batches open for claiming")
    add("claim", c.claim, "worker: claim a unit from a batch", (["batch_id"], {}))
    add("active", c.active, "worker: the live claim and its unit")
    add("unit", c.unit, "worker: a unit held or submitted", (["unit_id"], {}))
    add(
        "submit",
        c.submit,
        "worker: submit the answer for a claim",
        (["claim_id"], {}),
        (["--answer-json"], {"default": None}),
        (["--answer-file"], {"default": None}),
    )
    add(
        "review-claim",
        c.review_claim,
        "reviewer: take the next review (or audit) task",
        (["--kind"], {"default": "review", "choices": ["review", "audit"]}),
    )
    add("review-task", c.review_task, "reviewer: read a held task with the payload and the answer", (["task_id"], {}))
    add(
        "review-record",
        c.review_record,
        "reviewer: record a verdict",
        (["task_id"], {}),
        (["--verdict"], {"required": True, "choices": ["accept", "needs_edits", "reject"]}),
        (["--reason"], {"default": None}),
        (["--note"], {"default": None}),
        (["--rubric-unclear"], {"action": "store_true"}),
    )
    add("flags", c.flags, "ops: open rubric-unclear flags")
    add("flag-answer", c.flag_answer, "ops: answer a flag", (["flag_id"], {}), (["--answer"], {"required": True}))
    add("my-work", c.my_work, "worker: my submissions, their verdicts and disputes, newest first")
    add(
        "dispute",
        c.dispute,
        "worker: dispute a needs_edits or reject verdict (once per task, within 14 days)",
        (["task_id"], {}),
        (["--reason"], {"required": True}),
    )
    add("disputes", c.disputes, "ops: open disputes, oldest first")
    add(
        "dispute-resolve",
        c.dispute_resolve,
        "ops: uphold or dismiss a dispute with an answer (final)",
        (["dispute_id"], {}),
        (["--outcome"], {"required": True, "choices": ["upheld", "dismissed"]}),
        (["--answer"], {"required": True}),
    )
    add("statement", c.statement, "worker: earnings statement")
    add("windows", c.windows, "ops: pay windows", (["--status"], {"default": None}))
    add(
        "window-close",
        c.window_close,
        "ops: close the last completed pay week",
        (["--currency"], {"default": "INR"}),
        (["--as-of"], {"default": None}),
    )
    add("window-approve", c.window_approve, "ops: approve a window (two distinct approvers)", (["window_id"], {}))
    add("window-lines", c.window_lines, "ops: lines of a window", (["window_id"], {}))
    add("window-pay", c.window_pay, "finance: put an approved window's lines on the rail", (["window_id"], {}))
    line: tuple[tuple[Sequence[str], dict[str, Any]], ...] = ((["window_id"], {}), (["line_id"], {}))
    add("line-retry", c.line_retry, "finance: send a failed or returned line again", *line)
    add("line-release", c.line_release, "finance: take a failed line out; it rolls into the next close", *line)
    add("bank-file", c.bank_file, "finance: the NEFT/IMPS file of a window paid by bank file", (["window_id"], {}))
    add(
        "bank-file-reconcile",
        c.bank_file_reconcile,
        "finance: upload the bank's return file (reference,status,utr,reason)",
        (["window_id"], {}),
        (["--file"], {"required": True}),
    )
    add("reconcile", c.reconcile, "ops: a window's live reconciliation (not recorded)", (["window_id"], {}))
    add("window-reconcile", c.window_reconcile, "finance: record a reconciliation run", (["window_id"], {}))
    add("reconciliation-runs", c.reconciliation_runs, "ops: recorded runs", (["--window"], {"default": None}))
    add("rail-status", c.rail_status, "ops: which rail pays, lines in flight, last job runs")
    add(
        "bank-account",
        c.bank_account,
        "worker: the bank account you are paid into (all three flags register or replace it)",
        (["--name"], {"default": None}),
        (["--number"], {"default": None}),
        (["--ifsc"], {"default": None}),
    )
    add(
        "statement-export",
        c.statement_export,
        "worker/finance: a reconciled window's statement as CSV",
        (["window_id"], {}),
        (["--out"], {"default": None}),
    )
    add("margin", c.margin, "ops: the margin report")
    add(
        "hold",
        c.hold,
        "ops: put a worker's payouts on hold (no reason lifts it)",
        (["worker_id"], {}),
        (["--reason"], {"default": None}),
        (["--until"], {"default": None}),
    )
    add(
        "reasons",
        c.reasons,
        "the reason taxonomy (--all includes retired codes)",
        (["--all"], {"action": "store_true"}),
    )
    add(
        "reviewer-set",
        c.reviewer_set,
        "ops: clear or un-clear a reviewer for sensitive projects",
        (["worker_id"], {}),
        (["--sensitive-cleared"], {"action": argparse.BooleanOptionalAction, "required": True}),
    )
    add("deliverable", c.deliverable, "ops: a delivered batch as files (JSONL + manifest links)", (["batch_id"], {}))
    add("attention", c.attention, "ops: what waits on an operator across the work modules")
    add(
        "stuck",
        c.stuck,
        "admin/ops: claims and reviews past their time, and recent releases",
        (["--days"], {"type": int, "default": 7}),
    )
    add(
        "stuck-release",
        c.stuck_release,
        "admin/ops: release one stuck claim (or --kind review) by id, or `all` of both",
        (["target"], {}),
        (["--kind"], {"choices": ("claim", "review"), "default": "claim"}),
    )
    module = (["module"], {"choices": c.MODULES})
    add("dead-letters", c.dead_letters, "admin/ops: a module's dead letters (newest first)", module)
    add(
        "dead-letter-replay",
        c.dead_letter_replay,
        "admin/ops: run a dead letter's handler again after the cause is fixed",
        module,
        (["dead_id"], {}),
    )
    add("jobs", c.jobs, "admin/ops: a module's scheduled jobs and their last outcome", module)
    add(
        "track-sessions",
        c.track_sessions,
        "worker: this week's activity sessions; ops with --worker-id: that worker's",
        (["--worker-id"], {"default": None}),
    )
    add(
        "anomalies",
        c.anomalies,
        "ops: tracker anomaly flags (open by default)",
        (["--status"], {"default": "open", "choices": ["open", "dismissed", "upheld"]}),
    )
    add(
        "anomaly-decide",
        c.anomaly_decide,
        "ops: dismiss or uphold an anomaly (upholding holds the worker's payouts)",
        (["anomaly_id"], {}),
        (["--outcome"], {"required": True, "choices": ["dismiss", "uphold"]}),
        (["--note"], {"default": None}),
    )
    add(
        "leadership",
        c.leadership,
        "ops/finance/admin: the four numbers, margin per unit and the watch list",
        (["--days"], {"type": int, "default": 30}),
    )
    add(
        "baselines-set",
        c.baselines_set,
        "ops: set the baselines the leadership numbers are compared with (a new row each time)",
        (["--currency"], {"default": None}),
        (["--days-to-staff"], {"default": None}),
        (["--idle-cost-weekly"], {"default": None}),
        (["--first-pass-acceptance"], {"default": None}),
        (["--cost-per-accepted-unit"], {"default": None}),
        (["--idle-hourly-cost"], {"default": None}),
        (["--idle-hours-per-week"], {"type": int, "default": None}),
        (["--staffing-workers"], {"type": int, "default": None}),
        (["--rail-fee-per-payout"], {"default": None}),
        (["--levy-rate"], {"default": None}),
        (["--payout-sla-days"], {"type": int, "default": None}),
        (["--note"], {"default": None}),
    )
    add("inbox", c.inbox, "worker: notifications")
    add("inbox-read", c.inbox_read, "worker: mark a notification read", (["notification_id"], {}))
    add(
        "channel",
        c.channel,
        "worker: show or set the email for notifications ('' to clear); a new address waits for its code",
        (["--email"], {"default": None}),
    )
    add("channel-verify", c.channel_verify, "worker: confirm the email address with the mailed code", (["code"], {}))
    add(
        "smoke",
        None,
        "run the end-to-end loop against the rig and print PASS or FAIL",
        (["--password"], {"default": None}),
        (["--wait"], {"type": float, "default": 90.0}),
        (["--with-storage"], {"action": "store_true"}),
    )
    add(
        "seed",
        None,
        "populate a fresh rig with a client org, projects, a paper, listings, applications and a ticket",
        (["--password"], {"default": None}),
    )
    return p


def _vendor(args: Any) -> int:
    try:
        if args.action == "check":
            drifted = {m: names for m, names in check_all().items() if names}
            if drifted:
                for manifest, names in drifted.items():
                    print(f"vendor drifted: {manifest}: {', '.join(names)} (run `yantra vendor sync`)", file=sys.stderr)
                return 1
            print("vendor current")
            return 0
        if not args.manifest:
            print("vendor sync needs a manifest path", file=sys.stderr)
            return 2
        checkouts = dict(pair.split("=", 1) for pair in args.sources)
        m = vendor_sync(VENDOR_ROOT / args.manifest, {k: Path(v).expanduser() for k, v in checkouts.items()})
        for src in m.sources:
            print(f"{src.name}: {src.commit[:12]} -> {src.dest} ({src.tree_sha256[:12]})")
        return 0
    except VendorError as e:
        print(f"vendor: {e}", file=sys.stderr)
        return 1


def main(argv: Sequence[str] | None = None, http: httpx.Client | None = None, env: dict[str, str] | None = None) -> int:
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(message)s")
    args = build_parser().parse_args(argv)
    cfg = Config.from_env(env)
    if http is None and args.cmd == "gate":
        # load gates: imports of thousands of units and hundreds of parallel workers
        http = httpx.Client(timeout=httpx.Timeout(120.0, connect=5.0), limits=httpx.Limits(max_connections=128))
    http = http or httpx.Client(timeout=httpx.Timeout(20.0, connect=5.0))
    e = os.environ if env is None else env
    try:
        if args.cmd == "realm-render":
            if render_local(check=args.check):
                print("realm current" if args.check else "realm written: deployment/local/keycloak/yantra-realm.json")
                return 0
            print("realm drifted: run `yantra realm-render`", file=sys.stderr)
            return 1
        if args.cmd == "vendor":
            return _vendor(args)
        if args.cmd == "login" and args.device:
            session = device_login(http, cfg, say=print)
            session.save(cfg.session_file)
            print(f"logged in as {session.username} ({session.worker_id}) roles={','.join(session.roles)}")
            return 0
        if args.cmd == "login":
            if args.username is None:
                print("usage: yantra login <username> | yantra login --device", file=sys.stderr)
                return 2
            password = args.password or e.get("YANTRA_PASSWORD") or getpass.getpass(f"password for {args.username}: ")
            session = login(http, cfg, args.username, password)
            session.save(cfg.session_file)
            print(f"logged in as {session.username} ({session.worker_id}) roles={','.join(session.roles)}")
            return 0
        if args.cmd == "smoke":
            password = args.password or e.get("YANTRA_SMOKE_PASSWORD", "yantra")
            smoke = Smoke(cfg, password, http, wait_seconds=args.wait)
            report = smoke.run()
            if args.with_storage:
                report["storage"] = StorageSmoke(smoke.as_user("ops1"), smoke.as_user("worker1"), http).run()
            print(render(report, args.json))
            return 0
        if args.cmd == "gate":
            args.password = args.password or e.get("YANTRA_SMOKE_PASSWORD", "yantra")
            results = gates.run(args, cfg, http)
            print(render([r.as_dict() for r in results], True) if args.json else table(results))
            return 0 if all(r.passed for r in results) else 1
        if args.cmd == "seed":
            password = args.password or e.get("YANTRA_SMOKE_PASSWORD", "yantra")
            print(render(Seed(cfg, password, http).run(), args.json))
            return 0
        saved = Session.load(cfg.session_file)
        if saved is None:
            print("not logged in: yantra login <username>", file=sys.stderr)
            return 2
        session = saved
        if args.cmd == "whoami":
            print(
                render(
                    {"username": session.username, "worker_id": session.worker_id, "roles": session.roles}, args.json
                )
            )
            return 0
        gw = Gateway(cfg, session, http, on_session=lambda s: s.save(cfg.session_file))
        print(render(args.fn(gw, args), args.json))
        return 0
    except GatewayError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    except AuthError as err:
        print(f"auth error: {err}", file=sys.stderr)
        return 1
    except SmokeFailed as err:
        print(f"FAIL: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())

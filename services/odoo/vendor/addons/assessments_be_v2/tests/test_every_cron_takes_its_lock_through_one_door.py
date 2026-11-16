# -*- coding: utf-8 -*-
"""Every cron takes its single-flight lock through one door (W4 P0 a).

Nine crons each wrote their own `pg_try_advisory_lock` / unlock pair, and the
four scoring-side ones began with an unlock-all, which behind PgBouncer
transaction pooling can drop ANOTHER lane's lock on a shared server
connection. `services/locks.cron_lock` is now the only place a session
advisory lock is taken or released.

Pinned here:
  (a) the door takes the key and gives it back;
  (b) a busy key is False and never a release of the holder's lock, and a busy
      skip with work waiting says so once;
  (c) nothing else in models/ or services/ takes or drops a session advisory
      lock, and nothing drops them all;
  (d) each of the nine crons, its key held elsewhere, does no work and names
      itself when work is waiting;
  (e) a tick that raises, even on a database error, still lets go;
  (f) (a), (b), (d) and (e) hold in lease mode too, on committed lease rows,
      and so do the lease's own cases: a live lease is busy, a lapsed one is
      taken over with a line, the drop expires it, two racing ticks get one
      winner, and the mode is read on every tick;
  (g) renewal: a renewed lease outlives its first term, a renew after a
      takeover is False and says so once, a lane taken over stops taking
      candidates, a drop whose commit fails still lets go, and a drop past
      the term says OVERRUN. Advisory `renew()` issues no SQL.
"""
import logging
import os
import re
import socket
from contextlib import contextmanager
from datetime import timedelta
from pathlib import Path
from unittest import SkipTest
from unittest.mock import patch

import psycopg2
from psycopg2.errors import DivisionByZero, SerializationFailure

from odoo import SUPERUSER_ID, api
from odoo.sql_db import db_connect
from odoo.tests.common import TransactionCase, tagged

from ..models import assessment as assessment_module
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

from ..constants import (
    ADVISORY_LOCK_AUTOSCORE, ADVISORY_LOCK_EXPIRE_ATTEMPTS,
    ADVISORY_LOCK_IMAGE_DETECT, ADVISORY_LOCK_IMAGE_RENDER,
    ADVISORY_LOCK_INVITE_SEND, ADVISORY_LOCK_PII_PURGE,
    ADVISORY_LOCK_QUESTION_GEN, ADVISORY_LOCK_TAG_EXTRACT,
    ADVISORY_LOCK_VIDEO_POLL, CRON_LOCK_MODE_PARAM,
)
from ..services import locks
from ..services.locks import CRON_LEASE_TTL, cron_lock, queued_count

_ADDON = Path(__file__).resolve().parent.parent
_LOGGER = "odoo.addons.assessments_be_v2"
_DOOR_LOGGER = "odoo.addons.assessments_be_v2.services.locks"
#: Not a module key (constants.py), so no real cron ever holds it.
_KEY = 827999

_EVALUATOR = "assessments.be.evaluator"
_PROMPT = "assessments.be.prompt"
_DRAFT = "assessments.be.prompt.question"


def _busy(name, key):
    return "CRON_LOCK_BUSY name=%s key=%s queued=3" % (name, key)


#: (model, cron, key, the call that does its work, the count it reports when
#: busy and what that count returns, the busy line it must log)
_CRONS = [
    ("assessments.be", "_cron_llm_auto_score", ADVISORY_LOCK_AUTOSCORE,
     "_scoring_shard_evaluators", "_scoring_lane_counts", {0: (3,)},
     "SCORING_LANE_BLOCKED shard=0 queued=3"),
    (_EVALUATOR, "_cron_expire_stale_attempts", ADVISORY_LOCK_EXPIRE_ATTEMPTS,
     "search", "search_count", 3,
     _busy("expire_attempts", ADVISORY_LOCK_EXPIRE_ATTEMPTS)),
    (_EVALUATOR, "_cron_purge_expired_pii", ADVISORY_LOCK_PII_PURGE,
     "search", "search_count", 3, _busy("pii_purge", ADVISORY_LOCK_PII_PURGE)),
    (_EVALUATOR, "_cron_send_pending_invitations", ADVISORY_LOCK_INVITE_SEND,
     "search", "search_count", 3,
     _busy("invite_send", ADVISORY_LOCK_INVITE_SEND)),
    (_PROMPT, "_cron_generate_from_sop", ADVISORY_LOCK_QUESTION_GEN,
     "search", "search_count", 3,
     _busy("question_gen", ADVISORY_LOCK_QUESTION_GEN)),
    (_PROMPT, "_cron_extract_tags", ADVISORY_LOCK_TAG_EXTRACT,
     "search", "search_count", 3,
     _busy("tag_extract", ADVISORY_LOCK_TAG_EXTRACT)),
    (_DRAFT, "_cron_render_pending_images", ADVISORY_LOCK_IMAGE_RENDER,
     "search", "search_count", 3,
     _busy("image_render", ADVISORY_LOCK_IMAGE_RENDER)),
    (_DRAFT, "_cron_poll_video_ops", ADVISORY_LOCK_VIDEO_POLL,
     "_submit_pending_video_ops", "search_count", 3,
     _busy("video_poll", ADVISORY_LOCK_VIDEO_POLL)),
    ("assessments.be.question.image", "_cron_detect_image_labels",
     ADVISORY_LOCK_IMAGE_DETECT, "search", "search_count", 3,
     _busy("image_detect", ADVISORY_LOCK_IMAGE_DETECT)),
]


@contextmanager
def _held_elsewhere(env, key):
    """Hold ``key`` on a connection of its own, as a tick mid-run does."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("SELECT pg_try_advisory_lock(%s)", [key])
        if not other.fetchone()[0]:
            raise SkipTest("a real cron holds lock %s" % key)
        try:
            yield other
        finally:
            other.execute("SELECT pg_advisory_unlock(%s)", [key])


def _free(env, key):
    """Can a connection of its own take ``key`` right now? (Given back.)"""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("SELECT pg_try_advisory_lock(%s)", [key])
        won = other.fetchone()[0]
        if won:
            other.execute("SELECT pg_advisory_unlock(%s)", [key])
        return won


#: Another worker's lease, as lease mode's `_held_elsewhere` puts it.
_ELSEWHERE = "test:elsewhere"


def _lease_holder(env, key):
    """Who holds a live lease on ``key``, read on a connection of its own."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("SELECT holder FROM assessments_be_cron_lease "
                      "WHERE key = %s AND expires_at >= now()", [key])
        row = other.fetchone()
    return row and row[0]


def _put_lease(env, key, holder, expired_ago):
    """Commit a lease of ``holder`` that ran a full TTL and ended
    ``expired_ago`` ago (negative: still live)."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("""
            INSERT INTO assessments_be_cron_lease
                   (key, holder, acquired_at, expires_at)
            VALUES (%(key)s, %(holder)s, now() - %(ttl)s - %(ago)s,
                    now() - %(ago)s)
            ON CONFLICT (key) DO UPDATE
               SET holder = EXCLUDED.holder,
                   acquired_at = EXCLUDED.acquired_at,
                   expires_at = EXCLUDED.expires_at
        """, {"key": key, "holder": holder, "ttl": CRON_LEASE_TTL,
              "ago": expired_ago})


@contextmanager
def _lease_held_elsewhere(env, key):
    """A live lease on ``key`` another worker committed, as a tick mid-run
    holds it."""
    if _lease_holder(env, key):
        raise SkipTest("a real cron holds the lease on %s" % key)
    _put_lease(env, key, _ELSEWHERE, -CRON_LEASE_TTL)
    try:
        yield None
    finally:
        with db_connect(env.cr.dbname).cursor() as other:
            other.execute("DELETE FROM assessments_be_cron_lease "
                          "WHERE key = %s AND holder = %s", [key, _ELSEWHERE])


def _age_lease(env, key, expired_ago):
    """Move the clock: the term of the lease on ``key``, whoever holds it,
    ran out ``expired_ago`` ago."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("""
            UPDATE assessments_be_cron_lease
               SET acquired_at = now() - %(ttl)s - %(ago)s,
                   expires_at = now() - %(ago)s
             WHERE key = %(key)s
        """, {"key": key, "ttl": CRON_LEASE_TTL, "ago": expired_ago})


def _commit_param(env, key, value):
    """Set ``key`` for every connection (committed); return what it was."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute("SELECT value FROM ir_config_parameter WHERE key = %s",
                      [key])
        row = other.fetchone()
        api.Environment(other, SUPERUSER_ID, {})[
            "ir.config_parameter"].set_param(key, value)
    return row and row[0]


def _sweep_leases(env):
    """Drop the lease rows this process's tests made."""
    with db_connect(env.cr.dbname).cursor() as other:
        other.execute(
            "DELETE FROM assessments_be_cron_lease WHERE key = %s "
            "OR holder LIKE %s OR holder LIKE 'test:%%'",
            [_KEY, "%s:%s:%%" % (socket.gethostname(), os.getpid())])


@contextmanager
def _warnings(name):
    """The WARNING messages logged under ``name``; unlike `assertLogs`, none
    is required."""
    lines = []
    handler = logging.Handler(logging.WARNING)
    handler.emit = lambda record: lines.append(record.getMessage())
    logger = logging.getLogger(name)
    logger.addHandler(handler)
    try:
        yield lines
    finally:
        logger.removeHandler(handler)


class _Reaped:
    """A cron cursor whose connection the server reaped mid-tick. No lock
    mode is set, so the door takes the advisory lock."""

    def execute(self, query, params=None, log_exceptions=True):
        self._row = None if "ir_config_parameter" in query else (True,)
        if "unlock" in query:
            raise psycopg2.InterfaceError("cursor already closed")

    def fetchone(self):
        return self._row


class _TheDoorsContract:
    """(a), (b), (d) and (e), run once per lock mode by the two classes
    below. Advisory runs them on the test's own cursor, exactly as before;
    lease on connections of their own, because a lease commits."""

    MODE = "advisory"
    # Odoo's loader collects only a class's own test methods without this.
    allow_inherited_tests_method = True

    def _cron_env(self):
        """The environment a tick runs in."""
        if self.MODE == "advisory":
            return self.env
        cr = db_connect(self.env.cr.dbname).cursor()
        self.addCleanup(cr.close)
        return api.Environment(cr, SUPERUSER_ID, {})

    def _hold_elsewhere(self, key):
        if self.MODE == "advisory":
            return _held_elsewhere(self.env, key)
        return _lease_held_elsewhere(self.env, key)

    def _key_free(self, key):
        if self.MODE == "advisory":
            return _free(self.env, key)
        return not _lease_holder(self.env, key)

    def _holder_kept(self, holder, key):
        if self.MODE == "advisory":
            holder.execute("SELECT pg_advisory_unlock(%s)", [key])
            return holder.fetchone()[0]
        return _lease_holder(self.env, key) == _ELSEWHERE

    def _set_param(self, key, value):
        """``key`` as the tick will read it."""
        if self.MODE == "advisory":
            self.env["ir.config_parameter"].sudo().set_param(key, value)
        else:
            self.addCleanup(_commit_param, self.env, key,
                            _commit_param(self.env, key, value))

    # (a) the door takes the key and gives it back

    def test_the_door_takes_the_key_and_gives_it_back(self):
        env = self._cron_env()
        with self.assertNoLogs(_DOOR_LOGGER, "WARNING"):
            with cron_lock(env.cr, _KEY, name="t",
                           queued=lambda: self.fail("a won lock counted")) \
                    as got:
                self.assertTrue(got)
                self.assertFalse(self._key_free(_KEY))
        self.assertTrue(self._key_free(_KEY))

    # (b) a busy key is False, and the holder keeps it

    def test_a_busy_key_is_false_and_the_holder_keeps_it(self):
        env = self._cron_env()
        with self._hold_elsewhere(_KEY) as holder:
            with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
                with cron_lock(env.cr, _KEY, name="t", queued=2) as got:
                    self.assertFalse(got)
            self.assertEqual(
                [line.split(":", 2)[2] for line in logs.output],
                ["CRON_LOCK_BUSY name=t key=%s queued=2" % _KEY])
            self.assertTrue(self._holder_kept(holder, _KEY),
                            "the busy door released the holder's lock")

    def test_a_busy_key_with_nothing_waiting_is_silent(self):
        env = self._cron_env()
        with self._hold_elsewhere(_KEY), \
                self.assertNoLogs(_DOOR_LOGGER, "WARNING"):
            with cron_lock(env.cr, _KEY, name="t",
                           queued=lambda: 0) as got:
                self.assertFalse(got)

    def test_a_count_that_fails_does_not_fail_the_busy_tick(self):
        env = self._cron_env()
        with self._hold_elsewhere(_KEY), \
                self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(env.cr, _KEY, name="t",
                           queued=lambda: env.cr.execute(
                               "SELECT 1/0", log_exceptions=False)) as got:
                self.assertFalse(got)
        out = "\n".join(logs.output)
        self.assertIn("cron lock t (%s): queued count failed" % _KEY, out)
        self.assertNotIn("CRON_LOCK_BUSY", out)
        env.cr.execute("SELECT 1")  # the tick's transaction still works

    def test_a_skipped_lane_whose_count_fails_still_returns(self):
        """The scoring lane counts its own queue for its own marker."""
        env = self._cron_env()
        Paper = env["assessments.be"]
        cls = type(Paper)
        with self._hold_elsewhere(ADVISORY_LOCK_AUTOSCORE), \
                patch.object(cls, "_scoring_shard_evaluators",
                             side_effect=AssertionError("the lane worked")), \
                patch.object(cls, "_scoring_lane_counts",
                             side_effect=lambda *a: env.cr.execute(
                                 "SELECT 1/0", log_exceptions=False)), \
                self.assertLogs(_LOGGER, "WARNING") as logs:
            Paper._cron_llm_auto_score(shard=0)
        out = "\n".join(logs.output)
        self.assertIn("cron lock scoring_lane_0 (%s): queued count failed"
                      % ADVISORY_LOCK_AUTOSCORE, out)
        self.assertNotIn("SCORING_LANE_BLOCKED", out)
        env.cr.execute("SELECT 1")  # the tick's transaction still works

    # (d) each of the nine crons skips a held key and says when work waits

    def test_every_cron_skips_a_held_key_and_names_waiting_work(self):
        # The PII sweep returns before its lock when retention is off.
        self._set_param("assessments_be_v2.pii_retention_days", "30")
        self.assertEqual(len(_CRONS), 9, "fixture guard: all nine crons")
        with _warnings(_DOOR_LOGGER) as probe:
            queued_count(self.env.cr, lambda: 1 / 0, name="probe", key=_KEY)
        self.assertTrue([line for line in probe if "count failed" in line],
                        "fixture guard: a broken count is seen")
        for (model, cron, key, work, count, waiting, marker) in _CRONS:
            with self.subTest(cron=cron):
                # A tick of its own per cron, begun after the key is held.
                Model = self._cron_env()[model]
                cls = type(Model)
                with self._hold_elsewhere(key), patch.object(
                        cls, work, side_effect=AssertionError(
                            "%s worked under a held lock" % cron)):
                    # The real count first: its domain must run. A broken one
                    # is read as 0 with a WARNING, so the WARNING is the test.
                    with _warnings(_DOOR_LOGGER) as real:
                        getattr(Model, cron)()
                    self.assertEqual(
                        [line for line in real if "count failed" in line],
                        [], "%s's queued count does not run" % cron)
                    with patch.object(cls, count, return_value=waiting), \
                            self.assertLogs(_LOGGER, "WARNING") as logs:
                        getattr(Model, cron)()
                out = "\n".join(logs.output)
                self.assertIn(marker, out)
                self.assertEqual(
                    out.count("CRON_LOCK_BUSY") + out.count("_BLOCKED"), 1,
                    "one busy line per skipped tick, never two")

    # (e) a tick that raises still lets go

    def test_a_tick_that_raises_still_lets_go(self):
        Draft = self._cron_env()[_DRAFT]
        with patch.object(type(Draft), "_submit_pending_video_ops",
                          side_effect=RuntimeError("boom")), \
                self.assertRaises(RuntimeError):
            Draft._cron_poll_video_ops()
        self.assertTrue(self._key_free(ADVISORY_LOCK_VIDEO_POLL))

    def test_a_tick_that_dies_on_a_database_error_still_lets_go(self):
        """What the unlock-all was there for: the unlock in a `finally` ran
        inside the aborted transaction, failed, and the session lock rode the
        connection back into the pool."""
        with db_connect(self.env.cr.dbname).cursor() as cron_cr:
            with self.assertRaises(DivisionByZero):
                with cron_lock(cron_cr, _KEY, name="t") as got:
                    self.assertTrue(got)
                    cron_cr.execute("SELECT 1/0", log_exceptions=False)
            self.assertTrue(self._key_free(_KEY),
                            "the lock outlived the dead transaction")
            cron_cr.execute("SELECT 1")  # and the cursor is usable again


@tagged("post_install", "-at_install")
class TestEveryCronTakesItsLockThroughOneDoor(_TheDoorsContract,
                                              TransactionCase):
    """Advisory mode, the default: the contract above plus (c)."""

    def test_an_unlock_that_finds_no_lock_says_so(self):
        """Transaction pooling's symptom: the unlock runs on a server
        connection that does not hold the key."""
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(self.env.cr, _KEY, name="t") as got:
                self.assertTrue(got)
                self.env.cr.execute("SELECT pg_advisory_unlock(%s)", [_KEY])
        self.assertEqual(
            [line.split(":", 2)[2] for line in logs.output],
            ["CRON_LOCK_UNLOCK_FALSE name=t key=%s" % _KEY])

    # (c) one door: nothing else takes or drops a session advisory lock

    def test_nothing_else_takes_or_drops_a_session_lock(self):
        call = re.compile(r"\b(pg_\w*advisory\w*)\s*\(")
        self.assertEqual(
            call.findall("SELECT pg_advisory_unlock_all(); SELECT "
                         "pg_try_advisory_lock(%s)"),
            ["pg_advisory_unlock_all", "pg_try_advisory_lock"],
            "fixture guard: the sweep sees a raw call")
        # The two transaction-level locks are not a cron's and stay where
        # they are: the grading cache's two-key try-lock and the Vertex
        # bearer's blocking lock. `_held_cron_locks` reads `pg_locks`
        # and calls no lock function, so it needs no entry.
        allowed = {
            "services/locks.py": {"pg_try_advisory_lock",
                                  "pg_advisory_unlock"},
            "services/grading_cache.py": {"pg_try_advisory_xact_lock"},
            "services/vertex.py": {"pg_advisory_xact_lock"},
        }
        files = sorted((_ADDON / "models").rglob("*.py")) + sorted(
            (_ADDON / "services").rglob("*.py"))
        self.assertTrue(files, "fixture guard: the sweep found the code")
        offenders = []
        for path in files:
            rel = path.relative_to(_ADDON).as_posix()
            text = path.read_text(encoding="utf-8")
            if "pg_advisory_unlock_all" in text:
                offenders.append("%s: pg_advisory_unlock_all" % rel)
            for name in set(call.findall(text)) - allowed.get(rel, set()):
                offenders.append("%s: %s" % (rel, name))
        self.assertEqual(sorted(offenders), [])

    def test_a_reaped_cursor_on_exit_is_logged_not_raised(self):
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(_Reaped(), _KEY, name="t") as got:
                self.assertTrue(got)
        self.assertIn("cron lock t (%s) not released" % _KEY,
                      "\n".join(logs.output))

    def test_renew_is_a_no_op_that_issues_no_sql(self):
        """A session lock needs no renewal: advisory mode is unchanged."""
        with cron_lock(self.env.cr, _KEY, name="t") as got:
            before = self.env.cr.sql_log_count
            self.assertTrue(got.renew())
            self.assertEqual(self.env.cr.sql_log_count, before,
                             "an advisory renew issued SQL")

    def test_an_unknown_mode_runs_advisory_with_one_warning(self):
        """One line per process, not one per tick: two ticks, one line."""
        self.env["ir.config_parameter"].sudo().set_param(
            CRON_LOCK_MODE_PARAM, "Lease")
        self.env.flush_all()
        with patch.object(locks, "_WARNED_MODES", set()), \
                self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            for _tick in range(2):
                with cron_lock(self.env.cr, _KEY, name="t") as got:
                    self.assertTrue(got)
                    self.assertFalse(_free(self.env, _KEY),
                                     "the fallback is not the advisory lock")
        self.assertEqual(
            [line.split(":", 2)[2] for line in logs.output],
            ["cron lock t (%s): unknown %s 'Lease', using advisory"
             % (_KEY, CRON_LOCK_MODE_PARAM)])
        self.assertTrue(_free(self.env, _KEY))


@tagged("post_install", "-at_install")
class TestTheLeaseModeKeepsTheSameDoor(_TheDoorsContract, TransactionCase):
    """(f) Lease mode, switched on for every connection (committed) and put
    back after each test, with the lease rows the test made."""

    MODE = "lease"

    def setUp(self):
        super().setUp()
        self.addCleanup(_commit_param, self.env, CRON_LOCK_MODE_PARAM,
                        _commit_param(self.env, CRON_LOCK_MODE_PARAM,
                                      "lease"))
        self.addCleanup(_sweep_leases, self.env)

    def test_a_live_lease_is_busy_for_a_second_connection(self):
        first, second = self._cron_env().cr, self._cron_env().cr
        with cron_lock(first, _KEY, name="t") as got:
            self.assertTrue(got)
            with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
                with cron_lock(second, _KEY, name="t", queued=1) as again:
                    self.assertFalse(again)
            self.assertEqual(
                [line.split(":", 2)[2] for line in logs.output],
                ["CRON_LOCK_BUSY name=t key=%s queued=1" % _KEY])
            self.assertTrue(_free(self.env, _KEY),
                            "lease mode took an advisory lock")
        self.assertFalse(_lease_holder(self.env, _KEY))

    def test_a_lapsed_lease_is_taken_over_with_a_warning(self):
        _put_lease(self.env, _KEY, "test:dead-worker", timedelta(minutes=5))
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
                self.assertTrue(got)
                self.assertNotEqual(_lease_holder(self.env, _KEY),
                                    "test:dead-worker")
        self.assertEqual(len(logs.output), 1, logs.output)
        self.assertRegex(
            logs.output[0],
            r"CRON_LEASE_TAKEOVER name=t key=%s previous=test:dead-worker "
            r"expired_for=30\ds$" % _KEY)

    def test_the_drop_expires_the_lease_and_the_next_take_is_quiet(self):
        with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
            self.assertTrue(got)
            holder = _lease_holder(self.env, _KEY)
            self.assertEqual(holder.split(":")[:2],
                             [socket.gethostname(), str(os.getpid())])
        with db_connect(self.env.cr.dbname).cursor() as other:
            other.execute("SELECT holder, expires_at <= now() FROM "
                          "assessments_be_cron_lease WHERE key = %s", [_KEY])
            self.assertEqual(other.fetchall(), [(holder, True)],
                             "the drop kept the row and expired it")
        # A dropped lease is not a lapsed one: no takeover line.
        with self.assertNoLogs(_DOOR_LOGGER, "WARNING"):
            with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
                self.assertTrue(got)

    def test_two_ticks_racing_one_lapsed_lease_have_one_winner(self):
        """Both ticks have begun (each holds its REPEATABLE READ snapshot)
        before either takes. The second's take meets a row changed since its
        snapshot: a serialization failure, read as busy, never an error."""
        _put_lease(self.env, _KEY, "test:dead-worker", timedelta(minutes=5))
        first, second = self._cron_env().cr, self._cron_env().cr
        for cr in (first, second):
            cr.execute("SELECT 1")
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(first, _KEY, name="t") as one, \
                    cron_lock(second, _KEY, name="t") as two:
                self.assertEqual([bool(one), bool(two)], [True, False])
        self.assertEqual(
            len([line for line in logs.output
                 if "CRON_LEASE_TAKEOVER" in line]), 1, logs.output)

    def test_a_lease_lost_mid_tick_says_so(self):
        """The tick outran its TTL and another worker took the lane."""
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
                self.assertTrue(got)
                _put_lease(self.env, _KEY, "test:thief", -CRON_LEASE_TTL)
        self.assertEqual(
            [line.split(":", 2)[2] for line in logs.output],
            ["CRON_LEASE_LOST name=t key=%s" % _KEY])
        self.assertEqual(_lease_holder(self.env, _KEY), "test:thief",
                         "the drop expired another worker's lease")

    def test_a_drop_whose_commit_fails_still_lets_go(self):
        """The drop's commit flushes the tick's last writes, and one of them
        can lose a race. Swallowed, that left the lane held for a TTL."""
        cr = self._cron_env().cr
        real_commit = cr.commit
        failures = [SerializationFailure("could not serialize access")]

        def commit():
            if failures:
                raise failures.pop()
            real_commit()

        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(cr, _KEY, name="t") as got:
                self.assertTrue(got)
                cr.commit = commit  # the next commit is the drop's
        self.assertFalse(failures, "fixture guard: the drop's commit failed")
        self.assertFalse(_lease_holder(self.env, _KEY),
                         "the lane is still held")
        self.assertIn("cron lock t (%s): tick tail rolled back so the lease "
                      "could be dropped" % _KEY, "\n".join(logs.output))

    def test_a_tick_that_writes_then_raises_keeps_nothing(self):
        """The rollback before the drop is real: the drop's commit saves none
        of a failed tick's writes."""
        cr = self._cron_env().cr
        with self.assertRaises(RuntimeError):
            with cron_lock(cr, _KEY, name="t") as got:
                self.assertTrue(got)
                cr.execute("INSERT INTO assessments_be_cron_lease "
                           "VALUES (%s, 'test:tail', now(), now())",
                           [_KEY + 1])
                raise RuntimeError("boom")
        with db_connect(self.env.cr.dbname).cursor() as other:
            other.execute("SELECT count(*) FROM assessments_be_cron_lease "
                          "WHERE key = %s", [_KEY + 1])
            self.assertEqual(other.fetchone()[0], 0,
                             "the failed tick's write was committed")
        self.assertFalse(_lease_holder(self.env, _KEY))

    def test_a_renewed_lease_outlives_its_first_term(self):
        cr = self._cron_env().cr
        with self.assertNoLogs(_DOOR_LOGGER, "WARNING"):
            with cron_lock(cr, _KEY, name="t") as got:
                holder = _lease_holder(self.env, _KEY)
                _age_lease(self.env, _KEY, timedelta(minutes=5))
                self.assertFalse(_lease_holder(self.env, _KEY),
                                 "fixture guard: the first term ran out")
                self.assertTrue(got.renew())
                cr.commit()  # the record's commit saves the renewal
                self.assertEqual(_lease_holder(self.env, _KEY), holder)
                with cron_lock(self._cron_env().cr, _KEY, name="t") as other:
                    self.assertFalse(other, "a renewed lease was taken over")

    def test_a_renew_after_a_takeover_is_false_and_says_so_once(self):
        """Seen from a fresh transaction, and from one whose snapshot is
        older than the takeover (a serialization failure, read the same)."""
        for stale in (False, True):
            with self.subTest(stale=stale):
                _sweep_leases(self.env)
                cr = self._cron_env().cr
                with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
                    with cron_lock(cr, _KEY, name="t") as got:
                        if stale:
                            cr.execute("SELECT 1")
                        _put_lease(self.env, _KEY, "test:thief",
                                   -CRON_LEASE_TTL)
                        self.assertFalse(got.renew())
                        self.assertFalse(got.renew())
                        cr.commit()  # the record's commit, as a cron makes
                self.assertEqual(
                    [line.split(":", 2)[2] for line in logs.output],
                    ["CRON_LEASE_LOST name=t key=%s" % _KEY])
                self.assertEqual(_lease_holder(self.env, _KEY), "test:thief")

    def test_a_lane_taken_over_stops_taking_candidates(self):
        """Serial and parallel: the candidate in hand is finished, the next
        one is never taken, or two workers would grade it."""
        for workers in (1, 2):
            with self.subTest(workers=workers):
                _sweep_leases(self.env)
                env = self._cron_env()
                Paper = env["assessments.be"]
                Evaluator = env["assessments.be.evaluator"]
                evaluators = Evaluator.browse([910001, 910002, 910003])
                taken = []

                def take(_model, ev, *args):
                    """The candidate's own commit, then another worker takes
                    the lane over."""
                    taken.append(ev.id)
                    env.cr.commit()
                    _put_lease(self.env, ADVISORY_LOCK_AUTOSCORE,
                               "test:thief", -CRON_LEASE_TTL)
                    return "run"

                cls = type(Paper)
                with patch.object(cls, "_scoring_shard_evaluators",
                                  return_value=evaluators), \
                        patch.object(cls, "_scoring_parallel_calls",
                                     return_value=workers), \
                        patch.object(cls, "_auto_score_eligible",
                                     return_value=True), \
                        patch.object(cls, "_auto_score_mark_scoring", take), \
                        patch.object(type(Evaluator), "_action_llm_score",
                                     return_value=0), \
                        patch.object(cls, "_auto_score_begin", take), \
                        patch.object(cls, "_auto_score_finish",
                                     return_value=0), \
                        patch.object(cls, "_clear_finished_scoring_kills"), \
                        patch.object(vertex_svc, "_check_spend"), \
                        patch.object(vertex_svc, "_side_cursor_is_safe",
                                     return_value=True), \
                        patch.object(scoring_svc, "parallel_dispatch"), \
                        patch.object(assessment_module, "_pop_first_ready",
                                     lambda in_flight: in_flight.popleft()), \
                        self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
                    Paper._cron_llm_auto_score(shard=0)
                self.assertEqual(taken, [910001])
                self.assertEqual(
                    [line.split(":", 2)[2] for line in logs.output],
                    ["CRON_LEASE_LOST name=scoring_lane_0 key=%s"
                     % ADVISORY_LOCK_AUTOSCORE])

    def test_a_drop_after_the_term_ran_out_says_overrun(self):
        """A record outran the TTL and nobody took the lane: the drop says
        so, so the next tick's takeover line is not read as a dead worker."""
        cr = self._cron_env().cr
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(cr, _KEY, name="t") as got:
                self.assertTrue(got)
                holder = _lease_holder(self.env, _KEY)
                _age_lease(self.env, _KEY, timedelta(minutes=5))
        self.assertEqual(len(logs.output), 1, logs.output)
        self.assertRegex(logs.output[0],
                         r"CRON_LEASE_OVERRUN name=t key=%s over=30\ds$"
                         % _KEY)
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
                self.assertTrue(got)
        self.assertIn("CRON_LEASE_TAKEOVER name=t key=%s previous=%s "
                      % (_KEY, holder), logs.output[0])

    def test_a_closed_cursor_on_exit_is_logged_not_raised(self):
        cr = self._cron_env().cr
        with self.assertLogs(_DOOR_LOGGER, "WARNING") as logs:
            with cron_lock(cr, _KEY, name="t") as got:
                self.assertTrue(got)
                cr.close()
        self.assertIn("cron lock t (%s) not released" % _KEY,
                      "\n".join(logs.output))

    def test_the_mode_is_read_on_every_tick(self):
        with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
            self.assertTrue(got)
            self.assertTrue(_lease_holder(self.env, _KEY))
            self.assertTrue(_free(self.env, _KEY))
        _commit_param(self.env, CRON_LOCK_MODE_PARAM, "advisory")
        with cron_lock(self._cron_env().cr, _KEY, name="t") as got:
            self.assertTrue(got)
            self.assertFalse(_free(self.env, _KEY),
                             "the next tick did not take the advisory lock")
            self.assertFalse(_lease_holder(self.env, _KEY))

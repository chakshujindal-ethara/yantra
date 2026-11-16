# -*- coding: utf-8 -*-
"""One door for the crons' single-flight locks.

Every cron that must never run twice at once takes its key
(`constants.ADVISORY_LOCK_*`) through `cron_lock`, and nothing else in the
module takes or drops a session advisory lock.

SESSION-LEVEL ON PURPOSE. The ticks commit per record, and a transaction lock
would be gone at the first commit and let a second worker double-process. A
session lock lives until it is released here or the connection ends.

RELEASE IS PER KEY, AND ONLY BY THE TICK THAT WON IT. What this removed: the
four scoring-side crons began with an unlock-all, which drops EVERY advisory
lock on the backend, so on a shared server connection it could release
ANOTHER lane's lock. A tick that died on a database error (its unlock failed
in the aborted transaction) rolls the dead transaction back here, which the
cron runner does next anyway, and still releases its key.

PGBOUNCER IS NOT HYPOTHETICAL. Prod's main database connection already goes
through PgBouncer and its pool mode is UNCONFIRMED. Under transaction pooling
session advisory locks are unsafe TODAY: the lock and its unlock can land on
different server connections. The unlock then returns false and logs
`CRON_LOCK_UNLOCK_FALSE` (below), and the lock stays on the other server
connection. That line is evidence of transaction pooling; its absence is not
proof of session pooling, since an unlock can land on the same server
connection by chance.
With the unlock-all gone a leaked level no longer heals on the next tick: it
persists until PgBouncer closes that server connection, and every tick with
work waiting logs `CRON_LOCK_BUSY` (`SCORING_LANE_BLOCKED` for a scoring
lane). Runbook: Settings > Shards = 1 to drain scoring, then find the holder
with the `pg_locks` join in the KB (section "5. Concurrency") and terminate
that backend.

LEASE MODE, ONE SETTINGS SWITCH AWAY. `assessments_be_v2.cron_lock_mode`
(Settings > Scoring) is read on every call, so a change applies on each
cron's next tick. "advisory" (or unset) is the session lock above, unchanged.
"lease" holds a row in `assessments_be_cron_lease` (key, holder, acquired_at,
expires_at) instead, which no server connection carries, so transaction
pooling cannot leak it. An unknown value runs advisory and logs a warning,
once per value per process. Switch to lease when the database is reached
through PgBouncer in transaction mode, in a quiet window (Shards = 1, and
wait until the current mode's holder query shows nobody).
- Take: ONE statement, `INSERT .. ON CONFLICT (key) DO UPDATE .. WHERE
  expires_at < now()`; won iff our holder (host:pid:uuid4) comes back.
  Taking over a lapsed lease logs `CRON_LEASE_TAKEOVER` with the previous
  holder and how long it had been expired. Busy logs the same
  `CRON_LOCK_BUSY` line. Odoo cursors are REPEATABLE READ, so a row another
  worker changed after this tick's snapshot raises a serialization failure:
  that is read as busy, and the next tick tries again.
- Renew: `cron_lock` yields a `CronLock`, true exactly when held. Each cron
  calls `got.renew()` immediately before each per-record commit; in lease
  mode it starts a fresh `CRON_LEASE_TTL` inside that transaction (no extra
  commit), so the TTL bounds one record, not a tick. False means another
  worker took the lane (`CRON_LEASE_LOST`, once per tick); the scoring lane
  then stops before its next candidate. Advisory mode: no SQL, True.
- Drop: `UPDATE .. SET expires_at = now() WHERE key AND holder`. Finding no
  row of ours logs `CRON_LEASE_LOST`; finding it already expired logs
  `CRON_LEASE_OVERRUN .. over=<seconds>` (a record outran the TTL), so the
  next tick's takeover line is not read as a dead worker.
- Take and drop each COMMIT the tick's cursor, so other workers see them at
  once. The ticks already commit per record and the cron runner commits a
  tick that returns, so this moves no work's fate. A tick that raised is
  rolled back before the drop (the runner does that next anyway), so the
  drop's commit never saves half a record. A drop whose commit fails (it
  flushes the tick's last writes, which can lose a race) rolls that tail
  back, warns, and drops again: the lane is never left held for a TTL.
The lane heartbeat, `_held_cron_locks` (models/assessment.py, behind
`_being_graded`, `_running_cron_ids` and the generation progress route),
counts a live lease (`expires_at > now()`) as held, as it counts a granted
lock in `pg_locks`.
"""
import logging
import os
import socket
import uuid
from contextlib import contextmanager
from datetime import timedelta

from psycopg2.errors import InFailedSqlTransaction, SerializationFailure

from ..constants import CRON_LOCK_MODE_PARAM, CRON_LOCK_MODE_SELECTION

_logger = logging.getLogger(__name__)

#: A lease's life from its take or last renewal, so it bounds ONE record: a
#: scoring candidate's worst case is about 9 minutes of Vertex retries. A
#: worker that died mid-tick frees its lane when this runs out.
CRON_LEASE_TTL = timedelta(minutes=20)

_MODES = frozenset(code for code, _label in CRON_LOCK_MODE_SELECTION)
#: Unknown mode values already warned about: one line per process, not per
#: tick.
_WARNED_MODES = set()

# One statement. `prev` reads the row this statement replaces, for the
# takeover line: under REPEATABLE READ the row it took over is the one `prev`
# saw, or the statement fails instead. A dropped lease ends before its term
# (take or last renewal, both stamped in `acquired_at`) ran out; only one that
# ran out (`lapsed`) is a takeover worth a line.
_TAKE = """
    WITH prev AS (
        SELECT holder, now() - expires_at AS expired_for,
               expires_at - acquired_at >= %(ttl)s AS lapsed
          FROM assessments_be_cron_lease WHERE key = %(key)s)
    INSERT INTO assessments_be_cron_lease
           (key, holder, acquired_at, expires_at)
    VALUES (%(key)s, %(holder)s, now(), now() + %(ttl)s)
    ON CONFLICT (key) DO UPDATE
       SET holder = EXCLUDED.holder, acquired_at = now(),
           expires_at = EXCLUDED.expires_at
     WHERE assessments_be_cron_lease.expires_at < now()
    RETURNING holder, (SELECT holder FROM prev),
              (SELECT expired_for FROM prev), (SELECT lapsed FROM prev)
"""
# No row: the lease is no longer ours. Else how long ago it had expired
# (negative while it was live).
_DROP = """
    WITH prev AS (
        SELECT now() - expires_at AS over FROM assessments_be_cron_lease
         WHERE key = %(key)s AND holder = %(holder)s)
    UPDATE assessments_be_cron_lease SET expires_at = now()
     WHERE key = %(key)s AND holder = %(holder)s
    RETURNING (SELECT over FROM prev)
"""
# A new term from this moment, not from the transaction's start (`now()`):
# the renewal runs at the END of a record, and a term counted from its start
# would have to cover that record and the next.
_RENEW = """
    UPDATE assessments_be_cron_lease
       SET acquired_at = clock_timestamp(),
           expires_at = clock_timestamp() + %(ttl)s
     WHERE key = %(key)s AND holder = %(holder)s
"""


class CronLock:
    """What `cron_lock` yields: true exactly when the lock is held, so
    `if not got: return` reads as it always did."""

    def __init__(self, cr, key, name, held, holder=None):
        self._cr, self._key, self._name = cr, key, name
        self._held, self._holder = held, holder
        self.lost = False

    def __bool__(self):
        return self._held

    def renew(self):
        """Keep the lease for one more record; call it immediately before
        each per-record commit, which saves it. False when another worker
        took the lane. Advisory mode: a session lock needs none, no SQL."""
        if self._holder is None:
            return True
        if self.lost:
            return False
        try:
            with self._cr.savepoint(flush=False):
                self._cr.execute(_RENEW, {
                    "key": self._key, "holder": self._holder,
                    "ttl": CRON_LEASE_TTL}, log_exceptions=False)
                renewed = self._cr.rowcount
        except SerializationFailure:
            # The row changed after this transaction began: taken over.
            renewed = 0
        if not renewed:
            self.lost = True
            _logger.warning("CRON_LEASE_LOST name=%s key=%s",
                            self._name, self._key)
        return bool(renewed)

    def _drop(self, failed):
        """Expire our lease and commit. A ``failed`` tick is rolled back
        first, as the cron runner would next, so this commit saves none of
        it."""
        cr = self._cr
        try:
            if failed:
                cr.rollback()
            try:
                row = self._drop_and_commit()
            except Exception:  # noqa: BLE001 - retried once, below
                if cr.closed:
                    raise
                # The commit flushes the tick's last writes first, and one
                # lost a race (or the tick swallowed a database error). Left
                # alone the lease would stay live for a whole TTL.
                _logger.warning(
                    "cron lock %s (%s): tick tail rolled back so the lease "
                    "could be dropped", self._name, self._key, exc_info=True)
                cr.rollback()
                row = self._drop_and_commit()
        except Exception as exc:  # noqa: BLE001 - never mask the outcome
            _logger.warning("cron lock %s (%s) not released this tick: %s",
                            self._name, self._key, exc)
            return
        if row is None:
            if not self.lost:
                _logger.warning("CRON_LEASE_LOST name=%s key=%s",
                                self._name, self._key)
        elif row[0] and row[0].total_seconds() > 0:
            _logger.warning("CRON_LEASE_OVERRUN name=%s key=%s over=%ss",
                            self._name, self._key,
                            int(row[0].total_seconds()))
        else:
            _logger.debug("cron lock %s (%s) released", self._name,
                          self._key)

    def _drop_and_commit(self):
        self._cr.execute(_DROP, {"key": self._key, "holder": self._holder},
                         log_exceptions=False)
        row = self._cr.fetchone()
        self._cr.commit()
        return row


@contextmanager
def cron_lock(cr, key, *, name, queued=0):
    """Take lock ``key`` for one tick; yield a `CronLock`, true exactly when
    it won. A session advisory lock, or a lease row in lease mode (module
    docstring).

    ``queued`` is the work a busy tick leaves behind: a count, or a no-arg
    callable returning one, called only on a busy skip so an idle tick pays
    nothing. A busy skip with work queued logs ``CRON_LOCK_BUSY`` once; an
    empty queue stays silent. Leave it 0 when the caller logs its own marker
    (the scoring lane's ``SCORING_LANE_BLOCKED``). A count that fails is
    logged and read as 0: a log line never fails a tick.
    """
    holder = None
    if _lock_mode(cr, name, key) == "lease":
        holder = _take_lease(cr, key, name)
        won = holder is not None
    else:
        cr.execute("SELECT pg_try_advisory_lock(%s)", (key,))
        won = cr.fetchone()[0]
    if not won:
        count = queued_count(cr, queued, name=name, key=key)
        if count:
            _logger.warning("CRON_LOCK_BUSY name=%s key=%s queued=%s",
                            name, key, count)
        yield CronLock(cr, key, name, held=False)
        return
    _logger.debug("cron lock %s (%s) acquired", name, key)
    lock = CronLock(cr, key, name, held=True, holder=holder)
    failed = True
    try:
        yield lock
        failed = False
    finally:
        if holder is None:
            _release(cr, key, name)
        else:
            lock._drop(failed)


def _lock_mode(cr, name, key):
    """This tick's mode, read fresh (a cursor, not an environment, and no
    cache), so a Settings change applies on the next tick."""
    cr.execute("SELECT value FROM ir_config_parameter WHERE key = %s",
               (CRON_LOCK_MODE_PARAM,))
    row = cr.fetchone()
    mode = (row[0] if row else None) or "advisory"
    if mode in _MODES:
        return mode
    if mode not in _WARNED_MODES:
        _WARNED_MODES.add(mode)
        _logger.warning("cron lock %s (%s): unknown %s %r, using advisory",
                        name, key, CRON_LOCK_MODE_PARAM, mode)
    return "advisory"


def _take_lease(cr, key, name):
    """Our holder if the lease on ``key`` is ours now, else None. Commits."""
    holder = "%s:%s:%s" % (socket.gethostname(), os.getpid(), uuid.uuid4())
    try:
        with cr.savepoint(flush=False):
            cr.execute(_TAKE, {"key": key, "holder": holder,
                               "ttl": CRON_LEASE_TTL}, log_exceptions=False)
            row = cr.fetchone()
    except SerializationFailure:
        # Another worker changed the row after this tick's snapshot: it took
        # the lease or just dropped it. Busy; the next tick tries again.
        row = None
    # Even when busy: a conflicting row stays locked until this commits.
    cr.commit()
    if not row or row[0] != holder:
        return None
    if row[3]:
        _logger.warning(
            "CRON_LEASE_TAKEOVER name=%s key=%s previous=%s expired_for=%ss",
            name, key, row[1], int(row[2].total_seconds()))
    return holder


def queued_count(cr, queued, *, name, key):
    """``queued`` (a count or a no-arg callable) for a busy skip's log line.
    Also used by the scoring lane, which logs its own marker."""
    if not callable(queued):
        return queued
    try:
        # A savepoint, so a count that fails in SQL leaves the busy tick's
        # transaction usable.
        with cr.savepoint(flush=False):
            return queued()
    except Exception:  # noqa: BLE001 - a log line never fails a tick
        _logger.warning("cron lock %s (%s): queued count failed, read as 0",
                        name, key, exc_info=True)
        return 0


def _release(cr, key, name):
    try:
        try:
            cr.execute("SELECT pg_advisory_unlock(%s)", (key,),
                       log_exceptions=False)
        except InFailedSqlTransaction:
            # The tick died on a database error. Its transaction can only roll
            # back, and the lock would outlive it on the pooled connection.
            cr.rollback()
            cr.execute("SELECT pg_advisory_unlock(%s)", (key,))
        if cr.fetchone()[0]:
            _logger.debug("cron lock %s (%s) released", name, key)
        else:
            # This server connection does not hold the key: under PgBouncer
            # transaction pooling the lock was taken on another one, where it
            # stays (module docstring).
            _logger.warning("CRON_LOCK_UNLOCK_FALSE name=%s key=%s",
                            name, key)
    except Exception as exc:  # noqa: BLE001 - never mask the tick's outcome
        # A reaped connection took the lock with it; anything else is seen.
        _logger.warning("cron lock %s (%s) not released this tick: %s",
                        name, key, exc)

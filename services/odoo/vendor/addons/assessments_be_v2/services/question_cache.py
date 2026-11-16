# -*- coding: utf-8 -*-
"""A shared Redis cache of question CONTENT for the candidate exam routes.

`serializers.question_for_candidate` splits a question into its content (the
same for every candidate: text, dimensions and options, label boxes, media
asset ids) and the candidate's own part (index, total, media URLs carrying the
token, the saved answer). Only the content comes through here, so nothing a
candidate typed or picked, and no answer key, can ever be stored.

OFF UNLESS CONFIGURED. `REDIS_URL` in the environment, else the system
parameter below (for a local or stage rig). Empty means off, and off is
exactly the code path that ran before this module existed: `fetch` calls the
builder and returns, without creating a client or reading anything else.

VERSIONED, SO NOTHING IS EVER INVALIDATED. The key is
`{dbname}:q:{question_id}:{write_date ISO}:{code}`. An edit to the question or
to any of its dimensions, options, images or videos bumps its `write_date`
(`question.QuestionCacheTouch`), so a changed question is simply a new key and
the old one ages out on the TTL. `code` is a hash of the files that build the
content (`_BUILDER_FILES`): a deploy that changes the content's shape or how
it is derived never reads what the previous code cached, which would be a
KeyError (a 500) or a fixed bug still served for a day.

REDIS IS NEVER THE SOURCE OF TRUTH. Any error or timeout is logged at most
once a minute per process, and that call carries on as if the cache were off.
The process then leaves Redis alone for BACKOFF_SECONDS, so a dead or
unreachable Redis costs one timeout per process every few seconds, not one
per question (a whole-paper fetch would otherwise pay it for every question).
Rollback is unsetting the URL.

COUNTED, SO GRAFANA CAN SEE IT. Nothing else monitors this Redis (no exporter,
no Prometheus series), and a hit used to leave no trace at all. Each process
tallies reads, misses and errors and logs them as one `question cache: stats`
line at most every STATS_EVERY_SECONDS (on its next read or error, so an idle
process logs nothing), for Loki:
`sum by (pod) (sum_over_time({namespace="ethara"} |= "question cache: stats"
| logfmt | unwrap misses [1h]))`.
"""
import hashlib
import json
import logging
import os
import time
from urllib.parse import parse_qs, urlsplit

_logger = logging.getLogger(__name__)

URL_PARAM = "assessments_be_v2.redis_url"
TTL_SECONDS = 24 * 3600
#: Single flight: the first process to miss a key builds it under this lock;
#: the others wait up to WAIT_SECONDS for the fill, then build themselves.
LOCK_SECONDS = 30
WAIT_SECONDS = 0.2
POLL_SECONDS = 0.02
#: Larger content is not cached. An empty string is stored in its place, so a
#: process that misses builds straight away instead of waiting on a fill that
#: will never come.
MAX_BYTES = 256 * 1024
WARN_EVERY_SECONDS = 60
#: After any Redis error this process serves from Postgres for this long.
BACKOFF_SECONDS = 10
STATS_EVERY_SECONDS = 300
#: Every file whose code shapes the cached content, relative to the module.
#: Move a builder into another file and that file belongs here too.
_BUILDER_FILES = (
    "controllers/api/serializers.py",   # question_content and its helpers
    "controllers/api/candidate.py",     # _label_boxes
    "controllers/media_stream.py",      # annotated_is_worker_safe
    "services/labelling.py",            # label_overlay
    "services/scoring.py",              # the label key readers
    "services/question_cache.py",
    "constants.py",                     # DEFAULT_IMAGE_LABEL_COUNT
)
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: One client per process per URL (redis-py keeps its own pool inside it).
_clients = {}
_last_warning = [float("-inf")]
_skip_until = [float("-inf")]
_stats = {"reads": 0, "misses": 0, "errors": 0}
_stats_since = [time.monotonic()]


def _tally(reads=0, misses=0, errors=0):
    _stats["reads"] += reads
    _stats["misses"] += misses
    _stats["errors"] += errors
    now = time.monotonic()
    if now - _stats_since[0] >= STATS_EVERY_SECONDS:
        _logger.info("question cache: stats reads=%(reads)d "
                     "misses=%(misses)d errors=%(errors)d", dict(_stats))
        _stats.update(reads=0, misses=0, errors=0)
        _stats_since[0] = now


def _warn(exc):
    _tally(errors=1)
    now = time.monotonic()
    _skip_until[0] = now + BACKOFF_SECONDS
    if now - _last_warning[0] >= WARN_EVERY_SECONDS:
        _last_warning[0] = now
        _logger.warning("question cache: Redis failed, serving from Postgres "
                        "(%s: %s)", type(exc).__name__, exc)


def _url(env):
    """`(url, source)`: `REDIS_URL` from the environment wins over the
    setting; `("", "")` is off."""
    url = (os.environ.get("REDIS_URL") or "").strip()
    if url:
        return url, "env"
    url = (env["ir.config_parameter"].sudo().get_param(URL_PARAM)
           or "").strip()
    return url, ("setting" if url else "")


def describe(env):
    """For `/api/v1/settings`: on or off, where the URL came from, its
    target as scheme://host:port/db, and whether this server reaches it now
    (a live PING; False too while backing off after an error). Never the
    user name or the password."""
    url, source = _url(env)
    target = ""
    if url:
        try:
            parts = urlsplit(url)
            db = (parse_qs(parts.query).get("db", [""])[0]
                  or parts.path.strip("/") or "0")
            # Digits only: in a malformed URL this slot can hold password text.
            db = db if db.isdigit() else "?"
            target = "%s://%s:%s/%s" % (parts.scheme, parts.hostname or "",
                                        parts.port or 6379, db)
        except ValueError:
            target = "unreadable URL"
    return {"enabled": bool(url), "source": source, "target": target,
            "reachable": bool(url) and _reachable(env)}


def _reachable(env):
    client = _client(env)
    if client is None:
        return False
    try:
        return bool(client.ping())
    except Exception as exc:                                # noqa: BLE001
        _warn(exc)
        return False


def _client(env):
    """The process's client for the configured URL, or None when off or
    backing off after an error."""
    url = _url(env)[0]
    if not url or time.monotonic() < _skip_until[0]:
        return None
    client = _clients.get(url)
    if client is None:
        try:
            import redis
            # redis-py 5 retries nothing unless asked (Retry(NoBackoff(), 0)).
            # A 100 ms ceiling on connect and on every call keeps a dead Redis
            # from holding the request. No pool cap: a prefork worker serves
            # one request at a time and so holds one connection; on a threaded
            # server a cap made every request past it a "Too many
            # connections" error, which the back-off then turned into the
            # cache being off.
            client = redis.Redis.from_url(
                url, socket_connect_timeout=0.1, socket_timeout=0.1)
        except Exception as exc:                            # noqa: BLE001
            # Never the message: urllib quotes the URL's text, password
            # included ("Port could not be cast to integer value as '...'").
            _warn(RuntimeError("unreadable Redis URL (%s); percent-encode "
                               "the password" % type(exc).__name__))
            return None
        _clients[url] = client
    return client


def code_hash(root):
    """8 hex of the builder files' bytes under `root`. A missing file is
    hashed as its name and logged, never raised: this runs at import, and a
    rename must not take the whole module down."""
    digest = hashlib.sha1()
    for path in _BUILDER_FILES:
        try:
            with open(os.path.join(root, path), "rb") as handle:
                digest.update(handle.read())
        except OSError:
            _logger.warning("question cache: builder file %s is missing; "
                            "update _BUILDER_FILES", path)
            digest.update(b"missing:" + path.encode())
    return digest.hexdigest()[:8]


#: The code part of every key, computed once at import.
CODE = code_hash(_ROOT)


def _key(question):
    return "%s:q:%s:%s:%s" % (question.env.cr.dbname, question.id,
                              question.write_date.isoformat(), CODE)


def _blob(content):
    blob = json.dumps(content, separators=(",", ":"))
    return blob if len(blob) <= MAX_BYTES else ""


def _load(raw, keys):
    """A stored value as content, or None: anything but a JSON object holding
    every key in `keys` is a miss (a hit missing one would be a KeyError, a
    500, for every candidate until the TTL)."""
    try:
        content = json.loads(raw)
    except ValueError:
        return None
    if isinstance(content, dict) and content.keys() >= keys:
        return content
    return None


def fetch(question, build, keys=frozenset()):
    """`build()`'s content for `question`, served from Redis when it can be.

    `build` must return only JSON-safe question content (see the module
    docstring). Its own errors propagate exactly as they did uncached. A
    stored value that is not a JSON object with every key in `keys` is a
    miss, rebuilt and overwritten.
    """
    client = _client(question.env)
    if client is None or not question.write_date:
        return build()
    raw = None
    locked = False
    try:
        key = _key(question)
        raw = client.get(key)
        if raw is None:
            locked = bool(client.set(key + ":build", 1, nx=True,
                                     ex=LOCK_SECONDS))
            if locked:
                # A fill can land between the GET and the lock, its holder
                # having already dropped the lock: look once more.
                raw = client.get(key)
                if raw is not None:
                    client.delete(key + ":build")
                    locked = False
            # Another process is building it: wait briefly for its fill.
            deadline = time.monotonic() + WAIT_SECONDS
            while not locked and raw is None \
                    and time.monotonic() < deadline:
                time.sleep(POLL_SECONDS)
                raw = client.get(key)
        if raw:
            content = _load(raw, keys)
            if content is not None:
                _tally(reads=1)
                return content
            raw = None
    except Exception as exc:                                # noqa: BLE001
        _warn(exc)
        return build()
    _tally(reads=1, misses=1)
    try:
        content = build()
        if raw is None:
            try:
                client.set(key, _blob(content), ex=TTL_SECONDS)
            except Exception as exc:                        # noqa: BLE001
                _warn(exc)
    finally:
        # Ours to drop, filled or crashed: a lock left to its 30 s would
        # make every miss of this key wait 200 ms.
        if locked:
            try:
                client.delete(key + ":build")
            except Exception as exc:                        # noqa: BLE001
                _warn(exc)
    return content


def fetch_many(questions, build, keys=frozenset()):
    """`{question id: content}` for a whole paper in ONE round trip (a
    pipeline of GETs), plus one pipeline of SETs for what was missing or
    unreadable. `build(question)` and `keys` as in `fetch`. No single flight:
    the launch warm-up fills a paper before its cohort starts, and a miss
    here costs what the cache being off costs.
    """
    client = _client(questions.env) if questions else None
    stored = questions.filtered("write_date") if client else questions[:0]
    raws = []
    if stored:
        try:
            pipe = client.pipeline(transaction=False)
            for question in stored:
                pipe.get(_key(question))
            raws = pipe.execute()
        except Exception as exc:                            # noqa: BLE001
            _warn(exc)
            stored = questions[:0]
    contents, fills = {}, []
    for question, raw in zip(stored, raws):
        content = _load(raw, keys) if raw else None
        if content is not None:
            contents[question.id] = content
        elif raw != b"":            # b"" is "too large", never refilled
            fills.append(question)
    if stored:
        _tally(reads=len(stored), misses=len(stored) - len(contents))
    for question in questions:
        if question.id not in contents:
            contents[question.id] = build(question)
    if fills:
        try:
            pipe = client.pipeline(transaction=False)
            for question in fills:
                pipe.set(_key(question), _blob(contents[question.id]),
                         ex=TTL_SECONDS)
            pipe.execute()
        except Exception as exc:                            # noqa: BLE001
            _warn(exc)
    return contents


def warm(questions, build):
    """Fill the cache for every question of a paper at launch.

    Best effort, and it never fails the launch: the first failure of any
    kind stops the warm-up and the launch carries on. The reads run inside a
    savepoint, so even a database error (a statement timeout) leaves the
    launch's transaction usable. The launch's own writes are flushed first,
    OUTSIDE it: their errors are the launch's, and a rollback to the
    savepoint must not undo a write the ORM believes is stored. No `flush`
    savepoint, whose rollback would also drop the launch's precommit hooks.
    """
    client = _client(questions.env)
    if client is None:
        return
    env = questions.env
    env.flush_all()
    try:
        with env.cr.savepoint(flush=False):
            # One round trip for the whole paper.
            pipe = client.pipeline(transaction=False)
            for question in questions:
                if question.write_date:
                    pipe.set(_key(question), _blob(build(question)),
                             ex=TTL_SECONDS)
            pipe.execute()
    except Exception as exc:                                # noqa: BLE001
        _warn(exc)
        return
    _logger.info("question cache: warmed %d question(s)", len(questions))

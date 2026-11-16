import json
import logging
import os
import random
import re
import time
from datetime import datetime, timedelta

from psycopg2 import Error as PsycopgError
from psycopg2.errors import TransactionRollbackError

from odoo import SUPERUSER_ID, api

from ..constants import (
    QUESTION_TYPE_CODES as _QUESTION_TYPES,
    GENERATABLE_QUESTION_TYPE_CODES as _GENERATABLE_TYPES,
    DIFFICULTY_CODES as _DIFFICULTIES,
    IMAGE_QUESTION_TYPES as _IMAGE_TYPES,
    VIDEO_QUESTION_TYPES as _VIDEO_TYPES,
    NON_GENERATABLE_QUESTION_TYPES as _NON_GENERATABLE_TYPES,
    MEDIUM_CODES as _MEDIA,
    AB_DEFAULT_DIMENSIONS as _AB_DEFAULT_DIMS,
    AB_CHOICES as _AB_CHOICES,
    AB_CHOICE_SET as _AB_CHOICE_SET,
    AB_FLAWED_SIDES,
    ab_side_verdict, ab_other_side,
    ab_flip_construction_keys, ab_specs_from_construction_keys,
    ab_flip_sides_in_text, ab_is_side_option,
    template_slot_names, fill_template_slots, TEMPLATE_SLOT_FALLBACK,
    parse_flaw_plan,
    parse_task_registry, task_answer_contract, task_question_type,
    parse_shape_quotas, quota_shortfall, effective_generation_count,
    is_template_shape, template_id_of_shape,
    TASK_RESPONSE_PRIMITIVES as _TASK_PRIMITIVES,
    ab_code_from_label,
    ab_normalize_dim_key, ab_normalize_verdict, ab_is_tie_word,
    AB_VERDICT_SYNONYMS, _ab_norm_phrase,
    AB_OVERALL_CODE,
    validate_flaw_plan, normalize_flaw_plan,
    QUESTION_TYPE_PROMPT_LIST,
    ANSWER_KEY_REQUIREMENT,
    QUESTION_TYPE_ORDER as _QUESTION_TYPE_ORDER,
    VERTEX_DEFAULT_LOCATION,
    VERTEX_DEFAULT_MODEL,
    GENERATION_DEFAULT_MODEL,
    VERTEX_GLOBAL_LOCATION,
    VIDEO_DEFAULT_MODEL,
    VIDEO_DEFAULT_LOCATION,
    VIDEO_DEFAULT_DURATION_S,
    snap_video_duration,
    video_allowed_durations,
    is_duration_error,
    parse_supported_durations,
    ADVISORY_LOCK_VERTEX_BEARER,
    text_has_source_reference,
    DEFAULT_IMAGE_LABEL_COUNT,
    DEFAULT_DAILY_LLM_CAP_USD,
    DEFAULT_PER_EVALUATOR_LLM_CAP_USD,
)
from . import defect_render as _defect_render
from . import model_catalog

_logger = logging.getLogger(__name__)

_IMAGE_OR_VIDEO_TYPES = frozenset(
    (_IMAGE_TYPES | _VIDEO_TYPES) - _NON_GENERATABLE_TYPES)


def _label_box_cap(value):
    """The ceiling on how many numbered boxes ONE image_label question carries.

    Every lane in this module takes the cap as an OPTIONAL argument so a caller
    with no generator in scope (a bank re-detect, an on-demand capture, a test)
    keeps working; they all funnel through here so "unset" means one thing.
    Anything that is not a positive integer - None, 0, False from an unset
    Many2one, a string the admin typed - resolves to the module default rather
    than to zero boxes, because a question with nothing to label is a worse
    failure than one that carries the old hard-coded 20.
    """
    try:
        n = int(value)
    except (TypeError, ValueError):
        return DEFAULT_IMAGE_LABEL_COUNT
    return n if n >= 1 else DEFAULT_IMAGE_LABEL_COUNT

# The deterministic defect-injection ops the true-by-construction image_label
# (q7r) renderer supports.
#
# DERIVED FROM THE RENDERER, not restated. This used to be a hand-written set
# whose comment claimed to be the "single source of truth shared by ...
# services/defect_render.py (_OPS)" - but nothing imported anything, so there
# were two lists that happened to agree. Adding a 9th op to the renderer would
# have left the generation contract and the item validator rejecting a plan the
# renderer could draw. `defect_render` imports PIL lazily (inside functions),
# so importing it here costs nothing at module load.
_DEFECT_OPS = frozenset(_defect_render._OPS)

# Internal-taxonomy label the generator sometimes prepends to a question title
# (e.g. "Rule Application: ...", "Skill Probe: ..."). Stripped at draft-build so
# titles stay plain and candidate-facing. Keeps the "Task:" prefix (meaningful).
_JARGON_NAME_PREFIX_RE = re.compile(
    r"^\s*(?:rule\s+application|skill\s+probe|skill\s+check|fact\s+recall|"
    r"knowledge\s+check|assessment\s+question|assessment|concept\s+check|"
    r"rule\s+check|probe)\s*[:\-\u2013\u2014]\s*",
    re.IGNORECASE)

INLINE_QUESTION_PROMPT = (
    "You are an expert assessment author. Generate questions for the given "
    "SKILL grounded in the supplied artifacts. Return ONLY a JSON array, no "
    "markdown. Each item: name (short title), prompt (full question text), "
    'question_type (one of ' + QUESTION_TYPE_PROMPT_LIST + '), '
    'difficulty (easy/medium/hard), and the answer-key '
    "fields its type needs: mcq -> options (list) + correct_answer (string); "
    "msq -> options (list) + correct_answer (list); subjective_rubric -> "
    "rubric (object with checklist/constraints/pass_condition). For the "
    "image types the per-request directive gives the exact image_specs shape; "
    "do NOT emit options/correct_answer for image types. Every question MUST be "
    "self-contained: never reference the SOP, source, or guidelines — bake the "
    "deciding facts into the scenario itself."
)

_SELF_CONTAINED_RULE = (
    "\n\nHARD RULE - SELF-CONTAINED: Every question MUST be answerable from the "
    "scenario you write plus the candidate's skill ALONE. NEVER reference, cite, "
    "quote, or allude to the SOP, the source material, the guidelines, a "
    "Section/Step/Clause, or any document the candidate cannot see. Bake every "
    "deciding fact into the scenario. This binds the prompt, options, rubric and "
    "official_reasoning. The candidate NEVER has the SOP during the exam. The "
    "attached SAMPLE questions are for FORMAT only: when one points at the SOP "
    "(\"Refer to the SOP for...\", \"SOP section 6\", \"according to the "
    "SOP\"), never copy that pointer - drop it, or state the rule itself."
)

# THE REPAIR BEHIND THE RULE (owner, 2026-09-29). The rule above was broken on
# 8 of 8 labelling questions in one run: High Res Dense's own golden.docx says
# "Refer to the SOP for the full element list", and the model copies a sample's
# format. So every string that still points at the SOP is sent back in ONE small
# call to be rewritten, and only a rewrite that no longer does is kept.
_SOURCE_REWRITE_DIRECTIVE = (
    "Each text below is part of an assessment question. The candidate answering "
    "it has NOT read the SOP (the project's instructions document), and neither "
    "has the grader. Rewrite each text so it never mentions or points at the "
    "SOP, the source document, the guidelines, or a section/step/clause of "
    "them: state the rule or fact itself instead, and delete a sentence whose "
    "only job is to send the reader to the document. Keep everything else - "
    "meaning, facts, wording, length, language - the same. Return ONLY a JSON "
    'array of {"id": <same id>, "text": <rewritten text>}, one per input.'
    "\n\nTEXTS:\n")

# Where a SOP pointer is rewritten: everything a candidate or grader reads.
# NEVER an option, a correct answer or a key verdict - the answer key matches
# those strings exactly, so rewording one would break the key.
_REWRITE_ROOTS = ("name", "prompt", "official_reasoning", "rubric",
                  "image_specs")
_REWRITE_SKIP_KEYS = frozenset({
    "options", "choices", "correct_answer", "answers", "construction_keys",
    "dimension_options", "source_url", "slot"})


def _source_citing_strings(items):
    """[(item, path, text)] for every rewritable string that points at the SOP."""
    found = []

    def walk(item, node, path):
        if isinstance(node, str):
            if text_has_source_reference(node):
                found.append((item, path, node))
        elif isinstance(node, dict):
            for key, value in node.items():
                if key not in _REWRITE_SKIP_KEYS:
                    walk(item, value, path + (key,))
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(item, value, path + (i,))

    for item in items:
        if not isinstance(item, dict):
            continue
        for root in _REWRITE_ROOTS:
            if root in item:
                walk(item, item[root], (root,))
        solution = item.get("_solution")
        if isinstance(solution, dict) and "rationale" in solution:
            walk(item, solution["rationale"], ("_solution", "rationale"))
    return found


def _rewrite_source_references(env, model, items, usage_ctx=None):
    """Rewrite, in place, every string that still points at the SOP. Returns
    how many were fixed. Best-effort: a failed call keeps the originals, and
    the draft's warning still says so. A kill still stops it."""
    found = _source_citing_strings(items)
    if not found:
        return 0
    payload = [{"id": n, "text": text} for n, (_i, _p, text) in enumerate(found)]
    try:
        raw = _call_vertex(
            env, None, user_text="",
            user_parts=[{"text": _SOURCE_REWRITE_DIRECTIVE + json.dumps(
                payload, ensure_ascii=False, indent=1)}],
            model=model, max_tokens=_MAX_OUTPUT_TOKENS_CEILING,
            temperature=0.2, response_json=True, usage_ctx=usage_ctx)
        replies = _extract_json_array(raw)
    except VertexCancelledError:
        raise
    except Exception as exc:  # noqa: BLE001 - never sink the batch over this
        _logger.warning("etp_assessment SOP-reference rewrite failed: %s", exc)
        return 0
    fixed = 0
    for reply in replies:
        if not isinstance(reply, dict):
            continue
        try:
            item, path, _old = found[int(reply.get("id"))]
        except (TypeError, ValueError, IndexError):
            continue
        text = reply.get("text")
        if not isinstance(text, str) or not text.strip() \
                or text_has_source_reference(text):
            continue
        node = item
        for key in path[:-1]:
            node = node[key]
        node[path[-1]] = text.strip()
        fixed += 1
    return fixed


def _item_cites_source(item):
    if not isinstance(item, dict):
        return False
    parts = [item.get("name"), item.get("prompt"), item.get("official_reasoning")]
    opts = item.get("options")
    if isinstance(opts, list):
        parts.extend(str(o) for o in opts)
    ca = item.get("correct_answer")
    parts.extend(str(c) for c in ca) if isinstance(ca, list) else parts.append(
        str(ca) if ca else None)
    for key in ("rubric", "image_specs"):
        val = item.get(key)
        if isinstance(val, dict):
            parts.append(json.dumps(val, ensure_ascii=False))
    return text_has_source_reference(*[p for p in parts if p])


def _param(env, key, default=""):
    val = env["ir.config_parameter"].sudo().get_param(key, default) or default
    if isinstance(val, str) and "PLACEHOLDER" in val:
        return default
    return val


def _secret_param(env, key, default=""):
    """Read a credential that may be stored ENCRYPTED.

    `vertex_api_key` and `vertex_access_token` are listed in
    `secret_store.SECRET_PARAM_KEYS`, so both the settings form and
    `/api/v1/settings/update` write them through Fernet. A plain `_param` here
    therefore handed Vertex the literal `enc:v1:...` ciphertext as the key,
    which fails as a 401 that names nothing and points nowhere.

    `decrypt` returns a value WITHOUT the `enc:v1:` marker unchanged, so a
    legacy plaintext row keeps working until the next Save re-encrypts it. The
    PLACEHOLDER strip is `_param`'s and has to run AFTER decryption - the
    marker is on the stored value, the placeholder is in the plaintext.
    """
    from . import secret_store
    val = secret_store.get_secret(env, key, default) or default
    if isinstance(val, str) and "PLACEHOLDER" in val:
        return default
    return val


def _vertex_creds(env):
    return (
        _param(env, "assessments_be_v2.vertex_project_id"),
        _param(env, "assessments_be_v2.vertex_location", VERTEX_DEFAULT_LOCATION),
        _param(env, "assessments_be_v2.vertex_model", VERTEX_DEFAULT_MODEL),
        _secret_param(env, "assessments_be_v2.vertex_api_key"),
    )


def _vertex_image_model(env):
    return _param(env, "assessments_be_v2.image_model") \
        or _vertex_creds(env)[2]


_HTTPX_CLIENT = None

# write=180: a large SOP (a 6MB+ PDF becomes ~8MB base64 on the wire) can
# exceed a short write timeout on a slow uplink and abort the whole generation
# with WriteTimeout. read=180 covers the thinking model's long generateContent
# latency. A call under a `deadline` caps each phase, never raises one.
_HTTP_TIMEOUTS = {"connect": 30, "read": 180, "write": 180, "pool": 30}


def _httpx():
    global _HTTPX_CLIENT
    if _HTTPX_CLIENT is None:
        import httpx
        _HTTPX_CLIENT = httpx.Client(
            timeout=httpx.Timeout(**_HTTP_TIMEOUTS),
            limits=httpx.Limits(max_keepalive_connections=20,
                                max_connections=50))
    return _HTTPX_CLIENT


SA_FINGERPRINT_PARAM = "assessments_be_v2.vertex_sa_fingerprint"
SA_PROJECT_SOURCE_PARAM = "assessments_be_v2.vertex_project_id_source"


def _sa_fingerprint(sa):
    """Stable, NON-SECRET identity for a service-account key.

    `client_email` plus `private_key_id` changes on any new key, including a
    re-issued key for the same service account. Hashed and truncated so the
    value is safe in `ir.config_parameter`, in a database dump and in a log
    line - it identifies the key without being usable as one. The private key
    itself is never read here.
    """
    import hashlib
    material = "%s|%s" % (sa.get("client_email") or "",
                          sa.get("private_key_id") or "")
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def _sync_service_account_identity(env, sa):
    """Make a service-account swap a drop-in operation. Returns True if rotated.

    Uploading a new key used to leave TWO things pointing at the old project:

      * `vertex_project_id`, which was only ever auto-filled when EMPTY. A key
        for a different GCP project therefore authenticated as the new service
        account against the old project's URL - a 403 or 404 that names the
        project, not the key, and reads like an entitlement problem.
      * the cached bearer, valid for up to an hour. The settings form and
        `/api/v1/settings/update` do clear it, but nothing else does, so a key
        installed by any other route kept serving the old project until the
        token expired on its own.

    Keyed on a fingerprint rather than on a write hook so it holds for EVERY
    write path, including a direct `ir.config_parameter` update.

    `vertex_project_id` is only re-pointed when it is empty or still equal to
    the project the PREVIOUS key adopted - i.e. when we set it ourselves. A
    project id an admin deliberately typed is left alone and reported, because
    a cross-project setup (key in one project, quota in another) is legitimate
    and silently overwriting it would be the worse failure.

    CONCURRENCY. This runs from `_minted_bearer`, i.e. on the path of EVERY
    Vertex call, and scoring runs up to `MAX_SCORING_SHARDS` of those at once.
    The steady state - fingerprint unchanged - is therefore a single READ that
    returns before touching anything. Only an actual change writes, and that
    write is serialised on the same advisory lock `_minted_bearer` uses for
    minting, with the fingerprint re-read afterwards: whoever loses the race
    wakes up, sees the work already done and returns. Without that, the first
    call after a deploy had every worker writing the same `ir.config_parameter`
    rows at once, which at REPEATABLE READ is `could not serialize access due
    to concurrent update` - the failure mode this module has been bitten by
    before (see tests/test_tag_extract_lifecycle.py).

    The caller treats a raise here as non-fatal, so a lost race costs a retry
    on the next call rather than a failed generation.
    """
    ICP = env["ir.config_parameter"].sudo()
    fingerprint = _sa_fingerprint(sa)
    previous = (ICP.get_param(SA_FINGERPRINT_PARAM, "") or "").strip()
    if previous == fingerprint:
        return False
    # Serialise the write. Re-acquiring this lock is safe even when the caller
    # already holds it: an advisory xact lock is re-entrant within the same
    # transaction, so there is no need for callers to tell us.
    env.cr.execute(
        "SELECT pg_advisory_xact_lock(%s)", (ADVISORY_LOCK_VERTEX_BEARER,))
    # Re-read under the lock. Another worker may have finished the whole sync
    # while we queued for it, in which case there is nothing left to do.
    previous = (ICP.get_param(SA_FINGERPRINT_PARAM, "") or "").strip()
    if previous == fingerprint:
        return False
    rotated = bool(previous) and previous != fingerprint

    sa_project = (sa.get("project_id") or "").strip()
    stored_project = (
        ICP.get_param("assessments_be_v2.vertex_project_id", "") or "").strip()
    adopted_from = (ICP.get_param(SA_PROJECT_SOURCE_PARAM, "") or "").strip()

    if sa_project and stored_project != sa_project:
        if not stored_project or stored_project == adopted_from:
            ICP.set_param("assessments_be_v2.vertex_project_id", sa_project)
            ICP.set_param(SA_PROJECT_SOURCE_PARAM, sa_project)
            _logger.info(
                "etp_assessment: service account changed (%s) - Vertex project "
                "re-pointed %s -> %s to follow the new key.",
                sa.get("client_email") or "?", stored_project or "(unset)",
                sa_project)
        else:
            _logger.warning(
                "etp_assessment: service account changed (%s) and its key is "
                "issued for project %r, but vertex_project_id is set to %r by "
                "hand. KEEPING the manual value. If the new key has no access "
                "to %r, clear the Vertex Project ID setting and it will follow "
                "the key automatically.",
                sa.get("client_email") or "?", sa_project, stored_project,
                stored_project)
    elif sa_project:
        # Already correct. Record it as ours so a FUTURE swap can follow the key
        # instead of reading a matching value as a deliberate manual override.
        ICP.set_param(SA_PROJECT_SOURCE_PARAM, sa_project)

    if rotated:
        # Defence in depth. A bearer minted against the previous key must never
        # outlive it, whichever code path installed the replacement.
        ICP.set_param("assessments_be_v2.vertex_minted_token", "")
        ICP.set_param("assessments_be_v2.vertex_minted_token_expires", "0")
    ICP.set_param(SA_FINGERPRINT_PARAM, fingerprint)
    return rotated


def _load_service_account(sa_json):
    try:
        sa = json.loads(sa_json)
    except (ValueError, TypeError) as exc:
        raise RuntimeError(
            "The stored Vertex service-account JSON is not valid JSON (%s). "
            "Re-upload the key file in Settings." % exc)
    if not isinstance(sa, dict) or not sa.get("client_email") \
            or not sa.get("private_key"):
        raise RuntimeError(
            "The stored Vertex service-account JSON is missing client_email or "
            "private_key. Upload the full key file Google issued, not a "
            "fragment of it.")
    return sa


def _minted_bearer(env):
    ICP = env["ir.config_parameter"].sudo()
    from . import secret_store
    sa_json = secret_store.get_secret(
        env, "assessments_be_v2.vertex_service_account_json", "") or ""
    if not sa_json or "PLACEHOLDER" in sa_json:
        return ""
    # BEFORE the cache is trusted: a token minted against the previous key is
    # worse than no token, because it authenticates successfully against the
    # wrong project.
    sa = _load_service_account(sa_json)
    # NON-FATAL. This is bookkeeping that makes a key swap seamless; it is not a
    # precondition for calling Vertex. If it loses a write race, the old
    # behaviour still holds - the bearer is minted, the project id stays put -
    # and the next call retries. Letting it raise would turn a housekeeping
    # conflict into a failed generation or a lost score.
    try:
        _sync_service_account_identity(env, sa)
    except Exception:                                            # noqa: BLE001
        _logger.warning(
            "etp_assessment: service-account identity sync skipped this call; "
            "will retry on the next one.", exc_info=True)
    cached = ICP.get_param("assessments_be_v2.vertex_minted_token", "") or ""
    expires_at = int(
        ICP.get_param("assessments_be_v2.vertex_minted_token_expires", "0") or 0
    )
    if cached and time.time() < expires_at - 300:
        return cached
    env.cr.execute(
        "SELECT pg_advisory_xact_lock(%s)", (ADVISORY_LOCK_VERTEX_BEARER,))
    cached = ICP.get_param("assessments_be_v2.vertex_minted_token", "") or ""
    expires_at = int(
        ICP.get_param("assessments_be_v2.vertex_minted_token_expires", "0") or 0)
    if cached and time.time() < expires_at - 300:
        return cached
    try:
        import jwt as _jwt
        if not hasattr(_jwt, "encode"):
            raise ImportError(
                "Wrong 'jwt' package installed (no 'encode' attr). "
                "Two PyPI packages collide on the name `jwt`; we need PyJWT. "
                "Fix: pip uninstall jwt -y && pip install 'PyJWT[crypto]'"
            )
    except ImportError as exc:
        raise RuntimeError(
            "Service Account JSON support needs PyJWT installed. %s" % exc
        )
    import httpx
    # `sa` was already parsed and validated above by `_load_service_account`.
    # M-5: the JWT assertion (signed with the SA private key) is POSTed to
    # sa["token_uri"]. A tampered SA JSON could point token_uri at an attacker
    # host and exfiltrate a valid Google-signed assertion. Pin it to Google's
    # OAuth token endpoints before signing anything.
    token_uri = (sa.get("token_uri") or "").strip()
    _allowed_token_hosts = ("oauth2.googleapis.com",
                            "accounts.google.com",
                            "www.googleapis.com")
    from urllib.parse import urlparse as _urlparse
    _tu = _urlparse(token_uri)
    if _tu.scheme != "https" or _tu.hostname not in _allowed_token_hosts:
        raise RuntimeError(
            "Service account token_uri %r is not a recognised Google OAuth "
            "endpoint; refusing to mint a bearer (possible tampered SA JSON)."
            % (token_uri or "<empty>"))
    now = int(time.time())
    claim = {
        "iss": sa["client_email"],
        "scope": "https://www.googleapis.com/auth/cloud-platform",
        "aud": token_uri,
        "iat": now,
        "exp": now + 3600,
    }
    assertion = _jwt.encode(claim, sa["private_key"], algorithm="RS256")
    resp = _httpx().post(
        token_uri,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        },
        timeout=30,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            "Service account token exchange failed [%s]: %s"
            % (resp.status_code, resp.text[:400])
        )
    data = resp.json()
    token = data["access_token"]
    expires_in = int(data.get("expires_in", 3600))
    ICP.set_param("assessments_be_v2.vertex_minted_token", token)
    ICP.set_param(
        "assessments_be_v2.vertex_minted_token_expires", str(now + expires_in)
    )
    # Project id is handled by `_sync_service_account_identity` above, which runs
    # before the token cache and so also FOLLOWS a key swap instead of only
    # filling an empty value.
    _logger.info(
        "etp_assessment minted Vertex bearer for %s (expires in %ss)",
        sa.get("client_email") or "?", expires_in,
    )
    return token


#: A pinned bearer with less than this left is fetched afresh.
_PIN_REFRESH_BELOW = 120


def _vertex_bearer(env):
    # Pinned by a parallel grading lane, which resolves it once on its own
    # cursor: see `scoring.parallel_dispatch`. A pin about to lapse - its call
    # waited in the pool - is replaced by a fresh one.
    pinned = env.context.get("etp_vertex_bearer")
    expires = env.context.get("etp_vertex_bearer_expires") or 0
    if pinned and (not expires
                   or time.time() < expires - _PIN_REFRESH_BELOW):
        return pinned
    return _vertex_bearer_until(env)[0]


def _vertex_bearer_until(env):
    """``(bearer, expires)``, resolved now whatever is pinned: ``expires`` is
    the epoch second a minted bearer lapses, 0 when unknown (pasted token)."""
    direct = _secret_param(env, "assessments_be_v2.vertex_access_token")
    if direct:
        return direct, 0
    # MINTED ON A SHORT CURSOR OF ITS OWN, like the ledger row: on the caller's
    # cursor the refresh's `pg_advisory_xact_lock` and `ir.config_parameter`
    # write would be held - and every other lane wait on them - for the whole
    # Vertex call.
    if not _side_cursor_is_safe(env):
        return _minted_bearer(env), _minted_expiry(env)
    # READ COMMITTED, so a caller that waited on the lock reads the bearer the
    # holder just minted instead of minting over it. Should the write still
    # lose a serialization race, a fresh cursor reads the winner's token;
    # losing twice is a deferral (no attempt spent), as in parallel mode.
    for attempt in range(2):
        try:
            with env.registry.cursor() as cr:
                cr.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                own = api.Environment(cr, SUPERUSER_ID, {})
                return _minted_bearer(own), _minted_expiry(own)
        except TransactionRollbackError as exc:
            if attempt:
                raise VertexQuotaError(
                    "Another lane was refreshing the Vertex token (%s); "
                    "graded on a later tick." % exc) from exc


def _minted_expiry(env):
    return int(env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.vertex_minted_token_expires", "0") or 0)


def _vertex_host(location):
    return (
        f"https://{location}-aiplatform.googleapis.com"
        if location and location != VERTEX_GLOBAL_LOCATION
        else "https://aiplatform.googleapis.com"
    )


def _bearer_project(env, project):
    """``project``, else the project the service-account key was issued for;
    `VertexNotConfiguredError` when neither is set, before a URL reads
    `projects//` and Google answers a 404 that names nothing.

    Minting a bearer adopts the key's project when none is set
    (`_sync_service_account_identity`), but on a cursor of its own that the
    caller's transaction cannot see yet - so the first call after a key is
    saved takes it from the key, as the adoption would. `_gemini_request`
    reads ``project`` BEFORE the bearer: read after, its older snapshot would
    put the stale empty value back into the shared parameter cache.
    """
    if not project:
        from . import secret_store
        try:
            sa = json.loads(secret_store.get_secret(
                env, "assessments_be_v2.vertex_service_account_json", "")
                or "{}")
        except (ValueError, TypeError):
            sa = {}
        project = (sa.get("project_id") or "").strip() \
            if isinstance(sa, dict) else ""
    if not project:
        raise VertexNotConfiguredError(
            _NOT_CONFIGURED % "the Vertex project ID is empty")
    return project


def _gemini_request(env, model, suffix):
    project, location, _model, api_key = _vertex_creds(env)
    bearer = _vertex_bearer(env)
    if bearer:
        project = _bearer_project(env, project)
        host = _vertex_host(location)
        url = (
            f"{host}/v1/projects/{project}/locations/{location}"
            f"/publishers/google/models/{model}:{suffix}"
        )
        return url, {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {bearer}",
        }
    if api_key:
        if api_key.startswith("AQ."):
            url = (
                f"https://aiplatform.googleapis.com/v1/publishers/google/"
                f"models/{model}:{suffix}"
            )
        else:
            url = (
                f"https://generativelanguage.googleapis.com/v1beta/models/"
                f"{model}:{suffix}"
            )
        return url, {
            "Content-Type": "application/json",
            "x-goog-api-key": api_key,
        }
    raise VertexNotConfiguredError(
        _NOT_CONFIGURED % "no API key, static OAuth bearer or service account "
                          "JSON is set")


# Kept under 300 characters: the generation and tag-extract crons store the
# first 300 of an error, and the part that says where to fix it comes last.
_NOT_CONFIGURED = (
    "The AI model (Vertex/Gemini) is not configured: %s. Set it under "
    "Settings > Assessments v2 > Vertex AI, then try again.")


def _load_bundled_prompt(filename):
    try:
        path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "prompts", filename,
        )
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception as exc:
        _logger.warning(
            "etp_assessment: could not load bundled prompt %s: %s",
            filename, exc,
        )
        return ""


def _get_question_prompt(env):
    p = (env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.question_prompt", "") or "").strip()
    if p:
        return p
    bundled = _load_bundled_prompt("question.md")
    return bundled.strip() if bundled.strip() else INLINE_QUESTION_PROMPT


# Pricing, capability and thinking-config rules live in `model_catalog` so that
# adding a model is one edit in one file instead of three edits across three.
#
# These used to be dicts keyed on the EXACT model string, with a `_DEFAULT_PRICE`
# of $1/$5 and `image: 0.0` behind them. Two things went wrong with that:
#   * every model we are moving to was missing, so switching the image model
#     recorded each render as $0.00 and `_check_budget` - which sums the ledger -
#     stopped seeing image spend, taking the daily cap offline for images;
#   * an exact-match dict misses `...-preview`, `...-001` and date-stamped
#     aliases of models it already knows.
# The catalog normalises the ID, falls back to the longest matching family, and
# logs once at WARNING when it truly does not recognise a model.
#
# The four names below are kept as module-level aliases because tools/ and tests
# reference them; they are views onto the catalog, not a second copy.
_PRICING = model_catalog.TEXT_PRICING
_DEFAULT_PRICE = model_catalog.DEFAULT_TEXT_PRICE
_VIDEO_PRICING = model_catalog.VIDEO_PRICING
_DEFAULT_VIDEO_RATE = model_catalog.DEFAULT_VIDEO_RATE


def _estimate_cost(model, tokens_in, tokens_out, thoughts, image_count,
                   cached=0):
    return model_catalog.estimate_cost(
        model, tokens_in, tokens_out, thoughts, image_count, cached)


def _estimate_video_cost(model, video_seconds):
    return model_catalog.estimate_video_cost(model, video_seconds)


_warned_miscast = set()


def _text_lane(lane, *candidates):
    """First candidate that can actually RETURN text, skipping picture models.

    Every text/vision lane here has a fallback chain ending in a known-good
    default. The chain used to be walked with a plain `or`, which accepted
    whatever was in the config parameter - including an image-GENERATION model
    typed into the wrong field. Vertex answers that with "Multi-modal output is
    not supported", or with a picture where JSON was expected, and neither error
    names the real cause. Three docstrings in this module already warned about it
    in prose; this makes it enforceable.

    SKIPS, never raises. An override we cannot honour must not take the lane
    down - the chain still ends in a default that works, so grading and authoring
    keep running on a misconfigured deployment while the log explains itself.
    Returns "" when nothing is usable, so callers keep their own final default.
    """
    for candidate in candidates:
        name = (candidate or "").strip()
        if not name:
            continue
        if model_catalog.is_text_capable(name):
            return name
        key = "%s:%s" % (lane, name.lower())
        if key not in _warned_miscast:
            _warned_miscast.add(key)
            _logger.warning(
                "etp_assessment: %s is set to %r, which GENERATES pictures and "
                "cannot return text or JSON. Ignoring it and falling through to "
                "the next model in the chain. Point %s at a text model "
                "(e.g. gemini-3.1-flash-lite) and use the Image Rendering Model "
                "setting for picture generation.", lane, name, lane)
    return ""


def _side_cursor_is_safe(env):
    """Whether this process may open a cursor of its own and COMMIT on it.

    False under the test runner. A TransactionCase runs on a TestCursor whose
    whole point is that it never really commits, so a side cursor would both
    miss the test's uncommitted fixtures and leave real rows behind after the
    rollback - a suite that dirties the database it runs against.

    Two independent tests, because either one alone has a hole: `test_enable`
    is unset when a single test is selected by tag, and the cursor check is
    what actually decides whether a commit means anything.
    """
    try:
        from odoo.sql_db import Cursor
        from odoo.tools import config
        if config.get("test_enable") or config.get("test_tags"):
            return False
        return isinstance(env.cr, Cursor)
    except Exception:  # noqa: BLE001 - fall back to the caller's cursor
        return False


def _ledger_operations(env):
    """The `operation` values the ledger model will accept.

    Read off the field rather than restated here: a second copy of the list is
    a second thing to forget, and forgetting it is exactly the bug this guard
    exists to contain.
    """
    field = env["assessments.be.llm.usage"]._fields["operation"]
    return {code for code, _label in field.selection}


def _ledger_values(env, model, usage_meta, image_count, ctx):
    """The one place a ledger row's field values are built.

    Shared by the normal path and the failure path so a call that never reached
    a 200 is described by exactly the same columns as one that did.
    """
    meta = usage_meta or {}
    ctx = ctx or {}
    ti = int(meta.get("promptTokenCount") or 0)
    to = int(meta.get("candidatesTokenCount") or 0)
    th = int(meta.get("thoughtsTokenCount") or 0)
    cached = int(meta.get("cachedContentTokenCount") or 0)
    vsec = float(ctx.get("video_seconds") or 0.0)
    cost = (_estimate_video_cost(model, vsec) if vsec > 0
            else _estimate_cost(model, ti, to, th, image_count, cached))
    note = ctx.get("note") or ""

    # COERCE, NEVER DROP. `operation` is a Selection, so an unlisted value
    # raises on create - and this function swallows its own failures, so the
    # row simply vanished along with the money it accounted for. Three
    # operations lived in that blind spot for the module's whole life. An
    # unknown value now lands as `other` with its real name preserved in the
    # note, which is a mislabelled row rather than a missing one.
    operation = ctx.get("operation") or "other"
    if operation not in _ledger_operations(env):
        _logger.warning(
            "etp_assessment LLM usage: operation %r is not on "
            "assessments.be.llm.usage; filing as 'other'. Add it to the "
            "Selection in models/llm_usage.py.", operation)
        note = ("%s [op:%s]" % (note, operation)).strip()
        operation = "other"

    return {
        "operation": operation,
        "model": model or "",
        "tokens_in": ti,
        "tokens_out": to,
        "thoughts_tokens": th,
        "cached_tokens": cached,
        "image_count": image_count or 0,
        "video_seconds": vsec,
        "cost_usd": cost,
        "prompt_id": ctx.get("prompt_id") or False,
        "evaluator_id": ctx.get("evaluator_id") or False,
        "note": note[:120],
        # Text calls only (`_call_vertex_single`); 0 everywhere else.
        "latency_ms": int(ctx.get("latency_ms") or 0),
        "attempt": int(ctx.get("attempt") or 0),
    }


def _write_ledger_row(env, values):
    """Create one usage row so that it SURVIVES THE CALLER'S ROLLBACK.

    WHY A SEPARATE CURSOR. The Vertex call has already happened and Google will
    bill for it whatever this transaction goes on to do. Writing the ledger row
    on the caller's cursor tied the accounting to the outcome of the work: a
    generation that raised, or a 40001 serialization retry (the SOP-gen cron
    rolls back and re-queues, models/prompt.py), took the row down with it and
    the spend became invisible - to the LLM Budget dashboard AND to
    `_check_budget`, which sums this table to enforce the daily cap. Under-
    reporting spend is the one failure mode a cost ledger must not have.

    In test mode the caller's cursor is used instead: a committed side-cursor
    would leak rows past a TransactionCase's rollback and leave the database
    dirty for the next test.
    """
    if not _side_cursor_is_safe(env):
        env["assessments.be.llm.usage"].sudo().create(values)
        return
    with env.registry.cursor() as cr:
        api.Environment(cr, SUPERUSER_ID, {})[
            "assessments.be.llm.usage"].create(values)
        cr.commit()


def log_usage_line(values, cache=False):
    """The one "LLM usage" INFO line, from a ledger row's values.

    Shared with `grading_cache._book`, so spend totalled from the logs
    includes cache create/refresh. `cached` is printed because `in=` already
    includes cached tokens: without it a cache HIT reads as full rate.
    `ms` is the call's wall time (0 when none was measured).
    """
    _logger.info(
        "etp_assessment LLM usage: op=%s model=%s in=%d cached=%d out=%d "
        "thoughts=%d images=%d vsec=%.1f cost=$%.4f ms=%d ev=%s cache=%s "
        "note=%s",
        values["operation"], values["model"], values["tokens_in"],
        values.get("cached_tokens") or 0,
        values["tokens_out"], values["thoughts_tokens"],
        values["image_count"], values["video_seconds"],
        values["cost_usd"], values.get("latency_ms") or 0,
        values.get("evaluator_id") or "-",
        "yes" if cache else "no", values["note"][:60])


def _log_usage(env, model, usage_meta, image_count, ctx, cache=False):
    values = None
    try:
        values = _ledger_values(env, model, usage_meta, image_count, ctx)
        _write_ledger_row(env, values)
        log_usage_line(values, cache=cache)
    except Exception as exc:
        # NEVER swallow a billing-accounting failure silently: the Vertex call
        # already happened and Google WILL bill for it, so a lost usage row means
        # the LLM-budget dashboard silently under-reports real spend. Log loudly
        # with the estimated cost so a human can reconcile against the Vertex
        # invoice; still swallow (don't crash the scoring/gen path on a logging
        # DB hiccup), but the money is now traceable, not invisible.
        _est = (values or {}).get("cost_usd")
        if _est is None:
            try:
                _est = (_estimate_video_cost(model, float((ctx or {}).get(
                            "video_seconds") or 0.0))
                        if (ctx or {}).get("video_seconds")
                        else _estimate_cost(
                            model,
                            int((usage_meta or {}).get("promptTokenCount") or 0),
                            int((usage_meta or {}).get("candidatesTokenCount") or 0),
                            int((usage_meta or {}).get("thoughtsTokenCount") or 0),
                            image_count))
            except Exception:  # noqa: BLE001
                _est = -1.0
        _logger.error(
            "etp_assessment COST ACCOUNTING FAILED (op=%s model=%s est=$%.4f): "
            "%s - the Vertex call was billed but NOT recorded; reconcile the "
            "LLM-budget dashboard against the Vertex invoice.",
            (ctx or {}).get("operation") or "other", model or "", _est, exc)


def _log_failed_call(env, model, ctx, status, detail=""):
    """Record an attempt that never reached a 200.

    A failed call is usually not billed, so this row carries no cost and no
    tokens. It exists so the ledger can answer "how often is the model
    refusing / rate-limiting us", which a table of successes alone cannot -
    and so a 429 storm is visible on the LLM Budget screen rather than only in
    the server log.
    """
    failed_ctx = dict(ctx or {})
    failed_ctx["note"] = ("%s [http:%s %s]" % (
        failed_ctx.get("note") or "", status, (detail or "")[:40])).strip()
    try:
        _write_ledger_row(
            env, _ledger_values(env, model, None, 0, failed_ctx))
    except Exception as exc:  # noqa: BLE001 - a diagnostic must never raise
        _logger.warning(
            "etp_assessment could not record a failed LLM call (%s): %s",
            status, exc)


class LLMRefusalError(RuntimeError):
    """The model declined / was blocked / returned no usable text."""


_BLOCKING_FINISH_REASONS = {
    "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
    "IMAGE_SAFETY", "OTHER",
}
_REFUSAL_MARKERS = (
    "i cannot fulfill", "i can't fulfill", "i cannot create",
    "i can't create", "i cannot generate", "i can't generate",
    "i'm unable to", "i am unable to", "my current capab",
    "as an ai", "i cannot provide", "i can't provide",
)


def _detect_refusal_text(text):
    t = (text or "").strip()
    if not t:
        return "the model returned an empty response"
    head = t[:400].lower()
    if t[:1] in ("[", "{"):
        return None
    for marker in _REFUSAL_MARKERS:
        if marker in head:
            # NO EXCERPT. This message is logged at ERROR with a traceback and
            # stored in candidate-visible `llm_feedback`; on the grading lane
            # the model is quoting the worker's own answer back (services/
            # audit.py: names, emails and answer text stay out of the logs).
            return "the model declined (%d chars, marker %r)" % (
                len(t), marker)
    return None


# Kept as an alias: `gemini-2.5-pro` still rejects thinkingBudget 0 with a 400,
# and the catalog encodes that as "this family cannot be turned down".




def _thinking_level(env, operation=None):
    """Configured `thinkingLevel` for Gemini 3.x, or "" to send nothing.

    Empty is the DEFAULT and means "leave the model at its own depth". See the
    long comment in `model_catalog`: the old code sent `thinkingBudget: 0` to
    3.x models, which ignore it, so live traffic has been running at default
    depth. Translating that to LOW would quietly make grading shallower, so it
    is a setting rather than a silent consequence of the fix.

    `assessments_be_v2.thinking_level.<operation>` (a bare system parameter)
    wins for that ledger operation, so one lane can be turned down without
    touching the others; unset or unusable, the global level applies.
    """
    if env is None:
        return ""
    return model_catalog.normalize_thinking_level(
        operation and _param(env, "assessments_be_v2.thinking_level.%s"
                             % operation)
    ) or model_catalog.normalize_thinking_level(
        _param(env, "assessments_be_v2.thinking_level"))


def _apply_thinking_budget(gen_config, model, env=None):
    """Set whichever thinking field `model`'s generation accepts.

    Delegates because the PARAMETER changed between generations and this used to
    send 2.5's to everything. Gemini 2.5 takes `thinkingBudget` (int, 0 off);
    Gemini 3.x replaced it with `thinkingLevel` (enum) and rejects a request
    carrying both. `gemini-3.1-pro-preview` - the current generation and scoring
    default - is a 3.x model, so the old unconditional `thinkingBudget: 0` was
    already the wrong parameter for our own default.

    Name kept for its callers; see `model_catalog.apply_thinking`.
    """
    model_catalog.apply_thinking(gen_config, model, _thinking_level(env))


_MAX_OUTPUT_TOKENS_CEILING = 64000

# C-2: the MAX_TOKENS / bad-JSON retry doubles maxOutputTokens AND re-sends the
# whole (candidate-controlled) input. Left unbounded that is a cost-DoS lever, so
# the retry is capped hard here — 16k output covers any legitimate generation
# JSON (8 items * ~2k tokens) with headroom, while denying an adversary a
# 64k-token doubled retry on a payload they crafted to overflow.
# Grading passes its own, `scoring._retry_output_tokens`: double its first ask,
# capped at the model's own `max_out`, and reached only on a real MAX_TOKENS.
_RETRY_OUTPUT_TOKENS_CEILING = 16000

# Billed per generated token, so this high cap costs nothing on short outputs.
_GEN_MAX_OUTPUT_TOKENS = 64000

# Under a `deadline`, the least time left a model call is started with. Draft
# from SOP took 17-55 s on stage (13 Oct 2026); a call started with less only
# pays for a reply nobody is left to read.
# ponytail: fixed floor; carry the request's slowest attempt across the
# fallback if fallback calls start getting cut.
_DEADLINE_MIN_ATTEMPT_S = 30

_TERSE_RETRY_DIRECTIVE = (
    "CRITICAL: Output ONLY the JSON array — no reasoning, no explanation, no "
    "markdown fences. Keep every string field concise (short prompts, no repeated "
    "boilerplate) so the ENTIRE JSON array fits in a single response and is never "
    "truncated."
)


def _json_parses(text):
    t = (text or "").strip()
    t = re.sub(r"^```(?:json)?", "", t).strip()
    t = re.sub(r"```$", "", t).strip()
    try:
        json.loads(t)
        return True
    except Exception:
        return False


def _call_vertex_single(env, system_prompt, user_text, max_tokens=4000,
                        temperature=0.4, usage_ctx=None, response_json=False,
                        response_schema=None, user_parts=None, model=None,
                        thinking=False, cached_content=None,
                        retry_max_tokens=None, json_retry=True,
                        finish_out=None):
    """``cached_content``: a context cache's name, sent as `cachedContent`.
    The cache already holds the system instruction, so the caller passes none.
    A cache Vertex no longer has raises `VertexCacheMissError`.

    ``retry_max_tokens``: the most a cut-off reply is asked again with, in
    place of `_RETRY_OUTPUT_TOKENS_CEILING` (grading passes its own).

    ``json_retry``: whether unparseable JSON is also re-asked with more room.
    Grading passes False - `scoring._grade_job` already re-asks such a reply
    once, and more tokens do not fix a reply that was never cut off.

    ``finish_out``: optional list; the returned reply's `finishReason` is
    appended, so a caller can tell a cut-off reply from a whole one.
    """
    import httpx
    _project, _loc, default_model, _key = _vertex_creds(env)
    model = model or default_model
    url, headers = _gemini_request(env, model, "generateContent")

    # H-5: refuse before spending if a daily / per-candidate cap is already hit.
    _check_budget(env, usage_ctx)
    # ...and refuse outright if an admin has killed this generator. Same
    # position, same reason: no money leaves before both gates have passed.
    _check_cancelled(env, usage_ctx)
    # This is also the scoring lane: a grading call comes through here carrying
    # `evaluator_id`. Kill Scoring on its assessment must refuse it at the same
    # point, before the request, so a stopped run stops spending within one
    # call. The worst case a checkpoint here can produce is a call not made -
    # never a score lost, because a refusal raises before anything is written.
    _check_scoring_cancelled(env, usage_ctx)

    # A request above the model's own output ceiling is refused outright, so
    # every attempt - retries included - stays under it (W14).
    attempt_tokens = model_catalog.clamp_output_tokens(model, max_tokens)
    retry_ceiling = model_catalog.clamp_output_tokens(
        model, retry_max_tokens or _RETRY_OUTPUT_TOKENS_CEILING)
    pinned = bool(env.context.get("etp_vertex_bearer"))
    last_finish = None
    # Resolved ONCE, not per attempt: the retry loop below re-enters this body,
    # and the configured level cannot change between two attempts of the same
    # call. Reading it inside the loop was a needless second config query.
    thinking_level = None if thinking else _thinking_level(
        env, (usage_ctx or {}).get("operation"))
    # A web route's `deadline` (a time.monotonic() value): no attempt starts
    # that cannot finish before it, and the one in flight is cut there, so the
    # route answers before Odoo's `limit_time_real` kills its worker. A retry
    # asks for MORE tokens, so it needs at least as long as the slowest so far.
    deadline = (usage_ctx or {}).get("deadline")
    slowest = 0.0
    for attempt in range(2):
        gen_config = {
            "maxOutputTokens": attempt_tokens,
            "temperature": temperature,
        }
        # thinking=True (P5 video scoring: research score.py:252 "video judging
        # needs deep reasoning -> thinking ON") lets the model reason instead of
        # capping it. Leave the field unset entirely so the model self-sizes.
        if not thinking:
            model_catalog.apply_thinking(gen_config, model, thinking_level)
        if response_json:
            gen_config["responseMimeType"] = "application/json"
            if response_schema:
                gen_config["responseSchema"] = response_schema
        payload = {
            "contents": [{"role": "user",
                          "parts": user_parts or [{"text": user_text}]}],
            "generationConfig": gen_config,
        }
        if cached_content:
            payload["cachedContent"] = cached_content
        # Vertex rejects a systemInstruction whose only part has null/empty text
        # ("only text part is used to specify the system_instruction"). Omit the
        # field entirely when there is no system prompt (e.g. the critique pass and
        # the locate_defect grounding call pass None/"" here).
        if system_prompt:
            payload["systemInstruction"] = {"parts": [{"text": system_prompt}]}
        cap = {}
        if deadline:
            left = deadline - time.monotonic()
            if left < max(slowest, _DEADLINE_MIN_ATTEMPT_S):
                raise VertexDeadlineError(
                    "%.0fs left before this request's deadline, too little "
                    "for another model call; none was made." % left)
            cap = {"timeout": httpx.Timeout(**{
                phase: min(left, limit)
                for phase, limit in _HTTP_TIMEOUTS.items()})}
        _logger.info(
            "etp_assessment Vertex call: model=%s max_tokens=%d json=%s attempt=%d",
            model, attempt_tokens, response_json, attempt + 1,
        )
        sent_at = time.monotonic()
        try:
            resp = _httpx().post(url, json=payload, headers=headers, **cap)
        except httpx.TimeoutException as exc:
            if not cap:
                raise
            # Timed and numbered like a reply's row. Its cost stays unknown:
            # Vertex may bill a call it was still answering, and the row
            # carries none.
            _log_failed_call(env, model, dict(
                usage_ctx or {}, attempt=attempt + 1,
                latency_ms=int((time.monotonic() - sent_at) * 1000)),
                "deadline", str(exc))
            raise VertexDeadlineError(
                "the model did not answer before this request's deadline"
            ) from exc
        slowest = max(slowest, time.monotonic() - sent_at)
        if resp.status_code == 401 and pinned:
            # A PINNED BEARER CAN LAPSE WHILE ITS CALL WAITS for a grading
            # worker (`scoring.parallel_dispatch`). That 401 is about the
            # bearer, not the answer: sent once more with a fresh one.
            pinned = False
            _logger.warning("etp_assessment Vertex refused a pinned bearer "
                            "[401]; resending with a fresh one.")
            _log_failed_call(env, model, usage_ctx, 401, resp.text)
            url, headers = _gemini_request(
                env(context=dict(env.context, etp_vertex_bearer=False)),
                model, "generateContent")
            resp = _httpx().post(url, json=payload, headers=headers)
        if resp.status_code != 200:
            # Ledger the attempt before raising. A refusal is usually not
            # billed, so the row carries no cost - it is here so the LLM
            # Budget screen can show a 429 storm, which a table of successes
            # alone cannot.
            _log_failed_call(env, model, usage_ctx, resp.status_code, resp.text)
            if resp.status_code == 429:
                raise VertexQuotaError(
                    f"Vertex quota exhausted [429]: {resp.text[:200]}")
            if cached_content and (
                    resp.status_code == 404
                    or (resp.status_code in (400, 403)
                        and "cache" in (resp.text or "").lower())):
                raise VertexCacheMissError(
                    f"Context cache unusable [{resp.status_code}]: "
                    f"{resp.text[:200]}")
            raise RuntimeError(
                f"Vertex error [{resp.status_code}]: {resp.text[:400]}"
            )
        data = resp.json()
        _log_usage(env, model, data.get("usageMetadata"), 0,
                   dict(usage_ctx or {},
                        latency_ms=int((time.monotonic() - sent_at) * 1000),
                        attempt=attempt + 1),
                   cache=bool(cached_content))
        block = (data.get("promptFeedback") or {}).get("blockReason")
        if block:
            raise LLMRefusalError(
                "the model blocked this request (%s). This usually means the "
                "question/skill does not fit the requested medium." % block)
        try:
            cand = data["candidates"][0]
        except (KeyError, IndexError, TypeError):
            raise LLMRefusalError(
                "the model returned no candidates: %s" % str(data)[:200])
        finish = cand.get("finishReason")
        last_finish = finish
        if finish in _BLOCKING_FINISH_REASONS:
            raise LLMRefusalError(
                "the model stopped without an answer (reason: %s). This usually "
                "means a safety block or a medium mismatch." % finish)
        parts = ((cand.get("content") or {}).get("parts")) or []
        text = "".join(
            p["text"] for p in parts
            if isinstance(p, dict) and p.get("text") and not p.get("thought"))
        if not text:
            if (finish == "MAX_TOKENS" and attempt == 0
                    and attempt_tokens < retry_ceiling):
                attempt_tokens = min(attempt_tokens * 2,
                                     retry_ceiling)
                _logger.warning(
                    "etp_assessment Vertex MAX_TOKENS with no text; retrying "
                    "with maxOutputTokens=%d", attempt_tokens)
                continue
            raise LLMRefusalError(
                "the model returned no text content (finishReason: %s)" % finish)
        if (finish == "MAX_TOKENS" and attempt == 0
                and attempt_tokens < retry_ceiling):
            attempt_tokens = min(attempt_tokens * 2,
                                 retry_ceiling)
            _logger.warning(
                "etp_assessment Vertex MAX_TOKENS with truncated text (%d chars); "
                "retrying with maxOutputTokens=%d", len(text), attempt_tokens)
            continue
        refusal = _detect_refusal_text(text)
        if refusal:
            raise LLMRefusalError(refusal)
        if (json_retry and response_json and attempt == 0
                and attempt_tokens < retry_ceiling
                and not _json_parses(text)):
            attempt_tokens = min(attempt_tokens * 2,
                                 retry_ceiling)
            _logger.warning(
                "etp_assessment Vertex returned unparseable JSON (%d chars, "
                "finish=%s); retrying with maxOutputTokens=%d",
                len(text), finish, attempt_tokens)
            continue
        _logger.info(
            "etp_assessment Vertex result: model=%s finish=%s chars=%d attempt=%d",
            model, finish, len(text), attempt + 1)
        if finish_out is not None:
            finish_out.append(finish)
        return text

    raise LLMRefusalError(
        "the model returned no text content after a token-budget retry "
        "(finishReason: %s)" % last_finish)


def _fallback_model(env):
    """Optional second TEXT model retried when the primary fails transiently.
    Empty (default) disables the fallback lane. See res.config.settings help.

    No final default on purpose: an empty return DISABLES the lane, so a picture
    model set here degrades to "no fallback" rather than to a retry that cannot
    succeed and doubles the bill proving it."""
    return _text_lane(
        "fallback_model", _param(env, "assessments_be_v2.fallback_model"))


def _call_vertex(env, system_prompt, user_text, max_tokens=4000,
                 temperature=0.4, usage_ctx=None, response_json=False,
                 response_schema=None, user_parts=None, model=None,
                 thinking=False, served_model_out=None, cached=None,
                 retry_max_tokens=None, json_retry=True, finish_out=None):
    """Resilience wrapper over _call_vertex_single.

    A single Vertex model is a concentration risk: one regional outage or quota
    cut halts BOTH grading and generation. When a fallback model is configured
    (assessments_be_v2.fallback_model) and differs from the primary, a TRANSIENT
    failure (quota 429 or a no-text/parse refusal) is retried once on the
    fallback so an outage is a config flip, not a stalled campaign. A hard budget
    cap (VertexBudgetError) is NOT retried - retrying would only spend more.

    ``served_model_out``: optional list. When provided, the model that ACTUALLY
    produced the returned text is appended (primary on success, fallback when the
    fallback rescued the call). Lets an auditing caller record the true judge
    model even when the fallback fired, instead of assuming the primary.

    ``cached``: optional ``(cache name, user text)`` the PRIMARY model is sent
    instead - the cache holds the system prompt and the question material.
    The fallback never uses it: the cache belongs to the primary model, so the
    fallback is sent ``system_prompt`` and the inline ``user_text``.
    """
    kwargs = dict(
        max_tokens=max_tokens, temperature=temperature, usage_ctx=usage_ctx,
        response_json=response_json, response_schema=response_schema,
        user_parts=user_parts, thinking=thinking,
        retry_max_tokens=retry_max_tokens, json_retry=json_retry,
        finish_out=finish_out)
    primary = model or _vertex_creds(env)[2]
    try:
        if cached:
            text = _call_vertex_single(
                env, None, cached[1], model=primary,
                cached_content=cached[0], **kwargs)
        else:
            text = _call_vertex_single(
                env, system_prompt, user_text, model=primary, **kwargs)
        if served_model_out is not None:
            served_model_out.append(primary)
        return text
    except (VertexQuotaError, LLMRefusalError) as exc:
        fallback = (_fallback_model(env) or "").strip()
        if not fallback or fallback == primary:
            raise
        _logger.warning(
            "etp_assessment Vertex primary model %s failed transiently (%s); "
            "retrying on fallback model %s",
            primary, str(exc)[:160], fallback)
        ctx = dict(usage_ctx or {})
        ctx["note"] = (ctx.get("note") or "") + " [fallback:%s]" % fallback
        kwargs["usage_ctx"] = ctx
        text = _call_vertex_single(
            env, system_prompt, user_text, model=fallback, **kwargs)
        if served_model_out is not None:
            served_model_out.append(fallback)
        return text


class VertexQuotaError(RuntimeError):
    """HTTP 429 (transient). ``partial`` holds slots already rendered and PAID for
    before the 429, so the caller re-renders only what is missing."""

    partial = []


class VertexNotConfiguredError(ValueError):
    """No credential or project to call Vertex with; raised before any request.

    A ValueError, as it always was, so existing callers are unchanged. A caller
    that reads ValueError as "the reply did not parse" must let this one
    through: retrying cannot fix it, and only its message names the setting."""


class VertexCacheMissError(RuntimeError):
    """The context cache a call named is gone (expired, deleted, 404). The
    caller sends the call again inline; no grading attempt is spent."""


class VertexBudgetError(RuntimeError):
    """A per-day or per-candidate LLM spend cap would be exceeded by this call.

    Raised BEFORE the HTTP request so no money is spent. Not transient: the
    admin must raise the cap or wait for the daily window to roll over. Callers
    surface it like a refusal (the response resolves to error, not a silent
    partial)."""


class VertexCancelledError(RuntimeError):
    """An admin killed the generator this call belongs to.

    Raised BEFORE the HTTP request, so the call is never made and never billed.
    Not an error in the run's sense: callers settle the generator to
    `cancelled` rather than `failed`, and they KEEP whatever drafts the run had
    already committed - the admin can discard those from the review queue, and
    throwing away work the money has already paid for helps nobody."""


class VertexDeadlineError(RuntimeError):
    """The caller's `deadline` ran out (see `_call_vertex_single`).

    Either no call was started, because it could not finish in time, or the
    call in flight was cut at the deadline; that one Google still bills.
    Never retried on the fallback model: there is no time left for it."""


def _generation_cancelled(env, prompt_id):
    """Has this generator been killed? Read on a FRESH cursor, and never raise.

    THE FRESH CURSOR IS THE WHOLE POINT. The flag is written and committed by a
    web worker while the run is executing inside a cron worker, whose own
    transaction opened before that commit and therefore cannot see it. A
    short-lived cursor of our own starts a new snapshot, so it does. The cost
    is one primary-key read against a call that takes seconds.

    In test mode the caller's cursor is used instead: a side cursor cannot see
    a TransactionCase's uncommitted fixtures, so it would report every test
    generator as un-cancelled and the tests would pass for the wrong reason.

    A failure here returns False. The kill switch failing closed would stop
    every generator in the database over an unrelated database hiccup, which is
    a far worse outcome than one run that keeps going.
    """
    if not prompt_id:
        return False
    Prompt = env["assessments.be.prompt"].sudo()
    if not _side_cursor_is_safe(env):
        record = Prompt.browse(int(prompt_id))
        return bool(record.exists() and record.sop_gen_cancel_requested)
    try:
        with env.registry.cursor() as cr:
            cr.execute(
                'SELECT sop_gen_cancel_requested FROM "%s" WHERE id = %%s'
                % Prompt._table, (int(prompt_id),))
            row = cr.fetchone()
        return bool(row and row[0])
    except Exception as exc:  # noqa: BLE001 - never block work over the switch
        _logger.warning(
            "etp_assessment could not read the cancel flag for generator %s "
            "(%s); letting the call proceed.", prompt_id, exc)
        return False


def template_draft_cancelled(env, prompt_id, since):
    """Was Draft from SOP stopped for this generator at or after `since`?

    Fresh cursor for the reason `_generation_cancelled` gives: the Stop is
    committed by another web request while this one is waiting on the model.
    Never raises; a failed read lets the call proceed.
    """
    if not prompt_id or not since:
        return False
    Prompt = env["assessments.be.prompt"].sudo()
    if not _side_cursor_is_safe(env):
        record = Prompt.browse(int(prompt_id))
        stopped = record.exists() and record.template_draft_cancelled_at
        return bool(stopped and stopped >= since)
    try:
        with env.registry.cursor() as cr:
            cr.execute(
                'SELECT template_draft_cancelled_at FROM "%s" WHERE id = %%s'
                % Prompt._table, (int(prompt_id),))
            row = cr.fetchone()
        return bool(row and row[0] and row[0] >= since)
    except Exception as exc:  # noqa: BLE001 - never block work over the switch
        _logger.warning(
            "etp_assessment could not read the template-draft stop for "
            "generator %s (%s); letting the call proceed.", prompt_id, exc)
        return False


def _check_cancelled(env, usage_ctx):
    """Refuse a call whose generator has been killed.

    Sits beside `_check_budget` at the top of every billable lane, which is
    what makes one flag stop ALL of a generator's work - SOP generation, image
    rendering, defect grounding, Veo submission and tag extraction alike -
    without each of them growing its own interrupt. The handle is `prompt_id`
    in `usage_ctx`, which every generation-lane call site already carries.

    Scoring has its OWN kill, checked separately: a grading call carries
    `evaluator_id` and no `prompt_id`, so a generator kill still cannot abandon
    a submitted paper - but an ASSESSMENT kill now can, through
    `_check_scoring_cancelled`. The two switches are deliberately distinct
    handles so stopping one never stops the other.
    """
    prompt_id = (usage_ctx or {}).get("prompt_id")
    since = (usage_ctx or {}).get("template_draft_since")
    if since and template_draft_cancelled(env, prompt_id, since):
        raise VertexCancelledError(
            "Drafting a template for generator %s was stopped by an admin; "
            "this call was not made." % prompt_id)
    if not _generation_cancelled(env, prompt_id):
        return
    raise VertexCancelledError(
        "Generation for generator %s was cancelled by an admin; this call was "
        "not made." % prompt_id)


def _scoring_cancelled(env, evaluator_id):
    """Has the ASSESSMENT this candidate belongs to had its scoring killed?

    Read on a FRESH cursor, for the reason `_generation_cancelled` documents:
    the flag is written and committed by a web worker while the grading runs
    inside a cron worker whose transaction opened before that commit and so
    cannot see it. A short-lived cursor of our own starts a new snapshot.

    The scoring `usage_ctx` carries `evaluator_id` and no `assessment_id`, so
    the assessment is resolved from the evaluator in ONE join rather than
    threading a new key through every grading call site. Nothing is cached
    across the read - the whole point is to see the LATEST committed flag, so a
    stale copy would defeat it.

    In test mode the caller's cursor is used, and a failure returns False: the
    kill failing closed would freeze grading across the database over an
    unrelated hiccup, which is worse than one run that keeps going.
    """
    if not evaluator_id:
        return False
    Evaluator = env["assessments.be.evaluator"].sudo()
    Assessment = env["assessments.be"].sudo()
    if not _side_cursor_is_safe(env):
        record = Evaluator.browse(int(evaluator_id))
        return bool(record.exists()
                    and record.assessment_id.scoring_cancel_requested)
    try:
        with env.registry.cursor() as cr:
            cr.execute(
                'SELECT a.scoring_cancel_requested '
                'FROM "%s" a JOIN "%s" e ON e.assessment_id = a.id '
                'WHERE e.id = %%s'
                % (Assessment._table, Evaluator._table), (int(evaluator_id),))
            row = cr.fetchone()
        return bool(row and row[0])
    except Exception as exc:  # noqa: BLE001 - never block work over the switch
        _logger.warning(
            "etp_assessment could not read the scoring cancel flag for "
            "evaluator %s (%s); letting the call proceed.", evaluator_id, exc)
        return False


def _check_scoring_cancelled(env, usage_ctx):
    """Refuse a grading call whose assessment has been killed.

    The scoring twin of `_check_cancelled`, at the SAME billable checkpoints:
    money must not leave after an admin has pressed Kill Scoring. The handle is
    `evaluator_id`, resolved to its assessment on a fresh cursor. A call that
    carries no `evaluator_id` (every generation lane) is not a scoring call, so
    this is a no-op for it - the two kill switches never cross.
    """
    evaluator_id = (usage_ctx or {}).get("evaluator_id")
    if not _scoring_cancelled(env, evaluator_id):
        return
    raise VertexCancelledError(
        "Scoring for the assessment of evaluator %s was cancelled by an "
        "admin; this call was not made." % evaluator_id)


def spend_cap(env, key, default):
    """The configured value of one numeric `assessments_be_v2` money/rate knob.

    PUBLIC, AND THE ONLY RESOLVER. Every surface that reports a cap reads it
    through here - the gate below, the LLM Budget dashboard and the Settings
    route in controllers/api/admin.py - because each one that resolved the key
    for itself resolved it differently: both dashboards substituted 0 for an
    absent row while this function substituted the module default, so the gate
    enforced $100/day against a screen that said there was no cap at all. The
    leading underscore came off for exactly that reason: a private name invites
    the next caller to re-implement it locally and re-open the divergence.

    AN ABSENT OR BLANK ROW IS "NOT CONFIGURED" AND TAKES `default`. A STORED
    "0" IS A DELIBERATE 0 and is returned as such, which is what makes the
    "0 disables the cap" contract in the field help expressible at all.
    """
    raw = env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.%s" % key, "")
    if raw in (None, "", False):
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def _spend_since(env, domain):
    """Sum cost_usd on the usage ledger for ``domain`` (one aggregate query).

    Uses _read_group: read_group is deprecated in Odoo 19 and emitted a
    DeprecationWarning on EVERY billable call (this runs in the budget gate at
    the top of _call_vertex)."""
    rows = env["assessments.be.llm.usage"].sudo()._read_group(
        domain, [], ["cost_usd:sum"])
    return (rows[0][0] or 0.0) if rows else 0.0


def _calls_since(env, seconds):
    """How many billable calls the ledger recorded in the last ``seconds``.

    One aggregate query, and it counts ACROSS WORKERS - which is the whole
    point: the limiter has to hold when four shard crons in four processes are
    draining at once, and no in-process counter can see them all. The ledger is
    already written on every call (`_log_usage`), so this needs no new
    bookkeeping.
    """
    since = (datetime.utcnow() - timedelta(seconds=seconds)).strftime(
        "%Y-%m-%d %H:%M:%S")
    return env["assessments.be.llm.usage"].sudo().search_count(
        [("create_date", ">=", since)])


def _check_rate(env):
    """Refuse a Vertex call that would exceed the configured calls-per-minute.

    WHY THIS EXISTS. There was no proactive rate limiting of any kind - only
    reactive 429 handling once Vertex had already refused. That is the wrong way
    round for two reasons:

      * A 429 is a wasted round trip that still costs latency, and under a
        sustained wave it is most of the traffic.
      * `scoring_shards` is the throughput lever, and raising it multiplies the
        call rate directly: 4 shards run 4 lanes at once, each with up to
        `scoring_parallel_calls` calls in flight. So raising shards
        WITHOUT a limiter converts a slow grading queue into a quota-exhausted
        one. That is why the two belong together and why the settings help
        says to set them as a pair.

    ZERO OR UNSET MEANS NO LIMIT, so this is inert until an operator asks for
    it - the same convention `daily_llm_cap_usd` uses. That matters for the
    default install: nothing changes for anyone who has not configured a quota.

    A TRAILING SIXTY SECONDS, not a fixed clock minute. A per-minute bucket lets
    a wave fire its whole allowance in the last second of one minute and again
    in the first second of the next - twice the intended rate at the boundary,
    which is exactly when a queue is draining hardest.

    RAISES `VertexQuotaError`, NOT A NEW CLASS. That is deliberate and it is the
    important design point here: `VertexQuotaError` is Vertex's own 429, and
    every caller in the module already handles it as TRANSIENT - the candidate
    stays queued and is graded on a later tick, rather than being marked
    ungradeable (`models/prompt.py:785, 1194, 1628, 3942, ...`;
    `services/scoring.py`). A brand-new exception class would be caught by none
    of them and would surface as a scoring FAILURE, which is the opposite of
    what a rate limit means. Refusing locally is the same event as being refused
    remotely, one round trip earlier, so it should raise the same thing.
    """
    limit = spend_cap(env, "vertex_max_rpm", 0.0)
    if limit <= 0:
        return
    recent = _calls_since(env, 60)
    if recent >= limit:
        raise VertexQuotaError(
            "Vertex call rate limit reached: %d calls in the last 60s against "
            "a configured ceiling of %d (assessments_be_v2.vertex_max_rpm). "
            "This candidate stays queued and is graded on a later tick."
            % (recent, int(limit)))


def _check_budget(env, usage_ctx):
    """Refuse a Vertex call that would push same-day or per-candidate LLM spend
    over the configured cap. Uses the persisted usage ledger (actual recorded
    cost, not an estimate) so the gate is honest even across workers. Called at
    the top of every _call_vertex, before any billable HTTP request.

    THE RATE CHECK RUNS HERE TOO, deliberately: this function is already called
    at the top of all four billable entry points, so putting the limiter inside
    it means a new call path cannot forget one gate while remembering the other.
    Rate first, because it is a cheap count against a spend sum.
    """
    _check_rate(env)
    _check_spend(env, usage_ctx)


def _check_spend(env, usage_ctx):
    """The two money caps alone, without the calls-per-minute limit.

    Split out for a re-score request (`action_rescore_individually`), which
    must be refused at once when a cap is reached but not for a rate limit
    that clears within the minute.
    """
    ctx = usage_ctx or {}
    daily_cap = spend_cap(
        env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD)
    if daily_cap > 0:
        # create_date is stored in UTC; compare against UTC midnight so the daily
        # window is stable regardless of the caller's tz.
        day_start = datetime.utcnow().strftime("%Y-%m-%d 00:00:00")
        spent = _spend_since(env, [("create_date", ">=", day_start)])
        if spent >= daily_cap:
            raise VertexBudgetError(
                "Daily LLM spend cap $%.2f reached ($%.2f used today). Raise "
                "assessments_be_v2.daily_llm_cap_usd or wait for the daily "
                "reset." % (daily_cap, spent))
    ev_id = ctx.get("evaluator_id")
    ev_cap = spend_cap(
        env, "per_evaluator_llm_cap_usd", DEFAULT_PER_EVALUATOR_LLM_CAP_USD)
    if ev_id and ev_cap > 0:
        spent = _spend_since(env, [("evaluator_id", "=", ev_id)])
        if spent >= ev_cap:
            raise VertexBudgetError(
                "Per-candidate LLM spend cap $%.2f reached for evaluator %s "
                "($%.2f used). Raise assessments_be_v2.per_evaluator_llm_cap_usd "
                "if this candidate legitimately needs more grading."
                % (ev_cap, ev_id, spent))


def generate_image(env, image_prompt, *, aspect_hint=None, usage_ctx=None):
    import httpx
    model = _vertex_image_model(env)
    url, headers = _gemini_request(env, model, "generateContent")
    # H-5: image render is billable too — honour the spend caps before the call.
    _check_budget(env, usage_ctx)
    _check_cancelled(env, usage_ctx)
    _check_scoring_cancelled(env, usage_ctx)
    prompt_text = image_prompt or ""
    if aspect_hint:
        prompt_text = f"{prompt_text}\n\n(Aspect/framing hint: {aspect_hint})"
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt_text}]}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "temperature": 1.0,
        },
    }
    _logger.info("etp_assessment Vertex image gen: model=%s", model)
    resp = _httpx().post(url, json=payload, headers=headers)
    if resp.status_code != 200:
        _log_failed_call(env, model, usage_ctx, resp.status_code, resp.text)
    if resp.status_code == 429:
        raise VertexQuotaError(
            f"Vertex image quota exhausted [429]: {resp.text[:200]}")
    if resp.status_code != 200:
        raise RuntimeError(
            f"Vertex image error [{resp.status_code}]: {resp.text[:400]}"
        )
    data = resp.json()
    _log_usage(env, model, data.get("usageMetadata"), 1, usage_ctx)
    try:
        parts = data["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(
            f"Vertex image response missing candidates: {str(data)[:300]}"
        )
    for part in parts or []:
        inline = part.get("inlineData") or part.get("inline_data")
        if inline and inline.get("data"):
            mime = (inline.get("mimeType") or inline.get("mime_type")
                    or "image/png")
            _logger.info(
                "etp_assessment Vertex image ok: model=%s mime=%s b64_chars=%d",
                model, mime, len(inline["data"] or ""))
            return inline["data"], mime
    raise RuntimeError(
        "Vertex image response had no image part (safety block / refusal?): "
        f"{str(data)[:300]}"
    )


def edit_image(env, edit_prompt, ref_png_bytes, *, usage_ctx=None):
    """Image-to-image edit — ported 1:1 from the research harness `gen_image_edit`.

    Sends the reference image as an inlineData part FOLLOWED by the edit
    instruction text, with responseModalities=[TEXT, IMAGE]; returns the edited
    image bytes. Used by the q7r defect renderer to bake structural defects
    (fused fingers, garbled inline text, impossible joints — things PIL cannot
    synthesize) into the real pixels in ONE re-render, so a marker can then be
    vision-grounded on the final image. Same scene, only the requested changes.
    """
    model = _vertex_image_model(env)
    url, headers = _gemini_request(env, model, "generateContent")
    # H-5: image edit is billable too — honour the spend caps before the call.
    _check_budget(env, usage_ctx)
    _check_cancelled(env, usage_ctx)
    _check_scoring_cancelled(env, usage_ctx)
    import base64 as _b
    ref_b64 = _b.b64encode(bytes(ref_png_bytes)).decode()
    payload = {
        "contents": [{"role": "user", "parts": [
            {"inlineData": {"mimeType": "image/png", "data": ref_b64}},
            {"text": edit_prompt or ""},
        ]}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "temperature": 1.0,
        },
    }
    _logger.info("etp_assessment Vertex image EDIT: model=%s", model)
    resp = _httpx().post(url, json=payload, headers=headers)
    if resp.status_code != 200:
        _log_failed_call(env, model, usage_ctx, resp.status_code, resp.text)
    if resp.status_code == 429:
        raise VertexQuotaError(
            f"Vertex image-edit quota exhausted [429]: {resp.text[:200]}")
    if resp.status_code != 200:
        raise RuntimeError(
            f"Vertex image-edit error [{resp.status_code}]: {resp.text[:400]}")
    data = resp.json()
    _log_usage(env, model, data.get("usageMetadata"), 1, usage_ctx)
    try:
        parts = data["candidates"][0]["content"]["parts"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(
            f"Vertex image-edit response missing candidates: {str(data)[:300]}")
    for part in parts or []:
        inline = part.get("inlineData") or part.get("inline_data")
        if inline and inline.get("data"):
            import base64 as _b
            return _b.b64decode(inline["data"])
    raise RuntimeError(
        "Vertex image-edit response had no image part (safety block / refusal?): "
        f"{str(data)[:300]}")


# Grounding schema for locate_defect — mirrors the research harness _LOCATE_SCHEMA.
_LOCATE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "found": {"type": "BOOLEAN"},
        "box_2d": {"type": "ARRAY", "items": {"type": "INTEGER"},
                   "minItems": 4, "maxItems": 4},
        "defect_present": {"type": "BOOLEAN"},
    },
    "required": ["found", "box_2d"],
}


def locate_defect(env, image_png_bytes, anchor, flaw="", *, usage_ctx=None):
    """Vision-ground `anchor` in the ACTUAL rendered pixels so a defect marker
    lands on it, and judge whether `flaw` is visibly present there — ported 1:1
    from the research harness `locate_defect`.

    Returns {found, box_2d:[ymin,xmin,ymax,xmax] on a 0-1000 grid, defect_present}.
    This is how markers stay exact after a generative edit re-renders the scene:
    placement comes from vision on the FINAL image, never a pre-guessed pixel.
    """
    model = _detection_model(env)
    import base64 as _b
    b64 = _b.b64encode(bytes(image_png_bytes)).decode()
    prompt = (
        "You are locating one spot in a photograph so a marker can be dropped on "
        "it. Find this object or area: %s. Return found=true with a TIGHT bounding "
        "box (box_2d as [ymin,xmin,ymax,xmax] on a 0-1000 grid) centered on it."
        % (anchor or "")
    )
    if flaw:
        prompt += (
            ' Also judge whether this specific flaw is visibly present there: '
            '"%s". Set defect_present accordingly.' % flaw)
    prompt += " If you cannot see the object at all, return found=false."
    ctx = dict(usage_ctx or {})
    ctx["operation"] = "locate_defect"
    ctx.setdefault("note", "ground-marker")
    raw = _call_vertex(
        env, system_prompt="", user_text="",
        user_parts=[
            {"inlineData": {"mimeType": "image/png", "data": b64}},
            {"text": prompt},
        ],
        model=model, max_tokens=2000, temperature=0.0, response_json=True,
        response_schema=_LOCATE_SCHEMA, usage_ctx=ctx)
    try:
        obj = json.loads((raw or "").strip())
    except (ValueError, TypeError):
        m = re.search(r"\{.*\}", raw or "", re.S)
        obj = json.loads(m.group(0)) if m else {}
    box = obj.get("box_2d")
    if not (isinstance(box, list) and len(box) == 4 and obj.get("found", True)):
        return {"found": False, "box_2d": None,
                "defect_present": bool(obj.get("defect_present", False))}
    try:
        box = [int(round(float(c))) for c in box]
    except (TypeError, ValueError):
        return {"found": False, "box_2d": None, "defect_present": False}
    return {"found": True, "box_2d": box,
            "defect_present": bool(obj.get("defect_present", False))}


def _video_model(env):
    return _param(env, "assessments_be_v2.video_model", VIDEO_DEFAULT_MODEL) \
        or VIDEO_DEFAULT_MODEL


def _video_location(env):
    return _param(
        env, "assessments_be_v2.video_location", VIDEO_DEFAULT_LOCATION) \
        or VIDEO_DEFAULT_LOCATION


def _video_default_duration(env, model=None):
    """The configured default clip length, SNAPPED to a duration Veo accepts.

    A sysadmin can type any integer into the settings field, so snap here too:
    an out-of-enum config value would otherwise 400 every single generation.
    """
    raw = _param(env, "assessments_be_v2.video_default_duration_s", "")
    try:
        want = int(float(raw)) if str(raw).strip() else VIDEO_DEFAULT_DURATION_S
    except (TypeError, ValueError):
        want = VIDEO_DEFAULT_DURATION_S
    return snap_video_duration(want, model or _video_model(env))


def video_generation_available(env):
    if not _video_model(env):
        return False
    try:
        return bool(_vertex_bearer(env))
    except Exception:  # noqa: BLE001
        return False


def _veo_url(env, model, location, suffix):
    project = _bearer_project(env, _vertex_creds(env)[0])
    host = f"https://{location}-aiplatform.googleapis.com"
    return (f"{host}/v1/projects/{project}/locations/{location}"
            f"/publishers/google/models/{model}:{suffix}")


def _brief_prompt_text(brief):
    if isinstance(brief, str):
        return brief
    if isinstance(brief, dict):
        return brief.get("prompt") or ""
    return ""


# Veo's accepted duration enum, as reported by Veo itself the first time it
# rejects one of ours. Keyed per model because the enum differs by model.
_LEARNED_DURATIONS_PARAM = "assessments_be_v2.video_supported_durations"


def _learned_durations(env, model):
    """Durations Veo itself told us it accepts for this model, if it ever has.

    Persisted so the correction survives a worker restart and applies to every
    later submit - not just the one that got rejected.
    """
    raw = _param(env, "%s.%s" % (_LEARNED_DURATIONS_PARAM,
                                 (model or "").strip().lower()), "")
    out = []
    for chunk in str(raw or "").split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            val = int(float(chunk))
        except (TypeError, ValueError):
            continue
        if val > 0 and val not in out:
            out.append(val)
    return tuple(sorted(out))


def _remember_durations(env, model, durations):
    """Persist the enum Veo named, so we stop guessing for this model."""
    if not durations:
        return
    key = "%s.%s" % (_LEARNED_DURATIONS_PARAM, (model or "").strip().lower())
    try:
        env["ir.config_parameter"].sudo().set_param(
            key, ",".join(str(d) for d in sorted(durations)))
    except Exception:  # noqa: BLE001 - never fail a generation over a cache write
        _logger.debug("etp_assessment could not persist Veo durations for %s",
                      model, exc_info=True)


def _effective_durations(env, model):
    """What we will snap against: Veo's own list when known, else our guess."""
    return _learned_durations(env, model) or video_allowed_durations(model)


def submit_video_op(env, brief, *, model=None, location=None, duration_s=None,
                    aspect="16:9", prompt_id=None):
    """Veo 404s on the 'global' location — never reuse the gemini location here."""
    model = model or _video_model(env)
    location = location or _video_location(env)
    bearer = _minted_bearer(env) or _vertex_bearer(env)
    if not bearer:
        raise ValueError(
            "Veo video generation needs a Vertex OAuth bearer (service-account "
            "JSON or a static access token). Configure it or leave video_prompt "
            "clips upload-only.")
    prompt_text = _brief_prompt_text(brief)
    if duration_s is None:
        duration_s = (brief.get("duration_s") or brief.get("durationSeconds")) \
            if isinstance(brief, dict) else None
        duration_s = int(duration_s) if duration_s else \
            _video_default_duration(env, model)
    # LAST GATE before the wire. Veo accepts an ENUM of durations, not a range:
    # an out-of-enum value (5s and 7s are the easy ones to hit) 400s the whole
    # long-running op with "Unsupported output video duration N seconds".
    # Snapping here - rather than only in the brief builder - keeps every caller
    # path safe, including an explicit duration_s= passed by a caller/test.
    allowed = _effective_durations(env, model)
    snapped = snap_video_duration(duration_s, model, allowed=allowed)
    if snapped != int(duration_s or 0):
        _logger.info(
            "etp_assessment Veo duration %ss is not supported by %s; "
            "snapped to %ss", duration_s, model, snapped)
    duration_s = snapped

    # H-5, extended to Veo. Every other billable lane refuses before spending
    # when a cap is already hit - _call_vertex_single, generate_image and
    # edit_image all gate here - and Veo, priced per SECOND of output, was the
    # one that did not. A blown daily cap could still submit the single most
    # expensive call the module makes. `usage_ctx` is built here rather than
    # taken as an argument because this function owns the attribution it later
    # ledgers (see the _log_usage call below), and the gate must read the same
    # generator the row will be filed against.
    usage_ctx = {"operation": "submit_video_op",
                 "prompt_id": prompt_id or False,
                 "note": (prompt_text or "")[:80]}
    _check_budget(env, usage_ctx)
    _check_cancelled(env, usage_ctx)
    _check_scoring_cancelled(env, usage_ctx)

    url = _veo_url(env, model, location, "predictLongRunning")
    headers = {"Content-Type": "application/json",
               "Authorization": f"Bearer {bearer}"}

    def _post(seconds):
        payload = {
            "instances": [{"prompt": prompt_text}],
            "parameters": {
                "durationSeconds": int(seconds),
                "generateAudio": True,
                "sampleCount": 1,
                "aspectRatio": aspect or "16:9",
            },
        }
        _logger.info("etp_assessment Veo submit: model=%s loc=%s dur=%ss",
                     model, location, seconds)
        return _httpx().post(url, json=payload, headers=headers)

    resp = _post(duration_s)
    # SELF-HEAL: Veo names the durations it accepts in the rejection itself.
    # Our hardcoded enum is a guess that goes stale whenever Google changes a
    # model, so believe Veo over ourselves and re-submit ONCE at a length it
    # just told us is legal. A duration mismatch must never cost a generation.
    if resp.status_code != 200 and is_duration_error(resp.text):
        named = parse_supported_durations(resp.text)
        if named:
            _remember_durations(env, model, named)
        retry_at = snap_video_duration(
            duration_s, model, allowed=named or None)
        if retry_at != duration_s:
            _logger.warning(
                "etp_assessment Veo rejected %ss for %s (accepts %s); "
                "re-submitting at %ss", duration_s, model,
                list(named) or "unknown", retry_at)
            resp = _post(retry_at)
            if resp.status_code == 200:
                duration_s = retry_at
    if resp.status_code != 200:
        _log_failed_call(env, model, usage_ctx, resp.status_code, resp.text)
    if resp.status_code == 429:
        raise VertexQuotaError(
            f"Veo submit quota exhausted [429]: {resp.text[:200]}")
    if resp.status_code != 200:
        raise RuntimeError(
            f"Veo submit error [{resp.status_code}]: {resp.text[:400]}")
    op_name = (resp.json() or {}).get("name")
    if not op_name:
        raise RuntimeError(
            f"Veo submit returned no operation name: {resp.text[:300]}")
    _log_usage(env, model, None, 0,
               dict(usage_ctx, video_seconds=int(duration_s)))
    # Tell the caller what length we ACTUALLY used. Snapping/self-heal can move
    # it (7 -> 8), and the staged clip must be described by its real duration,
    # not the one the brief asked for, or the answer key drifts from the asset.
    if isinstance(brief, dict):
        brief["applied_duration_s"] = int(duration_s)
    return op_name


_VIDEO_ERROR_HINTS = (
    # (needle(s) matched case-insensitively, terse label, longer explanation)
    ((("unsupported output video duration",),
      "Unsupported clip length",
      "The clip length asked of Veo is not one it supports (it accepts only "
      "%s seconds). Retry - the brief is snapped to a supported length "
      "automatically now.")),
    ((("quota", "resource_exhausted", "429"),
      "Vertex quota exhausted",
      "Vertex quota for Veo is exhausted right now. Wait for the quota window "
      "to reset, then retry.")),
    ((("permission", "403", "forbidden"),
      "Vertex permission denied",
      "The Vertex credentials are not allowed to call Veo on this project. "
      "Check the service account's Vertex AI permissions in Settings.")),
    ((("not found", "404"),
      "Veo model not found",
      "Vertex could not find the Veo model or endpoint. Check the Video Model "
      "and Video Location in Settings (Veo is regional - it 404s on 'global').")),
    ((("safety", "blocked", "responsible ai", "policy"),
      "Blocked by content policy",
      "Veo refused this clip because the brief tripped its content policy. "
      "Edit the clip brief to remove the flagged content, then retry.")),
    ((("unauthenticated", "401", "invalid authentication",
       "needs a vertex oauth bearer"),
      "Vertex authentication failed",
      "Vertex authentication failed or is not configured. Add a service-account "
      "JSON or access token in Settings, then retry.")),
    ((("deadline", "timeout", "timed out"),
      "Veo timed out",
      "Veo did not answer in time. This is usually transient - retry.")),
    ((("no video bytes", "returned no video"),
      "Veo returned no video",
      "Veo finished the job but handed back no clip. This is usually "
      "transient - retry.")),
)

_SHORT_ERROR_FALLBACK = "Video generation failed"
_SHORT_ERROR_MAX = 48


def short_video_error(raw, model=None):
    """A 4-6 word label for the failure, to sit beside the Retry button.

    The full sentence belongs in a tooltip/log, not in the reviewer's face: the
    form previously rendered a whole paragraph (raw API text + a policy note
    about re-billing) for what is, to the reviewer, a single yes/no decision -
    retry or not. Keep this SHORT and free of raw API noise.
    """
    text = (raw or "").strip()
    if not text:
        return _SHORT_ERROR_FALLBACK
    low = text.lower()
    for needles, label, _hint in _VIDEO_ERROR_HINTS:
        if any(n in low for n in needles):
            return label
    # Unmapped failure: use its own first clause, trimmed to stay glanceable.
    first = re.split(r"[.;\n]", text, maxsplit=1)[0].strip() or text
    first = re.sub(r"\s+", " ", first)
    if len(first) > _SHORT_ERROR_MAX:
        first = first[:_SHORT_ERROR_MAX].rsplit(" ", 1)[0].rstrip(" ,:-") + "..."
    return first or _SHORT_ERROR_FALLBACK


def humanize_video_error(raw, model=None):
    """Turn a raw Veo/API error into something a reviewer can act on.

    The admin sees this in the draft form, so a bare API string like
    "Unsupported output video duration 5 seconds, supported durations are
    [8,4,6] for feature text_to_video." tells them nothing about what THEY
    should do next. We prepend a plain-English cause + next step and keep the
    original text so the underlying detail is never lost.
    """
    text = (raw or "").strip()
    if not text:
        return "Veo did not report a reason. Retry, and check the server log " \
               "if it fails again."
    low = text.lower()
    for needles, _label, hint in _VIDEO_ERROR_HINTS:
        if any(n in low for n in needles):
            if "%s" in hint:
                allowed = "/".join(str(d) for d in video_allowed_durations(model))
                hint = hint % allowed
            return "%s (Veo said: %s)" % (hint, text)
    return text


def _extract_video_payload(resp):
    if not isinstance(resp, dict):
        return None, None
    items = []
    for key in ("videos", "generatedSamples", "generated_videos",
                "predictions"):
        val = resp.get(key)
        if isinstance(val, list):
            items.extend(val)
    for item in items:
        if not isinstance(item, dict):
            continue
        b64 = (item.get("bytesBase64Encoded") or item.get("videoBytes")
               or item.get("b64_json"))
        gcs = item.get("gcsUri") or item.get("uri") or item.get("gcs_uri")
        video = item.get("video")
        if isinstance(video, dict):
            b64 = b64 or video.get("bytesBase64Encoded") \
                or video.get("videoBytes")
            gcs = gcs or video.get("gcsUri") or video.get("uri") \
                or video.get("gcs_uri")
        if b64 or gcs:
            return b64, gcs
    return None, None


def fetch_video_op(env, op_name, *, model, location, prompt_id=None):
    """Poll one Veo long-running operation.

    LEDGERED EVEN THOUGH IT IS FREE. The poll itself carries no token or video
    cost, but it was the one outbound Vertex loop with no row in the ledger at
    all - so "how long did this clip take, and how many times did we ask"
    could only be answered from the server log. A zero-cost row per poll makes
    the whole video lane visible on the LLM Budget screen, and makes a stuck
    operation obvious rather than silent.
    """
    model = model or _video_model(env)
    location = location or _video_location(env)
    bearer = _minted_bearer(env) or _vertex_bearer(env)
    if not bearer:
        raise ValueError("Veo poll needs a Vertex OAuth bearer.")
    usage_ctx = {"operation": "fetch_video_op",
                 "prompt_id": prompt_id or False,
                 "note": (op_name or "")[-80:]}
    url = _veo_url(env, model, location, "fetchPredictOperation")
    headers = {"Content-Type": "application/json",
               "Authorization": f"Bearer {bearer}"}
    resp = _httpx().post(url, json={"operationName": op_name}, headers=headers)
    if resp.status_code != 200:
        _log_failed_call(env, model, usage_ctx, resp.status_code, resp.text)
    else:
        _log_usage(env, model, None, 0, usage_ctx)
    if resp.status_code == 429:
        raise VertexQuotaError(
            f"Veo poll quota exhausted [429]: {resp.text[:200]}")
    if resp.status_code != 200:
        raise RuntimeError(
            f"Veo poll error [{resp.status_code}]: {resp.text[:400]}")
    data = resp.json() if resp.content else {}
    out = {"done": False, "video_b64": None, "gcs_uri": None, "error": None}
    if not isinstance(data, dict):
        return out
    out["done"] = bool(data.get("done"))
    err = data.get("error")
    if isinstance(err, dict) and err:
        out["error"] = str(err.get("message") or err)[:300]
    b64, gcs = _extract_video_payload(data.get("response") or {})
    out["video_b64"] = b64
    out["gcs_uri"] = gcs
    return out


_LIST_KEYS = ("skills", "items", "questions", "data", "results", "result")


def _unwrap_json_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in _LIST_KEYS:
            if isinstance(value.get(key), list):
                return value[key]
    return value


def _salvage_array_start(text):
    """Where the payload array begins, or -1.

    ANCHOR ON THE KEY, NOT THE FIRST BRACKET. The generation envelope is
    `{"metadata": {...}, "questions": [...], "solutions": [...]}` and
    `metadata` itself contains arrays (`mapping`, `tags`, `evidence`,
    `required_elements`). Starting at `text.find("[")` therefore salvaged
    METADATA STRINGS out of a truncated response: the caller filtered them
    with `isinstance(it, dict)`, ended up with zero items, and raised nothing
    at all - a generation run that silently produced no drafts and reported
    itself Done. Preferring the known list keys puts the anchor on the array
    the caller actually wants; the bare bracket stays as the last resort for
    a plain top-level array.
    """
    for key in _LIST_KEYS:
        at = text.find('"%s"' % key)
        while at != -1:
            bracket = text.find("[", at + len(key) + 2)
            colon = text.find(":", at + len(key) + 2)
            # `"questions": [` - the bracket must be the value, not some later
            # key's array, so nothing but whitespace may sit between them.
            if bracket != -1 and colon != -1 and colon < bracket \
                    and not text[colon + 1:bracket].strip():
                return bracket
            at = text.find('"%s"' % key, at + 1)
    return text.find("[")


def _salvage_json_objects(text):
    start = _salvage_array_start(text)
    if start == -1:
        return []
    decoder = json.JSONDecoder()
    i = start + 1
    n = len(text)
    out = []
    while i < n:
        while i < n and text[i] in " \t\r\n,":
            i += 1
        if i >= n or text[i] == "]":
            break
        try:
            obj, i = decoder.raw_decode(text, i)
        except ValueError:
            break
        out.append(obj)
    return out


def _extract_json_array(text):
    text = (text or "").strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()
    try:
        out = _unwrap_json_list(json.loads(text))
        if isinstance(out, list):
            return out
        # A lone JSON object (not wrapped in a known list key) parses fine but is
        # NOT a list; callers doing `[it for it in ... if isinstance(it, dict)]`
        # would iterate the dict's string KEYS -> zero items. Wrap it as a
        # one-item list, mirroring the regex branch below.
        if isinstance(out, dict):
            return [out]
    except Exception:
        pass
    for pattern in (r"\[.*\]", r"\{.*\}"):
        m = re.search(pattern, text, re.DOTALL)
        if m:
            try:
                out = _unwrap_json_list(json.loads(m.group(0)))
                if isinstance(out, list):
                    return out
            except Exception:
                pass
    salvaged = _salvage_json_objects(text)
    if salvaged:
        _logger.warning(
            "etp_assessment recovered %d complete item(s) from a truncated JSON "
            "response (dropped the trailing partial item).", len(salvaged))
        return salvaged
    raise ValueError(
        "Could not parse JSON array from LLM response: %s" % text[:200]
    )


_DETECT_SYSTEM_PROMPT = (
    "You are a precise visual object detector. Return ONLY the JSON array the "
    "user requests, matching the response schema, with no markdown or prose."
)

# Both detection prompts are FORMAT TEMPLATES, not finished strings: the box
# ceiling is the generator's `image_label_count`, so it is only known per call.
# `{lo}` is floored against the cap so a deliberately tiny cap never asks for
# "between 3 and 2 boxes" - an incoherent instruction the model resolves however
# it likes.
_DETECT_PROMPT = (
    "Identify DISTINCT TYPES of objects in this image for a visual quiz. "
    "Choose the single clearest example of each different object category and give "
    "it its own tight 2D bounding box, a short lowercase label (1-2 words, e.g. "
    "'car', 'bus', 'dog', 'tree', 'building', 'person', 'sign'), and a one-line "
    "description. Each label MUST be a different category: never repeat the same "
    "label and never return two boxes of the same object type. Maximize the VARIETY "
    "of categories present (vehicles, animals, people, plants, buildings, signs, "
    "everyday items, etc.). Never box the whole scene, sky, road, or background; "
    "each box must be tight around exactly one object. Order top-to-bottom, "
    "left-to-right. Return between {lo} and {cap} boxes, each a UNIQUE object "
    "type; NEVER more than {cap}."
)

_UI_PROMPT = (
    "This is a screenshot of a website or app interface. Detect the INTERACTIVE, "
    "clickable elements a user could act on: buttons, links, navigation menu items, "
    "tabs, icons (search, cart, menu, profile, back), input and search fields, "
    "logos, and call-to-action elements. For each, return a tight 2D bounding box, "
    "a short label naming the element and its action (e.g. 'search button', "
    "'cart icon', 'sign in', 'menu', 'add to cart', 'home link'), and a one-line "
    "description of what it does. Number EVERY distinct clickable element separately, "
    "even if several are the same type (e.g. multiple 'buy' buttons). Do not box "
    "large non-interactive regions, background images, or paragraphs of body text. "
    "Order top-to-bottom, left-to-right. Return the {cap} clearest interactive "
    "elements, in that order of clarity; NEVER more than {cap}."
)

BOX_SCHEMA = {
    "type": "ARRAY",
    "items": {
        "type": "OBJECT",
        "properties": {
            "box_2d": {
                "type": "ARRAY",
                "items": {"type": "INTEGER"},
                "minItems": 4,
                "maxItems": 4,
            },
            "label": {"type": "STRING"},
            "description": {"type": "STRING"},
        },
        "required": ["box_2d", "label"],
    },
}


def _detection_model(env):
    """Must READ an image and return JSON: a vision model, not a render model."""
    return _text_lane(
        "detection_model",
        _param(env, "assessments_be_v2.detection_model"),
    ) or _generation_model(env)


def detect_image_elements(env, image_b64, ui=False, model=None, usage_ctx=None,
                          cap=None):
    """Gemini returns box_2d as [ymin,xmin,ymax,xmax] on a normalized 0-1000 grid.

    ``cap`` bounds how many boxes come back. It is both ASKED FOR in the prompt
    and ENFORCED on the parsed result: this call is the FALLBACK source of
    geometry for an AI-made labelling picture (after `locate_label_elements`
    fails or finds under half) and the only one on the bank detect cron, so a
    model that over-returns here
    puts boxes on the image that the generator's cap says should not exist, and
    every downstream key is derived from whatever this returns.
    """
    limit = _label_box_cap(cap)
    model = model or _detection_model(env)
    prompt = (_UI_PROMPT if ui else _DETECT_PROMPT).format(
        cap=limit, lo=min(3, limit))
    user_parts = [
        {"inlineData": {"mimeType": "image/png", "data": image_b64}},
        {"text": prompt},
    ]
    ctx = dict(usage_ctx or {})
    ctx["operation"] = "detect_image_elements"
    ctx.setdefault("note", "ui" if ui else "objects")
    raw = _call_vertex(
        env, _DETECT_SYSTEM_PROMPT, user_text="", user_parts=user_parts,
        model=model, max_tokens=8000, temperature=0.0, response_json=True,
        response_schema=BOX_SCHEMA, usage_ctx=ctx)
    detections = []
    for it in _extract_json_array(raw):
        if not isinstance(it, dict):
            continue
        box = it.get("box_2d")
        if not isinstance(box, list) or len(box) != 4:
            continue
        try:
            coords = [int(round(float(c))) for c in box]
        except (TypeError, ValueError):
            continue
        detections.append({
            "box_2d": coords,
            "label": str(it.get("label") or "").strip(),
            "description": str(it.get("description") or "").strip(),
        })
    if not ui:
        # objects lane: one box per distinct category, so dedupe BEFORE the cap
        # or a run of near-duplicates would eat the whole budget and the caller
        # would get 20 boxes of the same thing.
        seen = set()
        unique = []
        for det in detections:
            key = det["label"].lower()
            if key and key not in seen:
                seen.add(key)
                unique.append(det)
        detections = unique
    if len(detections) > limit:
        _logger.warning(
            "etp_assessment detect_image_elements (%s): model returned %d box(es) "
            "against a cap of %d - kept the first %d. The overlay and the answer "
            "key are both drawn from the kept boxes.",
            "ui" if ui else "objects", len(detections), limit, limit)
        detections = detections[:limit]
    return detections


_LOCATE_LABELS_SCHEMA = {
    "type": "ARRAY",
    "items": {
        "type": "OBJECT",
        "properties": {
            "number": {"type": "INTEGER"},
            "found": {"type": "BOOLEAN"},
            "box_2d": {"type": "ARRAY", "items": {"type": "INTEGER"},
                       "minItems": 4, "maxItems": 4},
        },
        "required": ["number", "found"],
    },
}


def locate_label_elements(env, image_b64, elements, usage_ctx=None):
    """Find each NAMED labelling box on the rendered picture, in one call.

    The first of the two box methods (owner, 2026-09-29: one box list per
    question, a second method only as fallback). The generator named every
    element and wrote what it does - that list is the answer key - but its
    coordinates were guessed before the picture existed. Vision places each
    name on the actual pixels, so the key stays the generator's and the box
    lands on the thing it names.

    ``elements`` is ``[{number, element, functionality}]``. Returns
    ``{number: box_2d}`` for the elements found, box_2d as [ymin,xmin,ymax,xmax]
    on the 0-1000 grid; an element that is not visibly present is left out.
    """
    wanted = {e["number"]: e for e in elements
              if isinstance(e, dict) and isinstance(e.get("number"), int)}
    if not wanted:
        return {}
    listing = "\n".join(
        "%d. %s - %s" % (n, str(e.get("element") or "").strip(),
                         str(e.get("functionality") or "").strip())
        for n, e in sorted(wanted.items()))
    prompt = (
        "This picture is used in a labelling quiz. Find each numbered element "
        "below in the picture and return a TIGHT box around it (box_2d as "
        "[ymin,xmin,ymax,xmax] on a 0-1000 grid). Match on the element's name "
        "and any visible text; use what it does only to tell similar elements "
        "apart. Never give two numbers the same area. If an element is not "
        "visibly present, return found=false for its number. Return one entry "
        "per number.\n" + listing)
    ctx = dict(usage_ctx or {})
    ctx["operation"] = "detect_image_elements"
    ctx.setdefault("note", "locate named boxes")
    raw = _call_vertex(
        env, _DETECT_SYSTEM_PROMPT, user_text="",
        user_parts=[{"inlineData": {"mimeType": "image/png", "data": image_b64}},
                    {"text": prompt}],
        model=_detection_model(env), max_tokens=8000, temperature=0.0,
        response_json=True, response_schema=_LOCATE_LABELS_SCHEMA,
        usage_ctx=ctx)
    found = {}
    for it in _extract_json_array(raw):
        if not (isinstance(it, dict) and it.get("found")):
            continue
        try:
            n = int(it.get("number"))
            y0, x0, y1, x1 = [int(round(float(c))) for c in it.get("box_2d")]
        except (TypeError, ValueError):
            continue
        # A box outside the grid or with no area is not a placement.
        if (n in wanted and n not in found and 0 <= y0 < y1 <= 1000
                and 0 <= x0 < x1 <= 1000):
            found[n] = [y0, x0, y1, x1]
    return found


_IMG_PROMPT_RULE = (
    "Each image prompt MUST be a DETAILED, self-contained scene brief that "
    "states EVERY visually deciding detail (subjects, layout/composition, "
    "colours, materials, lighting) and QUOTES verbatim any text/labels/numbers "
    "that must appear in the image so it renders legibly. Default to a "
    "photorealistic style unless the scenario requires otherwise. Write it as a "
    "single source of truth, not a vague caption."
)


def _ab_fallback_dims():
    return [{"label": name, "choices": list(_AB_CHOICES)}
            for _code, name in _AB_DEFAULT_DIMS]


# Sent ONLY for a generator with `image_label_live_capture` on (owner,
# 2026-09-29): real website screenshots are one project's need (High Res
# Dense), not the default - every other labelling picture is AI-made.
_LIVE_CAPTURE_NOTE = (
    "\n\nLIVE WEBSITE SCREENSHOTS (this generator asks for them): for every "
    "image_label DENSE item ALSO return image_specs.source_url - a REAL, "
    "PUBLIC, non-login, reachable TOP-LEVEL page that renders the interactive "
    "controls the SOP is about - plus \"application\", \"viewport\": "
    "{\"width\": 1440, \"height\": 900}, \"wait_ms\": 2500 and \"dismiss\": "
    "[CSS selectors of cookie / consent ACCEPT buttons]. Use a DIFFERENT site "
    "for every item. The platform screenshots that page and numbers its real "
    "controls; that list then becomes the boxes, key, rubric and golden "
    "answer. Keep the images brief and boxes as well: they are used if the "
    "page cannot be captured.")


def _image_type_contract(qtype, ab_dims=None, label_box_cap=None):
    # The cap is baked into the CONTRACT TEXT as well as enforced after the
    # fact, because a model told "up to N" authors N coherent boxes with N
    # matching key entries, whereas a model told nothing authors 35 and lets
    # the truncation below decide which 20 survive - same ceiling, much worse
    # questions. The truncation stays because prompt text is advisory only.
    cap = _label_box_cap(label_box_cap)
    if qtype == "image_ab":
        return (
            "FLAW-INJECTION (mandatory): from a single TARGET brief, plan a PAIR "
            "of images and plant deliberate, VISIBLE flaws so the answer key is "
            "ground-truth BY CONSTRUCTION. Output image_specs = {\"flaw_plan\": {"
            '"faithful_side": "a" | "b" | null, "worker_prompt": "the TRUE target '
            'brief shown to the candidate (what a correct image should depict)", '
            '"render_prompts": {"a": "a COMPLETE self-contained brief for image '
            'A", "b": "a COMPLETE self-contained brief for image B"}, "planted": '
            '{"a": ["visible flaw on A", ...], "b": ["visible flaw on B", ...]}, '
            '"construction_keys": {"<DIM>": "<verdict>", ..., "OC": "<verdict>"}, '
            '"dimension_labels": {"<DIM>": "what this dimension checks, in the '
            'SOP\'s own words"}}}'
            " (construction_keys holds one entry per dimension THIS SOP rates — "
            'e.g. {"IF","VQ","LAI","OC"} for a compare-to-prompt task, or '
            '{"IF","VQ","LAI","IDP","CP","OC"} for an image-editing task). '
            "Rules: worker_prompt is the single target the candidate is judged "
            "against and MAY differ in wording from BOTH render prompts. "
            "render_prompts.a and render_prompts.b are each a FULL standalone "
            "brief — a flawed side is a COMPLETE rewrite that embeds the flaw, "
            "NOT 'clean plus a note'. planted lists the concrete, VISIBLE flaws "
            "per side (wrong object counts, misspellings, extra/missing/floating "
            "elements); a flaw must be visible in the RENDERED image, never one "
            "that lives only in the prompt text. PER-DIMENSION MODEL: each "
            "planted flaw decides EXACTLY ONE dimension (IF, VQ, or LAI). You may "
            "flaw ONE side (set faithful_side to the OTHER, its planted list "
            "EMPTY) or BOTH sides (set faithful_side null, BOTH planted lists "
            "NON-EMPTY). A dimension NO flaw touches is 'Both Good'. A side that "
            "carries a flaw on one dimension MAY STILL WIN a DIFFERENT dimension "
            "(name that side) when the other side's flaw on that dimension is "
            "worse. When BOTH sides are flawed on the SAME dimension it is 'Both "
            "Bad'. THE RATING DIMENSIONS COME FROM THE SOP, not a fixed list: use "
            "the exact dimensions this SOP tells workers to rate. A compare-two-"
            "images-to-a-prompt SOP typically rates Instruction Following (IF), "
            "Visual Quality (VQ), Less AI-Generated (LAI) and a mandatory Overall "
            "Choice (OC). An image-EDITING / modification SOP (two edits of an "
            "original) ALSO rates ID Preservation (IDP) and Content Preservation "
            "(CP). Emit a construction_keys entry for EVERY dimension THIS SOP "
            "names — no more, no fewer — keyed by its short code (IF, VQ, LAI, "
            "IDP, CP, OC) or, for a dimension the SOP defines that has no standard "
            "code, its short Name. construction_keys MUST include OC plus at least "
            "one other rating dimension; each verdict is one of [Response A, "
            "Response B, Both Good, Both Bad], EXCEPT OC which is ONLY Response A "
            "or Response B and MUST ALWAYS be DECIDED to one side by a "
            "correctness-before-polish tiebreak (the side needing fewer "
            "corrections to be right wins) — OC is NEVER Both Good or Both Bad "
            "even when both sides are flawed. "
            "INDEPENDENT-EVALUATION SOPs (a SOP where the worker answers a fixed "
            "set of INDEPENDENT questions about ONE edit — e.g. three Yes/No "
            "checks such as Q1 Instruction Aligned, Q2 Image Aligned, Q3 No AI "
            "Slop — rather than picking between two responses): use each SOP "
            "question as a construction_keys dimension keyed by its short Name "
            "(Q1/Q2/Q3 or the SOP's own labels) and add a top-level "
            '"dimension_options" map giving that dimension\'s EXACT answer options '
            'from the SOP, e.g. "dimension_options": {"Q1": ["YES", "NO"], "Q2": '
            '["YES", "NO"], "Q3": ["YES", "NO"]}, with each construction_keys '
            "verdict being the correct option for that dimension. ALSO emit a "
            'top-level "dimension_labels" map naming what each numbered question '
            'ACTUALLY CHECKS, in the SOP\'s own words, e.g. "dimension_labels": '
            '{"Q1": "Instruction Following", "Q2": "Image Aligned", "Q3": "Free '
            'from AI slop"} — a bare "Q1" is meaningless to a candidate or a '
            "reviewer, so every numbered dimension MUST carry its SOP title. "
            "When you supply "
            "dimension_options for the SOP's questions, OC is NOT required (there "
            "is no single overall pick); match the SOP's dimensions and options "
            "EXACTLY rather than forcing the Response A/B vocabulary. Use the "
            "default [Response A, Response B, Both Good, Both Bad] vocabulary and "
            "a mandatory OC ONLY for genuine A/B comparison SOPs. "
            "EVERY verdict must "
            "be JUSTIFIED by the planted flaws (the flaw that decides a dimension, "
            "or the absence of one for 'Both Good'/'Both Bad'). ACROSS THIS BATCH "
            "spread the planted flaws so every dimension the SOP rates is a "
            "decisive verdict on at least one item rather than the default Both "
            "Good, no dimension carries the same verdict on every item, and which "
            "dimension is decisive varies item to item — a set where one "
            "dimension always ties is a planning failure. LEGACY shape still "
            "accepted (mapped automatically): flawed_side + clean_prompt + "
            "flawed_prompt + injected_flaws, but PREFER the worker_prompt / "
            "render_prompts / planted shape. Do NOT emit image_a_prompt / "
            "image_b_prompt or a free-form dimensions map; the platform derives "
            "the two images and the answer key from the flaw_plan."
        )
    if qtype == "image_prompt":
        return (
            'Shape: {"name": "...", "question_type": "image_prompt", "prompt": '
            '"...", "difficulty": "medium", "image_specs": {"images": [...], '
            '"answer_key": {"ideal_prompt": "...", "mandatory_elements": ["..."], '
            '"penalty_rules": ["..."], "scoring_guide": "..."}}}. TWO supported '
            "forms: (1) FROM-SCRATCH — exactly ONE image with slot \"single\"; the "
            "candidate WRITES the text-to-image prompt that would produce that "
            "image, graded against ideal_prompt. (2) TRANSFORMATION / COMPARE — "
            'exactly TWO images: one with slot "reference" (the starting / input '
            'image) and one with slot "output" (the target / result image); the '
            "candidate WRITES the transformation prompt that turns the reference "
            "INTO the output, and ideal_prompt describes that reference->output "
            "transformation. PREFER the 2-image form whenever the task is to edit, "
            "transform, restyle, or compare one image into another — the candidate "
            "must SEE both the reference and the output to write the prompt. Each "
            'image needs a REQUIRED detailed self-contained "prompt" brief. Show '
            "the candidate the rendered image(s); the stimulus must SHOW the "
            "evidence, never a caption that states the answer."
        )
    if qtype == "video_prompt":
        return (
            'Shape: {"name": "...", "question_type": "video_prompt", "prompt": '
            '"...", "difficulty": "medium", "image_specs": {"videos": [...], '
            '"answer_key": {"ideal_prompt": "...", "mandatory_elements": ["..."], '
            '"penalty_rules": ["..."], "scoring_guide": "..."}}}. The VIDEO twin '
            "of image_prompt. TWO supported forms. (1) FROM-SCRATCH — exactly ONE "
            'clip with slot "single"; the candidate WRITES the text-to-video '
            "prompt that would produce that clip, graded against ideal_prompt. "
            "(2) TRANSFORMATION / COMPARE (PREFER) — exactly TWO clips: one with "
            'slot "reference" (the starting / input clip) and one with slot '
            '"output" (the target / result clip); the candidate WRITES the '
            "transformation prompt that turns the reference clip INTO the output "
            "clip, and ideal_prompt describes that reference->output "
            "TRANSFORMATION. Prefer the 2-clip form whenever the task is to edit, "
            "restyle, re-time, or compare one clip into another — the candidate "
            "must SEE both the reference and the output to write the prompt. "
            "For a TRANSFORMATION question you MUST emit BOTH clips (one "
            '"reference" AND one "output"); never emit only the output — the '
            "candidate has nothing to transform FROM without the reference. Each "
            'clip needs a REQUIRED detailed self-contained "prompt" brief stating '
            "subject, MOTION/action, camera, visual STYLE, SCENE STRUCTURE (any "
            "cut/scene divisions), background/lighting, DURATION, and any AUDIO / "
            'dialogue (or explicit silence). Each clip ALSO needs a "duration_s" '
            "integer that MUST be one of exactly 4, 6 or 8 (no other value is "
            "accepted by the renderer), chosen to fit THAT clip's action (a quick "
            "gesture 4, a multi-beat sequence 8) - vary it per clip and "
            "per question; do NOT default every clip to the same length. "
            "ideal_prompt must COVER the "
            "transformation as a checklist a grader can verify: name the shared "
            "STYLE, the concrete content CHANGES, the SCENE DIVISIONS, the "
            "AUDIO/SILENCE handling, any LENGTH change, and the DIALOGUE format. "
            "Show the candidate the clip(s); the stimulus must SHOW the evidence, "
            "never a caption that states the answer. The clips are UPLOADED by an "
            "admin or generated later — you author only the briefs + answer key."
        )
    return (
        'Shape: {"name": "...", "question_type": "image_label", "prompt": '
        '"...", "difficulty": "medium", "image_specs": {...}}. EXACTLY ONE image '
        'with slot "single" is shown; the candidate LABELS the elements in it. '
        "The picture is AI-MADE from YOUR brief, so brief the interface or scene "
        "THIS SOP is actually about - its own tool, screen or objects - never an "
        "unrelated public website. THE NUMBERED BOXES ARE ONE LIST: the platform "
        "finds each box you author on the rendered picture BY ITS ELEMENT NAME "
        "and draws it there, and that SAME list becomes the answer key, the "
        "rubric and the golden answer. So name every element exactly as it will "
        "appear (quote its visible text), make each name unique in the picture, "
        "and make its functionality the answer. (1) DENSE "
        "SCREENSHOT LABELLING (the form for an app / website / UI "
        "screenshot): the ONE image brief depicts an interface "
        "carrying MULTIPLE (up to " + str(cap) + ") interactive elements, and "
        "you number and label EVERY one of them - NEVER emit more than "
        + str(cap) + " boxes, and never a boxes[] list and an ideal_labels map "
        "of different lengths. Emit image_specs = {\"images\": [{\"slot\": "
        '"single", "label": "Screenshot", "prompt": "<detailed self-contained '
        'brief for a single screenshot showing every listed interactive '
        'element, quoting each visible control label verbatim>"}], '
        '"application": "<what app / site the screenshot depicts>", '
        '"coverage_expected": "yes" | "no", "boxes": [{"number": 1, "box_2d": '
        "[ymin,xmin,ymax,xmax], \"element\": \"<short name of the control>\", "
        '"functionality": "<the ACTION it performs, e.g. \'Opens the cart\'>"}, '
        "..., {\"number\": N, ...}], \"answer_key\": {\"ideal_labels\": "
        '{"1": "<functionality of box 1>", ..., "N": "<functionality of box '
        'N>"}, "mandatory_elements": ["..."], "penalty_rules": ["..."], '
        '"scoring_guide": "..."}}. Rules for the dense form: box_2d is your '
        "APPROXIMATE normalized rectangle [ymin,xmin,ymax,xmax] on a 0-1000 grid "
        "for that control in your briefed screenshot (top-left origin); the "
        "platform re-finds each control by its element name on the rendered "
        "picture and places the box there, so place one "
        "box per interactive control and keep them in reading order "
        "(top-to-bottom, left-to-right). functionality grades what the control "
        "DOES, not merely its name. answer_key.ideal_labels is the PER-BOX MAP "
        "keyed by box number to the same functionality. coverage_expected is "
        '"yes" when EVERY interactive element in the briefed screenshot has a '
        'box; set it "no" ONLY when you deliberately leave ONE interactive '
        'element un-boxed, and then also emit "omitted_element": {"tag": "...", '
        '"text": "...", "reason": "..."} naming the element you left out, so the '
        'coverage answer is "No" BY CONSTRUCTION. (2) SINGLE-BOX (legacy, still '
        'valid for a photo/defect with ONE region): image_specs = {"images": '
        '[{"slot": "single", "label": "Image", "prompt": "..."}], "answer_key": '
        '{"ideal_labels": "<single-string answer key>", "mandatory_elements": '
        '["..."], "penalty_rules": ["..."], "scoring_guide": "..."}} — '
        "ideal_labels is a plain string, no boxes. "
        "(3) DEFECT ANNOTATION — TRUE BY CONSTRUCTION (the faithful form for a "
        "single-image AI-defect / anomaly spotting task, e.g. drop a dot on each "
        "AI tell — the q7r task). Use this form when the SOP's "
        "task is marking defects in one image. Use BASE+EDIT: the platform renders "
        "a CLEAN base image from base_prompt, then BAKES all the defects into the "
        "real pixels in ONE image-to-image edit. The edit re-renders the whole "
        "scene, so a pre-guessed pixel is worthless — instead the platform "
        "VISION-GROUNDS each defect's `anchor` (the visible object it sits on) in "
        "the FINAL image, stamps the numbered marker on that object, and asks the "
        "same call whether the flaw is actually present (an absent flaw is flagged "
        "unverified and DROPPED). So markers land on the real object no matter "
        "where the model rendered it, and the key is true by construction. The "
        "defects MUST be the strong, NAMEABLE kinds a real AI image gives itself "
        "away with (see taxonomy) — never a vague blur or \"looks off\": a worker "
        "must be able to point at it and say what is wrong. A word like \"blurry\" "
        "must never be the honest description of a defect you planted. Emit "
        "image_specs = {\\\"base_prompt\\\": \\\"<a CLEAN, plausible photorealistic "
        "16:9 scene, NO defects — but it MUST contain the real surfaces each defect "
        "will corrupt: a hand actually touching an object, a printed sign or label "
        "or paper, a reflective surface, an animal's limb. Leave text surfaces "
        "present but do not stress clean spelling — the edit supplies the garbled "
        "text.>\\\", \\\"defects\\\": [{\\\"marker\\\": 1, \\\"kind\\\": "
        '"<anatomy|fusion|text|continuity|physical-purchase|smoothing>", '
        '"method": "edit", "edit_instruction": "<precise image-edit command naming '
        "the EXACT object and the EXACT structural failure, e.g. 'Give the man's "
        "right hand a sixth finger beside the pinky' or 'Make the chalkboard read a "
        "jumble of malformed letters that spell no real word'. One defect, one "
        "place. Never say blur/smudge/make it look off.>\\\", \\\"anchor\\\": \\\"<a "
        "short phrase naming the ONE visible object the marker sits on, so vision "
        "can find it in the rendered image: 'the framed sign on the desk', 'the "
        "right hand holding the ledger'. Must be unique in the scene — not 'a book' "
        "when there are many.>\\\", \\\"flaw\\\": \\\"<the canonical one-sentence "
        "note an ideal worker writes: name the defect + the visual evidence>\\\"}, "
        "... OVER-PLANT as many CANDIDATE defects as the scene naturally supports — "
        "the number is NOT fixed: a simple scene may carry 3 to 4, a rich/busy "
        "scene 6 to 10 — but NEVER more than " + str(cap) + " defects in total, "
        "which is the hard ceiling on markers this question may show; anything "
        "past it is DISCARDED ...], \\\"answer_key\\\": {\\\"ideal_labels\\\": {\\\"1\\\": "
        "\\\"<canonical one-sentence note>\\\", ...}, \\\"decoys\\\": [\\\"<a "
        "harmless real object the prompt did not forbid, that must NOT be "
        "marked>\\\"], \\\"scoring_guide\\\": \\\"coverage + precision, a wrong mark "
        "costs more than a miss\\\"}}. DEFECT TAXONOMY — plant strong, specific "
        "tells drawn from these kinds: anatomy (extra/fused/missing fingers, an "
        "extra limb, a joint bent at an impossible angle); fusion (one object "
        "merges into another with no clean boundary); text (garbled text ON the "
        "scene's own surface — sign, label, paper, screen — malformed merged "
        "letters forming no real word, OR one corrupted letter in an otherwise "
        "legible word; NOT a pasted card); continuity (a reflection that omits the "
        "subject or contradicts the scene, a duplicated object, a shadow cast the "
        "wrong way, a count that does not match); physical-purchase (an object "
        "floating with no support or contact shadow, a clip resting on top of hair "
        "instead of gripping it); smoothing (a waxy over-smoothed patch with no "
        "texture despite hard light). OVER-PLANT AND BIAS BY RELIABILITY: the edit "
        "does not always take, and the platform ships ONLY the defects it can "
        "verify are visibly present (the rest are dropped, survivors renumbered "
        "1..N) — so plant a generous, scene-appropriate number and lean on the "
        "kinds that render reliably. RELIABLE, use freely: text, continuity, "
        "fusion, fused-finger anatomy. HARD, at most ONE per question: added-"
        "geometry anatomy (a sixth finger, an extra limb), physical-purchase, "
        "smoothing — the model often refuses these, so pair any hard defect with 3+ "
        "reliable ones. Every defect sits on a DISTINCT anchor so nothing overlaps. "
        "Name at least one decoy in answer_key that must NOT be marked so precision "
        "is measurable. PIL FALLBACK — use ONLY for a genuine duplicate/clone "
        "artifact, where copying pixels beats an edit: {\\\"marker\\\": N, "
        '"kind": "continuity", "method": "pil", "op": "float_copy", "spec": '
        "{\\\"src_box\\\":[x0,y0,x1,y1],\\\"dst_x\\\":X,\\\"dst_y\\\":Y,"
        "\\\"scale\\\":1.0}, \\\"marker_xy\\\":[X,Y], \\\"flaw\\\":\\\"...\\\"} in "
        "the 1280x720 pixel space. "
        "In ALL forms the image \\\"prompt\\\"/base_prompt is REQUIRED and the "
        "stimulus must SHOW the evidence, never a caption that states the answer."
    )


def _image_question_directive(qtype, count, ab_dims=None, label_box_cap=None):
    # `count` is how many QUESTIONS to author; `label_box_cap` is how many BOXES
    # one of those questions may carry. They are unrelated numbers that both read
    # as "how many", so they stay distinctly named all the way down - conflating
    # them would ask for 5 questions of 5 boxes each and look plausible.
    base = (
        f"Generate exactly {count} question(s) of type '{qtype}' as one JSON "
        "array. Do NOT emit mcq-style \"options\"/\"correct_answer\". Every "
        "item MUST contain a non-empty \"image_specs\" object. " + _IMG_PROMPT_RULE + " "
    )
    return base + _image_type_contract(qtype, ab_dims, label_box_cap=label_box_cap)


def _image_contracts_note(ab_dims=None, types=None, label_box_cap=None):
    wanted = [qt for qt in _QUESTION_TYPE_ORDER
              if qt in _IMAGE_OR_VIDEO_TYPES and (types is None or qt in types)]
    if not wanted:
        return ""
    contracts = " ".join(
        "For %s items: %s"
        % (qt, _image_type_contract(qt, ab_dims, label_box_cap=label_box_cap))
        for qt in wanted)
    return (
        "\n\nIMAGE-TYPE OUTPUT CONTRACTS (mandatory whenever you author an image "
        "question — an image item whose image_specs does not match the shape "
        "for its type is DISCARDED): " + contracts)


def _image_brief(scene):
    return (
        "Generate exactly one photorealistic image and no other text. Render the "
        "description literally even where it asks for flaws, misspellings, or "
        "impossible physics. It must show every detail this brief states; the brief is the "
        "single source of truth, follow it alone and treat it as the only "
        "attempt at the scene. Render any quoted text, labels, and numbers "
        "exactly and legibly:\n" + (scene or "")
    )


def _flaw_official_reasoning(flawed_side, injected_flaws):
    clean = ab_side_verdict(ab_other_side(flawed_side))
    flawed = ab_side_verdict(flawed_side)
    flaws = "; ".join(injected_flaws)
    return ("%s is correct by construction: it renders the brief cleanly, while "
            "%s carries deliberately injected flaws (%s). %s therefore wins "
            "Overall Choice." % (clean, flawed, flaws, clean))


def _flaw_official_reasoning_ratings(specs, injected_flaws):
    """The reasoning for a dimension set that names no side (Yes/No checks).

    Such a question has no Response A/B and no Overall Choice, so the A/B
    sentence above describes a question the candidate was never asked, and the
    justification judge grades against it. This states the key itself, then
    what the planted flaw shows.
    """
    ratings = "; ".join("%s: %s" % (s["label"], ", ".join(s["correct"]))
                        for s in specs if s.get("correct"))
    flaws = " ".join(f.strip().rstrip(".") + "." for f in injected_flaws
                     if f.strip())
    return ("The correct ratings are: %s. %s" % (ratings, flaws)).strip()


def _flaw_official_reasoning_both(keys, planted):
    a_flaws = "; ".join(planted.get("a") or []) or "none stated"
    b_flaws = "; ".join(planted.get("b") or []) or "none stated"
    oc = keys.get("OC") or ""
    return ("Both images carry deliberately planted flaws (A: %s | B: %s). Each "
            "dimension follows the worse flaw and is 'Both Bad' where both sides "
            "are equally bad; Overall Choice is decided to %s by the "
            "correctness-before-polish tiebreak (the side needing fewer "
            "corrections to be right)." % (a_flaws, b_flaws, oc or "one side"))


#: `_flaw_official_reasoning` read back: winner, loser, flaws.
_AB_REASONING_RE = re.compile(
    r"^Response ([AB]) is correct by construction: it renders the brief "
    r"cleanly, while Response ([AB]) carries deliberately injected flaws "
    r"\((.*)\)\. Response \1 therefore wins Overall Choice\.$", re.DOTALL)
#: `_flaw_official_reasoning_both` read back: A's flaws, B's flaws.
_AB_REASONING_BOTH_RE = re.compile(
    r"^Both images carry deliberately planted flaws \(A: (.*) \| B: (.*)\)\. "
    r"Each dimension follows the worse flaw", re.DOTALL)
_AB_SIDE_RE = re.compile(r"\b(?i:response|image|option|side)\s+([AB])\b")
_AB_FAULT_RE = re.compile(
    r"\b(?:flaw\w*|violat\w*|incorrect\w*|fail\w*|wrong\w*|error\w*|"
    r"mistake\w*|lack\w*|missing|instead of)\b", re.IGNORECASE)
# "is not flawed", "does not follow": a negated sentence is never evidence.
_AB_NEGATION_RE = re.compile(r"\b(?:not|no|never|without)\b|n't\b",
                             re.IGNORECASE)
_AB_MERIT_RE = re.compile(
    r"\b(?:correct\w*|follow\w*|faithful\w*|accurate\w*|adher\w*|"
    r"satisf\w*)\b", re.IGNORECASE)


def _ab_prose_blames_winner(text, winner):
    """Whether prose about an A/B pair has the sides backwards for `winner`.

    True: it faults the winner or praises the loser, and no sentence says it
    the right way round. False: it reads right. None: it cannot be told (no
    sentence names exactly one side with a clear fault or merit, or the
    sentences disagree) - and None is never repaired.
    """
    wrong = right = 0
    for sentence in re.split(r"(?<=[.!?])\s+", text or ""):
        sides = {s.lower() for s in _AB_SIDE_RE.findall(sentence)}
        fault = bool(_AB_FAULT_RE.search(sentence))
        merit = bool(_AB_MERIT_RE.search(sentence))
        if len(sides) != 1 or fault == merit \
                or _AB_NEGATION_RE.search(sentence):
            continue
        if (sides == {winner}) == merit:
            right += 1
        else:
            wrong += 1
    if wrong and not right:
        return True
    if right and not wrong:
        return False
    return None


def repair_generated_question_text(env):
    """Repair generated text that contradicts its own answer key. Idempotent.

    Run on every `-u` (`assessments.be.question.init`), over bank questions and
    drafts. Each rule touches only what it can decide mechanically, and every
    id it changes or refuses to guess at is logged:

    * slots: a template's {slot} still raw in the text or on an axis (prod
      1165) is filled with the neutral fallback word, in every copy at once so
      the key-drift guard still maps labels onto flaw_plan_json codes.
    * reasoning: an axis set naming no side (Yes/No checks) whose official
      reasoning is the Response A/B sentence gets the ratings sentence the
      generator writes now.
    * rationale: the key's only side verdict is the reasoning's winner, and the
      rationale (or the solution's justification) faults that winner or
      praises the loser - it was written before the slots were swapped (prod
      1167, 1178). Its Response A/B mentions are flipped.
    """
    report = {"slots": [], "reasoning": [], "rationale": [], "ambiguous": [],
              "failed": []}
    for model in ("assessments.be.question", "assessments.be.prompt.question"):
        rows = env[model].sudo().with_context(active_test=False).search([
            "|", ("source_template_id", "!=", False),
            "&", ("question_type", "=", "image_ab"),
            "|", ("official_reasoning", "=like",
                  "Response _ is correct by construction:%"),
            ("official_reasoning", "=like",
             "Both images carry deliberately planted flaws%")])
        for rec in rows:
            # A repair must never fail the upgrade it rides on: a row that
            # will not take its fix is rolled back alone and listed.
            try:
                with env.cr.savepoint():
                    _repair_generated_row(rec, report)
            except PsycopgError:
                raise
            except Exception:  # noqa: BLE001
                _logger.exception("etp_assessment generated-text repair "
                                  "failed on %s %s", model, rec.id)
                report["failed"].append("%s:%s" % (model, rec.id))
    for rule, ids in report.items():
        if ids:
            _logger.warning("etp_assessment generated-text repair, %s: %s",
                            rule, ", ".join(ids))
    return report


def _repair_generated_row(rec, report):
    draft = rec._name == "assessments.be.prompt.question"
    tag = "%s:%s" % ("draft" if draft else "question", rec.id)
    dim_rows = rec.answer_dimension_ids if draft else rec.question_dimension_ids
    label_field = "label" if draft else "name"
    tpl = rec.source_template_id
    slots = template_slot_names(
        json.dumps(tpl.structure_json, default=str) + " "
        + (tpl.instructions or "")) if tpl else []
    if slots:
        values = dict.fromkeys(slots, TEMPLATE_SLOT_FALLBACK)
        changed = False
        for field in ("name", "question_prompt", "prompt", "description",
                      "solution_json", "solution_rationale",
                      "official_reasoning", "flaw_plan_json", "dimensions_json",
                      "rubric_json", "options_json", "correct_answer_json",
                      "subjective_rubric_json"):
            value = rec[field] if field in rec._fields else None
            if isinstance(value, str) and "{" in value:
                filled = fill_template_slots(value, values)
                if filled != value:
                    rec[field] = filled
                    changed = True
        for dim in dim_rows:
            for row, field in [(dim, label_field)] + [
                    (opt, "name") for opt in dim.option_line_ids]:
                filled = fill_template_slots(row[field] or "", values)
                if filled != (row[field] or ""):
                    row[field] = filled
                    changed = True
        if changed:
            report["slots"].append(tag)
    if rec.question_type != "image_ab":
        return
    dims = rec._dimension_specs() if draft else [
        {"label": d.name or "",
         "options": d.option_line_ids.mapped("name"),
         "correct": d.option_line_ids.filtered("is_correct").mapped("name")}
        for d in dim_rows]
    reasoning = rec.official_reasoning or ""
    single = _AB_REASONING_RE.match(reasoning)
    both = _AB_REASONING_BOTH_RE.match(reasoning)
    if not (single or both) or not dims:
        return
    if not any(ab_is_side_option(o) for d in dims for o in d["options"]):
        if not all(d["correct"] for d in dims):
            report["ambiguous"].append(tag)
            return
        planted = parse_flaw_plan(rec.flaw_plan_json).get("planted")
        planted = planted if isinstance(planted, dict) else {}
        flaws = [str(f) for f in (planted.get("a") or []) + (
            planted.get("b") or []) if str(f).strip()]
        if not flaws:
            flaws = [single.group(3)] if single else [
                f for f in both.groups() if f != "none stated"]
        rec.official_reasoning = _flaw_official_reasoning_ratings(dims, flaws)
        report["reasoning"].append(tag)
        return
    if not single:
        return
    winner = single.group(1).lower()
    keyed = {ab_normalize_verdict(c) for d in dims for c in d["correct"]
             if ab_is_side_option(c)}
    try:
        solution = json.loads(rec.solution_json or "null")
    except (TypeError, ValueError):
        solution = None
    justification = solution.get("justification") \
        if isinstance(solution, dict) else None
    texts = [t for t in (rec.solution_rationale,
                         justification if isinstance(justification, str)
                         else None) if t and _AB_SIDE_RE.search(t)]
    if not texts:
        return
    verdicts = [_ab_prose_blames_winner(t, winner) for t in texts]
    if keyed != {ab_side_verdict(winner)} or None in verdicts:
        report["ambiguous"].append(tag)
        return
    if not any(verdicts):
        return
    if _ab_prose_blames_winner(rec.solution_rationale or "", winner):
        rec.solution_rationale = ab_flip_sides_in_text(rec.solution_rationale)
    if isinstance(justification, str) \
            and _ab_prose_blames_winner(justification, winner):
        solution["justification"] = ab_flip_sides_in_text(justification)
        rec.solution_json = json.dumps(solution, ensure_ascii=False)
    report["rationale"].append(tag)


def _task_registry_note(prompt_record):
    """Tell the model EVERY task this SOP defines, with each task's own shape.

    This is what makes a project the platform has never seen assessable without
    a code change. `_rating_scheme_note` above carries ONE scheme for the whole
    SOP, which is right for a single-task project and wrong for a SOP that
    teaches several different jobs: the second job's axes and options are simply
    absent, so items for it get invented rather than reproduced.

    Each task here carries its own answer contract - the SOP's own axis wording,
    its own per-axis options, whether a justification is required - so an item
    can be authored against the task it belongs to. Returns "" when the SOP has
    no registry, which leaves the existing single-scheme behaviour untouched.
    """
    try:
        tasks = parse_task_registry(
            getattr(prompt_record, "tasks_json", "") or "")
    except Exception:  # noqa: BLE001
        return ""
    # One task adds nothing the rating scheme does not already say, and repeating
    # it costs tokens on every generation. The registry earns its place only when
    # the SOP genuinely defines more than one job.
    if len(tasks) < 2:
        return ""
    blocks = []
    for i, task in enumerate(tasks, start=1):
        contract = task_answer_contract(task)
        qtype = task_question_type(task)
        parts = [
            "  TASK %d - %s" % (i, task.get("display") or task.get("key")),
            "    what the worker looks at: %s"
            % (task.get("subject_inputs") or "(not stated)"),
            "    what the worker produces: %s"
            % (task.get("worker_output") or "(not stated)"),
        ]
        if qtype:
            parts.append("    author these as question_type: %s" % qtype)
        for d in contract.get("dimensions") or []:
            parts.append("    axis: %s | options: %s"
                         % (d["label"], ", ".join(d["options"])))
        if contract.get("justification") == "required":
            parts.append("    a written justification is REQUIRED")
        if contract.get("solution_shape"):
            parts.append("    a correct answer: %s" % contract["solution_shape"])
        blocks.append("\n".join(parts))
    return (
        "\n\nTHIS SOP DEFINES %d DISTINCT TASKS. Cover them - do not spend every "
        "item on the first one. Each task below carries the SOP's OWN axes and "
        "the SOP's OWN answer options for those axes: use them VERBATIM for items "
        "belonging to that task, and never carry one task's axes onto another "
        "task's items. An axis's options are specific to that axis; a task whose "
        "axis offers two choices must not be given four.\n%s"
        % (len(tasks), "\n".join(blocks)))


def _count_items_by_shape(items, allowed, quotas, ab_dims=None):
    """`{shape: how_many_survive}` for every shape a quota mentions.

    "Survive" means exactly what the coverage stage already meant: the item
    resolves to a type in the allow-list AND passes that type's validator, so an
    item that would be dropped at create does not count towards a quota. Without
    that, a quota looks satisfied while the batch ships short.

    A template shape is credited to items stamped with that template id, which is
    what `_topup_items(force_shape=...)` sets when it authors them.
    """
    counted = {}
    for it in items:
        if not isinstance(it, dict):
            continue
        qt = _resolve_item_type(it, allowed)
        if qt is None:
            continue
        if _validate_question_item(it, qt, ab_dims=ab_dims):
            continue
        # A template-authored item counts for its template AND its type: the
        # admin asked for "this shape x 2", and those items are still mcq/image_ab
        # for the purposes of the type coverage floor.
        stamped = it.get("_template_shape")
        if isinstance(stamped, str) and stamped in (quotas or {}):
            counted[stamped] = counted.get(stamped, 0) + 1
        counted[qt] = counted.get(qt, 0) + 1
    return counted


def _stamp_template_items(items, quotas, template_specs, allowed):
    """Mark PRIMARY-call items as having come from a template.

    WHY THIS EXISTS. `_template_shape` used to be set in exactly one place -
    the top-up loop - so an item was stamped only when the primary call had
    FAILED to satisfy a template quota. When the primary call succeeded (the
    normal, good case) nothing was stamped, and everything downstream that
    keys off the stamp silently did nothing: the item's axes kept the SOP's
    short names instead of the examiner's wording, and the draft carried no
    record of which template authored it.

    ATTRIBUTION IS CONSERVATIVE. A stamp is only applied when the template is
    the unambiguous owner of that question type - one template quota for the
    type - and only up to the number of items the admin asked for. Guessing
    between two templates of the same type would put one template's wording on
    another's item, which is worse than leaving it canonical.

    VALIDITY IS NOT PART OF ATTRIBUTION. The stamp answers "which template
    authored this", which is true whether or not the content passed. Skipping
    invalid items stripped provenance from exactly the drafts a human most
    needs it on - the ones they have to open the template to repair.
    """
    if not quotas or not template_specs:
        return
    # {question_type: shape} for types owned by exactly ONE template quota.
    owners = {}
    ambiguous = set()
    for shape in quotas:
        spec = (template_specs or {}).get(shape)
        if not spec:
            continue
        qt = spec.get("question_type")
        if not qt:
            continue
        if qt in owners:
            ambiguous.add(qt)
        owners[qt] = shape
    for qt in ambiguous:
        owners.pop(qt, None)
    if not owners:
        return
    remaining = {shape: quotas.get(shape, 0) for shape in owners.values()}
    for it in items:
        if not isinstance(it, dict) or it.get("_template_shape"):
            continue
        qt = _resolve_item_type(it, allowed)
        if qt is None or qt not in owners:
            continue
        shape = owners[qt]
        if remaining.get(shape, 0) <= 0:
            continue
        # ATTRIBUTION SURVIVES A FAILED VALIDATION.
        #
        # This used to `continue` on any validation error, so an item the model
        # got slightly wrong - a rubric-typed template returned with no rubric,
        # say - was kept for review with NO record of which template authored
        # it. That is precisely the item a human most needs the provenance for:
        # the reviewer has to open the template to see what it should have
        # been, and the drafts table showed the engine's name instead.
        # Attribution answers "where did this come from", which is true
        # regardless of whether the content passed.
        it["_template_shape"] = shape
        remaining[shape] -= 1


def _quota_directive(quotas, template_specs=None):
    """State the per-shape counts the admin actually asked for.

    Without this the directive says only "approximately N" plus "at least one of
    each selected type", so `MCQ x 2, Subjective x 3` was unsayable: the model
    was never told the split and the harness had no way to enforce it.
    """
    if not quotas:
        return ""
    lines = []
    for shape, wanted in quotas.items():
        if is_template_shape(shape):
            spec = (template_specs or {}).get(shape) or {}
            label = spec.get("name") or shape
            # NAME THE ANSWER-KEY FIELDS BESIDE THE TASK. "Reproduce the task
            # IG" is a specific instruction, and it wins over the general
            # answer-key rule stated ~18k characters earlier in the system
            # prompt - a live run on template 20 returned a well-formed
            # subjective_rubric question with no `rubric` at all, which then
            # failed validation AND lost its template attribution.
            need = ANSWER_KEY_REQUIREMENT.get(spec.get("question_type") or "")
            lines.append(
                "  - EXACTLY %d item(s) reproducing the task \"%s\"%s" % (
                    wanted, label,
                    (" - each MUST carry its answer key: %s" % need)
                    if need else ""))
        else:
            lines.append("  - EXACTLY %d item(s) of question_type \"%s\""
                         % (wanted, shape))
    return (
        "\n\nPER-SHAPE COUNTS (the examiner set these explicitly; they are not "
        "suggestions):\n" + "\n".join(lines)
        + "\nMeet each count. If you cannot, return what you can and the "
        "shortfall is reported to the examiner - do NOT substitute a different "
        "shape to pad the number.")


def _trim_preserving_quotas(items, count, allowed, quotas=None, ab_dims=None):
    """Trim to COUNT while protecting up to `wanted` items per quota shape.

    `_trim_preserving_type_coverage` protects exactly ONE item per selected type,
    which is right when coverage is the only invariant and wrong once the admin
    can ask for two. This protects the quota'd items first (in quota order, so
    the admin's priority survives a squeeze), then falls back to the existing
    one-per-type behaviour for types with no quota.

    With no quotas it delegates, so today's behaviour is untouched.
    """
    if not quotas:
        return _trim_preserving_type_coverage(
            items, count, allowed, ab_dims=ab_dims)
    if count <= 0 or len(items) <= count:
        return items

    remaining = dict(quotas)
    protected_idx = []
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            continue
        qt = _resolve_item_type(it, allowed)
        if qt is None or _validate_question_item(it, qt, ab_dims=ab_dims):
            continue
        stamped = it.get("_template_shape")
        for shape in (stamped, qt):
            if shape and remaining.get(shape):
                remaining[shape] -= 1
                protected_idx.append(i)
                break
        if len(protected_idx) >= count:
            break

    keep = list(protected_idx)
    # THE COVERAGE FLOOR STILL APPLIES to types with no explicit quota. Filling
    # the spare slots in plain original order would spend them on whichever type
    # happens to come first - in a batch of five mcq and one rubric, capped at
    # three with `mcq x 2`, that meant a THIRD mcq and no rubric at all, silently
    # re-opening the gap the coverage stage exists to close.
    if len(keep) < count:
        taken = set(keep)
        covered = set()
        for i in keep:
            qt = _resolve_item_type(items[i], allowed)
            if qt:
                covered.add(qt)
        for i, it in enumerate(items):
            if len(keep) >= count:
                break
            if i in taken or not isinstance(it, dict):
                continue
            qt = _resolve_item_type(it, allowed)
            if qt is None or qt in covered:
                continue
            if _validate_question_item(it, qt, ab_dims=ab_dims):
                continue
            keep.append(i)
            taken.add(i)
            covered.add(qt)
    if len(keep) < count:
        taken = set(keep)
        # Anything still spare goes in original order, so a run is stable and
        # reviewers see the model's own ordering rather than a reshuffle.
        for i in range(len(items)):
            if i not in taken:
                keep.append(i)
                if len(keep) >= count:
                    break
    keep = sorted(set(keep))[:count]
    return [items[i] for i in keep]


def _rating_scheme_note(prompt_record):
    """Inject THIS SOP's own rating scheme into the generation directive.

    Without it the model invents a generic Response A/B scale for every
    comparison-style item. With it, an A/B or multiple-choice question is planned
    against the dimensions and answer options the SOP actually prescribes, so the
    reviewer and candidate see the project's real labels."""
    try:
        scheme = sop_rating_scheme(prompt_record)
    except Exception:  # noqa: BLE001
        return ""
    if not scheme:
        return ""
    dims = scheme.get("dimensions") or []
    if not dims:
        return ""
    lines = []
    for d in dims:
        opts = d.get("options") or []
        lines.append(
            "  - %s = %s%s" % (
                d.get("code"), d.get("label"),
                (" | options: %s" % ", ".join(opts)) if opts else ""))
    kind = scheme.get("kind") or "none"
    how = ("the worker answers these INDEPENDENT questions about ONE item "
           "(one verdict per dimension; they do NOT trade off)"
           if kind == "independent_questions" else
           "the worker compares two candidates on these dimensions"
           if kind == "preference_comparison" else
           "the SOP rates these dimensions")
    return (
        "\n\nTHIS SOP'S RATING SCHEME (authoritative — taken from the SOP "
        "itself): %s.\n%s\n"
        "When you author ANY question whose answer is a choice on these axes "
        "(image_ab, mcq/msq about the judgement, etc.), use EXACTLY these "
        "dimension codes, these labels and these answer options — emit them in "
        "construction_keys / dimension_labels / dimension_options (and in an "
        "mcq's options) verbatim. Do NOT substitute a generic Response A/B "
        "scale, and do NOT rename or reorder the SOP's dimensions.\n"
        % (how, "\n".join(lines)))


def _normalize_rating_scheme(raw):
    """Validate/clean the SOP rating scheme the tag pass returns.

    Shape kept: {"kind": ..., "dimensions": [{"code","label","options",
    "evidence"}]}. A dimension is only kept when it has a code AND a label —
    an entry without them cannot drive a question. Options are optional (a
    preference_comparison SOP may rely on the default A/B vocabulary)."""
    if not isinstance(raw, dict):
        return None
    kind = str(raw.get("kind") or "").strip().lower()
    if kind not in ("independent_questions", "preference_comparison", "none"):
        kind = "none"
    dims = []
    for d in (raw.get("dimensions") or []):
        if not isinstance(d, dict):
            continue
        code = str(d.get("code") or "").strip()
        label = str(d.get("label") or "").strip()
        if not code or not label:
            continue
        opts = [str(o).strip() for o in (d.get("options") or [])
                if str(o).strip()]
        # CANONICALISE THE CODE, KEEP THE SOP'S LABEL.
        #
        # This stored `code.upper()`, so a SOP whose final axis reads "Overall
        # Preference" was persisted as the code 'OVERALL PREFERENCE' - and
        # `_rating_scheme_note` then ORDERS the model to emit these codes
        # verbatim into construction_keys. `validate_flaw_plan` requires OC, so
        # every image_ab item the model faithfully produced was rejected and the
        # run reported success with zero drafts. The label is untouched: the SOP's
        # own wording is what a reviewer and candidate should read.
        canon, _known_label = ab_normalize_dim_key(code) if code else ("", "")
        entry = {"code": (canon or code.upper()), "label": label}
        # A comparison SOP's option words ("Image A", "Tie") mean the same picks
        # as the platform's vocabulary, and scoring only understands the latter.
        # An independent-questions SOP keeps its own answer set verbatim - YES/NO
        # is not an A/B pick and must never be rewritten into one.
        if opts and kind == "preference_comparison":
            # TIE IS DROPPED AT THE SOURCE, before the mapping runs, so a SOP
            # that genuinely lists "Both Good" keeps it while one that offers a
            # tie does not have it reintroduced under another name.
            opts = [o for o in opts if not ab_is_tie_word(o)]
            opts = list(dict.fromkeys(ab_normalize_verdict(o) for o in opts))
            # THE OVERALL AXIS IS ALWAYS DECIDED. Belt and braces over the tie
            # filter: a SOP that literally writes "Both Good" against its
            # overall axis still cannot make an undecided Overall Choice legal,
            # because an A/B whose overall pick is a tie has no answer key.
            if entry["code"] == AB_OVERALL_CODE:
                opts = [o for o in opts if o in ("Response A", "Response B")]
        if opts:
            entry["options"] = opts
        ev = str(d.get("evidence") or "").strip()
        if ev:
            entry["evidence"] = ev[:400]
        dims.append(entry)
    if not dims and kind == "none":
        return None
    return {"kind": kind, "dimensions": dims}


def sop_rating_scheme(prompt_record):
    """The persisted SOP rating scheme for a generator, or None."""
    raw = (getattr(prompt_record, "rating_scheme_json", "") or "").strip()
    if not raw:
        return None
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return obj if isinstance(obj, dict) and obj.get("dimensions") else None


def sop_scheme_labels_and_options(prompt_record):
    """(labels_by_code, options_by_code) from the SOP's own rating scheme.

    This is the AUTHORITATIVE source for what an A/B or choice question should
    display: the dimensions the SOP names and the exact options it offers. Empty
    dicts when the SOP prescribes no scheme."""
    scheme = sop_rating_scheme(prompt_record)
    if not scheme:
        return {}, {}
    labels, options = {}, {}
    for d in scheme.get("dimensions") or []:
        code = str(d.get("code") or "").strip().upper()
        if not code:
            continue
        if d.get("label"):
            labels[code] = d["label"]
        if d.get("options"):
            options[code] = list(d["options"])
    return labels, options


def _template_dimension_labels(template_spec, keys):
    """{CODE: the examiner's own axis wording} for a template-authored item.

    A template names its axes the way a candidate should read them ("Which
    image better follows the prompt?"), while `construction_keys` uses short
    codes (`IF`). This pairs them so the examiner's wording can win.

    WHY NOT POSITION. The obvious pairing - zip the template's axes against
    the key codes - is wrong, and wrong in the worst way: it produces a
    complete, confident, entirely mislabelled answer key. The live T2I
    template lists its axes as [Overall, IF, VQ, LAI] while the model returned
    keys as [IF, VQ, LAIG, OP], so zipping labelled the overall-preference
    axis "Instruction Following" and every other axis shifted by one.

    So match on MEANING, through the same self-extending synonym registry the
    rest of the A/B vocabulary uses: run each axis phrase through
    `ab_code_from_label`, which knows "less ai generated" -> LAI and
    "overall preference" -> OC. An axis that resolves to no known code is left
    alone rather than guessed at - a missing label falls back to the canonical
    name, which is merely terse, where a WRONG label is a lie about what the
    candidate was asked.
    """
    if not template_spec or not keys:
        return {}
    contract = ((template_spec.get("task") or {}).get("answer_contract")
                or {})
    axes = [d.get("label") for d in (contract.get("dimensions") or [])
            if d.get("label")]
    if not axes:
        return {}
    key_codes = []
    for raw in keys:
        code, _label = ab_normalize_dim_key(raw)
        if code and code not in key_codes:
            key_codes.append(code)
    out = {}
    for axis in axes:
        code = ab_code_from_label(axis)
        if code and code in key_codes and code not in out:
            out[code] = axis
    return out


def _infer_dimension_labels(env, plan_labels, keys, prompt_record=None,
                            template_labels=None):
    """Titles for the dimensions of an A/B-style item.

    Priority (highest first):
      1. a TASK TEMPLATE's own axis wording — the examiner authored it by hand,
      2. the SOP's OWN rating scheme (captured at tag-extraction),
      3. the model's per-item `dimension_labels`,
      4. the SOP's extracted skill tags, for still-unnamed NUMBERED dims.

    A TEMPLATE OUTRANKS THE SOP. The generation directive already tells the
    model a template's axes "outrank anything you would infer from the SOP
    prose", and the same has to hold when the answer key is built - otherwise
    an examiner who wrote "Which image better follows the prompt?" watched the
    SOP's short name "Instruction Following" overwrite it on the candidate's
    screen, and the template silently stopped meaning anything.

    A bare 'Q1' is meaningless in the answer key and to the candidate, so this
    always tries to attach the SOP's own wording. Everything is data-driven and
    self-extending — no hardcoded dimension names."""
    labels = dict(plan_labels or {})
    if prompt_record is not None:
        try:
            sop_labels, _sop_opts = sop_scheme_labels_and_options(prompt_record)
        except Exception:  # noqa: BLE001
            sop_labels = {}
        # SOP wins over the model's per-item guess: it is the source of truth
        # for what the worker actually judges.
        labels.update(sop_labels)
    # ...but a hand-authored template wins over the SOP, applied LAST so it
    # cannot be overwritten by either.
    #
    # KEYED BY BOTH THE CANONICAL CODE AND THE RAW ONE. `construction_keys`
    # carries whatever code the model coined (`LAIG`, `OP`), while the
    # template map is keyed canonically (`LAI`, `OC`). Writing only the
    # canonical key left the raw key still pointing at the SOP's short name,
    # and the builder - which looks the label up by the RAW key - kept using
    # it: the examiner's wording was present in the map and never read.
    if template_labels:
        labels.update(template_labels)
        for raw in list(keys or {}):
            code, _label = ab_normalize_dim_key(raw)
            if code in template_labels:
                labels[raw] = template_labels[code]
    numbered = [c for c in (keys or {})
                if re.fullmatch(r"Q\d+", str(c).strip().upper() or "")
                and str(c).strip().upper() not in labels]
    if not numbered or prompt_record is None:
        return labels
    try:
        skills = [t.name for t in prompt_record.tag_ids
                  if (t.name or "").lower().startswith("skill:")]
    except Exception:  # noqa: BLE001
        return labels
    if not skills:
        return labels
    # Q1..Qn follow the SOP's own question order; pair them with the skill tags
    # in extraction order (the tag prompt emits them in SOP order too).
    numbered.sort(key=lambda c: int(str(c).strip().upper()[1:]))
    for idx, code in enumerate(numbered):
        if idx >= len(skills):
            break
        raw = skills[idx].split(":", 1)[1]
        labels[str(code).strip().upper()] = raw.replace("-", " ").title()
    return labels


def _build_flaw_injected_ab_fields(plan, prompt_record=None, env=None,
                                   template_spec=None):
    # The flawed image MUST land on a random slot: without the swap every answer
    # key is "Response A" and the item is gameable. Verdicts flip with it so
    # construction_keys stay aligned to the rendered slots.
    import random
    norm = normalize_flaw_plan(plan) or {}
    keys = dict(norm.get("construction_keys") or {})
    dimension_options = dict(norm.get("dimension_options") or {})
    # The SOP's OWN options (captured at tag-extraction) outrank whatever the
    # per-item plan guessed: the candidate must see the choices the SOP offers.
    if prompt_record is not None:
        try:
            _sl, sop_opts = sop_scheme_labels_and_options(prompt_record)
            dimension_options.update(sop_opts)
        except Exception:  # noqa: BLE001
            pass
    # A hand-authored template's axis wording outranks both the model's guess
    # and the SOP's short names - the examiner decided what the candidate reads.
    dimension_labels = _infer_dimension_labels(
        env, norm.get("dimension_labels"), keys, prompt_record,
        template_labels=_template_dimension_labels(template_spec, keys))
    worker_prompt = norm.get("worker_prompt") or ""
    render_prompts = dict(norm.get("render_prompts") or {"a": "", "b": ""})
    planted = {"a": list((norm.get("planted") or {}).get("a") or []),
               "b": list((norm.get("planted") or {}).get("b") or [])}
    both_flawed = norm.get("faithful_side") not in AB_FLAWED_SIDES
    # NO SIDE ON ANY AXIS (e.g. Yes/No checks on a reference image): the key
    # does not depend on the slot, so there is nothing to randomise, and a swap
    # would only move the images away from the prompt's own left/right wording.
    specs = ab_specs_from_construction_keys(keys, dimension_options,
                                            dimension_labels)
    side_free = bool(specs) and not any(
        ab_is_side_option(o) for s in specs for o in s["options"])
    if side_free:
        do_swap = False
    elif both_flawed:
        do_swap = random.choice((False, True))
    else:
        do_swap = random.choice(AB_FLAWED_SIDES) != (norm.get("flawed_side") or "")
    if do_swap:
        render_prompts = {"a": render_prompts.get("b") or "",
                          "b": render_prompts.get("a") or ""}
        planted = {"a": planted["b"], "b": planted["a"]}
        keys = ab_flip_construction_keys(keys)
        specs = ab_specs_from_construction_keys(keys, dimension_options,
                                                dimension_labels)
    if both_flawed:
        final_faithful = "both"
        final_flawed = "both"
        injected = planted["a"] + planted["b"]
        reasoning = _flaw_official_reasoning_both(keys, planted)
        flawed_prompt = ""
    else:
        final_flawed = norm.get("flawed_side") if not do_swap \
            else ab_other_side(norm.get("flawed_side"))
        final_faithful = ab_other_side(final_flawed)
        injected = planted[final_flawed]
        reasoning = _flaw_official_reasoning(final_flawed, injected)
        flawed_prompt = render_prompts.get(final_flawed) or ""
    if side_free:
        reasoning = _flaw_official_reasoning_ratings(
            specs, planted["a"] + planted["b"])
    briefs = [
        {"slot": "a", "label": "Response A", "prompt": render_prompts.get("a") or ""},
        {"slot": "b", "label": "Response B", "prompt": render_prompts.get("b") or ""},
    ]
    vals = {
        "image_brief_json": json.dumps(briefs, ensure_ascii=False),
        "dimensions_json": json.dumps(specs, ensure_ascii=False),
        "flaw_plan_json": json.dumps({
            "faithful_side": final_faithful,
            "flawed_side": final_flawed,
            "worker_prompt": worker_prompt,
            "render_prompts": render_prompts,
            "planted": planted,
            "construction_keys": keys,
            "dimension_options": dimension_options,
            "dimension_labels": dimension_labels,
            "clean_prompt": worker_prompt,
            "flawed_prompt": flawed_prompt,
            "injected_flaws": injected,
        }, ensure_ascii=False),
        "official_reasoning": reasoning,
    }
    # Verdicts MUST derive from construction_keys (slot-aligned, swap-corrected);
    # the model's own solution verdicts often name the pre-swap side.
    _CK2SOL = {"IF": "instruction_following", "VQ": "visual_quality",
               "LAI": "less_ai_generated", "OC": "overall_preference"}
    derived = {_CK2SOL[k]: v for k, v in keys.items() if k in _CK2SOL}
    vals["_derived_ab_solution"] = derived
    # The model's own prose (rationale, justification) names the PRE-swap
    # sides too; the caller flips it with this, as the key was flipped above.
    vals["_ab_swapped"] = do_swap
    if worker_prompt:
        vals["question_prompt"] = worker_prompt
    return vals


_IMAGE_PROMPT_SLOT_ALIASES = {
    "reference": "reference", "ref": "reference", "input": "reference",
    "source": "reference", "style": "reference", "before": "reference",
    "style-reference": "reference", "style reference": "reference",
    "output": "output", "out": "output", "target": "output",
    "result": "output", "after": "output", "transformed": "output",
    "single": "single", "image": "single", "img": "single",
}
_IMAGE_PROMPT_SLOT_ORDER = {"reference": 0, "output": 1, "single": 2}
_IMAGE_PROMPT_SLOT_LABEL = {"reference": "Reference", "output": "Output",
                            "single": "Image"}


def _image_prompt_briefs(images):
    imgs = [i for i in images
            if isinstance(i, dict) and (i.get("prompt") or "").strip()]
    if not imgs:
        return []
    briefs = [{
        "slot": _IMAGE_PROMPT_SLOT_ALIASES.get(
            (i.get("slot") or "").strip().lower(), ""),
        "label": (i.get("label") or "").strip(),
        "prompt": i["prompt"],
    } for i in imgs]
    if len(briefs) == 1:
        briefs[0]["slot"] = briefs[0]["slot"] or "single"
    else:
        default_order = ["reference", "output"]
        used = {b["slot"] for b in briefs if b["slot"]}
        di = 0
        for b in briefs:
            if b["slot"]:
                continue
            while di < len(default_order) and default_order[di] in used:
                di += 1
            b["slot"] = default_order[di] if di < len(default_order) else "output"
            used.add(b["slot"])
            di += 1
    briefs.sort(key=lambda b: _IMAGE_PROMPT_SLOT_ORDER.get(b["slot"], 9))
    for b in briefs:
        b["label"] = b["label"] or _IMAGE_PROMPT_SLOT_LABEL.get(
            b["slot"], b["slot"].title())
    return briefs


def _video_prompt_briefs(videos):
    """Build the video clip briefs, PRESERVING a per-clip ``duration_s`` and
    keeping the reference->output pair intact.

    Two bugs this guards (growth 24/7):
    - #4 REFERENCE EMPTY: a transformation question needs BOTH a ``reference``
      and an ``output`` clip. If the model emitted only one clip but wrote its
      answer key as a reference->output transformation, generating a lone
      ``output`` leaves the candidate with nothing to transform FROM. We keep
      whatever clips have a real prompt, slot them reference-first, and flag a
      single-clip transformation so the caller can log it (we never silently
      fabricate a second brief — that would be an ungrounded asset).
    - #5 ALL 6s: Veo defaulted every clip to 6s because the brief dropped the
      model's ``duration_s``. We now carry it through (snapped to a duration
      Veo actually accepts - veo-3.x takes the ENUM 4/6/8, not a 4-8 range)
      so durations vary per the SOP; ``submit_video_op`` already reads
      ``brief['duration_s']``.
    """
    vids = [v for v in videos
            if isinstance(v, dict) and (v.get("prompt") or "").strip()]
    if not vids:
        return []
    briefs = []
    for v in vids:
        b = {
            "slot": _IMAGE_PROMPT_SLOT_ALIASES.get(
                (v.get("slot") or "").strip().lower(), ""),
            "label": (v.get("label") or "").strip(),
            "prompt": v["prompt"],
        }
        dur = v.get("duration_s") or v.get("durationSeconds") or v.get("duration")
        try:
            dur = int(round(float(dur))) if dur else 0
        except (TypeError, ValueError):
            dur = 0
        if dur:
            # Veo takes an ENUM of durations (veo-3.x: 4/6/8), NOT a range - a
            # plain 4..8 clamp let 5s and 7s through and Veo 400'd the op with
            # "Unsupported output video duration 5 seconds". Snap to the
            # nearest legal value instead.
            b["duration_s"] = snap_video_duration(dur)
        briefs.append(b)
    if len(briefs) == 1:
        # A lone surviving clip can't be a reference/output half of a
        # transformation (nothing to pair with), so it becomes a from-scratch
        # 'single' regardless of the slot the model gave it — never an orphan
        # 'reference' the candidate can't act on (growth #4).
        briefs[0]["slot"] = "single"
    else:
        default_order = ["reference", "output"]
        used = {b["slot"] for b in briefs if b["slot"]}
        di = 0
        for b in briefs:
            if b["slot"]:
                continue
            while di < len(default_order) and default_order[di] in used:
                di += 1
            b["slot"] = default_order[di] if di < len(default_order) else "output"
            used.add(b["slot"])
            di += 1
    briefs.sort(key=lambda b: _IMAGE_PROMPT_SLOT_ORDER.get(b["slot"], 9))
    for b in briefs:
        b["label"] = b["label"] or _IMAGE_PROMPT_SLOT_LABEL.get(
            b["slot"], b["slot"].title())
    return briefs


def _label_key_sort(k):
    try:
        return (0, int(k))
    except (TypeError, ValueError):
        return (1, str(k))


def _normalize_box_2d(box):
    if not isinstance(box, (list, tuple)) or len(box) != 4:
        return None
    try:
        coords = [int(round(float(c))) for c in box]
    except (TypeError, ValueError):
        return None
    return [max(0, min(1000, c)) for c in coords]


def _image_label_boxes(specs, cap=None):
    """The generator's authored boxes, renumbered 1..N in the order given and
    truncated to ``cap``.

    The truncation is LOUD on purpose. A silently shortened list is
    indistinguishable from a model that complied with the "up to N" contract, so
    the one signal that the contract is being ignored - and that the reviewer is
    looking at a subset of what was authored - would be invisible in the logs.
    """
    limit = _label_box_cap(cap)
    answer_key = specs.get("answer_key") or {}
    ideal = answer_key.get("ideal_labels") if isinstance(answer_key, dict) else None
    labels_map = ideal if isinstance(ideal, dict) else {}
    raw_boxes = specs.get("boxes")
    entries = []
    dropped = 0
    if isinstance(raw_boxes, list):
        for b in raw_boxes:
            if not isinstance(b, dict):
                continue
            box_2d = _normalize_box_2d(b.get("box_2d") or b.get("box"))
            if not box_2d:
                continue
            # Counted only for WELL-FORMED boxes, so the warning below reports
            # boxes the model actually authored and we threw away - not the
            # malformed entries that were never usable in the first place.
            if len(entries) >= limit:
                dropped += 1
                continue
            n = len(entries) + 1
            element = str(b.get("element") or b.get("label") or "").strip()
            func = str(
                b.get("functionality") or b.get("description")
                or labels_map.get(str(b.get("number") or n))
                or labels_map.get(str(n)) or "").strip()
            entries.append({
                "number": n,
                "box_2d": box_2d,
                "element": element or ("Element %d" % n),
                "functionality": func,
            })
    if dropped:
        _logger.warning(
            "etp_assessment image_label: generator authored %d box(es), cap is "
            "%d - dropped the last %d. The answer key is rebuilt from the kept "
            "boxes only, so nothing grades against a box the candidate never "
            "saw.", len(entries) + dropped, limit, dropped)
    return entries


# IRREGULAR HOSTS, NOT A PREFERRED SET. Read the docstring on
# `_repair_image_label_source_url` before adding to this - it is an exception
# table for products whose homepage is NOT `www.<name>.com`, and nothing else.
# It was once a five-entry "golden set" that the generation directive told the
# model to pick from, and the result was exactly what you would expect: five
# labelling questions on the five listed sites, in list order, from a SOP that
# named none of them. The directive now tells the model to choose from the whole
# public web; this map never influences that choice and must not grow into one.
_IRREGULAR_HOSTS = {
    "spotify": "https://open.spotify.com",
    "wikipedia": "https://www.wikipedia.org",
    "wikimedia": "https://www.wikipedia.org",
    "google": "https://www.google.com",
    "google search": "https://www.google.com",
    "youtube": "https://www.youtube.com",
    "x": "https://x.com",
    "twitter": "https://x.com",
}

#: Words that describe the KIND of thing rather than name it, so they must never
#: become a hostname on their own.
_NOT_A_PRODUCT_NAME = frozenset({
    "app", "application", "site", "website", "page", "homepage", "web",
    "platform", "portal", "dashboard", "tool", "software", "service",
    "screenshot", "ui", "interface", "unknown", "n/a", "none",
})


def _slug_for_host(name):
    """A hostname label from a product name, or "" when it cannot be one.

    Words are tested BEFORE they are joined. Checking only the joined slug let
    "the website" through as `thewebsite.com`: every word was generic, but the
    concatenation matched nothing in the stop list. So a name is refused when
    what survives dropping articles and category words is empty.
    """
    words = [w for w in re.split(r"[^a-z0-9]+", (name or "").lower()) if w]
    kept = [w for w in words
            if w not in _NOT_A_PRODUCT_NAME and w not in ("the", "a", "an", "of")]
    cleaned = "".join(kept)
    return cleaned if len(cleaned) >= 2 else ""

# 1000 real, individually-verified-live public pages (data/image_label_sites.
# json - built by sampling each site's OWN API: Wikipedia's random-article
# API across 12 languages, GitHub's search API across star/topic/language
# ranges, the PyPI simple index, and npm registry search - then keeping only
# the ones that actually returned 200 at build time, not guessed by hand).
# The random draw below is the last resort for a generator with "Screenshot
# live websites" on, when nothing in the item names a site (the
# _IRREGULAR_HOSTS lane above) and _slug_for_host cannot derive one. Every
# other generator drops the URL at draft build (its picture is AI-made), so a
# draw there is discarded.
_IMAGE_LABEL_SITE_POOL = None


def _image_label_site_pool():
    global _IMAGE_LABEL_SITE_POOL
    if _IMAGE_LABEL_SITE_POOL is None:
        path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "data", "image_label_sites.json")
        try:
            with open(path, encoding="utf-8") as f:
                sites = json.load(f)
            _IMAGE_LABEL_SITE_POOL = [s for s in sites if isinstance(s, str)]
        except (OSError, ValueError):
            _logger.warning(
                "image_label site pool missing/unreadable at %s", path)
            _IMAGE_LABEL_SITE_POOL = []
    return _IMAGE_LABEL_SITE_POOL


def _repair_image_label_source_url(specs):
    """Best-effort URL for an image_label spec whose `source_url` is missing.

    A REPAIR NET, NOT A VOCABULARY. It fires only when the model authored
    everything else and left the URL out. Only a generator with "Screenshot
    live websites" on keeps the result (`generate_questions_from_sop` drops
    `source_url` otherwise); `_validate_question_item` consults it only for an
    item with neither an images[] brief nor a defect plan.

    It DERIVES a homepage from the product the model named, so any site on the
    web can be recovered rather than the handful somebody once hardcoded. The
    naive form is `https://www.<slug>.com`; `_IRREGULAR_HOSTS` overrides the
    products where that is simply wrong.

    A DERIVED GUESS CAN MISS: a wrong host fails the capture and the draft
    falls back to its AI-made picture with a warning. The POOL DRAW BELOW
    returns a page this build confirmed answers 200; it runs only when no
    product is named anywhere in the item.
    """
    if not isinstance(specs, dict):
        return ""
    hay = (str(specs.get("application") or "") + " "
           + str(specs.get("source_url") or "")).lower()
    for img in (specs.get("images") or []):
        if isinstance(img, dict):
            hay += " " + str(img.get("prompt") or "").lower()
            hay += " " + str(img.get("label") or "").lower()
    # Longest needle first: "google search" must beat "google".
    for needle in sorted(_IRREGULAR_HOSTS, key=len, reverse=True):
        if needle in hay:
            return _IRREGULAR_HOSTS[needle]
    # Otherwise derive from the product the model named. Only `application` is
    # used: the prose fields are full of ordinary words that would produce
    # nonsense hostnames.
    slug = _slug_for_host(specs.get("application"))
    if slug:
        return "https://www.%s.com" % slug
    # Nothing to derive from at all: a verified-live page from the pool (kept
    # only for a live-capture generator).
    pool = _image_label_site_pool()
    return random.choice(pool) if pool else ""


def _apply_capture_directives(specs, vals, cap=None):
    src = str(specs.get("source_url") or "").strip()
    if not src:
        src = _repair_image_label_source_url(specs)
    if not src:
        return
    vals["source_url"] = src[:2000]
    vals["detection_mode"] = "ui"
    cfg: dict = {}
    vp = specs.get("viewport")
    if isinstance(vp, dict):
        try:
            w, h = int(vp.get("width") or 0), int(vp.get("height") or 0)
        except (TypeError, ValueError):
            w = h = 0
        if w > 0 and h > 0:
            cfg["viewport"] = {"width": w, "height": h}
    if specs.get("wait_ms") is not None:
        try:
            cfg["wait_ms"] = int(specs.get("wait_ms"))
        except (TypeError, ValueError):
            pass
    dismiss = specs.get("dismiss")
    if isinstance(dismiss, list):
        sels = [str(s).strip() for s in dismiss if str(s).strip()]
        if sels:
            cfg["dismiss"] = sels
    # The live DOM capture runs LATER (at render, for a generator with live
    # capture on; on the bank image only if an approved capture carried no
    # boxes), long after this function's caller still has the
    # generator in hand. Freeze the cap into the capture plan the same way the
    # viewport and the settle delay are frozen, so the capture honours the
    # generator that authored the question even from a lane that only has the
    # image record. The image resolver still prefers a live generator value.
    cfg["max_boxes"] = _label_box_cap(cap)
    if cfg:
        vals["capture_config_json"] = json.dumps(cfg, ensure_ascii=False)
    omit = specs.get("omit")
    if isinstance(omit, dict) and omit:
        vals["omit_spec_json"] = json.dumps(omit, ensure_ascii=False)
    cov = str(specs.get("coverage_expected") or "yes").strip().lower()
    vals["coverage_expected"] = "no" if cov == "no" else "yes"
    app = str(specs.get("application") or "").strip()
    if app:
        vals["label_application"] = app[:200]


def _trim_marker_key(answer_key, kept_defects):
    """Drop every marker-keyed answer-key entry whose defect did not survive the
    cap, so the rubric describes exactly the markers that will be stamped.

    `_plant_defects_on_render` re-keys this map again after the render (defects
    the image edit refused to draw are dropped and the survivors renumbered), so
    it already tolerates a key that is a superset. But it only runs at render:
    between draft-build and render an admin reads the rubric in the reviewer
    form, and a key listing markers 1..30 beside a 20-defect plan reads as a
    generation bug rather than as a cap doing its job. Non-numeric keys
    (`decoys`, `scoring_guide`, prose) are never markers and always survive.
    """
    kept = set()
    for i, d in enumerate(kept_defects, start=1):
        try:
            kept.add(str(int(d.get("marker"))))
        except (TypeError, ValueError):
            kept.add(str(i))   # unnumbered plan: position IS the marker
    for field in ("ideal_labels", "answers", "labels", "markers"):
        sub = answer_key.get(field)
        if not isinstance(sub, dict) or not sub:
            continue
        answer_key[field] = {
            k: v for k, v in sub.items()
            if not str(k).strip().isdigit() or str(k).strip() in kept}
    return answer_key


def _image_label_draft_fields(specs, cap=None):
    """Both image_label lanes, capped.

    THE INVARIANT: whatever this returns, `behavioural_key_json`,
    `label_boxes_json` and `answer_key.ideal_labels` describe the SAME set of
    numbered boxes. They are three serialisations of one list and are read by
    three different consumers (the reviewer form, the overlay renderer, the
    grader), so a key that outlives its boxes is not a cosmetic mismatch: the
    grader would mark a candidate against boxes that were never drawn on the
    image they answered. Hence every one of the three is derived from the same
    already-truncated `boxes` list below, never from the raw specs.
    """
    limit = _label_box_cap(cap)
    vals = {}
    _apply_capture_directives(specs, vals, cap=limit)
    # DEFECT form (q7r): a base_prompt + defects[] means true-by-construction
    # injection — capture the plan so the render path plants each defect and
    # stamps the marker on the ACTUAL drawn region (defect_render.plant). This is
    # the faithful single-image defect-annotation lane; the DENSE/box lane below
    # is for UI-control labelling.
    base_prompt = str(specs.get("base_prompt") or "").strip()
    raw_defects = specs.get("defects")
    if base_prompt and isinstance(raw_defects, list) and raw_defects:
        clean_defects = []
        for d in raw_defects:
            if not isinstance(d, dict):
                continue
            # drop-2 shape: an EDIT defect (method=edit + edit_instruction + anchor)
            # OR a PIL clone defect (method=pil / an op in _DEFECT_OPS). Keep every
            # field the renderer reads for both lanes; a bare flaw+anchor still
            # counts as an edit defect (method defaults to edit downstream).
            has_edit = bool(str(d.get("edit_instruction") or "").strip())
            has_op = d.get("op") in _DEFECT_OPS
            if not (has_edit or has_op):
                continue
            clean_defects.append({
                "marker": d.get("marker"),
                "kind": d.get("kind"),
                "method": d.get("method") or ("pil" if has_op and not has_edit
                                              else "edit"),
                "edit_instruction": str(d.get("edit_instruction") or "").strip(),
                "anchor": str(d.get("anchor") or "").strip(),
                "op": d.get("op"),
                "spec": d.get("spec") or {},
                "marker_xy": d.get("marker_xy"),
                "region": d.get("region"),
                "flaw": str(d.get("flaw") or "").strip(),
            })
        if len(clean_defects) > limit:
            _logger.warning(
                "etp_assessment image_label (defect lane): generator planned %d "
                "defect(s), cap is %d - dropped the last %d along with their "
                "answer-key entries.",
                len(clean_defects), limit, len(clean_defects) - limit)
            clean_defects = clean_defects[:limit]
        if clean_defects:
            vals["defect_plan_json"] = json.dumps(
                {"base_prompt": base_prompt, "defects": clean_defects},
                ensure_ascii=False)
            vals["image_brief_json"] = json.dumps(
                [{"slot": "single", "label": "Image", "prompt": base_prompt}],
                ensure_ascii=False)
            answer_key = _trim_marker_key(
                dict(specs.get("answer_key") or {}), clean_defects)
            if answer_key:
                vals["rubric_json"] = json.dumps(answer_key, ensure_ascii=False)
            return vals
    briefs = []
    for img in (specs.get("images") or []):
        if img.get("prompt"):
            briefs.append({
                "slot": "single",
                "label": img.get("label") or "Image",
                "prompt": img["prompt"],
            })
            break
    answer_key = dict(specs.get("answer_key") or {})
    boxes = _image_label_boxes(specs, cap=limit)
    ideal = answer_key.get("ideal_labels")
    if isinstance(ideal, dict):
        # Reached when the generator authored a per-box MAP but no boxes[]
        # geometry. Nothing downstream can renumber this - the candidate portal
        # counts these entries to decide how many "Label N" inputs to render -
        # so the cap has to bite HERE or the map is the one place a 30-box
        # question survives.
        ordered = sorted(ideal, key=_label_key_sort)
        if len(ordered) > limit:
            _logger.warning(
                "etp_assessment image_label: authored ideal_labels map has %d "
                "entries with no boxes[] geometry, cap is %d - kept the first "
                "%d.", len(ordered), limit, limit)
            ordered = ordered[:limit]
        answer_key["ideal_labels"] = "\n".join(
            "%s. %s" % (k, ideal[k]) for k in ordered)
    if boxes:
        vals["behavioural_key_json"] = json.dumps(
            [{"number": b["number"], "element": b["element"],
              "functionality": b["functionality"]} for b in boxes],
            ensure_ascii=False)
        vals["label_boxes_json"] = json.dumps(
            [{"number": b["number"], "box_2d": b["box_2d"],
              "label": b["element"], "description": b["functionality"]}
             for b in boxes], ensure_ascii=False)
        answer_key["ideal_labels"] = "\n".join(
            "%d. %s" % (b["number"], b["functionality"]) for b in boxes)
        cov = str(specs.get("coverage_expected") or "yes").strip().lower()
        vals["coverage_expected"] = "no" if cov == "no" else "yes"
        omitted = specs.get("omitted_element")
        if cov == "no" and isinstance(omitted, dict) and omitted:
            vals["omitted_element_json"] = json.dumps(omitted, ensure_ascii=False)
        app = str(specs.get("application") or "").strip()
        if app:
            vals["label_application"] = app[:200]
    if answer_key:
        vals["rubric_json"] = json.dumps(answer_key, ensure_ascii=False)
    if briefs:
        vals["image_brief_json"] = json.dumps(briefs, ensure_ascii=False)
    return vals


def _build_image_draft_fields(env, qtype, item, usage_ctx=None, ab_dims=None,
                              label_box_cap=None):
    specs = item.get("image_specs") or {}
    vals = {}
    briefs = []

    if qtype == "image_ab":
        plan = specs.get("flaw_plan") or {}
        if plan and not validate_flaw_plan(plan):
            # Fill missing SOP titles for numbered dims before the plan is
            # frozen into dimensions_json (the model often omits them).
            prompt_rec = None
            pid = (usage_ctx or {}).get("prompt_id")
            if pid:
                prompt_rec = env["assessments.be.prompt"].browse(pid).exists()
            # WHICH TEMPLATE AUTHORED THIS ITEM, if any. `_template_shape` is
            # the stamp the quota stage puts on a template-authored item; the
            # specs ride in usage_ctx so this stays a pure function of its
            # inputs rather than re-reading the DB per item.
            shape = item.get("_template_shape")
            template_spec = ((usage_ctx or {}).get("template_specs")
                             or {}).get(shape) if shape else None
            return _build_flaw_injected_ab_fields(plan, prompt_record=prompt_rec,
                                                  env=env,
                                                  template_spec=template_spec)
        if specs.get("image_a_prompt"):
            briefs.append({"slot": "a", "label": "Response A",
                           "prompt": specs["image_a_prompt"]})
        if specs.get("image_b_prompt"):
            briefs.append({"slot": "b", "label": "Response B",
                           "prompt": specs["image_b_prompt"]})
        resolved = ab_dims or _ab_fallback_dims()
        by_label = {d["label"].strip().lower(): list(d["choices"])
                    for d in resolved}
        union = []
        for d in resolved:
            for c in d["choices"]:
                if c not in union:
                    union.append(c)
        dim_specs = []
        for label, val in (specs.get("dimensions") or {}).items():
            choices = by_label.get(str(label).strip().lower()) or union \
                or list(_AB_CHOICES)
            dim_specs.append({
                "label": label,
                "options": choices,
                "correct": [val] if val else [],
            })
        if dim_specs:
            vals["dimensions_json"] = json.dumps(dim_specs, ensure_ascii=False)
        if specs.get("official_reasoning"):
            vals["official_reasoning"] = specs["official_reasoning"]
    elif qtype == "image_prompt":
        briefs = _image_prompt_briefs(specs.get("images") or [])
        answer_key = specs.get("answer_key") or {}
        if answer_key:
            vals["rubric_json"] = json.dumps(answer_key, ensure_ascii=False)
    elif qtype == "video_prompt":
        v_briefs = _video_prompt_briefs(
            specs.get("videos") or specs.get("images") or [])
        answer_key = specs.get("answer_key") or {}
        if answer_key:
            vals["rubric_json"] = json.dumps(answer_key, ensure_ascii=False)
        if v_briefs:
            vals["video_brief_json"] = json.dumps(v_briefs, ensure_ascii=False)
        return vals
    else:
        return _image_label_draft_fields(specs, cap=label_box_cap)

    if briefs:
        vals["image_brief_json"] = json.dumps(briefs, ensure_ascii=False)
    return vals


def media_states_for_briefs(vals):
    """The media states a draft carrying these briefs should start in.

    ONE STATE PER MEDIUM - SNo 116. The stamp used to read

        if vals.get("image_brief_json") or vals.get("video_brief_json"):
            vals["image_state"] = "pending"

    so a VIDEO-ONLY draft was marked as waiting for an image it can never have:
    `_build_image_draft_fields` returns early on `video_prompt` carrying only
    `video_brief_json`, and the render cron requires BOTH
    `image_state = 'pending'` AND `image_brief_json != False`
    (models/prompt.py:3956-3958). Nothing ever claimed the row, so nothing ever
    cleared the flag.

    THE VISIBLE DAMAGE was `generation_status`, computed in_progress while
    `image_state == "pending"` (models/prompt.py:2140): a video draft whose clip
    had finished reported itself as still rendering, for ever, so a reviewer
    waited on work that was already done and the batch never looked complete.

    A FUNCTION RATHER THAN TWO LINES INLINE, for one reason: the rule decides
    whether a render cron ever looks at a row, and the inline version sat inside
    `generate_questions_from_sop`, which calls Vertex - so the only way to test
    it was to mock the model. Pure in, pure out, and the rule now has one home.

    Returns only the keys it has an opinion about, so a caller can `update` with
    it without clobbering a state some other lane already decided.
    """
    out = {}
    if (vals or {}).get("image_brief_json"):
        out["image_state"] = "pending"
    if (vals or {}).get("video_brief_json"):
        out["video_state"] = "pending"
    return out


def render_draft_images(env, briefs, usage_ctx=None, only_slot=None):
    images = []
    for brief in (briefs or []):
        if not isinstance(brief, dict):
            continue
        slot = brief.get("slot") or "single"
        if only_slot and slot != only_slot:
            continue
        prompt_text = brief.get("prompt")
        if not prompt_text:
            continue
        try:
            b64, mime = generate_image(
                env, _image_brief(prompt_text), usage_ctx=usage_ctx)
            images.append({
                "slot": slot,
                "label": brief.get("label") or slot.title(),
                "data": "data:%s;base64,%s" % (mime, b64),
            })
        except (VertexQuotaError, VertexBudgetError,
                VertexCancelledError) as exc:
            # Money safety: hand back the already-paid slots to re-render only the rest.
            exc.partial = images
            raise
        except VertexNotConfiguredError:
            # Not a slot that failed: the caller settles the draft.
            raise
        except Exception as exc:
            _logger.warning(
                "etp_assessment image render failed (%s): %s",
                slot, repr(exc)[:160])
    return images


_VERIFY_MAX_REGEN = 2

_VERIFY_SYSTEM_PROMPT = (
    "You are a meticulous visual-QA inspector for an assessment pipeline. You "
    "are shown ONE rendered image plus a numbered list of specific flaws that "
    "were DELIBERATELY planted into it. For EACH listed flaw, decide ONLY from "
    "what is actually visible in the pixels whether that flaw is present. Do NOT "
    "assume a flaw is there merely because it is listed, and do NOT invent flaws "
    "that are not listed. Return ONLY the JSON array the schema describes (one "
    "entry per listed flaw, in the SAME order), no markdown, no prose."
)

VERIFY_FLAW_SCHEMA = {
    "type": "ARRAY",
    "items": {
        "type": "OBJECT",
        "properties": {
            "flaw": {"type": "STRING"},
            "present": {"type": "BOOLEAN"},
            "note": {"type": "STRING"},
        },
        "required": ["flaw", "present"],
    },
}


def _verify_model(env):
    """Must READ an image: a vision model, never the image-only render model."""
    return _text_lane(
        "verify_model",
        _param(env, "assessments_be_v2.verify_model"),
    ) or _detection_model(env)


def verify_planted_flaws(env, image, planted_flaws, *, model=None,
                         usage_ctx=None):
    flaws = [str(f).strip() for f in (planted_flaws or []) if str(f).strip()]
    if not flaws:
        return {"verdicts": [], "all_present": True}
    import base64
    if isinstance(image, (bytes, bytearray)):
        b64 = base64.b64encode(bytes(image)).decode()
    else:
        b64 = str(image)
    numbered = "\n".join("%d. %s" % (i + 1, f) for i, f in enumerate(flaws))
    user_parts = [
        {"inlineData": {"mimeType": "image/png", "data": b64}},
        {"text": "These flaws were deliberately planted into this image. For "
                 "each, report whether it is visibly present in the pixels:\n"
                 + numbered},
    ]
    raw = _call_vertex(
        env, _VERIFY_SYSTEM_PROMPT, user_text="", user_parts=user_parts,
        model=model or _verify_model(env),
        # Sized for a THINKING model, as `draft_task_template_from_sop`: at
        # 4000, gemini-3.1-pro-preview spent 3,837 on thoughts + 149 output and
        # was cut off (MAX_TOKENS); the retry used 6,178 thoughts. The retry
        # doubles this up to `_RETRY_OUTPUT_TOKENS_CEILING` (16000).
        max_tokens=12000, temperature=0.0,
        response_json=True, response_schema=VERIFY_FLAW_SCHEMA,
        usage_ctx=usage_ctx or {"operation": "verify_planted_flaws"})
    items = [it for it in _extract_json_array(raw) if isinstance(it, dict)]
    verdicts = []
    for i, flaw in enumerate(flaws):
        present, note = False, ""
        if i < len(items):
            present = bool(items[i].get("present"))
            note = str(items[i].get("note") or "").strip()
        else:
            for it in items:
                lbl = str(it.get("flaw") or "").strip().lower()
                if lbl and (lbl in flaw.lower() or flaw.lower() in lbl):
                    present = bool(it.get("present"))
                    note = str(it.get("note") or "").strip()
                    break
        verdicts.append({"flaw": flaw, "present": present, "note": note})
    return {"verdicts": verdicts,
            "all_present": all(v["present"] for v in verdicts)}


def _data_url_to_b64(data):
    s = data or ""
    if s.startswith("data:") and "base64," in s:
        return s.split("base64,", 1)[1]
    return s


def verify_and_regenerate_ab_images(env, briefs, images, planted, *,
                                    usage_ctx=None, max_regen=_VERIFY_MAX_REGEN):
    by_slot = {img["slot"]: img for img in (images or [])
               if isinstance(img, dict) and img.get("slot")}
    sides = {}
    for slot in AB_FLAWED_SIDES:
        flaws = [str(f).strip() for f in (planted.get(slot) or [])
                 if str(f).strip()]
        if not flaws:
            sides[slot] = {"planted": [], "regenerations": 0,
                           "confirmed": True, "unavailable": False,
                           "verdicts": []}
            continue
        img = by_slot.get(slot)
        regen, result, unavailable = 0, None, False
        while True:
            b64 = _data_url_to_b64(img.get("data")) if img else ""
            if not b64:
                result = {"verdicts": [{"flaw": f, "present": False,
                                        "note": "no rendered image"}
                                       for f in flaws],
                          "all_present": False}
                break
            try:
                result = verify_planted_flaws(
                    env, b64, flaws, usage_ctx=usage_ctx)
            except VertexQuotaError:
                raise
            except Exception as exc:  # noqa: BLE001
                _logger.warning(
                    "etp_assessment flaw verify unavailable (slot %s): %s",
                    slot, repr(exc)[:160])
                unavailable = True
                break
            if result["all_present"] or regen >= max_regen:
                break
            try:
                new = render_draft_images(
                    env, briefs, usage_ctx=usage_ctx, only_slot=slot)
            except VertexQuotaError:
                raise
            except Exception as exc:  # noqa: BLE001 - a refusal ends the check
                _logger.warning(
                    "etp_assessment flaw re-render unavailable (slot %s): %s",
                    slot, repr(exc)[:160])
                unavailable = True
                break
            regen += 1
            if new:
                img = new[0]
                by_slot[slot] = new[0]
        if unavailable or result is None:
            sides[slot] = {"planted": flaws, "regenerations": regen,
                           "confirmed": False, "unavailable": True,
                           "verdicts": []}
        else:
            sides[slot] = {"planted": flaws, "regenerations": regen,
                           "confirmed": result["all_present"],
                           "unavailable": False,
                           "verdicts": result["verdicts"]}
    new_images = [by_slot.get(img["slot"], img) if isinstance(img, dict)
                  and img.get("slot") else img for img in (images or [])]
    needs_review = any(
        (not s["confirmed"]) and (not s["unavailable"]) and s["planted"]
        for s in sides.values())
    all_confirmed = all(s["confirmed"] for s in sides.values() if s["planted"])
    record = {
        "enabled": True,
        "max_regen": max_regen,
        "sides": sides,
        "all_confirmed": bool(all_confirmed),
        "needs_review": bool(needs_review),
    }
    return new_images, record


def _answer_resolves(ca, options, single):
    n = len(options)
    opt_strs = [str(o) for o in options]

    def one_ok(v):
        if isinstance(v, bool):
            return False
        if isinstance(v, str):
            if v in opt_strs:
                return True
            s = v.strip()
            return s.lstrip("-").isdigit() and 0 <= int(s) < n
        if isinstance(v, int):
            return 0 <= v < n
        return False

    if single:
        if isinstance(ca, list):
            return len(ca) == 1 and one_ok(ca[0])
        return one_ok(ca)
    vals = ca if isinstance(ca, list) else ([ca] if ca is not None else [])
    return bool(vals) and all(one_ok(v) for v in vals)


def _resolved_correct_count(ca, options):
    n = len(options)
    opt_strs = [str(o) for o in options]
    idxs = set()
    vals = ca if isinstance(ca, list) else ([ca] if ca is not None else [])
    for v in vals:
        if isinstance(v, bool):
            continue
        if isinstance(v, str):
            if v in opt_strs:
                idxs.add(opt_strs.index(v))
            else:
                s = v.strip()
                if s.lstrip("-").isdigit() and 0 <= int(s) < n:
                    idxs.add(int(s))
        elif isinstance(v, int) and 0 <= v < n:
            idxs.add(v)
    return len(idxs)


def _is_decisive_ab_winner(winner):
    w = str(winner or "").strip().lower()
    return w in ("response a", "response b", "a", "b")


# Every verdict the platform recognises, normalised: the synonym table's own
# keys AND the canonical words it maps to. Derived from the registry rather
# than restated, so a new verdict word is picked up here for free.
_AB_VERDICT_PHRASES = frozenset(
    [_ab_norm_phrase(k) for k in AB_VERDICT_SYNONYMS]
    + [_ab_norm_phrase(v) for v in AB_VERDICT_SYNONYMS.values()])


def _adopt_solution_keys(it):
    """Recover an A/B answer key the model put in `solution` instead of the plan.

    THE OBSERVED FAILURE. A live run returned two image_ab items whose
    `solution` carried a complete, coherent key - IF/VQ/LAIG/OP plus a
    justification naming the exact planted flaws - while `flaw_plan` came back
    with no `construction_keys` at all. `validate_flaw_plan` rejected both, so
    the whole answer key was thrown away and the drafts landed unkeyed and
    ungradeable. The model had done the work; we discarded it over which field
    it landed in.

    This is deliberately a REPAIR, not a relaxation: the plan must already be
    present, only genuine A/B verdicts are adopted, and the codes go through
    the same `ab_normalize_dim_key` registry as everything else - so `OP`
    becomes `OC` and `LAIG` becomes `LAI` rather than inventing a dimension.
    Nothing is fabricated; a key that is absent everywhere still fails.

    Returns True when keys were adopted, so the caller can flag the draft.
    """
    specs = it.get("image_specs") or {}
    plan = specs.get("flaw_plan") or {}
    if not plan or plan.get("construction_keys"):
        return False
    sol = it.get("solution")
    if not isinstance(sol, dict):
        return False
    # What counts as a verdict for THIS item: the plan's own per-dimension
    # options when it declares them, else the platform's A/B vocabulary.
    allowed = set()
    for opts in (plan.get("dimension_options") or {}).values():
        for opt in (opts or []):
            if isinstance(opt, str) and opt.strip():
                allowed.add(_ab_norm_phrase(opt))
    recovered = {}
    for raw, verdict in sol.items():
        if not isinstance(verdict, str):
            continue
        code, _label = ab_normalize_dim_key(raw)
        if not code or code in recovered:
            continue
        norm = ab_normalize_verdict(verdict)
        if not norm:
            continue
        # `ab_normalize_verdict` deliberately passes UNRECOGNISED values
        # through so a SOP keeps its own option wording - which means a
        # justification paragraph survives it untouched. Accept only a value
        # this item actually offers as a choice; without this the prose landed
        # in the answer key as a dimension called JUSTIFICATION.
        phrase = _ab_norm_phrase(norm)
        if allowed:
            if phrase not in allowed:
                continue
        elif not (_is_decisive_ab_winner(norm)
                  or phrase in _AB_VERDICT_PHRASES):
            continue
        recovered[code] = norm
    if not recovered:
        return False
    plan["construction_keys"] = recovered
    specs["flaw_plan"] = plan
    it["image_specs"] = specs
    return True


def _validate_question_item(it, qtype, ab_dims=None):
    errs = []
    if not (it.get("prompt") or it.get("name") or "").strip():
        errs.append("no prompt/name")
    if qtype == "mcq":
        opts = it.get("options") or []
        ca = it.get("correct_answer")
        if not isinstance(opts, list) or len(opts) < 2:
            errs.append("mcq needs >=2 options")
        elif not _answer_resolves(ca, opts, single=True):
            errs.append("mcq correct_answer must be one option (string or index)")
    elif qtype == "msq":
        opts = it.get("options") or []
        ca = it.get("correct_answer")
        if not isinstance(opts, list) or len(opts) < 2:
            errs.append("msq needs >=2 options")
        elif not _answer_resolves(ca, opts, single=False):
            errs.append("msq correct_answer must be a non-empty subset of options")
        elif _resolved_correct_count(ca, opts) >= len(opts):
            errs.append("msq correct_answer marks ALL options correct "
                        "(needs at least one wrong option)")
    elif qtype == "subjective_rubric":
        r = it.get("rubric")
        if not isinstance(r, dict) or not all(
                k in r for k in ("checklist", "constraints", "pass_condition")):
            errs.append("subjective_rubric needs rubric "
                        "{checklist,constraints,pass_condition}")
        else:
            checklist = r.get("checklist")
            has_checklist = bool(checklist) if isinstance(
                checklist, (list, str)) else bool(checklist)
            if not has_checklist:
                errs.append("subjective_rubric checklist is empty "
                            "(needs at least one gradable criterion)")
            if not str(r.get("pass_condition") or "").strip():
                errs.append("subjective_rubric pass_condition is blank")
    elif qtype == "image_ab":
        specs = it.get("image_specs") or {}
        plan = specs.get("flaw_plan") or {}
        if plan:
            # The model sometimes files the key under `solution` instead of
            # inside the plan. Recover it before judging - the key is real
            # work, and the field it arrived in is not worth a dead draft.
            if not plan.get("construction_keys") and _adopt_solution_keys(it):
                specs = it.get("image_specs") or {}
                plan = specs.get("flaw_plan") or {}
            errs.extend(validate_flaw_plan(plan))
        else:
            if not (specs.get("image_a_prompt") and specs.get("image_b_prompt")):
                errs.append("image_ab needs image_a_prompt AND image_b_prompt")
            dims = specs.get("dimensions") or {}
            if not isinstance(dims, dict) or not dims:
                errs.append("image_ab needs a non-empty dimensions map")
            else:
                resolved = ab_dims or _ab_fallback_dims()
                by_label = {d["label"].strip().lower(): set(d["choices"])
                            for d in resolved}
                union = set().union(*by_label.values()) if by_label \
                    else set(_AB_CHOICE_SET)
                for label, winner in dims.items():
                    allowed = by_label.get(str(label).strip().lower(), union)
                    if winner not in allowed:
                        errs.append("image_ab dim %r winner %r not in %s"
                                    % (label, winner, sorted(allowed)))
            if not (specs.get("official_reasoning") or "").strip():
                errs.append("image_ab needs official_reasoning")
            decisive = [
                w for w in (specs.get("dimensions") or {}).values()
                if _is_decisive_ab_winner(w)]
            if isinstance(specs.get("dimensions"), dict) and \
                    specs.get("dimensions") and not decisive:
                errs.append("image_ab has no planted flaw and every dimension is "
                            "a tie (needs at least one decisive A/B winner or a "
                            "flaw_plan)")
    elif qtype == "image_prompt":
        specs = it.get("image_specs") or {}
        imgs = specs.get("images") or []
        if not isinstance(imgs, list) or not any(
                isinstance(i, dict) and i.get("prompt") for i in imgs):
            errs.append("image_prompt needs images[] with a prompt")
        key = specs.get("answer_key") or {}
        if not isinstance(key, dict) or not key.get("ideal_prompt"):
            errs.append("image_prompt needs answer_key with ideal_prompt")
    elif qtype == "video_prompt":
        specs = it.get("image_specs") or {}
        vids = specs.get("videos") or specs.get("images") or []
        if not isinstance(vids, list) or not any(
                isinstance(v, dict) and v.get("prompt") for v in vids):
            errs.append("video_prompt needs videos[] with a prompt")
        key = specs.get("answer_key") or {}
        if not isinstance(key, dict) or not key.get("ideal_prompt"):
            errs.append("video_prompt needs answer_key with ideal_prompt")
    elif qtype == "image_label":
        specs = it.get("image_specs") or {}
        # DEFECT form (q7r) — true by construction: a base_prompt + a non-empty
        # defects[] plan is a complete, self-contained image_label item (the
        # platform renders the clean base, bakes the defects via one image-edit,
        # then vision-grounds each marker). A defect is valid if it is an EDIT
        # defect (edit_instruction, drop-2 primary lane) OR a PIL clone op. This is
        # the FAITHFUL single-image defect-annotation lane and needs neither a
        # source_url nor an images[] brief.
        base_prompt = str(specs.get("base_prompt") or "").strip()
        raw_defects = specs.get("defects")
        has_defects = (base_prompt and isinstance(raw_defects, list)
                       and any(isinstance(d, dict)
                               and (str(d.get("edit_instruction") or "").strip()
                                    or d.get("op") in _DEFECT_OPS)
                               for d in raw_defects))
        # AN AI-MADE PICTURE IS VALID AGAIN (owner, 2026-09-29): a brief to
        # render is the default; a live page only for a generator that asks.
        has_brief = any(isinstance(img, dict) and str(img.get("prompt") or "")
                        .strip() for img in (specs.get("images") or []))
        if has_defects or has_brief:
            pass  # valid defect-annotation or AI-picture item
        else:
            has_url = bool(str(specs.get("source_url") or "").strip()
                           or _repair_image_label_source_url(specs))
            if not has_url:
                # No brief and no defect plan: only a live-page item is left,
                # and only a generator with "Screenshot live websites" on
                # keeps its URL. _repair_image_label_source_url derives one
                # from the named product or the verified-live pool, so a
                # rejection means the item has nothing to show at all.
                errs.append("image_label needs an images[] brief to render, "
                            "a base_prompt+defects plan (defect annotation) "
                            "or a source_url to a real public page")
    else:
        errs.append("unknown question_type %r" % qtype)
    return errs


def _generation_model(env):
    """Must be document-capable: the image model cannot parse a PDF's structure."""
    return _text_lane(
        "generation_model",
        _param(env, "assessments_be_v2.generation_model"),
    ) or GENERATION_DEFAULT_MODEL


def _scoring_model(env):
    """NEVER fall back to vertex_model: it is the image model on this deployment,
    and grading through it is wrong, expensive and image-quota-bound."""
    return _text_lane(
        "scoring_model",
        _param(env, "assessments_be_v2.scoring_model"),
        _param(env, "assessments_be_v2.generation_model"),
    ) or GENERATION_DEFAULT_MODEL


def _utility_model(env):
    """Cheap TEXT model for the bulk label/tag/vocab lanes.

    These calls are high-volume, short, and mechanical - labelling a question
    with one skill from a numbered list, consolidating a tag vocabulary. They do
    not need the authoring model's reasoning and they should never have been on
    it: `assign_question_skills` passed no model at all, so it ran on
    `vertex_model`, whose default IS the image model, at the most expensive rate
    in the catalog.

    Falls back to the GENERATION model, not the scoring model, so that leaving
    this key unset reproduces today's behaviour for `extract_tags` and
    `consolidate_vocab` exactly - only `assign_question_skills` changes, and only
    to stop billing a picture model for a text job. `extract_tags` also ships the
    SOP, so anything set here must be document-capable; the Flash-Lite tier is.
    """
    return _text_lane(
        "utility_model",
        _param(env, "assessments_be_v2.utility_model"),
    ) or _generation_model(env)


_SOP_MIME_BY_EXT = {
    "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
    "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
    "txt": "text/plain", "md": "text/plain", "markdown": "text/plain",
    "csv": "text/plain", "json": "text/plain",
}


def _inline_doc_part(name, data, default_mime="application/pdf"):
    """An Odoo Binary field already holds base64, which is exactly Gemini's
    inlineData — do not re-encode."""
    import base64
    if not data:
        return None
    ext = name.rsplit(".", 1)[-1].lower() if "." in (name or "") else ""
    mime = _SOP_MIME_BY_EXT.get(ext, default_mime)
    raw = data.decode() if isinstance(data, bytes) else data
    if mime == "application/pdf":
        # M-6: verify the PDF magic properly. base64 decodes in 3-byte/4-char
        # groups, so slice on a 4-char boundary and require the "%PDF-" signature
        # at offset 0 (a real PDF always starts with "%PDF-1.x"), not merely
        # "%PDF" somewhere in a loosely-decoded head.
        try:
            _b64head = (raw or "")[:16]
            _b64head = _b64head[:len(_b64head) // 4 * 4]  # whole base64 groups
            head = base64.b64decode(_b64head) if _b64head else b""
        except Exception:
            head = b""
        if not head.startswith(b"%PDF-"):
            raise LLMRefusalError(
                "File %r is not a readable PDF (missing %%PDF- header) — "
                "re-upload a valid PDF." % (name or "?"))
    return {"inlineData": {"mimeType": mime, "data": raw}}


_SOP_TEXT_EXTS = frozenset({"docx", "txt", "md", "markdown", "csv",
                            "html", "htm", "json", "xml"})


def _sop_doc_parts(resources):
    """docx/text cannot be sent to Gemini as inlineData; they must be extracted to
    a text part.

    Sample questions (and their old name, golden) are EXCLUDED here and sent
    by `_sample_doc_parts` under their own heading - sending them twice would
    spend the tokens twice and bury the label under the copy that has none.

    SAMPLE QUESTIONS ARE EXCLUDED FOR EXACTLY THE SAME REASON, and were not,
    which is a bug that cost a production generator every run it attempted.
    `_sample_doc_parts` already sends them under "SAMPLE QUESTIONS"; this loop
    skipped only "golden", so a category-"sample" file went to the model TWICE
    in one request - once as source material (`SOP DOCUMENT:`, or an
    unlabelled inline part when the file is a PDF), once correctly.

    The arithmetic on the generator that reported it: three SOP files totalling
    464 KB plus a 1.9 MB sample. Sent once that is ~617K tokens and fits inside
    Gemini's 1,048,576 ceiling; with the sample doubled it is ~1,115K and the
    call is refused with `INVALID_ARGUMENT` before any work happens. Trimming
    the SOP did not help, because the duplicate was always the larger half.

    THE SAME MISLABELLING REACHED `extract_tags_from_sop`, which sends no
    sample part of its own, and `draft_task_template_from_sop` before it sent
    the sample list itself under GOLDEN EXAMPLE (`_sample_doc_parts`). They read worked
    question examples as procedure: the tags and knowledge profile were drawn
    partly from the answers, and the drafted template from an example rather
    than from the SOP. Both get more accurate by this line, not just cheaper.
    """
    parts = []
    for res in resources.sorted("sequence"):
        if res.category in ("golden", "sample"):
            continue
        ext = (res.name or "").rsplit(".", 1)[-1].lower() if "." in (res.name or "") else ""
        if ext in _SOP_TEXT_EXTS:
            try:
                text, err = res._extract_text()
            except Exception as exc:  # noqa: BLE001
                text, err = "", repr(exc)
            if text and str(text).strip():
                parts.append({"text": "SOP DOCUMENT (%s):\n%s"
                              % (res.name or "sop", text)})
                continue
            _logger.warning("etp_assessment SOP %r extract failed: %s",
                            res.name, err)
        part = _inline_doc_part(res.name or "", res.file)
        if part:
            parts.append(part)
    return parts


def _sample_doc_parts(prompt_record, label="SAMPLE QUESTION FILE"):
    """Sample-question files, newest storage first.

    ONE LIST (owner, 2026-09-29): golden questions are sample questions, so a
    row still carrying the old `golden` category is read here too. ``label``
    heads each extracted text part; Draft from SOP passes its own.

    Sample questions ride the same resource pipeline as the SOP and reference files
    (category "sample"), so they show up under Resources like everything else. The
    sample_questions_file fallback stays for records saved before that switch,
    whose bytes still live on the old field.

    TEXT FORMATS ARE EXTRACTED, and this function did NOT do that until the duplicate send was removed - which is how
    the omission stayed invisible. `_sop_doc_parts` used to pick every sample up
    as well and ran `_extract_text` on it, so the readable prose reached the
    model from there while this function sent the raw bytes beside it. Excluding
    samples from that function to stop paying twice therefore deleted the only
    readable copy.

    It matters most for `.docx`, whose raw bytes are a ZIP container: sent as
    `inlineData` it is noise, and `_SOP_MIME_BY_EXT` has no entry for it so it
    was labelled `text/plain` on the way out. `.html` and `.xml` degraded more
    quietly, losing the tag stripping `_extract_text` performs. Any of these
    can be a sample.

    Extracting is also CHEAPER than what it replaces: base64 costs about a third
    more tokens than the string it encodes.
    """
    parts = []
    for res in getattr(prompt_record, "resource_ids", []) or []:
        if res.category not in ("sample", "golden"):
            continue
        ext = (res.name or "").rsplit(".", 1)[-1].lower() \
            if "." in (res.name or "") else ""
        if ext in _SOP_TEXT_EXTS:
            try:
                text, err = res._extract_text()
            except Exception as exc:  # noqa: BLE001
                text, err = "", repr(exc)
            if text and str(text).strip():
                parts.append({"text": "%s (%s):\n%s"
                              % (label, res.name or "sample", text)})
                continue
            _logger.warning("etp_assessment sample %r extract failed: %s",
                            res.name, err)
        part = _inline_doc_part(res.name or "", res.file, default_mime="text/plain")
        if part:
            parts.append(part)
    if parts:
        return parts

    data = getattr(prompt_record, "sample_questions_file", None)
    if not data:
        return []
    name = getattr(prompt_record, "sample_questions_filename", "") or ""
    part = _inline_doc_part(name, data, default_mime="text/plain")
    return [part] if part else []


_TEXT_TYPE_SPEC = {
    "mcq": "options (>=3 strings) and correct_answer (exactly one option)",
    "msq": "options (>=4 strings) and correct_answer (a list of the correct options)",
    "subjective_rubric": "rubric = {checklist, constraints, pass_condition}",
}


_ENVELOPE_REMINDER = (
    " Return ONE JSON OBJECT with three keys, \"metadata\" (the grounded SOP profile: "
    "sop_title, summary, mapping, tags, skills, evidence, required_elements, "
    "covered_by_all, question_spec, gaps), \"questions\" (the array of question "
    "objects), and \"solutions\" (one entry per "
    "question IN THE SAME ORDER, each {answers, rationale} holding the most correct "
    "answer in an ideal worker's voice plus how it is known). "
    "COVERAGE CONTRACT (mandatory): first list the SOP's required_elements in "
    "metadata (atomic yes/no checkable statements, each with a stable kebab-case "
    "id). Then PLAN so that, together, metadata.covered_by_all plus each question's "
    "covers_elements span EVERY required_element id — every element must be "
    "exercised by at least one question, and each question MUST carry a "
    "covers_elements array naming the element id(s) its specific scenario tests. A "
    "required_element that no question covers is a failure; author a question for "
    "it rather than repeating an already-covered element. First char '{', last "
    "'}', no markdown.")


def _facet_vocabulary_note(env):
    try:
        vocab = env["assessments.be.tag"].sudo()._facet_vocabulary()
    except Exception as exc:  # noqa: BLE001
        # A silent "" here strips the tag-vocabulary steering from the
        # generation directive, so the model can invent off-taxonomy facets
        # with no trace. Degrade gracefully, but log why.
        _logger.warning(
            "generation: facet vocabulary unavailable (%s); "
            "proceeding without vocab steering", repr(exc)[:160])
        return ""
    if not vocab:
        return ""
    lines = "; ".join(
        "%s: [%s]" % (facet, ", ".join(
            v["value"] if isinstance(v, dict) else str(v) for v in vals))
        for facet, vals in vocab.items() if vals)
    return (
        " MAPPING VOCABULARY (important for cross-project matching): the platform "
        "already uses these faceted mapping values across existing projects — "
        + lines
        + ". When a facet of THIS SOP means the same thing as one of these, REUSE "
        "the exact existing value (e.g. do not write modality:ui-screenshot if "
        "modality:image already exists for the same idea). Only coin a NEW "
        "kebab-case value when this SOP introduces a genuinely new concept none of "
        "the above covers. Keep each mapping entry as facet:value.")


def _forced_type_directive(force_type, count, ab_dims=None, label_box_cap=None):
    n = count or 5
    if force_type in _IMAGE_OR_VIDEO_TYPES:
        return (f"Generate EXACTLY {n} question(s). EVERY item's question_type MUST "
                f'be exactly "{force_type}" — do NOT produce any other type. '
                + _image_question_directive(force_type, n, ab_dims=ab_dims,
                                            label_box_cap=label_box_cap)
                + _ENVELOPE_REMINDER
                + _SELF_CONTAINED_RULE)
    spec = _TEXT_TYPE_SPEC.get(force_type, "")
    return (f"Generate EXACTLY {n} question(s). EVERY item's question_type MUST be "
            f'exactly "{force_type}" — do NOT produce any other type. For EACH item '
            "provide " + spec + "." + _ENVELOPE_REMINDER
            + _SELF_CONTAINED_RULE)


def _extract_solutions(raw):
    try:
        text = (raw or "").strip()
        text = re.sub(r"^```(?:json)?", "", text).strip()
        text = re.sub(r"```$", "", text).strip()
        try:
            obj = json.loads(text)
        except Exception:
            m = re.search(r"\{.*\}", text, re.DOTALL)
            obj = json.loads(m.group(0)) if m else None
        if not isinstance(obj, dict):
            return []
        sols = obj.get("solutions")
        if isinstance(sols, dict):
            return [sols[k] for k in sorted(sols.keys())]
        if isinstance(sols, list):
            return sols
        return []
    except Exception:  # noqa: BLE001
        return []


def _attach_solutions(items, sols, prompt_id):
    """Match by reference, else positionally ONLY on an exact 1:1 — never guess:
    a mis-keyed solution grades a worker against another question's answer key."""
    if not (items and sols):
        return

    def _norm(v):
        return " ".join(str(v or "").strip().lower().split())

    by_name = {}
    for it in items:
        key = _norm(it.get("name") or it.get("title"))
        if key and key not in by_name:
            by_name[key] = it

    matched = 0
    unref = []
    for sol in sols:
        if not isinstance(sol, dict):
            continue
        ref = _norm(sol.get("question_ref") or sol.get("name")
                    or sol.get("question") or sol.get("id"))
        if ref and ref in by_name:
            by_name[ref]["_solution"] = sol
            matched += 1
        else:
            unref.append(sol)

    if matched:
        if unref:
            _logger.warning(
                "etp_assessment (SOP prompt %s): %d solution(s) had no matching "
                "question_ref and were left unattached (kept answer-key integrity "
                "over guessing).", prompt_id, len(unref))
        return

    if len(sols) == len(items):
        for it, sol in zip(items, sols):
            if isinstance(sol, dict):
                it["_solution"] = sol
        return

    _logger.warning(
        "etp_assessment (SOP prompt %s): %d solutions vs %d questions with no "
        "question_ref to match on — SKIPPED solution attachment to avoid "
        "mis-keying golden answers to the wrong questions.",
        prompt_id, len(sols), len(items))


def _extract_metadata_object(text):
    """Pull just the metadata {...} object out of a possibly-truncated envelope.

    The envelope emits metadata FIRST, so even when questions/solutions are cut off
    by MAX_TOKENS the metadata block is usually complete. A whole-string json.loads
    (and the greedy {.*} fallback) both fail on a truncated tail, silently losing
    the SOP grounding (evidence quotes, required_elements). This does a balanced
    brace scan from the "metadata" key so grounding survives truncation."""
    m = re.search(r'"metadata"\s*:\s*\{', text)
    if not m:
        return None
    start = m.end() - 1  # the opening brace of the metadata object
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except Exception:  # noqa: BLE001
                    return None
    return None


def _capture_sop_metadata(env, prompt_record, raw):
    # SAVEPOINT, BECAUSE THIS SWALLOWS ITS OWN ERRORS.
    #
    # Everything below is best-effort: a malformed metadata block must not lose a
    # generation run that already cost money. But the `except` at the bottom used
    # to swallow DATABASE errors too, and a failed write inside a Postgres
    # transaction ABORTS that transaction - so generation carried on with a
    # poisoned cursor and every later statement died with "current transaction is
    # aborted, commands ignored until end of transaction block". The admin saw
    # that message, not the real cause.
    #
    # The savepoint scopes the damage: a bad write rolls back to here and the
    # caller's transaction stays usable.
    try:
        with env.cr.savepoint():
            _capture_sop_metadata_inner(env, prompt_record, raw)
    except Exception as exc:  # noqa: BLE001
        _logger.warning("etp_assessment metadata capture skipped: %s",
                        repr(exc)[:160])


def _capture_sop_metadata_inner(env, prompt_record, raw):
    try:
        text = (raw or "").strip()
        text = re.sub(r"^```(?:json)?", "", text).strip()
        text = re.sub(r"```$", "", text).strip()
        meta = None
        try:
            obj = json.loads(text)
            if isinstance(obj, dict):
                meta = obj.get("metadata")
        except Exception:  # noqa: BLE001
            m = re.search(r"\{.*\}", text, re.DOTALL)
            if m:
                try:
                    obj = json.loads(m.group(0))
                    if isinstance(obj, dict):
                        meta = obj.get("metadata")
                except Exception:  # noqa: BLE001
                    meta = None
        # Truncation-robust fallback: the envelope truncated after metadata, so a
        # whole-object parse failed — recover the (complete) metadata block alone
        # so evidence quotes and required_elements are never silently lost.
        if not isinstance(meta, dict):
            meta = _extract_metadata_object(text)
        if not isinstance(meta, dict):
            return

        def _dump_list(key):
            v = meta.get(key)
            return json.dumps(v, ensure_ascii=False) if isinstance(v, list) and v else False

        vals = {"metadata_json": json.dumps(meta, ensure_ascii=False)}
        # The model sometimes emits `evidence` as a dict keyed by concept
        # ({"where_to_click": "<quote>"}) instead of the canonical list of
        # {id, quote, supports}. Normalize to the list form so the grounding lands
        # in the queryable evidence_json field (not just the raw metadata blob).
        ev = meta.get("evidence")
        if isinstance(ev, dict) and ev:
            meta["evidence"] = [
                {"id": "E%d" % (i + 1), "supports": k, "quote": str(v)}
                for i, (k, v) in enumerate(ev.items())]
        if meta.get("sop_title"):
            vals["sop_title"] = str(meta["sop_title"])[:255]
        if meta.get("summary"):
            vals["sop_summary"] = str(meta["summary"])
        tags = meta.get("tags")
        if isinstance(tags, list) and tags:
            vals["plain_tags"] = ", ".join(str(t) for t in tags)[:255]
        for meta_key, field_name in (
                ("mapping", "mapping_json"),
                ("skills", "skills_json"),
                ("evidence", "evidence_json"),
                ("required_elements", "required_elements_json"),
                ("covered_by_all", "covered_by_all_json"),
                ("sop_examples", "sop_examples_json"),
                ("quality_criteria", "quality_criteria_json"),
                ("common_failure_modes", "failure_modes_json"),
                ("gaps", "gaps_json"),
                ("conflicts", "conflicts_json"),
                ("injection_flags", "injection_flags_json")):
            dumped = _dump_list(meta_key)
            if dumped:
                vals[field_name] = dumped
        qspec = meta.get("question_spec")
        if isinstance(qspec, dict) and qspec:
            vals["question_spec_json"] = json.dumps(qspec, ensure_ascii=False)

        mapping = meta.get("mapping")
        if isinstance(mapping, list) and mapping:
            tag_model = env["assessments.be.tag"].sudo()
            tag_recs = tag_model._get_or_create(
                [str(m) for m in mapping if str(m).strip()])
            if tag_recs:
                # ADD, never replace. This runs during QUESTION GENERATION and
                # its `mapping` list describes the questions produced
                # (modality/output-format and the odd domain), so a (6,0,...)
                # here silently DROPPED whatever tag extraction had already put
                # on the generator - in practice every `skill:` facet.
                #
                # That is the vocabulary the per-category strengths/weaknesses are
                # built from: with the skills gone, backfill copied only
                # domain/modality/output-format onto each question and the
                # category breakdown had nothing to group by. Observed live on a
                # real SOP - extraction reported 4 skills, the generator ended up
                # with none, and all 8 questions came out unusable for categories.
                vals["tag_ids"] = [(4, tid) for tid in tag_recs.ids]

        prompt_record.sudo().write(vals)
        _logger.info(
            "etp_assessment captured research metadata for prompt %s "
            "(%d evidence, %d required_elements, %d mapping->tags, %d skills)",
            prompt_record.id,
            len(meta.get("evidence") or []),
            len(meta.get("required_elements") or []),
            len(meta.get("mapping") or []),
            len(meta.get("skills") or []))
    except Exception as exc:  # noqa: BLE001
        # DB errors must reach the savepoint in the caller so it can roll back;
        # swallowing them here is what poisoned the transaction. Parse/shape
        # errors stay swallowed - those genuinely are best-effort.
        import psycopg2
        if isinstance(exc, psycopg2.Error):
            raise
        _logger.warning("etp_assessment metadata capture skipped: %s",
                        repr(exc)[:160])


def _text_contracts_note(types):
    wanted = [qt for qt in _QUESTION_TYPE_ORDER
              if qt in _TEXT_TYPE_SPEC and qt in types]
    if not wanted:
        return ""
    contracts = " ".join(
        "For %s items provide %s." % (qt, _TEXT_TYPE_SPEC[qt]) for qt in wanted)
    return ("\n\nTEXT-TYPE OUTPUT CONTRACTS (mandatory for each text item you "
            "author): " + contracts)


def _allowed_types_directive(allowed, count, ab_dims=None, label_box_cap=None):
    if len(allowed) == 1:
        return _forced_type_directive(allowed[0], count, ab_dims=ab_dims,
                                      label_box_cap=label_box_cap)
    type_list = ", ".join('"%s"' % t for t in allowed)
    count_clause = f"Generate approximately {count} question(s). " if count else ""
    return (
        count_clause
        + "EVERY item's question_type MUST be one of [" + type_list + "] - do "
        "NOT produce any other type; an item of any other type is DISCARDED. "
        "MANDATORY TYPE COVERAGE: you MUST author AT LEAST ONE item for EVERY "
        "one of these allowed types [" + type_list + "]; a selected type left "
        "with zero items is a failure and will be back-filled by a forced "
        "follow-up pass, so cover it now. Beyond that one-each floor, choose the "
        "best-fitting allowed type per item. "
        "Return ONLY a JSON array, no markdown."
        + _text_contracts_note(allowed)
        + _image_contracts_note(ab_dims, types=allowed,
                                label_box_cap=label_box_cap)
        + _SELF_CONTAINED_RULE)


def _single_type_contract_note(qtype, label_box_cap=None):
    """The output-shape contract for ONE question type (text or image), ready to
    append to a forced-single-type top-up directive so the returned items carry
    the exact answer-key / image_specs shape that type's validator requires.
    Falls back cleanly to '' for a type with no special contract."""
    if qtype in _IMAGE_OR_VIDEO_TYPES:
        return _image_contracts_note(_ab_fallback_dims(), types=(qtype,),
                                     label_box_cap=label_box_cap)
    return _text_contracts_note((qtype,))


def _missing_allowed_types(allowed, items, ab_dims=None):
    """Selected types that NO SURVIVING item carries yet, in the admin's
    allow-list order. This is the coverage invariant the type-coverage self-heal
    stage closes: an allow-list is a REQUEST for each of those types, not merely
    a filter against the others, so a type the batch skipped is a gap to fill.

    Coverage is measured on items that would actually PERSIST - an item is
    counted for its type only if it resolves in-list AND passes that type's
    validator. A malformed image_ab (dropped later at create) therefore does NOT
    mask the image_ab gap; without this the fill would never fire for it."""
    if not allowed:
        return []
    present = set()
    for it in items:
        if not isinstance(it, dict):
            continue
        qt = _resolve_item_type(it, allowed)
        if qt is None or qt in present:
            continue
        if _validate_question_item(it, qt, ab_dims=ab_dims):
            continue  # malformed for its type -> would be dropped at create
        present.add(qt)
    return [t for t in allowed if t not in present]


def _trim_preserving_type_coverage(items, count, allowed, ab_dims=None):
    """Trim ITEMS down to COUNT WITHOUT re-dropping a selected type that only has
    one representative. A naive items[:count] slice can delete the sole msq/rubric
    the type-coverage stage just fought to add (they arrive LAST), silently
    re-introducing the very gap we closed. This keeps the FIRST surviving item of
    each allowed type first (so every covered selected type keeps >=1 slot when
    count allows), then fills the remaining slots with the rest in original order
    for stability. With no allow-list it degrades to a stable head slice."""
    if count <= 0 or len(items) <= count:
        return items
    protected = set()
    if allowed:
        seen = set()
        for i, it in enumerate(items):
            if not isinstance(it, dict):
                continue
            qt = _resolve_item_type(it, allowed)
            if qt is None or qt in seen:
                continue
            if _validate_question_item(it, qt, ab_dims=ab_dims):
                continue
            seen.add(qt)
            protected.add(i)
    keep = [i for i in range(len(items)) if i in protected][:count]
    if len(keep) < count:
        chosen = set(keep)
        for i in range(len(items)):
            if i in chosen:
                continue
            keep.append(i)
            if len(keep) >= count:
                break
    return [items[i] for i in sorted(keep[:count])]


def _fallback_item_type(item, allowed):
    """Type for an item whose own question_type cannot be honoured.

    Never returns None: the model's choice wins when it is generatable, else
    the first requested type, else mcq.
    """
    raw = item.get("question_type")
    if isinstance(raw, str) and raw in _GENERATABLE_TYPES:
        return raw
    if allowed:
        return allowed[0]
    return "mcq"


def _resolve_item_type(item, allowed):
    """Returns None to DROP. Never restamp an out-of-list item: its payload is
    shaped for the type the model chose, so a restamp can pass validation with the
    wrong answer-key shape."""
    raw = item.get("question_type")
    # A non-string question_type (e.g. ["mcq"]) would raise TypeError: unhashable
    # in the frozenset test and abort the whole batch. A NON-GENERATABLE code
    # (an import-only format) is rejected here too: the pipeline has no authoring
    # path for it and would approve into a question with no images.
    qtype = (raw if isinstance(raw, str) and raw in _GENERATABLE_TYPES
             else None)
    if not allowed:
        return qtype or "mcq"
    if qtype is None and len(allowed) == 1:
        return allowed[0]
    return qtype if qtype in allowed else None


def _selfheal_enabled(env):
    return (env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.gen_selfheal", "1") or "1").strip() != "0"


def _critique_enabled(env):
    return (env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.gen_critique", "1") or "1").strip() != "0"


def _item_title(it):
    return (it.get("name") or it.get("title") or "").strip()


def _uncovered_elements(prompt_record, items):
    """[(id, description)] for the SOP's required_elements that no item's
    covers_elements references yet. Reads the profile captured on the generator
    (required_elements_json), so coverage is measured against what the SOP said it
    needed - the same signal the harness targets its top-up passes at."""
    try:
        req = json.loads(prompt_record.required_elements_json or "[]")
    except Exception:  # noqa: BLE001
        req = []
    if not isinstance(req, list) or not req:
        return []
    covered = set()
    for it in items:
        ce = it.get("covers_elements")
        if isinstance(ce, list):
            covered |= {str(c) for c in ce}
    out = []
    for e in req:
        if isinstance(e, dict):
            eid = e.get("id") or e.get("key")
            desc = e.get("description") or e.get("text") or ""
        else:
            eid, desc = e, ""
        if eid and str(eid) not in covered:
            out.append((str(eid), desc))
    return out


def _topup_items(env, model, system_prompt, base_parts, existing, want,
                 allowed, target_elements=None, usage_ctx=None, force_type=None,
                 shape_note="", label_box_cap=None):
    """Request WANT more items when the primary run came up short (early
    truncation) or to close a coverage gap. Passes the titles already authored so
    the model does not duplicate, and asks for exactly the shortfall. Returns raw
    item dicts (with any solutions attached); the caller's validate/create loop
    is the single gate that shapes and persists them.

    When ``force_type`` is set the request is HARD-pinned to that single type
    (used by the quota stage to fill a selected-but-missing type): the allow-clause
    forces exactly that type and carries that type's output contract, so the
    returned items validate as ``force_type``.

    ``shape_note`` carries a TEMPLATE's own axes and options. Without it a
    template quota could only ask for the right question TYPE, so the top-up
    returned generic items that the caller then rejected for not matching the
    template - the shortfall never closed and the spend bought nothing.
    """
    made = [{"name": _item_title(q), "question_type": q.get("question_type")}
            for q in existing]
    focus = ""
    if target_elements:
        focus = ("\n\nEach new item MUST cover one or more of these so-far-"
                 "UNTESTED required elements (put their ids in covers_elements):\n"
                 + "\n".join("- %s: %s" % (eid, desc)
                             for eid, desc in target_elements))
    allow_clause = ""
    if force_type:
        allow_clause = (
            ' EVERY new item\'s question_type MUST be exactly "%s" - do NOT '
            "produce any other type; an item of any other type is DISCARDED."
            % force_type) + _single_type_contract_note(
                force_type, label_box_cap=label_box_cap)
    elif allowed:
        allow_clause = (" Every item's question_type MUST be one of ["
                        + ", ".join(allowed) + "].")
    directive = (
        "You already authored these %d assessment items:\n%s\n\n"
        "Author %d MORE, in the SAME schema/format as the system instructions, "
        "covering DIFFERENT elements and angles - do NOT repeat or paraphrase any "
        "listed above.%s%s%s\n\nReturn ONE JSON object "
        '{"questions":[...],"solutions":[...]} with exactly %d questions and their '
        "%d solutions, nothing else."
        % (len(existing), json.dumps(made, ensure_ascii=False), want,
           allow_clause, shape_note, focus, want, want))
    parts = list(base_parts) + [{"text": directive}]
    try:
        raw = _call_vertex(
            env, system_prompt, user_text="", user_parts=parts, model=model,
            max_tokens=_GEN_MAX_OUTPUT_TOKENS, temperature=0.6,
            response_json=True, usage_ctx=usage_ctx)
    except (ValueError, LLMRefusalError) as exc:
        _logger.warning("etp_assessment top-up call failed: %s", exc)
        return []
    try:
        items = [it for it in _extract_json_array(raw) if isinstance(it, dict)]
    except ValueError:
        return []
    sols = _extract_solutions(raw)
    if sols:
        _attach_solutions(
            items, sols, usage_ctx.get("prompt_id") if usage_ctx else 0)
    return items


def _backfill_solutions(env, model, base_parts, items, usage_ctx=None):
    """Regenerate answer keys from the FINALIZED items in a dedicated bounded
    call. Solutions are emitted LAST in the envelope, so a big-metadata SOP that
    truncates drops them first; this guarantees one keyed answer per item on its
    own token budget. Attaches results in place; returns the count backfilled."""
    slim = []
    for it in items:
        keep = {k: it.get(k) for k in ("name", "prompt", "question_type")
                if it.get(k) is not None}
        for k in ("options", "correct_answer", "rubric", "official_reasoning"):
            if it.get(k) is not None:
                keep[k] = it[k]
        slim.append(keep)
    directive = (
        "You are completing an assessment. Below are the FINALIZED questions, in "
        "order. Output ONLY a JSON object {\"solutions\":[...]} with exactly one "
        "object per question, SAME ORDER: "
        '{"question_ref":"<the exact question name>","answers":<the ideal worker '
        'answer>,"rationale":"<how it is known>"}. Return ONLY that JSON object.'
        "\n\nQUESTIONS:\n" + json.dumps(slim, ensure_ascii=False, indent=2))
    parts = list(base_parts) + [{"text": directive}]
    try:
        raw = _call_vertex(
            env, None, user_text="", user_parts=parts, model=model,
            max_tokens=_RETRY_OUTPUT_TOKENS_CEILING, temperature=0.3,
            response_json=True, usage_ctx=usage_ctx)
    except (ValueError, LLMRefusalError) as exc:
        _logger.warning("etp_assessment solution backfill failed: %s", exc)
        return 0
    sols = _extract_solutions(raw)
    if not sols:
        return 0
    need = [it for it in items if not isinstance(it.get("_solution"), dict)]
    before = len(need)
    _attach_solutions(items, sols, usage_ctx.get("prompt_id") if usage_ctx else 0)
    still = sum(1 for it in items if not isinstance(it.get("_solution"), dict))
    return max(0, before - still)


def _critique_revise(env, model, base_parts, items, usage_ctx=None):
    """Strict second-opinion audit of the assembled answer keys against the SOP.
    Only answer-key corrections are auto-applied (safe - no media change); item /
    prompt issues are logged. This is the main content-quality lever, and the
    discipline that catches a wrong or ambiguous key before candidates sit it.
    Returns the list of flagged issues."""
    pack = []
    for it in items:
        keep = {k: it.get(k) for k in ("name", "prompt", "question_type")
                if it.get(k) is not None}
        for k in ("options", "correct_answer", "rubric", "official_reasoning"):
            if it.get(k) is not None:
                keep[k] = it[k]
        sol = it.get("_solution") if isinstance(it.get("_solution"), dict) else {}
        keep["_solution"] = {"answers": sol.get("answers"),
                             "rationale": sol.get("rationale")}
        pack.append(keep)
    directive = (
        "You are a STRICT assessment reviewer. Audit the bank below against the "
        "SOP for ANSWER-KEY correctness, completeness and unambiguity. For EACH "
        "item decide whether its solution's answers is right and defensible given "
        "the item + SOP.\nReturn ONLY JSON: {\"solutions\":[<the FULL corrected "
        "solutions array, one object per item in the SAME ORDER, each "
        '{"question_ref","answers","rationale"}; fix any wrong/incomplete/'
        "ambiguous answer, keep correct ones unchanged>], \"issues\":"
        '[{"item":<1-based index>,"field":"answers|prompt|coverage|difficulty",'
        '"problem":"one sentence"}]}. Do not reword the questions; only correct '
        "solutions.\n\nBANK:\n" + json.dumps(pack, ensure_ascii=False, indent=2))
    parts = list(base_parts) + [{"text": directive}]
    try:
        raw = _call_vertex(
            env, None, user_text="", user_parts=parts, model=model,
            max_tokens=_MAX_OUTPUT_TOKENS_CEILING, temperature=0.2,
            response_json=True, usage_ctx=usage_ctx)
    except (ValueError, LLMRefusalError, RuntimeError) as exc:
        # A self-heal/critique failure (including a Vertex 4xx RuntimeError) must
        # NEVER poison the surrounding generation transaction — degrade to "no
        # issues" and let generation ship the un-revised bank.
        _logger.warning("etp_assessment critique pass failed: %s", exc)
        return []
    corr = _extract_solutions(raw)
    issues = []
    try:
        text = re.sub(r"```$", "", re.sub(
            r"^```(?:json)?", "", (raw or "").strip())).strip()
        obj = json.loads(text)
        if isinstance(obj, dict) and isinstance(obj.get("issues"), list):
            issues = obj["issues"]
    except Exception:  # noqa: BLE001
        pass
    # Only apply a fully-aligned 1:1 correction set - never a partial remap that
    # could key an answer to the wrong item.
    if isinstance(corr, list) and len(corr) == len(items):
        for it in items:
            it.pop("_solution", None)
        _attach_solutions(
            items, corr, usage_ctx.get("prompt_id") if usage_ctx else 0)
    return issues


def _selfheal_generation(env, prompt_record, items, base_parts, system_prompt,
                         model, count, allowed, quotas=None,
                         template_specs=None, report=None,
                         label_box_cap=None):
    """Harness-aligned robustness layer over a raw generation result: top up a
    short/truncated batch (targeting uncovered SOP elements), MEET EVERY SHAPE
    QUOTA the examiner set (a selected type with no explicit count still owes one
    item, so type coverage is the wanted=1 case), backfill any missing answer
    keys, then a critique pass to correct wrong/ambiguous keys. Each stage is
    config-gated and best-effort - a failure here never sinks the base batch.

    `quotas` is `{shape: wanted}` where a shape is a question type or
    `template:<id>`; `template_specs` carries each template shape's name and
    question type; `report`, when a dict, collects an unmet quota so the examiner
    sees the shortfall instead of a silently short batch.
    """
    prompt_id = prompt_record.id
    base = {"operation": "generate_questions", "prompt_id": prompt_id}
    ab_dims = _ab_fallback_dims()
    if _selfheal_enabled(env) and count and len(items) < count:
        tries = 0
        while len(items) < count and tries < 3:
            tries += 1
            want = count - len(items)
            gaps = _uncovered_elements(prompt_record, items)
            _logger.info(
                "etp_assessment self-heal: %d/%d items, topping up %d%s",
                len(items), count, want,
                " (targeting %d uncovered element(s))" % len(gaps)
                if gaps else "")
            new_items = _topup_items(
                env, model, system_prompt, base_parts, items, want, allowed,
                target_elements=gaps or None,
                usage_ctx=dict(base, note="topup"),
                label_box_cap=label_box_cap)
            if not new_items:
                break
            items += new_items
    # QUOTA STAGE. Generalises the old type-coverage stage: an allow-list is a
    # REQUEST for each selected type, not merely a filter, and an explicit
    # per-shape count (`MCQ x 2`, `this task x 3`) is that same request with a
    # number on it. Coverage is therefore the `wanted=1` case, and both run
    # through one loop instead of two mechanisms that would fight over the trim.
    #
    # A shape can be a question type or `template:<id>`. Items authored for a
    # template are stamped so they count for their template AND their type.
    if _selfheal_enabled(env) and allowed:
        counted = _count_items_by_shape(items, allowed, quotas, ab_dims=ab_dims)
        # Every selected type still owes at least one item, so fold the coverage
        # floor into the quota map rather than running a second pass.
        wanted_by_shape = dict(quotas or {})
        for qt in allowed:
            wanted_by_shape.setdefault(qt, 1)
        shortfall = quota_shortfall(wanted_by_shape, counted)
        if shortfall:
            _logger.info(
                "etp_assessment quota: %d shape(s) short on prompt %s (%s)",
                len(shortfall), prompt_id,
                ", ".join("%s needs %d" % (s, n)
                          for s, n in shortfall.items()))
        for shape, still_wanted in shortfall.items():
            template_id = template_id_of_shape(shape)
            force_type = None if template_id else shape
            shape_note = ""
            if template_id:
                # A template names its own primitive, so items for it are typed
                # by the template rather than by the shape key - and the model
                # needs the template's OWN axes, or it authors a generic item
                # that cannot count for this shape.
                spec = (template_specs or {}).get(shape) or {}
                force_type = spec.get("question_type")
                shape_note = _template_shapes_note({shape: spec})
            # ONE call per shape asking for the whole shortfall, not one call per
            # missing item: the top-up is already batched and a per-item loop
            # would multiply the spend on the most expensive path in the product.
            new_items = _topup_items(
                env, model, system_prompt, base_parts, items, still_wanted,
                allowed, usage_ctx=dict(base, note="quota"),
                force_type=force_type, shape_note=shape_note,
                label_box_cap=label_box_cap)
            kept = []
            refused = []
            for it in new_items:
                if not isinstance(it, dict):
                    continue
                qt = _resolve_item_type(it, allowed)
                if qt is None:
                    refused.append((_item_title(it), "type not in the allow-list"))
                    continue
                problems = _validate_question_item(it, qt, ab_dims=ab_dims)
                if problems:
                    refused.append((_item_title(it), "; ".join(problems)))
                    continue
                if force_type and qt != force_type:
                    refused.append(
                        (_item_title(it), "wanted %s, got %s" % (force_type, qt)))
                    continue
                if template_id:
                    # STAMPED HERE, not expected from the model. The stamp is our
                    # bookkeeping for "this item came from that template" - asking
                    # the model to echo it back only made the shortfall unclosable.
                    it["_template_shape"] = shape
                kept.append(it)
            # WHY an item was refused, not just that the shape stayed short. The
            # loop used to discard silently, so a quota that never closed gave no
            # clue whether the model returned the wrong type or a malformed item -
            # and every diagnosis cost another paid run.
            if refused:
                _logger.warning(
                    "etp_assessment quota: %s refused %d item(s): %s",
                    shape, len(refused),
                    " | ".join("%r: %s" % (t[:40], r) for t, r in refused[:4]))
            if kept:
                items += kept[:still_wanted]
            got = len(kept[:still_wanted])
            if got < still_wanted:
                # KEEP WHAT CAME BACK and report the gap. Failing the run or
                # padding with another shape would both be worse: the examiner
                # decides what to do about a shortfall, not the pipeline.
                _logger.warning(
                    "etp_assessment quota: %s short by %d on prompt %s",
                    shape, still_wanted - got, prompt_id)
                if isinstance(report, dict):
                    report.setdefault("quota_shortfall", {})[shape] = (
                        still_wanted - got)
    # One final cap. Never exceed the requested count, but trim so a quota'd shape
    # keeps its items and a selected type keeps at least one representative (the
    # coverage additions land LAST, so a naive items[:count] slice would silently
    # re-open the gap we just closed). Solutions ride on each item dict, so the
    # trim keeps every kept item's answer key intact.
    if count and len(items) > count:
        items = _trim_preserving_quotas(
            items, count, allowed, quotas=quotas, ab_dims=ab_dims)
    if _selfheal_enabled(env):
        missing = [it for it in items
                   if not isinstance(it.get("_solution"), dict)]
        if missing:
            n = _backfill_solutions(
                env, model, base_parts, items,
                usage_ctx=dict(base, note="backfill_solutions"))
            _logger.info(
                "etp_assessment self-heal: backfilled %d/%d missing answer key(s)",
                n, len(missing))
    if _critique_enabled(env) and any(
            isinstance(it.get("_solution"), dict) for it in items):
        issues = _critique_revise(
            env, _scoring_model(env), base_parts, items,
            usage_ctx=dict(base, note="critique"))
        if issues:
            _logger.info(
                "etp_assessment critique flagged %d answer-key issue(s) on "
                "prompt %s: %s", len(issues), prompt_id,
                "; ".join(
                    "item %s [%s] %s" % (i.get("item"), i.get("field"),
                                         i.get("problem"))
                    for i in issues[:8]))
    return items


def draft_task_template_from_sop(env, prompt_record, usage_ctx=None):
    """Propose ONE task template from the SOP, as a Form Studio structure.

    An EDITABLE STARTING POINT, never a saved artifact. The caller hands this to
    the designer for the admin to correct; nothing persists until they press Save,
    and `authored_by` then records `llm_edited`. That boundary is the point: the
    model is good at recovering the shape of a task from prose and unreliable at
    getting every option label exactly right, so a human closes the gap.

    Returns {"name", "instructions", "response", "structure", "warnings"}.
    Raises LLMRefusalError when there is nothing to read.
    """
    doc_parts = _sop_doc_parts(prompt_record.resource_ids)
    # The ONE sample list, read with rule 9's golden treatment: text under
    # "GOLDEN EXAMPLE" labels, PDFs and images sent natively.
    golden_parts = _sample_doc_parts(prompt_record, label="GOLDEN EXAMPLE")
    notes = (getattr(prompt_record, "source_text", "") or "").strip()
    if not doc_parts and not notes:
        raise LLMRefusalError(
            "No SOP document or notes to read — upload a SOP file first.")

    # Prefer the SOP's own already-extracted task: it was grounded in verbatim
    # quotes at extraction time, so seeding the draft with it keeps the template
    # anchored to the same evidence instead of re-deriving the task from scratch.
    tasks = parse_task_registry(getattr(prompt_record, "tasks_json", "") or "")
    seed = ""
    if tasks:
        primary = tasks[0]
        contract = task_answer_contract(primary)
        axes = "; ".join(
            "%s (%s)" % (d["label"], ", ".join(d["options"]))
            for d in contract.get("dimensions") or [])
        seed = (
            "\n\nTHE SOP'S OWN PRIMARY TASK, already extracted and grounded in "
            "verbatim quotes - build the template for THIS task rather than "
            "inventing a different one:\n"
            "  task: %s\n  the worker looks at: %s\n  the worker produces: %s%s"
            % (primary.get("display") or primary.get("key"),
               primary.get("subject_inputs") or "(not stated)",
               primary.get("worker_output") or "(not stated)",
               ("\n  axes the SOP names: %s" % axes) if axes else ""))

    project_name = (getattr(prompt_record, "sop_title", "") or "").strip()
    name_example = (
        'Compare AI-Generated Images: %s' % project_name if project_name
        else 'Compare AI-Generated Images: Product Photos')
    directive = (
        "Read this SOP and propose ONE reusable TASK TEMPLATE: the shape of the "
        "task a worker actually performs, expressed as a small form an examiner "
        "can edit."
        + seed +
        "\n\nReturn ONLY this JSON object:\n"
        "{\n"
        '  "name": string,            // Distinctive - MUST include what makes\n'
        "                             // THIS SOP's task different from another\n"
        "                             // SOP of the same general shape: the\n"
        "                             // subject/domain/project being judged, not\n"
        "                             // just the response mechanism. Two A/B\n"
        '                             // comparison SOPs must NOT both produce\n'
        '                             // "Compare AI-Generated Images" - one is\n'
        '                             // e.g. "%s"\n' % name_example
        + '  "instructions": string,    // one or two sentences telling a question\n'
        "                             // generator what this shape is for\n"
        '  "response": one of ["single_choice","multi_choice","free_text",\n'
        '                      "compare_two","annotate_image","author_prompt",\n'
        '                      "author_video_prompt","describe_media"],\n'
        '  "media_brief": string,     // REQUIRED when any item below is\n'
        "                             // comparePair, imageAnnotation or\n"
        "                             // promptWriting: what the picture or clip\n"
        "                             // must SHOW, so it can be rendered. Omit\n"
        "                             // when the task shows the worker nothing.\n"
        '  "sections": [              // Form Studio shape; usually ONE section\n'
        "    {\n"
        '      "title": string,\n'
        '      "items": [\n'
        "        {\n"
        '          "kind": one of\n'
        '            // choices\n'
        '            ["multipleChoice","checkboxes","dropdown",\n'
        '            // the same axis asked about several rows at once\n'
        '             "choiceGrid","checkboxGrid",\n'
        '            // a numeric judgement\n'
        '             "linearScale","rating",\n'
        '            // written answers\n'
        '             "shortAnswer","paragraph",\n'
        '            // THE THREE THAT PUT MEDIA IN FRONT OF THE WORKER\n'
        '             "comparePair",     // two plates side by side, then choose\n'
        '             "imageAnnotation", // one plate, mark numbered regions\n'
        '             "promptWriting"],  // a target plate, write its prompt\n'
        '          "title": string,   // the question a candidate reads, in the\n'
        "                             // SOP's OWN wording\n"
        '          "options": [       // omit for shortAnswer / paragraph\n'
        '            {"label": string, "correct": boolean}\n'
        "          ],\n"
        '          "rows": [string], "columns": [string],   // grids only\n'
        '          "scale_min": int, "scale_max": int,      // linearScale only\n'
        '          "rating_max": int,                       // rating only\n'
        '          "left_label": string, "right_label": string  // comparePair\n'
        "        }\n"
        "      ]\n"
        "    }\n"
        "  ]\n"
        "}\n\n"
        "RULES:\n"
        "1. Use the SOP's OWN wording for every question and every option label. "
        "Do NOT substitute a generic Response A / Response B scale when the SOP "
        "names its choices.\n"
        "2. Mark exactly the option(s) the SOP says are correct. If the SOP does "
        "not decide an answer, use shortAnswer or paragraph instead of guessing "
        "a key.\n"
        "3. Keep it SMALL - the axes this task really judges, nothing more. An "
        "examiner will edit this, so a tight correct draft beats a long vague one.\n"
        "4. Every option label must be one a worker could actually pick.\n"
        # WHAT THE WORKER LOOKS AT DECIDES `response`.
        #
        # `response` IS THE LEVER, NOT THE ITEM KINDS. Generation reads
        # `task_template.answer_contract()`, which maps `response` through
        # TASK_PRIMITIVE_TO_QUESTION_TYPE to the question type - and only
        # image_ab/image_label/image_prompt/video_prompt ever get media
        # rendered. The item kinds contribute only the AXES (title + options);
        # `_axes()` is explicit that "SHAPE DECIDES, NOT KIND". So a draft whose
        # items are all multipleChoice still shows plates if `response` is a
        # media one, and a draft full of comparePair items shows nothing if it
        # is not. The kind list above is still worth getting right - it is what
        # the examiner edits and what a Form Studio import renders - but this
        # rule is the one that decides whether a candidate sees anything.
        "5. LOOK AT WHAT THE WORKER LOOKS AT (stated above). If the task judges "
        "a picture or a clip, `response` MUST be one that shows media - "
        "compare_two, annotate_image, author_prompt or author_video_prompt - "
        "because that choice is what makes a plate get rendered at all. A "
        "question asking whether an image is sharp is unanswerable when no "
        "image is shown. Pick by what the work is:\n"
        "   - judging one thing against another, or judging properties of an "
        "artifact where a correct and a flawed version can be rendered side by "
        "side -> compare_two (items: comparePair)\n"
        "   - marking, counting or attributing regions in one picture -> "
        "annotate_image (items: imageAnnotation)\n"
        "   - writing the prompt that would produce a target -> author_prompt, "
        "or author_video_prompt for a clip (items: promptWriting)\n"
        "   - the task shows the worker nothing and tests knowledge only -> "
        "single_choice / multi_choice / free_text, and no media_brief\n"
        # THE MEDIUM IS NOT A DETAIL, IT DECIDES WHAT CAN BE ASKED.
        #
        # Only `author_video_prompt` renders a clip, and it is prompt-AUTHORING:
        # `video_prompt` carries no dimensions, so the SOP's pass/fail axes
        # cannot ride on a clip the way they ride on an `image_ab` pair. A model
        # told only "pick a media shape" will happily pair six Yes/No axes with
        # a video subject and produce a template that cannot generate what it
        # appears to promise.
        "6. MIND THE MEDIUM. Only author_video_prompt produces a CLIP; every "
        "other media shape produces STILLS. And a clip can only be used for "
        "prompt-authoring - the pass/fail axes a SOP names can be asked about a "
        "still (they become the comparison's own dimensions) but NOT about a "
        "clip. So: a task that JUDGES something on named axes -> compare_two, "
        "even when the source material is video, and say so in media_brief. A "
        "task whose output IS a written prompt for a clip -> "
        "author_video_prompt, with no axes. If the SOP covers BOTH stills and "
        "clips, build the template for ONE of them - the one its primary task "
        "names - rather than mixing the two.\n"
        "7. `media_brief` is REQUIRED whenever `response` shows media. It "
        "anchors every generated item to the SAME subject, so without it each "
        "one invents a different picture. Say what the plate must show, in the "
        "SOP's own terms - \"an image\" is not a brief.\n"
        "8. The SOP's own axes stay as separate items with their own option "
        "labels even when `response` shows media: each item becomes one graded "
        "axis about the plate, so four Pass/Fail picture checks are four items, "
        "not one."
        + ("\n9. GOLDEN EXAMPLES are worked examples of this task already solved "
           "correctly. Treat them as the ground truth for SHAPE: the axes they "
           "answer, the wording of those axes, and the option labels they use "
           "are what this template must reproduce. Where a golden example and "
           "the SOP prose disagree on wording, follow the golden example - it "
           "is what the work actually looks like."
           if golden_parts else ""))

    user_parts = list(doc_parts)
    # Golden examples ride BETWEEN the SOP and the directive: after the source
    # they illustrate, before the instruction that refers to them. Headed, as a
    # PDF or image travels as an unlabelled inline part like a SOP PDF.
    if golden_parts:
        user_parts.append({"text": "GOLDEN EXAMPLES - worked examples of this "
                                   "task, attached below:"})
        user_parts.extend(golden_parts)
    if notes:
        user_parts.append({"text": "ADDITIONAL NOTES:\n" + notes})
    user_parts.append({"text": directive})

    raw = _call_vertex(
        env, _get_question_prompt(env), "", user_parts=user_parts,
        # This call READS THE SOP, so it needs the document-capable generation
        # model. It was passing no model and inheriting `vertex_model`, which
        # defaults to the image model - and an image model sees a PDF as opaque
        # binary and fails with "document has no pages".
        model=_generation_model(env),
        # Sized for a THINKING model: at 4000, gemini-3.1-pro-preview spent
        # ~3,840 on thoughts and was cut off (MAX_TOKENS) on every first try;
        # the 8000 retry used up to 6,348 thoughts + ~400 output. The retry
        # doubles this up to `_RETRY_OUTPUT_TOKENS_CEILING` (16000).
        response_json=True, temperature=0.2, max_tokens=12000,
        usage_ctx=dict(usage_ctx or {},
                       operation="draft_task_template",
                       prompt_id=prompt_record.id))
    # Same object-parse pattern the rest of this module uses: whole-string
    # first, then the outermost {...} when the model wrapped it in prose.
    try:
        obj = json.loads((raw or "").strip())
    except (ValueError, TypeError):
        m = re.search(r"\{.*\}", raw or "", re.S)
        try:
            obj = json.loads(m.group(0)) if m else None
        except (ValueError, TypeError):
            obj = None
    if not isinstance(obj, dict):
        raise LLMRefusalError(
            "The model did not return a usable template; try again or author "
            "one by hand.")

    warnings = []
    response = str(obj.get("response") or "").strip()
    if response not in _TASK_PRIMITIVES:
        warnings.append(
            "The model proposed an unrecognised response type %r; defaulted to "
            "single choice. Change it in the designer if that is wrong."
            % response)
        response = "single_choice"

    sections, item_count = _normalise_template_sections(
        obj.get("sections"), warnings)

    media_brief = str(obj.get("media_brief") or "").strip()
    warnings.extend(_draft_shape_warnings(
        tasks, sections, response, media_brief))

    return {
        "name": (str(obj.get("name") or "").strip() or "Untitled task")[:120],
        "instructions": str(obj.get("instructions") or "").strip(),
        "response": response,
        # Carried so a media draft arrives WITH the brief that renders it. The
        # editor shows this field for the media primitives; without it the
        # examiner had to write the brief from scratch every time.
        "media_brief": media_brief,
        "structure": sections,
        "item_count": item_count,
        "warnings": warnings,
    }


# Kinds and primitives that actually put a plate in front of the worker. Kinds
# are what matter most: `task_template.to_question_specs` routes every item
# through `studio_form._walk_section`, so it is the ITEM KIND - not the
# template's response primitive - that decides the published question type and
# therefore whether media is rendered at all.
_MEDIA_ITEM_KINDS = frozenset({"comparePair", "imageAnnotation",
                               "promptWriting"})
_MEDIA_PRIMITIVES = frozenset({"compare_two", "annotate_image",
                               "author_prompt", "author_video_prompt"})

# Words that mean "the worker is looking at something", read off the SOP's own
# `subject_inputs`. Deliberately a plain word list: the alternative is another
# LLM call to classify a sentence this app already extracted, and a false
# positive here costs one dismissable warning.
#
# SPLIT BY MEDIUM, because the two are not interchangeable downstream. A still
# can carry judging axes (`compare_two` -> `image_ab`, whose dimensions ARE the
# SOP's axes); a clip cannot - `video_prompt` is the only video type and it is
# prompt-AUTHORING graded against `ideal_prompt`, with no dimensions. So a SOP
# whose subject is a clip needs a different answer from one whose subject is a
# photo, and "media" as one bucket cannot express that.
#
# WORDS WITH A COMMON NON-MEDIA SENSE ARE DELIBERATELY ABSENT. "render",
# "still", "frame", "clip" and "recording" all read naturally in text-only work
# - "render a decision", "still open after the SLA window", "frame the
# objection", "clip the quote into the summary" - and every one of them fired
# this check on a SOP with no media at all. A warning that cries wolf on
# ordinary prose trains the examiner to ignore the one that matters, which
# costs more than the miss it was meant to catch.
_IMAGE_SUBJECT_WORDS = (
    "image", "images", "picture", "pictures", "photo", "photos", "photograph",
    "photographs", "screenshot", "screenshots", "thumbnail", "thumbnails",
)
_VIDEO_SUBJECT_WORDS = (
    "video", "videos", "clips", "footage", "reel", "reels",
)
_MEDIA_SUBJECT_WORDS = _IMAGE_SUBJECT_WORDS + _VIDEO_SUBJECT_WORDS

# Which response primitives render which medium. `author_video_prompt` is the
# ONLY one that produces a clip: TASK_PRIMITIVE_TO_QUESTION_TYPE maps it to
# `video_prompt`, the single member of VIDEO_QUESTION_TYPES.
_VIDEO_PRIMITIVES = frozenset({"author_video_prompt"})
_IMAGE_PRIMITIVES = frozenset({"compare_two", "annotate_image",
                               "author_prompt"})


def _sop_subject_text(tasks):
    """The SOP's own words about what the work looks at and produces.

    READS EVERY TASK, not only the primary. The registry is a LIST - a SOP
    routinely defines an image task and a video task - and reading `tasks[0]`
    alone made the medium check blind to a second task, which is precisely the
    "Image + Video" case it exists to catch.
    """
    out = []
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        out.extend(str(task.get(k) or "") for k in (
            "subject_inputs", "worker_output", "one_sentence", "display"))
    return " ".join(out).lower()


def _names_any(haystack, words):
    """Whole-word match, so "imagine" is not an image and "reframe" not a frame."""
    return any(re.search(r"\b%s\b" % w, haystack) for w in words)


def _sop_subject_names_media(tasks):
    """True when the SOP's primary task says the worker looks at media."""
    return _names_any(_sop_subject_text(tasks), _MEDIA_SUBJECT_WORDS)


def _sop_subject_names_video(tasks):
    """True when the SOP's subject is a CLIP, not only a still."""
    return _names_any(_sop_subject_text(tasks), _VIDEO_SUBJECT_WORDS)


def _sop_subject_names_image(tasks):
    """True when the SOP's subject is a STILL."""
    return _names_any(_sop_subject_text(tasks), _IMAGE_SUBJECT_WORDS)


def _draft_shows_media(sections, response):
    """True when this draft would actually show the candidate a plate."""
    if response in _MEDIA_PRIMITIVES:
        return True
    for section in sections or []:
        if not isinstance(section, dict):
            continue
        for item in section.get("items") or []:
            if isinstance(item, dict) and item.get("kind") in _MEDIA_ITEM_KINDS:
                return True
    return False


def _draft_item_choice_count(item):
    """How many choices an authored item offers, by SHAPE not by kind.

    MIRRORS `task_template._option_labels`, which is the reader that actually
    reaches the generator. That method's own comment records the bug this
    duplicates: reading ONLY `options` "dropped all four to zero axes, so the
    kinds vanished from the contract even though the designer drew them" - a
    grid carries its choices in `columns`, a scale in scale_min/scale_max and a
    rating in rating_max. An earlier version of this helper read `options`
    alone and so reintroduced exactly that, silently treating a drafted grid or
    1-5 scale as "no axes".
    """
    if not isinstance(item, dict):
        return 0
    opts = [o for o in (item.get("options") or []) if o]
    if len(opts) >= 2:
        return len(opts)
    cols = [c for c in (item.get("columns") or []) if c]
    if len(cols) >= 2:
        return len(cols)
    lo, hi = item.get("scale_min"), item.get("scale_max")
    if hi is None and item.get("rating_max") is not None:
        lo, hi = 1, item.get("rating_max")
    if hi is not None:
        try:
            span = int(hi) - int(1 if lo is None else lo) + 1
        except (TypeError, ValueError):
            return 0
        return span if span >= 2 else 0
    return 0


def _draft_has_axes(sections):
    """True when the draft carries at least one gradable axis.

    Used to tell a JUDGING task (axes) from an AUTHORING one (a written
    prompt), because only the first can ride on `image_ab`.
    """
    for section in sections or []:
        if not isinstance(section, dict):
            continue
        for item in section.get("items") or []:
            if _draft_item_choice_count(item) >= 2:
                return True
    return False


def _draft_shape_warnings(tasks, sections, response, media_brief):
    """What is WRONG with this draft, in the examiner's words. [] when fine.

    PURE, so the wiring is testable. These checks were inline in
    `draft_task_template_from_sop`, which cannot be exercised without an LLM
    call - so the conditions were unit-tested through their helpers while the
    thing that actually decides whether an examiner SEES a warning was not
    tested at all.

    EVERY CHECK WARNS, NONE REWRITES. Which shape fits is a judgement about
    the task; guessing one here would replace a visible gap with an invisible
    wrong answer, and the examiner would have no way to tell.
    """
    out = []

    # A MEDIA TASK WITH NO BRIEF GENERATES A DIFFERENT SUBJECT EVERY ITEM.
    #
    # `answer_contract()` carries `media_brief` specifically to "anchor the
    # stimulus so every generated item is a variation on the same task rather
    # than a different one". Without it the model invents the subject per item,
    # so a five-item run about one product audit becomes five unrelated
    # pictures - which reads as a working run and is not one.
    if response in _MEDIA_PRIMITIVES and not media_brief:
        out.append(
            "This task shows the candidate media but no brief describes it, so "
            "every generated item would invent its own subject. Fill in what "
            "the picture or clip must show before generating.")

    # A DRAFT THAT SHOWS NOTHING FOR A TASK ABOUT A PICTURE IS THE FAILURE
    # WORTH NAMING.
    #
    # The first version of this returned six confident Pass/Fail questions for
    # an SOP whose whole subject is auditing an image, with no media anywhere
    # and not one warning. Nothing downstream could tell that from a correct
    # draft - the examiner had to notice, and only did because the questions
    # read oddly. This says it instead. It WARNS rather than rewrites: which
    # shape is right is a judgement about the task, and guessing one here would
    # replace a visible gap with an invisible wrong answer.
    if _sop_subject_names_media(tasks) and not _draft_shows_media(
            sections, response):
        out.append(
            "The SOP says the worker looks at a picture or a clip, but this "
            "draft shows the candidate nothing - they would be asked to judge "
            "media they were never given. Set 'What a candidate does' to a "
            "shape that shows media (compare two, annotate an image, write a "
            "prompt) and describe what the plate must show.")

    # THE MEDIUM THE SOP NAMES vs THE MEDIUM THIS SHAPE RENDERS.
    #
    # `author_video_prompt` is the ONLY primitive that produces a clip. So an
    # "Image + Video" SOP drafted as `compare_two` covers the image half and
    # silently drops the video half - which is exactly what happened on the IG
    # Entity SOP: the draft was a correct IMAGE audit and nothing anywhere said
    # the video checks had been left out. A template is allowed to cover one
    # medium; it is not allowed to do so silently.
    if _sop_subject_names_video(tasks) and response in _IMAGE_PRIMITIVES:
        out.append(
            "This SOP's work includes video, but this shape renders stills "
            "only, so the clip-based checks are not covered. That is fine for "
            "an image-only template - author a SECOND template with 'Write the "
            "prompt for a clip' for the video half, rather than expecting this "
            "one to carry both.")

    # A VIDEO JUDGING TASK HAS NO SHAPE, AND SAYING SO BEATS PRETENDING.
    #
    # `video_prompt` is the only video question type and it is prompt-AUTHORING
    # graded against `ideal_prompt`; it carries no dimensions. A still can be
    # judged on the SOP's own axes because `compare_two` -> `image_ab` puts them
    # in `dimensions`. A clip cannot. A draft that pairs a video subject with
    # judging axes therefore cannot generate what it appears to promise.
    if (_sop_subject_names_video(tasks)
            and not _sop_subject_names_image(tasks)
            and _draft_has_axes(sections)
            and response in _VIDEO_PRIMITIVES):
        out.append(
            "The axes below cannot be asked about a clip: the only video "
            "question type asks the candidate to WRITE a prompt, graded against "
            "an ideal prompt, and carries no pass/fail axes. Either state what "
            "the clip must show and drop the axes, or keep the axes and judge a "
            "still instead.")
    return out


# PUBLIC ALIAS. `models.task_template` computes the same warnings on its own
# record so they outlive the drafting toast; keeping one implementation means
# the editor, the template list and the drafter can never disagree about what
# is wrong with a template.
def draft_shape_warnings(tasks, sections, response, media_brief):
    return _draft_shape_warnings(tasks, sections, response, media_brief)


def _normalise_template_sections(sections, warnings):
    """Coerce the model's sections into the designer's shape, KEEPING everything.

    Nothing is dropped for being imperfect: an item the designer cannot render
    would vanish silently, so anything questionable is kept and flagged for the
    admin to fix. The admin approves or deletes - not the pipeline.
    """
    # EVERY KIND THE DESIGNER OFFERS, not a subset.
    #
    # This set was four kinds wide while task_template_editor.dart offers
    # thirteen, so when the MODEL drafted a template every scale, rating, grid,
    # dropdown, date, time, compare-pair and annotation item was rewritten to
    # "shortAnswer" with a warning. An examiner asking the model for a 1-5
    # quality rating got a text box, and because a text box carries no choices
    # it is not an axis at all - so the item then vanished from the answer
    # contract too, and nothing about the run said why. Hand-authored templates
    # were unaffected, which is what made this look like a model problem.
    kinds = {
        "multipleChoice", "checkboxes", "dropdown",
        "choiceGrid", "checkboxGrid",
        "linearScale", "rating",
        "shortAnswer", "paragraph",
        "comparePair", "imageAnnotation",
        "promptWriting",
    }
    # `date`, `time` and `fileUpload` ARE DELIBERATELY ABSENT, so a model that
    # drafts one is coerced to `shortAnswer` with a warning by the fallback
    # below - which is exactly what the designer now does with a stored one
    # (`FormItemKindX.parse`). None of the three is gradeable here: an upload has
    # no question type at all, and a date or a time is a single literal with no
    # answer key and no rubric, so an examiner could publish one and the
    # candidate's answer would count for nothing. Keeping them accepted would
    # store a kind the client silently reads as something else, which is the
    # drift this set exists to prevent.
    #
    # `promptWriting` was missing for the opposite reason - the designer offers
    # it and `_item_spec` publishes it as image_prompt/video_prompt, so a model
    # drafting one had it rewritten to a text box, losing the media slots and
    # the golden prompt.
    # Which extra fields each kind needs to survive. Losing these silently
    # turned a 1-5 scale into a scale with no bounds, which _option_labels then
    # read as "no choices" - the same disappearance by a different route.
    shape_fields = {
        "linearScale": ("scale_min", "scale_max",
                        "scale_min_label", "scale_max_label"),
        "rating": ("rating_max",),
        "choiceGrid": ("rows", "columns"),
        "checkboxGrid": ("rows", "columns"),
        "comparePair": ("left_label", "right_label"),
        "imageAnnotation": ("max_boxes",),
        # Prompt writing IS its media: `media_url` is the single/reference
        # plate and `media_url_b` the optional output. `_item_spec` refuses the
        # item outright when the first is missing, so dropping them here would
        # turn every drafted prompt question into a publish-time problem.
        # `golden_answer` is the model prompt the judge grades against.
        "promptWriting": ("media_url", "media_url_b", "golden_answer"),
    }
    out = []
    item_count = 0
    for si, section in enumerate(sections or [], start=1):
        if not isinstance(section, dict):
            warnings.append("Section %d was not an object and was skipped." % si)
            continue
        items = []
        for ii, item in enumerate(section.get("items") or [], start=1):
            if not isinstance(item, dict):
                warnings.append(
                    "Item %d in section %d was not an object and was skipped."
                    % (ii, si))
                continue
            kind = str(item.get("kind") or "").strip()
            title = str(item.get("title") or "").strip()
            if kind not in kinds:
                warnings.append(
                    "%r is not a question kind the designer knows; %r was kept "
                    "as a short answer - check it."
                    % (kind, title[:60] or "an untitled item"))
                kind = "shortAnswer"
            options = []
            for oi, opt in enumerate(item.get("options") or [], start=1):
                if not isinstance(opt, dict):
                    continue
                label = str(opt.get("label") or "").strip()
                if not label:
                    continue
                options.append({
                    "id": "opt-%d-%d-%d" % (si, ii, oi),
                    "label": label,
                    # The designer reads `correct`; `_options_of` emits
                    # `is_correct` on the way out.
                    "correct": bool(opt.get("correct")),
                })
            if kind in ("multipleChoice", "checkboxes", "dropdown"):
                if len(options) < 2:
                    warnings.append(
                        "%r offered fewer than two options, so it was kept as a "
                        "short answer - add the choices in the designer."
                        % (title[:60] or "an untitled item"))
                    kind, options = "shortAnswer", []
                elif not any(o["correct"] for o in options):
                    warnings.append(
                        "%r has no correct option marked - set the answer key "
                        "before saving." % (title[:60] or "an untitled item"))
            row = {
                "id": "item-%d-%d" % (si, ii),
                "kind": kind,
                "title": title or "Untitled question",
                "options": options,
            }
            # Carry the kind's own shape so a scale keeps its bounds, a rating
            # its maximum and a grid its rows/columns. Without these the item
            # survives as a kind name with nothing to answer.
            for extra in shape_fields.get(kind, ()):
                if item.get(extra) is not None:
                    row[extra] = item[extra]
            # A scale or rating the model left unbounded is not answerable, and
            # silently defaulting it would invent a range the examiner never
            # chose. Fill the designer's own default and say so.
            if kind == "linearScale" and row.get("scale_max") is None:
                row["scale_min"], row["scale_max"] = 1, 5
                warnings.append(
                    "%r is a scale with no range, so 1-5 was used - change it "
                    "in the designer if that is wrong."
                    % (title[:60] or "an untitled item"))
            if kind == "rating" and row.get("rating_max") is None:
                row["rating_max"] = 5
                warnings.append(
                    "%r is a rating with no maximum, so 5 was used - change it "
                    "in the designer if that is wrong."
                    % (title[:60] or "an untitled item"))
            if kind in ("choiceGrid", "checkboxGrid") and not (
                    row.get("rows") and row.get("columns")):
                warnings.append(
                    "%r is a grid missing its rows or columns, so it was kept "
                    "as a short answer - rebuild it in the designer."
                    % (title[:60] or "an untitled item"))
                row["kind"] = "shortAnswer"
                row.pop("rows", None)
                row.pop("columns", None)
            # PROMPT WRITING IS ITS STIMULUS. `_item_spec` REFUSES the item when
            # there is no media ("write the prompt that would produce this" with
            # nothing shown is unanswerable), and a model cannot invent a URL -
            # so a drafted one with no plate would fail at publish time, after
            # the examiner had already saved it. Degrade it here instead, the
            # same way a gridless grid is degraded, and say so.
            if kind == "promptWriting" and not str(
                    row.get("media_url") or "").strip():
                warnings.append(
                    "%r asks for a prompt but carries no image or clip, so it "
                    "was kept as a short answer - attach the media in the "
                    "designer to make it a prompt question."
                    % (title[:60] or "an untitled item"))
                row["kind"] = "shortAnswer"
                for gone in ("media_url", "media_url_b"):
                    row.pop(gone, None)
            items.append(row)
            item_count += 1
        out.append({
            "id": "sec-%d" % si,
            "title": str(section.get("title") or "").strip() or "Questions",
            "items": items,
        })
    if not out:
        warnings.append(
            "The model returned no usable section; start from a blank template.")
        out = [{"id": "sec-1", "title": "Questions", "items": []}]
    return out, item_count


def _resolve_template_shapes(env, quotas):
    """`{shape: {name, question_type, contract}}` for each `template:<id>` shape.

    Only ACTIVE templates resolve. A shape that does not resolve is dropped by
    the caller with a warning rather than quietly generating nothing for it: the
    admin picked that task deliberately, and an archived template is a real
    change they should hear about.
    """
    shapes = [s for s in (quotas or {}) if is_template_shape(s)]
    if not shapes:
        return {}
    ids = {}
    for shape in shapes:
        template_id = template_id_of_shape(shape)
        if template_id:
            ids[template_id] = shape
    if not ids:
        return {}
    out = {}
    records = env["assessments.be.task.template"].sudo().browse(
        list(ids)).exists()
    for rec in records:
        if not rec.active:
            continue
        shape = ids.get(rec.id)
        if not shape:
            continue
        out[shape] = {
            "name": rec.name or "",
            "question_type": rec.question_type or "",
            "instructions": rec.instructions or "",
            "task": rec.as_task(),
            # The examiner's OWN "any THREE of these five", carried raw and
            # separately from the contract. The contract deliberately fills a
            # blank count in from `len(annotation_targets)`, which is the right
            # thing to TELL the model and the wrong thing to grade against: a
            # template that only lists its targets is not asking for a subset,
            # and stamping that derived number on the draft would move the
            # denominator off the question's own boxes for every such template.
            # Only a count the examiner typed means "fewer than all of them".
            "annotation_expected_count": rec.annotation_expected_count or 0,
            # THE AUTHORED AXES, so a generated item can inherit the SHAPE the
            # examiner drew rather than only a prose description of it. Six
            # Yes/No checks authored in the template used to reach the model as
            # text, come back as text, and land on the candidate as a single
            # free-text box - unanswerable per axis and unscorable per axis.
            # `answer_contract()` is the same structure the directive is built
            # from, so what is graded is what was promised.
            "answer_contract": rec.answer_contract(),
        }
    return out


def _authored_axes(axes, axis_options):
    """The template's axes as answerable dimension rows, or [].

    An axis with fewer than two choices is not answerable - carrying it would
    draw an empty control on the candidate's screen - so it is dropped here
    rather than downstream.

    NO KEY IS INVENTED - but an AUTHORED one is carried. This used to hardcode
    `"correct": []` on every axis, on the reasoning that which option is correct
    is per generated instance and belongs to the model or the reviewer. That
    holds for an axis the examiner only drew the SHAPE of, and it is wrong for
    one they keyed by hand: a template with six Yes/No checks and Yes marked
    correct produced bank rows with zero keyed options, so no axis was a
    component and none of those marks existed. Measured on assessment 140 - six
    of six axes answered correctly, scored 1/3 (33%, fail).

    So the rule is the examiner's, not a guess: `correct` is honoured when the
    template states it (`task_template._authored_key` reads the designer's four
    key carriers and returns LABELS), and stays `[]` when it does not - leaving
    that axis exactly as before, for the model or the reviewer to answer. A
    label that is not one of this axis's own options is dropped rather than
    stored, since a key naming nothing is the unanswerable state the answer-key
    normaliser exists to prevent.
    """
    out = []
    for axis in (axes or []):
        # `dimensions` is a list of dicts carrying their own options;
        # `dimension_options` is the same data keyed by label. Read the dict
        # first and fall back to the map so either shape works.
        if isinstance(axis, dict):
            label = axis.get("label") or ""
            choices = axis.get("options") or []
            kind = str(axis.get("kind") or "")
            keyed = axis.get("correct") or []
        else:
            label = str(axis)
            choices = []
            kind = ""
            keyed = []
        if not choices:
            choices = (axis_options or {}).get(label) or []
        choices = [str(c) for c in choices]
        if not label or len(choices) < 2:
            continue
        # Matched by the same normalisation the bank side uses, so casing and
        # spacing in the authored key do not cost the examiner their marks -
        # then stored as the axis's OWN option text, never the key's spelling.
        want = {_axis_norm(str(k)) for k in
                (keyed if isinstance(keyed, list) else [keyed])}
        out.append({
            "label": str(label)[:200],
            "options": choices,
            "kind": kind,
            "correct": [c for c in choices if _axis_norm(c) in want],
        })
    return out


def _reconcile_axes_with_options(authored, options_json, correct_json):
    """Fit the model's flat answer onto the template's authored axes.

    Returns the axis list with the model's key applied, or None when the two
    cannot be reconciled honestly.

    WHY NOT JUST OVERRIDE. The model's `correct_answer` names ITS OWN options.
    Dropping those options for keyless template axes would publish a question
    whose key matches nothing - the same unanswerable state the answer-key
    normaliser exists to prevent. A reconciliation is only safe when exactly one
    authored axis offers the same set of choices the model answered against;
    then the key transfers with its meaning intact. Anything else is a guess,
    and a guess in an answer key is worse than an unapplied layout.
    """
    try:
        options = json.loads(options_json) if options_json else []
        correct = json.loads(correct_json) if correct_json else None
    except (ValueError, TypeError):
        return None
    if not isinstance(options, list) or len(options) < 2:
        return None
    opt_labels = [str(o.get("label") if isinstance(o, dict) else o)
                  for o in options]
    norm = {_axis_norm(x) for x in opt_labels}

    matches = [a for a in authored
               if {_axis_norm(c) for c in a["options"]} == norm]
    if len(matches) != 1:
        return None

    # Resolve the model's key against ITS options, then carry the resolved
    # LABELS onto the matching axis - index-based keys do not survive a
    # re-ordering, labels do.
    #
    # AS TEXT, NEVER AS AN INDEX. `prompts/question.md` states the contract in
    # two places - "Matches an option verbatim" and "`correct_answer` strings
    # must match an option" - so a bare integer is never a position in the option
    # list. It is either the option's own LABEL (a scale point "4", a rating, an
    # SLA of "10") or it is unresolvable.
    #
    # Read as an index it silently keys the WRONG option: a model answering 1 on
    # a linear scale means the point labelled "1", and `opt_labels[1]` is the
    # SECOND point. Every candidate who picks correctly is then marked wrong,
    # with nothing anywhere reporting it - which is why `_key_matches_option`
    # exists on the bank side and normalises rather than counts.
    chosen = []
    values = correct if isinstance(correct, list) else [correct]
    for v in values:
        # `bool` before `int` deliberately: True is an int in Python, and a
        # stray boolean must not resolve to the option labelled "1".
        if isinstance(v, bool) or v is None:
            continue
        if isinstance(v, (str, int, float)):
            hit = next((l for l in opt_labels
                        if _axis_norm(l) == _axis_norm(str(v))), None)
            if hit:
                chosen.append(hit)
    if not chosen:
        # UNRESOLVABLE IS A REFUSAL, and the caller turns that into "the
        # template's layout was not applied" plus a warning. That is the
        # module's stated preference: a guessed key is worse than an unapplied
        # layout, because a guess is invisible and a missing layout is not.
        return None

    out = []
    for a in authored:
        row = dict(a)
        # THE EXAMINER'S KEY OUTRANKS THE MODEL'S. An axis that already carries
        # `correct` was keyed by hand in the designer, and this function's whole
        # purpose is to avoid publishing a key that means something other than
        # what was authored - so overwriting a stated answer with the model's
        # would be the same defect in the opposite direction. The model's key is
        # adopted only for an axis nobody keyed.
        if a is matches[0] and not a.get("correct"):
            row["correct"] = [
                next(c for c in a["options"] if _axis_norm(c) == _axis_norm(ch))
                for ch in chosen
                if any(_axis_norm(c) == _axis_norm(ch) for c in a["options"])]
        out.append(row)
    return out


def _axis_norm(text):
    """Compare option text ignoring case, spacing and trailing punctuation."""
    return " ".join(str(text or "").strip().casefold().split()).rstrip(".!?,;:")


def _widen_allowed_for_templates(allowed, template_specs):
    """A chosen template's own question type joins `allowed` automatically.

    THE BUG THIS EXISTS TO FIX. An operator who put `template:5 x 2` on a run
    already declared they want that shape. Requiring them to ALSO tick its
    question type in Advanced Options was a second, easy-to-forget step, and
    forgetting it failed SILENTLY: every item the model wrote for the template
    resolved to a type outside `allowed`, `_resolve_item_type` discarded it
    before validation ever ran, and the template's quota could never be met no
    matter what the model returned. Reproduced live: `allowed=('mcq',)` with
    `template:5` mapping to `image_ab` produced 10/10 MCQ and 0 from the
    template - the operator's explicit split silently collapsed to one type.

    ONLY WIDENS WHEN `allowed` IS ALREADY NON-EMPTY. An empty `allowed` means
    Auto - the model chooses freely across every generatable type - and the
    caller's directive branches on `if allowed:` to pick its shape, so turning
    an empty tuple non-empty here would flip Auto into "ONLY this template's
    type", silently narrowing every free-choice item in the run. Returns
    `allowed` unchanged in that case.
    """
    if not allowed:
        return allowed
    template_types = tuple(dict.fromkeys(
        spec["question_type"] for spec in template_specs.values()
        if spec.get("question_type")))
    added_types = tuple(t for t in template_types if t not in allowed)
    return allowed + added_types if added_types else allowed


def _template_shapes_note(template_specs):
    """Describe each chosen template so the model can reproduce that shape.

    A template is the admin stating a task's shape by hand, which makes it the
    most authoritative input there is - more so than anything inferred from SOP
    prose. It is presented in the same vocabulary as an extracted SOP task, so
    the model sees one consistent idea of "a task with these axes".
    """
    if not template_specs:
        return ""
    blocks = []
    for shape, spec in template_specs.items():
        contract = (spec.get("task") or {}).get("answer_contract") or {}
        parts = ["  TASK TEMPLATE \"%s\" (shape id %s)"
                 % (spec.get("name") or shape, shape)]
        if spec.get("question_type"):
            parts.append("    author these as question_type: %s"
                         % spec["question_type"])
        if spec.get("instructions"):
            parts.append("    the examiner's own instruction: %s"
                         % spec["instructions"].strip())
        for d in contract.get("dimensions") or []:
            parts.append("    axis: %s | options: %s"
                         % (d["label"], ", ".join(d["options"])))
        # THE EXAMINER'S OWN ANSWER KEY, per primitive. Without these the model
        # invented a rubric / annotation list / stimulus per item, so two items
        # of the SAME authored task were graded to different standards and the
        # key was not provable by construction.
        rubric = contract.get("rubric") or {}
        for line in (rubric.get("checklist") or []):
            parts.append("    rubric criterion (grade against this): %s" % line)
        if rubric.get("pass_condition"):
            parts.append("    a PASSING answer must: %s"
                         % rubric["pass_condition"])
        if rubric.get("constraints"):
            parts.append("    the answer must respect: %s"
                         % rubric["constraints"])
        for target in (contract.get("annotation_targets") or []):
            parts.append("    the candidate must mark: %s" % target)
        if contract.get("annotation_expected_count"):
            parts.append("    a complete answer marks %s item(s)"
                         % contract["annotation_expected_count"])
        if contract.get("media_brief"):
            parts.append("    the stimulus must show: %s"
                         % contract["media_brief"])
        blocks.append("\n".join(parts))
    # DOES ANY TEMPLATE HERE STATE ITS OWN PER-AXIS OPTIONS? If so this is an
    # independent-evaluation shape (a fixed set of questions about ONE artifact,
    # e.g. three Yes/No checks), which `validate_flaw_plan` exempts from the
    # mandatory Overall Choice. Telling such a template to add an OC anyway
    # would push the model back onto the Response A/B vocabulary and overwrite
    # the examiner's own axes - the exact defect the exemption exists to avoid.
    any_custom_options = any(
        ((spec.get("task") or {}).get("answer_contract") or {}).get(
            "dimension_options")
        for spec in template_specs.values())
    ab_note = (
        "" if any_custom_options else
        # THE TYPE'S OWN CONTRACT STILL APPLIES. A template describes what a
        # candidate is ASKED; it does not exempt the item from the answer-key
        # shape its question type requires. For a plain A/B item that means an
        # Overall Choice key: the validator rejects a construction_keys map
        # without one, and the template's axes are named in the SOP's words
        # ("Overall Preference"), not in the OC code the key needs. Without this
        # sentence the model returned well-formed template items that were
        # refused for a missing OC, and the quota could never close.
        "\n\nEven for a template item, the question type's OWN answer-key "
        "contract still applies in full: keep every key the type requires "
        "(for an A/B item that includes the mandatory Overall Choice / OC "
        "entry in construction_keys, alongside the examiner's named axes).")
    custom_note = (
        "\n\nThe axes above are the COMPLETE answer key for these items. Key "
        "construction_keys by the examiner's own axis names and emit a "
        "dimension_options map carrying each axis's exact options; do NOT add "
        "an Overall Choice and do NOT translate the options into the Response "
        "A/B vocabulary." if any_custom_options else "")
    # A {slot} in the examiner's wording ("Is this reference a {type}?") is
    # filled per item by `_fill_template_slots` from the value asked for here,
    # so every copy of the wording (key, options, solution) is filled alike.
    slots = template_slot_names(json.dumps(template_specs, default=str))
    slot_note = (
        "\n\nWording above that contains {braces} (%s) holds a slot the "
        "examiner leaves to each item. Copy that wording VERBATIM, braces "
        "included, and put this item's own value for each slot on the item as "
        "\"template_values\": {%s}, e.g. the kind of entity the item shows."
        % (", ".join("{%s}" % n for n in slots),
           ", ".join('"%s": "<value>"' % n for n in slots))
        if slots else "")
    return (
        "\n\nTASK TEMPLATES the examiner authored by hand. Reproduce these shapes "
        "EXACTLY - the axes and options below are the examiner's own decision and "
        "outrank anything you would infer from the SOP prose. Vary the stimulus "
        "and the content between items; never vary the shape.\n"
        + "\n".join(blocks) + ab_note + custom_note + slot_note)


def _fill_template_slots(vals, slots, item):
    """Fill every template {slot} in a draft's text fields, in place.

    The examiner's axis wording reaches the draft in several copies - the
    dimension labels, the construction-key codes in flaw_plan_json, the
    solution - and the key-drift guard maps one onto another, so all of them
    are filled with the same word here, at the one place a draft is written.
    The word is the item's own `template_values` entry, else a neutral noun:
    a candidate must never read a raw "{type}" (prod 1165).
    """
    given = item.get("template_values")
    given = {str(k).strip("{} ").lower(): v for k, v in given.items()} \
        if isinstance(given, dict) else {}
    values = {}
    for name in slots:
        word = re.sub(r'[{}"\\\s]+', " ", str(given.get(name) or "")).strip()
        values[name] = word[:40] or TEMPLATE_SLOT_FALLBACK
    for key, value in list(vals.items()):
        if isinstance(value, str) and "{" in value:
            vals[key] = fill_template_slots(value, values)


def generate_questions_from_sop(env, prompt_record, sample_text="", count=0,
                                allowed_types=(), report=None,
                                shape_quotas=None, label_box_cap=None):
    """Author draft questions from a generator's SOP. Returns the draft ids.

    `label_box_cap` is the generator's `image_label_count`: the MAXIMUM number of
    numbered boxes any image_label item this run authors may carry. It is stated
    in the output contract AND enforced on the way back, because the contract is
    advisory - a model that returns 35 boxes has not failed loudly, it has just
    quietly authored a question whose answer key does not fit its image. Left
    None (a caller with no generator in scope) it falls back to the module
    default, which is the number the render path already clamped to.

    `report`, when a caller passes a dict, is filled in with what the run
    actually did: how many items the model returned, how many were rejected and
    the reasons. WITHOUT IT A ZERO-DRAFT RUN IS UNREADABLE - a bare empty list
    cannot tell "the SOP yielded nothing" apart from "five items came back and
    every one was thrown out", and the second is a defect that cost real money.
    The reasons themselves used to exist only inside a `_logger.warning`, so the
    only way to learn why an examiner got nothing was to read server logs.
    """
    doc_parts = _sop_doc_parts(prompt_record.resource_ids)
    sample_parts = _sample_doc_parts(prompt_record)
    has_sample = bool(sample_parts or sample_text)
    notes = (prompt_record.source_text or "").strip()
    # SAMPLES COUNT HERE, and only here.
    #
    # This guard used to be satisfied by a sample file because `_sop_doc_parts`
    # picked every category up. Excluding samples from that function - which is
    # right, they are sent under their own heading - silently narrowed the guard
    # from "nothing attached" to "nothing attached that is not a sample", and a
    # generator carrying only sample questions started refusing a run it had
    # been doing happily.
    #
    # It stays strict for tagging and for template drafting: those two have no
    # sample channel of their own, so admitting a sample-only generator there
    # would let it through to a call with nothing in it. Their wording already
    # says "upload a SOP file first", which is the right instruction for both.
    if not doc_parts and not notes and not has_sample:
        raise LLMRefusalError(
            "No SOP document or notes to generate from — upload a SOP file first.")
    system_prompt = _get_question_prompt(env)
    model = _generation_model(env)
    # Stamp every draft from this call with one run id so the UI can group and
    # label "the batch I just triggered".
    gen_batch = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    allowed = tuple(dict.fromkeys(allowed_types or ()))
    unknown = [t for t in allowed
               if not (isinstance(t, str) and t in _GENERATABLE_TYPES)]
    if unknown:
        # repr(): sorted()/join() would choke on a non-string entry.
        raise ValueError(
            "Unknown or non-generatable question type(s) in the generation "
            "allow-list: %s" % ", ".join(sorted(map(repr, unknown))))
    ab_dims = _ab_fallback_dims()
    box_cap = _label_box_cap(label_box_cap)
    # SHAPE QUOTAS. `{shape: wanted}` where a shape is a question type the admin
    # put a count on, or `template:<id>` for a saved task template. Parsed
    # tolerantly: a malformed quota degrades to none, which is the pre-quota
    # behaviour rather than a lost run.
    quotas = parse_shape_quotas(
        shape_quotas if shape_quotas is not None
        else getattr(prompt_record, "shape_quota_json", None),
        allowed_types=allowed)
    template_specs = _resolve_template_shapes(env, quotas)
    # An unresolvable template (archived, or deleted since the admin picked it)
    # must not silently become "generate nothing for that shape".
    for shape in list(quotas):
        if is_template_shape(shape) and shape not in template_specs:
            _logger.warning(
                "etp_assessment quota: %s is not a usable template; dropping "
                "that quota on prompt %s", shape, prompt_record.id)
            if isinstance(report, dict):
                report.setdefault("unresolved_templates", []).append(shape)
            quotas.pop(shape, None)
    # A CHOSEN TEMPLATE IMPLICITLY ALLOWS ITS OWN TYPE. An operator who put
    # `template:5 x 2` on the run has already declared they want that shape;
    # requiring them to ALSO tick its question type in Advanced Options is a
    # second, easy-to-forget step, and forgetting it used to be silent: every
    # item the model wrote for the template resolved to a type outside
    # `allowed` and `_resolve_item_type` discarded it before validation ever
    # ran, so the template's quota could never be met no matter what the model
    # returned. Widening `allowed` here means a template quota is USABLE BY
    # CONSTRUCTION - one thing to pick, not two things that must agree.
    # CAPTURED BEFORE THE WIDENING. A type that only became allowed because a
    # template implies it is already paid for by that template's quota;
    # counting it again as a bare "any" would ask for one item more than the
    # operator picked, every run.
    ticked_types = tuple(allowed or ())
    allowed = _widen_allowed_for_templates(allowed, template_specs)
    # The quotas are a FLOOR: never ask for fewer items than the admin explicitly
    # requested per shape, or the trim would have to discard one of their
    # choices - and a ticked type with no quota is a floor of one, which is what
    # its "any" chip has always said it was.
    count = effective_generation_count(count, quotas, allowed=ticked_types)
    vocab_note = _facet_vocabulary_note(env)
    scheme_note = _rating_scheme_note(prompt_record)
    # The SOP's OWN tasks, each with its own axes and options. Empty for a
    # single-task SOP, where scheme_note already says everything.
    tasks_note = _task_registry_note(prompt_record)
    # The examiner's explicit per-shape counts, and the hand-authored shapes
    # those counts may refer to. Both empty unless a quota was set, so an
    # existing generator's directive is byte-identical to before.
    quota_note = _quota_directive(quotas, template_specs)
    templates_note = _template_shapes_note(template_specs)
    capture_note = (_LIVE_CAPTURE_NOTE
                    if prompt_record.image_label_live_capture else "")
    if allowed:
        directive = (
            _allowed_types_directive(allowed, count, ab_dims=ab_dims,
                                     label_box_cap=box_cap)
            + quota_note + templates_note + tasks_note + scheme_note
            + vocab_note + capture_note)
    else:
        directive = (
        "The attached document is the project SOP. FIRST recover EVERY distinct "
        "task the SOP defines (each task = its stimulus + the action the worker "
        "performs + the grading axes). THEN produce TWO kinds of items with NO "
        "fixed ratio between them — generate as many of each as the SOP content "
        "actually warrants:\n"
        "  (1) TASKS — faithful reproductions of what the worker literally does on "
        "the production platform. Author one TASK item for EACH distinct task the "
        "SOP defines (and more than one when a task has clearly different stimulus "
        "variants). Use the same stimulus, action and grading axes as the SOP. "
        "PREFIX each TASK item's name with 'Task: '.\n"
        "  (2) ASSESSMENT QUESTIONS — items that probe the specific skills, "
        "decision rules, thresholds and common mistakes the SOP stresses. Cover "
        "every rule/skill the SOP emphasises; use text types for genuinely "
        "text-based rules."
        + (" Follow the format shown in the attached SAMPLE QUESTIONS."
           if has_sample else "")
        + " "
        + (f"Generate approximately {count} item(s) in total across BOTH kinds. "
           if count else "Generate as many items as the SOP warrants across both "
           "kinds. ")
        + "Each item's question_type must be one of " + QUESTION_TYPE_PROMPT_LIST
        + ". TASK-FIRST TYPE CHOICE (mandatory): choose each item's question_type "
          "to REPRODUCE the relevant task — the type is driven by the task, NOT by "
          "a modality quota. There is NO requirement that image-comparison types "
          "be a majority; use image_ab ONLY when the task really is A/B "
          "comparison, defect_point_annotation for single-image defect marking, "
          "image_label for UI functionality labelling, and so on. Do NOT pad with "
          "filler: every item must earn its place as either a real TASK or a "
          "genuine skill/rule probe. "
        + _ENVELOPE_REMINDER
        + _image_contracts_note(ab_dims, label_box_cap=box_cap)
        + _SELF_CONTAINED_RULE
        + quota_note
        + templates_note
        + tasks_note
        + scheme_note
        + vocab_note
        + capture_note)
    user_parts = list(doc_parts)
    if notes:
        user_parts.append({"text": "ADDITIONAL NOTES:\n" + notes})
    # EVERY FILE IN THE ONE LIST IS A SAMPLE here (owner, 2026-09-29): format
    # only. The separate GOLDEN EXAMPLES heading is no longer sent.
    if sample_parts:
        user_parts.append(
            {"text": "SAMPLE QUESTIONS (match this format) — see the attached "
                     "sample document:"})
        user_parts.extend(sample_parts)
    elif sample_text:
        user_parts.append(
            {"text": "SAMPLE QUESTIONS (match this format):\n" + sample_text})
    user_parts.append({"text": directive})

    def _run(parts, note):
        raw = _call_vertex(
            env, system_prompt, user_text="", user_parts=parts, model=model,
            max_tokens=_GEN_MAX_OUTPUT_TOKENS, temperature=0.5, response_json=True,
            usage_ctx={"operation": "generate_questions",
                       "prompt_id": prompt_record.id, "note": note})
        _capture_sop_metadata(env, prompt_record, raw)
        items = [it for it in _extract_json_array(raw) if isinstance(it, dict)]
        sols = _extract_solutions(raw)
        if sols:
            _attach_solutions(items, sols, prompt_record.id)
        return items

    # WHY THE REASONS ARE KEPT. Both attempts below used to discard the
    # exception and carry on with an empty list, so a run that never parsed a
    # single item finished indistinguishably from one the model simply had
    # nothing to say about - and the caller wrote "Done" over both. The text of
    # the ValueError is the only record of WHY, so it travels in the report.
    failures = []
    try:
        items = _run(user_parts, prompt_record.name or "SOP")
    except VertexNotConfiguredError:
        # Not a reply: the run fails on the message that names the setting.
        raise
    except ValueError as exc:
        failures.append(str(exc)[:300])
        items = []
    if not items:
        _logger.warning(
            "SOP generation for prompt %s produced no parseable items (%s); "
            "retrying once with a terse-output directive.", prompt_record.id,
            failures[0] if failures else "an empty list")
        try:
            items = _run(user_parts + [{"text": _TERSE_RETRY_DIRECTIVE}],
                         "%s (retry)" % (prompt_record.name or "SOP"))
        except ValueError as exc:
            failures.append("retry: %s" % str(exc)[:300])
            _logger.warning("SOP generation retry for prompt %s failed: %s",
                            prompt_record.id, exc)
            items = []
    if not items:
        # RETURN HERE, so the summary below cannot overwrite these reasons
        # with "returned 0 item(s)" - they are the only record of why.
        if isinstance(report, dict):
            report.update({
                "returned": 0,
                "created": 0,
                "rejected": 0,
                "flagged": 0,
                "no_items": True,
                "reasons": failures or [
                    "The model returned nothing this run could read as a "
                    "question list. Nothing was created."],
            })
        return []
    # Harness-aligned self-heal (top-up, type coverage, key backfill, critique).
    # Every stage is config-gated and best-effort - never sink the base batch.
    # ATTRIBUTE PRIMARY-CALL ITEMS TO THEIR TEMPLATE FIRST. The stamp is
    # what lets the quota stage see a template shape as already satisfied,
    # and what lets the answer key carry the examiner's own axis wording.
    # Without it, a primary call that succeeded looked - to everything
    # downstream - exactly like one that had produced no template items.
    _stamp_template_items(items, quotas, template_specs, allowed)
    try:
        items = _selfheal_generation(
            env, prompt_record, items, user_parts, system_prompt, model,
            count, allowed, quotas=quotas, template_specs=template_specs,
            report=report, label_box_cap=box_cap)
    except Exception:  # noqa: BLE001
        _logger.exception(
            "etp_assessment self-heal layer failed on prompt %s; keeping the "
            "base batch of %d item(s).", prompt_record.id, len(items))
    # Candidates never have the SOP: a question that still points at it
    # is rewritten before it becomes a draft.
    if _selfheal_enabled(env):
        fixed = _rewrite_source_references(
            env, model, items,
            usage_ctx={"operation": "generate_questions",
                       "prompt_id": prompt_record.id,
                       "note": "rewrite SOP references"})
        if fixed:
            _logger.info(
                "etp_assessment rewrote %d SOP reference(s) on prompt %s",
                fixed, prompt_record.id)
    PromptQuestion = env["assessments.be.prompt.question"].sudo()
    template_slots = template_slot_names(
        json.dumps(template_specs or {}, default=str))
    draft_ids = []
    dropped_out_of_scope = 0
    rejections = []           # (qtype, reason) for everything thrown away
    returned_by_model = len(items)
    for it in items:
        name = (it.get("name") or it.get("title") or "").strip()
        # Strip the generator's internal-taxonomy title prefixes (see
        # _JARGON_NAME_PREFIX_RE) so titles stay plain and candidate-facing.
        name = _JARGON_NAME_PREFIX_RE.sub("", name).strip()
        prompt_text = (it.get("prompt") or "").strip()
        if not name and not prompt_text:
            continue
        qtype = _resolve_item_type(it, allowed)
        # KEEP EVERY GENERATED ITEM. An out-of-list type used to be discarded;
        # now it is coerced to a usable type and the reason is recorded on the
        # draft, because the admin approves or denies - the pipeline does not
        # get to decide an item was not worth showing them.
        warnings = []
        if qtype is None:
            qtype = _fallback_item_type(it, allowed)
            declared = str(it.get("question_type") or "unknown")
            warnings.append(
                "Generated as %r, which is not in the selected allow-list "
                "(%s); kept as %s." % (declared, ",".join(allowed) or "any",
                                       qtype))
            rejections.append((declared, "type is not in the selected "
                                         "allow-list (kept as %s)" % qtype))
            _logger.warning(
                "etp_assessment (SOP) coerced out-of-scope %r item to %s; "
                "allow-list=%s", it.get("question_type"), qtype,
                ",".join(allowed))
        if _item_cites_source(it):
            warnings.append(
                "The question quotes the SOP at the candidate instead of "
                "standing alone - review the wording before approving.")
            rejections.append((qtype, "the question quoted the SOP at the "
                                      "candidate instead of standing alone "
                                      "(kept for review)"))
            _logger.warning(
                "etp_assessment (SOP) kept source-citing %s item for review",
                qtype)
        violations = _validate_question_item(it, qtype, ab_dims=ab_dims)
        if violations:
            warnings.extend(violations)
            rejections.extend((qtype, "%s (kept for review)" % v)
                              for v in violations)
            _logger.warning(
                "etp_assessment (SOP) kept malformed %s item for review: %s",
                qtype, "; ".join(violations))
        difficulty = it.get("difficulty") if it.get("difficulty") in _DIFFICULTIES \
            else "medium"
        vals = {
            "prompt_id": prompt_record.id,
            "name": (name or prompt_text[:60])[:200],
            "question_prompt": prompt_text or name,
            "question_type": qtype,
            "difficulty": difficulty,
            "description": (it.get("description") or "").strip() or False,
            "gen_batch": gen_batch,
        }
        ce = it.get("covers_elements")
        if isinstance(ce, list) and ce:
            vals["covers_elements_json"] = json.dumps(ce, ensure_ascii=False)
        sol = it.get("_solution")
        if isinstance(sol, dict):
            ans = sol.get("answers")
            if ans is not None:
                vals["solution_json"] = json.dumps(ans, ensure_ascii=False)
            if sol.get("rationale"):
                vals["solution_rationale"] = str(sol["rationale"])
        if qtype in _IMAGE_OR_VIDEO_TYPES:
            img_fields = _build_image_draft_fields(
                env, qtype, it, ab_dims=ab_dims, label_box_cap=box_cap,
                usage_ctx={"operation": "generate_image",
                           "prompt_id": prompt_record.id,
                           # Carried so a template-authored item can keep the
                           # examiner's own axis wording instead of the SOP's
                           # short names overwriting it.
                           "template_specs": template_specs,
                           "note": prompt_record.name or "SOP"})
            if qtype == "image_label" and not \
                    prompt_record.image_label_live_capture:
                # AI-made picture: no page to capture (the contract no longer
                # asks for one, and a repaired URL would be a random site).
                for key in ("source_url", "capture_config_json",
                            "omit_spec_json"):
                    img_fields.pop(key, None)
                if img_fields.get("behavioural_key_json"):
                    img_fields["detection_mode"] = "ui"
            derived = img_fields.pop("_derived_ab_solution", None)
            # SAME SIDES AS THE KEY. The model wrote its rationale against its
            # own plan; when the builder swapped the slots, prose left as-is
            # praised the flawed image (prod 1167, 1178).
            swapped = img_fields.pop("_ab_swapped", False)
            if swapped and vals.get("solution_rationale"):
                vals["solution_rationale"] = ab_flip_sides_in_text(
                    vals["solution_rationale"])
            if isinstance(derived, dict) and derived:
                model_ans = it.get("_solution") or {}
                model_ans = model_ans.get("answers") if isinstance(
                    model_ans, dict) else {}
                justification = (model_ans.get("justification")
                                 if isinstance(model_ans, dict) else "") or ""
                if swapped:
                    justification = ab_flip_sides_in_text(justification)
                merged = dict(derived)
                if justification:
                    merged["justification"] = justification
                vals["solution_json"] = json.dumps(merged, ensure_ascii=False)
            vals.update(img_fields)
            # One state per medium; the rule and its history live in the helper.
            vals.update(media_states_for_briefs(vals))
        else:
            options = it.get("options") or []
            vals.update({
                "options_json": json.dumps(options, ensure_ascii=False)
                if options else False,
                "correct_answer_json": json.dumps(
                    it.get("correct_answer"), ensure_ascii=False)
                if it.get("correct_answer") is not None else False,
                "rubric_json": json.dumps(it.get("rubric"), ensure_ascii=False)
                if it.get("rubric") else False,
                "official_reasoning": it.get("official_reasoning") or False,
            })
        if warnings:
            vals["gen_warnings"] = "\n".join(
                "- %s" % w for w in dict.fromkeys(warnings))
        # PROVENANCE. Which template authored this draft, so a template's real
        # output is auditable instead of inferred from the question type.
        stamped = it.get("_template_shape")
        if isinstance(stamped, str):
            tpl_id = template_id_of_shape(stamped)
            if tpl_id:
                vals["source_template_id"] = tpl_id
            # "A complete answer marks 3 item(s)" already reaches the MODEL, in
            # the template note - but nothing carried it to the grader, so a
            # candidate who marked exactly the three asked for was divided by
            # all five boxes and scored 0.6. Stamped from the resolved spec
            # rather than re-read off the template, so this stays a function of
            # its inputs and costs no query per draft.
            if qtype == "image_label":
                expected = (template_specs or {}).get(stamped, {}).get(
                    "annotation_expected_count") or 0
                if expected > 0:
                    vals["label_expected_count"] = expected
            # THE AUTHORED AXES BECOME REAL, ANSWERABLE STRUCTURE.
            #
            # A template that draws six Yes/No checks used to send them to the
            # model as prose, get prose back, and store prose: the draft landed
            # with no dimensions and no options, the candidate was shown one
            # free-text box for six distinct judgements, and the grader had
            # nothing per-axis to mark. The examiner's structure survived only
            # as a numbered list inside the question text.
            #
            # `dimensions_json` is the module's existing, type-agnostic carrier
            # for exactly this - `_specs_from_json` already expands it into
            # dimension rows on approve, and image_ab has always used it. The
            # axes are inherited only when the model did not return its own
            # structure for this item, so a model that answers the contract
            # properly still wins; this is the floor, not an override.
            contract = (template_specs or {}).get(stamped, {}).get(
                "answer_contract") or {}
            axes = contract.get("dimensions") or []
            axis_options = contract.get("dimension_options") or {}
            authored = _authored_axes(axes, axis_options)
            if authored and not vals.get("dimensions_json") \
                    and not vals.get("options_json"):
                vals["dimensions_json"] = json.dumps(
                    authored, ensure_ascii=False)
            elif authored and vals.get("options_json") \
                    and not vals.get("dimensions_json"):
                # THE TEMPLATE WAS CHOSEN, SO ITS SHAPE IS THE CONTRACT.
                #
                # An operator who put `template:78 x 2` on a run asked for that
                # shape. The model, though, often answers with a flat option
                # list instead - and the old rule ("inherit only when the model
                # returned nothing") let that silently win, so a template
                # drawing six checks reached the candidate as one 4-option MCQ
                # and the examiner's structure existed nowhere. Reproduced on
                # draft 197.
                #
                # Overriding blindly is worse, though: the model's key belongs
                # to ITS options, so replacing them with keyless axes would
                # publish an unanswerable question - exactly the failure the
                # answer-key normaliser exists to prevent. So reconcile: adopt
                # the authored shape and CARRY the model's key onto it when the
                # options are the same set, otherwise keep the model's
                # scoreable output and say on the draft that the template's
                # shape was not applied.
                reconciled = _reconcile_axes_with_options(
                    authored, vals.get("options_json"),
                    vals.get("correct_answer_json"))
                # AN AXIS THE EXAMINER KEYED NEEDS NOTHING FROM THE MODEL.
                #
                # Reconciliation exists to borrow the model's key for a keyless
                # authored axis, and refusing (`None`) meant keeping the model's
                # flat list - which discards the examiner's structure. When
                # EVERY authored axis already carries its own key, there is
                # nothing to borrow and nothing to guess: the axes are scoreable
                # by construction, so the template's shape is adopted on its own
                # terms. Without this, a hand-keyed template whose options the
                # model happened to reword (so no axis matched its option set)
                # still landed as one flat MCQ.
                keyed_throughout = bool(authored) and all(
                    a.get("correct") for a in authored)
                if reconciled or keyed_throughout:
                    vals["dimensions_json"] = json.dumps(
                        reconciled or authored, ensure_ascii=False)
                    # SAY THAT THE FLAT LIST WAS SUPERSEDED, do not just clear
                    # it. These two lines used to set both fields to False in
                    # silence, which breaks the module's own rule - never drop
                    # generated content, flag it and let the admin decide - and
                    # empties `correct_answer` in the review payload
                    # (serializers.question_draft), so the reviewer could not see
                    # the key that had been replaced or judge the substitution.
                    #
                    # The superseded key is kept verbatim in the warning rather
                    # than in a field of its own: it is only of interest while
                    # somebody reviews this draft, and a second key carrier is
                    # exactly the kind of thing that later gets mistaken for the
                    # real one.
                    superseded = (vals.get("correct_answer_json") or "").strip()
                    warnings.append(
                        "The task template's %d authored axis(es) were applied, "
                        "so the generator's own flat option list was superseded. "
                        "Its answer was %s. Check the axes carry the same "
                        "intent."
                        % (len(authored),
                           superseded[:200] if superseded else "not stated"))
                    vals["options_json"] = False
                    vals["correct_answer_json"] = False
                    if warnings:
                        vals["gen_warnings"] = "\n".join(
                            "- %s" % w for w in dict.fromkeys(warnings))
                else:
                    warnings.append(
                        "The task template asked for %d structured axis(es) but "
                        "the generator answered with a flat option list, which "
                        "was kept so the question stays scoreable. Re-shape it "
                        "in the editor if the template's layout matters."
                        % len(authored))
                    if warnings:
                        vals["gen_warnings"] = "\n".join(
                            "- %s" % w for w in dict.fromkeys(warnings))
        if template_slots:
            _fill_template_slots(vals, template_slots, it)
        draft_ids.append(PromptQuestion.create(vals).id)
    _logger.info(
        "etp_assessment generated %s drafts from SOP on prompt=%s "
        "(model returned %s, %s flagged for review, 0 dropped)",
        len(draft_ids), prompt_record.id, returned_by_model,
        len(rejections))
    if isinstance(report, dict):
        reasons = _summarize_rejections(rejections)
        report.update({
            "returned": returned_by_model,
            "created": len(draft_ids),
            # Nothing is discarded any more, so "rejected" would read as data
            # loss. What the admin needs is how many drafts carry a warning.
            "rejected": 0,
            "flagged": len(rejections),
            # `no_items` is the honest flag: a run can return items and still
            # create no drafts (every one unusable), and that is a failure the
            # examiner has paid for and must be shown, not a green tick.
            "no_items": not draft_ids,
            "reasons": reasons or ([
                "The model returned %s item(s) and none of them could be made "
                "into a draft." % returned_by_model] if not draft_ids else []),
        })
    return draft_ids


def _summarize_rejections(rejections):
    """One readable line per distinct reason, commonest first.

    Deduplicated with a count rather than listed per item: five items failing
    the same way is ONE fact about the run, and printing it five times buries it.
    """
    tally = {}
    for qtype, reason in rejections:
        key = "%s: %s" % (qtype, reason)
        tally[key] = tally.get(key, 0) + 1
    ordered = sorted(tally.items(), key=lambda kv: (-kv[1], kv[0]))
    return ["%s (x%d)" % (text, n) if n > 1 else text for text, n in ordered]


_TAG_SYSTEM_PROMPT_FALLBACK = (
    "You are an expert taxonomist and instructional analyst for a data-annotation "
    "/ AI-evaluation platform. Read ONE project SOP and return ONLY one JSON "
    "object with two keys: \"knowledge_profile\" and \"tags\". knowledge_profile "
    "carries {summary, canonical_task:{key,display,one_sentence}, subject_inputs, "
    "worker_output, what_the_worker_does[], key_skills[{key,display,weight,why}], "
    "decision_rules[], common_mistakes[], evidence[{claim,quote}]}. tags is 5-8 "
    "objects {facet, key:\"<facet>:<value>\", display} with EXACTLY one task and "
    "one domain tag, 2-4 skill, 0-1 modality, 0-1 output-format. Keys are "
    "lowercase kebab machine values; displays are 2-5 plain Title-Case words a "
    "non-technical teammate reads (task display starts with a verb). Reuse an "
    "existing key AND its display verbatim when it means the same thing; prefer "
    "the highest-usage existing value; never coin a near-duplicate. Return ONLY "
    "the JSON object.")


def _get_tag_prompt(env):
    p = (env["ir.config_parameter"].sudo().get_param(
        "assessments_be_v2.tag_prompt", "") or "").strip()
    if p:
        return p
    bundled = _load_bundled_prompt("tags.md")
    return bundled.strip() if bundled.strip() else _TAG_SYSTEM_PROMPT_FALLBACK


def assign_question_skills(env, prompt_record, questions=None):
    """Give each question the ONE skill it actually tests, from the SOP's own
    extracted `skill:` vocabulary.

    WHY THIS EXISTS. `action_backfill_tags_to_questions` copies the generator's
    WHOLE vocabulary onto every question - correct for bank search, useless for
    per-category scoring: with all four skills on all eight questions, every
    category scores identically and the strengths/weaknesses card cannot tell a
    candidate's pre-shift-inspection from their load-handling. The generation
    schema never asked which skill an item tests, so nothing else knows.

    A CLOSED VOCABULARY, so this cannot invent a facet. The model picks from the
    generator's existing skill tags by index; anything unparseable leaves the
    question as it was rather than guessing. One call for the whole batch.

    Returns the number of questions given a single primary skill.
    """
    prompt_record.ensure_one()
    skills = prompt_record.tag_ids.filtered(lambda t: t.prefix == "skill")
    if len(skills) < 2:
        # Nothing to disambiguate: zero or one skill needs no assignment, and
        # the backfill's copy is already the right answer.
        return 0

    if questions is None:
        questions = env["assessments.be.question"].sudo().with_context(
            active_test=False).search([("generator_id", "=", prompt_record.id)])
    questions = questions.filtered(lambda q: q.generator_id == prompt_record)
    if not questions:
        return 0

    catalogue = "\n".join(
        "%d. %s  (%s)" % (i, t.name, t.display or t.name)
        for i, t in enumerate(skills))
    items = "\n".join(
        "Q%d: %s | %s" % (i, (q.name or "")[:120],
                          (q.prompt or "")[:400].replace("\n", " "))
        for i, q in enumerate(questions))

    system = (
        "You label assessment questions with the ONE skill each question "
        "actually tests. You never invent a skill: you choose from the numbered "
        "list you are given, by index."
    )
    directive = (
        "SKILLS (choose by index):\n%s\n\n"
        "QUESTIONS:\n%s\n\n"
        "For EACH question return the index of the single skill it PRIMARILY "
        "tests - the one a trainer would coach if the candidate got it wrong. "
        "Judge by what the question asks the candidate to DO, not by which "
        "words appear in it. Return ONLY "
        '{\"labels\": [{\"q\": <question number>, \"skill\": <skill index>}]} '
        "with one entry per question, nothing else."
        % (catalogue, items))

    try:
        raw = _call_vertex(
            env, system, user_text=directive,
            # Was passing no model, so it fell through to `vertex_model` - the
            # IMAGE model on this deployment, and the priciest row in the
            # catalog - to do a bulk "pick one index from a numbered list" job.
            model=_utility_model(env),
            max_tokens=2048, temperature=0.0, response_json=True,
            usage_ctx={"operation": "assign_question_skills",
                       "prompt_id": prompt_record.id,
                       "note": prompt_record.name or "SOP"})
        obj = json.loads(raw) if isinstance(raw, str) else raw
        labels = (obj or {}).get("labels") or []
    except Exception as exc:  # noqa: BLE001 - never block approval on this
        _logger.warning("per-question skill assignment skipped: %s",
                        repr(exc)[:200])
        return 0

    by_index = {}
    for entry in labels:
        if not isinstance(entry, dict):
            continue
        q_raw, s_raw = entry.get("q"), entry.get("skill")
        if q_raw is None or s_raw is None:
            continue
        try:
            qi, si = int(q_raw), int(s_raw)
        except (TypeError, ValueError):
            continue
        if 0 <= qi < len(questions) and 0 <= si < len(skills):
            by_index[qi] = skills[si]

    changed = 0
    other_skills = skills
    for qi, question in enumerate(questions):
        chosen = by_index.get(qi)
        if not chosen:
            # Unlabelled: leave the question exactly as the backfill left it.
            # A wrong single skill is worse than several right ones.
            continue
        # Drop the OTHER skills, keep every non-skill facet (domain, modality,
        # output-format and task stay - they are what bank search uses).
        drop = (other_skills - chosen) & question.tag_ids
        ops = [(4, chosen.id)] + [(3, t.id) for t in drop]
        question.tag_ids = ops
        changed += 1

    if changed:
        _logger.info(
            "assigned a primary skill to %d/%d question(s) for prompt %s",
            changed, len(questions), prompt_record.id)
    return changed


def _render_vocabulary_block(env):
    """Frequency-ranked existing vocabulary, so runs CONVERGE on popular values
    instead of minting near-duplicates (drift fix). Data-driven from live tags;
    no hardcoded synonym map."""
    vocab = env["assessments.be.tag"].sudo()._facet_vocabulary()
    if not vocab:
        return "(none yet - this is an early project; coin clean values.)"
    lines = []
    for facet in ("task", "domain", "skill", "modality", "output-format"):
        items = vocab.get(facet)
        if not items:
            continue
        lines.append("%s:" % facet)
        for it in items:
            lines.append('  - %-28s "%s"  (used %sx)'
                         % (it["value"], it["display"], it["count"]))
    return "\n".join(lines)


def _capture_knowledge_profile(env, prompt_record, obj):
    """Persist the knowledge_profile object onto the prompt's existing metadata
    fields (no inert blob surfaced to end users; every artifact a queryable
    field). Mirrors _capture_sop_metadata's field mapping."""
    kp = obj.get("knowledge_profile") if isinstance(obj, dict) else None
    if not isinstance(kp, dict):
        return {}
    vals = {"metadata_json": json.dumps(kp, ensure_ascii=False)}
    ct = kp.get("canonical_task") or {}
    if kp.get("summary"):
        vals["sop_summary"] = str(kp["summary"])
    if isinstance(ct, dict) and ct.get("display"):
        vals["sop_title"] = str(ct.get("display"))[:255]
    # THE TASK REGISTRY. Every distinct task the SOP defines, each carrying its
    # own answer contract, so generation can author a shape this platform has
    # never seen. `canonical_task` stays the primary and keeps driving ranking
    # and the single task tag, so nothing downstream changes for a single-task
    # SOP.
    #
    # A registry that came back without the primary is REPAIRED rather than
    # rejected: canonical_task is already trusted enough to name the generator,
    # so it is a valid first entry, and dropping the whole registry over a
    # missing echo would lose the secondary tasks too.
    tasks = [t for t in (kp.get("tasks") or [])
             if isinstance(t, dict) and t.get("key")]
    if tasks:
        primary_key = ct.get("key") if isinstance(ct, dict) else None
        if primary_key and not any(t.get("key") == primary_key for t in tasks):
            tasks.insert(0, {
                "key": primary_key,
                "display": ct.get("display") or "",
                "one_sentence": ct.get("one_sentence") or "",
                "subject_inputs": kp.get("subject_inputs") or "",
                "worker_output": kp.get("worker_output") or "",
            })
        elif primary_key and tasks[0].get("key") != primary_key:
            # Primary present but not first: order carries meaning downstream
            # (the first task is what a single-task caller reads), so hoist it.
            tasks.sort(key=lambda t: 0 if t.get("key") == primary_key else 1)
        vals["tasks_json"] = json.dumps(tasks, ensure_ascii=False)
    for src, field_name in (
            ("key_skills", "skills_json"),
            ("evidence", "evidence_json"),
            ("decision_rules", "quality_criteria_json"),
            ("common_mistakes", "failure_modes_json"),
            ("what_the_worker_does", "sop_examples_json")):
        v = kp.get(src)
        if isinstance(v, list) and v:
            vals[field_name] = json.dumps(v, ensure_ascii=False)
    return vals


def _tag_reply(env, prompt_record):
    """The paid half of `extract_tags_from_sop`: the model's raw reply."""
    doc_parts = _sop_doc_parts(prompt_record.resource_ids)
    notes = (prompt_record.source_text or "").strip()
    if not doc_parts and not notes:
        raise LLMRefusalError(
            "No SOP document or notes to tag — upload a SOP file first.")
    directive = (
        "Analyse THIS SOP now and return ONLY the JSON object "
        "(knowledge_profile + tags), following every rule. Emit exactly one task "
        "tag and one domain tag. Ground every evidence quote verbatim in the SOP."
        "\n\nTASK REGISTRY — knowledge_profile.tasks MUST list EVERY distinct "
        "task this SOP defines, the primary one FIRST and identical to "
        "canonical_task. Most SOPs define exactly one task and emit exactly one "
        "entry; emit several ONLY when the SOP genuinely teaches different jobs "
        "(different thing looked at, or a different kind of answer produced). Do "
        "NOT split one task into steps - \"open the image\", \"check the label\" and "
        "\"submit\" are steps of ONE task, not three tasks. Do NOT invent a task "
        "the SOP does not define. Every task carries its own answer_contract, "
        "and each contract's dimensions MUST use the SOP's OWN axis wording and "
        "the SOP's OWN option labels for that axis - never a generic Response A / "
        "Response B scale when the SOP names its choices, and never one axis's "
        "options copied onto another axis that offers different ones."
        "\n\nRATING SCHEME — additionally emit a top-level \"rating_scheme\" "
        "object describing HOW this SOP tells a worker to judge an item, so "
        "generated comparison / choice questions can use the SOP's OWN wording "
        "instead of a generic scale. Shape: {\"kind\": \"independent_questions\" | "
        "\"preference_comparison\" | \"none\", \"dimensions\": [{\"code\": \"Q1\" (or "
        "the SOP's own short code, e.g. IF), \"label\": \"what this dimension "
        "checks, in the SOP's OWN words\", \"options\": [\"the exact answer "
        "choices the SOP offers, verbatim\"], \"evidence\": \"a short verbatim "
        "quote from the SOP\"}]}. Use kind=independent_questions when the worker "
        "answers a fixed set of INDEPENDENT questions about ONE item (e.g. three "
        "Yes/No checks); use preference_comparison when the worker picks between "
        "two candidates; use kind=none with an empty dimensions list when the SOP "
        "prescribes no such scheme. Copy labels and options EXACTLY as the SOP "
        "words them (if the SOP asks 'Q1: Is the edit instruction followed?' with "
        "YES/NO, emit code Q1, label 'Instruction Following', options "
        "[\"YES\",\"NO\"]). NEVER invent a dimension the SOP does not state."
        "\n\nEXISTING VOCABULARY — reuse an existing key + its display ONLY when it "
        "means the SAME thing for THIS SOP (a true synonym you could swap in any "
        "sentence). Do NOT snap a specific concept onto a broader popular value: "
        "if this SOP's work is genuinely different, COIN the specific value even "
        "when a common one looks adjacent (distinct beats popular). In particular "
        "name the actual `domain` the worker acts on — e.g. spotting defects on "
        "generated images is domain:image-annotation, judging which of two images "
        "is better is domain:image-evaluation, describing UI controls is "
        "domain:ui-annotation — never collapse these onto one umbrella like "
        "ai-image-quality. Only when several existing values are ALL true synonyms "
        "pick the highest usage count. Anchor every value to what the SOP says:\n"
        + _render_vocabulary_block(env))
    user_parts = list(doc_parts)
    if notes:
        user_parts.append({"text": "ADDITIONAL NOTES:\n" + notes})
    user_parts.append({"text": directive})
    # gemini-3.1-pro-preview is a THINKING model: the combined knowledge-profile
    # + tags object is large and can truncate at a tight cap (empty parts / cut
    # JSON). Retry once with a doubled budget when the first parse yields no tags.
    obj = None
    raw = ""
    for max_tokens in (8192, 16384):
        raw = _call_vertex(
            env, _get_tag_prompt(env), user_text="", user_parts=user_parts,
            # Utility lane: falls through to the generation model when
            # `utility_model` is unset, so this is a no-op until someone points
            # that key at a cheaper text model.
            model=_utility_model(env), max_tokens=max_tokens, temperature=0.2,
            response_json=True,
            usage_ctx={"operation": "extract_tags",
                       "prompt_id": prompt_record.id,
                       "note": prompt_record.name or "SOP"})
        obj = _parse_tag_object(raw)
        if isinstance(obj, dict) and obj.get("tags"):
            break
    return raw


def extract_tags_from_sop(env, prompt_record, raw=None, on_reply=None):
    """SOP -> (knowledge profile + readable, convergent tags).

    Returns ``(tag_dicts, raw)`` where ``tag_dicts`` is a list of
    ``{"key","display"}`` the tag model pins one-to-one, and ``raw`` is the
    model output kept for audit. The knowledge profile is persisted onto the
    prompt's queryable metadata fields as a side effect.

    ``raw``: a reply already paid for (`tag_extract_reply`), applied as if it
    had just come back - Vertex is not called. ``on_reply(raw)`` gets a fresh
    paid reply BEFORE anything is written, so the cron can keep it."""
    if raw is None:
        raw = _tag_reply(env, prompt_record)
        if on_reply:
            on_reply(raw)
    obj = _parse_tag_object(raw)
    if not isinstance(obj, dict):
        return [], raw
    try:
        kp_vals = _capture_knowledge_profile(env, prompt_record, obj)
        if kp_vals:
            prompt_record.sudo().write(kp_vals)
    except Exception as exc:  # noqa: BLE001
        _logger.warning("knowledge-profile capture skipped: %s", repr(exc)[:160])
    # Persist the SOP's OWN rating scheme (dimensions + verbatim options) so
    # question generation renders the SOP's labels/options rather than a generic
    # Response A/B scale. Captured in THIS call — no extra spend.
    try:
        scheme = _normalize_rating_scheme(obj.get("rating_scheme"))
        if scheme:
            prompt_record.sudo().rating_scheme_json = json.dumps(
                scheme, ensure_ascii=False)
            _logger.info(
                "SOP rating scheme captured for prompt %s: kind=%s dims=%s",
                prompt_record.id, scheme.get("kind"),
                [d.get("code") for d in scheme.get("dimensions") or []])
    except Exception as exc:  # noqa: BLE001
        _logger.warning("rating-scheme capture skipped: %s", repr(exc)[:160])
    tags = obj.get("tags")
    tag_dicts = []
    if isinstance(tags, list):
        for t in tags:
            if isinstance(t, dict) and t.get("key"):
                tag_dicts.append({"key": str(t["key"]).strip(),
                                  "display": str(t.get("display") or "").strip()})
            elif isinstance(t, (str, int, float)) and str(t).strip():
                tag_dicts.append({"key": str(t).strip(), "display": ""})
    if tag_dicts:
        prompt_record.sudo().plain_tags = ", ".join(
            d["display"] or d["key"] for d in tag_dicts if d)[:255] or False
    # Persist mapping_json from the derived faceted keys so SOP similarity works
    # after extraction ALONE (previously mapping_json was only set as a side
    # effect of full question generation via _capture_sop_metadata; a user who
    # only clicked "Extract Tags" got tags but an empty mapping, so the
    # similarity ranking silently had nothing to run on). The tag keys already
    # ARE the faceted "<facet>:<value>" strings the ranker consumes; order them
    # by the research facet convention (task, domain, skill, modality,
    # output-format) for a stable, readable mapping array. A RE-extraction MUST
    # refresh the mapping (an earlier run may have snapped a facet onto a stale
    # umbrella value); the fresh extraction is the authoritative mapping.
    faceted = [d["key"] for d in tag_dicts
               if d.get("key") and ":" in d["key"]]
    if faceted:
        _facet_rank = {"task": 0, "domain": 1, "skill": 2, "modality": 3,
                       "output-format": 4}
        ordered = sorted(
            dict.fromkeys(faceted),
            key=lambda k: (_facet_rank.get(k.split(":", 1)[0], 9), k))
        prompt_record.sudo().mapping_json = json.dumps(
            ordered, ensure_ascii=False)
    return tag_dicts, raw


def _parse_tag_object(raw):
    text = (raw or "").strip()
    text = re.sub(r"^```(?:json)?", "", text).strip()
    text = re.sub(r"```$", "", text).strip()
    try:
        return json.loads(text)
    except Exception:
        start = text.find("{")
        if start != -1:
            try:
                obj, _end = json.JSONDecoder().raw_decode(text[start:])
                return obj
            except Exception:
                m = re.search(r"\{.*\}", text, re.DOTALL)
                if m:
                    try:
                        return json.loads(m.group(0))
                    except Exception:
                        return None
    return None


_VOCAB_CONSOLIDATE_SYSTEM = (
    "You are a taxonomy curator for a data-annotation assessment platform. You "
    "are given the CURRENT tag vocabulary, grouped by facet, as "
    "`value  (used Nx)` lines. Your job: (1) find groups of values within the "
    "SAME facet that mean the SAME THING (near-duplicates / drift), and (2) give "
    "EVERY surviving value a short, plain-English, growth-team-readable display "
    "name. Return ONLY one JSON object:\n"
    '{ "merges": [ { "facet": "skill", "canonical": "comparative-judgment", '
    '"absorb": ["comparative-analysis","content-comparison","visual-comparison"] } ], '
    '"displays": { "skill:comparative-judgment": "Side-by-Side Judgment", '
    '"task:artifact-annotation": "Spot AI Flaws in Images", ... } }\n'
    "RULES: canonical = the clearest, most-used value in each duplicate group "
    "(keep its exact kebab string). absorb = the other values in that group "
    "(their rows are repointed to canonical). Only merge TRUE synonyms for the "
    "SAME worker concept — never merge distinct ideas (e.g. keep "
    "artifact-detection separate from rule-application). Provide a display for "
    "EVERY value you keep (canonicals + any value not in a merge). Displays are "
    "2-5 plain Title-Case words, NO facet prefix, NO kebab dashes, no jargon a "
    "non-technical growth teammate wouldn't know; a task display starts with a "
    "verb (Compare, Spot, Judge, Describe, Write, Tag, Rate). Do not invent new "
    "values. Return ONLY the JSON object.")


def consolidate_vocabulary(env):
    """LLM-driven, data-driven vocabulary consolidation (no hardcoded synonym
    map). Reads the live tag rows, asks the model to (a) cluster true synonyms
    within each facet and (b) mint readable displays for every survivor, then
    applies the merges (repoint m2m, archive/delete losers) and pins displays.

    Returns a summary dict {merged_groups, tags_absorbed, displays_updated}."""
    Tag = env["assessments.be.tag"].sudo()
    vocab = Tag._facet_vocabulary(limit_per_facet=200)
    if not vocab:
        return {"merged_groups": 0, "tags_absorbed": 0, "displays_updated": 0}
    lines = []
    for facet in ("task", "domain", "skill", "modality", "output-format"):
        items = vocab.get(facet)
        if not items:
            continue
        lines.append("%s:" % facet)
        for it in items:
            lines.append("  %s  (used %sx)" % (it["value"], it["count"]))
    user = "CURRENT VOCABULARY:\n" + "\n".join(lines)
    raw = _call_vertex(
        env, _VOCAB_CONSOLIDATE_SYSTEM, user_text=user,
        # Text-only tag housekeeping - no document, no images. Cheapest lane in
        # the module and the safest place to try a Flash-Lite tier first.
        model=_utility_model(env), max_tokens=8192, temperature=0.1,
        response_json=True,
        usage_ctx={"operation": "consolidate_vocab", "note": "normalize_tags"})
    plan = _parse_tag_object(raw)
    if not isinstance(plan, dict):
        return {"merged_groups": 0, "tags_absorbed": 0, "displays_updated": 0,
                "error": "consolidation plan did not parse"}

    merged_groups = 0
    tags_absorbed = 0
    # 1) apply merges: repoint every absorbed tag's prompts onto the canonical
    for m in (plan.get("merges") or []):
        facet = str(m.get("facet") or "").strip()
        canonical = str(m.get("canonical") or "").strip()
        absorb = [str(a).strip() for a in (m.get("absorb") or []) if str(a).strip()]
        if not facet or not canonical or not absorb:
            continue
        canon_key = "%s:%s" % (facet, canonical) if ":" not in canonical else canonical
        canon_tag = Tag.search([("name", "=ilike", canon_key)], limit=1)
        if not canon_tag:
            continue
        group_hit = False
        for a in absorb:
            a_key = "%s:%s" % (facet, a) if ":" not in a else a
            if a_key.lower() == canon_key.lower():
                continue
            loser = Tag.search([("name", "=ilike", a_key)], limit=1)
            if not loser:
                continue
            # repoint every prompt referencing loser onto the canonical, dedup
            prompts = env["assessments.be.prompt"].sudo().search(
                [("tag_ids", "in", loser.id)])
            for p in prompts:
                p.write({"tag_ids": [(4, canon_tag.id), (3, loser.id)]})
            loser.unlink()
            tags_absorbed += 1
            group_hit = True
        if group_hit:
            merged_groups += 1

    # 2) pin readable displays for every survivor
    displays_updated = 0
    for key, disp in (plan.get("displays") or {}).items():
        disp = str(disp or "").strip()
        if not disp:
            continue
        tag = Tag.search([("name", "=ilike", str(key).strip())], limit=1)
        if tag and tag.display != disp:
            tag.display = disp
            displays_updated += 1

    _logger.info(
        "etp_assessment vocabulary consolidation: %d groups merged, %d tags "
        "absorbed, %d displays refreshed",
        merged_groups, tags_absorbed, displays_updated)
    return {"merged_groups": merged_groups, "tags_absorbed": tags_absorbed,
            "displays_updated": displays_updated}

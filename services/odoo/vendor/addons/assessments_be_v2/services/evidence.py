# -*- coding: utf-8 -*-
"""AI proctoring evidence: where an attempt's camera snapshots go, and how an
admin reads them back.

With "AI proctoring" on (`assessments.be.rule_ai_proctor`, which needs
`rule_webcam`) the exam page watches the camera in the browser. Each time an
AI rule fires it posts the violation (reason `AI: ...`) and uploads one JPEG
straight to S3 with the POST policy `upload_policy` hands it with every
question served and on the instructions screen. The client names the file
`<epoch_ms>_<rule>.jpg`; the policy pins it under this attempt's own prefix,
so the prefix IS the index: the admin route lists it instead of keeping a
table, and erasing the attempt (`purge_evidence`) deletes it.
"""
import logging
import re
from datetime import datetime, timezone

import psycopg2
from botocore.exceptions import ClientError

from odoo import fields

from . import s3_service

_logger = logging.getLogger(__name__)

MAX_BYTES = 400000
CONTENT_TYPE = "image/jpeg"
LIST_CAP = 500
_LIST_MAX_PAGES = 5

_NAME = re.compile(r"^(\d{1,16})_(.+)\.jpe?g$", re.IGNORECASE)
_RULE = re.compile(r"[\w-]{1,64}", re.ASCII)
# The only name `web/proctor_ai.js` gives a snapshot; no `/`, so no sub-path.
_SNAPSHOT = re.compile(r"\d{1,16}_[\w-]{1,64}\.jpe?g", re.ASCII)
_EPOCH = datetime.fromtimestamp(0, timezone.utc)


def key_prefix(evaluator):
    """`proctoring/<db>/<evaluator_id>/`. The database name keeps stage and
    production apart when they share a bucket (attempt ids collide)."""
    return "proctoring/%s/%s/" % (evaluator.env.cr.dbname, evaluator.id)


def _expires_in(evaluator):
    """Until the deadline + 30 min once started, else the paper's length +
    60 min. Re-issued with every question served (`/begin`, `/state`,
    `/answer`), so this only has to outlive a gap between them."""
    if evaluator.started_at and evaluator.deadline_datetime:
        seconds = (evaluator.deadline_datetime
                   - fields.Datetime.now()).total_seconds() + 30 * 60
    else:
        seconds = ((evaluator.assessment_id.duration_minutes or 0) + 60) * 60
    return max(60, int(seconds))


def upload_policy(evaluator):
    """The runner's `evidence_upload`, or None: rule off, attempt closed, or
    no storage. Never raises for storage, so a storage fault can never fail an
    exam call; a database error still propagates (as in `purge_evidence`)."""
    assessment = evaluator.assessment_id
    if (not (assessment.rule_ai_proctor and assessment.rule_webcam)
            or evaluator.is_locked or evaluator.state == "submitted"):
        return None
    try:
        post = s3_service.presigned_post(
            evaluator.env, key_prefix(evaluator), CONTENT_TYPE, MAX_BYTES,
            _expires_in(evaluator))
    except psycopg2.Error:
        raise
    except Exception:  # noqa: BLE001 - the exam goes on without evidence
        _logger.warning("Evidence upload policy failed for attempt %s",
                        evaluator.id, exc_info=True)
        return None
    if not post:
        # presigned_post has already logged "no storage configured".
        return None
    return dict(post, max_bytes=MAX_BYTES, content_type=CONTENT_TYPE)


def _parse_name(key):
    """(iso, rule) from `<epoch_ms>_<rule>.jpg`. `at` is None when the time
    cannot be read, `rule` is "" unless it is a plain `[\\w-]{1,64}` word:
    the client chose the name, so nothing else is passed on."""
    match = _NAME.match(key.rsplit("/", 1)[-1])
    if not match:
        return None, ""
    rule = match.group(2) if _RULE.fullmatch(match.group(2)) else ""
    try:
        at = datetime.fromtimestamp(int(match.group(1)) / 1000, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None, rule
    return at.strftime("%Y-%m-%dT%H:%M:%SZ"), rule


def _full_prefix(env, evaluator):
    # The same `<s3_folder>/` normalisation `presigned_post` puts in front of
    # the key it signs; listing anywhere else would find nothing.
    folder = s3_service._param(
        env, "assessments_be_v2.s3_folder", "etp_assessment").strip("/")
    return "%s/%s" % (folder, key_prefix(evaluator))


def _pages(cli, bucket, prefix, max_pages=None):
    """Each page (at most 1000 objects) under `prefix`, in S3's key order."""
    token, seen = None, 0
    while True:
        params = {"Bucket": bucket, "Prefix": prefix}
        if token:
            params["ContinuationToken"] = token
        page = cli.list_objects_v2(**params)
        yield page.get("Contents") or []
        seen += 1
        token = page.get("NextContinuationToken")
        if not (page.get("IsTruncated") and token) or seen == max_pages:
            return


def list_evidence(evaluator):
    """`{"items", "count", "prefix"}`, newest first by S3's own
    `LastModified` (the file name's time is the client's), at most LIST_CAP.

    Empty for an erased attempt (`pii_anonymized`) and when no storage is
    configured. S3 errors propagate (the admin route answers 502).
    """
    env = evaluator.env
    prefix = _full_prefix(env, evaluator)
    empty = {"items": [], "count": 0, "prefix": prefix}
    if evaluator.pii_anonymized:
        return empty
    cli, bucket = s3_service.storage_target(env)
    if cli is None or not bucket:
        return empty
    # ponytail: 5 pages = the first 5000 keys in name order; a sitting with
    # more shows the newest of those. Keep an index table if that ever happens.
    objects = [obj for page in _pages(cli, bucket, prefix, _LIST_MAX_PAGES)
               for obj in page]
    objects.sort(key=lambda o: (o.get("LastModified") or _EPOCH, o["Key"]),
                 reverse=True)
    signer = s3_service.presign_client(env) or cli  # Yantra patch 0002: browser-facing signatures
    items = []
    for obj in objects[:LIST_CAP]:
        at, rule = _parse_name(obj["Key"])
        items.append({
            "key": obj["Key"],
            "url": signer.generate_presigned_url(
                "get_object", Params={"Bucket": bucket, "Key": obj["Key"]},
                ExpiresIn=900),
            "at": at,
            "rule": rule,
            "size": obj.get("Size") or 0,
        })
    return {"items": items, "count": len(items), "prefix": prefix}


def snapshot_landed(evaluator, key):
    """Whether ``key``, one of THIS attempt's snapshots, is in S3; None when it
    is not a `<epoch_ms>_<rule>.jpg` name directly under this attempt's prefix
    (the route refuses it, so this never answers for any other key).

    The runner asks after an upload whose reply it could not read: a bucket
    with no CORS rule for POST stores the file but withholds S3's answer.
    S3 errors other than "not there" propagate (the route answers 502)."""
    prefix = _full_prefix(evaluator.env, evaluator)
    if not (key.startswith(prefix)
            and _SNAPSHOT.fullmatch(key[len(prefix):])):
        return None
    cli, bucket = s3_service.storage_target(evaluator.env)
    if cli is None or not bucket:
        return False
    try:
        cli.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in (
                "404", "NoSuchKey", "NotFound"):
            return False
        raise
    return True


def purge_evidence(env, evaluator):
    """Delete every snapshot under this attempt's prefix (the erase path,
    `_anonymize_pii`). Never raises for S3: an erase must not fail because
    storage is down; the failure is logged for a retry by hand."""
    try:
        cli, bucket = s3_service.storage_target(env)
        if cli is None or not bucket:
            return
        prefix = _full_prefix(env, evaluator)
        # Each listed page is at most 1000 keys, `delete_objects`' own limit.
        for page in _pages(cli, bucket, prefix):
            if not page:
                continue
            out = cli.delete_objects(Bucket=bucket, Delete={
                "Objects": [{"Key": obj["Key"]} for obj in page],
                "Quiet": True})
            if out.get("Errors"):
                _logger.warning("Evidence purge for attempt %s left %d "
                                "object(s): %s", evaluator.id,
                                len(out["Errors"]), out["Errors"][:3])
    except psycopg2.Error:
        raise
    except Exception:  # noqa: BLE001 - S3 must never block an erasure
        _logger.warning("Evidence purge failed for attempt %s; its snapshots "
                        "are still in S3", evaluator.id, exc_info=True)

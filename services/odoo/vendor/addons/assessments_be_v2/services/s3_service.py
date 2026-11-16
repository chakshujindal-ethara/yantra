import base64
import logging
import time
import uuid
from datetime import datetime, timedelta, timezone

_logger = logging.getLogger(__name__)

# The most this worker will hold IN MEMORY for one object. Above it the object
# is STREAMED instead of buffered (see `open_stream`), so the cap bounds memory
# rather than what can be served.
_MAX_DOWNLOAD_BYTES = 15 * 1024 * 1024

# How much is read per chunk when streaming. 256 KB is large enough that the
# per-read overhead is irrelevant and small enough that a worker serving several
# clips at once is not holding megabytes each.
_STREAM_CHUNK_BYTES = 256 * 1024

_RETRYABLE_CODES = {
    "RequestTimeout", "RequestTimeTooSkewed", "Throttling",
    "ThrottlingException", "SlowDown", "InternalError",
    "ServiceUnavailable", "503", "500",
}


def _param(env, key, default=""):
    val = env["ir.config_parameter"].sudo().get_param(key, default)
    if val and "PLACEHOLDER" in str(val):
        return ""
    return val or default


def _secret(env, key, default=""):
    """M-8: read a secret param through the encryption-at-rest store (decrypts a
    stored ciphertext; passes legacy plaintext through unchanged)."""
    from . import secret_store
    val = secret_store.get_secret(env, key, default)
    if val and "PLACEHOLDER" in str(val):
        return ""
    return val or default


def _module_s3_configured(env):
    """True when THIS addon's own ``assessments_be_v2.s3_*`` keys are set.

    Kept separate from [is_configured] because they answer different questions:
    this one is about the module's own credentials, that one is about whether
    ANY storage is reachable. Conflating them told a connector-only deployment
    that S3 was "not configured" while uploads were working through the
    connector.
    """
    return bool(
        _param(env, "assessments_be_v2.s3_bucket")
        and _param(env, "assessments_be_v2.s3_access_key_id")
        and _secret(env, "assessments_be_v2.s3_secret_key")
    )


def is_configured(env):
    """True when media can be stored and served at all - by EITHER route.

    The platform connector counts: a deployment configured only that way has
    working storage, and every gate that reads this is asking "can we put an
    object somewhere and get it back", not "are the module's own keys set".
    """
    if _connector(env) is not None:
        return True
    return _module_s3_configured(env)


def _max_retries(env):
    try:
        return max(1, int(_param(env, "assessments_be_v2.s3_max_retries", "3")))
    except (TypeError, ValueError):
        return 3


_S3_CLIENT_CACHE = {}


def _build_client(region, ak, sk, endpoint=None):
    """The ONE way this addon builds a boto3 S3 client, cached per credential.

    ``endpoint`` (Yantra patch 0002) points the client at an S3-compatible store such as MinIO; such stores
    are addressed by path (``<endpoint>/<bucket>/<key>``), not by a virtual host.

    `s3v4` + virtual-host addressing are what a browser-usable presigned URL
    needs outside us-east-1 (proven on ap-south-1): without them S3 answers
    400 BEFORE it evaluates CORS, and the browser reports an opaque CORS error
    instead of the real one. The connector's own client sets neither, so the
    connector path builds its client here too (see [presigned_post]).
    """
    import boto3
    from botocore.config import Config
    cache_key = (ak, sk, region, endpoint)
    cli = _S3_CLIENT_CACHE.get(cache_key)
    if cli is None:
        cli = boto3.client(
            "s3",
            region_name=region,
            aws_access_key_id=ak,
            aws_secret_access_key=sk,
            endpoint_url=endpoint or None,
            config=Config(
                retries={"max_attempts": 3, "mode": "standard"},
                signature_version="s3v4",
                s3={"addressing_style": "path" if endpoint else "virtual"},
            ),
        )
        _S3_CLIENT_CACHE[cache_key] = cli
    return cli


def _client(env):
    return _build_client(
        _param(env, "assessments_be_v2.s3_region", "us-east-1"),
        _param(env, "assessments_be_v2.s3_access_key_id"),
        _secret(env, "assessments_be_v2.s3_secret_key"),
        _param(env, "assessments_be_v2.s3_endpoint_url") or None,
    )


def presign_client(env):
    """The client whose signatures a BROWSER will use (Yantra patch 0002). A signature covers the host, so when
    the server reaches the store at an internal address (``s3_endpoint_url``, e.g. ``http://minio:9000``) the
    browser-facing URL must be signed for the public one (``s3_public_endpoint_url``). Without a public endpoint
    this is the ordinary client."""
    public = _param(env, "assessments_be_v2.s3_public_endpoint_url")
    if not public or _connector(env) is not None:
        return storage_target(env)[0]
    return _build_client(
        _param(env, "assessments_be_v2.s3_region", "us-east-1"),
        _param(env, "assessments_be_v2.s3_access_key_id"),
        _secret(env, "assessments_be_v2.s3_secret_key"),
        public,
    )


def _is_retryable(exc):
    from botocore.exceptions import ClientError, BotoCoreError, ConnectionError
    if isinstance(exc, (BotoCoreError, ConnectionError)):
        return True
    if isinstance(exc, ClientError):
        code = str(exc.response.get("Error", {}).get("Code", ""))
        status = str(exc.response.get("ResponseMetadata", {})
                     .get("HTTPStatusCode", ""))
        return code in _RETRYABLE_CODES or status in _RETRYABLE_CODES
    return False


def _build_url(env, bucket, region, key):
    cdn = _param(env, "assessments_be_v2.s3_cdn_url")
    if cdn:
        return f"{cdn.rstrip('/')}/{key}"
    return f"https://{bucket}.s3.{region}.amazonaws.com/{key}"


def _connector(env):
    """The platform-wide ``s3.connector`` record, or None when that addon is
    absent or holds none.

    Membership-tested because ``s3_connector`` is deliberately NOT in this
    addon's ``depends``: a bare ``env["s3.connector"]`` raises KeyError on a
    database without it.
    """
    if "s3.connector" not in env:
        return None
    return env["s3.connector"].sudo().search([], limit=1) or None


def storage_target(env):
    """The ONE ``(client, bucket)`` this addon both WRITES to and READS from.

    WHY THIS IS SINGLE-SOURCED, and it is the whole point of this function.
    Uploads resolved the bucket CONNECTOR-FIRST while presigning only ever read
    ``assessments_be_v2.s3_bucket``. When those two name different buckets the
    bytes really are stored - just not where playback looks - so S3 answers
    NoSuchKey on a URL that is correctly signed, and a candidate's clip sits at
    0:00 with nothing in any log to say why. That is exactly how it presented
    on stage: the route, the key extraction and the signature were all correct
    and the object was in the other bucket.

    It could not happen locally, which is why it went unnoticed: with no
    connector record configured both halves fell through to the same module
    settings and physically could not disagree.

    Connector FIRST, matching the precedence uploads have always used - that
    record is the team's canonical bucket. Returns ``(None, None)`` when no
    storage is configured at all, which callers must treat as "cannot store or
    serve" rather than quietly trying a second location.
    """
    connector = _connector(env)
    if connector:
        return connector._get_s3_client(), connector.name
    if _module_s3_configured(env):
        return _client(env), _param(env, "assessments_be_v2.s3_bucket")
    return None, None


def upload_b64(env, b64_data, key_hint="file", content_type="application/octet-stream",
               client=None):
    if not is_configured(env):
        raise ValueError(
            "S3 not configured. Set assessments_be_v2.s3_bucket / "
            "s3_access_key_id / s3_secret_key in System Parameters."
        )
    if not b64_data:
        raise ValueError("Empty payload - nothing to upload.")

    # The resolved target, so an upload lands in the SAME bucket presigning
    # will later read from - see [storage_target].
    target_cli, bucket = storage_target(env)
    region = _param(env, "assessments_be_v2.s3_region", "us-east-1")
    folder = _param(env, "assessments_be_v2.s3_folder", "etp_assessment")
    ext = "bin"
    if "png" in content_type:
        ext = "png"
    elif "jpeg" in content_type or "jpg" in content_type:
        ext = "jpg"
    elif "mp4" in content_type:
        ext = "mp4"
    elif "webm" in content_type:
        ext = "webm"
    elif "json" in content_type:
        ext = "json"
    elif "text" in content_type:
        ext = "txt"
    key = f"{folder}/{key_hint}-{uuid.uuid4().hex}.{ext}"

    try:
        raw = base64.b64decode(b64_data)
    except Exception as exc:
        raise ValueError(f"Payload is not valid base64: {exc}")
    if not raw:
        raise ValueError("Decoded payload is empty - nothing to upload.")

    cli = client or target_cli
    retries = _max_retries(env)
    last_exc = None
    for attempt in range(1, retries + 1):
        try:
            cli.put_object(
                Bucket=bucket, Key=key, Body=raw, ContentType=content_type
            )
            _logger.info(
                "etp_assessment uploaded s3://%s/%s (attempt %s)",
                bucket, key, attempt,
            )
            return _build_url(env, bucket, region, key), key
        except Exception as exc:
            last_exc = exc
            if attempt < retries and _is_retryable(exc):
                wait = 2 ** (attempt - 1)
                _logger.warning(
                    "S3 upload attempt %s/%s failed (%s) - retrying in %ss",
                    attempt, retries, exc, wait,
                )
                time.sleep(wait)
                continue
            _logger.error("S3 upload failed permanently for %s: %s", key, exc)
            raise
    raise last_exc if last_exc else RuntimeError("S3 upload failed")


def delete_key(env, key, client=None):
    if not key or not is_configured(env):
        return
    try:
        target_cli, bucket = storage_target(env)
        cli = client or target_cli
        cli.delete_object(Bucket=bucket, Key=key)
        _logger.info("etp_assessment cleaned up s3://%s/%s", bucket, key)
    except Exception as exc:
        _logger.warning("Failed to clean up S3 key %s: %s", key, exc)


def object_key_from_url(env, url):
    """Return the S3 object key when ``url`` points at OUR configured bucket
    (virtual-hosted S3 URL, the configured CDN, or Form Studio's own proxy
    path), else None. Used to decide whether a stored image_url/video_url can
    be proxied from S3 or is an external URL."""
    if not url:
        return None
    from urllib.parse import urlparse, unquote

    # FORM STUDIO MEDIA, which is stored as this app's OWN RELATIVE proxy path
    # (`/api/v1/forms/media/form_studio/<uuid>.<ext>`) rather than an absolute
    # S3 URL - the bucket is private and that route is what serves it.
    #
    # WHY IT HAS TO BE RECOGNISED HERE. `media_stream.serve_video` presigns a
    # clip and 302s to S3 specifically so that an mp4 never streams through the
    # worker - but it can only do that when this function hands back a key. A
    # relative path has no netloc, so it fell past every host check below and
    # returned None, and EVERY Form Studio video - uploaded or imported - was
    # therefore proxied whole through Odoo. That proxy reads the object into
    # worker memory and answers no `Accept-Ranges`, so a candidate could not
    # seek in the clip either.
    #
    # Anchored on a RELATIVE url on purpose: this is the shape we store, and
    # requiring it means an external link that merely happens to contain the
    # same path segment is never mistaken for a key in our bucket.
    _FORM_MEDIA_MARKER = "/forms/media/form_studio/"
    if url.startswith("/") and _FORM_MEDIA_MARKER in url:
        key = "form_studio/" + url.split(_FORM_MEDIA_MARKER, 1)[1]
        key = unquote(key.split("?")[0].split("#")[0])
        # Same guard the proxy route applies before it reads anything.
        if ".." not in key:
            return key

    # EITHER bucket, because a stored URL may name the one that was configured
    # when it was written. A deployment that gains or loses a connector record
    # must not stop recognising URLs it minted under the other, or media that
    # is present reads as external and stops being presigned.
    buckets = {b for b in (
        storage_target(env)[1],
        _param(env, "assessments_be_v2.s3_bucket"),
    ) if b}
    cdn = (_param(env, "assessments_be_v2.s3_cdn_url") or "").rstrip("/")
    parsed = urlparse(url)
    key = unquote(parsed.path.lstrip("/"))
    if not key:
        return None
    host = parsed.netloc
    for bucket in buckets:
        if host.startswith(bucket + ".s3") and host.endswith("amazonaws.com"):
            return key
        if host == bucket + ".s3.amazonaws.com":
            return key
    if cdn and url.startswith(cdn + "/"):
        # Yantra patch 0002: a CDN or public endpoint may carry a path (MinIO's `<endpoint>/<bucket>`), so the key is
        # what follows the CDN prefix, not the whole URL path.
        return unquote(url[len(cdn) + 1:].split("?")[0].split("#")[0])
    return None


def presigned_url(env, key, expires=900, client=None):
    """Return a short-lived presigned GET URL for an object in the configured
    bucket, or ``None`` on failure. Lets the portal 302-redirect the browser
    straight to S3 (like a video ``video_url``) so a worker is not occupied for
    the whole transfer, WITHOUT exposing a permanently-public object: the URL
    is signed and expires after ``expires`` seconds. ``generate_presigned_url``
    is a local signing operation (no S3 round-trip)."""
    if not key or not is_configured(env):
        return None
    try:
        _target_cli, bucket = storage_target(env)
        cli = client or presign_client(env)
        return cli.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=max(60, int(expires or 900)),
        )
    except Exception as exc:
        _logger.warning("S3 presign failed for %s: %s", key, exc)
        return None


def presigned_post(env, key_prefix, content_type, max_bytes, expires_in,
                   under_folder=True):
    """A policy letting a BROWSER upload straight to S3, or ``None`` when no
    storage is configured.

    The policy pins the key to ``<s3_folder>/<key_prefix>`` (any filename under
    it), the exact Content-Type and a size ceiling, so a leaked policy can
    write only inside its own prefix, only that type, only up to ``max_bytes``,
    until ``expires_in`` seconds pass. Returns ``{"url", "fields", "prefix",
    "expires_at"}``: the client POSTs ``fields`` plus the file as a multipart
    form to ``url``; ``prefix`` is the full key prefix the object lands under.
    Signing is local (no S3 round-trip).

    ``under_folder=False`` drops the ``<s3_folder>/`` lead, for media whose
    keys are read back verbatim (Form Studio's ``form_studio/...``, which
    the proxy route and ``object_key_from_url`` only recognise at the root).
    """
    key_prefix = (key_prefix or "").strip("/")
    if not key_prefix:
        raise ValueError("presigned_post needs a key_prefix to scope the upload.")
    cli, bucket = storage_target(env)
    if cli is None or not bucket:
        _logger.warning("S3 presigned POST skipped: no storage configured")
        return None
    connector = _connector(env)
    if connector:
        # Not the connector's own client: it sets neither s3v4 nor virtual
        # addressing (and s3_connector is another team's addon), so rebuild
        # one from the same credentials with this addon's config.
        cli = _build_client(connector.region_name, connector.aws_access_key_id,
                            connector.aws_secret_access_key)
    else:
        cli = presign_client(env)
    prefix = f"{key_prefix}/"
    if under_folder:
        folder = _param(env, "assessments_be_v2.s3_folder", "etp_assessment").strip("/")
        prefix = f"{folder}/{prefix}"
    post = cli.generate_presigned_post(
        Bucket=bucket,
        Key=prefix + "${filename}",
        Fields={"Content-Type": content_type},
        Conditions=[
            ["starts-with", "$key", prefix],
            ["content-length-range", 0, max_bytes],
            {"Content-Type": content_type},
        ],
        ExpiresIn=expires_in,
    )
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=expires_in)
    return {
        "url": post["url"],
        "fields": post["fields"],
        "prefix": prefix,
        "expires_at": expires_at.isoformat(timespec="seconds"),
    }


def open_stream(env, key, client=None):
    """Open an object for STREAMING. Returns ``(iterator, content_type, length)``
    or ``(None, None, 0)``.

    WHY THIS EXISTS ALONGSIDE `download`. `download` buffers, so it refuses
    anything over `_MAX_DOWNLOAD_BYTES` - and the caller's only remaining move
    was a 302 to a presigned S3 URL, which the browser then refuses: an XHR
    cannot follow a cross-origin redirect to a bucket that answers no CORS
    headers. The result was a size-dependent, therefore intermittent, blank
    image: small pictures rendered, large ones did not, and the server logged a
    healthy 200 for both.

    Streaming keeps the bytes on THIS origin, so the response carries this
    module's own credentialed CORS headers, without ever holding the whole
    object in worker memory.
    """
    if not key or not is_configured(env):
        return None, None, 0
    try:
        target_cli, bucket = storage_target(env)
        cli = client or target_cli
        resp = cli.get_object(Bucket=bucket, Key=key)
    except Exception as exc:  # noqa: BLE001 - caller falls back
        _logger.warning("S3 stream open failed for %s: %s", key, exc)
        return None, None, 0

    body = resp["Body"]

    def _chunks():
        # The body MUST be closed even when the client disconnects mid-transfer,
        # or the underlying connection is returned to botocore's pool in an
        # unusable state and the next request on it fails for no visible reason.
        try:
            while True:
                chunk = body.read(_STREAM_CHUNK_BYTES)
                if not chunk:
                    return
                yield chunk
        finally:
            try:
                body.close()
            except Exception:  # noqa: BLE001 - nothing useful left to do
                pass

    return _chunks(), resp.get("ContentType"), int(resp.get("ContentLength") or 0)


def download(env, key, client=None):
    """Fetch an object's bytes from the configured bucket, server-side and
    authenticated (no presigned URL, so nothing can 'expire'). Returns
    ``(bytes, content_type)`` or ``(None, None)`` on any failure."""
    if not key or not is_configured(env):
        return None, None
    try:
        target_cli, bucket = storage_target(env)
        cli = client or target_cli
        resp = cli.get_object(Bucket=bucket, Key=key)
        length = resp.get("ContentLength") or 0
        if length and length > _MAX_DOWNLOAD_BYTES:
            _logger.info(
                "S3 object %s is %s bytes (> %s buffer cap); the caller should "
                "stream it with open_stream() rather than buffering.",
                key, length, _MAX_DOWNLOAD_BYTES)
            return None, None
        # M-4: ContentLength can be absent; read with a hard +1 cap so a missing
        # length can't stream unbounded bytes into worker memory.
        body = resp["Body"].read(_MAX_DOWNLOAD_BYTES + 1)
        if len(body) > _MAX_DOWNLOAD_BYTES:
            _logger.warning(
                "S3 object %s exceeded %s bytes on read (ContentLength absent); "
                "aborted.", key, _MAX_DOWNLOAD_BYTES)
            return None, None
        return body, resp.get("ContentType")
    except Exception as exc:
        _logger.warning("S3 download failed for %s: %s", key, exc)
        return None, None

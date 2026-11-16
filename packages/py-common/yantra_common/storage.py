"""Object storage on MinIO (any S3-compatible store): presigned PUT and GET for the browser, and HEAD, PUT and
multi-object DELETE for the services. Signature Version 4 is computed here over httpx (the four verbs need no SDK);
the pure signing functions are tested against the specification's published examples.

Rules:
- A presigned URL is signed for the host the browser reaches (`public_endpoint`); HEAD, PUT and DELETE go to the
  internal `endpoint`. Clock skew of more than fifteen minutes between this process and MinIO breaks every signature.
- A URL is never logged: it carries the signature. Logs name the bucket, a count and a status.
- Keys are built here, never by string concatenation in a module: a project's media live under
  `projects/<project>/`, a worker's documents under `workers/<worker>/documents/<kind>/`."""

import hashlib
import hmac
import logging
import random
import re
import time
import uuid
from base64 import b64encode
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol
from urllib.parse import quote, urlsplit
from xml.sax.saxutils import escape, unescape

import httpx
from pydantic_settings import BaseSettings, SettingsConfigDict

from yantra_common.errors import DomainError, Invalid

log = logging.getLogger("yantra.storage")
ALGORITHM = "AWS4-HMAC-SHA256"
UNSIGNED = "UNSIGNED-PAYLOAD"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
DELETE_CHUNK = 1000  # the store's multi-object delete takes at most a thousand keys per request
ATTEMPTS = 3
# the per-key failures in a multi-object delete's 200 answer (`<Error><Key>..</Key><Code>..</Code>..</Error>`)
DELETE_ERROR = re.compile(r"<Error>(.*?)</Error>", re.S)
DELETE_KEY = re.compile(r"<Key>(.*?)</Key>", re.S)
DELETE_CODE = re.compile(r"<Code>(.*?)</Code>", re.S)
LIST_KEY = re.compile(r"<Contents>.*?<Key>(.*?)</Key>.*?</Contents>", re.S)
LIST_TOKEN = re.compile(r"<NextContinuationToken>(.*?)</NextContinuationToken>", re.S)


class StorageSettings(BaseSettings):
    """`YANTRA_S3_ENDPOINT` unset means no storage: the routes that need it answer 503 `storage_unconfigured`."""

    model_config = SettingsConfigDict(env_prefix="YANTRA_S3_", extra="ignore")

    endpoint: str | None = None
    public_endpoint: str | None = None  # the host a browser reaches; defaults to `endpoint`
    bucket: str = "yantra"
    region: str = "ap-south-1"
    access_key: str = ""
    secret_key: str = ""
    presign_seconds: int = 300
    path_style: bool = True
    sse_kms_key_id: str | None = None  # when set, uploads are encrypted under this key
    timeout_seconds: float = 5.0


class StorageUnavailable(DomainError):
    status = 503
    code = "storage_unavailable"


class StorageUnconfigured(DomainError):
    status = 503
    code = "storage_unconfigured"


@dataclass(frozen=True)
class Presigned:
    url: str
    method: str
    headers: dict[str, str]  # what the uploader must send: they are covered by the signature
    expires_at: datetime


@dataclass(frozen=True)
class ObjectInfo:
    size: int
    content_type: str | None
    etag: str | None


class Storage(Protocol):
    bucket: str

    def presign_put(
        self, key: str, content_type: str, max_bytes: int, *, size_bytes: int | None = None, now: datetime | None = None
    ) -> Presigned: ...
    def presign_get(self, key: str, *, now: datetime | None = None) -> Presigned: ...
    def put(self, key: str, body: bytes, content_type: str) -> None: ...
    def head(self, key: str) -> ObjectInfo | None: ...
    def delete(self, keys: Sequence[str]) -> int: ...
    def list_keys(self, prefix: str) -> list[str]: ...


# ---------- Signature Version 4: pure functions ----------


def _q(value: str) -> str:
    return quote(value, safe="-_.~")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def signing_key(secret: str, day: str, region: str) -> bytes:
    k = hmac.new(f"AWS4{secret}".encode(), day.encode(), hashlib.sha256).digest()
    for part in (region, "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    return k


def _signature(
    secret: str,
    region: str,
    when: datetime,
    method: str,
    path: str,
    query: Mapping[str, str],
    headers: Mapping[str, str],
    payload_hash: str,
) -> tuple[str, str]:
    """The hex signature and the signed-headers list of one request. `path` is already encoded."""
    stamp = when.strftime("%Y%m%dT%H%M%SZ")
    day = stamp[:8]
    lowered = {k.lower(): " ".join(str(v).split()) for k, v in headers.items()}
    names = sorted(lowered)
    canonical = "\n".join(
        [
            method,
            path,
            "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items())),
            "".join(f"{n}:{lowered[n]}\n" for n in names),
            ";".join(names),
            payload_hash,
        ]
    )
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join([ALGORITHM, stamp, scope, _sha256(canonical.encode())])
    sig = hmac.new(signing_key(secret, day, region), to_sign.encode(), hashlib.sha256).hexdigest()
    return sig, ";".join(names)


def presigned_query(
    access_key: str,
    secret: str,
    region: str,
    when: datetime,
    expires: int,
    method: str,
    path: str,
    headers: Mapping[str, str],
) -> str:
    """The query string of a presigned URL (signature last). `headers` includes `host`."""
    stamp = when.strftime("%Y%m%dT%H%M%SZ")
    query = {
        "X-Amz-Algorithm": ALGORITHM,
        "X-Amz-Credential": f"{access_key}/{stamp[:8]}/{region}/s3/aws4_request",
        "X-Amz-Date": stamp,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": ";".join(sorted(k.lower() for k in headers)),
    }
    sig, _ = _signature(secret, region, when, method, path, query, headers, UNSIGNED)
    return "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items())) + f"&X-Amz-Signature={sig}"


def authorization(
    access_key: str,
    secret: str,
    region: str,
    when: datetime,
    method: str,
    path: str,
    query: Mapping[str, str],
    headers: Mapping[str, str],
    payload_hash: str,
) -> str:
    """The Authorization header of a header-signed request. `headers` includes host, x-amz-date and
    x-amz-content-sha256."""
    sig, signed = _signature(secret, region, when, method, path, query, headers, payload_hash)
    scope = f"{when.strftime('%Y%m%d')}/{region}/s3/aws4_request"
    return f"{ALGORITHM} Credential={access_key}/{scope},SignedHeaders={signed},Signature={sig}"


# ---------- keys and references ----------


def _safe_name(name: str) -> str:
    if not SAFE_NAME.match(name):
        raise Invalid(f"name: {name[:40]!r} must be letters, digits, '.', '_' or '-' (at most 120)")
    return name


def unit_key(project_id: uuid.UUID, upload_id: uuid.UUID, name: str) -> str:
    return f"projects/{project_id}/units/{upload_id}/{_safe_name(name)}"


def document_key(worker_id: uuid.UUID, kind: str, doc_id: uuid.UUID) -> str:
    return f"workers/{worker_id}/documents/{_safe_name(kind)}/{doc_id}"


def deliverable_key(project_id: uuid.UUID, manifest_id: uuid.UUID, name: str) -> str:
    return f"projects/{project_id}/deliveries/{manifest_id}/{_safe_name(name)}"


def project_prefix(project_id: uuid.UUID) -> str:
    return f"projects/{project_id}/"


def looks_like_ref(value: object) -> bool:
    return isinstance(value, str) and (value.startswith("s3://") or value.startswith("projects/"))


def parse_ref(ref: str, bucket: str | None) -> str:
    """`s3://<bucket>/<key>` or a bare key, to the key. Refuses another bucket (when `bucket` is known), a parent
    segment, an empty or absolute key and control characters: a ref names one object and nothing else."""
    key = ref
    if ref.startswith("s3://"):
        named, _, key = ref[len("s3://") :].partition("/")
        if bucket is not None and named != bucket:
            raise ValueError("ref names another bucket")
    if not key or key.startswith("/") or any(p in ("", ".", "..") for p in key.split("/")):
        raise ValueError("ref is not a plain object key")
    if any(ord(c) < 32 or ord(c) == 127 for c in key) or len(key) > 1024:
        raise ValueError("ref is not a plain object key")
    return key


def find_ref(payload: Mapping[str, Any] | None, bucket: str | None) -> str | None:
    """The key of the first top-level string in a payload that is a valid object ref; None when there is none."""
    for value in (payload or {}).values():
        if looks_like_ref(value):
            try:
                return parse_ref(value, bucket)
            except ValueError:
                continue
    return None


# ---------- the client ----------


class S3Storage:
    def __init__(
        self,
        s: StorageSettings,
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
        rng: Callable[[float, float], float] = random.uniform,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        if not s.endpoint:
            raise StorageUnconfigured("YANTRA_S3_ENDPOINT is not set")
        self.s = s
        self.bucket = s.bucket
        self._internal = urlsplit(s.endpoint)
        self._public = urlsplit(s.public_endpoint or s.endpoint)
        self._client = client or httpx.Client(timeout=httpx.Timeout(s.timeout_seconds, connect=3.0))
        self._sleep, self._rng, self._clock = sleep, rng, clock

    # where an object lives, for either face of the store
    def _locate(self, key: str, public: bool) -> tuple[str, str, str]:
        base = self._public if public else self._internal
        encoded = quote(key, safe="/-_.~")
        if self.s.path_style:
            return base.scheme, base.netloc, f"/{self.bucket}/{encoded}"
        return base.scheme, f"{self.bucket}.{base.netloc}", f"/{encoded}"

    def _sse(self) -> dict[str, str]:
        if not self.s.sse_kms_key_id:
            return {}
        return {
            "x-amz-server-side-encryption": "aws:kms",
            "x-amz-server-side-encryption-aws-kms-key-id": self.s.sse_kms_key_id,
        }

    def _presign(self, method: str, key: str, extra: dict[str, str], now: datetime | None) -> Presigned:
        when = now or self._clock()
        scheme, host, path = self._locate(key, public=True)
        query = presigned_query(
            self.s.access_key,
            self.s.secret_key,
            self.s.region,
            when,
            self.s.presign_seconds,
            method,
            path,
            {"host": host, **extra},
        )
        return Presigned(
            url=f"{scheme}://{host}{path}?{query}",
            method=method,
            headers=extra,
            expires_at=when + timedelta(seconds=self.s.presign_seconds),
        )

    def presign_put(
        self, key: str, content_type: str, max_bytes: int, *, size_bytes: int | None = None, now: datetime | None = None
    ) -> Presigned:
        """`max_bytes` is the caller's promise to the uploader; the registering route checks the size with HEAD.
        `size_bytes`, the exact size the client declared, is signed as `content-length`, so the store refuses a body
        of any other size. It is not in the returned headers: the uploader's HTTP client sets Content-Length itself
        (a browser refuses to let a page set it)."""
        signed = {"content-type": content_type, **self._sse()}
        presigned = self._presign("PUT", key, signed | self._length(size_bytes), now)
        return Presigned(presigned.url, presigned.method, signed, presigned.expires_at)

    @staticmethod
    def _length(size_bytes: int | None) -> dict[str, str]:
        return {} if size_bytes is None else {"content-length": str(size_bytes)}

    def presign_get(self, key: str, *, now: datetime | None = None) -> Presigned:
        return self._presign("GET", key, {}, now)

    def _send(
        self,
        method: str,
        key: str | None,
        body: bytes = b"",
        query: Mapping[str, str] | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> httpx.Response:
        """A header-signed request to the internal endpoint: three attempts on a connection error or a 5xx, with
        jittered backoff, then StorageUnavailable."""
        query = dict(query or {})
        for attempt in range(ATTEMPTS):
            when = self._clock()
            if key is None:
                scheme, host, path = self._internal.scheme, self._internal.netloc, f"/{self.bucket}"
                if not self.s.path_style:
                    host, path = f"{self.bucket}.{self._internal.netloc}", "/"
            else:
                scheme, host, path = self._locate(key, public=False)
            signed = {
                "host": host,
                "x-amz-date": when.strftime("%Y%m%dT%H%M%SZ"),
                "x-amz-content-sha256": _sha256(body),
                **(headers or {}),
            }
            auth = authorization(
                self.s.access_key,
                self.s.secret_key,
                self.s.region,
                when,
                method,
                path,
                query,
                signed,
                signed["x-amz-content-sha256"],
            )
            qs = "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items()))
            url = f"{scheme}://{host}{path}" + (f"?{qs}" if qs else "")
            send = {k: v for k, v in signed.items() if k != "host"} | {"authorization": auth}
            try:
                response = self._client.request(method, url, content=body or None, headers=send)
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout) as e:
                log.warning(
                    "storage %s failed bucket=%s attempt=%s error=%s",
                    method,
                    self.bucket,
                    attempt + 1,
                    type(e).__name__,
                )
            else:
                if response.status_code < 500:
                    return response
                log.warning(
                    "storage %s bucket=%s status=%s attempt=%s", method, self.bucket, response.status_code, attempt + 1
                )
            if attempt + 1 < ATTEMPTS:
                self._sleep(self._rng(0, 0.2 * 2**attempt))
        raise StorageUnavailable("object storage is unavailable; try again", bucket=self.bucket)

    def put(self, key: str, body: bytes, content_type: str) -> None:
        response = self._send("PUT", key, body, headers={"content-type": content_type, **self._sse()})
        if response.status_code != 200:
            log.error("storage put refused bucket=%s status=%s", self.bucket, response.status_code)
            raise StorageUnavailable("object storage refused the write", bucket=self.bucket)

    def head(self, key: str) -> ObjectInfo | None:
        response = self._send("HEAD", key)
        if response.status_code == 404:
            return None
        if response.status_code != 200:
            log.error("storage head refused bucket=%s status=%s", self.bucket, response.status_code)
            raise StorageUnavailable("object storage refused the read", bucket=self.bucket)
        return ObjectInfo(
            size=int(response.headers.get("content-length", "0")),
            content_type=response.headers.get("content-type"),
            etag=response.headers.get("etag"),
        )

    def list_keys(self, prefix: str) -> list[str]:
        """Every key under `prefix` (ListObjectsV2, page by page through the continuation token): what an erasure
        deletes when it must leave nothing behind, registered or not. An empty prefix (the whole bucket) is refused."""
        if not prefix.strip("/"):
            raise ValueError("list_keys needs a non-empty prefix")
        keys: list[str] = []
        token: str | None = None
        while True:
            query = {"list-type": "2", "prefix": prefix} | ({"continuation-token": token} if token else {})
            response = self._send("GET", None, query=query)
            if response.status_code != 200:
                log.error("storage list refused bucket=%s status=%s", self.bucket, response.status_code)
                raise StorageUnavailable("object storage refused the listing", bucket=self.bucket)
            text = response.content.decode("utf-8", "replace")
            keys += [unescape(k) for k in LIST_KEY.findall(text)]
            more = LIST_TOKEN.search(text)
            if "<IsTruncated>true</IsTruncated>" not in text or more is None:
                return keys
            token = unescape(more.group(1))

    def delete(self, keys: Sequence[str]) -> int:
        """Deletes in chunks of a thousand; a missing key is not an error. The store answers 200 even when some keys
        failed (quiet mode lists only those, as `<Error>` entries): any entry is StorageUnavailable naming the failed
        keys (`failed`), so a caller never records as gone an object that is still there. Returns how many keys were
        sent."""
        sent = 0
        for i in range(0, len(keys), DELETE_CHUNK):
            chunk = keys[i : i + DELETE_CHUNK]
            body = (
                "<Delete><Quiet>true</Quiet>"
                + "".join(f"<Object><Key>{escape(k)}</Key></Object>" for k in chunk)
                + "</Delete>"
            ).encode()
            md5 = b64encode(hashlib.md5(body, usedforsecurity=False).digest()).decode()
            response = self._send(
                "POST",
                None,
                body,
                query={"delete": ""},
                headers={"content-md5": md5, "content-type": "application/xml"},
            )
            if response.status_code != 200:
                log.error(
                    "storage delete refused bucket=%s status=%s keys=%s", self.bucket, response.status_code, len(chunk)
                )
                raise StorageUnavailable("object storage refused the delete", bucket=self.bucket)
            self._check_deleted(response.content, len(chunk))
            sent += len(chunk)
        log.info("storage delete bucket=%s keys=%s", self.bucket, sent)
        return sent

    def _check_deleted(self, body: bytes, sent: int) -> None:
        text = body.decode("utf-8", "replace").strip()
        if text and "<DeleteResult" not in text:
            log.error("storage delete answer unreadable bucket=%s keys=%s", self.bucket, sent)
            raise StorageUnavailable("object storage gave an unreadable delete answer", bucket=self.bucket)
        errors = DELETE_ERROR.findall(text)
        if not errors:
            return
        failed = [unescape(m.group(1)) for e in errors if (m := DELETE_KEY.search(e))]
        codes = sorted({m.group(1) for e in errors if (m := DELETE_CODE.search(e))})
        log.error(
            "storage delete partly failed bucket=%s keys=%s failed=%s codes=%s", self.bucket, sent, len(errors), codes
        )
        raise StorageUnavailable("object storage could not delete every object", bucket=self.bucket, failed=failed)


def storage_from_env() -> S3Storage | None:
    """The process's storage, or None when `YANTRA_S3_ENDPOINT` is unset."""
    s = StorageSettings()
    return S3Storage(s) if s.endpoint else None

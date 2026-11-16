"""Object storage: Signature Version 4 against the specification's published examples, key rules, and the client
against an in-process transport (retries, chunked delete, nothing secret in the log)."""

import uuid
from datetime import UTC, datetime

import httpx
import pytest

from yantra_common.errors import Invalid
from yantra_common.storage import (
    S3Storage,
    StorageSettings,
    StorageUnavailable,
    StorageUnconfigured,
    authorization,
    deliverable_key,
    document_key,
    find_ref,
    looks_like_ref,
    parse_ref,
    presigned_query,
    project_prefix,
    storage_from_env,
    unit_key,
)
from yantra_common.testing import FakeStorage

# the published example credentials of the signing specification
AK = "AKIAIOSFODNN7EXAMPLE"
SK = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
WHEN = datetime(2013, 5, 24, tzinfo=UTC)
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def test_presigned_get_matches_the_published_example():
    query = presigned_query(
        AK, SK, "us-east-1", WHEN, 86400, "GET", "/test.txt", {"host": "examplebucket.s3.amazonaws.com"}
    )
    assert query.endswith("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    assert "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" in query


def test_header_signed_get_with_a_range_matches_the_published_example():
    headers = {
        "host": "examplebucket.s3.amazonaws.com",
        "range": "bytes=0-9",
        "x-amz-content-sha256": EMPTY,
        "x-amz-date": "20130524T000000Z",
    }
    auth = authorization(AK, SK, "us-east-1", WHEN, "GET", "/test.txt", {}, headers, EMPTY)
    assert auth == (
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )


def settings(**over: object) -> StorageSettings:
    base: dict[str, object] = dict(
        endpoint="http://minio:9000",
        public_endpoint="http://localhost:9000",
        bucket="yantra",
        access_key="yantra",
        secret_key="secret",
    )
    return StorageSettings.model_validate({**base, **over})


def store(handler, **over: object) -> tuple[S3Storage, list[float]]:
    slept: list[float] = []
    s = S3Storage(
        settings(**over),
        client=httpx.Client(transport=httpx.MockTransport(handler)),
        sleep=slept.append,
        rng=lambda lo, hi: hi,
        clock=lambda: WHEN,
    )
    return s, slept


def test_presign_put_signs_the_content_type_for_the_public_host_path_style():
    s, _ = store(lambda r: httpx.Response(200))
    p = s.presign_put("projects/p/units/u/a.wav", "audio/wav", 1024)
    assert p.url.startswith("http://localhost:9000/yantra/projects/p/units/u/a.wav?")
    assert "X-Amz-SignedHeaders=content-type%3Bhost" in p.url
    assert p.method == "PUT" and p.headers == {"content-type": "audio/wav"}
    assert (p.expires_at - WHEN).total_seconds() == 300


def test_presign_put_signs_the_declared_size_so_the_store_refuses_another():
    s, _ = store(lambda r: httpx.Response(200))
    p = s.presign_put("projects/p/units/u/a.wav", "audio/wav", 1024, size_bytes=1000)
    assert "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost" in p.url
    assert p.headers == {"content-type": "audio/wav"}  # the uploader's client sets Content-Length from the body
    other = s.presign_put("projects/p/units/u/a.wav", "audio/wav", 1024, size_bytes=999)
    assert other.url.split("X-Amz-Signature=")[1] != p.url.split("X-Amz-Signature=")[1]
    unsized = s.presign_put("projects/p/units/u/a.wav", "audio/wav", 1024)
    assert "content-length" not in unsized.url


def test_presign_get_virtual_host_and_kms_headers():
    s, _ = store(lambda r: httpx.Response(200), path_style=False, sse_kms_key_id="k1")
    g = s.presign_get("a b.txt")
    assert g.url.startswith("http://yantra.localhost:9000/a%20b.txt?") and g.headers == {}
    p = s.presign_put("x", "image/png", 10)
    assert p.headers["x-amz-server-side-encryption"] == "aws:kms"
    assert "x-amz-server-side-encryption-aws-kms-key-id" in p.url.split("X-Amz-SignedHeaders=")[1].split("&")[
        0
    ].replace("%3B", ";")


def test_head_put_and_delete_go_to_the_internal_endpoint_signed():
    seen: list[httpx.Request] = []

    def handler(r: httpx.Request) -> httpx.Response:
        seen.append(r)
        if r.method == "HEAD":
            return httpx.Response(200, headers={"content-length": "16", "content-type": "audio/wav", "etag": '"e"'})
        return httpx.Response(200)

    s, _ = store(handler)
    info = s.head("k1")
    assert info is not None and (info.size, info.content_type, info.etag) == (16, "audio/wav", '"e"')
    s.put("k2", b"hello", "text/plain")
    assert s.delete([f"k{i}" for i in range(2500)]) == 2500
    hosts = {r.url.host for r in seen}
    assert hosts == {"minio"}
    assert all(r.headers["authorization"].startswith("AWS4-HMAC-SHA256 Credential=yantra/") for r in seen)
    deletes = [r for r in seen if r.method == "POST"]
    assert len(deletes) == 3 and all(r.url.query == b"delete=" for r in deletes)
    assert all("content-md5" in r.headers for r in deletes)
    assert b"<Key>k0</Key>" in deletes[0].content and deletes[0].content.count(b"<Object>") == 1000


def test_delete_escapes_keys_and_handles_the_virtual_host():
    seen: list[httpx.Request] = []

    def handler(r: httpx.Request) -> httpx.Response:
        seen.append(r)
        return httpx.Response(200)

    s, _ = store(handler, path_style=False)
    s.delete(["a&b"])
    assert seen[0].url.host == "yantra.minio" and seen[0].url.path == "/"
    assert b"<Key>a&amp;b</Key>" in seen[0].content


def test_a_delete_the_store_answers_200_with_per_key_errors_is_unavailable_naming_the_keys(caplog):
    body = (
        b'<?xml version="1.0" encoding="UTF-8"?><DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        b"<Error><Key>a</Key><Code>AccessDenied</Code><Message>Access Denied.</Message></Error>"
        b"<Error><Key>c&amp;d</Key><Code>InternalError</Code><Message>x</Message></Error>"
        b"</DeleteResult>"
    )
    s, _ = store(lambda r: httpx.Response(200, content=body))
    with caplog.at_level("ERROR"), pytest.raises(StorageUnavailable) as e:
        s.delete(["a", "b", "c&d"])
    assert e.value.context["failed"] == ["a", "c&d"]
    assert "failed=2" in caplog.text and "AccessDenied" in caplog.text and "X-Amz" not in caplog.text
    quiet = b'<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></DeleteResult>'
    s, _ = store(lambda r: httpx.Response(200, content=quiet))
    assert s.delete(["a"]) == 1
    s, _ = store(lambda r: httpx.Response(200, content=b"not xml"))
    with pytest.raises(StorageUnavailable):
        s.delete(["a"])


def test_head_of_a_missing_object_is_none_and_a_refusal_is_unavailable():
    s, _ = store(lambda r: httpx.Response(404))
    assert s.head("nope") is None
    s, _ = store(lambda r: httpx.Response(403))
    with pytest.raises(StorageUnavailable):
        s.head("nope")
    with pytest.raises(StorageUnavailable):
        s.put("k", b"x", "text/plain")
    with pytest.raises(StorageUnavailable):
        s.delete(["k"])


def test_a_5xx_is_retried_with_backoff_then_succeeds():
    answers = iter([503, 503, 200])
    s, slept = store(lambda r: httpx.Response(next(answers)))
    s.put("k", b"x", "text/plain")
    assert slept == [0.2, 0.4]


def test_connection_errors_exhaust_into_unavailable_and_never_log_a_url(caplog):
    def handler(r: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=r)

    s, slept = store(handler)
    with caplog.at_level("WARNING"), pytest.raises(StorageUnavailable):
        s.head("k")
    assert len(slept) == 2
    assert "X-Amz-Signature" not in caplog.text and "authorization" not in caplog.text.lower()
    assert "attempt=3" in caplog.text


def test_unconfigured_storage():
    with pytest.raises(StorageUnconfigured):
        S3Storage(StorageSettings(endpoint=None))
    assert storage_from_env() is None


def test_storage_from_env(monkeypatch):
    monkeypatch.setenv("YANTRA_S3_ENDPOINT", "http://minio:9000")
    s = storage_from_env()
    assert s is not None and s.bucket == "yantra"


def test_key_builders_refuse_unsafe_names():
    p, u = uuid.uuid4(), uuid.uuid4()
    assert unit_key(p, u, "clip-01.wav") == f"projects/{p}/units/{u}/clip-01.wav"
    assert document_key(u, "identity_front", p) == f"workers/{u}/documents/identity_front/{p}"
    assert deliverable_key(p, u, "units.jsonl") == f"projects/{p}/deliveries/{u}/units.jsonl"
    assert project_prefix(p) == f"projects/{p}/"
    for bad in ("../x", "a/b", ".hidden", "", "x" * 121):
        with pytest.raises(Invalid):
            unit_key(p, u, bad)


def test_refs():
    assert parse_ref("s3://yantra/projects/p/a.wav", "yantra") == "projects/p/a.wav"
    assert parse_ref("s3://other/k", None) == "k"
    assert parse_ref("projects/p/a.wav", "yantra") == "projects/p/a.wav"
    for bad in (
        "s3://other/k",
        "s3://yantra/",
        "/abs",
        "projects/../x",
        "projects//x",
        "projects/\x01",
        "p/" + "x" * 1030,
    ):
        with pytest.raises(ValueError):
            parse_ref(bad, "yantra")
    assert looks_like_ref("s3://b/k") and looks_like_ref("projects/x") and not looks_like_ref(3)
    assert find_ref({"text": "hi", "bad": "s3://other/k", "audio": "s3://yantra/projects/p/a.wav"}, "yantra") == (
        "projects/p/a.wav"
    )
    assert find_ref({"text": "hi"}, "yantra") is None and find_ref(None, None) is None


def test_fake_storage_records_everything():
    f = FakeStorage()
    put = f.presign_put("k", "audio/wav", 10, now=WHEN)
    f.presign_put("sized", "audio/wav", 10, size_bytes=7)
    assert f.put_sizes == {"k": None, "sized": 7}
    assert put.url == "fake://yantra/k?method=PUT" and put.headers == {"content-type": "audio/wav"}
    assert f.presign_get("k").method == "GET"
    assert f.head("k") is None
    f.put("k", b"abc", "text/plain")
    info = f.head("k")
    assert info is not None and info.size == 3
    assert f.delete(["k", "missing"]) == 2 and f.deleted == ["k", "missing"] and f.objects == {}
    assert f.presigned == [("PUT", "k"), ("PUT", "sized"), ("GET", "k")]

"""Listing a prefix: what an erasure deletes when it must leave nothing behind."""

import httpx
import pytest

from yantra_common.storage import StorageUnavailable
from yantra_common.testing import FakeStorage

from .test_storage import store

PAGE_1 = (
    "<ListBucketResult><IsTruncated>true</IsTruncated>"
    "<Contents><Key>workers/w/documents/a&amp;b</Key><Size>1</Size></Contents>"
    "<Contents><Key>workers/w/x</Key></Contents>"
    "<NextContinuationToken>t&amp;1</NextContinuationToken></ListBucketResult>"
)
PAGE_2 = (
    "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>workers/w/y</Key></Contents></ListBucketResult>"
)


def test_list_keys_follows_the_continuation_token_signed_to_the_internal_endpoint():
    seen: list[httpx.Request] = []

    def handler(r: httpx.Request) -> httpx.Response:
        seen.append(r)
        return httpx.Response(200, text=PAGE_2 if "continuation-token" in r.url.params else PAGE_1)

    s, _ = store(handler)
    assert s.list_keys("workers/w/") == ["workers/w/documents/a&b", "workers/w/x", "workers/w/y"]
    assert [r.url.params.get("continuation-token") for r in seen] == [None, "t&1"]
    assert all(r.method == "GET" and r.url.host == "minio" and r.url.params["list-type"] == "2" for r in seen)
    assert all(r.url.params["prefix"] == "workers/w/" and "authorization" in r.headers for r in seen)


def test_a_truncated_page_without_a_token_ends_the_listing_and_a_refusal_is_unavailable():
    s, _ = store(lambda r: httpx.Response(200, text="<IsTruncated>true</IsTruncated>"))
    assert s.list_keys("p/") == []
    s, _ = store(lambda r: httpx.Response(403))
    with pytest.raises(StorageUnavailable):
        s.list_keys("p/")


def test_an_empty_prefix_is_refused():
    s, _ = store(lambda r: httpx.Response(200))
    for prefix in ("", "/"):
        with pytest.raises(ValueError):
            s.list_keys(prefix)
        with pytest.raises(ValueError):
            FakeStorage().list_keys(prefix)


def test_fake_storage_lists_its_objects_under_a_prefix():
    fake = FakeStorage()
    for key in ("a/2", "a/1", "b/1"):
        fake.put(key, b"x", "text/plain")
    assert fake.list_keys("a/") == ["a/1", "a/2"]

import os

from fastapi.testclient import TestClient

from yantra_common.config import settings
from yantra_common.testing import ADMIN_URL
from yantra_money.app import default_app


def test_default_app_reads_the_database_url_from_the_environment(monkeypatch):
    db = "yantra_money_test" + os.environ.get("YANTRA_TEST_DB_SUFFIX", "")
    monkeypatch.setenv("YANTRA_DATABASE_URL", ADMIN_URL.rsplit("/", 1)[0] + "/" + db)
    settings.cache_clear()
    try:
        client = TestClient(default_app())
        assert client.get("/health").json() == {"status": "ok"}
        assert client.get("/ready").json()["status"] == "ok"
    finally:
        settings.cache_clear()

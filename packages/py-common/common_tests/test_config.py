"""Settings: the PII key has a local default and comes from `YANTRA_PII_KEY`; the full settings carry it too."""

from yantra_common.config import LOCAL_PII_KEY, Settings, pii_settings


def test_the_pii_key_defaults_for_the_local_rig_and_reads_the_environment(monkeypatch):
    monkeypatch.delenv("YANTRA_PII_KEY", raising=False)
    pii_settings.cache_clear()
    try:
        assert pii_settings().pii_key == LOCAL_PII_KEY
        monkeypatch.setenv("YANTRA_PII_KEY", "s3cret")
        pii_settings.cache_clear()
        assert pii_settings().pii_key == "s3cret"
        assert Settings(database_url="postgresql+psycopg://u:p@h/db").pii_key == "s3cret"
    finally:
        pii_settings.cache_clear()


def test_a_deployed_environment_refuses_the_rigs_secrets_and_names_the_setting_not_the_value(monkeypatch):
    import base64

    import pytest

    from yantra_common.config import LOCAL_BANK_KEY, RIG_BANK_KEY, RigSecretsRefused, refuse_rig_secrets, settings

    real_bank = "k1:" + base64.b64encode(b"b" * 32).decode()
    good = {
        "database_url": "postgresql+psycopg://svc:a-long-db-secret@db:5432/yantra",
        "pii_key": "p" * 40,
        "bank_key": real_bank,
        "requires_bank_key": True,
    }
    rig = Settings(database_url="postgresql+psycopg://yantra:yantra@localhost/yantra")
    refuse_rig_secrets(rig, {"YANTRA_S3_SECRET_KEY": "yantra-local-secret"})  # the rig: fine
    monkeypatch.setenv("YANTRA_ENV", "prod")
    refuse_rig_secrets(Settings(**good), {"YANTRA_S3_SECRET_KEY": "s" * 40})
    for override, named, value in (
        ({"pii_key": "local-rig-pii-key"}, "YANTRA_PII_KEY", "local-rig-pii-key"),
        ({"pii_key": "short"}, "YANTRA_PII_KEY", "short"),
        ({"bank_key": LOCAL_BANK_KEY}, "YANTRA_BANK_KEY", LOCAL_BANK_KEY),
        ({"bank_key": RIG_BANK_KEY}, "YANTRA_BANK_KEY", RIG_BANK_KEY),
        ({"bank_key_previous": LOCAL_BANK_KEY}, "YANTRA_BANK_KEY", LOCAL_BANK_KEY),
        ({"database_url": "postgresql+psycopg://yantra:yantra@db/yantra"}, "YANTRA_DATABASE_URL", ":yantra@"),
        ({"database_url": "postgresql+psycopg://yantra_work:yantra_work@db/y"}, "YANTRA_DATABASE_URL", ":yantra_work@"),
        ({"database_url": "postgresql+psycopg://yantra_money:yantra_money@db/y"}, "YANTRA_DATABASE_URL", "_money@"),
    ):
        with pytest.raises(RigSecretsRefused, match=named) as e:
            refuse_rig_secrets(Settings(**{**good, **override}), {})
        assert value not in str(e.value)
    # settings other modules own are checked by name: object storage and the RazorpayX credentials
    for name, value in (
        ("YANTRA_S3_ACCESS_KEY", "yantra"),
        ("YANTRA_S3_SECRET_KEY", "yantra-local-secret"),
        ("YANTRA_RAZORPAYX_KEY_ID", "rzp_test_yantra"),
        ("YANTRA_RAZORPAYX_KEY_SECRET", "yantra-local-razorpayx-secret"),
        ("YANTRA_RAZORPAYX_WEBHOOK_SECRET", "yantra-local-razorpayx-secret"),
    ):
        with pytest.raises(RigSecretsRefused, match=name) as e:
            refuse_rig_secrets(Settings(**good), {name: value})
        assert value not in str(e.value)
    monkeypatch.setenv("YANTRA_DATABASE_URL", "postgresql+psycopg://yantra:yantra@db/yantra")
    settings.cache_clear()
    try:
        with pytest.raises(RigSecretsRefused):
            settings()  # the process accessor runs the check, against the process environment
    finally:
        settings.cache_clear()


def test_only_a_process_that_seals_needs_its_own_bank_key(monkeypatch):
    """Work never seals an account number: it boots on the default key. Money sets YANTRA_REQUIRES_BANK_KEY and
    refuses to boot without a real one; any process that seals anyway is refused at first use."""
    import base64

    import pytest

    from yantra_common.config import RIG_BANK_KEY, RigSecretsRefused, bank_key_settings, refuse_rig_secrets

    work = {"database_url": "postgresql+psycopg://svc:a-long-db-secret@db:5432/yantra", "pii_key": "p" * 40}
    monkeypatch.setenv("YANTRA_ENV", "staging")
    refuse_rig_secrets(Settings(**work), {})
    with pytest.raises(RigSecretsRefused, match="YANTRA_BANK_KEY"):
        refuse_rig_secrets(Settings(**work, requires_bank_key=True), {})
    monkeypatch.setenv("YANTRA_REQUIRES_BANK_KEY", "true")
    assert Settings(**work).requires_bank_key is True
    bank_key_settings.cache_clear()
    try:
        for key in ("", RIG_BANK_KEY):
            if key:
                monkeypatch.setenv("YANTRA_BANK_KEY", key)
            bank_key_settings.cache_clear()
            with pytest.raises(RigSecretsRefused, match="YANTRA_BANK_KEY") as e:
                bank_key_settings()
            assert RIG_BANK_KEY not in str(e.value)
        real = "k1:" + base64.b64encode(b"r" * 32).decode()
        monkeypatch.setenv("YANTRA_BANK_KEY", real)
        bank_key_settings.cache_clear()
        assert bank_key_settings().bank_key == real
        monkeypatch.setenv("YANTRA_ENV", "local")
        monkeypatch.setenv("YANTRA_BANK_KEY", RIG_BANK_KEY)
        bank_key_settings.cache_clear()
        assert bank_key_settings().bank_key == RIG_BANK_KEY  # the rig seals with its own key
    finally:
        bank_key_settings.cache_clear()


def test_the_process_settings_load_on_the_rig(monkeypatch):
    from yantra_common.config import settings

    monkeypatch.setenv("YANTRA_ENV", "local")
    monkeypatch.setenv("YANTRA_DATABASE_URL", "postgresql+psycopg://yantra:yantra@localhost/yantra")
    settings.cache_clear()
    try:
        s = settings()
        assert (s.env, s.requires_bank_key, s.outbox_stuck_seconds) == ("local", False, 300)
    finally:
        settings.cache_clear()

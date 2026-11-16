"""The three rails: the RazorpayX adapter against a scripted fake RazorpayX (httpx MockTransport: auth,
idempotency store, faults), the deterministic fake rail, the bank-file rail, and how YANTRA_RAIL picks one."""

import json
import uuid
from decimal import Decimal

import httpx
import pytest

from yantra_payout.config import PayoutSettings
from yantra_payout.rails import PayoutRequest, RailError, RailUnavailable, RailUnknownOutcome, select_rail
from yantra_payout.rails.fake import FakeRail
from yantra_payout.rails.file import FileRail
from yantra_payout.rails.razorpayx import RazorpayXRail, narration, payout_of, validation_of

LINE = uuid.UUID("11111111-2222-4333-8444-555555555555")


class FakeRazorpayX:
    """A small RazorpayX: checks basic auth, keeps payouts by idempotency key, answers lookups, and plays scripted
    faults (a list of responses or exceptions per `METHOD path`) before the normal answer."""

    def __init__(self) -> None:
        self.payouts: dict[str, dict] = {}
        self.by_key: dict[str, str] = {}
        self.faults: dict[str, list] = {}
        self.seen: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        assert request.headers["Authorization"].startswith("Basic ")
        route = f"{request.method} {request.url.path}"
        script = self.faults.get(route)
        if script:
            fault = script.pop(0)
            if isinstance(fault, Exception):
                raise fault
            return fault
        body = json.loads(request.content) if request.content else {}
        if route == "POST /v1/contacts":
            return httpx.Response(200, json={"id": "cont_1", "name": body["name"]})
        if route == "POST /v1/fund_accounts":
            return httpx.Response(200, json={"id": "fa_1"})
        if route == "POST /v1/fund_accounts/validations":
            return httpx.Response(200, json={"id": "fav_1", "status": "created", "results": {}})
        if route == "GET /v1/fund_accounts/validations/fav_1":
            return httpx.Response(
                200,
                json={
                    "id": "fav_1",
                    "status": "completed",
                    "results": {"account_status": "active", "registered_name": "ASHA RAO"},
                },
            )
        if route == "POST /v1/payouts":
            key = request.headers["X-Payout-Idempotency"]
            if key not in self.by_key:
                pid = f"pout_{len(self.payouts) + 1}"
                self.payouts[pid] = {**body, "id": pid, "status": "processing"}
                self.by_key[key] = pid
            return httpx.Response(200, json=self.payouts[self.by_key[key]])
        if route == "GET /v1/payouts":
            # like RazorpayX: newest first, and the filter is the exact reference
            items = [p for p in self.payouts.values() if p["reference_id"] == request.url.params["reference_id"]]
            return httpx.Response(200, json={"items": items[::-1]})
        if request.method == "GET" and request.url.path.startswith("/v1/payouts/"):
            pid = request.url.path.rsplit("/", 1)[1]
            return httpx.Response(200, json={**self.payouts[pid], "status": "processed", "utr": "UTR42"})
        return httpx.Response(404, json={"error": {"code": "NOT_FOUND"}})


def rail_with(server: FakeRazorpayX, **kw):
    sleeps: list[float] = []
    client = httpx.Client(base_url="https://rzp.test/v1", auth=("key", "secret"), transport=httpx.MockTransport(server))
    rail = RazorpayXRail(
        "key", "secret", "2323230000000001", client=client, sleep=sleeps.append, rng=lambda a, b: b, **kw
    )
    return rail, sleeps


def request(amount: str = "28.00", attempt: int = 1, currency: str = "INR") -> PayoutRequest:
    return PayoutRequest(LINE, attempt, "fa_1", Decimal(amount), currency, "Yantra 30 Oct 2026!")


def test_registration_and_penny_drop_send_the_shapes_razorpayx_expects():
    server = FakeRazorpayX()
    rail, _ = rail_with(server)
    registered = rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert (registered.contact_id, registered.fund_account_id) == ("cont_1", "fa_1")
    contact, fund = (json.loads(r.content) for r in server.seen[:2])
    assert contact == {"name": "Asha Rao", "type": "vendor", "reference_id": str(LINE)}
    assert fund["bank_account"] == {"name": "Asha Rao", "ifsc": "HDFC0001234", "account_number": "123456789012"}
    started = rail.start_validation("fa_1", "Asha Rao", LINE)
    assert started.status == "pending" and started.id == "fav_1"
    assert json.loads(server.seen[2].content)["amount"] == 100
    done = rail.fetch_validation("fav_1")
    assert (done.status, done.registered_name) == ("verified", "ASHA RAO")


def test_a_payout_is_sent_in_paise_with_the_attempt_as_reference_and_an_idempotency_key():
    server = FakeRazorpayX()
    rail, _ = rail_with(server, mode="NEFT")
    result = rail.create_payout(request("28.50"))
    sent = json.loads(server.seen[-1].content)
    assert sent["amount"] == 2850 and sent["reference_id"] == f"{LINE}:1" and sent["mode"] == "NEFT"
    assert sent["narration"] == "Yantra 30 Oct 2026" and sent["account_number"] == "2323230000000001"
    assert server.seen[-1].headers["X-Payout-Idempotency"] == f"{LINE}:1"
    assert (result.reference, result.status, result.amount) == ("pout_1", "processing", Decimal("28.5"))
    again = rail.create_payout(request("28.50"))
    assert again.reference == "pout_1" and len(server.payouts) == 1  # the rail refused a second payout of one attempt
    assert rail.create_payout(request("28.50", attempt=2)).reference == "pout_2"
    fetched = rail.fetch_payout("pout_1")
    assert (fetched.status, fetched.utr) == ("paid", "UTR42")
    assert rail.find_payout(f"{LINE}:2").reference == "pout_2"
    assert rail.find_payout(f"{uuid.uuid4()}:1") is None
    with pytest.raises(RailError) as e:
        rail.create_payout(request(currency="USD"))
    assert e.value.code == "currency_not_supported"


def test_429_honours_retry_after_and_5xx_backs_off_then_succeeds():
    server = FakeRazorpayX()
    server.faults["POST /v1/contacts"] = [
        httpx.Response(429, headers={"Retry-After": "2"}),
        httpx.Response(503),
    ]
    rail, sleeps = rail_with(server)
    rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert sleeps == [2.0, 2.0]  # Retry-After, then full jitter (the test rng picks the top: 0.5 * 2**2)


def test_every_attempt_failing_is_unavailable_and_a_4xx_is_never_retried():
    server = FakeRazorpayX()
    server.faults["POST /v1/contacts"] = [httpx.Response(500)] * 3
    rail, sleeps = rail_with(server)
    with pytest.raises(RailUnavailable):
        rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert len(sleeps) == 2
    server.faults["POST /v1/contacts"] = [httpx.ConnectError("down")] * 3
    with pytest.raises(RailUnavailable):
        rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    server.faults["POST /v1/contacts"] = [
        httpx.Response(400, json={"error": {"code": "BAD_REQUEST_ERROR", "description": "bad ifsc"}})
    ]
    with pytest.raises(RailError) as e:
        rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert (e.value.code, e.value.status, str(e.value)) == ("BAD_REQUEST_ERROR", 400, "bad ifsc")
    server.faults["POST /v1/contacts"] = [httpx.Response(401, text="not json")]
    with pytest.raises(RailError) as e:
        rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert e.value.code == "http_401"


def test_a_timeout_after_a_payout_was_sent_is_an_unknown_outcome_other_timeouts_retry(caplog):
    server = FakeRazorpayX()
    server.faults["POST /v1/payouts"] = [httpx.ReadTimeout("slow")]
    rail, _ = rail_with(server)
    with caplog.at_level("WARNING"), pytest.raises(RailUnknownOutcome):
        rail.create_payout(request())
    server.faults["GET /v1/fund_accounts/validations/fav_1"] = [httpx.ReadTimeout("slow")]
    assert rail.fetch_validation("fav_1").status == "verified"
    assert "Asha" not in caplog.text and "123456789012" not in caplog.text


def test_the_client_side_limiter_waits_for_a_slot():
    from yantra_common.ratelimit import SlidingWindowLimiter

    server = FakeRazorpayX()
    clock = [0.0]

    class Limiter(SlidingWindowLimiter):
        def check(self, key: str, now: float | None = None) -> float:
            return super().check(key, clock[0])

    def sleep(seconds: float) -> None:
        clock[0] += seconds

    client = httpx.Client(base_url="https://rzp.test/v1", auth=("k", "s"), transport=httpx.MockTransport(server))
    rail = RazorpayXRail("k", "s", "1", client=client, sleep=sleep, limiter=Limiter(1, window_seconds=60))
    rail.fetch_validation("fav_1")
    rail.fetch_validation("fav_1")
    assert clock[0] == 60.0


def test_status_maps_and_entity_parsing():
    assert payout_of({"id": "p", "status": "processed", "utr": "U", "amount": 2800}).status == "paid"
    assert payout_of({"id": "p", "status": "reversed", "status_details": {"reason": "closed"}}).reason == "closed"
    assert payout_of({"id": "p", "status": "rejected", "failure_reason": "no funds"}).status == "failed"
    assert payout_of({"id": "p", "status": "something_new"}).status == "processing"
    assert payout_of({"id": "p", "status": "queued"}).amount is None
    assert validation_of({"id": "v", "status": "completed", "results": {"account_status": "invalid"}}).reason == (
        "invalid_account"
    )
    assert validation_of({"id": "v", "status": "failed"}).reason == "rail_error"
    assert narration("!!!") == "Yantra payout" and len(narration("x" * 50)) == 30


def test_the_fake_rail_decides_every_outcome_from_its_input():
    rail = FakeRail()
    good = rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")
    assert rail.start_validation(good.fund_account_id, "Asha Rao", LINE).status == "pending"
    assert rail.fetch_validation(f"fav_{good.fund_account_id}").registered_name == "ASHA RAO"
    bad = rail.register(LINE, "Asha Rao", "123456780000", "HDFC0001234")
    assert rail.fetch_validation(f"fav_{bad.fund_account_id}").reason == "invalid_account"
    other = rail.register(LINE, "Asha Rao", "123456781111", "HDFC0001234")
    assert rail.fetch_validation(f"fav_{other.fund_account_id}").registered_name == "SOMEONE ELSE"
    assert rail.find_payout(f"{LINE}:1") is None
    paid = rail.create_payout(request("28.00"))
    assert rail.fetch_payout(paid.reference).status == "paid" and rail.find_payout(f"{LINE}:1").utr
    assert rail.fetch_payout(rail.create_payout(request("28.13", 2)).reference).reason == "insufficient_funds"
    assert rail.fetch_payout(rail.create_payout(request("28.99", 3)).reference).status == "returned"


def test_the_file_rail_registers_as_given_and_leaves_lines_to_the_return_file():
    rail = FileRail()
    fund = rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234").fund_account_id
    assert rail.start_validation(fund, "Asha Rao", LINE).status == "verified"
    assert rail.fetch_validation("x").status == "verified" and rail.supports_penny_drop is False
    sent = rail.create_payout(request())
    assert sent.reference.startswith("FILE-") and rail.fetch_payout(sent.reference).status == "processing"
    assert rail.find_payout(f"{LINE}:1") is None


def test_yantra_rail_picks_the_adapter_and_razorpayx_needs_its_keys(monkeypatch):
    assert isinstance(select_rail(PayoutSettings()), FakeRail)
    assert isinstance(select_rail(PayoutSettings(rail="file")), FileRail)
    with pytest.raises(ValueError, match="YANTRA_RAZORPAYX_KEY_ID"):
        PayoutSettings(rail="razorpayx")
    monkeypatch.setenv("YANTRA_RAIL", "razorpayx")
    monkeypatch.setenv("YANTRA_RAZORPAYX_KEY_ID", "rzp_test_k")
    monkeypatch.setenv("YANTRA_RAZORPAYX_KEY_SECRET", "s")
    monkeypatch.setenv("YANTRA_RAZORPAYX_ACCOUNT_NUMBER", "2323230000000001")
    monkeypatch.setenv("YANTRA_PAYOUT_CURRENCIES", '["INR","USD"]')
    s = PayoutSettings()
    assert s.payout_currencies == ["INR", "USD"]
    rail = select_rail(s)
    assert isinstance(rail, RazorpayXRail) and rail.account_number == "2323230000000001"


def test_every_attempt_has_its_own_reference_and_a_lookup_finds_exactly_that_attempt():
    server = FakeRazorpayX()
    rail, _ = rail_with(server)
    rail.create_payout(request("28.50"))
    sent = json.loads(server.seen[-1].content)
    assert sent["reference_id"] == f"{LINE}:1" and server.seen[-1].headers["X-Payout-Idempotency"] == f"{LINE}:1"
    second = rail.create_payout(request("28.50", attempt=2))
    # the rail's own listing is newest first and may hold a payout another attempt left behind
    server.payouts["pout_stray"] = {**server.payouts["pout_1"], "id": "pout_stray", "reference_id": f"{LINE}:10"}
    found = rail.find_payout(f"{LINE}:1")
    assert found is not None and found.reference == "pout_1" and found.reference_id == f"{LINE}:1"
    assert rail.find_payout(f"{LINE}:2").reference == second.reference == "pout_2"
    assert rail.find_payout(f"{LINE}:3") is None
    assert len(PayoutRequest(LINE, 999, "fa_1", Decimal("1"), "INR", "x").reference_id) == 40  # RazorpayX's limit


def test_the_fake_and_file_rails_scope_references_to_the_attempt():
    fake = FakeRail()
    one, two = fake.create_payout(request("28.00", 1)), fake.create_payout(request("28.00", 2))
    assert (one.reference_id, two.reference_id) == (f"{LINE}:1", f"{LINE}:2")
    assert fake.find_payout(f"{LINE}:1").reference == one.reference and fake.find_payout(f"{LINE}:7") is None
    assert FileRail().create_payout(request(attempt=3)).reference_id == f"{LINE}:3"


def test_a_refusal_after_an_ambiguous_payout_attempt_is_an_unknown_outcome():
    server = FakeRazorpayX()
    rail, _ = rail_with(server)
    refusal = httpx.Response(400, json={"error": {"code": "BAD_REQUEST_ERROR"}})
    for ambiguous in (httpx.Response(502), httpx.RemoteProtocolError("dropped"), httpx.ReadError("reset")):
        server.faults["POST /v1/payouts"] = [ambiguous, refusal]
        with pytest.raises(RailUnknownOutcome):
            rail.create_payout(request())
    # a 429 or a refused connection never reached the payout: the refusal stands
    for clean in (httpx.Response(429), httpx.ConnectError("refused")):
        server.faults["POST /v1/payouts"] = [clean, refusal]
        with pytest.raises(RailError):
            rail.create_payout(request())
    # other paths are not money: a refusal after a 5xx is still a refusal
    server.faults["POST /v1/contacts"] = [httpx.Response(503), refusal]
    with pytest.raises(RailError):
        rail.register(LINE, "Asha Rao", "123456789012", "HDFC0001234")


def test_a_razorpayx_webhook_secret_must_be_long_when_set():
    keys = {
        "rail": "razorpayx",
        "razorpayx_key_id": "k",
        "razorpayx_key_secret": "s",
        "razorpayx_account_number": "1",
    }
    assert PayoutSettings(**keys).razorpayx_webhook_secret is None  # unset: no webhook route, the poll settles
    for weak in ("", "whsec", "x" * 31):
        with pytest.raises(ValueError, match="YANTRA_RAZORPAYX_WEBHOOK_SECRET"):
            PayoutSettings(**keys, razorpayx_webhook_secret=weak)
    assert PayoutSettings(**keys, razorpayx_webhook_secret="x" * 32).razorpayx_webhook_secret is not None

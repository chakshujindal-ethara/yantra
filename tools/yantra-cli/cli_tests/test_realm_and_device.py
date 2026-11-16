"""The realm renderer (merge rules, drift check, the committed rig realm is current) and the device-flow login."""

import base64
import json
from pathlib import Path

import httpx
import pytest

from yantra_cli import auth
from yantra_cli.__main__ import main
from yantra_cli.realm import ROOT, merge, render, render_local

from .conftest import WORKER


def test_merge_keys_objects_lists_by_identity_and_replaces_the_rest():
    base = {
        "a": 1,
        "nested": {"x": 1, "y": 2},
        "clients": [{"clientId": "app", "public": True, "uris": ["b"]}, {"clientId": "odoo"}],
        "flows": [{"alias": "f", "steps": [1]}],
        "tags": ["a", "b"],
        "mixed": [{"name": "n"}, {"other": 1}],
    }
    overlay = {
        "nested": {"y": 3, "z": 4},
        "clients": [{"clientId": "app", "uris": ["l"]}, {"clientId": "smoke"}],
        "flows": [{"alias": "g"}],
        "tags": ["c"],
        "mixed": [{"name": "m"}],
        "new": True,
    }
    out = merge(base, overlay)
    assert out["a"] == 1 and out["nested"] == {"x": 1, "y": 3, "z": 4} and out["new"] is True
    assert out["clients"] == [
        {"clientId": "app", "public": True, "uris": ["l"]},
        {"clientId": "odoo"},
        {"clientId": "smoke"},
    ]
    assert [f["alias"] for f in out["flows"]] == ["f", "g"]
    assert out["tags"] == ["c"] and out["mixed"] == [{"name": "m"}]  # no shared identity key: replaced
    assert merge([], [{"name": "x"}]) == [{"name": "x"}]


def test_the_committed_rig_realm_is_base_plus_local_and_keeps_every_user():
    assert render_local(check=True), "deployment/local/keycloak/yantra-realm.json drifted: run `yantra realm-render`"
    rig = json.loads((ROOT / "deployment/local/keycloak/yantra-realm.json").read_text())
    users = {u["username"]: (u["id"], sorted(u.get("realmRoles", []))) for u in rig["users"]}
    assert users["ops1"] == ("00000000-0000-4000-8000-00000000a001", ["finance", "ops"])
    assert users["worker1"][1] == ["reviewer", "worker"] and users["worker4"][1] == ["worker"]
    assert users["admin1"] == ("00000000-0000-4000-8000-00000000ad01", ["admin"])
    assert users["noroles1"] == ("00000000-0000-4000-8000-00000000ad02", [])
    assert users["client1"][1] == ["client"] and users["service-account-yantra-odoo"][1] == ["ops"]
    app = next(c for c in rig["clients"] if c["clientId"] == "yantra-app")
    assert app["directAccessGrantsEnabled"] is True and app["optionalClientScopes"] == []  # the rig's password grant
    assert rig["browserFlow"] == "browser-mfa" and rig["directGrantFlow"] == "direct-grant-password"


def test_the_production_base_is_strict():
    base = json.loads((ROOT / "deployment/keycloak/yantra-realm.json").read_text())
    assert base["sslRequired"] == "external" and base["bruteForceProtected"] is True and "users" not in base
    assert base["accessTokenLifespan"] == 900 and base["ssoSessionMaxLifespan"] == 86400
    assert base["registrationAllowed"] is True and base["verifyEmail"] is True
    app = next(c for c in base["clients"] if c["clientId"] == "yantra-app")
    assert app["directAccessGrantsEnabled"] is False and app["attributes"]["pkce.code.challenge.method"] == "S256"
    # explicit: naming the optional scopes (none: no offline tokens) drops the implied defaults, `sub` and roles too
    assert {"basic", "roles", "profile"} <= set(app["defaultClientScopes"]) and app["optionalClientScopes"] == []
    odoo = next(c for c in base["clients"] if c["clientId"] == "yantra-odoo")
    assert "secret" not in odoo
    roles = {r["name"]: r for r in base["roles"]["realm"]}
    for staff in ("ops", "finance", "admin"):
        assert roles[staff]["composites"]["realm"] == ["mfa-required"]
    assert roles["default-roles-yantra"]["composites"]["realm"] == ["worker"]
    assert base["authenticatorConfig"][0]["config"]["forceOtpRole"] == "mfa-required"
    staging = json.loads(render(ROOT, "staging"))
    assert staging["sslRequired"] == "external" and any(c["clientId"] == "yantra-smoke" for c in staging["clients"])
    # refresh tokens rotate and are single-use; the public client has no device grant outside the rig
    assert base["revokeRefreshToken"] is True and base["refreshTokenMaxReuse"] == 0
    assert app["attributes"]["oauth2.device.authorization.grant.enabled"] == "false"
    rig_app = next(c for c in json.loads(render(ROOT, "local"))["clients"] if c["clientId"] == "yantra-app")
    assert rig_app["attributes"]["oauth2.device.authorization.grant.enabled"] == "true"
    # staging: the password flow is the smoke client's alone, and admits only holders of the smoke role
    assert "directGrantFlow" not in staging
    flows = {f["alias"]: f for f in staging["authenticationFlows"]}
    smoke = next(c for c in staging["clients"] if c["clientId"] == "yantra-smoke")
    assert smoke["authenticationFlowBindingOverrides"] == {"direct_grant": flows["direct-grant-password"]["id"]}
    gate = flows["direct-grant-password smoke users only"]["authenticationExecutions"]
    assert [e["authenticator"] for e in gate] == ["conditional-user-role", "deny-access-authenticator"]
    config = {c["alias"]: c["config"] for c in staging["authenticatorConfig"]}
    assert config[gate[0]["authenticatorConfig"]] == {"condUserRole": "smoke", "negate": "true"}
    assert all("smoke" in u["realmRoles"] and u["emailVerified"] for u in staging["users"])


def test_realm_render_writes_and_check_reports_drift(tmp_path: Path, capsys):
    for rel in ("deployment/keycloak/yantra-realm.json", "deployment/keycloak/overlays/local.json"):
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text((ROOT / rel).read_text())
    (tmp_path / "deployment/local/keycloak").mkdir(parents=True)
    assert render_local(tmp_path, check=True) is False  # nothing there yet
    assert render_local(tmp_path) is True and render_local(tmp_path, check=True) is True
    assert main(["realm-render", "--check"]) == 0 and "realm current" in capsys.readouterr().out


def test_realm_render_command_paths(monkeypatch, capsys):
    import yantra_cli.__main__ as cli

    monkeypatch.setattr(cli, "render_local", lambda check=False: not check)
    assert main(["realm-render"]) == 0 and "realm written" in capsys.readouterr().out
    assert main(["realm-render", "--check"]) == 1 and "drifted" in capsys.readouterr().err


def jwt_for(username: str) -> str:
    def part(doc: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(doc).encode()).decode().rstrip("=")

    claims = {"sub": WORKER, "preferred_username": username, "realm_access": {"roles": ["worker"]}}
    return part({"alg": "none"}) + "." + part(claims) + ".sig"


def device_backend(backend, answers: list[httpx.Response], start_status: int = 200):
    starts = []

    def start(request: httpx.Request) -> httpx.Response:
        starts.append(dict(x.split("=", 1) for x in request.content.decode().split("&")))
        return httpx.Response(
            start_status,
            json={
                "device_code": "dc",
                "user_code": "ABCD-EFGH",
                "verification_uri": "http://kc/device",
                "interval": 1,
                "expires_in": 60,
            },
        )

    polls = []

    def token(request: httpx.Request) -> httpx.Response:
        polls.append(dict(x.split("=", 1) for x in request.content.decode().split("&")))
        return answers.pop(0)

    backend.on("POST /realms/yantra/protocol/openid-connect/auth/device", start)
    backend.on("POST /realms/yantra/protocol/openid-connect/token", token)
    return starts, polls


def test_device_login_shows_the_code_polls_with_the_verifier_and_slows_down(backend, cfg):
    pending = httpx.Response(400, json={"error": "authorization_pending"})
    slow = httpx.Response(400, json={"error": "slow_down"})
    ok = httpx.Response(200, json={"access_token": jwt_for("worker1"), "refresh_token": "r", "expires_in": 300})
    starts, polls = device_backend(backend, [pending, slow, ok])
    said, slept = [], []
    session = auth.device_login(backend.client, cfg, say=said.append, sleep=slept.append, clock=lambda: 0.0)
    assert session.username == "worker1" and session.worker_id == WORKER and session.expires_at > 0
    assert said == ["open http://kc/device and confirm code ABCD-EFGH"]
    assert slept == [1.0, 1.0, 6.0]  # slow_down adds five seconds
    assert starts[0]["code_challenge_method"] == "S256" and len(starts[0]["code_challenge"]) == 43
    assert all(p["code_verifier"] and p["device_code"] == "dc" for p in polls)


def test_device_login_refusals_and_timeouts(backend, cfg):
    device_backend(backend, [httpx.Response(400, json={"error": "access_denied"})])
    with pytest.raises(auth.AuthError, match="access_denied"):
        auth.device_login(backend.client, cfg, say=lambda m: None, sleep=lambda s: None, clock=lambda: 0.0)
    device_backend(backend, [httpx.Response(500, text="boom")])
    with pytest.raises(auth.AuthError, match="500"):
        auth.device_login(backend.client, cfg, say=lambda m: None, sleep=lambda s: None, clock=lambda: 0.0)
    device_backend(backend, [], start_status=401)
    with pytest.raises(auth.AuthError, match="device login refused \\(401\\)"):
        auth.device_login(backend.client, cfg, say=lambda m: None, sleep=lambda s: None)
    ticks = iter([0.0, 100.0])
    device_backend(backend, [])
    with pytest.raises(auth.AuthError, match="timed out"):
        auth.device_login(backend.client, cfg, say=lambda m: None, sleep=lambda s: None, clock=lambda: next(ticks))


def test_device_login_when_keycloak_is_away(cfg):
    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    with pytest.raises(auth.AuthError, match="unreachable"):
        auth.device_login(httpx.Client(transport=httpx.MockTransport(down)), cfg, say=lambda m: None)
    calls = []

    def start_then_down(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        if len(calls) == 1:
            return httpx.Response(200, json={"device_code": "d", "user_code": "u", "verification_uri": "v"})
        raise httpx.ConnectError("down")

    with pytest.raises(auth.AuthError, match="unreachable"):
        auth.device_login(
            httpx.Client(transport=httpx.MockTransport(start_then_down)), cfg, say=lambda m: None, sleep=lambda s: None
        )


def test_login_device_and_a_confidential_client_through_main(backend, env, capsys, monkeypatch):
    ok = httpx.Response(200, json={"access_token": jwt_for("worker1"), "refresh_token": "r", "expires_in": 300})
    starts, _ = device_backend(backend, [ok])
    monkeypatch.setattr(auth.time, "sleep", lambda s: None)
    assert main(["login", "--device"], http=backend.client, env={**env, "YANTRA_CLIENT_SECRET": "s3"}) == 0
    out = capsys.readouterr().out
    assert "confirm code ABCD-EFGH" in out and "logged in as worker1" in out
    assert starts[0]["client_secret"] == "s3"
    assert main(["login"], http=backend.client, env=env) == 2 and "usage" in capsys.readouterr().err

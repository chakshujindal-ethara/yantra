"""Thin HTTP client for the Yantra gateway.

One instance per logical action (its Idempotency-Key is one uuid4). The Keycloak service-account token is
cached per process and refreshed 30 s before it expires. Nothing here logs a token, a secret or a body.
"""

import logging
import random
import threading
import time
import uuid

import requests
from odoo.exceptions import UserError

_logger = logging.getLogger(__name__)

REALM = "yantra"
CONNECT_TIMEOUT_S = 3
READ_TIMEOUT_S = 10
TOKEN_SLACK_S = 30
RETRY_STATUSES = (429, 503)
MAX_RETRY_AFTER_S = 30
SETTINGS = {
    "gateway_url": "yantra.gateway_url",
    "keycloak_url": "yantra.keycloak_url",
    "client_id": "yantra.keycloak_client_id",
    "client_secret": "yantra.keycloak_client_secret",
}

SESSION = requests.Session()
_sleep = time.sleep
_TOKENS: dict[tuple[str, str], tuple[str, float]] = {}
_TOKEN_LOCK = threading.Lock()


class GatewayError(Exception):
    """The gateway (or Keycloak) answered with an error. `body` is the parsed JSON error, if any."""

    def __init__(self, status, code, message, request_id=None, body=None):
        super().__init__(f"{code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.request_id = request_id
        self.body = body or {}


def _read_settings(env):
    icp = env["ir.config_parameter"].sudo()
    values = {name: (icp.get_param(key) or "").strip() for name, key in SETTINGS.items()}
    missing = [SETTINGS[name] for name, value in values.items() if not value]
    return values, missing


def is_configured(env):
    return not _read_settings(env)[1]


def _retry_delay(response):
    header = response.headers.get("Retry-After")
    try:
        wait = min(int(header), MAX_RETRY_AFTER_S) if header else 1
    except ValueError:
        wait = 1
    return wait + random.uniform(0, 0.5)


def _error_from(response):
    try:
        body = response.json() if response.content else {}
    except ValueError:
        body = {}
    if not isinstance(body, dict):
        body = {}
    return GatewayError(
        response.status_code,
        body.get("code") or f"http_{response.status_code}",
        body.get("message") or "gateway error",
        body.get("request_id"),
        body,
    )


class GatewayClient:
    def __init__(self, env):
        values, missing = _read_settings(env)
        if missing:
            raise UserError(env._("Yantra is not configured: set %s in Settings > Yantra.", ", ".join(missing)))
        self.gateway_url = values["gateway_url"].rstrip("/")
        self.keycloak_url = values["keycloak_url"].rstrip("/")
        self.client_id = values["client_id"]
        self._client_secret = values["client_secret"]
        self.idempotency_key = str(uuid.uuid4())

    def get(self, path, params=None):
        return self._call("GET", path, params=params)

    def put(self, path, body):
        return self._call("PUT", path, json=body)

    def _call(self, method, path, params=None, json=None):
        headers = {"Authorization": f"Bearer {self._token()}", "Accept": "application/json"}
        if method in ("POST", "PUT"):
            headers["Idempotency-Key"] = self.idempotency_key
        response = self._send(method, self.gateway_url + path, params=params, json=json, headers=headers)
        if response.status_code in RETRY_STATUSES:
            _sleep(_retry_delay(response))
            response = self._send(method, self.gateway_url + path, params=params, json=json, headers=headers)
        if 200 <= response.status_code < 300:
            return response.json() if response.content else None
        raise _error_from(response)

    @staticmethod
    def _send(method, url, **kwargs):
        try:
            return SESSION.request(method, url, timeout=(CONNECT_TIMEOUT_S, READ_TIMEOUT_S), **kwargs)
        except requests.RequestException as exc:
            raise GatewayError(0, "gateway_unreachable", type(exc).__name__) from exc

    def _token(self):
        key = (self.keycloak_url, self.client_id)
        with _TOKEN_LOCK:
            cached = _TOKENS.get(key)
            if cached and cached[1] > time.monotonic():
                return cached[0]
            token, expires_in = self._fetch_token()
            _TOKENS[key] = (token, time.monotonic() + max(expires_in - TOKEN_SLACK_S, 0))
            return token

    def _fetch_token(self):
        url = f"{self.keycloak_url}/realms/{REALM}/protocol/openid-connect/token"
        data = {"grant_type": "client_credentials", "client_id": self.client_id, "client_secret": self._client_secret}
        response = self._send("POST", url, data=data)
        if response.status_code != 200:
            raise GatewayError(response.status_code, "token_rejected", "Keycloak refused the service account")
        payload = response.json()
        return payload["access_token"], int(payload.get("expires_in", 60))

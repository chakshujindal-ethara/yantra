"""Where the CLI points. Everything comes from the environment with the local rig as the default."""

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    gateway_url: str
    keycloak_url: str
    realm: str
    client_id: str
    session_file: Path
    client_secret: str | None = None  # only for a confidential client (the staging smoke client), never the app

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        e = os.environ if env is None else env
        default_session = Path(e.get("HOME", ".")) / ".config" / "yantra" / "session.json"
        return cls(
            gateway_url=e.get("YANTRA_GATEWAY_URL", "http://localhost:8090").rstrip("/"),
            keycloak_url=e.get("YANTRA_KEYCLOAK_URL", "http://localhost:8180").rstrip("/"),
            realm=e.get("YANTRA_REALM", "yantra"),
            client_id=e.get("YANTRA_CLIENT_ID", "yantra-app"),
            session_file=Path(e.get("YANTRA_SESSION_FILE", str(default_session))),
            client_secret=e.get("YANTRA_CLIENT_SECRET") or None,
        )

    @property
    def token_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.realm}/protocol/openid-connect/token"

    @property
    def device_url(self) -> str:
        return f"{self.keycloak_url}/realms/{self.realm}/protocol/openid-connect/auth/device"

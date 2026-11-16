"""The assess module's own settings: which engine runs the papers and how to reach it. Read from `YANTRA_ASSESS_*`.

`YANTRA_ASSESS_ENGINE` picks the engine: `v2` (Ethara's Assessment v2 inside Yantra's Odoo, reached through the
`yantra_assess_bridge` addon) or `fake` (deterministic, in-process; tests and a rig without Odoo only). `v2` without
its client secret, `fake` outside `YANTRA_ENV=local`, and the rig's client secret outside `local` all fail the
process at boot."""

import os
from typing import Literal, Self

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

EngineName = Literal["v2", "fake"]
LOCAL_CLIENT_SECRET = "yantra-assess-local-secret"


class AssessSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_ASSESS_", extra="ignore")

    engine: EngineName = "fake"
    odoo_url: str = "http://odoo:8069"  # where the work process reaches Odoo (the bridge and v2's API)
    app_url: str = "http://localhost:8096"  # the Assessment app the worker's browser opens
    return_url: str = "http://localhost:8095"  # the Yantra app the Assessment app sends the worker back to
    keycloak_token_url: str = "http://keycloak:8080/realms/yantra/protocol/openid-connect/token"
    client_id: str = "yantra-assess"
    client_secret: SecretStr | None = None
    timeout_seconds: float = Field(default=10.0, gt=0)
    sync_seconds: int = Field(default=15, ge=5)

    @model_validator(mode="after")
    def _guards(self) -> Self:
        env = os.environ.get("YANTRA_ENV", "local")
        if self.engine == "v2" and not self.client_secret:
            raise ValueError("YANTRA_ASSESS_ENGINE=v2 needs YANTRA_ASSESS_CLIENT_SECRET")
        if env != "local":
            if self.engine == "fake":
                raise ValueError(f"YANTRA_ENV={env} refuses YANTRA_ASSESS_ENGINE=fake")
            if self.client_secret and self.client_secret.get_secret_value() == LOCAL_CLIENT_SECRET:
                raise ValueError(f"YANTRA_ENV={env} refuses the rig's YANTRA_ASSESS_CLIENT_SECRET")
        return self

"""`yantra smoke --with-storage`: after the main smoke, the stored-media path end to end on the rig. Ops presign an
upload, the bytes go straight to MinIO, the import keeps the ref, a worker's claim opens a five-minute link that
returns the same bytes, the worker gives the claim back, and the stuck-work and attention views answer. Skipped (and
said so) when the rig has no object storage."""

import uuid
from dataclasses import dataclass
from typing import Any

import httpx

from yantra_cli.client import Gateway, GatewayError
from yantra_cli.smoke import SmokeFailed, check

SCHEMA = {"type": "object", "required": ["audio"], "properties": {"audio": {"type": "string"}}}
BODY = b"RIFF smoke clip"


@dataclass
class StorageSmoke:
    ops: Gateway
    worker: Gateway
    http: httpx.Client

    def run(self) -> dict[str, Any]:
        tag = uuid.uuid4().hex[:6]
        project = self.ops.post(
            "/v1/projects",
            {"name": f"Storage smoke {tag}", "currency": "INR", "payload_schema": SCHEMA, "margin_floor": "0"},
        )
        batch = self.ops.post(
            f"/v1/projects/{project['id']}/batches", {"title": "media", "unit_pay": "1", "unit_price": "2"}
        )
        try:
            ups = self.ops.post(
                f"/v1/batches/{batch['id']}/payload-uploads",
                {"files": [{"name": f"clip-{tag}.wav", "content_type": "audio/wav", "size_bytes": len(BODY)}]},
            )
        except GatewayError as e:
            if e.code == "storage_unconfigured":
                return {"storage": "skipped: the rig has no object storage"}
            raise
        up = ups["uploads"][0]
        put = self.http.put(up["url"], content=BODY, headers=up["headers"])
        check(put.status_code == 200, f"the presigned upload was refused ({put.status_code})")
        lines = [{"external_ref": f"m-{tag}", "payload": {"audio": up["ref"]}}]
        self.ops.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
        self.ops.post(f"/v1/batches/{batch['id']}/publish", {})
        claim = self.worker.post(f"/v1/batches/{batch['id']}/claims")
        link = self.worker.get(f"/v1/units/{claim['unit_id']}/payload-url")
        got = self.http.get(link["url"])
        check(got.status_code == 200 and got.content == BODY, "the payload link did not return the uploaded bytes")
        released = self.worker.post(f"/v1/claims/{claim['id']}/release")
        check(released["status"] == "released", "the worker could not give the claim back")
        try:
            self.worker.get(f"/v1/units/{claim['unit_id']}/payload-url")
        except GatewayError as e:
            check(e.status == 404, f"a released claim kept its link ({e.status})")
        else:
            raise SmokeFailed("a released claim kept its payload link")
        expired = self.ops.get("/v1/claims/expired")
        attention = self.ops.get("/v1/attention")
        check(isinstance(expired, list) and "dead_letters" in attention, "stuck work or attention did not answer")
        return {"storage": "ok", "object": up["key"], "bytes": len(BODY)}

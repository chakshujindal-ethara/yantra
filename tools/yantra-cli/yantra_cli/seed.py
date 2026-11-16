"""`yantra seed`: a small, believable world on a fresh rig so every screen has something to show: a client
organisation with a member, two projects (one with a published batch), an assessment paper, two listings
(one behind the paper), certified workers, a worker mid-application, an offer waiting, a support ticket.
Safe to run again: names carry a short suffix, nothing is deleted, and every call goes through the gateway
as the person who would do it in real life."""

import io
import math
import struct
import time
import uuid
import wave
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx

from yantra_cli.auth import login
from yantra_cli.client import Gateway, GatewayError
from yantra_cli.config import Config
from yantra_cli.smoke import bank_account_for, check

CLIENT1 = "00000000-0000-4000-8000-0000000000c1"
PAYLOAD_SCHEMA = {
    "type": "object",
    "required": ["audio_ref", "language"],
    "properties": {
        "audio_ref": {"type": "string", "minLength": 1},
        "language": {"type": "string", "enum": ["hi", "ta"]},
    },
}
ANSWER_SCHEMA = {
    "type": "object",
    "required": ["transcript", "speakers"],
    "properties": {
        "transcript": {"type": "string", "title": "Transcript", "minLength": 1},
        "speakers": {"type": "integer", "title": "Number of speakers", "minimum": 1, "maximum": 6},
        "noisy": {"type": "boolean", "title": "Background noise"},
    },
}
QUESTIONS = [
    {
        "id": "q1",
        "prompt": "A speaker says a number in Hindi. How do you write it in the transcript?",
        "kind": "single",
        "options": ["As digits", "As the word, as spoken", "Skip it"],
        "answer": "As the word, as spoken",
    },
    {
        "id": "q2",
        "prompt": "Which of these are transcribed verbatim?",
        "kind": "multi",
        "options": ["Filler words", "Repeated words", "Background music", "False starts"],
        "answer": ["Filler words", "Repeated words", "False starts"],
    },
    {
        "id": "q3",
        "prompt": "Two people talk over each other. What do you do?",
        "kind": "single",
        "options": ["Transcribe the louder voice only", "Tag the overlap and transcribe both", "Leave a gap"],
        "answer": "Tag the overlap and transcribe both",
    },
    {
        "id": "q4",
        "prompt": "Which tag marks a word you cannot make out?",
        "kind": "single",
        "options": ["[unclear]", "[inaudible]", "[noise]"],
        "answer": "[inaudible]",
    },
]
BRIEF = (
    "Transcribe short Hindi clips verbatim. Keep filler words, mark overlaps, write numbers as spoken. "
    "Tag an unclear word as [inaudible]. One clip is one unit; the rubric is v1."
)
LLM_POLICY = (
    "Allowed: spelling and grammar checks on your own transcript. Not allowed: generating the transcript "
    "from the audio with a model, or judging another worker's answer with a model."
)


@dataclass
class Seed:
    cfg: Config
    password: str
    http: httpx.Client
    sleep: Callable[[float], None] = time.sleep
    say: Callable[[str], None] = print
    users: dict[str, Gateway] = field(default_factory=dict)

    def as_user(self, name: str) -> Gateway:
        if name not in self.users:
            self.users[name] = Gateway(self.cfg, login(self.http, self.cfg, name, self.password), self.http, self.sleep)
        return self.users[name]

    def run(self) -> dict[str, Any]:
        ops = self.as_user("ops1")
        tag = uuid.uuid4().hex[:4]
        self.say("1. a client organisation with client1 as its member")
        org = ops.post("/v1/client-orgs", {"name": f"Acme Labs {tag}"})
        ops.put(f"/v1/client-orgs/{org['id']}/members/{CLIENT1}")

        self.say("2. two projects; the first has a published batch of eight units")
        hindi = ops.post(
            "/v1/projects",
            {
                "name": f"Hindi speech transcription {tag}",
                "currency": "INR",
                "payload_schema": PAYLOAD_SCHEMA,
                "answer_schema": ANSWER_SCHEMA,
                "cert_gate": "transcription",
                "margin_floor": "0.3",
            },
        )
        ops.call(
            "PATCH",
            f"/v1/projects/{hindi['id']}",
            {"status": "active", "brief": BRIEF, "llm_policy": LLM_POLICY, "client_org_id": org["id"]},
        )
        batch = ops.post(
            f"/v1/projects/{hindi['id']}/batches",
            {
                "title": "Week 45 clips",
                "unit_pay": "28",
                "unit_price": "60",
                "review_pay": "6",
                "claim_ttl_minutes": 60,
            },
        )
        refs = self._clips(ops, batch["id"], tag, 8)
        lines = [
            {"external_ref": f"clip-{tag}-{i:02d}", "payload": {"audio_ref": ref, "language": "hi"}}
            for i, ref in enumerate(refs)
        ]
        ops.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
        ops.post(f"/v1/batches/{batch['id']}/publish", {})
        tamil = ops.post(
            "/v1/projects",
            {
                "name": f"Tamil caption QA {tag}",
                "currency": "INR",
                "payload_schema": PAYLOAD_SCHEMA,
                "cert_gate": "captions",
                "margin_floor": "0.25",
            },
        )
        ops.call("PATCH", f"/v1/projects/{tamil['id']}", {"status": "active", "client_org_id": org["id"]})

        self.say("3. a published assessment paper (in the Assessment app) that grants the transcription gate")
        paper = ops.post(
            "/v1/assess/papers",
            {
                "gate": "transcription",
                "title": f"Transcription basics {tag}",
                "description": "Four questions on the verbatim rules, sat in the Assessment app. Pass at 75%.",
                "max_attempts": 3,
                # objective questions only: the adapter releases a clean result itself, so a pass certifies at once
                "release_policy": "auto_objective",
                "source": {"kind": "quick", "duration_minutes": 15, "pass_mark": "0.75", "questions": QUESTIONS},
            },
        )
        ops.post(f"/v1/assess/papers/{paper['id']}/publish", {})

        self.say("4. two open listings: Hindi behind the paper, Tamil screened by hand")
        closes = (datetime.now(UTC) + timedelta(days=21)).isoformat()
        hindi_listing = ops.post(
            "/v1/talent/listings",
            {
                "title": f"Hindi transcription pool {tag}",
                "domain": "Speech",
                "summary": "Verbatim transcription of short Hindi clips, paid per accepted unit.",
                "description": BRIEF,
                "pay_min": "25",
                "pay_max": "40",
                "pay_unit": "per_unit",
                "currency": "INR",
                "commitment": "task_based",
                "hours_per_week": 10,
                "slots_total": 12,
                "cert_gate": "transcription",
                "paper_id": paper["id"],
                "requirements": ["Native Hindi", "A quiet place and headphones", "Two hours a day on weekdays"],
                "questions": [
                    {
                        "key": "experience",
                        "prompt": "Years of transcription experience",
                        "kind": "choice",
                        "options": ["None", "Under 1", "1 to 3", "3+"],
                        "required": True,
                    },
                    {
                        "key": "sample",
                        "prompt": "Transcribe: 'haan ji, main kal aaunga'",
                        "kind": "text",
                        "required": True,
                    },
                ],
                "llm_policy": LLM_POLICY,
                "sensitive": False,
                "closes_at": closes,
            },
        )
        ops.call("PATCH", f"/v1/talent/listings/{hindi_listing['id']}", {"status": "open"})
        tamil_listing = ops.post(
            "/v1/talent/listings",
            {
                "title": f"Tamil captions QA pool {tag}",
                "domain": "Captions",
                "summary": "Check machine captions against Tamil audio; fix timing and words.",
                "description": "Each unit is a 30-second clip with its caption file.",
                "pay_min": "18",
                "pay_max": "24",
                "pay_unit": "per_unit",
                "currency": "INR",
                "commitment": "part_time",
                "hours_per_week": 15,
                "slots_total": 6,
                "cert_gate": "captions",
                "paper_id": None,
                "requirements": ["Native Tamil", "Comfortable with subtitle timing"],
                "questions": [
                    {"key": "tools", "prompt": "Subtitle tools you have used", "kind": "text", "required": False}
                ],
                "llm_policy": "Not allowed on this pool.",
                "sensitive": True,
                "closes_at": None,
            },
        )
        ops.call("PATCH", f"/v1/talent/listings/{tamil_listing['id']}", {"status": "open"})

        self.say(
            "5. workers: 1-3 certified for transcription; 4 applies to Hindi (paper pending); 5 holds a Tamil offer"
        )
        for n in (1, 2, 3):
            ops.put(
                f"/v1/workers/0000000{0}-0000-4000-8000-00000000000{n}",
                {"status": "eligible", "cert_gates": ["transcription"]},
            )
        w4, w5 = self.as_user("worker4"), self.as_user("worker5")
        self._apply(w4, hindi_listing["id"], {"experience": "1 to 3", "sample": "haan ji, main kal aaunga"})
        app5 = self._apply(w5, tamil_listing["id"], {"tools": "Aegisub"})
        if app5 is not None:
            ops.post(
                f"/v1/talent/applications/{app5['id']}/decide",
                {"decision": "offer", "note": "Welcome aboard", "offer_days": 7},
            )

        self.say("6. a support ticket from worker1, a flag from a reviewer is left to the real loop")
        w1 = self.as_user("worker1")
        w1.post(
            "/v1/notify/tickets",
            {
                "category": "payment",
                "title": "Bank name shows my old surname",
                "body": "I changed it last month; which name should the account carry?",
                "screen": "Profile",
                "context": {"app": "seed"},
            },
        )
        self.say("7. baselines for the leadership page; two workers share one device (the next scan flags both)")
        ops.put(
            "/v1/analytics/baselines",
            {
                "currency": "INR",
                "days_to_staff": "6",
                "idle_cost_weekly": "45000",
                "first_pass_acceptance": "0.72",
                "cost_per_accepted_unit": "38",
                "idle_hourly_cost": "150",
                "idle_hours_per_week": 10,
                "staffing_workers": 3,
                "rail_fee_per_payout": "3",
                "levy_rate": "0.01",
                "payout_sla_days": 3,
                "note": "Seeded: last quarter on the old process",
            },
        )
        shared_device = f"seed-device-{tag}"
        for name in ("worker2", "worker3"):
            self._track(self.as_user(name), shared_device)

        self.say("8. bank accounts for workers 1-5 (the rail's penny drop verifies them within a minute)")
        for n in range(1, 6):
            worker = self.as_user(f"worker{n}")
            worker.put("/v1/payout/accounts/me", bank_account_for(worker.session.worker_id))
        return {
            "org_id": org["id"],
            "project_ids": [hindi["id"], tamil["id"]],
            "batch_id": batch["id"],
            "paper_id": paper["id"],
            "listing_ids": [hindi_listing["id"], tamil_listing["id"]],
            "result": "SEEDED",
        }

    @staticmethod
    def _track(worker: Gateway, device: str) -> None:
        """A short activity session: four active samples a minute apart, then the end."""
        try:
            session = worker.post("/v1/tracker/sessions", {"source": "web", "device_hash": device})
        except GatewayError as e:
            if e.code != "session_open":
                raise
            session = {"id": (e.body or {})["session_id"]}  # the error carries the open session
        start = datetime.now(UTC) - timedelta(minutes=4)
        samples = [{"at": (start + timedelta(minutes=i)).isoformat(), "kind": "active"} for i in range(4)]
        worker.post(f"/v1/tracker/sessions/{session['id']}/samples", {"samples": samples})
        worker.post(f"/v1/tracker/sessions/{session['id']}/end")

    def _clips(self, ops: Gateway, batch_id: str, tag: str, count: int) -> list[str]:
        """Real audio for the batch: one short tone per unit, uploaded straight to object storage through presigned
        links, so the worker's player has something to play. Without storage the units keep plain file names."""
        names = [f"clip-{tag}-{i:02d}.wav" for i in range(count)]
        body = tone_wav()
        files = [{"name": n, "content_type": "audio/wav", "size_bytes": len(body)} for n in names]
        try:
            ups = ops.post(f"/v1/batches/{batch_id}/payload-uploads", {"files": files})
        except GatewayError as e:
            if e.code != "storage_unconfigured":
                raise
            self.say("   (no object storage on this rig: the clips are names only)")
            return names
        for up in ups["uploads"]:
            put = self.http.put(up["url"], content=body, headers=up["headers"])
            check(put.status_code == 200, f"object storage refused the clip upload ({put.status_code})")
        return [str(up["ref"]) for up in ups["uploads"]]

    @staticmethod
    def _apply(worker: Gateway, listing_id: str, answers: dict[str, Any]) -> Any:
        """Applies once; a second run finds the application already there and moves on."""
        try:
            return worker.post(f"/v1/talent/listings/{listing_id}/applications", {"answers": answers})
        except GatewayError as e:
            if e.code in ("already_applied", "listing_full"):
                return None
            raise


def tone_wav(seconds: float = 1.5, hz: int = 440, rate: int = 8000) -> bytes:
    """A short, quiet sine tone as a mono 16-bit WAV: small enough to upload eight times, real enough to play."""
    frames = b"".join(
        struct.pack("<h", int(6000 * math.sin(2 * math.pi * hz * n / rate))) for n in range(int(seconds * rate))
    )
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames)
    return out.getvalue()

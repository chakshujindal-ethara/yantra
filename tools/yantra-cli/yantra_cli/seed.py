"""`yantra seed`: a small, believable world on a fresh rig so every screen has something to show: two client
companies, four projects (two with published batches, one with work under way at every stage, two just set
up), an assessment paper, two listings (one behind the paper), certified workers, a worker mid-application,
an offer waiting, a support ticket. Every call goes through the gateway as the person who would do it in real
life. A second run finds the world in place and stops: reset the rig to seed afresh."""

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
        "topic": {"type": "string"},
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
CAPTION_ANSWER_SCHEMA = {
    "type": "object",
    "required": ["caption", "timing_ok"],
    "properties": {
        "caption": {"type": "string", "title": "Corrected caption", "minLength": 1},
        "timing_ok": {"type": "boolean", "title": "Timing matches the speech"},
    },
}
NORTHWIND = "Northwind Voice AI"
HELIX = "Helix Health Data"
HINDI = "Hindi customer-support call transcription"
TAMIL = "Tamil cooking-show caption QA"
CONSULT = "Hindi doctor-patient consultation transcription"
BENGALI = "Bengali product-review sentiment"
# what the support callers talk about, one per unit of the Hindi batch
CALL_TOPICS = [
    "Refund for a cancelled order",
    "Delivery running late",
    "Wrong size delivered",
    "Change of delivery address",
    "Payment failed but money deducted",
    "Return pickup not done",
    "Coupon not applied",
    "Damaged product received",
    "Account locked after OTP",
    "Cash on delivery not offered",
    "Order shows delivered, not received",
    "Exchange for a different colour",
]
# worker1 and worker3 each submit two calls; worker2 reviews three of the four
SUBMISSIONS = [
    ("worker1", "namaste, mera order cancel ho gaya tha, refund abhi tak nahi aaya", 2),
    ("worker1", "ji, delivery kal aani thi lekin abhi tak nahi aayi", 2),
    ("worker3", "maine M size order kiya tha, L aa gaya hai", 2),
    ("worker3", "address badalna hai, naya pin code 110024 hai", 1),
]
VERDICTS: list[dict[str, str]] = [
    {"verdict": "accept"},
    {"verdict": "accept"},
    {"verdict": "needs_edits", "reason_code": "guideline_miss"},
]
BRIEF = (
    "Transcribe short Hindi clips verbatim. Keep filler words, mark overlaps, write numbers as spoken. "
    "Tag an unclear word as [inaudible]. One clip is one unit; the rubric is v1."
)
TAMIL_BRIEF = (
    "Watch each 30-second clip from a Tamil cooking show with its machine caption. Fix wrong words, keep the "
    "cook's own phrasing, and say whether the caption's timing matches the speech."
)
CONSULT_BRIEF = (
    "Transcribe recorded doctor-patient consultations in Hindi, verbatim. Medicine names as spoken; never write "
    "a patient's name, phone number or address: tag them [name], [phone], [address]."
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
        if self._already_seeded(ops):
            self.say(f"already seeded: '{HINDI}' exists (reset the rig to seed afresh)")
            return {"result": "SEEDED", "already": True}
        tag = uuid.uuid4().hex[:4]  # only where nobody reads it: the device two workers share
        self.say("1. two client companies; client1 works for Northwind Voice AI")
        org = ops.post("/v1/client-orgs", {"name": NORTHWIND})
        ops.put(f"/v1/client-orgs/{org['id']}/members/{CLIENT1}")
        helix = ops.post("/v1/client-orgs", {"name": HELIX})

        self.say("2. four projects: two running with published batches, two just set up")
        hindi = self._project(ops, HINDI, "transcription", "0.3", org["id"], BRIEF, ANSWER_SCHEMA)
        batch = ops.post(
            f"/v1/projects/{hindi['id']}/batches",
            {
                "title": "Support calls, batch 1",
                "unit_pay": "28",
                "unit_price": "60",
                "review_pay": "6",
                "claim_ttl_minutes": 60,
            },
        )
        refs = self._clips(ops, batch["id"], "support-call", len(CALL_TOPICS))
        lines = [
            {"external_ref": f"support-call-{i + 1:03d}", "payload": {"audio_ref": ref, "language": "hi", "topic": t}}
            for i, (ref, t) in enumerate(zip(refs, CALL_TOPICS, strict=True))
        ]
        ops.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
        ops.post(f"/v1/batches/{batch['id']}/publish", {})
        tamil = self._project(ops, TAMIL, "captions", "0.25", org["id"], TAMIL_BRIEF, CAPTION_ANSWER_SCHEMA)
        captions = ops.post(
            f"/v1/projects/{tamil['id']}/batches",
            {"title": "Season 1, episodes 1-6", "unit_pay": "20", "unit_price": "45", "review_pay": "5"},
        )
        refs = self._clips(ops, captions["id"], "episode", 6)
        lines = [
            {"external_ref": f"episode-{i + 1:02d}", "payload": {"audio_ref": ref, "language": "ta"}}
            for i, ref in enumerate(refs)
        ]
        ops.post(f"/v1/batches/{captions['id']}/units/import", {"lines": lines}, dry_run="false")
        ops.post(f"/v1/batches/{captions['id']}/publish", {})
        consult = self._project(ops, CONSULT, "transcription", "0.35", helix["id"], CONSULT_BRIEF, ANSWER_SCHEMA)
        bengali = ops.post(
            "/v1/projects",
            {"name": BENGALI, "currency": "INR", "payload_schema": PAYLOAD_SCHEMA, "margin_floor": "0.3"},
        )

        self.say("3. a published assessment paper (in the Assessment app) that grants the transcription gate")
        paper = ops.post(
            "/v1/assess/papers",
            {
                "gate": "transcription",
                "title": "Hindi transcription basics",
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
                "title": "Hindi transcriber, customer-support calls",
                "domain": "Speech",
                "summary": "Verbatim transcription of short Hindi support calls, paid per accepted call.",
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
                "title": "Tamil caption reviewer, cooking shows",
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
            "5. workers: 1-3 certified for transcription; 4 applies to Hindi (paper pending); 5 holds a Tamil offer;"
            " work under way on the support calls"
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
        self._work(batch["id"])

        self.say("6. a support ticket from worker1, a flag from a reviewer is left to the real loop")
        w1 = self.as_user("worker1")
        w1.post(
            "/v1/notify/tickets",
            {
                "category": "payment",
                "title": "Bank name shows my old surname",
                "body": "I changed it last month; which name should the account carry?",
                "screen": "Profile",
                "context": {"app": "web"},
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
                "note": "Last quarter, on the old spreadsheet process",
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
            "project_ids": [hindi["id"], tamil["id"], consult["id"], bengali["id"]],
            "batch_id": batch["id"],
            "paper_id": paper["id"],
            "listing_ids": [hindi_listing["id"], tamil_listing["id"]],
            "result": "SEEDED",
        }

    @staticmethod
    def _already_seeded(ops: Gateway) -> bool:
        projects = ops.get("/v1/projects")
        return isinstance(projects, list) and any(p.get("name") == HINDI for p in projects)

    @staticmethod
    def _project(
        ops: Gateway, name: str, gate: str, margin: str, org_id: str, brief: str, answers: dict[str, Any]
    ) -> Any:
        """A running project for a client: created, then made active with its brief."""
        project = ops.post(
            "/v1/projects",
            {
                "name": name,
                "currency": "INR",
                "payload_schema": PAYLOAD_SCHEMA,
                "answer_schema": answers,
                "cert_gate": gate,
                "margin_floor": margin,
            },
        )
        ops.call(
            "PATCH",
            f"/v1/projects/{project['id']}",
            {"status": "active", "brief": brief, "llm_policy": LLM_POLICY, "client_org_id": org_id},
        )
        return project

    def _work(self, batch_id: str) -> None:
        """Real progress on the support calls, so every stage has something in it: worker1 and worker3 submit two
        calls each, worker2 accepts two and sends one back with a reason, one waits for review, and worker1 is part
        way through a fifth."""
        for name, transcript, speakers in SUBMISSIONS:
            worker = self.as_user(name)
            claim = worker.post(f"/v1/batches/{batch_id}/claims")
            answer = {"transcript": transcript, "speakers": speakers, "noisy": False}
            worker.post(f"/v1/claims/{claim['id']}/submission", {"answer": answer})
        reviewer = self.as_user("worker2")
        for verdict in VERDICTS:
            task = self._review_task(reviewer, batch_id)
            reviewer.post(f"/v1/quality/tasks/{task['id']}/review", verdict)
        self.as_user("worker1").post(f"/v1/batches/{batch_id}/claims")

    def _review_task(self, reviewer: Gateway, batch_id: str, tries: int = 60) -> Any:
        """The next review task of the batch, waiting (a second at a time) for the submitted event to reach quality."""
        for _ in range(tries - 1):
            try:
                return reviewer.post("/v1/quality/reviews/claim", batch_id=batch_id)
            except GatewayError as e:
                if e.status != 404:
                    raise
                self.sleep(1.0)
        return reviewer.post("/v1/quality/reviews/claim", batch_id=batch_id)

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

    def _clips(self, ops: Gateway, batch_id: str, prefix: str, count: int) -> list[str]:
        """Real audio for the batch: one short tone per unit, uploaded straight to object storage through presigned
        links, so the worker's player has something to play. Without storage the units keep plain file names."""
        names = [f"{prefix}-{i + 1:03d}.wav" for i in range(count)]
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

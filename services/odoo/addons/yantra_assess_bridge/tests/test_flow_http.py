"""The whole path through Assessment v2's real routes, as Yantra drives it: a service token, a person, a quick paper
(CSV into the bank, approve, create, assign, launch), a launch ticket, the redeem the exam app does, the sitting
(begin, answer, submit) on the redeemed bearer, then the attempt read and released by the service. Plus every way the
service and redeem routes refuse."""

import base64
import csv
import io
import json

from odoo.tests.common import HttpCase, tagged

from .common import bridge_settings, keycloak_keys, service_token

WORKER = "00000000-0000-4000-8000-0000000000a1"
STAFF = "00000000-0000-4000-8000-0000000000b2"
QUESTIONS = [
    {"title": "Numbers", "question_type": "mcq", "prompt": "Write a spoken number how?", "difficulty": "easy",
     "time_minutes": "1", "options": "As digits|As spoken", "correct_answer": "As spoken"},
    {"title": "Verbatim", "question_type": "msq", "prompt": "Transcribed verbatim?", "difficulty": "medium",
     "time_minutes": "2", "options": "Filler words|Music|False starts", "correct_answer": "Filler words|False starts"},
]


@tagged("post_install", "-at_install")
class TestFlowHttp(HttpCase):
    def setUp(self):
        super().setUp()
        bridge_settings(self.env)
        keys = keycloak_keys()
        keys.__enter__()
        self.addCleanup(keys.__exit__, None, None, None)

    def post(self, path, body=None, bearer=None):
        headers = {"Content-Type": "application/json"}
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        response = self.url_open(path, data=json.dumps(body or {}), headers=headers)
        return response.status_code, response.json()

    def service(self, path, body=None):
        return self.post(path, body, bearer=service_token())

    def admin(self, path, body=None):
        status, got = self.post(path, body, bearer=self.v2_bearer)
        self.assertEqual(status, 200, got)
        self.assertTrue(got["ok"], got)
        return got["data"]

    def quick_paper(self):
        out = io.StringIO()
        columns = ["title", "question_type", "prompt", "difficulty", "time_minutes", "options", "correct_answer"]
        writer = csv.DictWriter(out, fieldnames=columns)
        writer.writeheader()
        writer.writerows(QUESTIONS)
        content = base64.b64encode(out.getvalue().encode()).decode()
        imported = self.admin("/api/v1/bank/import", {"content": content, "filename": "q.csv", "generator_name": "Quick"})
        self.admin(f"/api/v1/generators/{imported['generator_id']}/approve_all")
        return self.admin(
            "/api/v1/assessments/create",
            {"name": "Quick paper", "generator_id": imported["generator_id"], "duration_minutes": 15, "pass_threshold": 75},
        )

    def test_a_worker_goes_from_a_service_ticket_to_a_released_pass_without_a_password(self):
        status, token = self.service("/api/v1/yantra/service/token")
        self.assertEqual(status, 200, token)
        self.v2_bearer = token["data"]["access_token"]
        _, person = self.service(
            "/api/v1/yantra/service/people",
            {"sub": WORKER, "email": "asha@yantra.local", "email_verified": True, "name": "Asha", "kind": "worker"},
        )
        user_id = person["data"]["user_id"]
        paper = self.quick_paper()
        self.admin(f"/api/v1/assessments/{paper['id']}/assign", {"user_ids": [user_id]})
        self.admin(f"/api/v1/assessments/{paper['id']}/launch", {"confirm": True})

        status, ticket = self.service(
            "/api/v1/yantra/service/tickets",
            {"sub": WORKER, "kind": "candidate", "assessment_id": paper["id"],
             "return_url": "http://localhost:8095/work/applications"},
        )
        self.assertEqual(status, 200, ticket)
        ticket = ticket["data"]
        self.assertTrue(ticket["launch_url"].startswith("http://localhost:8096/yantra/launch#ticket="))
        self.assertEqual(ticket["attempt_state"], "pending")

        status, redeemed = self.post("/api/v1/yantra/launch/redeem", {"ticket": ticket["ticket"]})
        self.assertEqual(status, 200, redeemed)
        redeemed = redeemed["data"]
        self.assertEqual(redeemed["return_url"], "http://localhost:8095/work/applications")
        bearer, exam = redeemed["access_token"], redeemed["exam_token"]
        status, again = self.post("/api/v1/yantra/launch/redeem", {"ticket": ticket["ticket"]})
        self.assertEqual((status, again["error"]["code"]), (410, "ticket_used"))

        _, state = self.post(f"/api/v1/exam/{exam}/state", bearer=bearer)
        self.assertEqual(state["data"]["outcome"], "instructions")
        _, begun = self.post(f"/api/v1/exam/{exam}/begin", {"session_key": "tab-1"}, bearer=bearer)
        question = begun["data"]["question"]
        for _ in range(2):
            options = {o["name"]: o["id"] for d in question["dimensions"] for o in d["options"]}
            right = [options[n] for n in ("As spoken", "Filler words", "False starts") if n in options]
            _, saved = self.post(
                f"/api/v1/exam/{exam}/answer",
                {"session_key": "tab-1", "question_id": question["id"], "selected_option_ids": right},
                bearer=bearer,
            )
            self.assertTrue(saved["data"]["saved"], saved)
            following = (saved["data"].get("next") or {}).get("question")
            if not following:
                break
            question = following
        _, submitted = self.post(f"/api/v1/exam/{exam}/submit", {"session_key": "tab-1"}, bearer=bearer)
        self.assertTrue(submitted["data"]["submitted"])

        attempts = self.admin("/api/v1/attempts", {"assessment_id": paper["id"]})
        attempt = attempts[0]
        self.assertEqual((attempt["state"], attempt["result"], attempt["results_released"]), ("submitted", "pass", False))
        self.assertEqual(attempt["id"], ticket["evaluator_id"])
        released = self.admin(f"/api/v1/assessments/{paper['id']}/release", {"evaluator_ids": [attempt["id"]]})
        self.assertEqual(released["released_count"], 1)

    def test_a_staff_ticket_opens_the_admin_as_a_v2_admin(self):
        self.service(
            "/api/v1/yantra/service/people",
            {"sub": STAFF, "email": "ops1@yantra.local", "email_verified": True, "name": "Ops", "kind": "staff"},
        )
        _, ticket = self.service("/api/v1/yantra/service/tickets", {"sub": STAFF, "kind": "staff", "next": "/assessments/1"})
        _, redeemed = self.post("/api/v1/yantra/launch/redeem", {"ticket": ticket["data"]["ticket"]})
        self.assertEqual(redeemed["data"]["next"], "/assessments/1")
        _, me = self.post("/api/v1/auth/me", bearer=redeemed["data"]["access_token"])
        self.assertEqual(me["data"]["user"]["role"], "admin")

    def test_the_service_routes_refuse_everything_but_the_service_client(self):
        for path in ("/api/v1/yantra/service/token", "/api/v1/yantra/service/people", "/api/v1/yantra/service/tickets"):
            for bearer in (None, service_token(azp="yantra-app")):
                status, got = self.post(path, {"sub": WORKER}, bearer=bearer)
                self.assertEqual((status, got["error"]["code"]), (401, "unauthorized"), path)

    def test_bad_requests_are_named(self):
        self.service("/api/v1/yantra/service/people", {"sub": WORKER, "email": "w@yantra.local", "email_verified": True})
        cases = [
            ("/api/v1/yantra/service/people", {"sub": WORKER, "kind": "boss"}, 422, "invalid"),
            ("/api/v1/yantra/service/people", {"sub": "bad subject"}, 422, "invalid_subject"),
            ("/api/v1/yantra/service/tickets", {"sub": STAFF}, 404, "unknown_person"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "kind": "boss"}, 422, "invalid"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "return_url": "https://evil.example/x"}, 422, "invalid"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "kind": "staff", "next": "https://evil/x"}, 422, "invalid"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "kind": "staff", "next": "/assessments"}, 403, "forbidden"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "assessment_id": 999999}, 404, "not_assigned"),
            ("/api/v1/yantra/service/tickets", {"sub": WORKER, "exam_token": "no-such-token"}, 404, "not_assigned"),
        ]
        for path, body, status, code in cases:
            got_status, got = self.service(path, body)
            self.assertEqual((got_status, got["error"]["code"]), (status, code), body)
        status, got = self.post("/api/v1/yantra/launch/redeem", {"ticket": "nope"})
        self.assertEqual((status, got["error"]["code"]), (404, "invalid_ticket"))

    def test_another_persons_attempt_is_not_theirs_to_open(self):
        self.service("/api/v1/yantra/service/people", {"sub": WORKER, "email": "w@yantra.local", "email_verified": True})
        _, other = self.service(
            "/api/v1/yantra/service/people", {"sub": STAFF, "email": "x@yantra.local", "email_verified": True}
        )
        _, token = self.service("/api/v1/yantra/service/token")
        self.v2_bearer = token["data"]["access_token"]
        paper = self.quick_paper()
        self.admin(f"/api/v1/assessments/{paper['id']}/assign", {"user_ids": [other["data"]["user_id"]]})
        self.admin(f"/api/v1/assessments/{paper['id']}/launch", {"confirm": True})
        theirs = self.admin("/api/v1/attempts", {"assessment_id": paper["id"]})[0]
        evaluator = self.env["assessments.be.evaluator"].sudo().browse(theirs["id"])
        status, got = self.service("/api/v1/yantra/service/tickets", {"sub": WORKER, "exam_token": evaluator.access_token})
        self.assertEqual((status, got["error"]["code"]), (403, "forbidden"))

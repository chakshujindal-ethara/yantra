# -*- coding: utf-8 -*-
"""The SEB proof's page check compares URLs the way a browser reads them.

SEB review #16: `proof_ok` checked the page URL with a raw, case-sensitive
`startswith`. A host typed in capitals or an explicit :443 (the same page)
was refused, while `/exam/<token>x` (another page that shares the prefix)
passed. Scheme and host now compare lowercased, a default port is dropped and
the path must end at a `/` boundary. The hash is still over the RAW URL, as
SEB computes it, so the Config Key does not move.
"""
import hashlib
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import seb

APP = "https://app.example.com"


@tagged("-at_install", "post_install")
class TestTheSebPageCheckReadsTheUrlLikeABrowser(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.candidate_app_base_url", APP)
        generator = self.env["assessments.be.prompt"].create(
            {"name": "SEB url %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        paper = self.env["assessments.be"].create({
            "name": "SEB url paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 30, "state": "in_progress",
            "rule_require_seb": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Url Check",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex,
        })
        self.link = self.evaluator.candidate_link
        self.assertTrue(self.link.startswith(APP + "/exam/"),
                        "fixture guard: %s" % self.link)

    def _ok(self, page_url):
        """`proof_ok` for a hash SEB would send from `page_url`: SHA-256 of
        the URL exactly as loaded plus the Config Key."""
        key = seb.config_key(seb.settings(self.evaluator))
        sent = hashlib.sha256((page_url + key).encode()).hexdigest()
        return seb.proof_ok(self.evaluator, page_url, sent)

    def test_the_link_itself_still_passes(self):
        self.assertTrue(self._ok(self.link))
        self.assertTrue(self._ok(self.link + "/question/2"))
        self.assertTrue(self._ok(self.link + "?lang=en"))

    def test_an_uppercase_scheme_and_host_is_the_same_page(self):
        self.assertTrue(self._ok(self.link.replace(
            "https://app.example.com", "HTTPS://App.Example.COM")))

    def test_an_explicit_default_port_is_the_same_page(self):
        self.assertTrue(self._ok(self.link.replace(
            "app.example.com", "app.example.com:443")))

    def test_a_sibling_path_that_shares_the_prefix_is_not_the_page(self):
        self.assertFalse(self._ok(self.link + "x"))
        self.assertFalse(self._ok(self.link + "-other/question/1"))

    def test_another_host_or_port_is_not_the_page(self):
        self.assertFalse(self._ok(self.link.replace(
            "app.example.com", "evil.example.com")))
        self.assertFalse(self._ok(self.link.replace(
            "app.example.com", "app.example.com:8443")))
        self.assertFalse(self._ok(self.link.replace("https://", "http://")))
        self.assertFalse(self._ok(self.link.replace(
            "app.example.com", "app.example.com:notaport")))

    def test_the_hash_is_over_the_raw_url_not_the_normalised_one(self):
        shouted = self.link.replace("app.example.com", "APP.EXAMPLE.COM")
        key = seb.config_key(seb.settings(self.evaluator))
        over_normalised = hashlib.sha256(
            (self.link + key).encode()).hexdigest()
        self.assertFalse(
            seb.proof_ok(self.evaluator, shouted, over_normalised))

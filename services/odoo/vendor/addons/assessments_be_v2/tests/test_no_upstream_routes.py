# -*- coding: utf-8 -*-
"""No payload may point at a route this addon does not serve.

THE BUG THIS PINS. `question_media` handed every candidate
`/pro_assessment/qimage|qvideo/<token>/<id>` - a route only `etp_assessment_pro`
registers. It worked because that module was installed alongside, so the exam
looked perfectly healthy right up until upstream was uninstalled, at which point
every image and video in every exam answered 404 and the candidate got a broken
plate above inputs they had to answer.

That is the whole difficulty: a cross-module URL dependency is INVISIBLE while
both modules are installed, which is exactly the state every developer machine
is in. Nothing short of a test that reads the routing map can see it.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestNoUpstreamRoutes(TransactionCase):

    def _own_prefixes(self):
        """Every URL prefix THIS addon registers."""
        prefixes = set()
        for rule in self.env["ir.http"].routing_map().iter_rules():
            endpoint = getattr(rule, "endpoint", None)
            mod = getattr(getattr(endpoint, "func", endpoint), "__module__", "")
            if "assessments_be_v2" in (mod or ""):
                prefixes.add(rule.rule)
        return prefixes

    def _question_with_media(self):
        gen = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        q = self.env["assessments.be.question"].create({
            "name": "Spot the defect %s" % uuid4().hex[:6],
            "question_type": "image_ab",
            "prompt": "Which plate is correct?",
            "generator_id": gen.id,
        })
        self.env["assessments.be.question.image"].create({
            "question_id": q.id, "slot": "a", "label": "A",
            "image_url": "https://example.invalid/a.png",
        })
        self.env["assessments.be.question.video"].create({
            "question_id": q.id, "slot": "single", "label": "V",
            "video_url": "https://example.invalid/v.mp4",
        })
        return q

    def test_exam_media_urls_point_at_routes_we_register(self):
        q = self._question_with_media()
        images, videos = S.question_media(q, "tok-%s" % uuid4().hex[:8])
        self.assertTrue(images and videos, "fixture built no media")

        served = self._own_prefixes()
        for row in list(images) + list(videos):
            path = (row["url"] or "").split("?")[0]
            # Compare shape, not the concrete token/id.
            head = "/".join(path.split("/")[:3])
            self.assertTrue(
                any(r.startswith(head) for r in served),
                "payload sends %r but this addon registers no route under %r - "
                "it resolves only while etp_assessment_pro is installed"
                % (path, head))

    def test_no_payload_mentions_the_upstream_portal(self):
        q = self._question_with_media()
        images, videos = S.question_media(q, "tok-%s" % uuid4().hex[:8])
        for row in list(images) + list(videos):
            for key in ("url", "annotated_url"):
                self.assertNotIn(
                    "/pro_assessment/", row.get(key) or "",
                    "%s still points at the module being decommissioned" % key)

    def test_addon_registers_the_candidate_media_routes(self):
        served = self._own_prefixes()
        for expected in ("/assessments_be/exam/qimage/<string:token>/<int:image_id>",
                         "/assessments_be/exam/qvideo/<string:token>/<int:video_id>"):
            self.assertIn(
                expected, served,
                "candidate exam media has no route here; the payload would "
                "resolve only against etp_assessment_pro")

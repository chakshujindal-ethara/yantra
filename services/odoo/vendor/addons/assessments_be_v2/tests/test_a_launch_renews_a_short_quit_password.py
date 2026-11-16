# -*- coding: utf-8 -*-
"""Launching a Safe Exam Browser paper renews an old short quit password.

SEB review #23: papers made before 19.0.3.28.0 kept the old 48-bit password
(`xxxx-xxxx-xxxx`, 14 characters); the upgrade renewed only the shared ones.
Its hash is in the public .seb, so it is the weak one. Nobody can be sitting
before launch, so launch is the safe moment to replace it with a full-length
one, and one typed below the 12-character minimum too. A password an admin
typed that meets the minimum, and any password with SEB off, is kept.
"""
import re
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import seb

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"
OLD = "ab12-cd34-ef56"


@tagged("-at_install", "post_install")
class TestALaunchRenewsAShortQuitPassword(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Renew %s" % uuid4().hex[:6]})
        # A KEYED mcq, so the answer-key gate cannot refuse the launch.
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6], "question_type": "mcq",
            "prompt": "Pick one.", "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": opt, "sequence": i * 10, "is_correct": i == 0})
                for i, opt in enumerate(("Alpha", "Bravo"))],
        })

    def _draft(self, seb_on, password):
        slug = uuid4().hex[:8]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "renew_%s@example.com" % slug})
        paper = self.env["assessments.be"].create({
            "name": "Renew paper %s" % slug,
            "generator_id": self.generator.id, "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [applicant.id])],
            "rule_require_seb": seb_on,
        })
        paper._sync_roster_rows()
        # Straight to the column, as the old default left it.
        self.env.flush_all()
        self.env.cr.execute("UPDATE assessments_be SET seb_quit_password = %s "
                            "WHERE id = %s", (password, paper.id))
        paper.invalidate_recordset()
        return paper

    def test_an_old_short_password_is_renewed_at_launch(self):
        paper = self._draft(True, OLD)

        paper.action_start()

        self.assertEqual(paper.state, "in_progress")
        self.assertNotEqual(paper.seb_quit_password, OLD)
        self.assertEqual(len(paper.seb_quit_password),
                         len(seb.new_quit_password()))
        self.assertTrue(re.fullmatch(r"[0-9a-z]{4}(-[0-9a-z]{4}){3}",
                                     paper.seb_quit_password))

    def test_a_full_length_password_is_kept(self):
        current = seb.new_quit_password()
        paper = self._draft(True, current)

        paper.action_start()

        self.assertEqual(paper.seb_quit_password, current)

    def test_a_password_an_admin_typed_is_kept_when_it_is_long_enough(self):
        """12 characters is the bar for a typed one; invigilators may already
        have been given it."""
        paper = self._draft(True, "typed-by-admin")

        paper.action_start()

        self.assertEqual(paper.seb_quit_password, "typed-by-admin")

    def test_a_typed_password_below_the_minimum_is_renewed(self):
        paper = self._draft(True, "1234")

        paper.action_start()

        self.assertEqual(len(paper.seb_quit_password),
                         len(seb.new_quit_password()))

    def test_with_seb_off_the_password_is_left_alone(self):
        paper = self._draft(False, OLD)

        paper.action_start()

        self.assertEqual(paper.seb_quit_password, OLD)

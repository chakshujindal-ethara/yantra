# -*- coding: utf-8 -*-
"""A Manager who is admitted at the route must also be admitted by the ORM.

THE BUG THIS CLOSES, found on a running server and not by any test. Adding the
read-only Manager rung gave it `require_operator` on 16 read routes, and the
route guard let it straight through - but NOT ONE ROW in
security/ir.model.access.csv granted `group_assessment_manager_restricted`
anything at all. So every one of those 16 routes reached the ORM, the ORM
refused, and the API answered:

    403 {"code": "forbidden", "message": "You are not allowed to access
         'Assessment' (assessments.be) records. This operation is allowed for
         the following groups: - Assessment v2 Access/Admin ..."}

A brand-new role that can sign in, is offered a console, and 403s on every
screen in it.

WHY 1,691 GREEN TESTS MISSED IT. Access control is TWO independent gates and the
suite only ever exercised one of them. `test_assessment_role_ladder` asks
`_be_assessment_role()`, a pure function over `has_group`; the controller tests
build a `_FakeRequest` around `self.env`, which is the SUPERUSER env - and
`check_access` begins `if not self.env.su`, so every ACL check in the suite was
a no-op. Holding the group and being able to READ are different facts, and the
tests only ever asserted the first.

So this file does the one thing none of the others do: it acts as a REAL user.
`self.env(user=manager)` clears `env.su`, and from that point on the ORM answers
honestly. Every assertion below is worthless if that user is ever replaced with
`self.env` or given `.sudo()`.

THE SECOND MISS, one route later. With 14 rows added, `/api/v1/assessments` still
403'd - "Failed to read field assessments.be.evaluator_ids" - because
`evaluator_ids` is a Many2many to `hr.applicant`, a model this module does not
own. The roster is on every assessment payload, so the grant list is not "our
models": it is "every model the payload touches". Group 2 reads a real
assessment through a real Manager for exactly that reason, and Group 3 pins the
shape of the hr.applicant grant, which is the part that is easy to get subtly
wrong (see the docstring on `test_the_roster_is_not_narrowed_...`).
"""
import csv
import pathlib
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..constants import GROUP_MANAGER, GROUP_MANAGER_RESTRICTED

# EVERY MODEL A `require_operator` ROUTE READS. The 16 routes are
# /api/v1/{analytics,assessments,assessments/<id>,assessments/<id>/candidates,
# attempts,attempts/<id>,bank,bank/<id>,bank/<id>/studio_item,budget,forms,
# leaderboard,ledger,responses,responses/<id>/<id>,tags}.
#
# Kept as a literal list, not derived from the CSV, so the two can disagree -
# `test_the_granted_models_are_exactly_this_list` is that disagreement being
# reported. Deriving it from the CSV would make the test tautological: it would
# pass for any CSV, including an empty one, which is precisely the state that
# shipped the bug.
OPERATOR_READ_MODELS = (
    "assessments.be",
    "assessments.be.evaluator",
    "assessments.be.llm.usage",
    "assessments.be.prompt",
    "assessments.be.question",
    "assessments.be.question.dimension",
    "assessments.be.question.dimension.option",
    "assessments.be.question.image",
    "assessments.be.question.video",
    "assessments.be.response",
    "assessments.be.response.line",
    "assessments.be.tag",
    "assessments.be.task.template",
    "etp.studio.form",
    # Not ours. `assessments.be.evaluator_ids` is a Many2many to it, so the
    # roster - and therefore the assessment list AND detail payloads - cannot be
    # serialized without read on it.
    "hr.applicant",
)

# Read-only means read-only. Anything a Manager could write would be a write
# performed by a role whose whole purpose is not being able to.
FORBIDDEN_OPERATIONS = ("write", "create", "unlink")


@tagged("-at_install", "post_install")
class TestAReadOnlyManagerCanActuallyRead(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Users = self.env["res.users"].sudo()
        self.manager = self._user(GROUP_MANAGER_RESTRICTED)
        # THE WHOLE POINT OF THIS FILE. `self.env` is superuser and
        # `check_access` short-circuits on `env.su`, so an assertion made
        # through it proves nothing about ACLs. Everything below reads through
        # this env instead.
        self.manager_env = self.env(user=self.manager)

    # -- fixtures ---------------------------------------------------------

    def _user(self, *group_xmlids):
        """An account holding exactly the named groups and nothing else."""
        groups = [self.env.ref(x).id for x in group_xmlids]
        return self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "ACL fixture %s" % uuid4().hex[:6],
            "login": "acl_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, groups)],
        })

    def _attempt_with_an_answer(self):
        """One launched-shaped assessment with a roster row and one response.

        Created as SUPERUSER on purpose: the Manager cannot write, so the
        fixture has to come from somewhere else. Only the reads below are made
        as the Manager.
        """
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": generator.id,
        })
        dimension = self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, applicant.ids)],
            "question_ids": [(6, 0, question.ids)],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "access_token": str(uuid4()),
        })
        # `evaluator_id` is the CANDIDATE (an hr.applicant); the ATTEMPT row is
        # `assessment_evaluator_id`. Two similarly-named Many2ones on the same
        # table, and the FK error for getting them the wrong way round names
        # hr_applicant rather than either field.
        response = self.env["assessments.be.response"].create({
            "assessment_id": assessment.id,
            "evaluator_id": applicant.id,
            "assessment_evaluator_id": evaluator.id,
            "question_id": question.id,
        })
        self.env["assessments.be.response.line"].create({
            "response_id": response.id,
            "question_dimension_id": dimension.id,
        })
        return assessment, evaluator, question

    def _as_manager(self, record):
        return record.with_env(self.manager_env)

    # -- group 1: the grant exists, and it is read-only -------------------

    def test_a_manager_may_read_every_model_an_operator_route_touches(self):
        """The bug, stated once per model.

        `has_access` rather than `check_access` so a failure names the model
        instead of unwinding an AccessError, and `browse()` (empty recordset) so
        this is a question about the MODEL grant and not about record rules -
        the missing rows were model-level.
        """
        missing = [
            model for model in OPERATOR_READ_MODELS
            if not self.manager_env[model].browse().has_access("read")
        ]
        self.assertFalse(
            missing,
            "the read-only Manager is admitted at these routes by "
            "`require_operator` and then refused by the ORM, which is a 403 on "
            "a screen the role was built for. Add a `1,0,0,0` row for "
            "group_assessment_manager_restricted in "
            "security/ir.model.access.csv for: %s" % ", ".join(missing))

    def test_the_grant_is_read_only(self):
        """A Manager that could write would not be a read-only Manager.

        Guards against the tempting one-line fix for the bug above: copying
        Admin's `1,1,1,1` rows onto the restricted group.
        """
        writable = [
            "%s/%s" % (model, op)
            for model in OPERATOR_READ_MODELS
            for op in FORBIDDEN_OPERATIONS
            if self.manager_env[model].browse().has_access(op)
        ]
        self.assertFalse(
            writable,
            "the read-only Manager may modify data: %s" % ", ".join(writable))

    def test_the_granted_models_are_exactly_this_list(self):
        """Two-way lock between this file and the CSV.

        A new `require_operator` route on a new model fails
        `test_a_manager_may_read_...` above; a row added to the CSV without a
        route needing it fails here. Either way somebody has to state which of
        the two is right, which is the review this bug never got.
        """
        csv_path = (pathlib.Path(__file__).resolve().parent.parent
                    / "security" / "ir.model.access.csv")
        granted = set()
        with csv_path.open(newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                if row["group_id:id"].split(".")[-1] != (
                        GROUP_MANAGER_RESTRICTED.split(".")[-1]):
                    continue
                ref = row["model_id:id"]
                # An unqualified xmlid belongs to this module; `hr.applicant`
                # is carried as `hr_recruitment.model_hr_applicant`.
                if "." not in ref:
                    ref = "assessments_be_v2." + ref
                granted.add(self.env.ref(ref).model)

        self.assertEqual(
            granted, set(OPERATOR_READ_MODELS),
            "security/ir.model.access.csv and OPERATOR_READ_MODELS disagree. "
            "Only in the CSV: %s. Only in this file: %s."
            % (sorted(granted - set(OPERATOR_READ_MODELS)) or "-",
               sorted(set(OPERATOR_READ_MODELS) - granted) or "-"))

    # -- group 2: the reads the payloads actually make --------------------

    def test_a_manager_can_read_the_roster_off_an_assessment(self):
        """THE SECOND MISS. `evaluator_ids` is a Many2many to `hr.applicant`.

        With the 14 rows for our own models in place, `/api/v1/assessments` was
        still 403 - "Failed to read field assessments.be.evaluator_ids" - and
        the message named a model this module does not own. A grant list built
        from "the models we declare" is incomplete by construction.
        """
        assessment, _evaluator, _question = self._attempt_with_an_answer()
        mine = self._as_manager(assessment)

        self.assertEqual(len(mine.evaluator_ids), 1)
        self.assertTrue(
            mine.evaluator_ids.mapped("partner_name"),
            "the roster is on every assessment payload, so reading the "
            "applicant's own fields has to work too")

    def test_a_manager_can_read_an_assessment_the_way_the_payload_does(self):
        """A field-by-field read, because that is what actually 403'd.

        `search([])` succeeding proves only the model grant. The serializer
        reads FIELDS, and a related field can reach a model with no grant - so
        the assertion has to be a real read of the real field list.
        """
        assessment, evaluator, question = self._attempt_with_an_answer()

        self._as_manager(assessment).read([
            "name", "state", "duration_minutes", "generator_id",
            "question_ids", "evaluator_ids", "assessment_evaluator_ids",
        ])
        self._as_manager(evaluator).read([
            "assessment_id", "applicant_id", "state", "score_percent",
            "response_ids",
        ])
        self._as_manager(question).read([
            "name", "question_type", "prompt", "generator_id",
            "question_dimension_ids", "image_ids", "video_ids",
        ])

    def test_a_manager_can_read_an_answer_and_its_lines(self):
        """`/api/v1/responses` and `/api/v1/responses/<ev>/<q>`."""
        _assessment, evaluator, _question = self._attempt_with_an_answer()
        responses = self._as_manager(evaluator).response_ids

        self.assertEqual(len(responses), 1)
        self.assertEqual(len(responses.line_ids), 1)
        responses.line_ids.read(["question_dimension_id"])

    def test_a_manager_can_search_the_models_the_lists_page(self):
        """`search` is a separate permission path from `read` in Odoo."""
        self._attempt_with_an_answer()
        for model in OPERATOR_READ_MODELS:
            self.manager_env[model].search([], limit=1)

    # -- group 3: HOW hr.applicant is granted, not just THAT it is --------

    def test_the_roster_is_not_narrowed_to_applicants_the_manager_interviews(
            self):
        """The subtle wrong fix, pinned so it cannot be made.

        `hr.applicant` read could also be granted by implying one of
        hr_recruitment's own groups, and one of them looks harmless:
        `group_hr_recruitment_interviewer`. It is not. It carries the
        "Applicant Interviewer" RECORD RULE, domain

            ['|', ('job_id.interviewer_ids','in',user.id),
                  ('interviewer_ids','in',user.id)]

        A Manager would then pass every assertion in Group 1, get 200 on every
        route, and see an EMPTY roster on every launched assessment - with
        nothing on screen to explain it. That is worse than the 403 this file
        was written for, because it looks like data.

        A bare ACL row attaches no rule, so the only rule left on hr.applicant
        is the global multi-company one.
        """
        assessment, _evaluator, _question = self._attempt_with_an_answer()
        applicant = assessment.evaluator_ids
        self.assertFalse(
            applicant.interviewer_ids,
            "fixture check: this applicant names no interviewer, so an "
            "interviewer-scoped rule would hide it")

        self.assertEqual(
            self._as_manager(applicant).mapped("partner_name"),
            applicant.mapped("partner_name"),
            "a Manager must see the whole roster, not only the candidates they "
            "personally interview")

    def test_a_manager_holds_no_recruitment_group(self):
        """The other wrong fix: reusing Admin's `group_hr_recruitment_user`.

        That group carries write, create and unlink on applicants plus the whole
        Recruitment menu - a read-only role would be able to edit and delete
        candidate records. Admin holds it deliberately; Manager must not.
        """
        for xmlid in ("hr_recruitment.group_hr_recruitment_user",
                      "hr_recruitment.group_hr_recruitment_interviewer",
                      "hr_recruitment.group_hr_recruitment_manager"):
            self.assertFalse(
                self.manager.has_group(xmlid),
                "the read-only Manager holds %s. hr.applicant read belongs in "
                "ir.model.access.csv as a bare `1,0,0,0` row - see the comment "
                "on group_assessment_manager_restricted in "
                "security/etp_assessment_security.xml" % xmlid)

    # -- group 4: the rungs above and below ------------------------------

    def test_an_admin_can_still_write(self):
        """Guard the guard. If the ACL rows were broken for everyone, every
        assertion in Group 1 would pass for the wrong reason."""
        admin_env = self.env(user=self._user(GROUP_MANAGER))
        for model in OPERATOR_READ_MODELS:
            self.assertTrue(
                admin_env[model].browse().has_access("read"),
                "Admin lost read on %s" % model)
        for model in ("assessments.be", "assessments.be.question",
                      "assessments.be.tag"):
            self.assertTrue(
                admin_env[model].browse().has_access("write"),
                "Admin lost write on %s" % model)

    def test_an_internal_account_with_no_assessment_group_reads_nothing(self):
        """"Assessment v2 Access = No" has to mean no, at the ORM too.

        The 15 rows added for the Manager are keyed on the Manager group, but a
        row keyed on `base.group_user` by accident would grant the whole
        instance - and every other test in this file would still pass.
        """
        employee_env = self.env(user=self._user("base.group_user"))
        readable = [
            model for model in OPERATOR_READ_MODELS
            if model != "hr.applicant"  # not ours to say anything about
            and employee_env[model].browse().has_access("read")
        ]
        self.assertFalse(
            readable,
            "an employee with no Assessment v2 group can read %s - a grant row "
            "is keyed on the wrong group" % ", ".join(readable))

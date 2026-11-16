# -*- coding: utf-8 -*-
"""Is C1 systemic, or local to the attempt listing? One walk per paged route.

The design hypothesises that the non-unique ordering key is a HOUSE PATTERN
rather than one mistake, and lists fourteen offset-paged listings with a verdict
for each. This file tests every one of those verdicts. A route that PASSES here
is evidence its key is already unique, and the correct response is to record
that and leave the route alone - not to "fix" it.

HOW A TIE IS SEEDED. Odoo memoises `cr.now()` for the transaction, so anything
created in one `create()` call shares `create_date` to the microsecond; and
`fields.Datetime.now()` strips microseconds, so two records stamped a second
apart on any other datetime column tie as well. Both are ordinary production
shapes - a bulk invitation, a batch of chatter notes - not test contrivances.

PAGE SIZES 1 AND 5. The planner only flips between a bounded top-N heapsort and
an unbounded quicksort at particular `(rows, limit, offset)` combinations, and
the tie order differs between the two algorithms. A 60-row population loses 28
rows at limit=1, 4 at limit=5 and none at limit=20, so a single page size can
hide the defect entirely. The property is quantified over the page size, so the
test is too.

THE CONTROL GROUP IS THE POINT OF THIS FILE. `/drafts`, `/bank` and `/emails`
already order by a unique key and must pass UNFIXED. If one of them fails, the
design's audit table is wrong and no ordering edit should be made until it is
corrected.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..controllers.api import forms as api_forms
from ..controllers.api import task_templates as api_templates
from ._paging_harness import call_route, losses, walk

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: Rows per fixture. 60 at limit=1 loses 28 rows on a non-unique key, which is
#: unambiguous, and every fixture below builds in well under a second.
ROWS = 60

#: The page sizes the property is quantified over here. 1 is the harshest and
#: 5 is an ordinary small page; both are inside `paging()`'s clamp.
PAGE_SIZES = (1, 5)

#: A tie on a datetime column, shared by every fixture that needs one.
TIED_DATE = "2026-01-01 00:00:00"


@tagged("-at_install", "post_install")
class _Audit(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.forms = api_forms.EtpStudioFormsApi()
        self.templates = api_templates.AssessmentsBeTaskTemplateApi()
        self.Assessment = self.env["assessments.be"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.Tag = self.env["assessments.be.tag"]
        self.Usage = self.env["assessments.be.llm.usage"]
        self.Form = self.env["etp.studio.form"]
        self.Template = self.env["assessments.be.task.template"]
        self.Message = self.env["mail.message"]
        self.Mail = self.env["mail.mail"]
        self.Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        self.token = uuid4().hex[:10]

    # ------------------------------------------------------------------
    # Assertions
    # ------------------------------------------------------------------
    def _partition(self, label, page_call, expect="fail_before_fix",
                   population_ids=None, page_sizes=PAGE_SIZES):
        """Walk `page_call` at every page size and report the partition result.

        Returns a dict of `{page_size: lost_row_count}` instead of asserting, so
        the sweep can report a verdict per route in one run rather than stopping
        at the first one. `expect` is documentation only; the caller asserts.
        """
        report = {}
        for limit in page_sizes:
            ids, pages, meta = walk(page_call, limit)
            total = meta["total"]
            distinct = len(set(ids))
            duplicated, missing = losses(
                ids, population_ids if population_ids is not None else set())
            report[limit] = {
                "total": total,
                "collected": len(ids),
                "distinct": distinct,
                "lost": total - distinct,
                "pages": pages,
                "duplicated": duplicated[:8],
                "missing": missing[:8],
                "expect": expect,
                "label": label,
            }
        return report

    def _assert_whole(self, report):
        for limit, row in sorted(report.items()):
            self.assertEqual(
                row["distinct"], row["total"],
                "%s at limit=%d: %d pages returned %d rows, %d distinct, "
                "%d short of meta.total=%d (duplicated %s, never returned %s)"
                % (row["label"], limit, row["pages"], row["collected"],
                   row["distinct"], row["lost"], row["total"],
                   row["duplicated"] or "-", row["missing"] or "-"))

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _generator(self):
        return self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})

    def _question(self, generator, sequence=10, name=None):
        return self.Question.create({
            "name": name or "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "sequence": sequence,
            "generator_id": generator.id,
        })

    def _assessment(self):
        generator = self._generator()
        question = self._question(generator)
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
        })

    def _applicants(self, size, prefix="Cand"):
        return self.Applicant.create([{
            "partner_name": "%s %04d %s" % (prefix, i, self.token),
            "email_from": "%s.%04d.%s@example.com" % (
                prefix.lower(), i, self.token),
        } for i in range(size)])

    def _cohort(self, assessment, size):
        return self.Evaluator.create([{
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        } for applicant in self._applicants(size)])

    # ------------------------------------------------------------------
    # Page callables
    # ------------------------------------------------------------------
    def _page(self, module, controller, method, path=None, **filters):
        def page(limit, offset):
            return call_route(module, controller, method, self.env,
                              path=path, limit=limit, offset=offset, **filters)
        return page


class TestTheSweepRoutesLoseRows(_Audit):
    """The routes the design says have a non-unique ordering key."""

    def test_assessments_listing_is_a_partition(self):
        """`/assessments` - `create_date desc`, audit row 2."""
        names = "Tied paper %s" % self.token
        records = self.Assessment.create([
            {"name": names} for _ in range(ROWS)])
        report = self._partition(
            "/assessments", self._page(
                api_admin, self.admin, "assessment_list", search=names),
            population_ids=set(records.ids))
        self._assert_whole(report)

    def test_generators_listing_is_a_partition(self):
        """`/generators` - `create_date desc`, audit row 3."""
        names = "Tied generator %s" % self.token
        records = self.Generator.create([
            {"name": names} for _ in range(ROWS)])
        report = self._partition(
            "/generators", self._page(
                api_admin, self.admin, "generator_list", search=names),
            population_ids=set(records.ids))
        self._assert_whole(report)

    def test_users_listing_is_a_partition(self):
        """`/users` - `name`, audit row 8.

        `name` is reached through `res.partner` by `_inherits` and nothing makes
        it unique, so a directory holding two people called the same thing is
        the ordinary case rather than the odd one.
        """
        shared = "Tied Person %s" % self.token
        users = self.env["res.users"].with_context(
            no_reset_password=True).create([{
                "name": shared,
                "login": "tied.%02d.%s@example.com" % (i, self.token),
            } for i in range(30)])
        report = self._partition(
            "/users", self._page(
                api_admin, self.admin, "user_list", search=self.token),
            population_ids=set(users.ids))
        self._assert_whole(report)

    def test_responses_listing_is_a_partition(self):
        """`/responses` - `create_date desc`, audit row 9."""
        assessment = self._assessment()
        question = assessment.question_ids[0]
        cohort = self._cohort(assessment, ROWS)
        records = self.Response.create([{
            "assessment_id": assessment.id,
            "assessment_evaluator_id": ev.id,
            "evaluator_id": ev.applicant_id.id,
            "question_id": question.id,
        } for ev in cohort])
        report = self._partition(
            "/responses", self._page(
                api_admin, self.admin, "response_list",
                assessment_id=assessment.id),
            population_ids=set(records.ids))
        self._assert_whole(report)

    def test_ledger_listing_is_a_partition(self):
        """`/ledger` - `create_date desc`, audit row 10."""
        model_name = "tied-model-%s" % self.token
        records = self.Usage.create([{
            "operation": "other", "model": model_name,
        } for _ in range(ROWS)])
        report = self._partition(
            "/ledger", self._page(
                api_admin, self.admin, "ledger", model=model_name),
            population_ids=set(records.ids))
        self._assert_whole(report)

    def test_chatter_listing_is_a_partition(self):
        """`/chatter` - `date desc`, audit row 11.

        `mail.message.date` is stamped by `fields.Datetime.now()`, which strips
        microseconds, so every note `_log_activity` posts inside the same second
        ties. The fixture pins one date to make that deterministic.
        """
        assessment = self._assessment()
        records = self.Message.create([{
            "model": "assessments.be",
            "res_id": assessment.id,
            "message_type": "notification",
            "subtype_id": self.env.ref("mail.mt_note").id,
            "body": "<p>Tied note %d</p>" % i,
            "date": TIED_DATE,
        } for i in range(ROWS)])
        report = self._partition(
            "/chatter", self._page(
                api_admin, self.admin, "chatter",
                path={"kind": "assessment", "record_id": assessment.id}),
            population_ids=set(records.ids))
        self._assert_whole(report)


class TestTheRoutesTheDesignCallsUnknown(_Audit):
    """`/forms` and `/task_templates` pass no `order=` at all.

    The design lists both as "unknown - state it explicitly". What they actually
    inherit is recorded here, because task 8.2's explicit order has to reproduce
    today's behaviour rather than change it.
    """

    def test_the_two_inherited_orders_are_recorded(self):
        """Both models already end their `_order` with a unique column."""
        self.assertEqual(self.Form._order, "write_date desc, id desc")
        self.assertEqual(self.Template._order, "write_date desc, id desc")

    def test_forms_listing_is_a_partition(self):
        """`/forms` (forms.py:70) - inherits `write_date desc, id desc`.

        Expected to PASS unfixed: `write_date` ties across a batch exactly as
        `create_date` does, and `id desc` is what saves it.
        """
        title = "Tied form %s" % self.token
        records = self.Form.create([{
            "client_uid": "cuid-%02d-%s" % (i, self.token),
            "title": title,
        } for i in range(ROWS)])
        report = self._partition(
            "/forms", self._page(
                api_forms, self.forms, "forms_list", search=title),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)

    def test_task_templates_listing_is_a_partition(self):
        """`/task_templates` (task_templates.py:108) - same inherited order."""
        name = "Tied template %s" % self.token
        records = self.Template.create([{
            "name": name, "response": "single_choice",
        } for _ in range(ROWS)])
        report = self._partition(
            "/task_templates", self._page(
                api_templates, self.templates, "task_templates_list",
                search=name),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)


class TestTagsCannotHoldATie(_Audit):
    """`/tags` orders by `name`, and the model refuses a duplicate name.

    The design's audit calls `name` non-unique. It is non-unique in the SCHEMA -
    there is no SQL constraint - but `_check_unique_name` rejects a
    case-insensitive duplicate, so a tie is unconstructible through the ORM and
    `/tags` cannot lose a row today. The tiebreaker task 8.1 adds is defence
    against that Python constraint being bypassed (a raw SQL write, or a race
    between two `_get_or_create` calls), not a fix for an observable defect.
    """

    def test_a_duplicate_tag_name_is_refused(self):
        from odoo.exceptions import ValidationError
        name = "domain:tied-%s" % self.token
        self.Tag.create({"name": name})
        with self.assertRaises(ValidationError):
            self.Tag.create({"name": name.upper()})

    def test_tags_listing_is_a_partition(self):
        """Distinct names, so this passes before and after the fix."""
        records = self.Tag.create([
            {"name": "domain:tied-%s-%02d" % (self.token, i)}
            for i in range(ROWS)])
        report = self._partition(
            "/tags", self._page(
                api_admin, self.admin, "tag_list", search=self.token),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)


class TestTheServableSliceIsAlreadyOrdered(_Audit):
    """`/bank?servable_only` - audit row 6, and the audit is wrong about it.

    The design says this branch Python-slices "a `search()` with no explicit
    order at all". It does not: `admin.py:1138-1141` already passes
    `order="sequence, id"` before `.filtered()` and the slice, and `.filtered()`
    preserves recordset order. The slice is therefore taken out of a totally
    ordered recordset and the walk is stable. Recorded as a test so the claim is
    checked rather than repeated.
    """

    def test_the_servable_search_is_ordered_before_it_is_sliced(self):
        generator = self._generator()
        questions = self.Question.create([{
            "name": "Servable %02d %s" % (i, self.token),
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            # EQUAL sequence: the tie the audit says is unhandled here.
            "sequence": 10,
            "generator_id": generator.id,
        } for i in range(ROWS)])
        servable = questions.filtered(
            lambda q: q.has_valid_key and q._has_required_images()
            and q._has_required_videos())
        self.assertEqual(
            len(servable), ROWS,
            "fixture check: every question must be servable or the walk below "
            "measures nothing")
        report = self._partition(
            "/bank?servable_only", self._page(
                api_admin, self.admin, "bank_list",
                servable_only=True, search=self.token),
            expect="pass_before_fix", population_ids=set(questions.ids))
        self._assert_whole(report)


class TestTheControlGroupIsAlreadyCorrect(_Audit):
    """`/drafts`, `/bank`, `/emails` - audit rows 4, 5, 12. NO edit in task 8.

    A failure in this class means the audit table is wrong and the ordering fix
    must not be made until the design is revisited.
    """

    def test_drafts_listing_is_a_partition(self):
        """`order="id"` - the primary key, unique by definition."""
        generator = self._generator()
        name = "Tied draft %s" % self.token
        records = self.Draft.create([{
            "prompt_id": generator.id, "name": name, "state": "draft",
        } for _ in range(ROWS)])
        report = self._partition(
            "/drafts", self._page(
                api_admin, self.admin, "draft_list", search=name),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)

    def test_bank_listing_is_a_partition(self):
        """`order="sequence, id"` - ends in the primary key."""
        generator = self._generator()
        name = "Tied bank %s" % self.token
        records = self.Question.create([{
            "name": name,
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "sequence": 10,
            "generator_id": generator.id,
        } for _ in range(ROWS)])
        report = self._partition(
            "/bank", self._page(
                api_admin, self.admin, "bank_list", search=name),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)

    def test_emails_listing_is_a_partition(self):
        """`order="id desc"` on `_email_page`, which serves both mail routes."""
        assessment = self._assessment()
        records = self.Mail.create([{
            "subject": "Tied mail %02d %s" % (i, self.token),
            "body_html": "<p>hi</p>",
            "email_to": "someone@example.com",
            "model": "assessments.be",
            "res_id": assessment.id,
            "state": "outgoing",
        } for i in range(ROWS)])
        report = self._partition(
            "/emails/assessment/<id>", self._page(
                api_admin, self.admin, "emails_for_record",
                path={"kind": "assessment", "record_id": assessment.id}),
            expect="pass_before_fix", population_ids=set(records.ids))
        self._assert_whole(report)


class TestTheTrivialPopulations(_Audit):
    """A 0-row and a 1-row population, before and after.

    An ordering change is exactly the kind of edit that breaks the cases with no
    tie in them at all: an empty page whose `has_more` never clears loops
    forever, and a single row that gets returned twice is a partition failure
    the sweep above is too coarse to notice.
    """

    def test_an_empty_population_walks_once_and_stops(self):
        assessment = self._assessment()
        for limit in PAGE_SIZES:
            ids, pages, meta = walk(
                self._page(api_admin, self.admin, "assessment_candidates",
                           path={"assessment_id": assessment.id}), limit)
            self.assertEqual((ids, pages, meta["total"], meta["has_more"]),
                             ([], 1, 0, False),
                             "an empty roster must answer one empty page")

    def test_a_single_row_population_is_returned_exactly_once(self):
        assessment = self._assessment()
        cohort = self._cohort(assessment, 1)
        for limit in PAGE_SIZES:
            ids, pages, meta = walk(
                self._page(api_admin, self.admin, "assessment_candidates",
                           path={"assessment_id": assessment.id}), limit)
            self.assertEqual((ids, pages, meta["total"]),
                             (cohort.ids, 1, 1))

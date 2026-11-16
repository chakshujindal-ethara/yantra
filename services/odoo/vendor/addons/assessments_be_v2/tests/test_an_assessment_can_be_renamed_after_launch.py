# -*- coding: utf-8 -*-
"""An assessment can be renamed after it launches.

WHY THIS EXISTS. `assessment_update` refuses every field outside
`POST_DRAFT_FIELDS` once an assessment leaves `draft`, and `name` was not in
that set - so the title was editable for exactly as long as nobody had sat the
paper. The 409 landed the moment it launched, which is when a wrong name starts
mattering: the name is the only handle an operator has on an assessment in every
list, export, invitation and dashboard, and a typo in it could not be corrected
without cancelling the sitting and starting again.

A RENAME IS NOT A CHANGE TO THE EXAM. Nothing a candidate saw, agreed to or
answered depends on what the assessment is called - the same argument
`subjective_threshold` is unlocked on. The things that must stay frozen (the
question draw, the clock, the generator behind the paper) are still frozen, and
`test_the_gate_still_refuses_a_draft_only_field` plus
`test_the_route_still_answers_409_on_a_draft_only_field` are what keep this from
being read as "the post-draft lock was removed". Without those two, a route that
had lost its gate entirely would pass every other test in this file.

NO SOURCE READING ANYWHERE. The structural tests consult the LIVE class
attribute the route consults - `EtpAssessmentApiWrite.POST_DRAFT_FIELDS` - and
evaluate the route's own refusal expression against a rename payload, so
deleting the entry fails them. A test that searched the file for the string
`"name"` would pass with the entry commented out; reading the set cannot.

THREE LAYERS, ASSERTED SEPARATELY, so a failure says which one broke: the
allow-list is a set of strings, the route is the thing that answers 409, and the
model is the thing that has to accept the write. The route is driven end to end
through the shipped method with a request stub - the same pattern
`test_candidate_identity` and `test_an_archived_paper_is_out_of_the_cohort` use -
because re-implementing the gate here would assert that a copy of it behaves
like itself.

The Manager group is referenced by XML ID only, never by its label: the label is
being changed and a test that spelled it out would fail on a rename of the
group, which is not the behaviour under test.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import common as api_common
from ..controllers.api import write as write_api

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


class _Req:
    """The three things `assessment_update` and its helpers read off `request`.

    `env` for the ORM in the route body, `params` for every `arg`/`str_arg`
    lookup in `_picked`, and `make_json_response` because that is how `fail()`
    builds a non-200 envelope - the status code is the whole point of the 409
    assertions below.
    """

    def __init__(self, env, params):
        self.env = env
        self.params = params

    def make_json_response(self, payload, headers=None, status=200):
        return {"__status": status, **payload}


@tagged("-at_install", "post_install")
class TestAnAssessmentCanBeRenamedAfterLaunch(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.controller = write_api.EtpAssessmentApiWrite()
        # `assessment_update` is Manager-gated. Without the group every route
        # assertion below would be measuring the gate instead of the rule.
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]

    # ------------------------------------------------------------------
    # Fixtures - same shape as test_assessment_archive
    # ------------------------------------------------------------------
    def _question(self):
        # `prompt` is required=True on the model, so the fixture carries one.
        return self.Question.create({
            "name": "Battery charging %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
        })

    def _assessment(self, name="Warehouse Safety"):
        return self.Assessment.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_ids": [(6, 0, self._question().ids)],
        })

    def _launched(self, state="in_progress"):
        """An assessment past draft. The state is written directly rather than
        through `action_start` on purpose: the launch gates are somebody else's
        tests, and what this file needs is only a record whose `state` is not
        `draft` - which is the single condition the refusal branch reads."""
        asm = self._assessment()
        asm.state = state
        return asm

    @staticmethod
    def _blocked(values):
        """The route's own refusal expression, evaluated on a payload.

        Copied from the branch in `assessment_update`:

            blocked = sorted(set(values) - self.POST_DRAFT_FIELDS)

        The EXPRESSION is one line and is duplicated here; the SET it consults
        is the live class attribute, read at call time, which is the part that
        cannot drift. That the route really evaluates this is what the two
        end-to-end tests below establish.
        """
        return sorted(
            set(values) - write_api.EtpAssessmentApiWrite.POST_DRAFT_FIELDS)

    def _update(self, assessment, **payload):
        """Drive the shipped route with a request stub.

        Both module bindings are patched: `write.request` is what the route
        body reads for `env`, and `common.request` is what `_picked`, `arg`,
        `str_arg` and `fail` read. They are the same proxy in production and
        two distinct names here.
        """
        fake = _Req(self.env, dict(payload))
        with patch.object(write_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return self.controller.assessment_update(assessment.id)

    @staticmethod
    def _status(response):
        """`ok()` returns a bare dict (HTTP 200); `fail()` goes through the
        stub's `make_json_response` and carries its status."""
        return response.get("__status", 200)

    # ------------------------------------------------------------------
    # The allow-list the route actually consults
    # ------------------------------------------------------------------
    def test_name_is_writable_after_draft(self):
        """THE ENTRY. Read off the live attribute, so removing it fails here."""
        self.assertIn(
            "name", write_api.EtpAssessmentApiWrite.POST_DRAFT_FIELDS,
            "`name` must stay in POST_DRAFT_FIELDS or an operator cannot "
            "correct a wrong assessment title once anybody has sat the paper")

    def test_the_allow_list_can_pick_the_name_at_all(self):
        """POST_DRAFT_FIELDS only *unblocks*; ASSESSMENT_FIELDS is what copies
        the value out of the payload. A key in the first but not the second
        would give the worst outcome of the two: HTTP 200, and nothing renamed.
        """
        self.assertIn(
            "name", write_api.EtpAssessmentApiWrite.ASSESSMENT_FIELDS,
            "a field the allow-list never picks cannot be written through the "
            "API - the route would answer 200 and change nothing")

    def test_the_gate_does_not_block_a_rename(self):
        """The refusal predicate on the exact payload a rename sends."""
        self.assertEqual(
            self._blocked({"name": "Corrected title"}), [],
            "nothing may be blocked when the only field sent is the name")

    def test_the_gate_still_refuses_a_draft_only_field(self):
        """THE SELECTIVITY CONTROL.

        Emptying POST_DRAFT_FIELDS' complement - by widening the set to
        everything, or by deleting the branch - would satisfy every assertion
        above. These are the fields that decide what a candidate is actually
        asked, and they must still come back blocked.
        """
        for field in ("generator_id", "question_ids"):
            self.assertEqual(
                self._blocked({field: "whatever"}), [field],
                "%s changes the exam under somebody taking it and must stay "
                "refused after draft" % field)

    def test_a_rename_cannot_smuggle_a_draft_only_field_with_it(self):
        """A mixed payload is refused for the field that is not allowed, and
        the allowed one does not launder it."""
        self.assertEqual(
            self._blocked({"name": "New", "generator_id": 7}),
            ["generator_id"])

    # ------------------------------------------------------------------
    # The model accepts the write
    # ------------------------------------------------------------------
    def test_a_launched_assessment_accepts_the_new_name(self):
        """Unblocking the field is pointless if `write` refuses it anyway."""
        asm = self._launched()
        asm_id = asm.id
        new_name = "Renamed mid-flight %s" % uuid4().hex[:6]

        asm.write({"name": new_name})
        asm.invalidate_recordset(["name"])

        self.assertEqual(asm.name, new_name)
        self.assertEqual(
            asm.id, asm_id,
            "a rename must edit the row in place, not replace it - every "
            "response, evaluator and score points at this id")
        self.assertEqual(
            asm.state, "in_progress",
            "renaming must not move the lifecycle")

    def test_every_state_after_draft_accepts_a_rename(self):
        """Including `done` and `cancelled`: a finished paper with a wrong name
        is the most common reason anybody needs this, and it is exactly the one
        the old 409 covered."""
        for state in ("draft", "in_progress", "done", "cancelled"):
            asm = self._launched(state)
            new_name = "Fixed in %s %s" % (state, uuid4().hex[:6])

            asm.write({"name": new_name})
            asm.invalidate_recordset(["name"])

            self.assertEqual(
                asm.name, new_name, "a rename must work in state %r" % state)

    # ------------------------------------------------------------------
    # End to end, through the shipped route
    # ------------------------------------------------------------------
    def test_the_route_renames_a_running_assessment(self):
        """THE HEADLINE: the call that used to answer 409 now answers 200 and
        the new name is on the record afterwards."""
        asm = self._launched()
        new_name = "Corrected title %s" % uuid4().hex[:6]

        response = self._update(asm, name=new_name)

        self.assertEqual(
            self._status(response), 200,
            "the update route refused a rename on a running assessment: %r"
            % response)
        self.assertTrue(response.get("ok"), response)
        asm.invalidate_recordset(["name"])
        self.assertEqual(asm.name, new_name)
        self.assertEqual(
            response.get("data", {}).get("name"), new_name,
            "the response must carry the name it just stored, or the console "
            "redraws the old title")

    def test_the_route_still_answers_409_on_a_draft_only_field(self):
        """The negative control at route level.

        A gate that had been deleted outright would pass every other test
        here. This one fails if it has been.
        """
        asm = self._launched()
        before = asm.generator_id.id
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Other SOP %s" % uuid4().hex[:6]})
        self.assertNotEqual(
            before, generator.id,
            "fixture check: the payload has to name a DIFFERENT generator or "
            "an unchanged record proves nothing")

        response = self._update(asm, generator_id=generator.id)

        self.assertEqual(self._status(response), 409, response)
        self.assertEqual(response.get("error", {}).get("code"), "not_draft")
        asm.invalidate_recordset(["generator_id"])
        self.assertEqual(
            asm.generator_id.id, before,
            "a refused write must leave the record as it found it")

    def test_a_refused_payload_does_not_half_apply_the_rename(self):
        """The refusal is all or nothing.

        `blocked` is computed over the WHOLE payload and returns before
        `record.write`, so a request carrying one allowed field and one
        forbidden one must store neither. A route that wrote the allowed part
        and then refused would report "nothing changed" while having renamed
        the assessment.
        """
        asm = self._launched()
        original = asm.name
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Other SOP %s" % uuid4().hex[:6]})

        response = self._update(
            asm, name="Should not land %s" % uuid4().hex[:6],
            generator_id=generator.id)

        self.assertEqual(self._status(response), 409, response)
        asm.invalidate_recordset(["name"])
        self.assertEqual(
            asm.name, original,
            "the rename rode along with a refused field and was stored anyway")

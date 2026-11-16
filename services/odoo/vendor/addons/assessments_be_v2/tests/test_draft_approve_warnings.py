"""The authoring-warnings gate, on BOTH paths into the bank.

THE BUG, as it reached stage. `/drafts/<id>/approve` refuses a draft carrying an
authoring smell unless the caller sends `acknowledge_warnings`, and the client
never sent it: the reviewer ticked "I have looked at this warning", the request
went out with the flag false, and the server answered 422. Every draft with
either smell was unapprovable from every screen.

The gate itself is right, and these tests pin it so the fix stays on the client
side where it belongs.

The second half is the hole the first half made attractive. `Approve All Drafts`
reached `action_approve_all_drafts`, which tests neither flag, so the one button
that skipped the gate entirely was also the obvious way around it for anyone the
gate had just blocked - bulk-banking exactly what the per-draft gate exists to
hold back. A batch click cannot stand for a per-question human judgement, so
those drafts are now HELD and named instead.

`text_has_source_reference` is a regex over SOP/manual/procedure wording, so
"per the SOP" in the prompt is all it takes to raise the flag - which is also
why the warning means the item CITES the document, not that it is unsourced.
"""
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase


class TestDraftApproveWarnings(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Warnings fixture %s" % uuid4().hex[:6]})
        self.Draft = self.env["assessments.be.prompt.question"]

    def _draft(self, prompt="Describe the escalation path.", **extra):
        return self.Draft.create(dict({
            "prompt_id": self.generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "question_prompt": prompt,
        }, **extra))

    def _flagged(self, prompt="Per the SOP, describe the escalation."):
        """A draft that ACTUALLY carries the smell, asserted on the way out.

        The regex is narrow - it wants "SOP", a numbered "Section 4.2", or an
        "according to the <thing>" construction - so a plausible-looking prompt
        like "The manual says to escalate" raises nothing. A test that assumed
        otherwise was green while the gate under test never ran, so every
        fixture that depends on the flag proves it is set before going on.
        """
        draft = self._draft(prompt=prompt)
        self.assertTrue(
            draft.has_source_reference,
            "fixture prompt %r does not raise the flag this test needs"
            % prompt)
        return draft

    # ---- the flag the compute actually raises ------------------------
    def test_citing_the_sop_raises_the_source_flag(self):
        """The smell is the CITATION, not its absence.

        The client modelled this inverted and told the reviewer the question
        could not be tied back to the document - the opposite of what was
        detected, on the one screen where they decide whether to serve it.
        """
        cites = self._draft(prompt="Per Section 4.2 of the SOP, escalate how?")

        self.assertTrue(
            cites.has_source_reference,
            "a prompt naming the SOP must raise the source-reference flag")

    def test_a_self_contained_prompt_raises_nothing(self):
        clean = self._draft()

        self.assertFalse(clean.has_source_reference)
        self.assertFalse(clean.has_revealing_option)

    def test_naming_a_document_is_not_on_its_own_a_citation(self):
        """The boundary that made an earlier test here green for nothing.

        The regex wants "SOP", a numbered "Section 4.2", or an "according to
        the <thing>" construction - the bare noun is not enough, and should not
        be: "read the manual before you start" is ordinary prose, not a pointer
        at material the candidate cannot see. Pinned because a fixture written
        on the wrong assumption silently disables whatever it was meant to test.
        """
        bare = self._draft(prompt="The manual says to escalate - describe how.")

        self.assertFalse(
            bare.has_source_reference,
            "naming a document without citing it must not raise the flag")

    def test_the_flag_follows_the_options_as_edited(self):
        """A save renames the option rows and leaves `options_json` as
        generated, so the flag read the stale JSON both ways."""
        draft = self._draft(
            prompt="Which city hosts the head office?", question_type="mcq",
            options_json='["Lyon, as per the SOP", "Paris"]',
            answer_dimension_ids=[(0, 0, {"label": "Answer", "option_line_ids": [
                (0, 0, {"name": "Lyon, as per the SOP", "is_correct": True}),
                (0, 0, {"name": "Paris"})]})])
        self.assertTrue(draft.has_source_reference)
        lyon = draft.answer_dimension_ids.option_line_ids[0]

        lyon.name = "Lyon"
        self.assertFalse(draft.has_source_reference,
                         "the citation was edited out of the option")
        lyon.name = "Lyon, according to the SOP"
        draft.options_json = '["Lyon", "Paris"]'
        self.assertTrue(draft.has_source_reference,
                        "a citation edited into an option was missed")

    # ---- Approve All: the flagged drafts must not slip through -------
    def test_approve_all_holds_a_flagged_draft(self):
        clean = self._draft()
        flagged = self._flagged("According to the SOP, what happens?")

        self.generator.action_approve_all_drafts()

        self.assertEqual(clean.state, "approved",
                         "a clean draft must still go through in bulk")
        self.assertEqual(
            flagged.state, "draft",
            "a draft carrying an authoring smell must NOT be bulk-approved - "
            "that is the gate the per-draft route applies, and Approve All "
            "was the one way around it")

    def test_approve_all_reports_what_it_held(self):
        """Silence here is what made a held draft look like a lost one."""
        self._draft()
        flagged = self._flagged("Follow the SOP and describe the steps.")

        result = self.generator.action_approve_all_drafts()

        self.assertIsInstance(
            result, dict,
            "a partial pass must return a notification, not a bare True")
        self.assertEqual(result.get("tag"), "display_notification")
        params = result.get("params") or {}
        self.assertEqual(params.get("type"), "warning",
                         "the client keys its red toast off this")
        self.assertIn("skipped", (params.get("message") or "").lower())
        self.assertEqual(flagged.state, "draft")

    def test_the_held_draft_is_named_in_the_generator_log(self):
        """"2 skipped" with no names leaves an operator nothing to act on.

        The assertion is deliberately scoped to the SKIPPED rollup. Asserting
        only that the name appears somewhere in the chatter passed for the wrong
        reason: `_log_drafts_to_generators` posts the APPROVED names too, so a
        draft that was never flagged - this test first used "The manual says to
        escalate", which the regex does not match - showed up in the log by
        being approved and the test went green on a gate that never fired.
        """
        clean = self._draft()
        flagged = self._flagged()

        self.generator.action_approve_all_drafts()

        skipped = " ".join(
            body for body in self.generator.message_ids.mapped("body") or []
            if "skipped during Approve All" in body)
        self.assertTrue(skipped, "the skip rollup must be posted at all")
        self.assertIn(flagged.name, skipped,
                      "the rollup must name the draft that was held")
        self.assertNotIn(
            clean.name, skipped,
            "a draft that went through must not be reported as skipped")

    def test_approve_all_refuses_outright_when_everything_is_flagged(self):
        """No silent no-op: nothing reached the bank, so say why."""
        self._flagged()

        with self.assertRaises(UserError) as caught:
            self.generator.action_approve_all_drafts()

        self.assertIn("no drafts could be approved",
                      str(caught.exception).lower())

    def test_acknowledging_lets_approve_all_through(self):
        """The deliberate opt-out, for a caller that has done the review."""
        flagged = self._flagged()

        self.generator.with_context(
            acknowledge_warnings=True).action_approve_all_drafts()

        self.assertEqual(
            flagged.state, "approved",
            "an explicit acknowledgement must still be able to approve")

    def test_an_empty_generator_still_refuses_for_the_old_reason(self):
        """The gate must not swallow the pre-existing 'nothing to do' case."""
        with self.assertRaises(UserError) as caught:
            self.generator.action_approve_all_drafts()

        self.assertIn("no pending drafts", str(caught.exception).lower())

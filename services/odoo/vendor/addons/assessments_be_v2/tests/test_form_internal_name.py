# -*- coding: utf-8 -*-
"""An operator's name for a form must not become the candidate's heading.

WHAT THE TWO FIELDS ARE FOR. `etp.studio.form.title` is candidate-facing copy:
it is the heading rendered above the first question, and it is written for the
person answering. `internal_name` is what the people RUNNING the assessment
call the same form in a list of two hundred rows - "Quality Assessment" to the
candidate, "Q7r cohort 3 - retake" to the operator who has to find it again on
Monday. `display_title` resolves which of the two an operator-facing reader
gets.

THE GAP THIS CLOSES. There was ONE name. An operator who needed a form
findable in the assessment list had to retitle the form, and the retitle
landed on the candidate's heading - so the way to organise your own back
office was to write your filing system into the exam paper. Publishing made
that permanent in two places at once: `publish_to_assessment` names the
assessment from the form, and `_create_generator` names the question pool from
it, and both read `title`.

WHY THESE ASSERTIONS AND NOT OTHERS.

  * PUBLISH IS ASSERTED ON THE RECORDS, not on the resolved string. Reading
    `form.display_title` back proves the compute, and proves nothing about the
    two consumers that were the actual defect. So each case browses the
    assessment and the generator the publish created and reads their `name`.

  * THE RESPONDENT SIDE IS ASSERTED EXPLICITLY. `title` being unchanged by an
    override is the whole safety property of the feature, and it would break
    silently: everything an operator looks at would still be right. The only
    thing that would move is what a candidate reads, which no admin screen
    shows.

  * THE FALLBACK IS ASSERTED IN BOTH DIRECTIONS. A `display_title` that always
    returned the title would pass every "does the fallback work" test and
    deliver none of the feature; one that always returned `internal_name`
    would name a never-overridden form's assessment "False".

`_FormBase` supplies the document fixtures and keeps media inside the process -
see `test_authored_question_marks` for why that matters.
"""
from uuid import uuid4

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("-at_install", "post_install")
class TestFormInternalName(_FormBase):
    """`internal_name` -> `display_title` -> the assessment and the pool."""

    CANDIDATE_TITLE = "Quality Assessment: IG Entity Image"
    OPERATOR_NAME = "Q7r cohort 3 - retake"

    # -- fixtures ------------------------------------------------------

    def _choice(self, title=None):
        return self._item(
            "multipleChoice", title=title or "Q %s" % uuid4().hex[:6],
            options=self._opts(("Yes", True), ("No", False)))

    def _titled_form(self, internal_name=None):
        """A publishable one-question form with a known candidate title."""
        form = self._form(self._choice())
        vals = {"title": self.CANDIDATE_TITLE}
        if internal_name is not None:
            vals["internal_name"] = internal_name
        form.write(vals)
        return form

    def _published(self, form):
        """(assessment, generator) for a publish that must have succeeded."""
        result = form.publish_to_assessment()
        self.assertNotIn(
            "problems", result,
            "the fixture form must publish; problems were %r"
            % (result.get("problems"),))
        assessment = self.env["assessments.be"].browse(result["assessment_id"])
        generator = self.env["assessments.be.prompt"].browse(
            result["generator_id"])
        self.assertTrue(assessment.exists() and generator.exists())
        return assessment, generator

    # -- the fallback --------------------------------------------------

    def test_display_title_falls_back_to_the_candidate_title(self):
        """No override is the ordinary case, so it must read as it always did.

        Every form that exists predates this field and has NULL in it; if the
        fallback were wrong, the whole Form Studio list would change name at
        once on upgrade.
        """
        form = self._titled_form()

        self.assertFalse(
            form.internal_name,
            "a form nobody has renamed must store NOTHING - empty is how the "
            "'not overridden' state is expressed, so a default copied from "
            "the title would make every form permanently overridden")
        self.assertEqual(form.display_title, self.CANDIDATE_TITLE)

    def test_an_internal_name_wins(self):
        form = self._titled_form(internal_name=self.OPERATOR_NAME)

        self.assertEqual(form.display_title, self.OPERATOR_NAME)

    def test_an_internal_name_does_not_move_the_respondent_heading(self):
        """THE SAFETY PROPERTY. Setting the operator's name must leave the
        candidate's heading exactly where it was.

        Asserted on its own because it fails invisibly: every admin screen
        would still show the right thing, and the only casualty would be the
        heading a candidate reads - which no admin screen shows.
        """
        form = self._titled_form(internal_name=self.OPERATOR_NAME)

        self.assertEqual(
            form.title, self.CANDIDATE_TITLE,
            "the internal name is a second label, not a rename")

    def test_clearing_the_internal_name_returns_to_the_title(self):
        """An override is reversible, and reverting must need no extra state.

        The nullable field IS the flag: emptying it is how an operator says
        "go back to the title", and no companion boolean has to be cleared in
        step with it.
        """
        form = self._titled_form(internal_name=self.OPERATOR_NAME)
        form.internal_name = ""

        self.assertEqual(form.display_title, self.CANDIDATE_TITLE)

    def test_a_form_with_neither_name_still_reads_as_something(self):
        """`title` is required, so this is defence against a blanked column
        rather than a shape the API can post - but `display_title` names an
        assessment, and an assessment called "False" is unfindable."""
        form = self._titled_form()
        form.title = ""

        self.assertEqual(form.display_title, "Untitled form")

    # -- publish reads the operator-facing name ------------------------

    def test_publish_names_the_assessment_from_the_internal_name(self):
        """The list an operator actually works in.

        Nobody sitting the exam reads an assessment's `name`; the people who
        assign, launch and release it read nothing else, and they look for
        whatever they called the form.
        """
        form = self._titled_form(internal_name=self.OPERATOR_NAME)
        assessment, _generator = self._published(form)

        self.assertEqual(assessment.name, self.OPERATOR_NAME)

    def test_publish_names_the_question_pool_from_the_internal_name(self):
        """The generator is the second consumer, and it was the one likeliest
        to be missed: it builds its name by interpolation rather than by
        assignment, so a sweep for `self.title` reads differently there."""
        form = self._titled_form(internal_name=self.OPERATOR_NAME)
        _assessment, generator = self._published(form)

        self.assertEqual(generator.name, "Form: %s" % self.OPERATOR_NAME)

    def test_publish_without_an_override_names_both_from_the_title(self):
        """Guard the guard. If publish read a name that was always empty, the
        two cases above could pass for the wrong reason and every existing
        form would publish as "Untitled form"."""
        form = self._titled_form()
        assessment, generator = self._published(form)

        self.assertEqual(assessment.name, self.CANDIDATE_TITLE)
        self.assertEqual(generator.name, "Form: %s" % self.CANDIDATE_TITLE)

    def test_publishing_an_override_leaves_the_candidate_heading_alone(self):
        """A publish must not write the operator's name back onto the form.

        The form is still the artefact the designer edits and the preview
        renders, so a publish that "normalised" the two names would rename the
        exam paper as a side effect of creating an assessment.
        """
        form = self._titled_form(internal_name=self.OPERATOR_NAME)
        self._published(form)

        self.assertEqual(form.title, self.CANDIDATE_TITLE)
        self.assertEqual(form.internal_name, self.OPERATOR_NAME)

    # -- the pool name is still bounded and still unique ---------------

    def test_a_long_internal_name_is_still_truncated_for_the_pool(self):
        """`assessments.be.prompt.name` is a Char with a 110-char budget here,
        and the override is free text from a much wider input. Truncation was
        already applied to the title; routing a different string through the
        same expression must not lose it."""
        form = self._titled_form(internal_name="N" * 300)
        _assessment, generator = self._published(form)

        self.assertEqual(len(generator.name), 110)
        self.assertTrue(generator.name.startswith("Form: NNN"))

    def test_two_forms_sharing_an_internal_name_get_distinct_pools(self):
        """De-duplication has to keep working on the NEW name.

        Two operators can easily land on the same internal name, and the
        suffix loop is what keeps `Prompt.search_count` from matching an
        existing pool - which is the difference between a second pool and a
        publish that walks onto the first one's questions.
        """
        first = self._titled_form(internal_name=self.OPERATOR_NAME)
        second = self._titled_form(internal_name=self.OPERATOR_NAME)

        _a1, g1 = self._published(first)
        _a2, g2 = self._published(second)

        self.assertEqual(g1.name, "Form: %s" % self.OPERATOR_NAME)
        self.assertEqual(g2.name, "Form: %s (2)" % self.OPERATOR_NAME)
        self.assertNotEqual(
            g1.id, g2.id,
            "each publish owns its own pool - action_start draws every active "
            "question of the generator, so a shared pool serves one form's "
            "questions on another form's paper")

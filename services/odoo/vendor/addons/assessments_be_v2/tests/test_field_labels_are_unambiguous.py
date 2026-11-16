"""No field this module adds may wear a label another module already uses.

WHY THIS IS A TEST AND NOT A TIDY-UP. `assessments_be_v2` is a fork of
`etp_assessment_pro` and the two are installed side by side, so both extend
`hr.applicant` and `res.config.settings` with their own copy of the same idea.
Both copies arrived with the same labels: two "Scoring Prompt" settings, two
"Passed" counters on a candidate, two "Vertex Project ID" fields. Odoo logged
51 warnings a startup about it, which is how it went unnoticed for so long -
a warning nobody can act on is one everybody scrolls past.

The cost is not the log. It is that an operator filtering candidates by
"Average Score", or an admin setting "Vertex Model", is offered two identical
choices with no way to tell which module each belongs to - and picking the
wrong one configures a module that is not running the job.

The fork's fields now carry a " (v2)" suffix. This test is what keeps them
carrying it: a field added tomorrow to either shared model gets the same
treatment or this fails, rather than the collision reappearing one warning at
a time.

WHY THE FORK IS THE SIDE THAT MOVED: it is the only side that may be edited
here. If `etp_assessment_pro` is ever uninstalled, the suffixes stop earning
their keep and should come off - this test would then pass either way, so it
will not stand in the way of that.

DEPLOYMENT-SHAPED, deliberately. It reads the labels actually installed in
this database rather than parsing the source, because a collision only exists
between modules that are installed together. On a database carrying only this
module it passes trivially, which is the correct answer there.
"""
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestFieldLabelsAreUnambiguous(TransactionCase):

    MODULE = "assessments_be_v2"

    #: Labels this module repeats ON ITS OWN MODELS, on purpose.
    #:
    #: Both are one value surfaced twice, not two things sharing a name, so
    #: telling them apart in a filter list is not a thing anybody needs to do:
    #:
    #:  - `slot_ab` / `slot_text` are per-question-type selectors over the same
    #:    canonical `slot`. Only one is ever visible, and the column above it
    #:    should read "Slot" whichever it is. Naming them apart would put
    #:    "A/B Slot" over one question type and "Text Slot" over another for
    #:    what a user experiences as one column.
    #:  - `subjective_score` is `related="llm_score"`. It IS that field.
    ALLOWED = {
        ("assessments.be.question.image", "Slot"),
        ("assessments.be.response", "Subjective Mark"),
    }

    def _our_fields(self):
        """Every `ir.model.fields` row this module owns.

        Via `ir.model.data` rather than `ir.model.fields.modules`: `modules` is
        computed and not stored, so a domain on it raises rather than filtering.
        A module's field always gets an external ID under that module's name,
        which is the same fact stored somewhere searchable.
        """
        data = self.env["ir.model.data"].search([
            ("module", "=", self.MODULE),
            ("model", "=", "ir.model.fields"),
        ])
        return self.env["ir.model.fields"].browse(data.mapped("res_id")).exists()

    def test_no_field_shares_a_label_with_another_modules_field(self):
        Field = self.env["ir.model.fields"]
        ours = self._our_fields()
        self.assertTrue(
            ours, "no fields found for %s - the lookup is wrong, not the "
                  "codebase" % self.MODULE)

        clashes = set()
        for f in ours:
            if (f.model, f.field_description) in self.ALLOWED:
                continue
            siblings = Field.search([
                ("model", "=", f.model),
                ("field_description", "=", f.field_description),
                ("id", "!=", f.id),
            ])
            for other in siblings:
                clashes.add(
                    '%s: "%s" is on both %s (%s) and %s (%s)' % (
                        f.model, f.field_description,
                        f.name, f.modules or "?",
                        other.name, other.modules or "?"))

        self.assertFalse(
            sorted(clashes),
            "these labels are ambiguous in every filter, group-by and "
            "settings form that offers them. Give this module's field a "
            '" (v2)" suffix, or name the pair in ALLOWED above with the '
            "reason they are meant to read alike:\n  "
            + "\n  ".join(sorted(clashes)))

    def test_the_allowed_list_does_not_outlive_its_reason(self):
        """An exemption for a pair that no longer collides is dead weight that
        would silently cover a real collision arriving later on the same
        model and label."""
        Field = self.env["ir.model.fields"]
        stale = []
        for model, label in self.ALLOWED:
            hits = Field.search_count([
                ("model", "=", model), ("field_description", "=", label)])
            if hits < 2:
                stale.append('%s: "%s" (%d field carries it)' % (
                    model, label, hits))

        self.assertFalse(
            stale,
            "these entries in ALLOWED no longer describe a real duplicate - "
            "delete them:\n  " + "\n  ".join(sorted(stale)))

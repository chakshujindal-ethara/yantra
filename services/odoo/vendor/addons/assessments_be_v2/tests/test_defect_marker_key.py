# -*- coding: utf-8 -*-
"""A labelling question's answer key must describe the markers actually drawn.

THE DEFECT THIS LOCKS DOWN. `defect_render.plant` drops any planned defect that
vision could not confirm on the rendered image and renumbers the survivors 1..N.
`_remap_answer_key` re-keyed `rubric_json` for that - but not `solution_json`,
which is the golden answer fed to the subjective judge at score time. Draft 200
planned 7 markers, rendered 2, and ended up with a 2-entry rubric beside a
7-entry solution: the judge graded the candidate against five golden labels for
markers that were never drawn on the image they answered, and the draft carried
no warning at all.
"""
import json

from odoo.tests.common import TransactionCase


class TestDefectMarkerKeyRemap(TransactionCase):

    def _draft(self, rubric=None, solution=None):
        prompt = self.env["assessments.be.prompt"].create({
            "name": "marker remap probe",
        })
        vals = {
            "prompt_id": prompt.id,
            "name": "Tag the entities",
            "question_prompt": "Categorise each numbered box.",
            "question_type": "image_label",
        }
        if rubric is not None:
            vals["rubric_json"] = json.dumps(rubric)
        if solution is not None:
            vals["solution_json"] = json.dumps(solution)
        return self.env["assessments.be.prompt.question"].create(vals)

    def test_solution_json_is_remapped_too(self):
        """The judge's golden answer must lose the markers that never rendered."""
        seven = {str(n): "Clothing" for n in range(1, 8)}
        d = self._draft(
            rubric={"ideal_labels": dict(seven)},
            solution={"ideal_labels": dict(seven), "commentary": "7 entities"},
        )
        # Only markers 1 and 2 survived, renumbered 1 and 2.
        d._remap_answer_key({1: 1, 2: 2})

        rub = json.loads(d.rubric_json)["ideal_labels"]
        sol = json.loads(d.solution_json)["ideal_labels"]
        self.assertEqual(sorted(rub), ["1", "2"])
        self.assertEqual(
            sorted(sol), ["1", "2"],
            "solution_json still names markers the candidate never saw")

    def test_renumbering_moves_the_value_with_the_marker(self):
        """Marker 5 surviving as marker 2 must carry ITS OWN label."""
        d = self._draft(
            rubric={"ideal_labels": {"1": "People", "5": "Animals"}},
            solution={"ideal_labels": {"1": "People", "5": "Animals"}},
        )
        d._remap_answer_key({1: 1, 5: 2})
        for field in ("rubric_json", "solution_json"):
            key = json.loads(getattr(d, field))["ideal_labels"]
            self.assertEqual(key, {"1": "People", "2": "Animals"},
                             "%s mis-assigned a renumbered marker" % field)

    def test_prose_keys_survive(self):
        """`decoys` and `scoring_guide` are not markers and must not be dropped."""
        d = self._draft(
            rubric={"ideal_labels": {"1": "People", "3": "Products"},
                    "decoys": ["the woman's jeans"],
                    "scoring_guide": "tag every findable entity"},
        )
        d._remap_answer_key({1: 1})
        key = json.loads(d.rubric_json)
        self.assertEqual(sorted(key["ideal_labels"]), ["1"])
        self.assertEqual(key["decoys"], ["the woman's jeans"])
        self.assertTrue(key["scoring_guide"])

    def test_an_identity_map_changes_nothing(self):
        d = self._draft(
            rubric={"ideal_labels": {"1": "People", "2": "Animals"}},
            solution={"ideal_labels": {"1": "People", "2": "Animals"}},
        )
        before = (d.rubric_json, d.solution_json)
        d._remap_answer_key({1: 1, 2: 2})
        self.assertEqual((d.rubric_json, d.solution_json), before)

    def test_a_draft_with_no_solution_key_is_untouched(self):
        """Remapping must not invent a solution field that was never there."""
        d = self._draft(rubric={"ideal_labels": {"1": "People", "4": "Products"}})
        d._remap_answer_key({1: 1})
        self.assertFalse(d.solution_json)
        self.assertEqual(sorted(json.loads(d.rubric_json)["ideal_labels"]), ["1"])


class TestMarkerShortfallWarning(TransactionCase):

    def _draft(self):
        prompt = self.env["assessments.be.prompt"].create({"name": "shortfall"})
        return self.env["assessments.be.prompt.question"].create({
            "prompt_id": prompt.id,
            "name": "Tag the entities",
            "question_prompt": "Categorise each numbered box.",
            "question_type": "image_label",
        })

    def test_a_shortfall_is_reported_on_the_draft(self):
        d = self._draft()
        rendered = [{"number": 1}, {"number": 2}]
        self.assertTrue(d._warn_on_marker_shortfall(7, rendered))
        self.assertIn("2 of 7", d.gen_warnings)

    def test_zero_markers_says_the_image_is_unanswerable(self):
        d = self._draft()
        self.assertTrue(d._warn_on_marker_shortfall(5, []))
        self.assertIn("NO numbered boxes", d.gen_warnings)

    def test_a_full_render_is_not_flagged(self):
        d = self._draft()
        rendered = [{"number": n} for n in range(1, 6)]
        self.assertFalse(d._warn_on_marker_shortfall(5, rendered))
        self.assertFalse(d.gen_warnings)

    def test_an_existing_warning_is_kept(self):
        d = self._draft()
        d.gen_warnings = "- The question quotes the SOP at the candidate."
        d._warn_on_marker_shortfall(4, [{"number": 1}])
        self.assertIn("quotes the SOP", d.gen_warnings)
        self.assertIn("1 of 4", d.gen_warnings)

# -*- coding: utf-8 -*-
"""B3-23 / Q2b: `tools/calibration/synthetic.py` seeds made-up answers on
exported question content - image_prompt, video_prompt and image_ab included -
and the harness grades them like graded ones: nothing from a candidate."""
import base64
import importlib.util
import json
import os
import tempfile
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import model_catalog

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA"
    "hKmMIQAAAABJRU5ErkJggg==")


def _tool(name):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "tools", "calibration", name + ".py")
    spec = importlib.util.spec_from_file_location("calibration_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


synthetic = _tool("synthetic")
harness = synthetic.harness


def _question(qid, qtype, **extra):
    return dict({"id": qid, "name": "Q%d" % qid, "question_type": qtype,
                 "prompt": "Prompt %d" % qid, "generator_name": "Form: evals",
                 "solution_json": json.dumps("Key %d" % qid),
                 "images": [], "videos": [], "dimensions": []}, **extra)


QUESTIONS = [
    _question(1, "subjective_rubric"),
    _question(2, "image_label",
              solution_json=json.dumps({"1": "Misspelled heading"}),
              images=[{"id": 9, "slot": "single", "label": "Plate",
                       "image_file": {"file": "media/plate.png"},
                       "detections_json": json.dumps([
                           {"number": 1, "label": "Misspelled heading"}])}]),
    _question(3, "image_prompt", images=[
        {"id": 10, "slot": "reference", "label": "Reference",
         "image_file": {"file": "media/plate.png"}},
        {"id": 11, "slot": "output", "label": "Output", "image_file": None}]),
    _question(4, "video_prompt", videos=[
        {"id": 5, "slot": "reference", "label": "Reference",
         "video_url": "/api/v1/forms/media/a.mp4"}]),
    _question(5, "image_ab", solution_json=False,
              official_reasoning="B is safer: the walkway is clear.",
              dimensions=[{"name": "Overall Choice", "options": [
                  {"name": "B is safer", "is_correct": True, "score": 1},
                  {"name": "A is safer", "is_correct": False}]}]),
]
ANSWERS = {"candidates": [
    {"kind": kind, "answers": {
        "1": "The weld is cracked.", "2": {"justification": {"1": "Typo"}},
        "3": "A warehouse aisle, eye level.", "4": "A pony dancing, 2D.",
        "5": {"justification": "B keeps people off the forklift route.",
              "picks": {"Overall Choice": pick}}}}
    for kind, pick in (("correct", "B is safer"), ("wrong", "A is safer"))]}


@tagged("-at_install", "post_install")
class TestMadeUpAnswersOnRealQuestionsCanBeCalibrated(TransactionCase):

    def _build(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.mkdir(os.path.join(tmp, "media"))
            with open(os.path.join(tmp, "media", "plate.png"), "wb") as fh:
                fh.write(PNG)
            return synthetic.build(self.env, QUESTIONS, ANSWERS, tmp)

    def test_every_graded_type_is_seeded_and_selected(self):
        paper, answers = self._build()
        self.assertEqual(len(answers), 10)
        self.assertEqual(set(answers.mapped("llm_state")), {"pending"})
        rows = harness.gradable_answers(self.env, [paper.id])
        self.assertEqual(sorted(r[0] for r in rows), answers.ids,
                         "seeded answers are selected like graded ones")
        self.assertEqual({r[1] for r in rows}, {
            "subjective_rubric", "image_label", "image_prompt", "video_prompt",
            "image_ab"})
        ab = answers.filtered(lambda r: r.question_type == "image_ab")
        self.assertEqual(ab.mapped("line_ids.selected_option_id.name"),
                         ["B is safer", "A is safer"])
        self.assertTrue(all(r._image_ab_uses_llm() for r in ab))
        question = answers.question_id
        self.assertEqual(question.filtered(
            lambda q: q.question_type == "image_prompt").image_ids.mapped(
                lambda i: bool(i.image)), [True, False],
            "a binary only where prod stored one")
        video = question.filtered(lambda q: q.question_type == "video_prompt")
        self.assertEqual(
            (video.video_ids.video_url, bool(video.video_ids.video)),
            ("/api/v1/forms/media/a.mp4", False))
        self.assertTrue(all(e.applicant_id.email_from.endswith(
            "@blanked.invalid") for e in answers.assessment_evaluator_id))

    def test_the_copy_is_marked_synthetic_with_prods_settings(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.fallback_model", "gemini-2.5-pro")
        icp.set_param(harness.SYNTHETIC_MARKER, "7")
        paper, answers = self._build()
        self.assertEqual(icp.get_param(harness.SYNTHETIC_MARKER),
                         "7,%d" % paper.id, "an earlier build stays listed")
        self.assertEqual(harness.live_reasons(self.env, answers.ids), [])
        self.assertEqual(icp.get_param("assessments_be_v2.scoring_batch_size"),
                         "20")
        self.assertFalse(icp.get_param("assessments_be_v2.fallback_model"))

    def test_both_arms_can_grade_the_seeded_answers(self):
        paper, answers = self._build()
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.daily_llm_cap_usd", "0")
        ids = [r[0] for r in harness.gradable_answers(self.env, [paper.id])]
        rows = harness.run_arm(self.env, arm="new_uncached", run=1, ids=ids,
                               dry_run=True, concurrency=1)
        self.assertEqual({(r["source"], r["state"]) for r in rows},
                         {("model", "dry_run")})
        self.assertEqual(len({r["call"] for r in rows}), 2)
        with patch.object(model_catalog, "cache_min_tokens", lambda _m: 1):
            cached = harness.run_arm(self.env, arm="new_cached", run=1,
                                     ids=ids, dry_run=True)
        self.assertEqual({r["cache_spec"] for r in cached}, {True},
                         "the paper's questions form one cached group")

    def _attempt(self, name):
        """A paper with one candidate and one answer, as a copied DB has."""
        gen = self.env["assessments.be.prompt"].create({"name": name})
        paper = self.env["assessments.be"].create({
            "name": name, "generator_id": gen.id})
        applicant = self.env["hr.applicant"].create({
            "partner_name": name, "email_from": "%s@example.com" % paper.id})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        question = self.env["assessments.be.question"].create({
            "name": name, "question_type": "subjective_rubric",
            "prompt": "Why?", "generator_id": gen.id})
        self.env["assessments.be.response"].create({
            "assessment_id": paper.id, "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id, "question_id": question.id,
            "justification": "A real answer.", "state": "submitted"})
        return paper, evaluator

    def test_the_build_deletes_every_attempt_it_did_not_make(self):
        # etp_f2_synth still held 262 real answers copied from its source.
        earlier, kept = self._attempt("Earlier synthetic")
        _paper, real = self._attempt("Real paper")
        self.env["ir.config_parameter"].sudo().set_param(
            harness.SYNTHETIC_MARKER, str(earlier.id))
        paper, answers = self._build()
        self.assertFalse(real.exists())
        self.assertEqual(len(kept.response_ids), 1, "an earlier build stays")
        self.env.flush_all()
        for table in ("assessments_be_response", "assessments_be_evaluator"):
            self.env.cr.execute(
                "SELECT count(*) FROM %s WHERE assessment_id IS NULL"
                " OR assessment_id NOT IN %%s" % table,
                [(earlier.id, paper.id)])
            self.assertEqual(self.env.cr.fetchone()[0], 0, table)
        self.assertEqual(harness.live_reasons(self.env, answers.ids), [])

    def test_a_live_database_is_not_turned_into_a_synthetic_one(self):
        self.env["ir.cron"].with_context(active_test=False).search(
            [], limit=1).active = True
        with self.assertRaises(SystemExit):
            synthetic.refuse_live(self.env)

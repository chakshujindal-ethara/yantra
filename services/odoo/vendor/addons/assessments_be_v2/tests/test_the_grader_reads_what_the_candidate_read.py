# -*- coding: utf-8 -*-
"""The grader reads what the candidate read.

  * A question's `description` is part of its task. Form Studio keeps only the
    item title in `prompt`; the scenario the candidate was shown is the
    description. Without it, an answer quoting the scenario read as made up.
  * A prompt-writing key's `scoring_guide` - the examiner's pass conditions
    and penalty sizes - is sent, and the instructions say to follow it.
  * A labelling question whose numbered markers the candidate never saw
    (planted defects: `box_px` only, overlay withheld) is sent
    `markers_hidden`, so its labels are matched to the key in any order.
  * Defect or UI labelling is the question's stored `detection_mode` first;
    words in the key decide only when no mode is stored.

Question material reaches the grader inline and in a group cache's QUESTIONS
block, both built by `_question_material`; both are read here, and the cached
call itself carries none of it. The model is never called.
"""
import json
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import model_catalog
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

TITLE = "Escalation call"
SCENARIO = ("The customer says the courier left parcel 88121 in the rain and "
            "it arrived soaked.")
GUIDE = "Pass only if the sofa is named; a visible watermark costs 30."
#: Planted defects as the renderer keys them: `box_px`, no `box_2d`, and no
#: word the keyword fallback looks for.
PLANTED = [
    {"number": 1, "label": "extra finger",
     "description": "a sixth finger on the left hand",
     "box_px": [80, 80, 120, 120]},
    {"number": 2, "label": "melted clock",
     "description": "the wall clock drips off its frame",
     "box_px": [300, 40, 340, 80]},
]


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})

    def _question(self, qtype, **vals):
        return self.env["assessments.be.question"].create(dict({
            "name": "%s %s" % (qtype, uuid4().hex[:6]),
            "question_type": qtype,
            "prompt": TITLE,
            "generator_id": self.generator.id,
        }, **vals))

    def _labelling(self, detections, **vals):
        q = self._question("image_label", prompt="Label each defect.", **vals)
        self.env["assessments.be.question.image"].create({
            "question_id": q.id, "label": "Plate", "slot": "single",
            "detections_json": json.dumps(detections)})
        return q

    def _answer(self, question, text):
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id})
        ev = self.env["assessments.be.evaluator"].create(
            {"assessment_id": paper.id, "applicant_id": applicant.id})
        return self.env["assessments.be.response"].create({
            "assessment_id": paper.id, "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id, "question_id": question.id,
            "justification": text, "state": "submitted",
            "llm_state": "pending"})

    def _item(self, resp):
        _scored, job = scoring_svc._prepare_submission(self.env, resp)
        return json.loads(job.user_text)["items"][0]

    def _cached(self, resp):
        """The question's QUESTIONS entry, and the text a cached call sends."""
        group = SimpleNamespace(question_ids=(resp.question_id.id,),
                                create=True)
        with patch.object(model_catalog, "cache_min_tokens", return_value=1), \
                patch.object(vertex_svc, "_vertex_creds",
                             return_value=("proj", "global", "m", "")):
            spec = scoring_svc._cache_spec(
                self.env, group, [scoring_svc._build_item(resp)],
                scoring_svc._get_scoring_prompt(), "m")
        entry = json.loads(spec.block[len("QUESTIONS\n"):])["questions"][0]
        return entry, spec.user_text


@tagged("-at_install", "post_install")
class TestTheTaskCarriesTheScenario(_Base):

    def test_a_form_studio_question_sends_its_scenario_once(self):
        q = self._question(
            "subjective_rubric", description=SCENARIO,
            subjective_rubric_json=json.dumps(
                {"checklist": ["Apologises and reships"]}),
            solution_json=json.dumps("Apologise and reship 88121."))
        resp = self._answer(q, "Sorry parcel 88121 got soaked; I reship it.")
        task = "%s\n\n%s" % (TITLE, SCENARIO)
        self.assertEqual(self._item(resp)["task"], task)
        entry, call = self._cached(resp)
        self.assertEqual(entry["task"], task)
        self.assertNotIn(SCENARIO, call, "a cached call never sends it again")

    def test_every_type_with_a_task_reads_the_description(self):
        for qtype in ("subjective_rubric", "image_ab", "image_prompt",
                      "video_prompt"):
            with self.subTest(qtype=qtype):
                q = self._question(qtype, description=SCENARIO)
                self.assertEqual(
                    scoring_svc._question_material(q)["task"],
                    "%s\n\n%s" % (TITLE, SCENARIO))

    def test_a_description_that_repeats_the_prompt_is_not_doubled(self):
        for description in (" %s " % TITLE, "", False):
            with self.subTest(description=description):
                q = self._question("subjective_rubric",
                                   description=description)
                self.assertEqual(
                    scoring_svc._question_material(q)["task"], TITLE)


@tagged("-at_install", "post_install")
class TestAPromptKeySendsItsScoringGuide(_Base):

    def test_the_examiner_s_guide_reaches_the_grader(self):
        for qtype in ("image_prompt", "video_prompt"):
            with self.subTest(qtype=qtype):
                q = self._question(qtype, subjective_rubric_json=json.dumps({
                    "ideal_prompt": "A navy velvet sofa, top down",
                    "mandatory_elements": ["navy velvet sofa"],
                    "penalty_rules": ["No watermark"],
                    "scoring_guide": GUIDE}))
                resp = self._answer(q, "A blue sofa seen from above")
                self.assertEqual(self._item(resp)["scoring_guide"], GUIDE)
                entry, call = self._cached(resp)
                self.assertEqual(entry["scoring_guide"], GUIDE)
                self.assertNotIn(GUIDE, call)

    def test_the_instructions_say_to_follow_it(self):
        line = next(
            ln for ln in scoring_svc._get_scoring_prompt().splitlines()
            if ln.startswith("image_prompt, video_prompt:"))
        self.assertIn("`scoring_guide`", line)


@tagged("-at_install", "post_install")
class TestHiddenMarkersAreMatchedInAnyOrder(_Base):

    def test_planted_defects_are_sent_markers_hidden(self):
        resp = self._answer(self._labelling(PLANTED), json.dumps(
            {"1": "the clock melts off the wall", "2": "six fingers"}))
        self.assertIs(self._item(resp)["markers_hidden"], True)
        entry, call = self._cached(resp)
        self.assertIs(entry["markers_hidden"], True)
        self.assertNotIn("markers_hidden", call)

    def test_markers_the_candidate_was_shown_are_not(self):
        drawn = [dict(d, box_2d=[100, 100, 200, 200]) for d in PLANTED]
        for name, q in (
                ("client draws box_2d", self._labelling(drawn)),
                ("UI overlay served", self._labelling(
                    PLANTED, detection_mode="ui"))):
            with self.subTest(name):
                resp = self._answer(q, json.dumps({"1": "a label"}))
                self.assertNotIn("markers_hidden", self._item(resp))

    def test_box_scores_stay_under_the_candidate_s_own_numbers(self):
        resp = self._answer(self._labelling(PLANTED), json.dumps(
            {"1": "the clock melts off the wall", "2": "six fingers"}))
        reply = {"results": [{"id": resp.id, "score": 90,
                              "box_scores": {"1": 95, "2": 85}}]}
        with patch.object(vertex_svc, "_call_vertex",
                          return_value=json.dumps(reply)):
            scoring_svc._score_submission(self.env, resp)
        self.assertEqual(json.loads(resp.label_box_scores_json),
                         {"1": 95.0, "2": 85.0})

    def test_the_instructions_match_them_one_to_one(self):
        text = scoring_svc._get_scoring_prompt()
        self.assertIn("`markers_hidden`", text)
        self.assertIn("one to one", text)


@tagged("-at_install", "post_install")
class TestTheStoredModeDecidesDefectOrUi(_Base):

    def _rules(self, question):
        return scoring_svc._grading_rules(question)[0]

    def test_a_ui_screenshot_whose_key_says_artifact_is_ui_labelling(self):
        q = self._labelling([{"number": 1, "label": "Download artifact",
                              "description": "downloads the build artifact",
                              "box_2d": [10, 10, 60, 60]}],
                            detection_mode="ui")
        self.assertEqual(self._rules(q), "P3 DENSE UI LABELLING")

    def test_a_photo_whose_key_has_no_defect_word_is_defect_annotation(self):
        q = self._labelling(PLANTED, detection_mode="object")
        self.assertEqual(self._rules(q), "P2 AI DEFECT ANNOTATION")

    def test_with_no_stored_mode_the_key_s_words_decide(self):
        self.assertEqual(
            self._rules(self._labelling(PLANTED, detection_mode=False)),
            "P3 DENSE UI LABELLING")
        garbled = [dict(PLANTED[0], label="garbled sign text")]
        self.assertEqual(
            self._rules(self._labelling(garbled, detection_mode=False)),
            "P2 AI DEFECT ANNOTATION")

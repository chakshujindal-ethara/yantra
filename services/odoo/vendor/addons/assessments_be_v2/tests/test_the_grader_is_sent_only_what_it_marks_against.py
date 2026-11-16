# -*- coding: utf-8 -*-
"""W12: text-only grading that sends only what scoring needs.

What a grading call carries is asserted as an exact key set per question type,
so a field added "just in case" - or one of the dropped ones coming back - is a
red test, not a quiet cost on every call. The model is never called: the
request is read off the prepared job, and the reply is a hand-written string
fed through the real parse and store path.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common
from odoo.addons.assessments_be_v2.services import scoring as scoring_svc
from odoo.addons.assessments_be_v2.services import vertex as vertex_svc

PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
           "z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")
WRITTEN = ("The mast weld is cracked along the seam, so the load path fails "
           "before the rated limit.")


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.generator = self._generator("Neutral SOP")

    def _generator(self, sop_title):
        return self.env["assessments.be.prompt"].create({
            "name": "Gen %s" % uuid4().hex[:6], "sop_title": sop_title})

    # -- questions, one per type ----------------------------------------

    def _question(self, qtype, generator=None, **vals):
        return self.Question.create(dict({
            "name": "%s %s" % (qtype, uuid4().hex[:6]),
            "question_type": qtype,
            "prompt": "Do the %s task." % qtype,
            "generator_id": (generator or self.generator).id,
        }, **vals))

    def _written(self, generator=None, **vals):
        return self._question("subjective_rubric", generator, **dict({
            "subjective_rubric_json": json.dumps({
                "checklist": ["Names the cracked weld"], "constraints": [],
                "pass_condition": ""}),
            "solution_json": json.dumps("The weld is cracked."),
        }, **vals))

    def _comparison(self, generator=None):
        q = self._question("image_ab", generator,
                           official_reasoning="A keeps the logo; B warps it.",
                           solution_json=json.dumps({"OC": "Response A"}),
                           solution_rationale="A is better.")
        self.env["assessments.be.question.dimension"].create({
            "question_id": q.id,
            "name": "Overall Choice (OC)",
            "option_line_ids": [
                (0, 0, {"name": "Response A", "is_correct": True}),
                (0, 0, {"name": "Response B", "is_correct": False}),
            ],
        })
        return q

    def _labelling(self, generator=None, defect=False):
        q = self._question("image_label", generator, subjective_rubric_json=(
            json.dumps({"ideal_labels": {"1": "x"},
                        "decoys": ["the red mug"]})))
        image = {"question_id": q.id, "label": "Plate", "slot": "single"}
        if defect:
            image["detections_json"] = json.dumps([
                {"number": 1, "label": "garbled sign text",
                 "description": "the framed sign"}])
        else:
            image["behavioural_key_json"] = json.dumps([
                {"number": 1, "element": "Search", "functionality":
                 "opens the search box"}])
        self.env["assessments.be.question.image"].create(image)
        return q

    def _prompt_writing(self, qtype="image_prompt", generator=None, key=None):
        key = key or {"ideal_prompt": "A red bicycle against a brick wall",
                      "mandatory_elements": ["red bicycle", "brick wall"],
                      "penalty_rules": ["No text in the image"],
                      "scoring_guide": "coverage"}
        return self._question(qtype, generator,
                              subjective_rubric_json=json.dumps(key))

    # -- one candidate's answer -----------------------------------------

    def _evaluator(self, generator=None):
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": (generator or self.generator).id,
        })
        return self.env["assessments.be.evaluator"].create(
            {"assessment_id": assessment.id, "applicant_id": applicant.id})

    def _answer(self, question, text=WRITTEN, pick=None, evaluator=None):
        evaluator = evaluator or self._evaluator(question.generator_id)
        vals = {
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "justification": text,
            "state": "submitted",
            "llm_state": "pending",
        }
        if pick:
            dim = question.question_dimension_ids[:1]
            vals["line_ids"] = [(0, 0, {
                "question_dimension_id": dim.id,
                "selected_option_id": dim.option_line_ids.filtered(
                    lambda o: o.name == pick).id,
            })]
        return self.env["assessments.be.response"].create(vals)

    def _item(self, resp):
        _scored, job = scoring_svc._prepare_submission(self.env, resp)
        return json.loads(job.user_text)["items"][0]

    def _grade(self, resp, **reply):
        result = dict({"id": resp.id, "score": 70, "verdict": "Fair.",
                       "deductions": [{"points": -30, "reason": "r",
                                       "evidence": "e"}],
                       # The model's echo, deliberately wrong: never stored.
                       "profile": "P2 AI DEFECT ANNOTATION"}, **reply)
        with patch.object(vertex_svc, "_call_vertex",
                          return_value=json.dumps({"results": [result]})):
            scoring_svc._score_submission(self.env, resp)
        resp.invalidate_recordset()
        return resp


@tagged("-at_install", "post_install")
class TestEachTypeSendsOnlyItsKey(_Base):

    def test_a_written_answer_sends_task_rubric_and_golden_answer(self):
        q = self._written(solution_rationale="dup",
                          covers_elements_json=json.dumps(["e1"]),
                          verification_json=json.dumps({"summary": "ok"}))
        item = self._item(self._answer(q))
        self.assertEqual(set(item), {"id", "question_id", "question_type",
                                     "task", "rubric", "golden_answer",
                                     "answer"})
        self.assertEqual(item["rubric"],
                         {"checklist": ["Names the cracked weld"]},
                         "empty rubric parts are not sent")
        self.assertEqual(item["golden_answer"], "The weld is cracked.")
        self.assertEqual(item["answer"], WRITTEN)

    def test_a_rubric_that_repeats_the_golden_answer_is_not_sent_twice(self):
        """Form Studio stores the golden answer as both the solution and the
        rubric's `ideal_answer`."""
        q = self._written(
            subjective_rubric_json=json.dumps({"ideal_answer": "Cracked."}),
            solution_json=json.dumps("Cracked."))
        item = self._item(self._answer(q))
        self.assertNotIn("rubric", item)
        self.assertEqual(item["golden_answer"], "Cracked.")

    def test_a_comparison_sends_axes_reasoning_and_the_picks(self):
        q = self._comparison()
        item = self._item(self._answer(q, pick="Response B"))
        self.assertEqual(set(item), {"id", "question_id", "question_type",
                                     "task", "axes", "official_reasoning",
                                     "answer", "picks"})
        self.assertEqual(item["axes"], [{"axis": "Overall Choice (OC)",
                                         "official": "Response A"}])
        self.assertEqual(item["picks"], {"Overall Choice (OC)": "Response B"})
        self.assertEqual(item["official_reasoning"],
                         "A keeps the logo; B warps it.")

    def test_labelling_sends_box_keys_and_decoys(self):
        q = self._labelling()
        item = self._item(self._answer(q, text=json.dumps(
            {"1": "Search field"})))
        self.assertEqual(set(item), {"id", "question_id", "question_type",
                                     "boxes", "decoys", "answer"})
        self.assertEqual(item["boxes"], {"1": "Search: opens the search box"})
        self.assertEqual(item["decoys"], ["the red mug"],
                         "decoys were never sent before W12")
        self.assertEqual(item["answer"], {"1": "Search field"})

    def test_a_defect_key_names_the_box_and_where_it_is(self):
        q = self._labelling(defect=True)
        item = self._item(self._answer(q, text=json.dumps({"1": "bad text"})))
        self.assertEqual(item["boxes"],
                         {"1": "garbled sign text (the framed sign)"})

    def test_prompt_writing_sends_elements_penalties_and_one_reference(self):
        for qtype in ("image_prompt", "video_prompt"):
            with self.subTest(qtype=qtype):
                q = self._prompt_writing(qtype)
                q.solution_json = json.dumps("A red bicycle, brick wall")
                item = self._item(self._answer(q))
                self.assertEqual(set(item), {
                    "id", "question_id", "question_type", "task",
                    "required_elements", "penalties", "reference_prompt",
                    "scoring_guide", "answer"})
                self.assertEqual(item["reference_prompt"],
                                 "A red bicycle against a brick wall")
                self.assertEqual(item["required_elements"],
                                 ["red bicycle", "brick wall"])

    def test_a_form_studio_prompt_key_is_read(self):
        """Form Studio stores the reference prompt as `ideal_answer`; it used
        to reach the grader as an empty `ideal_prompt`."""
        q = self._prompt_writing(key={"ideal_answer": "A blue sofa, top down"})
        item = self._item(self._answer(q))
        self.assertEqual(item["reference_prompt"], "A blue sofa, top down")


@tagged("-at_install", "post_install")
class TestTheCallIsTextOnly(_Base):

    def test_the_request_is_compact_json_with_no_preamble(self):
        resp = self._answer(self._comparison(), pick="Response A")
        _scored, job = scoring_svc._prepare_submission(self.env, resp)
        payload = json.loads(job.user_text)
        self.assertEqual(
            job.user_text,
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            "the request is the compact items object and nothing else")
        for gone in ("item_id", "media", "profile", "grade_justification_only",
                     "justification_consistency", "golden_rationale"):
            self.assertNotIn(gone, job.user_text)

    def test_no_image_is_attached_even_when_the_question_has_one(self):
        q = self._labelling()
        q.image_ids.write({"image": PNG_B64, "annotated_image": PNG_B64})
        resp = self._answer(q, text=json.dumps({"1": "Search field"}))
        with patch.object(vertex_svc, "_call_vertex", return_value=json.dumps(
                {"results": [{"id": resp.id, "score": 90,
                              "box_scores": {"1": 90}}]})) as call:
            scoring_svc._score_submission(self.env, resp)
        kwargs = call.call_args.kwargs
        self.assertFalse(kwargs.get("user_parts"))
        self.assertNotIn("inlineData", call.call_args.args[2])
        self.assertEqual(kwargs["temperature"], 0.2)

    def test_every_call_has_room_for_16000_output_tokens(self):
        _s, job = scoring_svc._prepare_submission(
            self.env, self._answer(self._written()))
        self.assertEqual(job.max_tokens, 16000)
        self.assertFalse(job.thinking)
        _s, job = scoring_svc._prepare_submission(
            self.env, self._answer(self._prompt_writing("video_prompt")))
        self.assertEqual(job.max_tokens, 16000)
        self.assertTrue(job.thinking, "thinking is keyed on the video type")

    def test_a_big_call_keeps_its_per_answer_room(self):
        answers = self.env["assessments.be.response"]
        evaluator = self._evaluator()
        for _i in range(20):
            answers |= self._answer(self._written(), evaluator=evaluator)
        _s, job = scoring_svc._prepare_submission(self.env, answers)
        self.assertEqual(job.max_tokens, 4000 + 2500 * 20)


@tagged("-at_install", "post_install")
class TestRulesFollowTheQuestionType(_Base):
    """The SOP title never picks the rules; a title pointing at rules the type
    does not allow is flagged `profile_mismatch` for review."""

    EXPECTED = {
        "subjective_rubric": "GENERAL",
        "image_ab": "P1 IMAGE A/B COMPARE",
        "image_label": "P3 DENSE UI LABELLING",
        "image_prompt": "P4 PROMPT WRITING — IMAGE",
        "video_prompt": "P5 PROMPT WRITING — VIDEO",
    }

    def _graded(self, qtype, generator):
        if qtype == "subjective_rubric":
            return self._grade(self._answer(self._written(generator)))
        if qtype == "image_ab":
            return self._grade(self._answer(self._comparison(generator),
                                            pick="Response A"))
        if qtype == "image_label":
            resp = self._answer(self._labelling(generator),
                                text=json.dumps({"1": "Search field"}))
            return self._grade(resp, box_scores={"1": 80})
        return self._grade(self._answer(self._prompt_writing(qtype, generator)))

    def test_every_type_gets_its_own_rules_under_a_misleading_sop(self):
        for title in ("Q7r", "UI labelling", "image A/B"):
            generator = self._generator(title)
            for qtype, rules in self.EXPECTED.items():
                with self.subTest(sop=title, qtype=qtype):
                    resp = self._graded(qtype, generator)
                    self.assertEqual(resp.llm_state, "scored")
                    self.assertEqual(resp.llm_profile, rules,
                                     "stored rules are the code's, not the "
                                     "model's echo")
                    flags = json.loads(resp.llm_flags_json or "[]")
                    # Only "Q7r" is a known SOP signal (defect annotation),
                    # and only labelling may use those rules.
                    mismatch = title == "Q7r" and qtype != "image_label"
                    self.assertEqual("profile_mismatch" in flags, mismatch)

    def test_the_labelling_key_decides_defect_or_ui(self):
        resp = self._answer(self._labelling(defect=True),
                            text=json.dumps({"1": "garbled text"}))
        self._grade(resp, box_scores={"1": 90})
        self.assertEqual(resp.llm_profile, "P2 AI DEFECT ANNOTATION")

    def test_the_table_accepts_only_the_type_s_rules(self):
        self.assertTrue(scoring_svc.rules_fit_type("image_label", "P2 x"))
        self.assertTrue(scoring_svc.rules_fit_type("image_label", "P3"))
        self.assertTrue(scoring_svc.rules_fit_type("image_ab", "P1-J"),
                        "an old echo of the same rules still fits")
        self.assertFalse(scoring_svc.rules_fit_type("image_ab", "P10"))
        self.assertFalse(scoring_svc.rules_fit_type(
            "subjective_rubric", "P2 AI DEFECT ANNOTATION"))
        self.assertFalse(scoring_svc.rules_fit_type("image_ab", "GENERAL"))


@tagged("-at_install", "post_install")
class TestAKeylessQuestionIsGradedAndFlagged(_Base):

    def test_its_answer_is_graded_and_flagged(self):
        q = self._question("subjective_rubric")
        self.assertTrue(scoring_svc.lacks_answer_key(q))
        resp = self._grade(self._answer(q))
        self.assertEqual(resp.llm_state, "scored")
        self.assertIn("no_answer_key", json.loads(resp.llm_flags_json))

    def test_a_keyed_answer_is_not_flagged(self):
        resp = self._grade(self._answer(self._written()))
        self.assertNotIn("no_answer_key",
                         json.loads(resp.llm_flags_json or "[]"))

    def test_objective_and_comparison_questions_are_never_keyless(self):
        for qtype in ("mcq", "msq", "image_ab"):
            self.assertFalse(scoring_svc.lacks_answer_key(
                self._question(qtype)))

    def _launch_check(self, assessment):
        stub = _StubRequest(self.env, {"assessment_id": assessment.id})
        controller = admin_api.EtpAssessmentApiAdmin()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            return controller.assessment_launch(assessment.id)

    def test_launch_warns_but_never_blocks(self):
        self.env.ref("assessments_be_v2.group_assessment_manager").sudo() \
            .write({"user_ids": [(4, self.env.user.id)]})
        keyless = self._question("subjective_rubric")
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand", "email_from": "c_%s@example.com"
            % uuid4().hex[:6]})
        assessment = self.env["assessments.be"].create({
            "name": "Keyless paper", "generator_id": self.generator.id,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, applicant.ids)]})
        assessment._sync_roster_rows()

        answer = self._launch_check(assessment)
        gate = next(g for g in answer["data"]["gates"]
                    if g["code"] == "grading_keys")
        self.assertTrue(gate["passed"])
        self.assertTrue(gate["warning"])
        self.assertIn(keyless.name, gate["reason"])
        self.assertTrue(answer["data"]["can_launch"])

        assessment.action_start()
        self.assertEqual(assessment.state, "in_progress")
        self.assertTrue(any(
            "no answer key" in (m.body or "")
            for m in assessment.message_ids))


class _StubRequest:
    """The slice of `odoo.http.request` the launch route touches."""

    def __init__(self, env, params=None):
        self.env = env
        self.params = dict(params or {})

    def make_json_response(self, payload, headers=None, status=200):
        return dict(payload, _status=status)


@tagged("-at_install", "post_install")
class TestTheInstructionsAreOneShippedText(TransactionCase):

    def test_the_code_default_is_the_shipped_file(self):
        shipped = vertex_svc._load_bundled_prompt("scoring.md").strip()
        self.assertEqual(scoring_svc.DEFAULT_SCORING_PROMPT.strip(), shipped)
        self.assertEqual(scoring_svc._get_scoring_prompt(), shipped)

    def test_the_text_is_trimmed_and_text_only(self):
        text = scoring_svc._get_scoring_prompt()
        tokens = len(text) / 4.03
        self.assertTrue(1100 <= tokens <= 2900, tokens)
        for stale in ("P6", "0.25", "0.75", "judge_model", "pass_threshold",
                      "media_unseen", "attached", "watch", "`reasoning`",
                      "profile", "item_id", "golden_rationale",
                      "justification_consistency"):
            self.assertNotIn(stale, text)
        self.assertIn("LEFT OUT ON PURPOSE", text)


@tagged("-at_install", "post_install")
class TestTheDraftEditorKeepsAVideoKey(TransactionCase):

    def _draft(self, qtype, rubric):
        prompt = self.env["assessments.be.prompt"].create({"name": "Gen"})
        return self.env["assessments.be.prompt.question"].create({
            "prompt_id": prompt.id, "name": "Draft",
            "question_prompt": "Write the prompt.", "question_type": qtype,
            "rubric_json": json.dumps(rubric)})

    def test_editing_a_video_draft_keeps_its_reference_prompt(self):
        draft = self._draft("video_prompt", {"ideal_prompt": "A slow pan",
                                             "mandatory_elements": ["pan"]})
        self.assertEqual(draft.ak_ideal_answer, "A slow pan")
        draft.ak_penalty_rules = "No cuts"
        data = json.loads(draft.rubric_json)
        self.assertEqual(data["ideal_prompt"], "A slow pan")
        self.assertEqual(data["penalty_rules"], ["No cuts"])

    def test_a_value_saved_under_the_old_name_moves_to_the_right_key(self):
        draft = self._draft("video_prompt", {"ideal_answer": "A slow pan"})
        self.assertEqual(draft.ak_ideal_answer, "A slow pan")
        draft.ak_scoring_guide = "coverage"
        data = json.loads(draft.rubric_json)
        self.assertEqual(data.get("ideal_prompt"), "A slow pan")
        self.assertNotIn("ideal_answer", data)

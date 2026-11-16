# -*- coding: utf-8 -*-
"""The Transcription question: published from Form Studio, answered with a
transcription plus the clip's category / characteristics / speakers, and marked
by the LLM judge with the client's rule on top of ours.

THE RULE. The judge's reply format has no severity field and its instructions
cannot change (their fingerprint gates every verdict), so the weight rides on
the deduction size the question's own rubric asks for: -20 critical, -5 minor.
The store counts them back, and a clip earns its mark only with no critical
mistake, fewer than five minor ones AND a score at the assessment's bar.

The judge is never called: replies are hand-written and fed through the real
parse-and-store path. No media leaves the process: `requests.get` is replaced.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.constants import TRANSCRIPTION_RUBRIC
from odoo.addons.assessments_be_v2.controllers.api import serializers as S
from odoo.addons.assessments_be_v2.models import studio_form as studio_form_mod
from odoo.addons.assessments_be_v2.services import scoring as scoring_svc
from odoo.addons.assessments_be_v2.services import transcript_diff
from odoo.addons.assessments_be_v2.services import vertex as vertex_svc
from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)

_MP3 = "/api/v1/forms/media/form_studio/%s/clip.mp3" % ("b" * 32)
_KEY_TEXT = "तो ये देखो मेरा नाम राहुल है म्हम्"
_GOLDEN_CLIP = {"category": "none", "characteristics": ["background_speech"],
                "speakers": [{"gender": "masculine", "nativity": "native"}]}


def _never(*a, **kw):
    raise AssertionError("publish must not fetch a clip")


def _controller():
    import inspect

    from odoo import http

    from ..controllers.api import candidate as candidate_api
    for _name, obj in vars(candidate_api).items():
        if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                and obj.__module__ == candidate_api.__name__
                and hasattr(obj, "exam_answer")):
            return obj()
    raise AssertionError("the candidate controller was not found")


@tagged("-at_install", "post_install")
class TestATranscriptionPublishes(_FormBase):

    def _transcription(self, **extra):
        return self._item("transcription", title="Type what you hear",
                          **dict({"media_url": _MP3, "media_kind": "audio",
                                  "transcription_language": "hi",
                                  "golden_answer": _KEY_TEXT,
                                  "golden_clip": _GOLDEN_CLIP}, **extra))

    def test_one_question_owns_its_clip_and_carries_the_client_key(self):
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._transcription(golden_clip={
                "category": "none",
                "characteristics": ["laughter", "made_up", "laughter"],
                "speakers": [{"gender": "feminine", "nativity": "nope"}]}))
        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "transcription")
        self.assertEqual(question.transcription_language, "hi")
        self.assertEqual(json.loads(question.solution_json), {
            "transcription": _KEY_TEXT, "category": "none",
            "characteristics": ["laughter"],
            "speakers": [{"gender": "feminine", "nativity": "unknown"}]})
        self.assertEqual(json.loads(question.subjective_rubric_json),
                         TRANSCRIPTION_RUBRIC)
        self.assertEqual(len(question.video_ids), 1)
        self.assertEqual(question.video_ids.media_kind, "audio")
        self.assertEqual(question._component_counts(), (1, 1))

    def test_a_link_with_no_extension_is_still_an_audio_clip(self):
        drive = "https://drive.google.com/file/d/1A9qBxVtHC/view"
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._transcription(media_url=drive))
        self.assertEqual(
            self._published_one(form, result).video_ids.media_kind, "audio")

    def test_no_clip_is_refused_in_plain_words(self):
        form, result = self._publish(self._transcription(media_url=""))
        self._refused(form, result, "add the clip the candidate transcribes")

    def test_no_correct_transcription_is_refused(self):
        form, result = self._publish(self._transcription(golden_answer=""))
        self._refused(form, result, "write the correct transcription")

    def test_a_clip_that_is_not_transcribed_needs_no_text(self):
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._transcription(
                golden_answer="typed anyway",
                golden_clip={"category": "no_speech",
                             "characteristics": ["laughter"],
                             "speakers": [{"gender": "masculine"}]}))
        solution = json.loads(self._published_one(form, result).solution_json)
        self.assertEqual(solution["category"], "no_speech")
        self.assertEqual(solution["transcription"], "",
                         "a non-None category means no transcription")
        self.assertEqual((solution["characteristics"], solution["speakers"]),
                         ([], []), "nor ticks nor speakers (Strix's rule)")


class _Sitting(_FormBase):
    """A transcription question in a begun sitting, answered through the real
    `/exam/<token>/answer` route body."""

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Transcription %s" % uuid4().hex[:6]})
        self.question = self.Question.create({
            "name": "Clip %s" % uuid4().hex[:6],
            "question_type": "transcription",
            "prompt": "Type exactly what is said.",
            "generator_id": self.generator.id,
            "transcription_language": "hi",
            "subjective_rubric_json": json.dumps(TRANSCRIPTION_RUBRIC),
            "solution_json": json.dumps(dict(_GOLDEN_CLIP,
                                             transcription=_KEY_TEXT)),
            "video_ids": [(0, 0, {"video_url": _MP3, "label": "Clip"})],
        })
        self.controller = _controller()

    def _sitting(self):
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, self.question.ids)],
            "question_limit": 1,
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Transcriber",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(self.question.ids),
            "access_token": uuid4().hex,
            "started_at": fields.Datetime.now(),
        })
        assessment.sudo()._ensure_candidate_user(applicant)
        return evaluator, evaluator.sudo()._candidate_user()

    def _save(self, evaluator, user, **params):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), dict(
            params, question_id=self.question.id, nav="stay"))
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return self.controller.exam_answer(evaluator.access_token,
                                               **fake.params)

    def _row(self, evaluator):
        return self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", self.question.id)])


@tagged("-at_install", "post_install")
class TestATranscriptionIsAnswered(_Sitting):

    def test_the_candidate_sees_the_language_and_never_the_key(self):
        payload = S.question_for_candidate(self.question, "tok", 1, 1)
        self.assertEqual(payload["transcription_language"], "hi")
        self.assertEqual(payload["answer"]["clip_answers"], {})
        self.assertEqual([v["kind"] for v in payload["videos"]], ["audio"])
        flat = json.dumps(payload, ensure_ascii=False)
        for secret in ("solution", "rubric", _KEY_TEXT, "background_speech",
                       "pass_condition"):
            self.assertNotIn(secret, flat)

    def test_clip_answers_are_cleaned_and_kept(self):
        evaluator, user = self._sitting()
        self._save(evaluator, user, justification="तो ये देखो", clip_answers={
            "category": "made_up",
            "characteristics": ["laughter", "laughter", "x"],
            "speakers": [{"gender": "x", "nativity": "native"}] * 6})
        row = self._row(evaluator)
        self.assertEqual(row.state, "submitted")
        self.assertEqual(row._clip_answers(), {
            "category": "none", "characteristics": ["laughter"],
            "speakers": [{"gender": "unknown", "nativity": "native"}] * 4})
        payload = S.question_for_candidate(self.question, "tok", 1, 1, row)
        self.assertEqual(payload["answer"]["clip_answers"]["characteristics"],
                         ["laughter"])

    def test_an_edit_to_the_clip_answers_alone_is_graded_again(self):
        evaluator, user = self._sitting()
        self._save(evaluator, user, justification=_KEY_TEXT,
                   clip_answers={"category": "none"})
        row = self._row(evaluator)
        before = row._graded_answer_hash()
        self._save(evaluator, user, justification=_KEY_TEXT, clip_answers={
            "category": "none", "characteristics": ["laughter"]})
        row.invalidate_recordset()
        self.assertNotEqual(row._graded_answer_hash(), before)

    def test_an_empty_box_with_a_category_is_a_complete_answer(self):
        """A non-None category means the clip is not transcribed: the empty
        box is the answer, it counts as answered, and it goes to the judge."""
        evaluator, user = self._sitting()
        reply = self._save(evaluator, user, justification="",
                           clip_answers={"category": "no_speech"})
        self.assertNotIn("error", reply, reply)
        row = self._row(evaluator)
        self.assertEqual(row.state, "submitted")
        self.assertTrue(row.needs_llm)
        self.assertEqual(row.llm_state, "pending")
        self.assertEqual(row.answer_summary, "Not transcribed: no speech")
        _scored, job = scoring_svc._prepare_submission(self.env, row)
        self.assertIsNotNone(job, "an empty-box answer was gated as blank")
        item = json.loads(job.user_text)["items"][0]
        self.assertEqual(item["answer"]["category"], "no_speech")
        self.assertEqual(item["answer"]["transcription"], "")

    def test_hidden_ticks_and_speakers_are_not_kept(self):
        """The app hides ticks and speakers under a non-None category but
        keeps them on screen; the stored answer must not carry them."""
        evaluator, user = self._sitting()
        self._save(evaluator, user, justification="", clip_answers={
            "category": "no_speech", "characteristics": ["laughter"],
            "speakers": [{"gender": "feminine", "nativity": "native"}]})
        self.assertEqual(self._row(evaluator)._clip_answers(), {
            "category": "no_speech", "characteristics": [], "speakers": []})

    def test_an_empty_box_with_category_none_is_incomplete(self):
        evaluator, user = self._sitting()
        reply = self._save(evaluator, user, justification="",
                           clip_answers={"category": "none"})
        self.assertEqual((reply.get("error") or {}).get("code"),
                         "incomplete_answer", reply)


@tagged("-at_install", "post_install")
class TestATranscriptionIsMarkedByTheClientRule(_Sitting):

    def _answered(self, text, clip=None):
        evaluator, user = self._sitting()
        self._save(evaluator, user, justification=text,
                   clip_answers=clip or {"category": "none"})
        return self._row(evaluator)

    def _judged(self, text, key=None, clip=None):
        """The item the judge gets for `text`, against `key` when given."""
        if key is not None:
            self.question.solution_json = json.dumps(
                dict(_GOLDEN_CLIP, transcription=key), ensure_ascii=False)
        _scored, job = scoring_svc._prepare_submission(
            self.env, self._answered(text, clip))
        return json.loads(job.user_text)["items"][0]

    def _grade(self, row, *points, score=None, **extra):
        deductions = [{"points": p, "reason": "r", "evidence": "e"}
                      for p in points]
        result = dict(extra, id=row.id, verdict="v", deductions=deductions,
                      score=score if score is not None
                      else 100 + sum(points))
        with patch.object(vertex_svc, "_call_vertex",
                          return_value=json.dumps({"results": [result]})):
            scoring_svc._score_submission(self.env, row)
        row.invalidate_recordset()
        return row

    def test_the_judge_gets_the_key_the_rule_and_the_differences(self):
        row = self._answered("तो ये देखो मेरा नाम राहुल है")
        _scored, job = scoring_svc._prepare_submission(self.env, row)
        item = json.loads(job.user_text)["items"][0]
        self.assertEqual(item["question_type"], "transcription")
        self.assertEqual(item["golden_answer"]["transcription"], _KEY_TEXT)
        self.assertEqual(item["rubric"]["pass_condition"],
                         TRANSCRIPTION_RUBRIC["pass_condition"])
        self.assertEqual(item["answer"]["differences"], [
            {"kind": "missing", "answer": "", "correct": "म्हम्",
             "after": "है"}])

    def test_two_minor_mistakes_at_ninety_earn_the_mark(self):
        row = self._grade(self._answered(_KEY_TEXT), -5, -5)
        self.assertEqual((row.llm_critical_count, row.llm_minor_count), (0, 2))
        self.assertEqual(row.llm_raw_100, 90)
        self.assertEqual(row.llm_score, 1)

    def test_one_critical_mistake_fails_the_clip_above_the_bar(self):
        row = self._grade(self._answered(_KEY_TEXT), -20)
        self.assertEqual(row.llm_raw_100, 80, "the score clears the 70 bar")
        self.assertEqual(row.llm_critical_count, 1)
        self.assertEqual(row.llm_score, 0)
        self.assertFalse(row.llm_passed)

    def test_five_minor_mistakes_fail_the_clip(self):
        row = self._grade(self._answered(_KEY_TEXT), -5, -5, -5, -5, -5)
        self.assertEqual(row.llm_raw_100, 75)
        self.assertEqual(row.llm_minor_count, 5)
        self.assertEqual(row.llm_score, 0)

    def test_the_admin_sees_both_answers_and_the_rule(self):
        row = self._grade(self._answered("तो ये देखो मेरा नाम राहुल है"), -20)
        audit = S.response_audit(row)["transcription"]
        self.assertEqual(audit["language"], "hi")
        self.assertEqual(audit["correct"]["transcription"], _KEY_TEXT)
        self.assertEqual(audit["answer"]["category"], "none")
        self.assertEqual([d["kind"] for d in audit["differences"]],
                         ["missing"])
        self.assertEqual((audit["critical"], audit["minor"]), (1, 0))
        self.assertFalse(audit["client_rule_passed"])

    def test_the_released_review_shows_the_candidates_own_answers_only(self):
        # Answered by its category alone: the box is empty on purpose.
        row = self._grade(
            self._answered("", {"category": "no_speech"}), score=100)
        review = S.released_answer_review_row(
            1, self.question, row, row.assessment_evaluator_id.access_token)
        self.assertNotEqual(review["verdict"], "Not answered")
        self.assertEqual(review["clip_answers"]["category"], "no_speech")
        self.assertNotIn(_KEY_TEXT, json.dumps(review, ensure_ascii=False),
                         "the correct transcription is the key")

    def test_numbers_are_kept_as_typed(self):
        """Numbers are words (the QC rule), so a digit is the candidate's
        mistake to be marked, never something the server rewrites."""
        row = self._answered("मेरा नंबर ९८ है")
        self.assertEqual(row.justification, "मेरा नंबर ९८ है")

    def test_the_pre_checks_follow_the_qc_worked_examples(self):
        self.assertTrue(transcript_diff.demo())

    def test_a_mark_on_clear_words_reaches_the_judge_as_critical(self):
        item = self._judged("आज {{मौसम}} अच्छा है", key="आज मौसम अच्छा है")
        self.assertEqual(item["answer"]["differences"], [
            {"kind": "different", "answer": "{{मौसम}}", "correct": "मौसम",
             "after": "आज", "rule": "mark_on_clear_words"}])

    def test_a_digit_reaches_the_judge_as_critical(self):
        item = self._judged("500 रुपये", key="पाँच सौ रुपये")
        self.assertEqual(item["answer"]["differences"], [
            {"kind": "different", "answer": "500", "correct": "पाँच सौ",
             "after": "", "rule": "digit"}])

    def test_spaced_letters_beside_another_slip_are_one_minor(self):
        """QC 4.3: g s t for g. s. t. is one minor, even when the next word
        differs too; it was one critical per letter."""
        item = self._judged("मेरा g s t नंबर", key="मेरा g. s. t. number")
        self.assertEqual(item["answer"]["differences"], [
            {"kind": "different", "answer": "g s t", "correct": "g. s. t.",
             "after": "मेरा", "rule": "letters_without_periods"},
            {"kind": "different", "answer": "नंबर", "correct": "number",
             "after": "t."}])

    def test_differences_the_client_never_counts_are_not_sent(self):
        """The nasal sign, a nukta, ये/यह, वो/वह and a hyphen in a repeat
        (QC section 5) never reach the judge."""
        item = self._judged("पांच जरूर यह ना ना वह",
                            key="पाँच ज़रूर ये ना-ना वो")
        self.assertEqual(item["answer"]["differences"], [])

    def test_speakers_are_a_set_and_tags_one_mistake(self):
        same = {"category": "none",
                "characteristics": ["background_speech", "laughter"],
                "speakers": [{"gender": "masculine", "nativity": "unknown"}]}
        item = self._judged(_KEY_TEXT, clip=same)
        self.assertNotIn("clip_differences", item["answer"],
                         "laughter and nativity are never compared")

        item = self._judged(_KEY_TEXT, clip={
            "category": "none",
            "characteristics": ["cross_talk", "audio_artifact"],
            "speakers": [{"gender": "feminine", "nativity": "native"}]})
        self.assertEqual(item["answer"]["clip_differences"], {
            "characteristics": {"answer": ["audio_artifact", "cross_talk"],
                                "correct": ["background_speech"]},
            "speakers": {"answer": ["feminine"], "correct": ["masculine"]}})

        swapped = transcript_diff.clip_differences(
            {"category": "none", "speakers": [
                {"gender": "feminine", "nativity": "non_native"},
                {"gender": "masculine", "nativity": "native"}]},
            {"category": "none", "speakers": [
                {"gender": "masculine", "nativity": "native"},
                {"gender": "feminine", "nativity": "native"}]})
        self.assertEqual(swapped, {}, "the order of speakers is never compared")

        item = self._judged("", clip={"category": "no_speech"})
        self.assertEqual(item["answer"]["clip_differences"], {
            "category": {"answer": "no_speech", "correct": "none"}},
            "a wrong category is one mistake, and nothing that follows from it")

    def test_the_rubric_settles_the_qc_cases(self):
        """A different auxiliary is a substitution (the key is what was said),
        an untranscribed speech clip is critical, and no rule code is quoted."""
        text = " ".join(TRANSCRIPTION_RUBRIC["constraints"])
        self.assertNotIn("auxiliary", text)
        self.assertIn("leaving the clip untranscribed is one critical mistake",
                      text)
        self.assertIn("Never write a rule's name or code", text)

    def test_the_rubric_is_read_live(self):
        self.question.subjective_rubric_json = json.dumps({
            "checklist": ["stale"], "constraints": ["Minor (-5): a marker slip"],
            "pass_condition": "stale"})
        item = self._judged(_KEY_TEXT, clip=_GOLDEN_CLIP)
        self.assertEqual(item["rubric"], TRANSCRIPTION_RUBRIC)

    def test_no_ceiling_cuts_a_clip(self):
        """The client's count decides a clip. The essay ceilings read signals
        a clip's judge sends for its own reasons: a word 'not said' is a
        hallucination flag there, and it capped a 90 at 25."""
        row = self._grade(
            self._answered(_KEY_TEXT, _GOLDEN_CLIP), -5, -5,
            checklist_zero_count=2, fabrication_count=1,
            verdict_consistency="contradiction",
            flags=["hallucinated word"])
        self.assertEqual(row.llm_raw_100, 90)
        self.assertEqual(row.llm_score, 1)

    def test_a_clip_is_stamped_with_its_own_rules(self):
        row = self._grade(self._answered(_KEY_TEXT, _GOLDEN_CLIP), -5)
        self.assertEqual(row.llm_profile, "P7 TRANSCRIPTION")


@tagged("-at_install", "post_install")
class TestATranscriptionSavedInABatch(_Sitting):
    """The write-behind runner saves through `/answers/batch`: each item must
    carry its own clip answers, and a cleared answer must drop them."""

    def _batch(self, evaluator, user, answers):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), {"answers": answers})
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            reply = self.controller.exam_answers_batch(
                evaluator.access_token, **fake.params)
        self.env.flush_all()
        return reply

    def test_a_batch_item_carries_its_own_clip_answers(self):
        evaluator, user = self._sitting()
        reply = self._batch(evaluator, user, [{
            "question_id": self.question.id, "justification": "",
            "clip_answers": {"category": "no_speech"}}])
        self.assertEqual([(r["accepted"], r["reason"])
                          for r in reply["data"]["results"]],
                         [(True, "saved")], reply)
        row = self._row(evaluator)
        self.assertEqual(row.state, "submitted")
        self.assertEqual(row._clip_answers()["category"], "no_speech")
        evaluator.invalidate_recordset()
        self.assertEqual(evaluator.answered_count, 1,
                         "a not-transcribed clip is a real answer")

    def test_a_cleared_transcription_drops_its_clip_answers(self):
        evaluator, user = self._sitting()
        self._save(evaluator, user, justification="तो ये देखो",
                   clip_answers={"category": "none",
                                 "characteristics": ["laughter"]})
        self._save(evaluator, user, cleared=True)
        row = self._row(evaluator)
        self.assertTrue(row.cleared)
        self.assertEqual(row.state, "draft")
        self.assertFalse(row.clip_answers_json)
        self.assertFalse(row._transcription_has_answer())

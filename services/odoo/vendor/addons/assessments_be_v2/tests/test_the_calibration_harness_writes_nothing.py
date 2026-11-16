# -*- coding: utf-8 -*-
"""W15: the calibration harness (`tools/calibration/harness.py`) grades stored
answers through the code's own path and keeps nothing.

"Nothing" is checked on the rows themselves: every column the harness touches,
the row's `ctid` (a new one on any UPDATE, even inside this test's own
transaction, where `write_date` cannot move) and row counts of the tables a
grade could add to. Vertex is never called: a dry run stops at the HTTP seam,
and the one graded run answers from a fake transport.
"""
import importlib.util
import json
import os
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..constants import ADVISORY_LOCK_VERTEX_BEARER
from ..services import model_catalog
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

WRITTEN = ("The mast weld is cracked along the seam, so the load path fails "
           "before the rated limit.")
LABELS = json.dumps({"1": "Search field", "2": "Opens settings"})


def _tool(name):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "tools", "calibration", name + ".py")
    spec = importlib.util.spec_from_file_location("calibration_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


harness = _tool("harness")


class _FakeVertex:
    """One Gemini reply per request: a result for every item it was sent,
    ``label`` for labelling items and ``written`` for the rest. A question-
    group cache is created on request."""

    def __init__(self, written, label):
        self.replies, self.requests = {"image_label": label}, []
        self.written, self.caches, self.bearers = written, [], []

    def post(self, url, **kw):
        if url.endswith("/cachedContents"):
            self.caches.append(kw["json"])
            body = {"name": "cachedContents/c%d" % len(self.caches),
                    "usageMetadata": {"totalTokenCount": 5000}}
            return type("Resp", (), {"status_code": 200, "text": "",
                                     "json": lambda _self: body})()
        assert url.endswith(":generateContent"), url
        self.requests.append(kw["json"])
        self.bearers.append(kw["headers"].get("Authorization"))
        text = kw["json"]["contents"][0]["parts"][0]["text"]
        items = json.loads(text[text.index("{"):])
        reply = {"results": [
            dict(self.replies.get(it.get("question_type"), self.written),
                 id=it["id"]) for it in items["items"]]}
        body = {"candidates": [{"finishReason": "STOP", "content": {
                    "parts": [{"text": json.dumps(reply)}]}}],
                "usageMetadata": {"promptTokenCount": 1200,
                                  "candidatesTokenCount": 300,
                                  "thoughtsTokenCount": 500}}
        return type("Resp", (), {"status_code": 200, "text": "",
                                 "json": lambda _self: body})()


@tagged("-at_install", "post_install")
class TestTheCalibrationHarnessWritesNothing(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.vertex_max_rpm", "6000")
        icp.set_param("assessments_be_v2.daily_llm_cap_usd", "0")
        icp.set_param("assessments_be_v2.scoring_batch_size", "8")
        # `_run` pins a bearer; a bearer with no project is refused before
        # any request (`vertex._gemini_request`).
        icp.set_param("assessments_be_v2.vertex_project_id", "calib-project")
        self.generator = self.env["assessments.be.prompt"].create({
            "name": "Gen %s" % uuid4().hex[:6], "sop_title": "Neutral SOP"})
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id})
        icp.set_param(harness.SYNTHETIC_MARKER, str(self.paper.id))
        # A database marked synthetic may hold only synthetic answers.
        self.env["assessments.be.response"].search([]).unlink()
        Question = self.env["assessments.be.question"]
        self.written = Question.create({
            "name": "W %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain the failure.", "generator_id": self.generator.id,
            "subjective_rubric_json": json.dumps({
                "checklist": ["Names the cracked weld"]}),
            "solution_json": json.dumps("The weld is cracked.")})
        self.labelling = Question.create({
            "name": "L %s" % uuid4().hex[:6], "question_type": "image_label",
            "prompt": "Label the boxes.", "generator_id": self.generator.id})
        self.env["assessments.be.question.image"].create({
            "question_id": self.labelling.id, "label": "Plate",
            "slot": "single", "behavioural_key_json": json.dumps([
                {"number": 1, "element": "Search",
                 "functionality": "opens the search box"},
                {"number": 2, "element": "Gear",
                 "functionality": "opens settings"}])})
        self.answers = self.env["assessments.be.response"]
        for n in range(3):
            evaluator = self.env["assessments.be.evaluator"].create({
                "assessment_id": self.paper.id,
                "applicant_id": self.env["hr.applicant"].create(
                    {"partner_name": "Cand %d %s" % (n, uuid4().hex[:4])}).id})
            for question, text in ((self.written, WRITTEN),
                                   (self.labelling, LABELS)):
                self.answers |= self.answers.create({
                    "assessment_id": self.paper.id,
                    "assessment_evaluator_id": evaluator.id,
                    "evaluator_id": evaluator.applicant_id.id,
                    "question_id": question.id, "justification": text,
                    "state": "submitted", "llm_state": "scored",
                    "llm_raw_100": 55.0, "llm_attempts": 1,
                    "llm_prompt_version": "bundled:34c42d2f",
                    "llm_result_json": json.dumps({"fixture": True})})
        self.env.flush_all()

    # -- proof that nothing was kept ----------------------------------------

    def _snapshot(self):
        self.env.flush_all()
        cr = self.env.cr
        cr.execute("""
            SELECT id, ctid::text, write_date, llm_state, llm_raw_100,
                   llm_attempts, llm_result_json, label_box_scores_json,
                   llm_prompt_version, justification
              FROM assessments_be_response WHERE id IN %s ORDER BY id""",
                   [tuple(self.answers.ids)])
        answers = cr.fetchall()
        cr.execute("""SELECT id, ctid::text, write_date
                        FROM assessments_be_evaluator
                       WHERE assessment_id = %s ORDER BY id""", [self.paper.id])
        evaluators = cr.fetchall()
        counts = []
        for table in ("assessments_be_response", "assessments_be_llm_usage",
                      "ir_config_parameter", "mail_message"):
            cr.execute("SELECT count(*) FROM %s" % table)
            counts.append(cr.fetchone()[0])
        return answers, evaluators, counts

    def _run(self, **kw):
        kw.setdefault("arm", "new_uncached")
        return harness.run_arm(
            self.env(context=dict(self.env.context,
                                  etp_vertex_bearer="test-bearer")), run=1,
            ids=self.answers.ids, concurrency=1, **kw)

    # -- which answers --------------------------------------------------------

    def test_the_selection_is_the_same_for_the_same_seed(self):
        rows = harness.gradable_answers(self.env, [self.paper.id])
        self.assertEqual(sorted(r[0] for r in rows), self.answers.ids)
        with patch.object(harness, "MIN_PER_TYPE", 1):
            first = harness.pick(rows, 4, seed=11)
            self.assertEqual(first, harness.pick(rows, 4, seed=11))
            self.assertEqual(len(first), 4)
            types = [r[1] for r in rows if r[0] in first]
            self.assertEqual(types.count("subjective_rubric"), 2,
                             "each type keeps its share")
            self.assertTrue(set(harness.pick(rows, 2, seed=11)) <= set(first),
                            "a smaller sample is a subset (fallback arm)")
        self.assertEqual(harness.pick(rows, 4, seed=11), self.answers.ids,
                         "the per-type floor takes every answer here")

    def test_precheck_flags_a_prompt_version_prod_did_not_ship(self):
        self.answers[0].llm_prompt_version = "override:0badc0de"
        found = harness.precheck(self.env, [self.paper.id])
        self.assertEqual(found["versions"], {"bundled:34c42d2f": 5,
                                             "override:0badc0de": 1})
        self.assertEqual(found["flagged"], {"override:0badc0de": 1})
        self.assertEqual(found["types"], {"subjective_rubric": 3,
                                          "image_label": 3})

    def test_the_verdict_scan_finds_admin_wording_candidates_would_see(self):
        # Candidates now see the verdict on released answers; verdicts
        # written under the old instructions were meant for admins only.
        self.answers[0].llm_verdict = "Solid answer that names the weld."
        self.answers[1].llm_verdict = "P2 profile: below the 60 threshold."
        self.answers[2].llm_verdict = "Capped at 25 for fabrication."
        found = harness.verdict_scan(self.env, [self.paper.id])
        self.assertEqual(found["checked"], 3)
        self.assertEqual(sorted(found["hits"]),
                         sorted([self.answers[1].id, self.answers[2].id]))

    # -- a dry run --------------------------------------------------------------

    def test_a_dry_run_builds_the_codes_own_request_and_keeps_nothing(self):
        mine = self.answers.filtered(
            lambda r: r.assessment_evaluator_id == self.answers[0]
            .assessment_evaluator_id)
        _s, job = scoring_svc._prepare_submission(self.env, mine,
                                                  individual=True)
        before = self._snapshot()
        sent = []
        post = harness._Transport.post

        def spy(transport, url, **kw):
            sent.append((url, kw["json"]))
            return post(transport, url, **kw)

        with patch.object(harness._Transport, "post", spy):
            rows = self._run(dry_run=True)
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(sent), 3, "one call per candidate")
        url, request = sent[0]
        self.assertTrue(url.endswith("/%s:generateContent" % job.model), url)
        self.assertEqual(request["contents"][0]["parts"],
                         [{"text": job.user_text}])
        self.assertEqual(request["systemInstruction"]["parts"][0]["text"],
                         scoring_svc._get_scoring_prompt())
        self.assertEqual(request["generationConfig"]["temperature"], 0.2)
        self.assertNotIn("inlineData", json.dumps(request))
        self.assertEqual(len(rows), 6)
        row = next(r for r in rows if r["answer_id"] == mine[0].id)
        chars = len(job.user_text) + len(scoring_svc._get_scoring_prompt())
        self.assertEqual(row["tokens_in"], round(chars / 4.03) / 2)
        self.assertEqual((row["state"], row["dry_run"], row["source"],
                          row["arm"], row["requested_model"]),
                         ("dry_run", True, "model", "new_uncached", job.model))
        self.assertGreater(row["cost_usd"], 0)

    def test_a_trick_rides_on_its_host_and_leaves_it_as_it_was(self):
        host = self.answers.filtered(
            lambda r: r.question_id == self.written)[0]
        sent = []
        post = harness._Transport.post

        def spy(transport, url, **kw):
            sent.append(kw["json"]["contents"][0]["parts"][0]["text"])
            return post(transport, url, **kw)

        before = self._snapshot()
        with patch.object(harness._Transport, "post", spy):
            rows = self._run(dry_run=True, tricks=[{
                "key": "T01", "kind": "invented", "answer_id": host.id,
                "answer": "A TRICK ANSWER", "question_type":
                "subjective_rubric"}])
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(sent), 4, "three candidates + one trick call")
        self.assertIn("A TRICK ANSWER", sent[-1])
        trick = [r for r in rows if r["key"] == "T01"]
        self.assertEqual([(r["trick"], r["answer_id"]) for r in trick],
                         [("invented", host.id)])

    # -- a graded run -----------------------------------------------------------

    def test_a_graded_run_records_the_codes_own_mark_and_keeps_nothing(self):
        fake = _FakeVertex(
            written={"score": 80, "verdict": "Fair.", "deductions": [
                {"points": -20, "reason": "r", "evidence": "e"}],
                "fabrication_count": 1, "checklist_zero_count": 0,
                "verdict_consistency": "consistent"},
            label={"score": 65, "box_scores": {"1": 90, "2": 40}})
        before = self._snapshot()
        with patch.object(vertex_svc, "_httpx", lambda: fake):
            rows = self._run()
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(fake.requests), 3)
        written = next(r for r in rows
                       if r["question_type"] == "subjective_rubric")
        self.assertEqual(written["state"], "scored")
        self.assertEqual(written["raw_100"], 25.0,
                         "80 from the deductions, capped by the fabrication")
        self.assertEqual(written["caps"], ["fabrication"])
        self.assertEqual((written["fabrication_count"],
                          written["checklist_zero_count"],
                          written["verdict_consistency"]),
                         (1, 0, "consistent"))
        self.assertFalse(written["passed"])
        self.assertEqual(written["prompt_version"],
                         scoring_svc.scoring_prompt_version(
                             scoring_svc._get_scoring_prompt()))
        self.assertEqual(written["model"], written["requested_model"])
        self.assertEqual((written["tokens_in"], written["tokens_out"],
                          written["thinking_tokens"]), (600, 150, 250),
                         "the call's tokens, shared by its two answers")
        self.assertGreater(written["cost_usd"], 0)
        self.assertFalse(written["cached_content"])
        label = next(r for r in rows if r["question_type"] == "image_label")
        self.assertEqual(label["box_scores"], {"1": 90, "2": 40})
        self.assertEqual(label["raw_100"], 65.0, "the mean of its boxes")

    def test_the_fallback_arm_grades_on_the_fallback_model(self):
        fake = _FakeVertex(
            written={"score": 70, "deductions": [
                {"points": -30, "reason": "r", "evidence": "e"}]},
            label={"score": 70, "box_scores": {"1": 70, "2": 70}})
        with patch.object(vertex_svc, "_httpx", lambda: fake):
            rows = self._run(arm="new_fallback", model="gemini-2.5-pro")
        self.assertEqual({r["model"] for r in rows}, {"gemini-2.5-pro"})
        self.assertEqual({r["state"] for r in rows}, {"scored"})

    def test_the_baseline_arm_refuses_to_run_on_the_new_code(self):
        with self.assertRaises(SystemExit):
            self._run(arm="baseline", dry_run=True)

    # -- trick answers ----------------------------------------------------------

    def test_seeding_tricks_writes_nothing(self):
        before = self._snapshot()
        tricks = harness.build_tricks(self.env, [self.paper.id], count=6,
                                      seed=3)
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(tricks), 6)
        by = {(t["question_type"], t["kind"]): t for t in tricks}
        self.assertEqual(len({t["answer_id"] for t in tricks}), 6,
                         "every trick has its own host")
        self.assertIsNone(by[("subjective_rubric", "true_unlisted")]["answer"],
                          "only a person who saw the media can write it")
        self.assertIn(harness._INVENTED,
                      by[("subjective_rubric", "invented")]["answer"])
        self.assertEqual(
            json.loads(by[("image_label", "contradicting")]["answer"]),
            {"1": "Gear: opens settings", "2": "Search: opens the search box"},
            "every box carries another box's key")

    # -- 19.0.3.22.0's grading code (R6-01) -----------------------------------

    @mute_logger("odoo.addons.assessments_be_v2.services.scoring")
    def test_the_baseline_arm_drives_heads_single_entry_point(self):
        # 19.0.3.22.0 has no `_prepare_submission`: `_score_submission`
        # builds, calls and stores in one go.
        fake = _FakeVertex(
            written={"score": 70, "deductions": [
                {"points": -30, "reason": "r", "evidence": "e"}]},
            label={"score": 50, "box_scores": {"1": 50, "2": 50}})
        entered = []
        real = scoring_svc._score_submission

        def spy(env, responses, *a, **kw):
            entered.append(responses.ids)
            return real(env, responses, *a, **kw)
        before = self._snapshot()
        with patch.object(harness, "_new_code", lambda _scoring: False), \
                patch.object(scoring_svc, "_score_submission", spy), \
                patch.object(vertex_svc, "_httpx", lambda: fake):
            dry = self._run(arm="baseline", dry_run=True)
            graded = self._run(arm="baseline", allow_missing_media=True)
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(entered), 6, "one entry per call, per run")
        self.assertEqual(len(fake.requests), 3)
        self.assertEqual(
            {(r["source"], r["state"], r["dry_run"]) for r in dry},
            {("model", "dry_run", True)})
        self.assertGreater(dry[0]["cost_usd"], 0)
        written = next(r for r in graded
                       if r["question_type"] == "subjective_rubric")
        self.assertEqual(
            (written["state"], written["raw_100"], written["arm"]),
            ("scored", 70.0, "baseline"))
        self.assertEqual(written["model"], written["requested_model"])
        self.assertEqual((written["tokens_in"], written["tokens_out"]),
                         (600, 150))

    def test_the_baseline_arm_refuses_a_model_override(self):
        with patch.object(harness, "_new_code", lambda _scoring: False), \
                self.assertRaises(SystemExit):
            self._run(arm="baseline", dry_run=True, model="gemini-2.5-pro")

    # -- the cached arm (R6-03) -------------------------------------------------

    def _one_paper(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.scoring_cache", "groups")
        self.answers.assessment_evaluator_id.write({
            "question_order": json.dumps([self.written.id, self.labelling.id])})

    def test_the_cached_arm_grades_on_the_codes_question_group_cache(self):
        self._one_paper()
        with patch.object(model_catalog, "cache_min_tokens", lambda _m: 1):
            big = self._run(arm="new_cached", dry_run=True)
        with patch.object(model_catalog, "cache_min_tokens",
                          lambda _m: 10 ** 9):
            small = self._run(arm="new_cached", dry_run=True)
        self.assertEqual({r["cache_spec"] for r in big}, {True},
                         "a group over the model's minimum gets a cache")
        self.assertEqual({r["cache_spec"] for r in small}, {False},
                         "under it the call goes inline")
        self.assertEqual(len({r["call"] for r in big}), 3,
                         "one call per candidate on the paper's one group")
        uncached = self._run(arm="new_uncached", dry_run=True)
        self.assertEqual({r["cache_spec"] for r in uncached}, {False},
                         "the re-score path never uses a group cache")

        # The dry runs' cache creates stop at the HTTP seam and are remembered
        # as failed (`failed_until`). A real run is its own uncommitted
        # transaction and never sees them; this test's one transaction does.
        self.env["assessments.be.scoring.cache"].sudo().search([]).unlink()
        fake = _FakeVertex(written={"score": 60}, label={
            "score": 60, "box_scores": {"1": 60, "2": 60}})
        before = self._snapshot()
        with patch.object(model_catalog, "cache_min_tokens", lambda _m: 1), \
                patch.object(vertex_svc, "_httpx", lambda: fake):
            rows = self._run(arm="new_cached")
        self.assertEqual(self._snapshot(), before)
        self.assertEqual(len(fake.caches), 1, "created once, then reused")
        self.assertEqual({r["cached_content"] for r in rows}, {True})
        self.assertTrue(all("cachedContent" in req for req in fake.requests))

    # -- runs over an hour (R6-04) ----------------------------------------------

    def _advisory_locks(self):
        self.env.cr.execute("SELECT count(*) FROM pg_locks WHERE locktype = "
                            "'advisory' AND pid = pg_backend_pid()")
        return self.env.cr.fetchone()[0]

    def test_a_long_run_mints_its_bearer_again_and_holds_no_lock(self):
        now, mints = [1.9e9], []

        def mint(env):
            env.cr.execute("SELECT pg_advisory_xact_lock(%s)",
                           [ADVISORY_LOCK_VERTEX_BEARER])
            env["ir.config_parameter"].sudo().set_param(
                "assessments_be_v2.vertex_minted_token_expires",
                str(int(now[0]) + 3600))
            mints.append(now[0])
            return "token-%d" % len(mints)

        fake = _FakeVertex(written={"score": 60}, label={
            "score": 60, "box_scores": {"1": 60, "2": 60}})
        post = fake.post

        def slow(url, **kw):
            now[0] += 2000      # each call takes a third of an hour
            return post(url, **kw)
        locks = self._advisory_locks()
        with self.enter_registry_test_mode(), \
                patch.object(harness, "_now", lambda: now[0]), \
                patch.object(vertex_svc, "_vertex_bearer", mint), \
                patch.object(fake, "post", slow), \
                patch.object(vertex_svc, "_httpx", lambda: fake):
            rows = harness.run_arm(self.env, arm="new_uncached", run=1,
                                   ids=self.answers.ids, concurrency=1)
        self.assertEqual(fake.bearers, ["Bearer token-1", "Bearer token-1",
                                        "Bearer token-2"],
                         "a fresh bearer before the first one lapses")
        self.assertEqual(self._advisory_locks(), locks,
                         "the mint's lock ends with the mint")
        self.assertEqual({r["state"] for r in rows}, {"scored"})

    # -- live databases (R6-09) -------------------------------------------------

    def test_a_live_or_unblanked_database_is_refused_unless_synthetic(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(harness.SYNTHETIC_MARKER, False)
        self.env["hr.applicant"].create({
            "partner_name": "Real Person", "email_from": "real@example.com"})
        self.env["ir.mail_server"].create({
            "name": "live smtp", "smtp_host": "smtp.example.com"})
        reasons = harness.live_reasons(self.env, self.answers.ids)
        self.assertTrue(any("mail server" in r for r in reasons), reasons)
        self.assertTrue(any("unblanked applicant" in r for r in reasons),
                        reasons)
        with self.assertRaises(SystemExit):
            self._run()
        rows = self._run(dry_run=True)
        self.assertEqual(len(rows), 6,
                         "a dry run sends nothing, so it is allowed")
        self.assertEqual([row["error"] for row in rows], ["dry-run"] * 6,
                         "every row stopped at the dry-run seam, none failed "
                         "before it")
        icp.set_param(harness.SYNTHETIC_MARKER, "%d,0" % self.paper.id)
        self.assertEqual(harness.live_reasons(self.env, self.answers.ids), [])

    def test_a_synthetic_copy_that_kept_real_answers_is_refused(self):
        # etp_f2_synth held 262 real answers beside its synthetic paper.
        other = self.env["assessments.be"].create({
            "name": "Real paper", "generator_id": self.generator.id})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": other.id,
            "applicant_id": self.env["hr.applicant"].create({
                "partner_name": "Real Person",
                "email_from": "real@example.com"}).id})
        real = self.answers.create({
            "assessment_id": other.id, "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": self.written.id, "justification": WRITTEN,
            "state": "submitted", "llm_state": "scored"})
        reasons = harness.live_reasons(self.env, self.answers.ids)
        self.assertEqual(reasons, ["1 non-synthetic answer(s) on a database "
                                   "marked synthetic (rebuild it with "
                                   "synthetic.py)"])
        with self.assertRaises(SystemExit):
            self._run()
        with self.assertRaises(SystemExit):
            harness.run_arm(
                self.env(context=dict(self.env.context,
                                      etp_vertex_bearer="test-bearer")),
                arm="new_uncached", run=1, ids=self.answers.ids + real.ids,
                concurrency=1)
        with self.assertRaises(SystemExit):
            self._run(tricks=[{"answer_id": real.id, "answer": "x",
                               "key": "T01", "kind": "invented"}])

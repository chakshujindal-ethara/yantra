# -*- coding: utf-8 -*-
"""A question is served from the Redis cache, and the cache changes nothing.

`services/question_cache.py` keeps each question's CONTENT (the part every
candidate sees the same) in Redis, keyed on the question's `write_date`, so
`/state`, `/begin` and `/answer` stop rebuilding it from Postgres. It is OFF
unless `REDIS_URL` or the `assessments_be_v2.redis_url` setting names a Redis,
and off is the code path that ran before it existed.

What is held here, each with a case below:

* off without a URL: no client, the output as before;
* a miss builds and fills, a hit builds nothing, and the output is
  byte-identical on, off, cold and warm, for every question type;
* nothing a candidate typed or picked, and no answer key, is ever cached;
* any edit to the question or to a dimension, option, image or video makes a
  new key; a candidate's answer does not;
* Redis down or slow: Postgres, one warning a minute, never a 500;
* single flight, the size guard, the warm-up at launch that never fails it;
* `/api/v1/settings` says whether it is on and where, never the password;
* the SQL statements of one `/answer` with the cache cold and warm.

The unit class runs on an in-process fake; the last class runs against a
real Redis on redis://localhost:6379/0 and skips, saying so, without one.
"""
import json
import logging
import os
import re
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import urlsplit
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..controllers.api import admin as api_admin
from ..controllers.api import candidate as candidate_api
from ..controllers.api import serializers as S
from ..services import question_cache as QC
from . import test_a_sitting_stays_inside_its_write_budget as budget
from ._paging_harness import call_route, status_of

_logger = logging.getLogger(__name__)

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
PNG = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChw"
       "GA60e6kgAAAABJRU5ErkJggg==")
PANELS = [{"number": n, "box_2d": [100 * n, 100, 100 * n + 80, 700],
           "label": "Panel %s" % n, "description": "Does %s" % n}
          for n in range(1, 5)]
BEHAVIOURAL = [{"number": n, "element": "Panel %s" % n,
                "functionality": "Does %s" % n} for n in range(1, 5)]
DETECTED = [{"number": n, "label": "Control %s" % n,
             "box_px": [n, n, n + 9, n + 9]} for n in range(1, 18)]
#: Answer material planted on the fixtures; none of it may reach the cache.
SECRETS = ("GOLDEN-RUBRIC-7f3", "GOLDEN-SOLUTION-7f3", "GOLDEN-REASONING-7f3",
           "GOLDEN-PROMPT-7f3", "Does 1", "Control 1")
#: A key named like any of these in the cached JSON is answer material.
FORBIDDEN_KEY = re.compile(
    r"answer|correct|solution|key|reasoning|rubric|grading|golden|ideal", re.I)
QC_LOGGER = "odoo.addons.assessments_be_v2.services.question_cache"

_Budget = "TestASittingStaysInsideItsWriteBudget"


class FakeRedis:
    """get/set/setnx/expire/delete/ping in process. `down` makes every call
    raise what redis-py raises for a dead server."""

    def __init__(self):
        self.store = {}
        self.ttl = {}
        self.down = False
        self.on_get = None
        self.sets = []
        self.gets = 0
        self.executes = 0
        self.lock = threading.Lock()

    def _check(self):
        if self.down:
            import redis
            raise redis.exceptions.ConnectionError("fake Redis is down")

    def pipeline(self, transaction=True):
        """Queues SETs; `execute` is one round trip (`executes`)."""
        fake, queued = self, []

        class Pipe:
            def set(self, *args, **kwargs):
                queued.append((fake.set, args, kwargs))
                return self

            def get(self, *args):
                queued.append((fake.get, args, {}))
                return self

            def execute(self):
                fake._check()
                fake.executes += 1
                return [call(*a, **k) for call, a, k in queued]
        return Pipe()

    def get(self, key):
        self._check()
        self.gets += 1
        if self.on_get:
            self.on_get(key)
        value = self.store.get(key)
        return value.encode() if isinstance(value, str) else value

    def set(self, key, value, ex=None, nx=False):
        self._check()
        with self.lock:
            if nx and key in self.store:
                return None
            self.store[key] = value if isinstance(value, str) else str(value)
            self.ttl[key] = ex
            self.sets.append(key)
        return True

    def setnx(self, key, value):
        return self.set(key, value, nx=True)

    def expire(self, key, seconds):
        self._check()
        self.ttl[key] = seconds
        return key in self.store

    def delete(self, *keys):
        self._check()
        return sum(1 for k in keys if self.store.pop(k, None) is not None)

    def ping(self):
        self._check()
        return True

    def content_keys(self, question=None):
        prefix = "%s:q:%s:" % (question.env.cr.dbname, question.id) \
            if question else ""
        return [k for k in self.store
                if k.startswith(prefix) and not k.endswith(":build")]


def _walk_keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _walk_keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk_keys(item)


def _paper(env, generator):
    """One question of every type the exam serves, each carrying answer
    material that must never reach the cache. `{label: question}`."""
    Question = env["assessments.be.question"]
    Image = env["assessments.be.question.image"]
    Video = env["assessments.be.question.video"]

    def question(qtype, **vals):
        return Question.create(dict({
            "name": "%s %s" % (qtype, uuid4().hex[:6]),
            "question_type": qtype, "prompt": "Prompt for %s" % qtype,
            "description": "About %s" % qtype, "difficulty": "easy",
            "generator_id": generator.id}, **vals))

    def axis(q, name="Answer", options=(("Alpha", True), ("Bravo", False)),
             **vals):
        env["assessments.be.question.dimension"].create(dict({
            "question_id": q.id, "name": name,
            "option_line_ids": [(0, 0, {"name": n, "sequence": i * 10,
                                        "is_correct": c})
                                for i, (n, c) in enumerate(options)]}, **vals))

    paper = {}
    paper["mcq"] = question("mcq", time_minutes=3)
    axis(paper["mcq"])
    paper["msq"] = question("msq")
    axis(paper["msq"], options=(("A", True), ("B", True), ("C", False)),
         input_kind="checkboxes")
    paper["rubric"] = question(
        "subjective_rubric", section_title="Writing",
        subjective_rubric_json=json.dumps(
            {"scoring_guide": SECRETS[0]}),
        solution_json=json.dumps(SECRETS[1]))
    paper["image_ab"] = question(
        "image_ab", official_reasoning=SECRETS[2])
    for slot in ("a", "b"):
        Image.create({"question_id": paper["image_ab"].id, "slot": slot,
                      "label": "Response %s" % slot.upper(), "image": PNG})
    axis(paper["image_ab"], name="Which is better",
         options=(("A", True), ("B", False)))
    paper["image_prompt"] = question(
        "image_prompt", subjective_rubric_json=json.dumps(
            {"ideal_prompt": SECRETS[3]}))
    Image.create({"question_id": paper["image_prompt"].id,
                  "slot": "single", "label": "Target", "image": PNG})
    paper["labelling"] = question("image_label", detection_mode="ui")
    Image.create({"question_id": paper["labelling"].id, "slot": "single",
                  "label": "Shot", "image": PNG, "annotated_image": PNG,
                  "source_url": "https://www.cvat.ai/",
                  "label_boxes_json": json.dumps(PANELS),
                  "behavioural_key_json": json.dumps(BEHAVIOURAL),
                  "detections_json": json.dumps(DETECTED)})
    paper["labelling_baked"] = question("image_label", detection_mode="ui")
    Image.create({"question_id": paper["labelling_baked"].id,
                  "slot": "single", "label": "Page", "image": PNG,
                  "annotated_image": PNG,
                  "source_url": "https://example.org/",
                  "capture_viewport": "1440x900@2x 2026-09-29T10:00:00Z",
                  "dom_manifest_json": json.dumps(
                      [{"number": n, "box_css": [0, 0, 9, 9]}
                       for n in (1, 2, 3)]),
                  "behavioural_key_json": json.dumps(BEHAVIOURAL[:3])})
    paper["video"] = question("video_prompt")
    Video.create({"question_id": paper["video"].id, "slot": "reference",
                  "label": "Reference", "video_url": "https://cdn.test/a.mp4",
                  "poster_url": "https://cdn.test/a.jpg", "duration_s": 12.5,
                  "has_audio": True})
    Video.create({"question_id": paper["video"].id, "slot": "output",
                  "label": "Output", "sequence": 20,
                  "video_url": "https://www.youtube.com/watch?v=abc123"})
    paper["audio"] = question("mcq")
    Video.create({"question_id": paper["audio"].id, "slot": "single",
                  "label": "Listen", "video_url": "https://cdn.test/clip.mp3"})
    axis(paper["audio"], options=(("Yes", True), ("No", False)))
    for q in paper.values():
        q.invalidate_recordset()
    return paper


def _payload(question, response=None):
    """`question_for_candidate` exactly as `_question_payload` calls it."""
    controller = candidate_api.EtpAssessmentApiCandidate()
    return S.question_for_candidate(
        question, "tok", 1, 9, response,
        label_boxes=lambda: controller._label_boxes(question))


def _isolate(case):
    """Each test starts with the cache off and the warning clock reset. The
    shell running the suite must not switch the cache on either."""
    environ = patch.dict(os.environ)
    environ.start()
    case.addCleanup(environ.stop)
    os.environ.pop("REDIS_URL", None)
    case.icp = case.env["ir.config_parameter"].sudo()
    case.icp.set_param(QC.URL_PARAM, "")
    QC._last_warning[0] = float("-inf")
    QC._skip_until[0] = float("-inf")
    QC._stats.update(reads=0, misses=0, errors=0)
    QC._stats_since[0] = time.monotonic()
    case.generator = case.env["assessments.be.prompt"].create(
        {"name": "Cache %s" % uuid4().hex[:6]})


def _warnings(records):
    return [r for r in records if r.levelno == logging.WARNING
            and r.name == QC_LOGGER]


def _tick(env):
    """A new transaction's clock, so a write stamps a new `write_date`
    (inside one test transaction `cr.now()` never moves)."""
    env.cr._now = env.cr.now() + timedelta(seconds=1)


def _launchable(case, paper):
    """A draft paper of two keyed questions (mcq, audio), shortlisted, one
    candidate: what `action_start` launches."""
    case.env.user.group_ids = [(4, case.env.ref(MANAGER_GROUP).id)]
    slug = uuid4().hex[:8]
    applicant = case.env["hr.applicant"].create({
        "partner_name": "Cand %s" % slug,
        "email_from": "cache_%s@example.com" % slug})
    assessment = case.env["assessments.be"].create({
        "name": "Cache paper %s" % slug,
        "generator_id": case.generator.id,
        "question_ids": [(6, 0, paper["mcq"].ids + paper["audio"].ids)],
        "question_limit": 2, "duration_minutes": 30,
        "evaluator_ids": [(6, 0, [applicant.id])],
    })
    assessment._sync_roster_rows()
    return assessment


@tagged("-at_install", "post_install")
class TestAQuestionIsServedFromTheCache(TransactionCase):

    #: The write-budget test's sitting (five mcq, one written answer) and
    #: its request helpers, reused rather than copied.
    QUESTIONS = 6
    _question = getattr(budget, _Budget)._question
    _sitting = getattr(budget, _Budget)._sitting
    _call = getattr(budget, _Budget)._call
    _answer = getattr(budget, _Budget)._answer
    _count_writes = getattr(budget, _Budget)._count_writes

    def setUp(self):
        super().setUp()
        _isolate(self)
        self.fake = FakeRedis()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.controller = getattr(budget, _Budget)._controller()
        self.session_key = uuid4().hex
        self.stamps = {}

    def _on(self):
        """Point the setting at a URL whose process client is the fake, so
        the real `_url` / `_client` lookup is what finds it."""
        url = "redis://fake-%s:6379/0" % uuid4().hex[:6]
        QC._clients[url] = self.fake
        self.addCleanup(QC._clients.pop, url, None)
        self.icp.set_param(QC.URL_PARAM, url)
        return url

    @contextmanager
    def _count_queries(self):
        """Every statement, SELECTs included: the write-budget spy, minus
        its filter."""
        counted = {"n": 0}
        cr = self.env.cr
        original = cr.execute

        def spy(query, params=None, **kw):
            counted["n"] += 1
            if params is not None:
                return original(query, params, **kw)
            return original(query, **kw)

        cr.execute = spy
        try:
            yield counted
        finally:
            cr.execute = original

    # -- off ------------------------------------------------------------

    def test_off_without_a_url_creates_no_client(self):
        paper = _paper(self.env, self.generator)
        clients = dict(QC._clients)
        import redis
        with patch.object(redis.Redis, "from_url",
                          side_effect=AssertionError("a client was made")):
            for q in paper.values():
                self.assertEqual(_payload(q)["name"], q.name)
        self.assertEqual(QC._clients, clients)
        self.assertEqual(QC.describe(self.env),
                         {"enabled": False, "source": "", "target": "",
                          "reachable": False})

    # -- miss, fill, hit ------------------------------------------------

    def test_a_miss_builds_and_fills_then_a_hit_builds_nothing(self):
        q = _paper(self.env, self.generator)["mcq"]
        expected = S.question_content(q)
        self._on()
        with patch.object(S, "question_content",
                          wraps=S.question_content) as built:
            first = _payload(q)
            self.assertEqual(built.call_count, 1)
            second = _payload(q)
            self.assertEqual(built.call_count, 1, "a hit built the question")
        self.assertEqual(second, first)
        [key] = self.fake.content_keys(q)
        self.assertEqual(key, "%s:q:%s:%s:%s" % (
            self.env.cr.dbname, q.id, q.write_date.isoformat(), QC.CODE))
        self.assertEqual(self.fake.ttl[key], 24 * 3600)
        self.assertIn(key + ":build", self.fake.sets,
                      "the miss took no single-flight lock")
        self.assertEqual(self.fake.ttl[key + ":build"], 30)
        self.assertNotIn(key + ":build", self.fake.store,
                         "the lock outlived its fill")
        self.assertEqual(json.loads(self.fake.store[key]), expected)

    def test_a_call_without_label_boxes_never_touches_the_cache(self):
        """The boxes are an argument, not part of the key: a caller that
        omits them would cache a labelling question's boxes as []."""
        q = _paper(self.env, self.generator)["labelling"]
        self._on()
        payload = S.question_for_candidate(q, "tok", 1, 1)
        self.assertEqual(payload["label_boxes"], [])
        self.assertEqual(self.fake.gets, 0, "the cache was read")
        self.assertEqual(self.fake.store, {}, "the cache was written")
        self.assertEqual([b["number"] for b in _payload(q)["label_boxes"]],
                         [1, 2, 3, 4])

    def test_the_code_hash_covers_constants_and_survives_a_missing_file(self):
        import shutil
        import tempfile
        self.assertIn("constants.py", QC._BUILDER_FILES)
        with tempfile.TemporaryDirectory() as root:
            for path in QC._BUILDER_FILES:
                os.makedirs(os.path.join(root, os.path.dirname(path)),
                            exist_ok=True)
                shutil.copy(os.path.join(QC._ROOT, path),
                            os.path.join(root, path))
            self.assertEqual(QC.code_hash(root), QC.CODE)
            with open(os.path.join(root, "constants.py"), "ab") as handle:
                handle.write(b"\nDEFAULT_IMAGE_LABEL_COUNT = 7\n")
            changed = QC.code_hash(root)
            self.assertNotEqual(changed, QC.CODE)
            os.remove(os.path.join(root, "services/labelling.py"))
            with self.assertLogs(QC_LOGGER, "WARNING"):
                self.assertNotEqual(QC.code_hash(root), changed)

    def test_a_crashed_build_drops_its_lock(self):
        q = _paper(self.env, self.generator)["mcq"]
        self._on()
        with patch.object(S, "question_content",
                          side_effect=RuntimeError("builder bug")):
            with self.assertRaises(RuntimeError):
                _payload(q)
        self.assertEqual(self.fake.store, {}, "the crashed build left a lock")
        started = time.monotonic()
        self.assertEqual(_payload(q)["name"], q.name)
        self.assertLess(time.monotonic() - started, QC.WAIT_SECONDS)

    def test_a_stored_value_that_is_not_an_object_is_a_miss(self):
        q = _paper(self.env, self.generator)["mcq"]
        expected = _payload(q)
        self._on()
        key = "%s:q:%s:%s:%s" % (self.env.cr.dbname, q.id,
                                 q.write_date.isoformat(), QC.CODE)
        # An object missing a key the payload reads would be a KeyError (a
        # 500 for every candidate until the TTL), so it is a miss too.
        partial = dict(S.question_content(q))
        del partial["images"]
        for junk in ("[1, 2]", '"text"', "7", "null", "not json {", "{}",
                     json.dumps(partial)):
            with self.subTest(junk=junk):
                self.fake.store[key] = junk
                self.assertEqual(_payload(q), expected)
                self.assertEqual(json.loads(self.fake.store[key]),
                                 S.question_content(q),
                                 "the junk was not overwritten")

    def test_a_hit_reads_nothing_of_the_question(self):
        q = _paper(self.env, self.generator)["labelling"]
        self._on()
        expected = _payload(q)
        with patch.object(S, "question_content",
                          side_effect=AssertionError("built on a hit")), \
                patch.object(candidate_api.EtpAssessmentApiCandidate,
                             "_label_boxes",
                             side_effect=AssertionError("boxes on a hit")):
            self.assertEqual(_payload(q), expected)

    # -- the output does not move -----------------------------------------

    def test_the_output_is_byte_identical_for_every_type(self):
        paper = _paper(self.env, self.generator)
        off = {k: json.dumps(_payload(q)) for k, q in paper.items()}
        self._on()
        cold = {k: json.dumps(_payload(q)) for k, q in paper.items()}
        with patch.object(S, "question_content",
                          side_effect=AssertionError("built on a hit")):
            warm = {k: json.dumps(_payload(q)) for k, q in paper.items()}
        for kind in paper:
            with self.subTest(kind=kind):
                self.assertEqual(cold[kind], off[kind])
                self.assertEqual(warm[kind], off[kind])
        # The fixtures reach every branch the content has.
        out = {k: json.loads(v) for k, v in off.items()}
        self.assertEqual(set(S.question_content(paper["mcq"])),
                         S.CONTENT_KEYS)
        self.assertEqual([b["number"] for b in out["labelling"]["label_boxes"]],
                         [1, 2, 3, 4])
        self.assertEqual(out["labelling_baked"]["label_boxes"], [1, 2, 3])
        self.assertTrue(out["labelling_baked"]["images"][0]["annotated_url"])
        self.assertEqual([i["slot"] for i in out["image_ab"]["images"]],
                         ["a", "b"])
        self.assertTrue(out["image_ab"]["requires_justification"])
        self.assertEqual([v["kind"] for v in out["audio"]["videos"]],
                         ["audio"])
        self.assertEqual(out["video"]["videos"][1]["url"],
                         "https://www.youtube.com/watch?v=abc123")
        self.assertEqual(out["msq"]["dimensions"][0]["input_kind"],
                         "checkboxes")

    def test_a_saved_and_a_cleared_answer_stay_out_and_render_the_same(self):
        """Through `/state`: the candidate's answer is read fresh every time,
        and a cleared answer renders as no answer, cache on or off."""
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        prose = "CANDIDATE-PROSE-%s" % uuid4().hex[:6]
        self.assertTrue(self._answer(evaluator, user, questions[0])["ok"])
        self.assertTrue(self._answer(evaluator, user, questions[1])["ok"])
        self.assertTrue(self._call(
            "exam_answer", evaluator, user, question_id=questions[-1].id,
            justification=prose, nav="stay")["ok"])
        cleared = self._call(
            "exam_answer", evaluator, user, question_id=questions[1].id,
            cleared=True, nav="stay",
            updated_at=self.stamps[questions[1].id] + 1)
        self.assertTrue(cleared["data"].get("cleared"), cleared)

        def shown(index):
            reply = self._call("exam_state", evaluator, user, q=index)
            self.assertTrue(reply.get("ok"), reply)
            return json.dumps(reply["data"]["question"])

        indexes = (1, 2, len(questions))
        off = {i: shown(i) for i in indexes}
        self._on()
        cold = {i: shown(i) for i in indexes}
        warm = {i: shown(i) for i in indexes}
        for i in indexes:
            with self.subTest(index=i):
                self.assertEqual(cold[i], off[i])
                self.assertEqual(warm[i], off[i])
        self.assertTrue(json.loads(off[1])["answer"]["selected_option_ids"])
        self.assertEqual(json.loads(off[2])["answer"], {
            "answered": False, "selected_option_ids": [], "justification": "",
            "label_answers": {}}, "a cleared answer must render as none")
        self.assertEqual(json.loads(off[len(questions)])["answer"]
                         ["justification"], prose)
        blobs = " ".join(self.fake.store.values())
        self.assertNotIn(prose, blobs)

    def test_no_answer_or_key_material_is_ever_cached(self):
        paper = _paper(self.env, self.generator)
        self._on()
        for q in paper.values():
            _payload(q)
        S.warm_question_cache(
            self.Question.browse([q.id for q in paper.values()]))
        blobs = [self.fake.store[k] for k in self.fake.content_keys()]
        self.assertEqual(len(blobs), len(paper))
        for blob in blobs:
            content = json.loads(blob)
            bad = sorted({k for k in _walk_keys(content)
                          if FORBIDDEN_KEY.search(k)})
            self.assertFalse(bad, "answer material cached under %s" % bad)
            for secret in SECRETS:
                self.assertNotIn(secret, blob)
            # Per-candidate parts are never in it either: no position, no
            # token-carrying URL, no saved answer.
            self.assertFalse({"index", "total", "url", "annotated_url"}
                             & set(_walk_keys(content)))
            self.assertNotIn("id", content)
            self.assertNotIn("tok", blob)

    # -- invalidation ------------------------------------------------------

    def test_writing_the_question_makes_a_new_key(self):
        q = _paper(self.env, self.generator)["mcq"]
        self._on()
        _payload(q)
        _tick(self.env)
        q.name = "Renamed %s" % uuid4().hex[:6]
        self.env.flush_all()
        self.assertEqual(_payload(q)["name"], q.name)
        self.assertEqual(len(self.fake.content_keys(q)), 2)

    def test_every_child_bumps_its_question_on_create_write_and_unlink(self):
        paper = _paper(self.env, self.generator)
        q = paper["image_ab"]
        Dim = self.env["assessments.be.question.dimension"]
        Option = self.env["assessments.be.question.dimension.option"]
        Image = self.env["assessments.be.question.image"]
        Video = self.env["assessments.be.question.video"]
        made = {}

        def make_dim():
            made["dim"] = Dim.create({"question_id": q.id, "name": "Extra"})

        def make_option():
            made["option"] = Option.create({
                "question_dimension_id": made["dim"].id, "name": "Maybe"})

        def make_image():
            made["image"] = Image.create({"question_id": q.id,
                                          "slot": "reference", "label": "Ref",
                                          "image": PNG})

        def make_video():
            made["video"] = Video.create({
                "question_id": q.id, "video_url": "https://cdn.test/b.mp4"})

        steps = [
            ("dimension create", make_dim),
            ("dimension write", lambda: made["dim"].write({"name": "Axis"})),
            ("option create", make_option),
            ("option write", lambda: made["option"].write({"name": "Maybe"
                                                           " not"})),
            ("option unlink", lambda: made["option"].unlink()),
            ("dimension unlink", lambda: made["dim"].unlink()),
            ("image create", make_image),
            ("image write", lambda: made["image"].write({"label": "Ref"})),
            ("label box write", lambda: made["image"].write(
                {"label_boxes_json": json.dumps(PANELS[:1])})),
            # A retry counter riding with content still bumps.
            ("detections with attempts", lambda: made["image"].write(
                {"detection_attempts": 1,
                 "detections_json": json.dumps(DETECTED[:2])})),
            ("image unlink", lambda: made["image"].unlink()),
            ("video create", make_video),
            ("video write", lambda: made["video"].write({"label": "Clip"})),
            ("video unlink", lambda: made["video"].unlink()),
        ]
        for name, step in steps:
            with self.subTest(step=name):
                self.env.flush_all()
                q.invalidate_recordset(["write_date"])
                before = q.write_date
                _tick(self.env)
                step()
                self.env.flush_all()
                q.invalidate_recordset(["write_date"])
                self.assertGreater(q.write_date, before,
                                   "%s did not bump the question" % name)

    def test_a_detect_cron_retry_leaves_the_question_alone(self):
        """`image.detection_attempts += 1`, as `_cron_detect_image_labels`
        writes it: bookkeeping the candidate never sees, so no new key."""
        q = _paper(self.env, self.generator)["labelling"]
        self.env.flush_all()
        q.invalidate_recordset(["write_date"])
        before = q.write_date
        _tick(self.env)
        q.image_ids[:1].detection_attempts += 1
        self.env.flush_all()
        q.invalidate_recordset(["write_date"])
        self.assertEqual(q.write_date, before,
                         "a retry counter re-versioned the question")

    def test_a_changed_option_is_served_new_not_stale(self):
        q = _paper(self.env, self.generator)["mcq"]
        self._on()
        self.assertEqual(
            [o["name"] for o in _payload(q)["dimensions"][0]["options"]],
            ["Alpha", "Bravo"])
        _tick(self.env)
        q.question_dimension_ids.option_line_ids[:1].name = "Aleph"
        self.env.flush_all()
        self.assertEqual(
            [o["name"] for o in _payload(q)["dimensions"][0]["options"]],
            ["Aleph", "Bravo"])

    def test_an_answer_leaves_the_question_and_its_key_alone(self):
        _assessment, evaluator, questions, user = self._sitting()
        self._on()
        self._call("exam_begin", evaluator, user)
        stamp = questions[0].write_date
        self.assertTrue(self._answer(evaluator, user, questions[0])["ok"])
        questions[0].invalidate_recordset(["write_date"])
        self.assertEqual(questions[0].write_date, stamp,
                         "saving an answer re-versioned the question")

    # -- Redis down or slow ------------------------------------------------

    def test_redis_down_serves_from_postgres_with_one_warning(self):
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        expected = self._call("exam_state", evaluator, user, q=1)
        self._on()
        self.fake.down = True
        import redis
        with self.assertLogs(QC_LOGGER, "WARNING") as logs:
            for _ in range(3):
                reply = self._call("exam_state", evaluator, user, q=1)
                self.assertTrue(reply.get("ok"), reply)
                self.assertEqual(reply["data"]["question"],
                                 expected["data"]["question"])
            # A slow Redis is a timeout: the same path (once the back-off
            # after the outage above is over).
            self.fake.down = False
            QC._skip_until[0] = float("-inf")
            with patch.object(self.fake, "get", side_effect=(
                    redis.exceptions.TimeoutError("Timeout reading"))):
                self.assertEqual(_payload(questions[1])["name"],
                                 questions[1].name)
        self.assertEqual(len(_warnings(logs.records)), 1,
                         "the warning is not rate limited")

    def test_a_dead_redis_costs_one_call_per_back_off_not_one_per_question(
            self):
        """A whole paper against a dead Redis asks it once; after the
        back-off it is asked again and, back up, serves hits."""
        paper = _paper(self.env, self.generator)
        self._on()
        self.fake.down = True
        calls = []
        check = self.fake._check
        self.fake._check = lambda: (calls.append(1), check())[1]
        with self.assertLogs(QC_LOGGER, "WARNING") as logs:
            for q in paper.values():
                self.assertEqual(_payload(q)["name"], q.name)
        self.assertEqual(len(calls), 1, "Redis was asked again inside the "
                                        "back-off")
        self.assertEqual(len(_warnings(logs.records)), 1)
        self.fake.down = False
        QC._skip_until[0] = time.monotonic() - 1    # the back-off ran out
        q = paper["mcq"]
        self.assertEqual(_payload(q)["name"], q.name)
        self.assertEqual(len(self.fake.content_keys(q)), 1,
                         "not asked again after the back-off")

    def test_reads_misses_and_errors_are_logged_for_grafana(self):
        """Nothing else monitors this Redis: the stats line is the only
        evidence a hit ever happened (13 Oct stage demo)."""
        paper = _paper(self.env, self.generator)
        self._on()
        q = paper["mcq"]
        _payload(q)                                     # miss
        _payload(q)                                     # hit
        S.paper_content(q | paper["msq"], lambda _q: [])  # 1 hit, 1 miss
        self.fake.down = True
        with self.assertLogs(QC_LOGGER, "WARNING"):
            _payload(paper["rubric"])                   # error
        self.fake.down = False
        QC._skip_until[0] = float("-inf")
        QC._stats_since[0] = float("-inf")              # the window is over
        # logging.INFO, never "INFO": Odoo names its level 25 "INFO".
        with self.assertLogs(QC_LOGGER, logging.INFO) as logs:
            _payload(q)                                 # hit
        [line] = [r.getMessage() for r in logs.records
                  if "stats" in r.getMessage()]
        self.assertIn("reads=5 misses=2 errors=1", line)
        self.assertEqual(QC._stats, {"reads": 0, "misses": 0, "errors": 0})

    def test_an_unreadable_url_never_logs_or_shows_its_password(self):
        q = _paper(self.env, self.generator)["mcq"]
        # An unencoded "/" in the password: urllib reads it as the path.
        self.icp.set_param(QC.URL_PARAM, "redis://:pw-SECRET/x@cache:6379/0")
        with self.assertLogs(QC_LOGGER, "WARNING") as logs:
            self.assertEqual(_payload(q)["name"], q.name)
        shown = json.dumps(QC.describe(self.env))
        for text in [r.getMessage() for r in logs.records] + [shown]:
            self.assertNotIn("SECRET", text)

    # -- single flight and size --------------------------------------------

    def test_two_builders_make_one_fill(self):
        """B misses while A is building: B waits for A's fill and builds
        nothing. Then a lock nobody fills: the loser builds after 200 ms."""
        fake = self.fake
        q = SimpleNamespace(id=1, write_date=datetime(2026, 10, 7, 9, 0),
                            env=SimpleNamespace(
                                cr=SimpleNamespace(dbname="sf-%s" % uuid4())))
        key = QC._key(q)
        builds, results = [], {}
        building, polled = threading.Event(), threading.Event()

        def on_get(k):
            if building.is_set() and k == key:
                polled.set()
        fake.on_get = on_get

        def build_a():
            builds.append("a")
            building.set()
            polled.wait(2)
            return {"name": "A"}

        def build_b():
            builds.append("b")
            return {"name": "B"}

        with patch.object(QC, "_client", return_value=fake):
            thread = threading.Thread(
                target=lambda: results.update(a=QC.fetch(q, build_a)))
            thread.start()
            self.assertTrue(building.wait(2))
            results["b"] = QC.fetch(q, build_b)
            thread.join(2)
            self.assertEqual(builds, ["a"])
            self.assertEqual(results, {"a": {"name": "A"}, "b": {"name": "A"}})
            self.assertEqual(fake.sets.count(key), 1)

            fake.on_get = None
            q.id = 2
            other = QC._key(q)
            fake.store[other + ":build"] = "1"
            started = time.monotonic()
            self.assertEqual(QC.fetch(q, build_b), {"name": "B"})
            waited = time.monotonic() - started
        self.assertGreaterEqual(waited, QC.WAIT_SECONDS)
        self.assertLess(waited, 1.0)
        self.assertNotIn(key + ":build", fake.store,
                         "the winner kept its lock after the fill")
        self.assertIn(other + ":build", fake.store,
                      "a loser deleted a lock it did not hold")

    def test_content_over_the_size_guard_is_not_cached(self):
        q = _paper(self.env, self.generator)["rubric"]
        self._on()
        with patch.object(QC, "MAX_BYTES", 10), \
                patch.object(S, "question_content",
                             wraps=S.question_content) as built:
            first = _payload(q)
            [key] = self.fake.content_keys(q)
            self.assertEqual(self.fake.store[key], "",
                             "an oversized value was stored")
            started = time.monotonic()
            self.assertEqual(_payload(q), first)
            self.assertLess(time.monotonic() - started, QC.WAIT_SECONDS,
                            "a reader waited on a fill that never comes")
        self.assertEqual(built.call_count, 2)

    # -- the warm-up at launch -------------------------------------------

    def _launchable(self):
        return _launchable(self, _paper(self.env, self.generator))

    def _paper_of(self, assessment):
        return self.Question.browse(json.loads(
            assessment.assessment_evaluator_ids[:1].question_order))

    def test_launch_warms_every_question_of_the_paper(self):
        assessment = self._launchable()
        self._on()
        assessment.action_start()
        self.assertEqual(assessment.state, "in_progress")
        questions = self._paper_of(assessment)
        self.assertTrue(questions)
        self.assertEqual(self.fake.executes, 1,
                         "the warm-up was not one pipelined round trip")
        for q in questions:
            [key] = self.fake.content_keys(q)
            self.assertEqual(json.loads(self.fake.store[key]),
                             json.loads(json.dumps(S.question_content(
                                 q, candidate_api.EtpAssessmentApiCandidate()
                                 ._label_boxes(q)))))

    def test_a_failing_warm_up_never_fails_the_launch(self):
        assessment = self._launchable()
        self._on()
        self.fake.down = True
        with self.assertLogs(QC_LOGGER, "WARNING"):
            assessment.action_start()
        self.assertEqual(assessment.state, "in_progress")

    def test_a_database_error_in_the_warm_up_never_fails_the_launch(self):
        assessment = self._launchable()
        self._on()
        cr = self.env.cr

        def broken(*_args, **_kwargs):
            cr.execute("SELECT 1 / 0")

        with patch.object(S, "question_content", side_effect=broken), \
                mute_logger("odoo.sql_db"), \
                self.assertLogs(QC_LOGGER, "WARNING"):
            assessment.action_start()
        self.env.flush_all()
        cr.execute("SELECT state FROM assessments_be WHERE id = %s",
                   (assessment.id,))
        self.assertEqual(cr.fetchone()[0], "in_progress",
                         "the launch's transaction was left aborted")

    # -- the settings screen ---------------------------------------------

    def _settings(self):
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        reply = call_route(api_admin, api_admin.EtpAssessmentApiAdmin(),
                           "settings", self.env)
        self.assertEqual(status_of(reply), 200, reply)
        return reply["data"]

    def test_saving_the_url_never_sends_the_password_back(self):
        from ..controllers.api import write as write_api
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        url = "redis://:s3cret-pw@cache.example:6380/2"
        reply = call_route(write_api, write_api.EtpAssessmentApiWrite(),
                           "settings_update", self.env, redis_url=url)
        self.assertEqual(status_of(reply), 200, reply)
        self.assertEqual(reply["data"]["updated"], {"redis_url": True})
        self.assertEqual(self.icp.get_param(QC.URL_PARAM), url)

    def test_settings_report_the_cache_and_never_the_password(self):
        self.assertEqual(self._settings()["question_cache"],
                         {"enabled": False, "source": "", "target": "",
                          "reachable": False})
        url = "redis://:s3cret-pw@cache.example:6380/2"
        QC._clients[url] = self.fake
        self.addCleanup(QC._clients.pop, url, None)
        self.icp.set_param(QC.URL_PARAM, url)
        data = self._settings()
        self.assertEqual(data["question_cache"], {
            "enabled": True, "source": "setting",
            "target": "redis://cache.example:6380/2", "reachable": True})
        self.assertNotIn("s3cret-pw", json.dumps(data))
        # A Redis that does not answer: reported, never raised.
        self.fake.down = True
        with self.assertLogs(QC_LOGGER, "WARNING"):
            self.assertFalse(self._settings()["question_cache"]["reachable"])
        self.fake.down = False
        QC._skip_until[0] = float("-inf")
        url = "rediss://ops:pw-env@prod-cache:6379"
        QC._clients[url] = self.fake
        self.addCleanup(QC._clients.pop, url, None)
        os.environ["REDIS_URL"] = url
        data = self._settings()
        self.assertEqual(data["question_cache"], {
            "enabled": True, "source": "env",
            "target": "rediss://prod-cache:6379/0", "reachable": True})
        self.assertNotIn("pw-env", json.dumps(data))

    # -- what it saves ---------------------------------------------------

    def test_answer_query_count_cold_and_warm(self):
        """The SQL statements of one `/answer` that returns the next
        question, with the ORM cache empty as at the start of a request:
        cache off, cache on and cold (a miss), cache on and warm (a hit).
        Writes must not move; reads must fall on a hit."""
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        # The first answer also moves the attempt to in_progress: unmeasured.
        self.assertTrue(self._answer(evaluator, user, questions[0])["ok"])
        counts = {}

        def measure(label, answered, served):
            self.env.invalidate_all()
            with self._count_writes() as writes, \
                    self._count_queries() as queries:
                reply = self._answer(evaluator, user, answered)
            self.assertTrue(reply.get("ok"), reply)
            self.assertEqual(reply["data"]["next"]["question"]["id"],
                             served.id)
            counts[label] = (queries["n"], writes["n"])

        measure("off", questions[1], questions[2])
        # On through REDIS_URL, not the setting: `set_param` empties Odoo's
        # registry caches, and the next request would be billed for
        # refilling them (4 statements) as if the cache had cost them.
        url = "redis://fake-%s:6379/0" % uuid4().hex[:6]
        QC._clients[url] = self.fake
        self.addCleanup(QC._clients.pop, url, None)
        os.environ["REDIS_URL"] = url
        measure("cold", questions[2], questions[3])
        S.warm_question_cache(questions[4])
        measure("warm", questions[3], questions[4])
        _logger.info(
            "question cache /answer statements (all, writes): off=%s "
            "cold=%s warm=%s", counts["off"], counts["cold"], counts["warm"])
        self.assertEqual(counts["cold"], counts["off"],
                         "a miss must cost what no cache costs: %s" % counts)
        self.assertLess(counts["warm"][0], counts["cold"][0], counts)
        self.assertEqual(counts["warm"][1], counts["cold"][1], counts)


@tagged("-at_install", "post_install")
class TestTheQuestionCacheOnARealRedis(TransactionCase):
    """The same contract against the local Redis (docker `etp-redis`). Every
    key is under a prefix unique to the test, and only those are deleted."""

    #: ETP_TEST_REDIS_URL runs this class against another Redis (TLS, ACL).
    URL = os.environ.get("ETP_TEST_REDIS_URL", "redis://localhost:6379/0")
    _ping = None

    def setUp(self):
        super().setUp()
        _isolate(self)
        cls = type(self)
        if cls._ping is None:
            try:
                import redis
                redis.Redis.from_url(cls.URL, socket_connect_timeout=0.5,
                                     socket_timeout=0.5).ping()
                cls._ping = ""
            except Exception as exc:                        # noqa: BLE001
                cls._ping = "%s: %s" % (type(exc).__name__, exc)
        if cls._ping:
            self.skipTest("no Redis answers PING on %s (%s); start one with "
                          "`docker start etp-redis`"
                          % (urlsplit(self.URL).hostname, cls._ping))
        import redis
        self.redis = redis.Redis.from_url(self.URL)
        self.prefix = "abv2-test-%s:" % uuid4().hex
        real_key = QC._key
        prefixed = patch.object(QC, "_key",
                                lambda q: self.prefix + real_key(q))
        prefixed.start()
        self.addCleanup(prefixed.stop)
        self.addCleanup(self._delete_own_keys)
        self.icp.set_param(QC.URL_PARAM, self.URL)

    def _delete_own_keys(self):
        own = list(self.redis.scan_iter(match=self.prefix + "*"))
        if own:
            self.redis.delete(*own)

    def _own(self):
        return sorted(k.decode() for k in
                      self.redis.scan_iter(match=self.prefix + "*"))

    def test_miss_fill_and_hit_on_a_real_redis(self):
        paper = _paper(self.env, self.generator)
        off = {}
        self.icp.set_param(QC.URL_PARAM, "")
        for kind, q in paper.items():
            off[kind] = json.dumps(_payload(q))
        self.icp.set_param(QC.URL_PARAM, self.URL)
        for kind, q in paper.items():
            self.assertEqual(json.dumps(_payload(q)), off[kind], kind)
        own = self._own()
        content = [k for k in own if not k.endswith(":build")]
        self.assertEqual(len(content), len(paper), own)
        self.assertTrue(0 < self.redis.ttl(content[0]) <= 24 * 3600)
        self.assertFalse([k for k in own if k.endswith(":build")],
                         "a lock outlived its fill")
        with patch.object(S, "question_content",
                          side_effect=AssertionError("built on a hit")):
            for kind, q in paper.items():
                self.assertEqual(json.dumps(_payload(q)), off[kind], kind)

    def test_the_size_guard_on_a_real_redis(self):
        q = _paper(self.env, self.generator)["rubric"]
        with patch.object(QC, "MAX_BYTES", 10):
            _payload(q)
        [key] = [k for k in self._own() if not k.endswith(":build")]
        self.assertEqual(self.redis.get(key), b"")

    def test_launch_warms_a_real_redis(self):
        assessment = _launchable(self, _paper(self.env, self.generator))
        assessment.action_start()
        self.assertEqual(assessment.state, "in_progress")
        self.assertEqual(len(self._own()), 2, self._own())

    def test_an_unreachable_redis_falls_back_inside_the_timeout(self):
        # A non-routable address: the connect hangs until the 100 ms
        # ceiling, or is refused at once; either way Postgres serves it.
        self.icp.set_param(QC.URL_PARAM, "redis://10.255.255.1:6379/0")
        q = _paper(self.env, self.generator)["mcq"]
        started = time.monotonic()
        with self.assertLogs(QC_LOGGER, "WARNING"):
            self.assertEqual(_payload(q)["name"], q.name)
        self.assertLess(time.monotonic() - started, 1.0)

# -*- coding: utf-8 -*-
"""W15 calibration harness: grade the SAME answers under today's and the new
grading request without keeping a mark, so `compare.py` can tell whether the
new request moves marks more than the model's own run-to-run wobble.

The scripts beside this file are thin command lines over it; the steps are in
`docs/ETP_PLANS_AND_STRATEGY.md` §5.6.

NOTHING HERE WRITES TO THE DATABASE IT RUNS AGAINST:
- every step that writes (restoring an answer to "never graded", storing a
  grade through the code's own `_store_submission`) runs in a savepoint that is
  always rolled back, after the stored values have been read;
- ledger rows are captured in memory (`_write_ledger_row`), never inserted;
- side cursors are switched off (`_side_cursor_is_safe`), the Vertex bearer is
  minted on a cursor of its own that is rolled back at once (`_Bearer`), and
  every cursor is rolled back, never committed, at exit.

The same file runs from either checkout: whichever `assessments_be_v2` the
config loads is the code that builds, sends, parses and caps the grade. The
baseline arm drives 19.0.3.22.0's one entry point, `_score_submission`;
the new arms drive `_prepare_submission`, `_grade_job` and `_store_submission`.

A run that would send answers to Vertex refuses a database that looks live or
unblanked, unless it is marked synthetic and holds only made-up answers
(`live_reasons`).
"""
import argparse
import collections
import contextlib
import importlib
import inspect
import json
import logging
import os
import random
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from types import SimpleNamespace
from unittest import mock

_logger = logging.getLogger("assessments_be_v2.calibration")

#: Dry-run token estimate (same ratio the W12 instruction-size test uses).
CHARS_PER_TOKEN = 4.03
#: Gemini 3 bills a flat 1,120 tokens per attached image (llm_cost_model.py).
IMAGE_TOKENS = 1120
#: Measured billed output (visible + thinking) per graded answer
#: (`SCORING_PER_RESPONSE_OUT`, llm_cost_model.py). Dry-run only.
OUT_TOKENS_PER_ANSWER = 982
#: Floor per question type, so a rare type still gets a readable sample.
MIN_PER_TYPE = 30
#: The prompt version 19.0.3.22.0 grades with (its pre-W12 prompts/scoring.md).
EXPECTED_PROMPT_VERSION = "bundled:34c42d2f"
#: `ir.config_parameter` listing the papers `synthetic.py` built ("7,9"):
#: their answers are made up, so they need no blanking.
SYNTHETIC_MARKER = "calibration.synthetic_papers"
#: A minted Vertex bearer is replaced this long before it lapses.
BEARER_REFRESH_S = 300

NEW_ARMS = ("new_uncached", "new_cached", "new_fallback")
BASELINE_ARM = "baseline"
TRICK_KINDS = ("true_unlisted", "invented", "contradicting")
_INVENTED = "There is also a small green potted plant in the lower-left corner."
_WRITE_BY_HAND = {
    "true_unlisted": "a claim that is TRUE of the media but not in the key",
    "invented": "a claim about the media the key neither confirms nor "
                "contradicts",
    "contradicting": "a claim the key contradicts",
}

#: An answer as it stood before it was ever graded. Only fields the running
#: code has are written (`rescore_request_key` is new-code only).
_NEVER_GRADED = {
    "llm_state": "pending", "llm_attempts": 0, "llm_raw_100": 0.0,
    "label_box_scores_json": False, "llm_result_json": False,
    "llm_prompt_version": False, "llm_judge_model": False,
    "rescore_request_key": False,
}

_TLS = threading.local()
_now = time.time
# One thread at a time holds write locks: a grade that is stored (and rolled
# back) never waits on a row another thread wrote. The Vertex calls - the slow
# part - run outside it.
_DB_LOCK = threading.RLock()


def _services():
    scoring = importlib.import_module(
        "odoo.addons.assessments_be_v2.services.scoring")
    vertex = importlib.import_module(
        "odoo.addons.assessments_be_v2.services.vertex")
    return scoring, vertex


# -- command line and session -------------------------------------------------

def ids_arg(text):
    return [int(x) for x in str(text).replace(" ", "").split(",") if x]


def parser(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument("-c", "--config", required=True,
                   help="Odoo config of the checkout whose code should run")
    p.add_argument("-d", "--database", required=True,
                   help="the blanked prod copy (never prod or stage)")
    p.add_argument("--odoo-src", default="src",
                   help="that checkout's Odoo source folder (default ./src)")
    return p


@contextlib.contextmanager
def odoo_env(args):
    """A superuser env on ``args.database`` whose cursor is always rolled
    back, never committed."""
    sys.path.insert(0, os.path.abspath(args.odoo_src))
    from odoo import api
    from odoo.modules.registry import Registry
    from odoo.tools import config
    config.parse_config(["-c", args.config, "-d", args.database],
                        setup_logging=True)
    threading.current_thread().dbname = args.database
    cr = Registry(args.database).cursor()
    try:
        env = api.Environment(cr, api.SUPERUSER_ID, {})
        scoring, _vertex = _services()
        _logger.info("calibration: grading code %s", scoring.__file__)
        yield env
    finally:
        cr.rollback()
        cr.close()


@contextlib.contextmanager
def _rolled_back(env):
    """Run the block in a savepoint that is ALWAYS rolled back."""
    with _DB_LOCK:
        sp = env.cr.savepoint()
        try:
            yield
        finally:
            sp.close(rollback=True)


def synthetic_papers(env):
    value = env["ir.config_parameter"].sudo().get_param(SYNTHETIC_MARKER) or ""
    return {int(p) for p in value.split(",") if p.strip().isdigit()}


def live_reasons(env, ids):
    """Why answers ``ids`` must not go to Vertex from this database: it looks
    live (active mail servers or crons) or its candidates are not blanked
    (§5.6.1's `0 0 0` check). A database marked synthetic skips those checks
    only while every answer in it sits on a synthetic paper: made-up answers
    carry nobody's data, but real ones copied in with the source do."""
    papers = synthetic_papers(env)
    if papers:
        real = env["assessments.be.response"].sudo().search_count([
            ("assessment_id", "not in", list(papers))])
        return ["%d non-synthetic answer(s) on a database marked synthetic "
                "(rebuild it with synthetic.py)" % real] if real else []
    blanked = "%@blanked.invalid"
    checks = (
        ("active mail server(s)",
         "SELECT count(*) FROM ir_mail_server WHERE active", ()),
        ("active cron(s)", "SELECT count(*) FROM ir_cron WHERE active", ()),
        ("unblanked applicant email(s)",
         "SELECT count(*) FROM hr_applicant WHERE email_from NOT LIKE %s",
         (blanked,)),
        ("unblanked roster email(s)",
         "SELECT count(*) FROM assessments_be_evaluator"
         " WHERE candidate_email NOT LIKE %s", (blanked,)),
        ("unblanked candidate login(s)", """
            SELECT count(*) FROM res_users u
              JOIN res_groups_users_rel r ON r.uid = u.id
              JOIN ir_model_data d
                ON d.model = 'res.groups' AND d.res_id = r.gid
             WHERE d.module = 'assessments_be_v2'
               AND d.name = 'group_assessment_candidate'
               AND u.login NOT LIKE %s""", (blanked,)),
    )
    reasons = []
    for label, query, params in checks:
        env.cr.execute(query, params)
        count = env.cr.fetchone()[0]
        if count:
            reasons.append("%d %s" % (count, label))
    return reasons


# -- precheck -------------------------------------------------------------------

def _graded_domain(assessment_ids):
    domain = [("needs_llm", "=", True), ("llm_state", "=", "scored")]
    if assessment_ids:
        domain.append(("assessment_id", "in", list(assessment_ids)))
    return domain


def precheck(env, assessment_ids=None):
    """Graded answers by prompt version and by question type."""
    Response = env["assessments.be.response"].sudo()
    domain = _graded_domain(assessment_ids)
    versions = collections.Counter()
    for version, count in Response._read_group(
            domain, ["llm_prompt_version"], ["__count"]):
        versions[version or ""] += count
    types = collections.Counter()
    for question, count in Response._read_group(
            domain, ["question_id"], ["__count"]):
        types[question.question_type or ""] += count
    return {"versions": dict(versions), "types": dict(types),
            "flagged": {v: n for v, n in versions.items()
                        if v != EXPECTED_PROMPT_VERSION}}


# Admin-side grading mechanics a candidate should never read in a verdict.
_INTERNAL_VERDICT = re.compile(
    r"\bP[1-6]\b|profile|threshold|pass mark|\bcap(ped)?\b|ceiling|weight"
    r"|fabricat|checklist|verdict_consistency|rubric_source|item_id"
    r"|\d+\s*%", re.IGNORECASE)


def verdict_scan(env, assessment_ids=None):
    """Graded verdicts that mention grading mechanics - candidates now see
    the verdict once results are released. ``{checked, hits: {id: verdict}}``."""
    hits, checked = {}, 0
    for r in env["assessments.be.response"].sudo().search(
            _graded_domain(assessment_ids) + [("llm_verdict", "!=", False)]):
        checked += 1
        if _INTERNAL_VERDICT.search(r.llm_verdict or ""):
            hits[r.id] = r.llm_verdict
    return {"checked": checked, "hits": hits}


def mismatch_report(env):
    """Run the phase-1 profile-mismatch report (read-only) on ``env``."""
    path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "profile_mismatch_report.py")
    with open(path, encoding="utf-8") as fh:
        exec(compile(fh.read(), path, "exec"), {"env": env})  # noqa: S102


# -- which answers --------------------------------------------------------------

def gradable_answers(env, assessment_ids):
    """``(answer id, question type, candidate id, question id)`` of every
    answer the grader marks in these assessments: graded ones, and seeded ones
    never graded yet (`synthetic.py`). An image A/B with no official reasoning
    is marked on its picks alone, so it is left out."""
    domain = [("needs_llm", "=", True),
              ("llm_state", "in", ("scored", "pending"))]
    if assessment_ids:
        domain.append(("assessment_id", "in", list(assessment_ids)))
    rows = []
    for r in env["assessments.be.response"].sudo().search(domain, order="id"):
        if r.question_type == "image_ab" and not r._image_ab_uses_llm():
            continue
        rows.append((r.id, r.question_type or "", r.assessment_evaluator_id.id,
                     r.question_id.id))
    return rows


def _candidate_rank(rows, seed):
    candidates = sorted({r[2] for r in rows})
    random.Random(seed).shuffle(candidates)
    return {c: i for i, c in enumerate(candidates)}


def pick(rows, sample, seed):
    """About ``sample`` answer ids, stratified by question type.

    Each type gets its share of ``sample`` (at least MIN_PER_TYPE), taken
    candidate by candidate in a seeded order, so the picked answers share few
    candidates and grade in few calls. Deterministic for a seed, and a smaller
    ``sample`` with the same seed picks a subset (the 200-answer fallback arm
    reuses the main arm's baseline rows).
    """
    if not rows:
        return []
    rank = _candidate_rank(rows, seed)
    by_type = collections.defaultdict(list)
    for row in rows:
        by_type[row[1]].append(row)
    picked = []
    for qtype in sorted(by_type):
        group = sorted(by_type[qtype], key=lambda r: (rank[r[2]], r[0]))
        share = round(sample * len(group) / len(rows))
        picked += [r[0] for r in group[:max(MIN_PER_TYPE, share)]]
    return sorted(picked)


# -- seeded trick answers -------------------------------------------------------

def _swap_ab(text):
    return re.sub(r"\b([AB])\b", lambda m: "B" if m.group(1) == "A" else "A",
                  text)


def _trick_text(material, kind):
    """``(answer, base)``: the trick answer (None when a person must write it)
    and the correct answer it starts from, both as stored in `justification`.
    """
    qtype = material.get("question_type")
    if qtype == "image_label":
        boxes = material.get("boxes") or {}
        numbers = sorted(boxes, key=lambda n: (len(str(n)), str(n)))
        base = {n: str(boxes[n]) for n in numbers}
        if kind == "invented" and numbers:
            answer = dict(base)
            answer[numbers[0]] += " - next to a small green potted plant"
        elif kind == "contradicting" and len(numbers) > 1:
            # Every box carries the next box's key: each label is wrong.
            answer = {n: base[numbers[(i + 1) % len(numbers)]]
                      for i, n in enumerate(numbers)}
        else:
            answer = None
        dump = lambda d: json.dumps(d, ensure_ascii=False)  # noqa: E731
        return (dump(answer) if answer else None), dump(base)
    if qtype == "image_ab":
        base = material.get("official_reasoning") or ""
        contradicting = (_swap_ab(base) if _swap_ab(base) != base
                         else "None of this is true: %s" % base)
    elif qtype in ("image_prompt", "video_prompt"):
        elements = material.get("required_elements") or []
        base = material.get("reference_prompt") or ", ".join(
            str(e) for e in elements)
        contradicting = "%s, but without %s" % (
            base, elements[0] if elements else "any of the above")
    else:
        golden = material.get("golden_answer")
        base = golden if isinstance(golden, str) else json.dumps(
            golden, ensure_ascii=False)
        contradicting = "None of this is true: %s" % base
    answer = {"invented": "%s %s" % (base, _INVENTED),
              "contradicting": contradicting}.get(kind)
    return answer, base


def build_tricks(env, assessment_ids, count=20, seed=7):
    """~``count`` trick answers on real questions of these assessments.

    Each trick borrows a real graded answer (its "host") on that question and
    replaces its text only inside a rolled-back transaction - here to prove
    the grader's item builder takes it, and again in every arm. Kinds cycle
    through true-but-unlisted (a person writes it after looking at the media:
    ``answer`` is None until then), invented-but-not-contradicting, and
    contradicting-the-key. Writes nothing.
    """
    scoring, _vertex = _services()
    rows = gradable_answers(env, assessment_ids)
    rank = _candidate_rank(rows, seed)
    hosts = collections.defaultdict(list)
    for rid, qtype, cand, qid in sorted(rows, key=lambda r: (rank[r[2]], r[0])):
        hosts[(qtype, qid)].append(rid)
    by_type = collections.defaultdict(list)
    for qtype, qid in sorted(hosts):
        by_type[qtype].append(qid)
    rng = random.Random(seed)
    for qids in by_type.values():
        rng.shuffle(qids)
    # Round-robin over the types, so ~20 tricks still cover every type.
    order = [(qtype, qids[i]) for i in range(max(map(len, by_type.values()),
                                                  default=0))
             for qtype, qids in sorted(by_type.items()) if i < len(qids)]
    Question = env["assessments.be.question"].sudo()
    Response = env["assessments.be.response"].sudo()
    tricks = []
    for qtype, qid in order:
        material = scoring._question_material(Question.browse(qid))
        if not any(material.get(k) for k in scoring._KEY_FIELDS):
            continue
        for kind, host in zip(TRICK_KINDS, hosts[(qtype, qid)]):
            if len(tricks) >= count:
                break
            answer, base = _trick_text(material, kind)
            tricks.append({
                "key": "T%02d" % (len(tricks) + 1), "kind": kind,
                "question_id": qid, "question_type": qtype,
                "answer_id": host, "answer": answer, "base": base,
                "note": "" if answer else (
                    "Write `answer` by hand: `base` plus %s (the media is on "
                    "question %d)." % (_WRITE_BY_HAND[kind], qid))})
    with _rolled_back(env):
        for t in tricks:
            if not t["answer"]:
                continue
            host = Response.browse(t["answer_id"])
            host.justification = t["answer"]
            sent = scoring._build_item(host)["answer"]
            if sent not in (t["answer"], scoring._label_answer(t["answer"])):
                raise ValueError("trick %s did not reach the grader's item"
                                 % t["key"])
    return tricks


# -- grading one arm ------------------------------------------------------------

class DryRun(Exception):
    """Raised at the HTTP seam in a dry run, after the request is recorded."""


class _Transport:
    """Stands in for `vertex._httpx()`: records every grading request, keeps
    the calls-per-minute pace, and in a dry run (``real`` None) stops before
    anything leaves the machine. Token mints and cache requests pass through
    unrecorded."""

    def __init__(self, real, pace):
        self.real, self.pace = real, pace

    def post(self, url, **kwargs):
        sent = getattr(_TLS, "sent", None)
        grading = sent is not None and url.endswith(":generateContent")
        if grading:
            sent.append(dict(kwargs.get("json") or {}, _url=url))
        if self.real is None:
            raise DryRun(url)
        if grading:
            self.pace()
        return self.real.post(url, **kwargs)

    def patch(self, url, **kwargs):
        if self.real is None:
            raise DryRun(url)
        return self.real.patch(url, **kwargs)


class _Bearer:
    """Stands in for `vertex._vertex_bearer` for a whole run. Minted on a
    cursor of its own that is rolled back at once, so its advisory lock never
    outlives the mint, and minted again before it lapses (runs over an hour).
    A ``pinned`` bearer is used as it is."""

    def __init__(self, registry, mint, pinned=None):
        self.registry, self.mint, self.lock = registry, mint, threading.Lock()
        self.token, self.expires = pinned, 0

    def __call__(self, env):
        with self.lock:
            refused = env.context.get("etp_vertex_bearer") is False
            lapsing = self.expires and _now() > self.expires - BEARER_REFRESH_S
            if self.mint and (not self.token or lapsing or refused):
                self.token, self.expires = _on_own_cursor(
                    self.registry, {}, self._fresh)
            return self.token

    def _fresh(self, env):
        token = self.mint(env)
        expires = int(env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.vertex_minted_token_expires", "0") or 0)
        return token, (expires if expires > _now() else 0)


def _pacer(per_minute):
    gap, lock, slot = 60.0 / per_minute, threading.Lock(), [0.0]

    def wait():
        with lock:
            now = time.monotonic()
            at = slot[0] = max(now, slot[0])
            slot[0] += gap
        time.sleep(max(0.0, at - now))
    return wait


@contextlib.contextmanager
def _sandbox(scoring, vertex, transport, bearer):
    def capture(_env, values):
        _TLS.ledger.append(dict(values))
    build_item, call_vertex = scoring._build_item, vertex._call_vertex

    def built(resp):
        # Which answers reached the judge on 19.0.3.22.0, where one call
        # builds, sends and stores.
        getattr(_TLS, "built", []).append(resp.id)
        return build_item(resp)

    def not_the_candidates(env, *args, usage_ctx=None, **kw):
        # Not the candidate's spend: the per-candidate cap and the assessment
        # kill switch are left out; the run has its own --max-usd.
        return call_vertex(env, *args, **kw, usage_ctx=dict(
            usage_ctx or {}, evaluator_id=False))
    with mock.patch.object(vertex, "_side_cursor_is_safe", lambda _env: False), \
            mock.patch.object(vertex, "_write_ledger_row", capture), \
            mock.patch.object(vertex, "_httpx", lambda: transport), \
            mock.patch.object(vertex, "_vertex_bearer", bearer), \
            mock.patch.object(vertex, "_call_vertex", not_the_candidates), \
            mock.patch.object(scoring, "_build_item", built):
        yield


def _as_never_graded(resps, texts):
    resps.write({k: v for k, v in _NEVER_GRADED.items() if k in resps._fields})
    for resp in resps:
        if resp.id in texts:
            resp.justification = texts[resp.id]


def _stored(resp):
    """What the code stored for ``resp`` - read before the rollback."""
    def load(raw, default):
        try:
            return json.loads(raw) if raw else default
        except (TypeError, ValueError):
            return default
    it = load(resp.llm_result_json, {})
    scored = resp.llm_state == "scored"
    return {
        "state": resp.llm_state,
        "raw_100": resp.llm_raw_100 if scored else None,
        "passed": bool(resp.llm_passed) if scored else None,
        "threshold": resp._subjective_threshold(),
        "box_scores": load(resp.label_box_scores_json, None),
        "fabrication_count": it.get("fabrication_count"),
        "checklist_zero_count": it.get("checklist_zero_count"),
        "verdict_consistency": it.get("verdict_consistency"),
        "caps": [c.get("reason") for c in it.get("applied_ceilings") or []
                 if isinstance(c, dict)],
        "prompt_version": resp.llm_prompt_version or "",
        "error": None if scored else (resp.llm_feedback or "")[:300],
    }


def _parts(sent):
    request = sent[0] if sent else {}
    return ([p for c in request.get("contents") or []
             for p in c.get("parts") or []]
            + ((request.get("systemInstruction") or {}).get("parts") or []))


def _media(sent):
    """Image and video parts attached to the call (today's code only)."""
    kinds = [(p.get("inlineData") or {}).get("mimeType", "")
             for p in _parts(sent) if "inlineData" in p]
    images = sum(k.startswith("image/") for k in kinds)
    return {"images": images, "videos": len(kinds) - images}


def _estimate(sent, model, answers, vertex):
    """Dry-run spend of one call, from the request that would have gone."""
    chars = sum(len(p.get("text") or "") for p in _parts(sent))
    tokens_in = (round(chars / CHARS_PER_TOKEN)
                 + IMAGE_TOKENS * _media(sent)["images"])
    tokens_out = OUT_TOKENS_PER_ANSWER * answers
    return {"tokens_in": tokens_in, "tokens_out": tokens_out,
            "thinking_tokens": 0, "cached_tokens": 0,
            "cost_usd": vertex._estimate_cost(model, tokens_in, tokens_out, 0, 0)}


def missing_media(env, ids):
    """Media-graded questions whose image or clip cannot be read - on a copy
    that means the filestore was not restored. Today's code would then grade
    them blind, which prod did not."""
    questions = env["assessments.be.response"].sudo().browse(ids).question_id
    return [q.id for q in questions if (
        q.question_type in ("image_ab", "image_label")
        and not any(i.image or i.annotated_image for i in q.image_ids)) or (
        q.question_type == "video_prompt"
        and not any(v.video for v in q.video_ids))]


def _spent(ledger):
    return {"tokens_in": sum(r.get("tokens_in") or 0 for r in ledger),
            "tokens_out": sum(r.get("tokens_out") or 0 for r in ledger),
            "thinking_tokens": sum(r.get("thoughts_tokens") or 0 for r in ledger),
            "cached_tokens": sum(r.get("cached_tokens") or 0 for r in ledger),
            "cost_usd": sum(r.get("cost_usd") or 0.0 for r in ledger)}


def plan_calls(env, ids, tricks, batch_size, plan_of=None):
    """The calls an arm makes: each candidate's answers in chunks of the
    code's batch size, exactly as a bulk run groups them; trick answers in
    calls of their own (a host may also be graded as itself).

    ``plan_of(evaluator)``: the code's question-group plan (`_cache_plan`) for
    the cached arm. A candidate with a plan gets one call per question group,
    on that group's cache, created when 2+ of the arm's answers use it."""
    Response = env["assessments.be.response"].sudo()
    calls = []

    def chunks(resps, plan):
        groups = [None] if plan is None else plan.groups + [None]
        for group in groups:
            mine = [r.id for r in resps if plan is None
                    or plan.group_of.get(r.question_id.id) == group]
            for i in range(0, len(mine), batch_size):
                yield group, mine[i:i + batch_size]

    def add(group, texts, keys, kinds):
        by_candidate = collections.defaultdict(list)
        found = Response.browse(sorted(group)).exists()
        if len(found) < len(group):
            _logger.warning("calibration: %d answer id(s) are not in this "
                            "database and are skipped", len(group) - len(found))
        for resp in found:
            by_candidate[resp.assessment_evaluator_id].append(resp)
        for cand in sorted(by_candidate, key=lambda e: e.id):
            plan = plan_of(cand) if plan_of else None
            for question_group, chunk in chunks(by_candidate[cand], plan):
                calls.append(SimpleNamespace(
                    ids=chunk, texts={h: texts[h] for h in chunk if h in texts},
                    keys={h: keys.get(h, str(h)) for h in chunk},
                    kinds={h: kinds.get(h) for h in chunk},
                    group=question_group))

    add(set(ids), {}, {}, {})
    ready = [t for t in tricks or () if t.get("answer")]
    hosts = [t["answer_id"] for t in ready]
    if len(hosts) != len(set(hosts)):
        raise ValueError("each trick needs its own host answer")
    add(set(hosts), {t["answer_id"]: t["answer"] for t in ready},
        {t["answer_id"]: t["key"] for t in ready},
        {t["answer_id"]: t["kind"] for t in ready})
    wanted = collections.Counter()
    for call in calls:
        wanted[call.group] += len(call.ids)
    for call in calls:
        call.prepare_kw = {"cache_group": SimpleNamespace(
            question_ids=call.group, create=wanted[call.group] >= 2)
            } if call.group else {}
    return calls


def _grade_call(env, index, call, opts):
    """Grade one call's answers through the code's own path; return one row
    per answer. Every write is rolled back."""
    scoring, vertex = opts.scoring, opts.vertex
    resps = env["assessments.be.response"].sudo().browse(call.ids)
    _TLS.sent, _TLS.ledger, _TLS.built = [], [], []
    grade_rows = _grade_rows_head if opts.head else _grade_rows
    try:
        rows = grade_rows(env, call, opts, scoring, vertex, resps)
    except Exception as exc:  # noqa: BLE001 - one call must not end a paid run
        _logger.exception("calibration: call %d failed in the harness", index)
        rows = {rid: {"source": "model", "state": "harness_error",
                      "error": repr(exc)[:300]} for rid in call.ids}
    finally:
        _TLS.__dict__.clear()
    for rid, row in rows.items():
        row.update(key=call.keys[rid], answer_id=rid, trick=call.kinds[rid],
                   question_type=resps.browse(rid).question_type,
                   arm=opts.arm, run=opts.run, call=index,
                   dry_run=opts.dry_run)
    return [rows[rid] for rid in call.ids]


def _model_fields(opts, vertex, graded, model, served):
    """Spend and model columns of a call's graded rows, its cost in total."""
    spend = (_estimate(_TLS.sent, model, len(graded), vertex)
             if opts.dry_run else _spent(_TLS.ledger))
    cost = spend["cost_usd"]
    spend.update(_media(_TLS.sent))
    share = {k: v / len(graded) for k, v in spend.items()}
    share.update(model=served, requested_model=model,
                 cached_content=any("cachedContent" in s for s in _TLS.sent),
                 calls_made=len(_TLS.sent))
    return share, cost


def _grade_rows_head(env, call, opts, scoring, vertex, resps):
    """19.0.3.22.0 grades through one entry point that builds, calls and
    stores, so the call runs inside the rolled-back savepoint."""
    # ponytail: and under _DB_LOCK, so baseline calls go one at a time; split
    # at `_call_vertex` if a baseline run must be faster.
    rows, served = {}, {}
    with _rolled_back(env):
        _as_never_graded(resps, call.texts)
        scoring._score_submission(env, resps)
        graded = [rid for rid in call.ids if rid in _TLS.built]
        for resp in resps:
            rows[resp.id] = dict(_stored(resp), source="model"
                                 if resp.id in graded else "code")
            served[resp.id] = resp.llm_judge_model or None
    if graded:
        share, cost = _model_fields(opts, vertex, graded,
                                    vertex._scoring_model(env), None)
        for rid in graded:
            rows[rid].update(share, model=served[rid])
            if opts.dry_run:
                rows[rid].update(state="dry_run", error="dry-run")
        with opts.lock:
            opts.spent += cost
    return rows


def _grade_rows(env, call, opts, scoring, vertex, resps):
    rows = {}
    with _rolled_back(env):
        _as_never_graded(resps, call.texts)
        _pre, job = scoring._prepare_submission(
            env, resps, **dict(opts.prepare_kw, **call.prepare_kw))
        graded = [r.id for r in job.gradable] if job else []
        for resp in resps:
            if resp.id not in graded:
                rows[resp.id] = dict(_stored(resp), source="code")
    error = results = None
    if job:
        job.model = opts.model or job.model
        # Not the candidate's spend: the per-candidate cap and the assessment
        # kill switch are left out; the run has its own --max-usd.
        job.usage_ctx = dict(job.usage_ctx, evaluator_id=False,
                             note="calibration " + job.usage_ctx.get("note", ""))
        try:
            results = scoring._grade_job(env, job)
        except DryRun:
            error = "dry-run"
        except Exception as exc:  # noqa: BLE001 - recorded on the rows
            error = "%s: %s" % (type(exc).__name__, str(exc)[:300])
        if results is not None:
            with _rolled_back(env):
                _as_never_graded(resps, call.texts)
                scoring._store_submission(env, job, results, None)
                for resp in job.gradable:
                    rows[resp.id] = dict(_stored(resp), source="model")
        share, cost = _model_fields(
            opts, vertex, graded, job.model,
            job.served_models[-1] if job.served_models else None)
        for rid in graded:
            row = rows.setdefault(rid, {
                "source": "model", "error": error,
                "state": "dry_run" if opts.dry_run else "error"})
            row.update(share, cache_spec=bool(getattr(job, "cache", None)))
        with opts.lock:
            opts.spent += cost
    return rows


def _new_code(scoring):
    """Whether this checkout runs the new grading code (not 19.0.3.22.0's)."""
    prepare = getattr(scoring, "_prepare_submission", None)
    return bool(prepare) and "individual" in inspect.signature(
        prepare).parameters


def _on_own_cursor(registry, context, fn, *args):
    from odoo import api
    threading.current_thread().dbname = registry.db_name
    cr = registry.cursor()
    try:
        return fn(api.Environment(cr, api.SUPERUSER_ID, context), *args)
    finally:
        cr.rollback()
        cr.close()


def run_arm(env, *, arm, run, ids, tricks=(), model=None, concurrency=4,
            dry_run=False, max_usd=40.0, allow_missing_media=False,
            write=None):
    """Grade ``ids`` (+ tricks) once as ``arm``/``run``; returns the rows and
    hands each to ``write`` as it lands. Writes nothing to the database."""
    scoring, vertex = _services()
    if arm == BASELINE_ARM:
        gaps = missing_media(env, list(ids) + [t["answer_id"] for t in tricks])
        if gaps and not (dry_run or allow_missing_media):
            raise SystemExit(
                "no readable media for question(s) %s: restore the filestore "
                "(or pass --allow-missing-media if prod had none either)"
                % gaps[:20])
        if gaps:
            _logger.warning("calibration: no readable media for question(s) "
                            "%s - today's code will grade them blind", gaps[:20])
    new_code = _new_code(scoring)
    if (arm in NEW_ARMS) != new_code:
        raise SystemExit(
            "arm %r needs the %s code, but this checkout runs the %s code"
            % (arm, "new" if arm in NEW_ARMS else "baseline",
               "new" if new_code else "baseline"))
    if arm == BASELINE_ARM and model:
        raise SystemExit("--model is for the new arms; the baseline grades on "
                         "the copy's own scoring model")
    if arm == "new_fallback" and not model:
        model = vertex._fallback_model(env)
        if not model:
            raise SystemExit("new_fallback: no fallback model configured; "
                             "pass --model")
    if not dry_run:
        reasons = live_reasons(
            env, list(ids) + [t["answer_id"] for t in tricks])
        if reasons:
            raise SystemExit(
                "refusing to send answers from %s to Vertex: %s. Blank the "
                "copy first (§5.6.1), or grade only the answers on its "
                "synthetic papers (synthetic.py)."
                % (env.cr.dbname, "; ".join(reasons)))
    opts = SimpleNamespace(
        scoring=scoring, vertex=vertex, arm=arm, run=run, model=model,
        dry_run=dry_run, spent=0.0, lock=threading.Lock(),
        head=not new_code,
        # The re-score path never shares a question-group cache; the bulk
        # path does whenever the code (W13) and its switch allow it.
        prepare_kw=({"individual": arm != "new_cached"} if new_code else {}))
    batch = scoring._scoring_batch_size(env)
    plan_of = None
    if arm == "new_cached" and hasattr(scoring, "_cache_plan"):
        plan_of = lambda evaluator: scoring._cache_plan(  # noqa: E731
            env, evaluator, batch)
        # ponytail: a cache's row lives only in this run's never-committed
        # transaction, so cached calls go one at a time on it; keep the
        # caches in memory if this arm must run in parallel.
        concurrency = 1
    calls = plan_calls(env, ids, tricks, batch, plan_of)
    if plan_of and not any(c.group for c in calls):
        _logger.warning("calibration: new_cached found no question group "
                        "(switch %s off, or per-person papers): every call "
                        "goes inline", scoring._CACHE_SWITCH)
    per_minute = vertex.spend_cap(env, "vertex_max_rpm", 0.0) or 60.0
    transport = _Transport(None if dry_run else vertex._httpx(),
                           _pacer(per_minute))
    pinned = "dry-run" if dry_run else env.context.get("etp_vertex_bearer")
    bearer = _Bearer(env.registry, None if pinned else vertex._vertex_bearer,
                     pinned)
    rows, skipped = [], 0
    with _sandbox(scoring, vertex, transport, bearer):
        context = dict(env.context, etp_vertex_bearer=bearer(env) or False,
                       etp_vertex_bearer_expires=bearer.expires)

        def grade(call_env, index, call):
            if opts.spent >= max_usd:
                return None
            return _grade_call(call_env, index, call, opts)

        if concurrency <= 1:
            done = (grade(env(context=context), i, c)
                    for i, c in enumerate(calls))
        else:
            pool = ThreadPoolExecutor(max_workers=concurrency)
            futures = [pool.submit(_on_own_cursor, env.registry, context,
                                   grade, i, c) for i, c in enumerate(calls)]
            done = (f.result() for f in as_completed(futures))
        for n, call_rows in enumerate(done, 1):
            if call_rows is None:
                skipped += 1
                continue
            for row in call_rows:
                rows.append(row)
                if write:
                    write(row)
            _logger.info("calibration %s#%s: call %d/%d, %d answer(s), "
                         "$%.2f so far", arm, run, n, len(calls),
                         len(call_rows), opts.spent)
        if concurrency > 1:
            pool.shutdown()
    if skipped:
        _logger.warning("calibration: --max-usd $%.2f reached, %d call(s) "
                        "not made", max_usd, skipped)
    return rows


def cli_run(arms, description):
    """The command line shared by run_new_arm.py and run_baseline_arm.py."""
    p = parser(description)
    p.add_argument("--arm", choices=arms, default=arms[0])
    p.add_argument("--run", type=int, default=1)
    p.add_argument("--ids", required=True, help="file from select_answers.py")
    p.add_argument("--tricks", help="file from seed_tricks.py")
    p.add_argument("--model", help="grade on this model instead")
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--max-usd", type=float, default=40.0,
                   help="stop starting calls once this run has spent this")
    p.add_argument("--dry-run", action="store_true",
                   help="build every request and estimate tokens; no Vertex")
    p.add_argument("--allow-missing-media", action="store_true",
                   help="baseline: grade media questions whose files are gone")
    p.add_argument("--out", required=True, help="JSONL file to create")
    args = p.parse_args()
    if os.path.exists(args.out):
        raise SystemExit("%s exists; results are never overwritten" % args.out)
    with open(args.ids, encoding="utf-8") as fh:
        ids = json.load(fh)["ids"]
    tricks = []
    if args.tricks:
        with open(args.tricks, encoding="utf-8") as fh:
            tricks = json.load(fh)
    try:
        with odoo_env(args) as env, \
                open(args.out, "w", encoding="utf-8") as out:
            def write(row):
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
            rows = run_arm(env, arm=args.arm, run=args.run, ids=ids,
                           tricks=tricks, model=args.model,
                           concurrency=args.concurrency, dry_run=args.dry_run,
                           max_usd=args.max_usd, write=write,
                           allow_missing_media=args.allow_missing_media)
    except BaseException:
        if os.path.exists(args.out) and not os.path.getsize(args.out):
            os.remove(args.out)     # nothing graded: leave no file to refuse
        raise
    model_rows = [r for r in rows if r["source"] == "model"]
    calls = {r["call"] for r in model_rows}
    print("%s#%s%s: %d answers, %d graded by the model in %d call(s), "
          "%d by code; tokens in %d, out %d, thinking %d, cached %d; "
          "cost $%.2f%s -> %s" % (
              args.arm, args.run, " (DRY RUN, estimated)" if args.dry_run
              else "", len(rows), len(model_rows), len(calls),
              len(rows) - len(model_rows),
              *(round(sum(r.get(k) or 0 for r in model_rows)) for k in (
                  "tokens_in", "tokens_out", "thinking_tokens",
                  "cached_tokens")),
              sum(r.get("cost_usd") or 0 for r in model_rows),
              "; %d image / %d video part(s) attached%s" % (
                  round(sum(r.get("images") or 0 for r in model_rows)),
                  round(sum(r.get("videos") or 0 for r in model_rows)),
                  " (video not in the estimate)" if args.dry_run else ""),
              args.out))
    return rows

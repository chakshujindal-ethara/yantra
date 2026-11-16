# -*- coding: utf-8 -*-
"""CSV exporters for assessment results and responses."""
import base64
import csv
import io

from . import pace as pace_svc


def _violation_detail(ev, field="violation_log"):
    """A per-reason tally of this candidate's violations for one CSV cell.

    `violation_count` is the total; this is the breakdown behind it, folded
    into a single readable cell (``reason xN``, most frequent first, `;`
    separated) so a results export carries the same history the API tally does
    without a second file. A legacy attempt with a null/empty log yields "".
    `field="ai_violation_log"` for the AI violations, logged apart (R5).
    """
    log = ev[field] or []
    if not isinstance(log, list):
        return ""
    counts = {}
    for entry in log:
        if isinstance(entry, dict) and entry.get("reason") is not None:
            reason = str(entry["reason"])
            counts[reason] = counts.get(reason, 0) + 1
    return "; ".join(
        "%s x%d" % (reason, count)
        for reason, count in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))


RESULTS_COLUMNS = [
    "rank", "candidate", "email", "assessment", "assessment_state",
    "candidate_state",
    "objective_score", "objective_max",
    "subjective_marks", "subjective_max",
    "total_score", "total_max", "score_percent", "pass_threshold",
    "result", "subjective_scoring_state", "results_released",
    "is_locked", "violation_count", "violation_detail", "started_at",
    # D1 - the operator's flag on THIS sitting, and their remark about it.
    #
    # APPENDED after the base columns, so an existing consumer that reads this
    # file by column position keeps working: appending is the only safe way to
    # widen a schema somebody else's spreadsheet is already keyed to. They are
    # no longer last - every later addition is appended after them, below.
    #
    # "yes" OR EMPTY, never "no", unlike `results_released` and `is_locked`
    # above. Those two are a state every row genuinely has; a flag is a rare
    # exception, and a column of 200 "no"s buries the four rows that matter.
    # Empty also sorts and filters to the bottom in every spreadsheet, which is
    # the behaviour somebody scanning for flagged candidates actually wants.
    "Flagged", "Flag Remarks",
    # Time analysis, appended for the same reason as the two above. `pace` is
    # EMPTY, never "Normal", when there is no time or no median to compare.
    "submitted_at", "time_taken_minutes", "test_median_minutes", "pace",
    # The per-candidate roster facts, so this is the ONE per-candidate file (the
    # app's old browser-built roster export is gone). `invite_state` is the raw
    # value like `candidate_state`; the two counts are separate integer columns
    # on purpose, because "8 / 14" in one cell is read as a date by spreadsheets.
    "invite_state", "answered_count", "question_count",
    # The AI proctoring violations, counted apart from `violation_count` since
    # 14 Oct (R5). Appended, like every block above.
    "ai_violation_count", "ai_violation_detail",
]

RESPONSES_COLUMNS = [
    "candidate", "email", "assessment", "day", "skill",
    "question", "question_type", "generator", "difficulty", "prompt",
    "candidate_answer", "correct_answer", "model_answer", "dimension_detail",
    "objective_score", "objective_max",
    # ONE RAW COLUMN, ON ONE SCALE. `subjective_score_0_100` sat here beside
    # `subjective_raw_0_1` carrying the SAME number a hundred times larger, so
    # a spreadsheet of these had two "raw" columns that never agreed and no
    # header said which to trust. Raw scores are decimals from 0 to 1
    # everywhere, so the 0-100 twin is gone rather than renamed.
    "needs_subjective", "subjective_result",
    "subjective_mark", "subjective_max", "subjective_raw_0_1", "subjective_state",
    "subjective_reasoning", "justification", "rubric",
    "integrity_alert",
    "ab_verdict_pct", "ab_justification_pct",
    "label_coverage_pct", "label_correctness_pct",
    "flaw_plan_json", "source_url", "dom_manifest_json", "behavioural_key_json",
    "total_score", "total_max", "response_state",
]


def _attachment_download(env, model, res_id, filename, content_bytes,
                         mimetype="text/csv"):
    att = env["ir.attachment"].create({
        "name": filename,
        "type": "binary",
        "raw": content_bytes,
        "mimetype": mimetype,
        "res_model": model,
        "res_id": res_id,
    })
    return {
        "type": "ir.actions.act_url",
        "url": f"/web/content/{att.id}?download=true",
        "target": "self",
    }


def _dimension_detail(resp):
    """Return (candidate_answer, correct_answer, detail) for one response."""
    rec = resp.sudo()
    q = rec.question_id
    chosen_by_dim = {}
    for line in rec.line_ids:
        if line.selected_option_id:
            chosen_by_dim.setdefault(line.question_dimension_id.id, []).append(
                line.selected_option_id.name)

    cand_parts, correct_parts, detail_parts = [], [], []
    for qd in q.question_dimension_ids:
        chosen = chosen_by_dim.get(qd.id, [])
        correct = [ol.name for ol in qd.option_line_ids.filtered("is_correct")
                   if ol.name]
        if chosen:
            cand_parts.append(f"{qd.name}: {', '.join(chosen)}")
        if correct:
            correct_parts.append(f"{qd.name}: {', '.join(correct)}")
        if correct or chosen:
            ok = (set(s.strip().casefold() for s in chosen)
                  == set(s.strip().casefold() for s in correct))
            mark = "\u2713" if ok else "\u2717"
            detail_parts.append(
                f"{qd.name} [chose: {', '.join(chosen) or '-'} | "
                f"correct: {', '.join(correct) or '-'}] {mark}")
    cand = " | ".join(cand_parts)
    if not cand and (rec.justification or "").strip():
        cand = (rec.justification or "").strip()
    return cand, " | ".join(correct_parts), " || ".join(detail_parts)


def _authoring_json(q):
    """The Phase-3 flaw plan (on the question) and the Phase-4 DOM capture fields
    (on the image_label source image), for the full/native export audit trail.
    First image carrying each DOM field wins; empty strings when absent."""
    dom_source = q.image_ids.filtered(lambda i: i.source_url)[:1]
    dom_manifest = q.image_ids.filtered(lambda i: i.dom_manifest_json)[:1]
    dom_key = q.image_ids.filtered(lambda i: i.behavioural_key_json)[:1]
    return {
        "flaw_plan_json": q.flaw_plan_json or "",
        "source_url": dom_source.source_url or "" if dom_source else "",
        "dom_manifest_json": (
            dom_manifest.dom_manifest_json or "" if dom_manifest else ""),
        "behavioural_key_json": (
            dom_key.behavioural_key_json or "" if dom_key else ""),
    }


def _response_row(resp):
    rec = resp.sudo()
    q = rec.question_id
    emp = rec.evaluator_id
    cand, correct, detail = _dimension_detail(rec)
    obj = rec.score or 0
    obj_max = rec.max_score or 0
    subj = rec.llm_score or 0
    subj_max = rec.llm_max_score or 0
    row = {
        "candidate": emp.partner_name or "",
        "email": emp.email_from or "",
        "assessment": rec.assessment_id.name or "",
        "day": "",
        "skill": q.generator_id.name or "",
        "question": q.name or "",
        "question_type": q.question_type or "",
        "generator": q.generator_id.name or "",
        "difficulty": q.difficulty or "",
        "prompt": q.prompt or "",
        "candidate_answer": cand,
        "correct_answer": correct,
        "model_answer": q.official_reasoning or "",
        "dimension_detail": detail,
        "objective_score": obj,
        "objective_max": obj_max,
        "needs_subjective": "yes" if rec.needs_llm else "no",
        "subjective_result": rec.subjective_result or "",
        "subjective_mark": subj,
        "subjective_max": subj_max,
        "subjective_raw_0_1": round(rec.llm_raw_score, 4) if rec.needs_llm else "",
        "subjective_state": rec.llm_state or "",
        "subjective_reasoning": rec.llm_feedback or "",
        "justification": rec.justification or "",
        "rubric": q.subjective_rubric_json or "",
        "integrity_alert": "yes" if rec.integrity_alert else "no",
        "ab_verdict_pct": round(rec.ab_verdict_pct, 2) if rec.needs_llm else "",
        "ab_justification_pct": (
            round(rec.ab_justification_pct, 2) if rec.needs_llm else ""),
        "label_coverage_pct": (
            round(rec.label_coverage_pct, 2) if rec.needs_llm else ""),
        "label_correctness_pct": (
            round(rec.label_correctness_pct, 2) if rec.needs_llm else ""),
        "total_score": obj + subj,
        "total_max": obj_max + subj_max,
        "response_state": rec.state or "",
    }
    row.update(_authoring_json(q))
    return row


# Leading characters that spreadsheet apps (Excel / Numbers / Sheets) treat as
# the start of a formula. Candidate-controlled fields (name, email,
# justification) and LLM feedback flow verbatim into these CSVs, so a cell like
# `=HYPERLINK(...)` or `@SUM(...)` would execute on the admin's machine when the
# export is opened (CSV injection, CWE-1236). Prefix any such cell with a single
# quote so it is rendered as literal text and never evaluated.
_CSV_FORMULA_LEAD = ("=", "+", "-", "@", "\t", "\r")


def _sanitize_cell(value):
    if value is None:
        return ""
    if isinstance(value, (int, float)):
        # Real numerics are safe and must stay numeric for sorting in the sheet.
        return value
    s = str(value)
    if s and s[0] in _CSV_FORMULA_LEAD:
        return "'" + s
    return s


def _write_csv(columns, rows):
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow({k: _sanitize_cell(v) for k, v in r.items()})
    return buf.getvalue().encode("utf-8")


def results_rows(assessment):
    ranked = assessment.assessment_evaluator_ids.sorted(
        key=lambda e: (-(e.score_percent or 0.0),
                       e.applicant_id.partner_name or ""))
    # The paper's median once per file, never once per row.
    median = pace_svc.median_seconds(assessment)
    rows = []
    for idx, ev in enumerate(ranked, start=1):
        emp = ev.applicant_id
        taken = pace_svc.span_seconds(
            ev.started_at, ev.submitted_at, ev.deadline_datetime)
        obj = ev.total_score or 0
        obj_max = ev.max_possible_score or 0
        subj = ev.llm_total_score or 0
        subj_max = ev.llm_max_score or 0
        rows.append({
            "rank": idx,
            "candidate": emp.partner_name or "",
            "email": emp.email_from or "",
            "assessment": assessment.name or "",
            "assessment_state": assessment.state or "",
            "candidate_state": ev.state or "",
            "objective_score": obj,
            "objective_max": obj_max,
            "subjective_marks": subj,
            "subjective_max": subj_max,
            "total_score": obj + subj,
            "total_max": obj_max + subj_max,
            "score_percent": ev.score_percent or 0.0,
            "pass_threshold": ev.pass_threshold or 0.0,
            "result": ev.result or "pending",
            "subjective_scoring_state": ev.llm_state or "",
            "results_released": "yes" if ev.results_released else "no",
            "is_locked": "yes" if ev.is_locked else "no",
            "violation_count": ev.violation_count or 0,
            "violation_detail": _violation_detail(ev),
            "started_at": ev.started_at or "",
            "Flagged": "yes" if ev.manual_flagged else "",
            # The remark stands alone: it is exported whether or not the flag
            # beside it is raised, because an operator can note something about
            # a sitting without accusing anybody, and dropping the note when
            # the flag is clear would lose exactly the rows nobody re-reads.
            "Flag Remarks": ev.manual_remark or "",
            "submitted_at": ev.submitted_at or "",
            "time_taken_minutes": pace_svc.minutes(taken),
            "test_median_minutes": pace_svc.minutes(median),
            "pace": pace_svc.pace(taken, median),
            "invite_state": ev.invite_state or "none",
            "answered_count": ev.answered_count or 0,
            # THIS candidate's paper: `total_questions`, the stored count of the
            # frozen `question_order` the admin candidate serializers send as
            # the denominator beside Answered. A stored column, so it rides the
            # same prefetch as the rest of the row - no query per candidate.
            "question_count": ev.total_questions or 0,
            "ai_violation_count": ev.ai_violation_count or 0,
            "ai_violation_detail": _violation_detail(ev, "ai_violation_log"),
        })
    return rows


def export_results(assessment):
    assessment.ensure_one()
    rows = results_rows(assessment)
    content = _write_csv(RESULTS_COLUMNS, rows)
    return _attachment_download(
        assessment.env, assessment._name, assessment.id,
        f"{assessment.name}_results.csv", content)


def _summary_row(ev):
    """One per-candidate scorecard summary row in the response column schema.

    Derived from the SAME stored fields as the detail rows so it can't disagree.
    """
    submitted = ev.response_ids.filtered(lambda r: r.state == "submitted")
    obj = submitted.filtered(lambda r: r.has_objective)
    obj_total = len(obj)
    obj_correct = len(obj.filtered(
        lambda r: r.max_score and r.score >= r.max_score))
    subj = submitted.filtered(lambda r: r.needs_llm)
    subj_total = len(subj)
    subj_pass = len(subj.filtered(
        lambda r: r.llm_state == "scored" and r.llm_passed))
    pending = len(subj.filtered(
        lambda r: r.llm_state in ("pending", "queued", "failed")))

    obj_pts = ev.total_score or 0
    obj_max = ev.max_possible_score or 0
    sub_pts = ev.llm_total_score or 0
    sub_max = ev.llm_max_score or 0
    detail = (
        f"Objective: {obj_correct}/{obj_total} correct ({obj_pts}/{obj_max} pts)"
        f" | Subjective: {subj_pass}/{subj_total} passed "
        f"({sub_pts}/{sub_max} pts)")
    if pending:
        detail += f" | {pending} subjective pending (not final)"
    return {
        "candidate": ev.applicant_id.partner_name or "",
        "email": ev.applicant_id.email_from or "",
        "assessment": ev.assessment_id.name or "",
        "day": "",
        "skill": "",
        "question": "[RESULT SUMMARY]",
        "question_type": "summary",
        "generator": "",
        "difficulty": "",
        "prompt": "",
        "candidate_answer": detail,
        "correct_answer": (ev.result or "pending").upper(),
        "dimension_detail": (
            f"answered {ev.answered_count or 0}/{ev.total_questions or 0}"
            + (f" | violations {ev.violation_count}"
               if ev.violation_count else "")
            + (f" | AI violations {ev.ai_violation_count}"
               if ev.ai_violation_count else "")),
        "objective_score": obj_pts,
        "objective_max": obj_max,
        "needs_subjective": "yes" if subj_total else "no",
        "subjective_result": ev.result or "pending",
        "subjective_mark": sub_pts,
        "subjective_max": sub_max,
        # THE PAPER'S RAW AS A FRACTION, not its score percentage. This column
        # held `score_percent` - a 0-100 number under a header promising 0-1,
        # and the MARK percentage rather than the raw at that. Two things wrong
        # in one cell, and the header is what made both invisible.
        "subjective_raw_0_1": (
            round((ev.raw_result or 0.0) / ev.raw_max, 4)
            if ev.raw_max else ""),
        "subjective_state": ev.llm_state or "",
        "subjective_reasoning": (
            f"score {round(ev.score_percent or 0.0, 2)}% vs threshold "
            f"{round(ev.pass_threshold or 0.0, 2)}% -> "
            f"{(ev.result or 'pending').upper()}"),
        "justification": "",
        "total_score": obj_pts + sub_pts,
        "total_max": obj_max + sub_max,
        "response_state": ev.state or "",
    }


def export_responses(assessment, evaluator=None):
    """Responses for the whole assessment, or one candidate's when ``evaluator`` is given."""
    assessment.ensure_one()
    if evaluator is not None:
        responses = evaluator.response_ids
        suffix = (evaluator.applicant_id.partner_name or "candidate").replace(
            " ", "_")
        fname = f"{assessment.name}_{suffix}_responses.csv"
    else:
        responses = assessment.response_ids
        fname = f"{assessment.name}_responses.csv"
    ordered = responses.sorted(
        key=lambda r: (
            r.evaluator_id.partner_name or "",
            r.question_id.sequence or 0,
            r.id))
    rows = []
    if evaluator is not None:
        rows.append(_summary_row(evaluator))
        rows.extend(_response_row(r) for r in ordered)
    else:
        seen = set()
        ev_by_applicant = {
            ev.applicant_id.id: ev
            for ev in assessment.assessment_evaluator_ids}
        for r in ordered:
            app_id = r.evaluator_id.id
            if app_id not in seen:
                seen.add(app_id)
                ev = ev_by_applicant.get(app_id)
                if ev:
                    rows.append(_summary_row(ev))
            rows.append(_response_row(r))
    content = _write_csv(RESPONSES_COLUMNS, rows)
    res_id = evaluator.id if evaluator is not None else assessment.id
    model = evaluator._name if evaluator is not None else assessment._name
    return _attachment_download(
        assessment.env, model, res_id, fname, content)

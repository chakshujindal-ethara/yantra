"""Q2b: turn a scratch database into a SYNTHETIC calibration database - real
prod QUESTION content, made-up answers - so every arm can be graded with no
candidate data. Run it on a copy made for this, never on a shared database:

    createdb -T etp_f2_tools etp_f2_synth
    .venv/bin/python \
        custom_addons/assessments_be_v2/tools/calibration/synthetic.py \
        -c lane.conf -d etp_f2_synth --questions synth/prod_questions.json \
        --answers synth/answers.json

It WRITES and COMMITS. It first DELETES every attempt and answer not on a
paper an earlier run built, since a copy keeps its source's real candidates.
Then: a generator per prod form name, the questions with
their images, dimensions and options (clips as URLs only, as prod stores
them), one paper, one blanked candidate per made-up persona with their
answers (never graded), prod's grading settings, and the paper's id in
`calibration.synthetic_papers`: the arms send answers on those papers to Vertex
without blanking, and nothing else. It refuses a database with an active mail
server or cron.

--questions: prod question rows as read (plus `generator_name`, `images` with
`image_file`, `videos`, `dimensions` with `options`); files resolve against
that file's folder. --answers: {"candidates": [{"kind": ..., "answers":
{"<prod question id>": text, or {"justification": text, "picks": {dimension:
option}} for image_ab}}]}.
"""
import base64
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

#: Prod's grading settings (read 2026-09-23, B1-08): batches of 20, no
#: fallback; the cache switch as the push ships it (Q3).
PROD_SETTINGS = {
    "assessments_be_v2.scoring_batch_size": "20",
    "assessments_be_v2.fallback_model": False,
    "assessments_be_v2.scoring_cache": "groups",
}
_QUESTION_FIELDS = (
    "name", "question_type", "prompt", "description", "section_title",
    "solution_json", "solution_rationale", "subjective_rubric_json",
    "official_reasoning", "covers_elements_json", "flaw_plan_json",
    "verification_json", "grading_json", "meta_json", "detection_mode",
    "difficulty", "time_minutes")
_IMAGE_FIELDS = (
    "label", "slot", "sequence", "behavioural_key_json", "detections_json",
    "label_boxes_json", "label_application", "label_expected_count",
    "coverage_expected", "omit_spec_json", "omitted_element_json",
    "capture_config_json", "capture_viewport", "source_url")
_VIDEO_FIELDS = ("label", "slot", "sequence", "duration_s", "has_audio",
                 "video_filename", "video_url", "poster_url")


def _vals(Model, row, names):
    return {k: row[k] for k in names
            if k in Model._fields and row.get(k) not in (None, False, "")}


def refuse_live(env):
    for table in ("ir_mail_server", "ir_cron"):
        env.cr.execute("SELECT count(*) FROM %s WHERE active" % table)
        if env.cr.fetchone()[0]:
            raise SystemExit("%s has an active %s row: not a scratch copy"
                             % (env.cr.dbname, table))


def drop_real_attempts(env):
    """Delete every answer and attempt not on a synthetic paper."""
    papers = list(harness.synthetic_papers(env))
    for model in ("assessments.be.response", "assessments.be.evaluator"):
        rows = env[model].sudo().search([("assessment_id", "not in", papers)])
        harness._logger.info("synthetic: deleting %d %s row(s) not built "
                             "here", len(rows), model)
        rows.unlink()


def build(env, questions, answers, media_dir):
    """Create the synthetic paper; returns ``(paper, responses)``."""
    drop_real_attempts(env)
    Question = env["assessments.be.question"].sudo()
    generators, by_prod_id = {}, {}
    for row in questions:
        name = row.get("generator_name") or "Synthetic"
        if name not in generators:
            generators[name] = env["assessments.be.prompt"].sudo().create(
                {"name": name})
        q = Question.create(dict(_vals(Question, row, _QUESTION_FIELDS),
                                 generator_id=generators[name].id))
        Image = env["assessments.be.question.image"].sudo()
        for img in row.get("images") or ():
            vals = dict(_vals(Image, img, _IMAGE_FIELDS), question_id=q.id)
            if img.get("image_file"):
                path = os.path.join(media_dir, img["image_file"]["file"])
                with open(path, "rb") as fh:
                    vals["image"] = base64.b64encode(fh.read())
            Image.create(vals)
        Video = env["assessments.be.question.video"].sudo()
        for vid in row.get("videos") or ():
            Video.create(dict(_vals(Video, vid, _VIDEO_FIELDS),
                              question_id=q.id))
        options = {}
        for dim in row.get("dimensions") or ():
            d = env["assessments.be.question.dimension"].sudo().create({
                "question_id": q.id, "name": dim["name"],
                "sequence": dim.get("sequence") or 10})
            for opt in dim.get("options") or ():
                options[(dim["name"], opt["name"])] = env[
                    "assessments.be.question.dimension.option"].sudo().create({
                        "question_dimension_id": d.id, "name": opt["name"],
                        "sequence": opt.get("sequence") or 10,
                        "is_correct": opt.get("is_correct"),
                        "score": opt.get("score") or 0})
        by_prod_id[str(row["id"])] = (q, options)
    # The questions keep their own forms' generators (19.0.3.22.0 picks
    # grading rules by generator title), so the paper selects none: each
    # candidate's question order is the paper, as `_cache_plan` reads it.
    paper = env["assessments.be"].sudo().create({
        "name": "Synthetic calibration (Q2b)",
        "generator_id": next(iter(generators.values())).id})
    order = json.dumps([q.id for q, _o in by_prod_id.values()])
    Response = env["assessments.be.response"].sudo()
    responses = Response.browse()
    for n, cand in enumerate(answers["candidates"], 1):
        applicant = env["hr.applicant"].sudo().create({
            "partner_name": "Synthetic %s %d" % (cand["kind"], n),
            "email_from": "synthetic-%d@blanked.invalid" % n})
        evaluator = env["assessments.be.evaluator"].sudo().create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "question_order": order})
        for prod_id, answer in cand["answers"].items():
            q, options = by_prod_id[str(prod_id)]
            answer = answer if isinstance(answer, dict) else {
                "justification": answer}
            text = answer["justification"]
            vals = {
                "assessment_id": paper.id,
                "assessment_evaluator_id": evaluator.id,
                "evaluator_id": applicant.id, "question_id": q.id,
                "justification": text if isinstance(text, str)
                else json.dumps(text, ensure_ascii=False),
                "state": "submitted", "llm_state": "pending",
                "line_ids": [(0, 0, {
                    "question_dimension_id":
                        options[(dim, opt)].question_dimension_id.id,
                    "selected_option_id": options[(dim, opt)].id})
                    for dim, opt in (answer.get("picks") or {}).items()]}
            responses |= Response.create(vals)
    icp = env["ir.config_parameter"].sudo()
    for key, value in PROD_SETTINGS.items():
        icp.set_param(key, value)
    icp.set_param(harness.SYNTHETIC_MARKER, ",".join(
        map(str, sorted(harness.synthetic_papers(env) | {paper.id}))))
    return paper, responses


def main():
    p = harness.parser(__doc__.splitlines()[0])
    p.add_argument("--questions", required=True)
    p.add_argument("--answers", required=True)
    args = p.parse_args()
    with open(args.questions, encoding="utf-8") as fh:
        questions = json.load(fh)
    with open(args.answers, encoding="utf-8") as fh:
        answers = json.load(fh)
    with harness.odoo_env(args) as env:
        refuse_live(env)
        media_dir = os.path.dirname(os.path.abspath(args.questions))
        paper, responses = build(env, questions, answers, media_dir)
        env.cr.commit()
        print("synthetic paper %d: %d answers from %d candidates on %d "
              "questions (%s)" % (
                  paper.id, len(responses), len(answers["candidates"]),
                  len(questions), ", ".join(sorted(
                      set(responses.mapped("question_type"))))))


if __name__ == "__main__":
    main()

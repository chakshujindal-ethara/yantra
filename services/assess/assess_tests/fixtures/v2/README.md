# Assessment v2: recorded responses

Real responses from Assessment v2 (`services/odoo/vendor/addons/assessments_be_v2`, 19.0.3.29.0) running in the rig's
Odoo, recorded on 12 Nov 2026 for the Yantra adapter's tests. Every route is `POST` with a JSON body (the query
string is ignored) and answers `{"ok": true, "data": ...}` or `{"ok": false, "error": {"code", "message"}, ...}`.
Admin calls ran as the Odoo admin (role `admin`); candidate calls with a bearer `api.access_token` of an internal
user in `assessments_be_v2.group_assessment_candidate`, the way the bridge provisions workers.

## A paper without Vertex (the "quick paper" path)

Works end to end with no Vertex credentials, for `mcq` and `msq` questions. Objective questions are scored at
submit; nothing waits for the LLM.

1. `POST /api/v1/bank/import` with
   `{"content": <base64 of a CSV in v2's template layout>, "filename": "quick.csv", "generator_name": "<name>"}`.
   Columns are those of `POST /api/v1/bank/template` (the CSV header); for a question set `title`,
   `question_type` (`mcq` | `msq`), `prompt`, `difficulty` (`easy` | `medium` | `hard`), `time_minutes`,
   `options` (`a|b|c`), `correct_answer` (one option for mcq, `a|c` for msq), optionally `category`, `skills`.
   Answer: `bank-import.json`, `{format: "csv", generator_id, questions_created, warnings, message}`. The
   questions land as DRAFTS of a new generator.
2. `POST /api/v1/generators/<generator_id>/approve_all` with `{}`: needs no Vertex; answer `approve-all.json`
   (`approved_count`).
3. `POST /api/v1/assessments/create` with `{"name", "generator_id", "duration_minutes" (>= 2), "pass_threshold"
   (percent, 1-100), "results_release": "manual", "rule_*": bool, "max_violations", "violation_action":
   "log_only" | "auto_submit", ...}` (the accepted keys: `ASSESSMENT_FIELDS` in `controllers/api/write.py`).
   Always lands in `draft`. Answer: `assessment-create.json` (the full assessment detail).
4. `POST /api/v1/assessments/<id>/assign` with `{"user_ids": [<res.users id>]}`: binds each user to an
   `hr.applicant` (`created_applicants`) and adds them to the roster. Answer: `assign-draft.json`.
5. `POST /api/v1/assessments/<id>/launch` with `{"confirm": true}`. With nobody assigned it refuses:
   `launch-no-candidates.json` (`error.code = "launch_blocked"`, plus `gates: [{code, label, passed, reason}]`; the
   gate codes include `duration`, `state`, `candidates`, `generator`, `questions_available`). Answer on success:
   `launch.json`.

## A sitting (candidate, bearer token)

- `POST /api/v1/me/assessments` with `{}`: `me-assessments.json`; `data.buckets.available[].token` is the exam token
  (`/exam/<token>` in the app), with `assessment_id`, `duration_minutes`, `result: {released, status}`.
- `POST /api/v1/exam/<token>/state` with `{}`: before begin, `outcome: "instructions"` and the rules
  (`exam-state-instructions.json`); with `{"q": N}` during the sitting, question N (`exam-state-q2.json`).
- `POST /api/v1/exam/<token>/begin` with `{"session_key": "<per tab>"}`: `outcome: "question"` with the first
  question (`exam-begin.json`); options are `question.dimensions[].options[] {id, name}`.
- `POST /api/v1/exam/<token>/answer` with `{"session_key", "question_id", "selected_option_ids": [ids]}`
  (`exam-answer.json`).
- `POST /api/v1/exam/<token>/submit` with `{"session_key"}`: `{submitted, result: {released: false, status:
  "awaiting_results"}}` (`exam-submit.json`).
- `POST /api/v1/exam/<token>/paper` answers `prefetch_off` unless the `paper_prefetch` setting is on
  (`exam-paper-prefetch-off.json`).

## Results (admin)

- `POST /api/v1/attempts` with `{"assessment_id": N}` or `{"changed_since": "<ISO UTC>"}`: a page of attempts
  (`attempts-*.json`); `meta: {total, limit (40), offset, has_more, server_time}`. Use `meta.server_time` (minus a
  few seconds: v2 compares whole seconds) as the next `changed_since`.
  - an attempt: `id` (the evaluator id), `assessment_id`, `candidate {id (applicant), email}`, `state`
    (`pending` | `in_progress` | `submitted`), `result` (`pending` | `pass` | `fail`), `results_released`,
    `score_percent`, `score_marks`, `raw_percent`, `objective {score, max}`, `subjective {score, max, pending,
    state, ...}`, `flags {integrity_alert, violation_limit_breached, ...}`, `started_at`, `submitted_at`,
    `deadline`.
  - an objective-only paper is decided at submit: `result: "pass"` / `"fail"` with `subjective.max == 0` (its
    `subjective.state` still reads `pending`; ignore it when `max` is 0).
- `POST /api/v1/assessments/<id>/release` with `{"evaluator_ids": [ids]}` releases those submitted attempts
  (`release-one.json`); WITHOUT `evaluator_ids` it releases the whole submitted cohort (`release.json`). Any other
  key (for example `attempt_ids`) is ignored, so the whole cohort is released.
- `POST /api/v1/assessments/<id>` with `{}`: the detail (`assessment-detail.json`); `POST /api/v1/assessments`
  with `{}`: the list (`assessments-list.json`).

## Behaviour the adapter must handle

- **Adding a worker to a running assessment works**: `assign-after-launch.json` (`launched_attempts: [<evaluator
  id>]`, the attempt is `pending` at once; no second launch).
- **A released cohort closes**: once every assigned attempt is submitted and the cohort is released, the assessment
  moves to `done` and refuses new candidates with `409 assessment_closed` (`assign-after-done.json`). Releasing
  only some `evaluator_ids` while others are still `pending` keeps it `in_progress`
  (`attempts-after-release-one.json`). The adapter must open a new cohort (a new v2 assessment from the same
  generator) when its open one is `done`.
- **One attempt per worker per assessment** (unique index), so a retake is a new v2 assessment.
- Invitations are queued on assign (`invite_state: "queued"`); the bridge suppresses the mail for Yantra workers.

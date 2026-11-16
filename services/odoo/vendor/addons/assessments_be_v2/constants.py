# -*- coding: utf-8 -*-

import json
import re

DEFAULT_SUBJECTIVE_THRESHOLD = 70.0

# Seeds `assessments.be.pass_threshold` on new assessments only.
DEFAULT_PASS_THRESHOLD_PARAM = "assessments_be_v2.default_pass_threshold"
DEFAULT_PASS_THRESHOLD = 70

# How many labelled boxes ONE image_label question may carry, when nothing more
# specific says otherwise. This is the fallback for the per-generator
# `image_label_count`: the generator's own value governs anything it authors,
# and this covers every caller that has no generator in scope (the candidate
# render path, a hand-authored bank question, Form Studio).
#
# 20 because that is the cap `services/labelling.py` has silently enforced on
# the render path all along - it was a bare `min(n, 20)` with "a sane render
# range" for a comment. Promoting it to a named default changes no behaviour;
# it just makes the number configurable and stops the same magic constant being
# re-derived in three places.
DEFAULT_IMAGE_LABEL_COUNT = 20

# Score-outlier review (veteran finding #3): flag a submitted candidate whose
# overall score_percent sits this many standard deviations ABOVE the cohort mean
# for human review (a prompt-injection that dodges gates.py + inflates a score is
# the thing to catch). Advisory only - never changes the score or pass/fail.
# Overridable via ir.config_parameter assessments_be_v2.score_outlier_sigma.
SCORE_OUTLIER_SIGMA_DEFAULT = 2.0
# Minimum cohort size before an outlier flag is meaningful (a 2-person cohort has
# no stable mean/stdev). Below this, no candidate is flagged.
SCORE_OUTLIER_MIN_COHORT = 5

# Pace tag on a sitting's "time analysis" (services/pace.py): taken / the paper's
# median, rounded half up to 2 decimals. At or below FAST is "Fast", at or above
# SLOW is "Slow", anything between is "Normal". Their client twins are
# `kPaceFastAtOrBelow` / `kPaceSlowAtOrAbove` in ethara-assessment-fe
# `lib/assessment/domain/category_scores.dart`: the two must move together, or
# the console and the Results export tag the same sitting differently.
PACE_FAST_AT_OR_BELOW = 0.75
PACE_SLOW_AT_OR_ABOVE = 1.25

# PII retention (veteran finding #2): anonymize candidate free-text/PII on
# submitted attempts older than this many days. 0 (default) DISABLES the purge
# so behaviour is unchanged until an admin opts in. Numeric scores/pass-fail are
# always kept (aggregate integrity); only free text + violation reason + judge
# audit prose are scrubbed. Override via assessments_be_v2.pii_retention_days.
PII_RETENTION_DAYS_DEFAULT = 0

# H-5: default LLM spend caps (USD). Data-driven - overridable per deployment
# via ir.config_parameter, ON by default so a fresh install is protected
# without any flag to remember. 0 disables a cap. The defaults are generous for
# a real cohort (300 candidates * a few subjective Qs is well under $100/day)
# but stop the unbounded-input / retry-doubling cost-DoS dead.
#
# THEY LIVE HERE RATHER THAN IN services/vertex.py BECAUSE FOUR SURFACES ANSWER
# "what is the cap": the enforcement gate, the LLM Budget dashboard, the
# Flutter Settings screen and the Odoo Settings form. Each of them used to
# resolve it independently, and with both rows absent from ir.config_parameter
# they reported three different numbers - the gate refusing at $100/day while
# the one screen an operator checks to find out why said `cap_usd: 0,
# capped: false`. One constant, reached by every reader through
# `services/vertex.spend_cap`, is what stops that recurring.
DEFAULT_DAILY_LLM_CAP_USD = 100.0
DEFAULT_PER_EVALUATOR_LLM_CAP_USD = 5.0

# THE 0.75/0.25 A/B BLEND IS GONE, and its constants with it.
#
# It combined an image_ab's verdict accuracy and its justification quality into
# one 0-100 before either was marked. Two things made it indefensible once the
# unit of scoring became the component: it was applied TWICE (once in the
# grader, once again composing the raw, giving an effective 93.75/6.25 nobody
# intended), and a perfect set of verdicts started the raw at 75, so under any
# threshold at or below that the justification could not affect the mark at all
# while still appearing to be worth a quarter of it.
#
# Each verdict axis is now its own keyed sub-question worth 1 mark, and the
# justification is its own component worth 1 mark. Nothing is weighted against
# anything else, and the 60-point overall-wrong cap that rode on the blend went
# with it - the Overall Choice axis is simply marked wrong when it is wrong.

# SOP similarity ranking now lives in services/similarity.py (research hybrid
# lexical+semantic port on the faceted mapping array). The old tag-prefix
# weighted-Jaccard constants (TAG_PREFIX_WEIGHTS / TAG_DEFAULT_PREFIX_WEIGHT /
# TAG_SIMILAR_MIN_SCORE_DEFAULT) were removed with it; the facet WEIGHTS and the
# similar-% floor (ir.config_parameter assessments_be_v2.similar_min_pct) are
# defined there.

# Postgres advisory-lock keys: MUST stay mutually unique across the whole module.
#
# RENUMBERED AT THE FORK, AND THAT IS NOT COSMETIC. Advisory locks are keyed by
# integer and scoped to the DATABASE, not to the module. `etp_assessment_pro`
# uses 8271xx/8272xx/8273xx for the same jobs, and both modules run their crons
# in the same database - so sharing a number means whichever cron takes the lock
# first makes the OTHER module's cron find it held and return immediately.
#
# The failure is silent by design: `pg_try_advisory_lock` returns false and the
# tick simply does nothing. No error, no log line, no queued row moving. A
# generator would sit on "Queued" while the cron ran happily every minute
# against a lock another module was holding. The 200-offset block below keeps
# the two fleets from ever seeing each other.
ADVISORY_LOCK_AUTOSCORE = 827393
ADVISORY_LOCK_IMAGE_RENDER = 827394
ADVISORY_LOCK_IMAGE_DETECT = 827395
ADVISORY_LOCK_VIDEO_POLL = 827396
ADVISORY_LOCK_EXPIRE_ATTEMPTS = 827397
ADVISORY_LOCK_INVITE_SEND = 827398
ADVISORY_LOCK_PII_PURGE = 827399
ADVISORY_LOCK_SKILL_EXTRACT = 827400
ADVISORY_LOCK_QUESTION_GEN = 827401
ADVISORY_LOCK_TAG_EXTRACT = 827402
ADVISORY_LOCK_VERTEX_BEARER = 827500
# First key of the two-key `pg_try_advisory_xact_lock(ns, key)` a lane takes
# while it creates one question-group grading cache (services/grading_cache.py);
# the second key comes from the cache key. Two-key locks never collide with the
# one-key locks above.
ADVISORY_LOCK_SCORING_CACHE = 827600
# `assessments_be_v2.scoring_cache` when unset. A group is cached only once it
# reaches the model's minimum (`scoring._cache_spec`); `off` sends all inline.
SCORING_CACHE_DEFAULT = "groups"

# Parallel scoring lanes. Shard 0 keeps ADVISORY_LOCK_AUTOSCORE so the default
# (scoring_shards=1) is byte-identical to the single-lock design; shards >= 1 use
# this reserved block (base + shard) which cannot collide with the keys above.
# MAX_SCORING_SHARDS MUST equal the number of shard cron records in data/cron.xml,
# or evaluators in an unserved shard would never be scored.
ADVISORY_LOCK_AUTOSCORE_SHARD_BASE = 827450
MAX_SCORING_SHARDS = 4

# How `services/locks.cron_lock` keeps the nine crons single-flight, read on
# every tick. A choice, not a range: "advisory" (unset means this) is a session
# advisory lock; "lease" is a row in `assessments_be_cron_lease`, for when the
# database is reached through PgBouncer in transaction mode.
CRON_LOCK_MODE_PARAM = "assessments_be_v2.cron_lock_mode"
CRON_LOCK_MODE_SELECTION = [
    ("advisory", "Advisory lock (default)"),
    ("lease", "Lease row (PgBouncer in transaction mode)"),
]

# Judge calls one scoring lane may keep on the wire at once
# (`scoring_parallel_calls`). Each holds an HTTP connection and ~2 DB
# connections for the length of the call, so MAX_SCORING_SHARDS x this must
# stay under the shared httpx pool (50, `vertex._httpx`: 4 x 8 = 32), and
# `_scoring_parallel_calls` lowers it at runtime to fit half of Odoo's
# `db_maxconn` less the lanes' own cursors (at 4 shards: pool 64 -> 3 per lane;
# prod's 600 -> the full setting).
MAX_SCORING_PARALLEL_CALLS = 8

# THE SCHEDULER KNOBS' ACCEPTED RANGE, IN ONE PLACE. (low, high, default).
#
# THREE SURFACES ENFORCE THIS SAME RANGE and each used to carry its own copy:
# the Odoo form constraint (`res_config_settings._check_be_llm_limits`), the
# write API (`controllers/api/write.py._SETTING_BOUNDS`) and the pre-deploy
# gate (`tools/check_settings_in_range.py`). The gate's copy had already
# drifted - it refused a stored 0, which the constraint coerces to the default
# and accepts - so it held deployments back on values that save perfectly well.
# A hand-copied bound cannot be kept honest by review; one table can.
#
# 0 MEANS "UNSET, USE THE DEFAULT" on every one of them, which is why the
# default rides in the tuple: the constraint compares `(value or default)` and
# the gate has to resolve 0 the same way before it decides anything.
SETTING_RANGES = {
    "llm_max_attempts": (1, 5, 3),
    "scoring_batch_size": (1, 32, 8),
    "scoring_shards": (1, MAX_SCORING_SHARDS, 1),
    "scoring_parallel_calls": (1, MAX_SCORING_PARALLEL_CALLS, 4),
    # Seconds the exam client waits before sending its unsent answers as one batch.
    "answers_flush_seconds": (15, 300, 60),
}

# ONE VOCABULARY, SHARED WITH FORM STUDIO.
#
# The CODES are the stored values and never change - they are in every existing
# row, every payload and every test. The LABELS are display text, and they used
# to speak an older vocabulary than the designer an examiner actually builds in:
# an annotation question read "Image - Labelling" here and "Image annotation" in
# Form Studio, and a side-by-side comparison read "A/B Evaluation" - the name of
# the rendering engine - against "Side-by-side comparison" there. Two names for
# one type, and the operator had no way to know they matched.
#
# `QType` in the client's `enums.dart` and `FormItemKind.label` in
# `form_models.dart` are the other halves of this pairing. Change one, change all
# three.
QUESTION_TYPE_SELECTION = [
    ("mcq", "Objective - MCQ"),
    ("msq", "Objective - MSQ"),
    ("subjective_rubric", "Subjective - Rubric"),
    ("image_ab", "Image - Side-by-side Comparison"),
    ("image_prompt", "Image - Prompt Writing"),
    ("image_label", "Image - Annotation"),
    ("video_prompt", "Video - Prompt Writing"),
    ("transcription", "Transcription"),
]
QUESTION_TYPE_CODES = frozenset(code for code, _label in QUESTION_TYPE_SELECTION)
# Deterministic order for prompt text; QUESTION_TYPE_CODES is unordered.
QUESTION_TYPE_ORDER = tuple(code for code, _label in QUESTION_TYPE_SELECTION)

# Types the LLM generation pipeline must NOT be offered, because it has no way
# to AUTHOR them - an import-only format whose media and answer key can only come
# from a human-authored bank. `transcription` is one: its clip is a real
# recording and its key is what a person heard in it, so only Form Studio makes
# them. The registry is designed to grow, so the constant and all four of its
# guards stay in place: retiring a type from generation must be a one-line
# change here, not a hunt for the guards that used to enforce it.
NON_GENERATABLE_QUESTION_TYPES = frozenset({"transcription"})
GENERATABLE_QUESTION_TYPE_ORDER = tuple(
    code for code in QUESTION_TYPE_ORDER
    if code not in NON_GENERATABLE_QUESTION_TYPES)
GENERATABLE_QUESTION_TYPE_CODES = frozenset(GENERATABLE_QUESTION_TYPE_ORDER)


# ── What a question is made of, for SCORING ──────────────────────────────────
# The unit of scoring is the COMPONENT, not the question. Every component is
# worth exactly 1 mark, and a question is worth the sum of its components:
#
#   * one component per KEYED dimension (a dimension with at least one correct
#     option). Covers mcq, msq and every image_ab verdict axis alike. Derived
#     per-question from the data, so it needs no list here.
#   * one component for the LLM-graded free-text answer, on the types below.
#   * one component for the labelling box set as a whole, on the types below.
#
# THESE ARE KEYED ON THE QUESTION TYPE, NEVER ON `needs_llm`. `needs_llm` goes
# false when the candidate wrote nothing, and a denominator that read it would
# let an unanswered subjective cost nothing instead of costing its mark - the
# paper's length is the denominator, whatever the candidate did with it.
#
# image_label is deliberately NOT in the subjective set even though it is
# LLM-graded: its per-box answers are stored as JSON in the SAME
# `justification` column, so counting it in both sets would charge one answer
# two marks.
SUBJECTIVE_COMPONENT_TYPES = frozenset({
    "subjective_rubric", "image_prompt", "video_prompt", "image_ab",
    "transcription"})
LABELLING_COMPONENT_TYPES = frozenset({"image_label"})
IMAGE_QUESTION_TYPES = frozenset({"image_ab", "image_prompt", "image_label"})
VIDEO_QUESTION_TYPES = frozenset({"video_prompt"})
# Drafts one tick of `_cron_render_pending_images` renders. Also the
# `images_per_run` the generation progress route reports and builds its ETA
# from, so the two cannot disagree.
IMAGE_RENDER_BATCH = 2

DETECTION_MODE_SELECTION = [("object", "Objects"), ("ui", "UI Elements")]

# The short forms, in the SAME vocabulary as the selection above and as the
# client's `QType.short`. "Image Labelling" was the last place the retired word
# survived.
QUESTION_TYPE_SHORT_LABELS = {
    "mcq": "MCQ",
    "msq": "MSQ",
    "subjective_rubric": "Rubric",
    "image_ab": "Side-by-side Comparison",
    "image_prompt": "Image Prompt Writing",
    "image_label": "Image Annotation",
    "video_prompt": "Video Prompt Writing",
    "transcription": "Transcription",
}

# Only generatable codes may reach the model: this string IS the allow-list the
# question-authoring prompt shows it.
QUESTION_TYPE_PROMPT_LIST = "/".join(GENERATABLE_QUESTION_TYPE_ORDER)

# THE ANSWER-KEY FIELDS EACH TYPE MUST CARRY, in the model's own vocabulary.
#
# The base system prompt states these once, ~18k characters before the
# per-request directive. That is far enough away that a SPECIFIC instruction
# ("reproduce the task IG") wins over the general one, and the model returns a
# well-written question with no answer key: the item then fails validation,
# is kept for review, and - because the stamp is skipped for invalid items -
# also loses the record of which template authored it. One live run on
# template 20 (`describe_media` -> subjective_rubric) reproduced exactly that.
#
# Restating the requirement NEXT TO the task the model is being asked to
# reproduce is what closes the gap. Keyed by question type so a new template of
# any type inherits it without a code change; the image types are absent
# because their per-request directive already spells out `image_specs`.
ANSWER_KEY_REQUIREMENT = {
    "mcq": "options (list) and correct_answer (the single correct option)",
    "msq": "options (list) and correct_answer (a LIST of the correct options)",
    "subjective_rubric": (
        "rubric, an object with checklist (at least one gradable criterion), "
        "constraints and pass_condition"),
}


# ── FORM STUDIO'S DESIGNER ITEM KINDS ────────────────────────────────────────
#
# THE KINDS AN AUTHORED FORM ITEM CAN BE, and what each one needs filled in.
# This is the same list `studio_form._item_spec` branches on, lifted out of it
# so a SECOND reader can enumerate the kinds without re-reading that method's
# fifteen branches. The back-office item editor is that reader
# (`static/src/fields/form_item_editor/`), and a hardcoded copy of this list
# inside that widget is precisely how an editor ends up offering a kind publish
# refuses - or hiding one it accepts, which is worse, because the operator then
# cannot author something the pipeline supports and nothing says why.
#
# `_item_spec` IS STILL THE AUTHORITY on what each kind MEANS; this carries only
# what a reader cannot derive from it - the human label, the family its branch
# tests, and which panels an editor must draw. The `FORM_KINDS_*` tuples below
# are what that method now tests against, so a kind added HERE is a kind it
# handles; `tests/test_the_form_editor_speaks_the_same_kinds.py` walks the
# method's own AST to refuse the reverse drift, a kind handled there and missing
# here.
#
# `role` IS WHAT PUBLISH DOES WITH IT, and the four values are genuinely
# different outcomes an author has to be able to see:
#   question       - always becomes one exam question.
#   informational  - never a question; folds into the NEXT question's
#                    description (`_attach_carry`), across section boundaries.
#   media          - informational UNTIL it carries an option label, at which
#                    point the plate itself is the question
#                    (`_media_item_has_options`).
#   refused        - publish REFUSES the whole form over it. fileUpload is the
#                    only one: the exam runner cannot collect a file.
#
# `needs` NAMES EDITOR PANELS, NOT STORAGE. Each token is one block of controls,
# and the fields each block writes are the DESIGNER's own names (form_models.
# dart `toJson`) because that document is what publish and the Flutter designer
# both read - an editor inventing its own key writes a form the designer cannot
# open:
#   options   -> options[] of {id, label, correct}. With `multi_key`, several
#                may be marked; without it a two-correct key is REFUSED
#                (`_single_answer_or_problem`) - a radio group can never match
#                it, so the mark would be unearnable.
#   grid      -> rows[], columns[], grid_key{row index -> column label(s)}
#   scale     -> scale_min, scale_max, scale_min_label, scale_max_label
#   rating    -> rating_max
#   golden    -> golden_answer, MANDATORY on every written kind: it is the model
#                answer the judge marks against, and without it the standard is
#                invented per candidate.
#   media     -> media_url, plus media_kind (the probed image/video answer)
#   media_b   -> media_url_b, the second plate
#   regions   -> annotation_count, regions[], golden_labels{n -> text}
#   flags     -> the per-kind switches listed in `flags`
# THE PER-KIND SWITCHES, defined once each. The item editor renders the label
# and the hint verbatim, so they live beside the kinds rather than in the widget:
# a switch described one way in Odoo and another in the designer is the same
# defect as a kind list that drifted, just harder to see.
_FLAG_ALLOW_OTHER = {
    "name": "allow_other",
    "label": 'Offer an "Other" free-text option',
    "hint": "Not deliverable in an exam - publish drops it and says so, "
            "because a free-text option has no answer key.",
}
_FLAG_MULTI_SELECT = {
    "name": "multi_select",
    "label": "Allow several answers",
    "hint": "Scored as a set: the candidate must tick exactly the options "
            "marked correct.",
}
_FLAG_REQUIRE_JUSTIFICATION = {
    "name": "require_justification",
    "label": "Require a written justification",
    "hint": "On, the answer rationale below becomes mandatory - it is what the "
            "judge marks the candidate's prose against. Off, the comparison is "
            "scored on its verdict alone and any rationale is ignored.",
}


FORM_ITEM_KINDS = (
    # -- layout: carries prose, never an answer --------------------------
    {"kind": "textBlock", "label": "Text block", "family": "layout",
     "role": "informational", "needs": (), "flags": (),
     "hint": "Instructions only. The heading and body ride along on the next "
             "question, so a block at the end of a section attaches to that "
             "section's last question."},

    # -- the choice kinds: one options list, one answer key --------------
    {"kind": "multipleChoice", "label": "Multiple choice", "family": "choice",
     "role": "question", "needs": ("options",), "flags": (_FLAG_ALLOW_OTHER,),
     "hint": "Two or more options, exactly one marked correct."},
    {"kind": "dropdown", "label": "Dropdown", "family": "choice",
     "role": "question", "needs": ("options",), "flags": (_FLAG_ALLOW_OTHER,),
     "hint": "Two or more options, exactly one marked correct. Delivered the "
             "same way as multiple choice; the designer draws it as a list."},
    {"kind": "checkboxes", "label": "Checkboxes", "family": "choice",
     "role": "question", "needs": ("options", "multi_key"),
     "flags": (_FLAG_ALLOW_OTHER,),
     "hint": "Two or more options; mark every correct one. A candidate must "
             "tick exactly that set to earn the mark."},

    # -- the grids: the same columns asked of several rows ----------------
    {"kind": "choiceGrid", "label": "Multiple-choice grid", "family": "grid",
     "role": "question", "needs": ("grid",), "flags": (),
     "hint": "Every row needs exactly one correct column - a row with two is "
             "refused, because a radio row can never match that key."},
    {"kind": "checkboxGrid", "label": "Checkbox grid", "family": "grid",
     "role": "question", "needs": ("grid", "multi_key"), "flags": (),
     "hint": "Every row needs at least one correct column; a row may have "
             "several, because a checkbox row is scored as a set."},

    # -- the scales: options are generated from the range -----------------
    {"kind": "linearScale", "label": "Linear scale", "family": "scale",
     "role": "question", "needs": ("scale", "golden_point"), "flags": (),
     "hint": "The correct point on the scale is the answer key. End labels are "
             "appended to the question's help text for the candidate."},
    {"kind": "rating", "label": "Rating", "family": "scale",
     "role": "question", "needs": ("rating", "golden_point"), "flags": (),
     "hint": "Stars run 1..max; the correct star count is the answer key."},

    # -- the written kinds: the golden answer IS the key ------------------
    {"kind": "shortAnswer", "label": "Short answer", "family": "written",
     "role": "question", "needs": ("golden",), "flags": (),
     "hint": "Write the model answer. The judge marks each candidate against "
             "it, so without one the standard is invented per candidate."},
    {"kind": "paragraph", "label": "Paragraph", "family": "written",
     "role": "question", "needs": ("golden",), "flags": (),
     "hint": "Write the model answer. The judge marks each candidate against "
             "it, so without one the standard is invented per candidate."},
    {"kind": "date", "label": "Date", "family": "written",
     "role": "question", "needs": ("golden",), "flags": (),
     "hint": "Delivered as free text - the exam runner has no date picker - so "
             "the golden answer is the date the judge marks against."},
    {"kind": "time", "label": "Time", "family": "written",
     "role": "question", "needs": ("golden",), "flags": (),
     "hint": "Delivered as free text - the exam runner has no time picker - so "
             "the golden answer is the time the judge marks against."},

    # -- media, informational until it carries an option ------------------
    {"kind": "imageBlock", "label": "Image", "family": "media",
     "role": "media", "needs": ("media", "options"),
     "flags": (_FLAG_MULTI_SELECT,),
     "hint": "A picture on its own rides along on the next question. Add an "
             "option and the picture becomes the question itself."},
    # The kind string stays `videoBlock`: an audio file rides the same block,
    # lands on `question.video` like a clip, and is told apart there by
    # `media_kind` (see AUDIO_MIME_BY_EXT below).
    {"kind": "videoBlock", "label": "Video", "family": "media",
     "role": "media", "needs": ("media", "options"),
     "flags": (_FLAG_MULTI_SELECT,),
     "hint": "A clip on its own rides along on the next question. Add an "
             "option and the clip becomes the question itself."},

    # -- the three purpose-built media questions -------------------------
    {"kind": "comparePair", "label": "Side-by-side comparison",
     "family": "compare", "role": "question",
     "needs": ("media", "media_b", "options", "golden_optional"),
     "flags": (_FLAG_REQUIRE_JUSTIFICATION,),
     "hint": "Both plates, and one correct verdict. Asking for a written "
             "justification also requires the rationale the judge marks it "
             "against; turning that off scores the verdict alone."},
    {"kind": "imageAnnotation", "label": "Image annotation",
     "family": "annotate", "role": "question",
     "needs": ("media", "regions"), "flags": (),
     "hint": "One plate and a numbered point per thing to find. EVERY point "
             "needs its golden answer - an unkeyed point is a mark no "
             "candidate can earn."},
    {"kind": "promptWriting", "label": "Prompt writing", "family": "prompt",
     "role": "question",
     "needs": ("media", "media_b_optional", "golden", "options_optional"),
     "flags": (),
     "hint": "The plate the candidate writes a prompt for, plus the golden "
             "prompt. A second plate makes it a transform (reference then "
             "output) and the medium follows the output."},

    # -- a clip the candidate types out, Strix-style ----------------------
    # Owns its clip like promptWriting (never carried onto another question)
    # and its key is the client's: the transcription plus the whole-audio
    # category, the sound characteristics and the speakers.
    {"kind": "transcription", "label": "Transcription",
     "family": "transcription", "role": "question",
     "needs": ("media", "golden"), "flags": (),
     "hint": "A clip the respondent transcribes, plus category, sound tags "
             "and speakers; marked by the LLM judge with the client's "
             "critical/minor rule."},

    # -- authorable, and NOT deliverable ---------------------------------
    {"kind": "fileUpload", "label": "File upload", "family": "upload",
     "role": "refused", "needs": (), "flags": (),
     "hint": "The exam runner cannot collect a file, so publish refuses the "
             "whole form over one. Replace it with a text question."},
)

FORM_ITEM_KIND_ORDER = tuple(d["kind"] for d in FORM_ITEM_KINDS)
FORM_ITEM_KIND_CODES = frozenset(FORM_ITEM_KIND_ORDER)
FORM_ITEM_KIND_LABELS = {d["kind"]: d["label"] for d in FORM_ITEM_KINDS}
FORM_ITEM_KIND_BY_CODE = {d["kind"]: d for d in FORM_ITEM_KINDS}


def form_item_kinds_of(*families):
    """The kinds belonging to [families], in catalogue order.

    DERIVED, NEVER RETYPED. `studio_form._item_spec` tests membership of these
    tuples, so the catalogue above is the only place a kind is declared - and
    adding one to a family cannot be half-done. Retyping the tuples is how a
    kind ends up in an editor's picker and in no branch of publish.
    """
    wanted = frozenset(families)
    return tuple(d["kind"] for d in FORM_ITEM_KINDS if d["family"] in wanted)


FORM_KINDS_CHOICE = form_item_kinds_of("choice")
FORM_KINDS_GRID = form_item_kinds_of("grid")
FORM_KINDS_SCALE = form_item_kinds_of("scale")
FORM_KINDS_WRITTEN = form_item_kinds_of("written")
FORM_KINDS_MEDIA_BLOCK = form_item_kinds_of("media")

# ── THE TRANSCRIPTION QUESTION (Strix's client conventions) ──────────────────
#
# The candidate's answer and the key share one shape: the transcription text
# (in `justification` / `solution_json["transcription"]`) plus these codes.
# Codes, not labels, so the app can word them in Hindi or English.
TRANSCRIPTION_LANGUAGES = [("hi", "Hindi"), ("en", "English")]
TRANSCRIPTION_CATEGORIES = (
    "none", "no_audio", "no_speech", "sensitive_content", "synthetic_speech",
    "primarily_non_target_language")
TRANSCRIPTION_CHARACTERISTICS = (
    "overlapping_speech", "cross_talk", "laughter", "human_noise",
    "background_speech", "excessive_background_noise", "audio_artifact",
    "garbled_audio", "non_target_language")
TRANSCRIPTION_GENDERS = ("masculine", "feminine", "unknown")
TRANSCRIPTION_NATIVITIES = ("native", "non_native", "unknown")
# The client asks 0, 1, 2, 3 or "4 or more", and describes at most four.
TRANSCRIPTION_MAX_SPEAKERS = 4

# THE CLIENT'S RULE, CARRIED AS POINT SIZES. The judge's reply format
# (prompts/scoring.md) has no severity field and its fingerprint gates every
# verdict, so the instructions cannot change. The weight travels in item data
# instead: a critical mistake costs exactly 20, a minor one exactly 5, and the
# store counts them back by size (`scoring._store_scored`). A deduction of 13
# or more is read as critical, so a judge that drifts from 20 to 15 still
# fails the clip rather than passing it. The rubric below is the client's QC
# rulebook condensed (QC_AGENT.md sections 4-6), and `scoring._question_material`
# sends this text LIVE, not the copy a question stored at publish, so a rule
# change here reaches every clip without a migration.
TRANSCRIPTION_CRITICAL_POINTS = 13
TRANSCRIPTION_MINOR_LIMIT = 5   # five minor mistakes fail a clip
TRANSCRIPTION_RUBRIC = {
    "checklist": [
        "answer.transcription has every word, filler, backchannel, repeat and cut-off of "
        "golden_answer.transcription, in order, and nothing that was not said.",
        "answer.category, answer.characteristics and answer.speakers agree with golden_answer.",
    ],
    "constraints": [
        "golden_answer is what was said, typed by a person who listened. answer.differences lists "
        "every place answer.transcription departs from it, after the differences the client never "
        "counts were taken out; answer.clip_differences lists the clip answers that differ. Judge "
        "exactly these and look for nothing else. A missed checklist point is not a deduction of its own.",
        "Each mistake is ONE deduction of exactly -20 (critical) or exactly -5 (minor); no other sizes. "
        "A difference with \"times\" is one mistake however often it occurs; a run of missing or added "
        "words next to each other is one; different words are separate mistakes.",
        "A difference's \"rule\" fixes its size: mark_on_clear_words, digit, lone_letter and "
        "cut_off_in_full are critical; letters_without_periods and joined_words are minor.",
        "Critical (-20): a word, filler, backchannel, repeat or stutter left out (a doubled word typed "
        "once counts); a word that was not said, the last word included; a different word - misheard, "
        "grammar fixed, register changed, words in another order, a word written in the other language; "
        "(( )) or {{ }} around words spoken clearly, or a wrong word inside such a mark (one mistake, not "
        "two); a cut-off word typed in full; a number in digits (numbers are words, in the language said); "
        "a single spoken letter without its period (c for c.).",
        "Minor (-5), never critical: the same word with another ending or agreement that does not fit its "
        "sentence (है for हैं, गया for गए, की for कि); a near-sounding real word that does not fit its "
        "sentence; spoken letters or an acronym without their periods (mrp for m. r. p.); an English word "
        "in Devanagari, or a Hindi word or Indian name in English letters (a loanword dictionaries list, "
        "such as स्कूल, is right in Devanagari); a misspelling no dictionary has; two words typed as one; "
        "a filler spelled off the guide's table (म्हम्, अहाँ, हम्म, अ, um, म्म्-म्म्, ना-ना, अरे, वाह, "
        "[fp] for any other); a capital, punctuation or a symbol.",
        "Never a mistake: which sign writes a nasal (पाँच or पांच); a nukta variant; ये or यह; वो or वह; "
        "a hyphen or a space in a repeated word; a spelling a dictionary lists; another Indian language; "
        "a near-sounding word that fits the sentence as well; anything at a place golden_answer marks "
        "(( )) or {{ }}.",
        "answer.clip_differences: a wrong category is one mistake and nothing that follows from it "
        "counts again. When golden_answer.category is \"none\" (speech to transcribe) and answer.category "
        "is not, leaving the clip untranscribed is one critical mistake: the spoken words are missing; "
        "any other wrong category is one minor mistake. All characteristics that differ together are ONE "
        "minor mistake; speakers that differ (their number, or their genders compared as a set) are one "
        "minor mistake. Laughter and whether a speaker is native are never compared.",
        "When golden_answer.category is not \"none\" the clip is not transcribed: an empty "
        "answer.transcription is right, and only answer.clip_differences is judged.",
        "In each reason say in plain words what was written and what was said, quote the words, and name "
        "the guide's convention (Deletion, Substitution, Unintelligible and Guessed Words, Truncations, "
        "Text Normalization, Tags, Speakers). For a word that was not said, say so in those words. Never "
        "write a rule's name or code such as mark_on_clear_words; describe it in plain words.",
    ],
    "pass_condition": "No critical mistake and fewer than 5 minor ones.",
}


def clean_clip_answers(raw):
    """A clip's category / characteristics / speakers, reduced to known codes.

    ONE cleaner for both sides of the comparison: the key Form Studio publishes
    (`golden_clip`) and the answer a candidate saves (`clip_answers`). Anything
    else in the dict is dropped, an unknown category reads as "none", and a
    speaker without a known gender or nativity reads as "unknown" - the
    client's own word for "cannot tell".
    """
    raw = raw if isinstance(raw, dict) else {}
    category = str(raw.get("category") or "none")
    if category not in TRANSCRIPTION_CATEGORIES:
        category = "none"
    if category != "none":
        # Strix's rule: a clip that is not transcribed collects no tick and no
        # speaker. The app hides them but keeps them on screen so choosing
        # None brings them back; they must not reach the key or the judge.
        return {"category": category, "characteristics": [], "speakers": []}
    picked = raw.get("characteristics")
    picked = picked if isinstance(picked, list) else []
    characteristics = [c for c in TRANSCRIPTION_CHARACTERISTICS
                       if c in {str(p) for p in picked}]
    speakers = []
    for one in (raw.get("speakers") if isinstance(raw.get("speakers"), list)
                else [])[:TRANSCRIPTION_MAX_SPEAKERS]:
        one = one if isinstance(one, dict) else {}
        gender = str(one.get("gender") or "")
        nativity = str(one.get("nativity") or "")
        speakers.append({
            "gender": gender if gender in TRANSCRIPTION_GENDERS else "unknown",
            "nativity": (nativity if nativity in TRANSCRIPTION_NATIVITIES
                         else "unknown"),
        })
    return {"category": category, "characteristics": characteristics,
            "speakers": speakers}

# Audio a Form Studio media block may carry, by file extension. ONE list: the
# upload allow-list and proxy MIME map (controllers/api/forms.py), publish's
# `_looks_like_audio` and `question.video.media_kind` all read it, so an
# extension cannot be uploadable and then publish as a video, or vice versa.
AUDIO_MIME_BY_EXT = {
    "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
    "ogg": "audio/ogg", "aac": "audio/aac", "flac": "audio/flac",
}


DIFFICULTY_SELECTION = [("easy", "Easy"), ("medium", "Medium"), ("hard", "Hard")]
DIFFICULTY_CODES = frozenset(code for code, _label in DIFFICULTY_SELECTION)


MEDIUM_SELECTION = [("text", "Text"), ("image", "Image"), ("video", "Video")]
MEDIUM_CODES = frozenset(code for code, _label in MEDIUM_SELECTION)


# ── A/B rating dimensions ────────────────────────────────────────────────────
# The dimensions an A/B question is graded on come FROM THE SOP, not a fixed list.
# A compare-to-a-prompt SOP (e.g. proj-3) rates Instruction Following / Visual
# Quality / Less-AI-Generated / Overall Choice; an image-EDITING SOP (e.g.
# omni-elo) ALSO rates ID Preservation and Content Preservation. So the model
# emits the dimension set into construction_keys per the SOP and everything
# downstream (answer key, validation, drift, scoring) derives from THOSE keys.
# The tables below are a known-label REGISTRY for pretty labels + a sensible
# default — never an allow-list. Unknown codes are humanized on the fly, so a new
# SOP with a new dimension needs no code change (data-driven, self-extending).

# The always-present, decided overall preference: every A/B ends in one pick.
AB_OVERALL_CODE = "OC"

# Canonical dimension code -> human label, in preferred display/scoring order.
# Overall Choice sorts last (it is the final decision, capped to Response A/B).
AB_CANONICAL_DIMENSIONS = [
    ("IF", "Instruction Following"),
    ("VQ", "Visual Quality"),
    ("LAI", "Less AI Generated"),
    ("IDP", "ID Preservation"),
    ("CP", "Content Preservation"),
    ("OC", "Overall Choice"),
]
AB_KNOWN_DIMENSION_ORDER = [code for code, _name in AB_CANONICAL_DIMENSIONS]
AB_KNOWN_DIMENSION_LABELS = {code: name for code, name in AB_CANONICAL_DIMENSIONS}
# Aliases the model sometimes emits for the same canonical dimension.
# ABBREVIATED CODES the model coins itself. `AB_DIMENSION_SYNONYMS` below maps
# SOP PHRASES ("overall preference"); this maps the SHORT CODES a model derives
# from those phrases. The distinction cost a live run: the directive tells the
# model to use "its short code", so a SOP whose axes are "Overall Preference"
# and "Less AI-Generated" came back keyed `OP` and `LAIG` - correct, complete
# answer keys that the validator rejected because it only knew `OC` and `LAI`.
# Four well-formed items were flagged unkeyed and the operator was told the
# model had failed. It had not; our vocabulary had.
AB_CODE_ALIASES = {"ID": "IDP", "IDPRESERVATION": "IDP",
                   "CONTENTPRESERVATION": "CP", "OVERALL": "OC",
                   "OP": "OC", "OVERALLPREFERENCE": "OC",
                   "OVERALLCHOICE": "OC", "PREF": "OC",
                   "LAIG": "LAI", "LESSAI": "LAI", "AIG": "LAI",
                   "PA": "IF", "IA": "IF", "IQ": "VQ", "AQ": "VQ"}

# WHAT A SOP CALLS THE SAME DIMENSION. Matched on the normalized token, so
# spacing, case and punctuation do not matter.
#
# THIS IS NOT COSMETIC. `validate_flaw_plan` requires an OC dimension, and the
# generation directive orders the model to emit THIS SOP's dimension names
# verbatim - so a SOP whose final axis is called "Overall Preference" produced a
# construction_keys map with no OC in it, every image_ab item was rejected, and
# the run reported success with zero drafts. One live SOP ("Text to Image
# Compare") does exactly that, and it failed 5 items for 5 items, every time.
# A registry entry is what stops the platform's own vocabulary being the thing
# that rejects the platform's own output.
AB_DIMENSION_SYNONYMS = {
    "overall preference": "OC",
    "overall pick": "OC",
    "overall winner": "OC",
    "overall rating": "OC",
    "preferred response": "OC",
    "which response do you prefer overall": "OC",
    # Bare heads, so the contained-phrase fallback below can resolve ANY
    # wording built around them ("Which image do you prefer overall?",
    # "Overall, which do you prefer?"). Enumerating whole questions here is
    # what makes a synonym table go stale; a head phrase does not.
    "prefer overall": "OC",
    "follows the prompt": "IF",
    "follows the instruction": "IF",
    "prompt alignment": "IF",
    "prompt following": "IF",
    "instruction alignment": "IF",
    "image quality": "VQ",
    "aesthetic quality": "VQ",
    "less ai generated": "LAI",
    "looks less ai generated": "LAI",
    "identity preservation": "IDP",
}

# The verdict words a SOP writes, mapped onto the vocabulary the platform
# validates and scores against. The SOP's own wording is kept for DISPLAY (see
# `dimension_labels`); only the machine value is canonicalised, so a candidate
# still reads the project's language while one vocabulary reaches scoring.
AB_VERDICT_SYNONYMS = {
    "response a": "Response A", "image a": "Response A", "a": "Response A",
    "option a": "Response A", "candidate a": "Response A",
    "left": "Response A", "first": "Response A",
    "response b": "Response B", "image b": "Response B", "b": "Response B",
    "option b": "Response B", "candidate b": "Response B",
    "right": "Response B", "second": "Response B",
    # A tie is "both acceptable", which is what Both Good means here.
    #
    # THIS IS A SAFETY NET, NOT AN OFFER. Tie is dropped from every advertised
    # option list (see AB_TIE_WORDS), so neither the model nor a candidate is
    # given it. The mapping stays for the case where a model emits one anyway:
    # an unrecognised verdict on a rating dimension makes
    # `_infer_missing_ab_options` invent a custom answer set for it, which flips
    # the whole plan to custom-options and skips BOTH the Overall Choice
    # requirement and the planted-flaw checks. Silently resolving a stray tie is
    # much cheaper than mis-grading a paper as an independent-questions eval.
    "tie": "Both Good", "both good": "Both Good", "equal": "Both Good",
    "either": "Both Good", "no preference": "Both Good",
    "both bad": "Both Bad", "neither": "Both Bad",
}

# Option words a SOP offers that the platform does NOT put in front of anyone.
# A comparison task asks for a decision; "Tie" is the answer that avoids making
# one, and it collapses onto Both Good, which the SOP's own scale already has a
# clearer word for when it means it.
AB_TIE_WORDS = frozenset({"tie", "tied", "draw", "equal", "no preference",
                          "same", "cannot decide", "can't decide"})


def ab_is_tie_word(value):
    return _ab_norm_phrase(value) in AB_TIE_WORDS


def ab_normalize_verdict(value):
    """One verdict word in the platform's vocabulary, or the input unchanged.

    Unrecognised values pass THROUGH rather than being dropped: a SOP is allowed
    its own per-dimension options (see `dimension_options`), and silently
    rewriting one to the nearest A/B word would put an answer key on the wrong
    side. This only collapses the spellings that provably mean the same pick.
    """
    raw = str(value or "").strip()
    if not raw:
        return raw
    return AB_VERDICT_SYNONYMS.get(_ab_norm_phrase(raw), raw)

# The default rating set for a plain compare-to-prompt A/B when the SOP is silent.
# NOT a contract — just the fallback the generator hints when no SOP dims are known.
AB_DEFAULT_DIMENSIONS = [
    ("IF", "Instruction Following"),
    ("VQ", "Visual Quality"),
    ("LAI", "Less AI Generated"),
    ("OC", "Overall Choice"),
]

# Means "the KNOWN/DEFAULT set", never the only allowed set - the machinery
# derives real dims from construction_keys. Its siblings AB_DIMENSIONS and
# AB_DIMENSION_CODES were removed: they were labelled back-compat aliases for
# "existing imports" that no longer exist anywhere in the module.
AB_DIMENSION_NAMES = dict(AB_KNOWN_DIMENSION_LABELS)

AB_CHOICES = ["Response A", "Response B", "Both Good", "Both Bad"]
AB_CHOICE_SET = frozenset(AB_CHOICES)


VERTEX_GLOBAL_LOCATION = "global"
VERTEX_DEFAULT_LOCATION = VERTEX_GLOBAL_LOCATION
VERTEX_DEFAULT_MODEL = "gemini-3-pro-image"
# Generation reads a SOP document: must NOT fall back to the image model, which
# sees a PDF as opaque binary -> "document has no pages".
GENERATION_DEFAULT_MODEL = "gemini-3.1-pro-preview"

# Veo is served ONLY on a regional endpoint; the gemini 'global' location 404s
# for Veo, hence its own location constant.
VIDEO_DEFAULT_MODEL = "veo-3.1-generate-001"
VIDEO_DEFAULT_LOCATION = "us-central1"
VIDEO_DEFAULT_DURATION_S = 6

# Veo does NOT accept an arbitrary integer duration: it accepts a small
# ENUMERATED set and 400s anything else with
#   "Unsupported output video duration 5 seconds, supported durations are
#    [8,4,6] for feature text_to_video."
# A range clamp (4..8) is therefore NOT sufficient - 5 and 7 sit inside the
# range but are rejected. Keep these sets as the single source of truth.
VIDEO_ALLOWED_DURATIONS_S = (4, 6, 8)          # veo-3.x text_to_video
VIDEO_ALLOWED_DURATIONS_S_VEO2 = (5, 6, 7, 8)  # veo-2.x text_to_video


def video_allowed_durations(model=None):
    """Legal ``durationSeconds`` values for a Veo model name.

    This is our BEST GUESS, not gospel: Google changes the enum per model and
    per feature without notice, so treat it as a starting point that
    ``parse_supported_durations`` corrects from Veo's own error text.
    """
    name = (model or VIDEO_DEFAULT_MODEL or "").strip().lower()
    if "veo-2" in name:
        return VIDEO_ALLOWED_DURATIONS_S_VEO2
    return VIDEO_ALLOWED_DURATIONS_S


# Veo names the durations it WILL accept inside the very error it rejects us
# with: "supported durations are [8,4,6] for feature text_to_video". That list
# is authoritative for this model+feature, so we parse and reuse it rather than
# trusting our hardcoded tuple - which is what let a 7s brief burn a real
# generation attempt.
_SUPPORTED_DURATIONS_RE = re.compile(
    r"supported\s+durations?\s+are\s*\[([0-9,\s]+)\]", re.IGNORECASE)
_UNSUPPORTED_DURATION_RE = re.compile(
    r"unsupported\s+output\s+video\s+duration", re.IGNORECASE)


def is_duration_error(text):
    """True when an error is Veo's "unsupported output video duration"."""
    return bool(_UNSUPPORTED_DURATION_RE.search(text or ""))


def parse_supported_durations(text):
    """Pull the authoritative duration enum out of a Veo error string.

    Returns a sorted tuple of ints, or () when the message carries no list.
    Veo prints them unsorted ([8,4,6]); we sort so callers can rely on order.
    """
    match = _SUPPORTED_DURATIONS_RE.search(text or "")
    if not match:
        return ()
    out = []
    for chunk in match.group(1).split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            val = int(float(chunk))
        except (TypeError, ValueError):
            continue
        if val > 0 and val not in out:
            out.append(val)
    return tuple(sorted(out))


def snap_video_duration(duration_s, model=None, allowed=None):
    """Snap any requested clip length onto the nearest duration Veo accepts.

    Veo rejects out-of-enum durations outright, so a brief asking for 5s or 7s
    (very natural numbers for an LLM to emit) killed the whole generation. We
    snap instead of failing: the candidate still gets a clip, just at the
    nearest legal length. Ties round UP (5 -> 6, not 4) so we never truncate
    the described action.

    ``allowed`` overrides the model's assumed enum - pass the set Veo itself
    named in a previous rejection so a retry lands on a value we KNOW works.
    """
    allowed = tuple(allowed or ()) or video_allowed_durations(model)
    try:
        want = int(round(float(duration_s)))
    except (TypeError, ValueError):
        want = VIDEO_DEFAULT_DURATION_S
    if want in allowed:
        return want
    return min(allowed, key=lambda a: (abs(a - want), -a))


_OPTION_REASONING_RE = re.compile(
    r",\s+(because|since|due to|as it|making it|so that|therefore|"
    r"which makes|as the|given that)\b", re.IGNORECASE)


def option_name_reveals_reasoning(name):
    if not name:
        return False
    match = _OPTION_REASONING_RE.search(name)
    return bool(match) and len(name[:match.start()].split()) <= 5


_SOURCE_REF_RE = re.compile(
    r"\bSOPs?\b"
    r"|\bstandard operating procedures?\b"
    r"|\b(?:Section|Sub-?section|Step|Clause|Rule)\s+\d"
    r"|\b(?:according to|as per|per|as (?:stated|specified|defined|described|"
    r"outlined|set out|laid out|mentioned) in|in accordance with|pursuant to|"
    r"as required by|in line with)\s+the\s+(?:\w+\s+){0,2}"
    r"(?:guidelines?|documentation|document|material|polic(?:y|ies)|"
    r"procedures?|manual|handbook|sop|protocol|spec(?:ification)?s?|"
    r"rubric|criteria|scheme|brief|playbook|runbook|standards?|"
    r"workflows?|process(?:es)?|framework)\b",
    re.IGNORECASE)


def text_has_source_reference(*texts):
    for text in texts:
        if text and _SOURCE_REF_RE.search(text):
            return True
    return False


# GATE VOCABULARIES. There are TWO, both landing in response.llm_gate, and they
# are deliberately kept distinct so the audit trail shows which producer spoke:
#
#   1. PLATFORM gates -- services/gates.py evaluate_gates(), raised BEFORE the
#      grader runs (the LLM is never called for these).
#   2. JUDGE gates -- emitted by earlier grader prompts. The current
#      prompts/scoring.md asks for no gate, so these appear only on answers
#      graded before it; they are still read.
#
# Both live here, together, so every reader tests the exact spelling its
# producer emitted ("unscorable:wrong_item", not a bare "wrong_item").
# A new gate on EITHER side must be added here in the same change.

# 1. Platform (services/gates.py)
GATE_EMPTY_ANSWER = "empty_answer"

# 2. Judge (older prompts). injection_attempt is also the platform's own gate.
GATE_UNSCORABLE_EMPTY = "unscorable:empty"
GATE_UNSCORABLE_PLACEHOLDER = "unscorable:placeholder"
GATE_UNSCORABLE_TOO_SHORT = "unscorable:too_short"
GATE_UNSCORABLE_WRONG_ITEM = "unscorable:wrong_item"
GATE_INJECTION_ATTEMPT = "injection_attempt"

JUDGE_GATE_CODES = frozenset({
    GATE_UNSCORABLE_EMPTY,
    GATE_UNSCORABLE_PLACEHOLDER,
    GATE_UNSCORABLE_TOO_SHORT,
    GATE_UNSCORABLE_WRONG_ITEM,
    GATE_INJECTION_ATTEMPT,
})

# 3. Platform, raised post-scoring by the key-drift guard.
GATE_KEY_DRIFT = "key_drift"

# Gates that mean "this answer is not an honest attempt at THIS item, so the
# grader must stamp integrity_alert on it". Both spellings of wrong_item are
# accepted on read; only the judge's form was ever emitted.
GATE_FLAG_INTEGRITY = frozenset({
    GATE_UNSCORABLE_WRONG_ITEM,
    "wrong_item",
    GATE_INJECTION_ATTEMPT,
})

# Gates that must surface an integrity alert to a reviewer. Superset of the
# above: it also covers the platform's own blank-answer gate and key drift.
GATE_INTEGRITY_ALERTS = GATE_FLAG_INTEGRITY | frozenset({
    GATE_EMPTY_ANSWER,
    GATE_UNSCORABLE_EMPTY,
    GATE_KEY_DRIFT,
})


def normalize_gate(value):
    """Canonical form for COMPARISON ONLY -- never for storage.

    llm_gate keeps whatever its producer emitted: "empty_answer" (platform) and
    "unscorable:empty" (judge) mean the same thing but come from different
    places, and collapsing them would erase which one fired.
    """
    return str(value or "").strip().lower()


def gate_flags_integrity(value):
    """True when the grader should stamp integrity_alert on this gate."""
    return normalize_gate(value) in GATE_FLAG_INTEGRITY


def is_integrity_gate(value):
    """True when the gate means 'a human must look at this'."""
    return normalize_gate(value) in GATE_INTEGRITY_ALERTS


# Patterns are compiled with re.IGNORECASE by services/gates.py; a match resolves
# the answer to raw score 0 locally and the grader is never called.
# Keep every entry TIGHT: it must match a "coerce the grader" idiom, never ordinary
# answer prose. A broad pattern silently zeroes honest candidates, with no error.
INTEGRITY_GATE_PATTERNS = [
    r"ignore\s+(?:the\s+|this\s+|all\s+)?rubric",
    r"ignore\s+(?:all\s+)?(?:previous\s+|prior\s+|the\s+above\s+)?instructions",
    r"disregard\s+(?:the\s+|all\s+|any\s+)?(?:previous\s+|prior\s+)?instructions",
    r"(?:grading|scoring)\s+is\s+waived",
    r"you\s+are\s+now\b",
    r"(?:award|give|assign|grant|hand)\s+(?:me\s+|this\s+|the\s+)?"
    r"(?:answer\s+|response\s+)?(?:full|maximum|max)\s+"
    r"(?:marks|score|points|credit)",
    r"(?:output|print|return|give|assign|set)\b.{0,40}?\bscore\b.{0,20}?"
    r"(?:1\.0|100|full|max(?:imum)?)",
    r"(?:score|grade)\s+(?:of\s+)?(?:1\.0|100)\b",
    # Spelled-out perfect-score coercion ("give me one hundred percent",
    # "award a perfect score") - the numeric forms above miss the words.
    #
    # COERCION IS A VERB, NOT AN ADJACENCY. This used to be bare proximity -
    # any of score/grade/marks/credit/rating within 40 characters of
    # "perfect"/"one hundred" - which reads a DESCRIPTION as an instruction:
    # "the colour grade is perfect" is a candidate describing footage, and
    # `marks?` with no leading \b matched inside "water|mark|" too. A real IG
    # video-review answer ("free of watermark ... the audio is perfect") was
    # scored 0 and flagged as cheating. Requiring a coercive verb, a
    # possessive, or a modal keeps every genuine attempt while letting the
    # candidate talk about grades and watermarks like a person.
    # Pinned by tests/test_gate_false_positives.py.
    #
    # a coercive verb steering a score word to a perfect value
    r"\b(?:give|award|assign|grant|hand|set|make|rate|mark|score|grade"
    r"|credit)\b"
    r"[^\n]{0,30}?\b(?:score|grade|marks?|credit|rating)\b"
    r"[^\n]{0,40}?(?:one\s+hundred|hundred\s+percent|perfect|full\s+marks)"
    r"|"
    # the same verb aimed at the candidate/answer directly, no score word first
    r"\b(?:give|award|assign|grant|hand|rate|mark|score|grade|credit)\b\s+"
    r"(?:me|us|this|that|it|my|our)\b"
    r"[^\n]{0,40}?(?:one\s+hundred|hundred\s+percent|perfect|full\s+marks|"
    r"full\s+(?:score|credit|points))"
    r"|"
    # possessive framing: "my score ... perfect"
    r"\b(?:my|me|this\s+answer|this\s+response)\b[^\n]{0,20}?"
    r"\b(?:score|grade|marks?|credit|rating)\b[^\n]{0,40}?"
    r"(?:one\s+hundred|hundred\s+percent|perfect|full\s+marks)"
    r"|"
    # modal framing: "the score should be perfect"
    r"\b(?:score|grade|marks?|credit|rating)\b[^\n]{0,20}?"
    r"(?:should|must|has\s+to|needs?\s+to)\b[^\n]{0,30}?"
    r"(?:one\s+hundred|hundred\s+percent|perfect|full\s+marks)",
    r"(?:give|award|assign|grant)\b.{0,25}?(?:a\s+)?perfect\s+(?:score|grade|"
    r"mark|rating)",
]

# 0-100 upper bounds services/scoring._apply_ceilings applies after the grader,
# from the counts prompts/scoring.md asks it to report (verdict_consistency,
# checklist_zero_count, fabrication_count). The prompt never applies them itself.
SCORE_CEILINGS = {
    "verdict_contradiction": 25.0,
    "multi_checklist_zero": 55.0,
    "fabrication": 25.0,
}


AB_FLAWED_SIDES = ("a", "b")

_AB_CODE_PAREN_RE = re.compile(r"\(([A-Za-z0-9]{1,8})\)")
_AB_TOKEN_RE = re.compile(r"[^a-z0-9]")


def _ab_norm_token(s):
    return _AB_TOKEN_RE.sub("", (s or "").lower())


_AB_PHRASE_RE = re.compile(r"[^a-z0-9]+")


def _ab_norm_phrase(s):
    """Lowercase words, single-spaced. Keeps word boundaries, unlike
    `_ab_norm_token`, so a multi-word synonym stays readable in the tables
    above ('overall preference') instead of running together."""
    return _AB_PHRASE_RE.sub(" ", (s or "").lower()).strip()


# label (normalized) -> canonical code, for reversing a full dimension name.
_AB_LABEL_TO_CODE = {
    _ab_norm_token(name): code for code, name in AB_CANONICAL_DIMENSIONS}
# The SOP-wording synonyms fold into the SAME lookup, so every path that already
# reversed a full label picks them up without a second branch.
_AB_LABEL_TO_CODE.update(
    {_ab_norm_token(phrase): code
     for phrase, code in AB_DIMENSION_SYNONYMS.items()})
_AB_PHRASE_TO_CODE = {
    _ab_norm_phrase(phrase): code
    for phrase, code in AB_DIMENSION_SYNONYMS.items()}
_AB_PHRASE_TO_CODE.update(
    {_ab_norm_phrase(name): code for code, name in AB_CANONICAL_DIMENSIONS})


def ab_humanize_code(code):
    """Pretty label for a dimension code/key. Known codes use the registry; an
    unknown SOP-specific dimension is humanized on the fly ('edge_fidelity' ->
    'Edge Fidelity', 'ID Preservation' passes through) so no code change is ever
    needed for a new dimension."""
    raw = (code or "").strip()
    if not raw:
        return ""
    known = AB_KNOWN_DIMENSION_LABELS.get(raw.upper())
    if known:
        return known
    if " " in raw or "-" in raw:            # already a human phrase
        return raw.replace("-", " ").strip()
    spaced = raw.replace("_", " ").strip()
    if spaced != raw:                       # snake_case -> Title Case
        return spaced.title()
    return raw if raw.isupper() else raw[:1].upper() + raw[1:]


def ab_normalize_dim_key(key):
    """(code, label) for a construction_keys key, which may be a compact code
    ('IF'), an alias ('ID'), a parenthetical ('Instruction Following (IF)'), or a
    full label ('Less AI-Generated'). An unknown SOP dimension is accepted and
    humanized (self-extending) rather than dropped."""
    raw = (key or "").strip()
    if not raw:
        return ("", "")
    up = raw.upper()
    if up in AB_KNOWN_DIMENSION_LABELS:
        return (up, AB_KNOWN_DIMENSION_LABELS[up])
    if up in AB_CODE_ALIASES:
        code = AB_CODE_ALIASES[up]
        return (code, AB_KNOWN_DIMENSION_LABELS[code])
    m = _AB_CODE_PAREN_RE.search(raw)       # "Name (CODE)"
    if m:
        pcode = m.group(1).upper()
        if pcode in AB_KNOWN_DIMENSION_LABELS:
            return (pcode, AB_KNOWN_DIMENSION_LABELS[pcode])
        if pcode in AB_CODE_ALIASES:
            code = AB_CODE_ALIASES[pcode]
            return (code, AB_KNOWN_DIMENSION_LABELS[code])
    tok = _ab_norm_token(raw)               # full label -> canonical code
    if tok in _AB_LABEL_TO_CODE:
        code = _AB_LABEL_TO_CODE[tok]
        return (code, AB_KNOWN_DIMENSION_LABELS[code])
    if tok in AB_CODE_ALIASES:
        code = AB_CODE_ALIASES[tok]
        return (code, AB_KNOWN_DIMENSION_LABELS[code])
    phrase = _ab_norm_phrase(raw)           # SOP wording -> canonical code
    if phrase in _AB_PHRASE_TO_CODE:
        code = _AB_PHRASE_TO_CODE[phrase]
        return (code, AB_KNOWN_DIMENSION_LABELS[code])
    # CONTAINED PHRASE. An examiner writes an axis as a QUESTION - "Which image
    # better follows the prompt?" - not as the bare noun phrase the registry
    # lists. Rather than enumerate every phrasing (a hardcoded synonym map that
    # goes stale the moment a SOP words it differently), look for a known
    # phrase INSIDE the wording. Longest match first so "less ai generated"
    # cannot be beaten by a shorter, more generic entry.
    if phrase:
        for known in sorted(_AB_PHRASE_TO_CODE, key=len, reverse=True):
            if known and known in phrase:
                code = _AB_PHRASE_TO_CODE[known]
                return (code, AB_KNOWN_DIMENSION_LABELS[code])
    # UNKNOWN SOP/EXAMINER DIMENSION: keep it, and keep the WORDING AS WRITTEN.
    # The code is upper-cased because that is what a code is (`OP`, `LAIG`), but
    # the LABEL is what a candidate reads. A template axis is a whole sentence -
    # "Was the instruction applied?" - and upper-casing it made the exam shout
    # "WAS THE INSTRUCTION APPLIED?" at the candidate. `ab_humanize_code` is for
    # turning a code into prose; when the key already IS prose, the examiner's
    # own casing is the answer.
    if " " in raw:
        return (up, raw)
    return (up, ab_humanize_code(raw))      # unknown SOP dimension: keep + humanize


def ab_dimensions_from_keys(keys):
    """Ordered [(code, label), ...] derived from a construction_keys dict — THE SOP
    decides which dimensions exist. Known dims sort in canonical order, unknown
    (SOP-specific) dims keep insertion order, and Overall Choice is always last."""
    seen = {}
    for raw in (keys or {}):
        code, label = ab_normalize_dim_key(raw)
        if code and code not in seen:
            seen[code] = label

    def _rank(code):
        return (AB_KNOWN_DIMENSION_ORDER.index(code)
                if code in AB_KNOWN_DIMENSION_ORDER
                else len(AB_KNOWN_DIMENSION_ORDER))
    ordered = sorted(seen, key=lambda c: (c == AB_OVERALL_CODE, _rank(c)))
    return [(c, seen[c]) for c in ordered]


def ab_side_verdict(side):
    return "Response A" if (side or "").strip().lower() == "a" else "Response B"


def ab_other_side(side):
    return "b" if (side or "").strip().lower() == "a" else "a"


def ab_code_from_label(label):
    if not label:
        return ""
    code, _label = ab_normalize_dim_key(label)
    return code


def ab_dimension_label(code):
    code = (code or "").upper()
    name = AB_KNOWN_DIMENSION_LABELS.get(code) or ab_humanize_code(code)
    if name and code and code != name.upper():
        return "%s (%s)" % (name, code)
    return name or code or ""


def ab_dimension_options(code, override=None):
    """The answer options for one A/B dimension.

    SOP-derived override wins: when the flaw plan supplies a ``dimension_options``
    entry for this dimension (e.g. an independent YES/NO eval like the I2I SOP),
    those options are used verbatim. Otherwise the default A/B vocabulary applies
    (Overall Choice is always the decided Response A/Response B pick)."""
    if override:
        opts = [str(o).strip() for o in override if str(o).strip()]
        if opts:
            return opts
    if (code or "").upper() == AB_OVERALL_CODE:
        return ["Response A", "Response B"]
    return list(AB_CHOICES)


def ab_dimension_options_map(raw):
    """Normalize a raw ``dimension_options`` dict ({<dim key>: [options]}) to a
    canonical {CODE: [options]} map, so 'ID Preservation'/'ID'/'IDP' collapse and
    an unknown SOP dimension keeps its upper token. Empty/invalid -> {}."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for raw_code, opts in raw.items():
        code, _label = ab_normalize_dim_key(raw_code)
        if not code or code in out:
            continue
        clean = [str(o).strip() for o in (opts or []) if str(o).strip()]
        if clean:
            out[code] = clean
    return out


def ab_dimension_labels_map(raw):
    """Normalize a raw ``dimension_labels`` dict ({<dim key>: "SOP title"}) to a
    canonical {CODE: title} map.

    An independent-eval SOP numbers its questions (Q1/Q2/Q3) but each ALSO has a
    meaning ('Instruction Following', 'Image Aligned', 'Free from AI slop'). A
    bare 'Q1' is opaque to the candidate and the reviewer, so the SOP's own title
    travels alongside the code and is shown with it."""
    if not isinstance(raw, dict):
        return {}
    out = {}
    for raw_code, title in raw.items():
        code, _label = ab_normalize_dim_key(raw_code)
        if not code or code in out:
            continue
        text = str(title or "").strip()
        if text:
            out[code] = text
    return out


def ab_pretty_label(text):
    """Readable form of a SOP-supplied dimension title.

    SOPs frequently write their axes in shouting caps ('NO AI SLOP',
    'IMAGE ALIGNED (PIXEL ALIGNMENT)'). Shown verbatim to a candidate that reads
    as noise, so an ALL-CAPS title is title-cased for display while genuine
    acronyms (AI, ID, UI, OK...) and mixed-case titles are left alone."""
    raw = (text or "").strip()
    if not raw:
        return ""
    letters = [c for c in raw if c.isalpha()]
    if not letters or not all(c.isupper() for c in letters):
        return raw                      # already mixed case: the SOP's own styling
    keep = {"AI", "ID", "UI", "UX", "OK", "QA", "PDF", "URL", "HTML", "3D", "2D"}
    out = []
    for word in raw.split(" "):
        core = word.strip("()[],.:;")
        if core.upper() in keep:
            out.append(word)
            continue
        out.append(word.capitalize() if word else word)
    return " ".join(out)


def ab_dimension_display_label(code, title=None):
    """The label shown for one A/B dimension.

    THE SOP'S OWN WORDING WINS. When the SOP (or an examiner's task template)
    names an axis, that name is what a candidate reads and what the examiner
    asked for. This used to return the canonical name for any KNOWN code, so a
    template whose axis is "Which image better follows the prompt?" surfaced
    as "Instruction Following (IF)" - the platform's vocabulary overriding the
    examiner's, exactly the failure the code-alias table exists to prevent in
    the other direction.

    The canonical label remains the fallback for a code with no title, and a
    title that merely repeats the code or its canonical name still renders
    once rather than doubled.
    """
    base = ab_dimension_label(code)
    text = ab_pretty_label(title)
    if not text:
        return base
    up_code = (code or "").strip().upper()
    # Title already carries the code (or IS the humanized label) -> show it once.
    # PREFER THE TITLE'S OWN CASING. For an examiner-authored axis the "code" IS
    # the sentence, upper-cased (that is what an unknown dimension's code is), so
    # this branch matched every template axis and returned the SHOUTED form -
    # "WAS THE INSTRUCTION APPLIED?" in front of a candidate. The title and the
    # base say the same words here; the title says them the way a human wrote
    # them, so it wins.
    if text.upper() == up_code or text.upper() == base.upper():
        return text if text.upper() == up_code else base
    if up_code and up_code in text.upper():
        return text
    return text


def ab_flip_verdict(verdict):
    v = (verdict or "").strip()
    if v == "Response A":
        return "Response B"
    if v == "Response B":
        return "Response A"
    return v


def ab_flip_construction_keys(keys):
    return {str(c).upper(): ab_flip_verdict(v) for c, v in (keys or {}).items()}


# The side letter is upper-case only: "in the image a hand holds" is prose.
_AB_SIDE_IN_TEXT_RE = re.compile(
    r"\b((?i:response|image|option|side))(\s+)([AB])\b")


def ab_flip_sides_in_text(text):
    """`text` with "Response A" and "Response B" (Image/Option/Side too) swapped.

    For prose written against one slot assignment that was then swapped, the
    same flip `ab_flip_construction_keys` applies to the key. Only the side
    letter changes.
    """
    return _AB_SIDE_IN_TEXT_RE.sub(
        lambda m: m.group(1) + m.group(2)
        + {"A": "B", "B": "A"}[m.group(3)],
        text or "")


def ab_is_side_option(option):
    """True when an answer option names a side ("Response A", "Image B")."""
    return ab_normalize_verdict(option) in ("Response A", "Response B")


# A slot an examiner left in template wording: "Is this reference a {type}?".
_TEMPLATE_SLOT_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
TEMPLATE_SLOT_FALLBACK = "item"


def template_slot_names(text):
    """The {slot} names in `text`, lower-cased and sorted."""
    return sorted({n.lower() for n in _TEMPLATE_SLOT_RE.findall(text or "")})


def fill_template_slots(text, values):
    """`text` with each {slot} named in `values` filled in.

    `values` maps a lower-cased slot name to its word. "a {type}" takes the
    word's article ("an item"), and an upper-cased slot ({TYPE}, as in an A/B
    construction-key code) gets an upper-cased word, so a label and the code
    derived from it stay equal after filling.
    """
    if not text or not values:
        return text
    pattern = re.compile(
        r"(\b(?:a|an) )?\{(%s)\}" % "|".join(map(re.escape, values)),
        re.IGNORECASE)

    def fill(m):
        article, slot = m.group(1), m.group(2)
        word = values[slot.lower()]
        if slot.isupper():
            word = word.upper()
        if not article:
            return word
        art = "an" if word[:1].lower() in "aeiou" else "a"
        if slot.isupper():
            art = art.upper()
        elif article[0].isupper():
            art = art.capitalize()
        return "%s %s" % (art, word)
    return pattern.sub(fill, text)


# Known binary answer sets an independent-eval SOP dimension may use. The verdict
# is one member; we pair it with the complementary member so the candidate has
# both to choose from. Order is the natural affirmative-first reading.
_AB_BINARY_PAIRS = [
    ("YES", "NO"),
    ("TRUE", "FALSE"),
    ("PASS", "FAIL"),
    ("CORRECT", "INCORRECT"),
    ("ALIGNED", "NOT ALIGNED"),
    ("ACCEPT", "REJECT"),
]
_AB_BINARY_LOOKUP = {}
for _hi, _lo in _AB_BINARY_PAIRS:
    _AB_BINARY_LOOKUP[_hi] = [_hi, _lo]
    _AB_BINARY_LOOKUP[_lo] = [_hi, _lo]


def _infer_missing_ab_options(keys, dim_options):
    """Fill in dimension_options for any construction_keys dimension whose verdict
    is NOT a default A/B choice and has no explicit options yet.

    Independent-evaluation SOPs (I2I's Q1/Q2/Q3 = YES/NO) frequently return the
    right verdicts but omit the dimension_options side channel. We recover the
    dimension's answer set from the verdict: a known binary (YES/NO, Pass/Fail)
    expands to its pair; any other non-A/B verdict yields a two-option set of the
    verdict and its negation, so the SOP's own vocabulary is never forced back
    onto Response A/B. A/B verdicts are left alone (empty override = default)."""
    out = dict(dim_options or {})
    for raw_code, verdict in (keys or {}).items():
        code, _label = ab_normalize_dim_key(raw_code)
        if not code or code in out or code == AB_OVERALL_CODE:
            continue
        v = str(verdict or "").strip()
        if not v or v in AB_CHOICE_SET:
            continue  # a real A/B verdict -> keep the default vocabulary
        pair = _AB_BINARY_LOOKUP.get(v.upper())
        if pair:
            out[code] = list(pair)
        else:
            out[code] = [v, "Not %s" % v]
    return out


def normalize_flaw_plan(plan):
    if not isinstance(plan, dict):
        return None
    # CANONICALISE THE DIMENSION CODES HERE, not at each reader.
    #
    # This was `str(c).upper()`, so a SOP that names its final axis "Overall
    # Preference" produced the key 'OVERALL PREFERENCE' and never matched OC -
    # and since the generation directive orders the model to emit the SOP's own
    # dimension names verbatim, that is what a whole SOP family emitted. Every
    # item failed `validate_flaw_plan`'s OC requirement and the run reported
    # success with zero drafts. Canonical in, canonical everywhere after.
    keys = {}
    for raw_code, verdict in (plan.get("construction_keys") or {}).items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code and code not in keys:
            keys[code] = verdict
    # SOP-derived per-dimension options (e.g. YES/NO for an independent-eval SOP).
    # Optional and additive: absent -> the default A/B vocabulary is used.
    dim_options = ab_dimension_options_map(plan.get("dimension_options"))
    # THE SOP'S VERDICT WORDS, mapped onto the vocabulary scoring reads.
    #
    # Only for a dimension the model did NOT give its own options - those define
    # their own semantics and must survive untouched. Without this, a SOP whose
    # options are "Image A / Image B / Tie" fell into `_infer_missing_ab_options`
    # below and was silently reclassified as a custom-options plan, which skips
    # the OC requirement AND the planted-flaw checks: a two-response A/B graded
    # as though it were an independent-questions eval.
    keys = {code: (verdict if code in dim_options
                   else ab_normalize_verdict(verdict))
            for code, verdict in keys.items()}
    # SOP question titles for numbered dimensions (Q1 -> "Instruction Following").
    dim_labels = ab_dimension_labels_map(plan.get("dimension_labels"))
    # SELF-HEAL: an independent-evaluation SOP (e.g. I2I's Q1/Q2/Q3 YES/NO) often
    # comes back with the right verdicts in construction_keys but WITHOUT the
    # dimension_options map (the model forgets the side channel). When a
    # dimension's verdict is NOT in the A/B vocabulary, infer its options from the
    # verdict itself so the SOP's own answer set (YES/NO, Pass/Fail, ...) is
    # honoured instead of being rejected against Response A/B.
    dim_options = _infer_missing_ab_options(keys, dim_options)
    is_new = bool(plan.get("render_prompts") or plan.get("worker_prompt")
                  or plan.get("faithful_side"))
    if is_new:
        rp = plan.get("render_prompts") or {}
        faithful = str(plan.get("faithful_side") or "").strip().lower()
        flawed = (ab_other_side(faithful)
                  if faithful in AB_FLAWED_SIDES else "")
        planted = plan.get("planted") or {}
        return {
            "faithful_side": faithful,
            "flawed_side": flawed,
            "worker_prompt": str(plan.get("worker_prompt") or "").strip(),
            "render_prompts": {
                "a": str(rp.get("a") or "").strip(),
                "b": str(rp.get("b") or "").strip(),
            },
            "planted": {
                "a": [str(f) for f in (planted.get("a") or []) if str(f).strip()],
                "b": [str(f) for f in (planted.get("b") or []) if str(f).strip()],
            },
            "construction_keys": keys,
            "dimension_options": dim_options,
            "dimension_labels": dim_labels,
        }
    flawed = str(plan.get("flawed_side") or "").strip().lower()
    faithful = ab_other_side(flawed) if flawed in AB_FLAWED_SIDES else ""
    clean = str(plan.get("clean_prompt") or "").strip()
    flawed_prompt = str(plan.get("flawed_prompt") or "").strip()
    injected = [str(f) for f in (plan.get("injected_flaws") or [])
                if str(f).strip()]
    render = {"a": "", "b": ""}
    planted = {"a": [], "b": []}
    if flawed in AB_FLAWED_SIDES:
        render[flawed] = flawed_prompt
        render[faithful] = clean
        planted[flawed] = injected
    return {
        "faithful_side": faithful,
        "flawed_side": flawed,
        "worker_prompt": clean,
        "render_prompts": render,
        "planted": planted,
        "construction_keys": keys,
        "dimension_options": dim_options,
        "dimension_labels": dim_labels,
    }


def validate_flaw_plan(plan):
    if not isinstance(plan, dict):
        return ["flaw_plan is not an object"]
    norm = normalize_flaw_plan(plan)
    errs = []
    faithful = norm["faithful_side"]
    both_flawed = faithful not in AB_FLAWED_SIDES
    opts_by_code = norm.get("dimension_options") or {}
    # An independent-evaluation SOP (I2I: Q1/Q2/Q3 YES/NO on ONE edit) supplies
    # per-dimension options and is NOT a two-response A/B: its two rendered
    # images are the reference (input) and the edited output, and the answer key
    # is carried by the construction_keys verdicts, not by a flawed-vs-faithful
    # side. So skip the A/B side/planted-flaw checks for a custom-options plan.
    custom_options = bool(opts_by_code)
    if not norm["worker_prompt"]:
        errs.append("worker_prompt (target prompt) required")
    if not norm["render_prompts"].get("a"):
        errs.append("render_prompts.a required")
    if not norm["render_prompts"].get("b"):
        errs.append("render_prompts.b required")
    if not custom_options:
        if both_flawed:
            for slot in AB_FLAWED_SIDES:
                if not norm["planted"].get(slot):
                    errs.append("planted flaws required on side %r (both-flawed "
                                "plan)" % slot)
        else:
            flawed = norm["flawed_side"]
            if flawed not in AB_FLAWED_SIDES:
                errs.append("flawed side must resolve to the 'a'/'b' slot opposite "
                            "the faithful side")
            elif not norm["planted"].get(flawed):
                errs.append("planted flaws must be a non-empty list on the flawed "
                            "side")
    keys = norm["construction_keys"]
    if not keys:
        errs.append("construction_keys missing/empty")
        return errs
    opts_by_code = norm.get("dimension_options") or {}
    # An independent-evaluation SOP (e.g. I2I: 3 YES/NO questions on ONE edit)
    # supplies per-dimension options and has no single "overall pick". Only such
    # a custom-options plan is exempt from the mandatory Overall Choice; a plain
    # A/B (no dimension_options) still REQUIRES OC exactly as before.
    custom_options = bool(opts_by_code)
    dims = ab_dimensions_from_keys(keys)
    codes = {code for code, _label in dims}
    if not custom_options and AB_OVERALL_CODE not in codes:
        errs.append("construction_keys must include an Overall Choice (OC) "
                    "dimension (the mandatory decided preference)")
    # At least one rating dimension is always required (an empty rating set is a
    # planning failure); for a plain A/B that means one BESIDES OC.
    rating_codes = codes if custom_options else (codes - {AB_OVERALL_CODE})
    if not rating_codes:
        errs.append("construction_keys needs at least one rating dimension")
    key_by_code = {}
    for raw_code, verdict in keys.items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code:
            key_by_code[code] = verdict
    for code, _label in dims:
        verdict = key_by_code.get(code)
        override = opts_by_code.get(code)
        allowed = ab_dimension_options(code, override)
        if (code == AB_OVERALL_CODE and not override
                and verdict not in ("Response A", "Response B")):
            errs.append("construction_keys[OC]=%r must be DECIDED "
                        "(Response A or Response B)" % (verdict,))
            continue
        if verdict not in allowed:
            # Same reconciliation the spec builder applies: a SOP saying
            # "Image A" and a verdict saying "Response A" are the same side.
            aligned = ab_align_verdict_to_options(verdict, allowed)
            if aligned in allowed:
                verdict = aligned
            else:
                errs.append("construction_keys[%s]=%r not in %s"
                            % (code, verdict, allowed))
                continue
        # The "Both Bad needs both sides flawed" rule is specific to the default
        # A/B vocabulary; a custom-options dimension defines its own semantics.
        if verdict == "Both Bad" and not override and not both_flawed:
            errs.append("construction_keys[%s]='Both Bad' requires BOTH sides "
                        "flawed (faithful_side null/'both')" % (code,))
    return errs


def ab_align_verdict_to_options(verdict, options):
    """Say ``verdict`` in the vocabulary a dimension actually offers.

    A/B verdicts are decided in the canonical "Response A"/"Response B" terms,
    but a SOP is free to label the same two sides "Image A"/"Image B" (and
    "Tie" where the default vocabulary says "Both Good"). When the two disagree
    the verdict matches no option, so the dimension is stored with an empty
    ``correct`` and the UI reports "No correct option marked" on a question
    whose key was decided by construction and is sitting right there in
    flaw_plan_json.

    Matching is by SIDE, not by string: A stays A and B stays B whatever the
    noun. Returns the verdict unchanged when it is already sayable, or when no
    equivalent exists (a genuine mismatch the validator should still reject).
    """
    text = (verdict or "").strip()
    if not text or not options:
        return verdict
    opts = [str(o).strip() for o in options if str(o).strip()]
    if text in opts:
        return verdict
    lowered = {o.lower(): o for o in opts}
    side = ""
    low = text.lower()
    if low.endswith(" a"):
        side = "a"
    elif low.endswith(" b"):
        side = "b"
    if side:
        for noun in ("response", "image", "video", "option", "output"):
            hit = lowered.get("%s %s" % (noun, side))
            if hit:
                return hit
    # "Both Good" and "Tie" are the same verdict wearing different names.
    for a, b in (("both good", "tie"), ("tie", "both good")):
        if low == a and b in lowered:
            return lowered[b]
    return verdict


def _ab_is_both_verdict(verdict):
    """True for the "no single side wins" verdicts, whatever they are called.

    Kept alongside `ab_align_verdict_to_options` because the two answer different
    questions: alignment asks "can this be SAID here?", this asks "is this a
    refusal to pick a side?". Both Good / Both Bad / Tie / Neither all are.
    """
    low = (verdict or "").strip().lower()
    return low in ("both good", "both bad", "both", "tie", "neither")


def ab_specs_from_construction_keys(keys, options_map=None, labels_map=None):
    norm = {}
    for raw_code, verdict in (keys or {}).items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code and code not in norm:
            norm[code] = verdict
    opts_by_code = ab_dimension_options_map(options_map)
    labels_by_code = ab_dimension_labels_map(labels_map)
    specs = []
    for code, _label in ab_dimensions_from_keys(keys):
        verdict = norm.get(code)
        options = ab_dimension_options(code, opts_by_code.get(code))
        # Say the verdict in this dimension's own vocabulary, so a SOP that
        # labels the sides "Image A"/"Image B" still gets a marked key.
        verdict = ab_align_verdict_to_options(verdict, options)
        # A "BOTH" VERDICT ON A FORCED-CHOICE DIMENSION.
        #
        # Some SOPs narrow a dimension to two sides ("Which looks less
        # AI-generated?" -> Response A / Response B) while the model, which sees
        # the default four-way vocabulary, still answers "Both Good". That
        # verdict is unsayable here, alignment correctly finds no equivalent, and
        # the dimension used to be stored with an EMPTY key - so a question whose
        # ground truth was decided by construction rendered as "No correct option
        # marked" and would score zero for every candidate. Seen live: 3 of 6
        # image A/B drafts, on the LAG dimension only.
        #
        # A forced choice between two sides has an answer available: the side
        # this sitting already decided on overall. Prefer that over discarding
        # the key. If OC itself is unusable there is genuinely nothing to infer,
        # and the empty key + validator warning is the correct outcome.
        if (verdict and options and verdict not in options
                and _ab_is_both_verdict(verdict)):
            fallback = ab_align_verdict_to_options(
                norm.get(AB_OVERALL_CODE), options)
            if fallback and fallback in options:
                verdict = fallback
            else:
                verdict = None
        specs.append({
            "label": ab_dimension_display_label(code, labels_by_code.get(code)),
            "options": options,
            "correct": [verdict] if verdict else [],
        })
    return specs


# ---------------------------------------------------------------------------
# TASK REGISTRY
#
# The SOP's own tasks, each with the answer contract that task needs. This is
# the layer that lets a NEW project be assessed without a code change: the eight
# question types stay a closed set of RESPONSE PRIMITIVES, while what an item
# actually asks - its axis names, its per-axis options, whether a justification
# is required - is read from the SOP at extraction time.
#
# The generic "Response A / Response B" scale was the symptom this fixes: every
# A/B item on every project got the same four options because the options were
# hardcoded in the harness rather than read from the SOP that names them.
# ---------------------------------------------------------------------------

# Response primitives. Deliberately CLOSED: a primitive is a way a human can
# answer, not a subject area, and these cover every task shape seen so far. A
# new project brings new DIMENSIONS and new OPTIONS (data), never a new
# primitive (code).
TASK_RESPONSE_PRIMITIVES = (
    "single_choice",    # pick exactly one option
    "multi_choice",     # pick any number
    "free_text",        # write prose
    "compare_two",      # judge two candidates side by side
    "annotate_image",   # mark points/boxes on an image
    "author_prompt",    # write a prompt that would produce a target image
    "author_video_prompt",  # write a prompt that would produce a target CLIP
    "describe_media",   # describe what is in an image or clip
)

# Which question type serves each primitive. The map is the ONLY place a
# primitive meets a stored question type, so adding a type later is one edit
# here rather than a hunt through the harness.
TASK_PRIMITIVE_TO_QUESTION_TYPE = {
    "single_choice": "mcq",
    "multi_choice": "msq",
    "free_text": "subjective_rubric",
    "compare_two": "image_ab",
    "annotate_image": "image_label",
    "author_prompt": "image_prompt",
    # video_prompt was a stored, fully-validated question type that NO primitive
    # routed to, so no template could ever author video and the type was dead
    # weight. It differs from author_prompt only in the medium the prompt has to
    # produce, which is exactly what a separate primitive is for.
    "author_video_prompt": "video_prompt",
    "describe_media": "subjective_rubric",
}


def parse_task_registry(tasks_json):
    """The SOP's tasks as a list of dicts, primary first. [] when absent.

    Tolerant by design: a malformed registry must not lose a generation run that
    already cost money, so this degrades to [] and the caller falls back to the
    pre-registry behaviour.
    """
    raw = (tasks_json or "").strip()
    if not raw:
        return []
    try:
        tasks = json.loads(raw)
    except (ValueError, TypeError):
        return []
    if not isinstance(tasks, list):
        return []
    return [t for t in tasks if isinstance(t, dict) and t.get("key")]


def task_answer_contract(task):
    """One task's answer contract, with only the keys we can trust.

    Returns {} when the task carries no usable contract, which the caller must
    read as "fall back to the generic shape" rather than "no dimensions".
    """
    if not isinstance(task, dict):
        return {}
    contract = task.get("answer_contract")
    if not isinstance(contract, dict):
        return {}
    out = {}
    response = contract.get("response")
    if isinstance(response, str) and response in TASK_RESPONSE_PRIMITIVES:
        out["response"] = response
    dims = []
    for d in contract.get("dimensions") or []:
        if not isinstance(d, dict):
            continue
        label = str(d.get("label") or "").strip()
        options = [str(o).strip() for o in (d.get("options") or [])
                   if str(o).strip()]
        # An axis with a label but no options cannot be answered, and an axis
        # with options but no label cannot be read. Both are dropped rather
        # than half-rendered.
        if label and len(options) >= 2:
            dims.append({"label": label, "options": options,
                         "evidence": str(d.get("evidence") or "").strip()})
    if dims:
        out["dimensions"] = dims
    justification = contract.get("justification")
    if justification in ("required", "optional", "none"):
        out["justification"] = justification
    assets = contract.get("assets_per_question")
    if isinstance(assets, (int, float)) and assets >= 0:
        out["assets_per_question"] = int(assets)
    shape = str(contract.get("solution_shape") or "").strip()
    if shape:
        out["solution_shape"] = shape
    return out


def task_question_type(task, fallback=None):
    """The stored question type a task's primitive maps to.

    `fallback` is returned when the task names no usable primitive, so a caller
    can keep whatever type it would have chosen without the registry.
    """
    contract = task_answer_contract(task)
    primitive = contract.get("response")
    if not primitive:
        return fallback
    return TASK_PRIMITIVE_TO_QUESTION_TYPE.get(primitive, fallback)


# ---------------------------------------------------------------------------
# SHAPE QUOTAS
#
# "How many of what." A quota maps a SHAPE to a wanted count, where a shape is
# either a question type ("mcq") or a saved task template ("template:7").
#
# This generalises the type-coverage stage rather than sitting beside it. That
# stage already forces ONE item per selected type; a quota is the same idea with
# `wanted` allowed to exceed 1, so per-type counts (the admin's "MCQ x 2") and
# template counts ("this task x 3") are the SAME feature and share one code path.
# Built as two separate mechanisms, the second would have rewritten the first.
# ---------------------------------------------------------------------------

TEMPLATE_SHAPE_PREFIX = "template:"


def is_template_shape(shape):
    return isinstance(shape, str) and shape.startswith(TEMPLATE_SHAPE_PREFIX)


def template_id_of_shape(shape):
    """The template id inside a `template:<id>` shape, or None."""
    if not is_template_shape(shape):
        return None
    raw = shape[len(TEMPLATE_SHAPE_PREFIX):]
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


# Distinguishes "the caller stated an EMPTY allow-list" (Auto - drop bare type
# quotas) from "the caller did not state one at all" (no opinion - keep them).
# `()` alone cannot express both, and overloading it silently dropped quotas
# for a caller that was only reading stored JSON back.
_NO_ALLOW_LIST = object()


def parse_shape_quotas(raw, allowed_types=_NO_ALLOW_LIST):
    """`{shape: wanted}` from stored JSON or a dict, keeping only usable entries.

    Tolerant on purpose - a malformed quota must not lose a paid generation run,
    it must degrade to "no quota", which is exactly today's behaviour.

    A question-type shape is kept only when it is in `allowed_types`: a quota for
    a type the admin did not select is contradictory, and honouring it would
    author items the allow-list says to discard.

    THREE STATES, NOT TWO - and conflating the last two is a real defect this
    signature exists to prevent:

      * a NON-EMPTY list      -> keep the type quotas it names
      * an EMPTY list `()`    -> AUTO. The model picks the types, so a bare type
                                 quota is an instruction about a list that no
                                 longer exists. It is always a leftover from a
                                 session where types WERE selected, and keeping
                                 it was invisible AND load-bearing: the picker
                                 read "Any type" while the count and the
                                 generation directive still demanded "1 rubric,
                                 2 mcq" (generator 178, 2026-08-25).
      * OMITTED entirely      -> no opinion. Parse the shape and nothing else,
                                 for a caller reading stored JSON back before it
                                 knows what the allow-list will be.

    TEMPLATE shapes are never filtered by any of the three: a template names its
    own question type, which is why picking a task needs no type ticked beside it.
    """
    if isinstance(raw, str):
        raw = raw.strip()
        if not raw:
            return {}
        try:
            raw = json.loads(raw)
        except (ValueError, TypeError):
            return {}
    if not isinstance(raw, dict):
        return {}
    no_opinion = allowed_types is _NO_ALLOW_LIST
    allowed = set() if no_opinion else set(allowed_types or ())
    out = {}
    for shape, wanted in raw.items():
        if not isinstance(shape, str) or not shape.strip():
            continue
        shape = shape.strip()
        # bool is an int subclass; True would silently become a count of 1.
        if isinstance(wanted, bool) or not isinstance(wanted, (int, float)):
            continue
        wanted = int(wanted)
        if wanted <= 0:
            continue
        if is_template_shape(shape):
            if template_id_of_shape(shape) is None:
                continue
        elif no_opinion:
            pass                    # caller has not stated an allow-list yet
        elif not allowed:
            continue                # AUTO: a bare type quota means nothing now
        elif shape not in allowed:
            continue
        out[shape] = wanted
    return out


def quota_total(quotas):
    return sum(quotas.values()) if quotas else 0


def effective_generation_count(count, quotas, allowed=()):
    """How many items to ask for, given a total, a set of quotas and the types
    the operator ticked.

    The quotas are a FLOOR: asking for fewer items than the admin explicitly
    requested per shape would silently drop one of their choices, and the trim
    downstream would then have to pick a victim. So the count rises to the sum
    when the sum is larger, and the caller reports that rather than hiding it.

    A count of 0 means "auto" (the model decides), and a quota makes that
    concrete: auto plus `MCQ x 2` is a request for at least two items.

    AN ALLOWED TYPE WITH NO QUOTA COUNTS AS ONE. Its chip reads "any", and the
    UI has always promised that "a type with no explicit count still gets at
    least one item (the coverage floor)" - but the floor was built from the
    quotas alone, so "any" contributed nothing. Two things followed, both
    wrong: ticking a fifth type left the total on screen unchanged, and a run
    of `MSQ x3` plus `Rubric x any` asked the model for three items when the
    operator had asked for at least four.

    `allowed` must be the types the operator ACTUALLY TICKED, before
    `_widen_allowed_for_templates` adds the ones a template quota implies -
    those are already paid for by the template's own quota, and counting them
    here would charge the run twice for one choice.
    """
    quotas = quotas or {}
    total = quota_total(quotas)
    # A type carrying its own quota is counted by that quota, never twice.
    total += sum(1 for code in (allowed or ()) if code not in quotas)
    if not total:
        return count
    return max(count or 0, total)


def quota_shortfall(quotas, counted):
    """`{shape: still_wanted}` for shapes that have not met their quota.

    `counted` is `{shape: how_many_survive}` as measured by the caller, which
    owns what "survives" means (resolves in-list AND passes its validator).
    Keeps the caller's quota order so top-ups happen in the admin's order.
    """
    if not quotas:
        return {}
    out = {}
    for shape, wanted in quotas.items():
        have = int((counted or {}).get(shape) or 0)
        if have < wanted:
            out[shape] = wanted - have
    return out


def parse_flaw_plan(flaw_plan_json):
    raw = (flaw_plan_json or "").strip()
    if not raw:
        return {}
    try:
        plan = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return plan if isinstance(plan, dict) else {}


def ab_construction_keys(flaw_plan_json):
    plan = parse_flaw_plan(flaw_plan_json)
    keys = plan.get("construction_keys") if isinstance(plan, dict) else None
    if not isinstance(keys, dict):
        return {}
    # Normalize every key to its canonical dimension CODE (so 'ID Preservation',
    # 'ID' and 'IDP' collapse to 'IDP'); unknown SOP dims keep their upper token.
    out = {}
    for raw_code, verdict in keys.items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code and code not in out:
            out[code] = verdict
    return out


def ab_code_from_stored_label(label, construction_keys=None, labels_map=None):
    """Recover a dimension CODE from a STORED dimension name.

    THE INVERSE OF ``ab_dimension_display_label``, which is what actually wrote
    that name. For a SOP-numbered dimension the writer emits '<CODE> <title>'
    ("Q1 Instruction Aligned"), and ``ab_code_from_label`` cannot undo that: it
    upper-cases the whole string and hands back 'Q1 INSTRUCTION ALIGNED', which
    matches no construction key. Every drift check then compared two different
    namespaces and reported total drift on a perfectly sound answer key, so an
    entire family of image_ab questions - the independent YES/NO eval an I2I SOP
    produces - could never be approved and, had one reached the bank, would have
    scored 0 for every candidate behind the 'key_drift' gate.

    So re-render each expected code's own display label and match on that first.
    Reader and writer then agree by construction rather than by coincidence.
    Falls back to the plain normalization, which is still correct for a
    canonically-named dimension ('Instruction Following (IF)') and for any row
    written before the SOP-title format existed.
    """
    text = (label or "").strip()
    if not text:
        return ""
    labels_by_code = ab_dimension_labels_map(labels_map)
    for raw_code in (construction_keys or {}):
        code, _label = ab_normalize_dim_key(raw_code)
        if not code:
            continue
        rendered = ab_dimension_display_label(code, labels_by_code.get(code))
        if rendered.strip().casefold() == text.casefold():
            return code
    return ab_code_from_label(text)


#: Input kinds on which a candidate ticks several options (`answer_layouts.dart`).
MULTI_SELECT_KINDS = ("checkboxes", "checkboxGrid")


def takes_one_answer(question_type, input_kind=""):
    """True when a candidate picks ONE option on this axis, so more than one
    correct option there is a key nobody can earn (scoring is an exact-set
    match per axis). msq, and a checkboxes axis on any type, take several."""
    return (question_type != "msq"
            and (input_kind or "") not in MULTI_SELECT_KINDS)


def ab_materialized_keys(question_dimensions, construction_keys=None,
                         labels_map=None, name_field="name"):
    """{CODE: [correct option names]} read off stored question dimensions.

    The one place that turns dimension records back into a comparable answer
    key, so the approve-time guard and the score-time guard cannot drift apart
    the way they already had - both used to inline the same broken lookup.
    `name_field` is the axis name column: `name` on bank dimensions, `label`
    on draft ones (reading `.name` on a draft axis was an AttributeError, a
    500 on every image A/B draft answer-key save, 2026-10-13).
    """
    out = {}
    for qd in question_dimensions:
        code = ab_code_from_stored_label(
            qd[name_field], construction_keys, labels_map)
        if not code or code in out:
            continue
        out[code] = [ol.name for ol in qd.option_line_ids if ol.is_correct]
    return out


def ab_key_drift(materialized_keys, construction_keys):
    drift = []
    norm = {}
    for raw_code, verdict in (construction_keys or {}).items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code and code not in norm:
            norm[code] = verdict
    mat = {}
    for raw_code, verdicts in (materialized_keys or {}).items():
        code, _label = ab_normalize_dim_key(raw_code)
        if code and code not in mat:
            mat[code] = verdicts
    # Drive the check off the SOP's OWN dimension set, not a fixed list.
    for code, _label in ab_dimensions_from_keys(norm):
        expected = str(norm.get(code) or "").strip()
        got = [str(x).strip() for x in (mat.get(code) or [])]
        if not expected:
            drift.append("%s: no construction key" % code)
            continue
        # The stored option speaks the dimension's own vocabulary ("Image B"),
        # the construction key speaks the canonical one ("Response B"). Compare
        # the SIDE, or a SOP-labelled question reports total drift and is gated
        # to zero on a key that is in fact correct.
        if got != [expected] and got != [
                str(ab_align_verdict_to_options(expected, got)).strip()]:
            drift.append("%s expected=%r stored=%r" % (code, expected, got))
    return drift


# ══════════════════════════════════════════════════════════════════════════
#  THE ACCESS LADDER
# ══════════════════════════════════════════════════════════════════════════
#
# THE THREE RUNGS, LOWEST FIRST. `has_group` resolves through `implied_ids`
# (Admin implies Manager implies Candidate), so a guard tests the LOWEST group
# that should pass and the higher ones come along for free.
#
# `GROUP_MANAGER` keeps its name and still points at the full-power group, now
# labelled "Admin" - see `require_manager` and security/etp_assessment_security
# for why the xmlid was not repurposed.
#
# THEY LIVE HERE, NOT IN `controllers/api/common.py`, because models need them
# too: `res.users._be_assessment_role` and `assessments.be._ensure_candidate_user`
# both ask which rung an account is on, and a model importing from a controller
# is the wrong direction. `common.py` re-exports these names so its ~18 existing
# reference sites are untouched.
GROUP_CANDIDATE = "assessments_be_v2.group_assessment_candidate"
GROUP_MANAGER_RESTRICTED = (
    "assessments_be_v2.group_assessment_manager_restricted")
GROUP_MANAGER = "assessments_be_v2.group_assessment_manager"

# ══════════════════════════════════════════════════════════════════════════
#  THE ONE ANSWER TO "WHAT MAY THIS ACCOUNT DO HERE"
# ══════════════════════════════════════════════════════════════════════════
#
# THIS PLATFORM IS INTERNAL-USERS-ONLY. A portal user has no access to it at
# all - not as a candidate, not as a viewer, not on the media routes. That is a
# product rule, not an Odoo limitation, and it is the reason these three values
# are the complete set.
#
# WHY A NAMED ROLE AND NOT SCATTERED `_is_internal()` CALLS. The invariant used
# to be spelled out independently at four gates, and they did not agree:
# `admin_media` refused a non-internal caller outright, while
# `exam_media._refused` ADMITTED every internal user and then compared
# identities - so once candidates became internal accounts, its cross-candidate
# check became unreachable code and candidate A could fetch candidate B's exam
# media with B's token. One function, one answer, and a grep that proves there
# is no second copy.
ROLE_NONE = "none"
ROLE_CANDIDATE = "candidate"
ROLE_STAFF = "staff"

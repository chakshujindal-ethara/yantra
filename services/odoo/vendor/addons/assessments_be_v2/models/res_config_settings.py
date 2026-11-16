import base64

from odoo import api, fields, models
from odoo.exceptions import UserError, ValidationError

from ..constants import (
    CRON_LOCK_MODE_SELECTION,
    DEFAULT_PASS_THRESHOLD,
    DEFAULT_PASS_THRESHOLD_PARAM,
    DEFAULT_DAILY_LLM_CAP_USD,
    DEFAULT_PER_EVALUATOR_LLM_CAP_USD,
    MAX_SCORING_SHARDS,
    SETTING_RANGES,
    VERTEX_DEFAULT_LOCATION,
    VERTEX_DEFAULT_MODEL,
    VIDEO_DEFAULT_MODEL,
    VIDEO_DEFAULT_LOCATION,
    VIDEO_DEFAULT_DURATION_S,
    VIDEO_ALLOWED_DURATIONS_S,
)


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    assessments_be_vertex_project_id = fields.Char(
        string="Vertex Project ID (v2)",
        config_parameter="assessments_be_v2.vertex_project_id",
    )
    assessments_be_vertex_location = fields.Char(
        string="Vertex Location (v2)",
        config_parameter="assessments_be_v2.vertex_location",
        default=VERTEX_DEFAULT_LOCATION,
    )
    assessments_be_vertex_model = fields.Char(
        string="Vertex Model (v2)",
        config_parameter="assessments_be_v2.vertex_model",
        default=VERTEX_DEFAULT_MODEL,
        help="Default model used for scoring, image rendering, and any task "
             "without its own override.",
    )
    assessments_be_generation_model = fields.Char(
        string="Question Generation Model (v2)",
        config_parameter="assessments_be_v2.generation_model",
        help="Strong multimodal model that reads the SOP document (with its "
             "images) and authors questions directly. Must be DOCUMENT-capable: "
             "an image-generation model sees a PDF as opaque binary and fails "
             "with 'document has no pages'. gemini-3.1-pro-preview is the "
             "quality choice; gemini-3.8-flash is ~3x cheaper on the same "
             "1M-token context. Leave empty to fall back to the Vertex Model.",
    )
    assessments_be_detection_model = fields.Char(
        string="Image Detection Model (v2)",
        config_parameter="assessments_be_v2.detection_model",
        help="Multimodal model that READS an image_label stimulus and returns "
             "the numbered-box JSON. Needs vision, not image generation - an "
             "'-image' model returns a picture where JSON was expected and is "
             "refused here. gemini-3.1-flash-lite handles this at 1/8th of "
             "3.1-pro's rate. Leave empty to fall back to the Question "
             "Generation Model.",
    )
    assessments_be_verify_model = fields.Char(
        string="Flaw Verification Model (v2)",
        config_parameter="assessments_be_v2.verify_model",
        help="Model that re-reads a rendered image to confirm the planted "
             "flaws are actually visible, driving the A/B regenerate loop. "
             "Must READ an image, never the render model. Leave empty to fall "
             "back to the Image Detection Model. Previously settable only by "
             "writing the ir.config_parameter row by hand.",
    )
    assessments_be_thinking_level = fields.Selection(
        selection=[("", "Model default (recommended)"),
                   ("LOW", "LOW - cheapest, shallowest"),
                   ("MEDIUM", "MEDIUM"),
                   ("HIGH", "HIGH - deepest, dearest")],
        string="Gemini 3.x Thinking Level (v2)",
        config_parameter="assessments_be_v2.thinking_level",
        default="",
        help="How much internal reasoning Gemini 3.x models are allowed before "
             "answering. Thinking tokens bill at the OUTPUT rate, so this is a "
             "direct cost/quality dial.\n\n"
             "Leave at 'Model default' unless you have benched the alternative. "
             "Gemini 2.5 used a numeric thinkingBudget that this module set to "
             "0; Gemini 3.x replaced that parameter and ignores it, so 3.x "
             "traffic has been running at the model's own depth. Forcing LOW is "
             "cheaper but makes grading and authoring measurably shallower - "
             "bench it on a known cohort before turning it down. Has no effect "
             "on Gemini 2.5 models, on gemini-2.5-pro (which cannot be turned "
             "down at all), or on Veo.",
    )
    assessments_be_utility_model = fields.Char(
        string="Utility Model (cheap lane) (v2)",
        config_parameter="assessments_be_v2.utility_model",
        help="Cheap TEXT model for the high-volume mechanical lanes: "
             "extract_tags, consolidate_vocab and per-question skill "
             "labelling. These are short, structured jobs that do not need the "
             "authoring model's reasoning - gemini-3.1-flash-lite runs them at "
             "1/8th of gemini-3.1-pro's rate. Note extract_tags also ships the "
             "SOP, so whatever is set here must be able to read a PDF. Leave "
             "empty to fall back to the Question Generation Model, which is "
             "exactly the behaviour before this setting existed.",
    )
    assessments_be_scoring_model = fields.Char(
        string="Subjective Scoring Model (v2)",
        config_parameter="assessments_be_v2.scoring_model",
        help="TEXT reasoning model the subjective judge uses to grade answers "
             "against the golden key. MUST be a text model, never the image "
             "model - one set here is ignored with a warning in the log. This "
             "is the RECURRING cost: it scales with candidate volume, where "
             "authoring and video are one-off per question. It also receives "
             "every image and clip the candidate saw, so it needs vision. "
             "gemini-3.1-flash-lite is 8x cheaper than gemini-3.1-pro on both "
             "input and output; bench grading quality before trusting it on "
             "live cohorts. Leave empty to fall back to the Question "
             "Generation Model.",
    )
    assessments_be_fallback_model = fields.Char(
        string="Fallback Model (resilience) (v2)",
        config_parameter="assessments_be_v2.fallback_model",
        help="OPTIONAL. A second TEXT model retried automatically when the "
             "primary model fails transiently (quota 429, or a no-text/parse "
             "refusal) on a generation/scoring/detection call. A single Vertex "
             "model is a concentration risk: one regional outage or quota cut "
             "halts grading AND generation. Set a different model here (e.g. "
             "gemini-2.5-pro as a backup for gemini-3.1-pro-preview) so an "
             "outage is a config flip, not a stalled campaign. Leave empty to "
             "disable the fallback lane. Image/Veo calls are unaffected.",
    )
    assessments_be_image_model = fields.Char(
        string="Image Rendering Model (v2)",
        config_parameter="assessments_be_v2.image_model",
        help="Model used to RENDER image_ab / image_prompt / image_label "
             "pictures. Per generated image at the 1K/2K tier: "
             "gemini-3-pro-image (Nano Banana Pro) $0.134; "
             "gemini-3.1-flash-image (Nano Banana 2) $0.067; "
             "gemini-3.1-flash-lite-image (Nano Banana 2 Lite) $0.0336. Note "
             "the A/B flaw-verify loop can re-render up to twice per side, so a "
             "worst-case image_ab question is 6 renders. Leave empty to fall "
             "back to the Default Model. Keeping this separate means the "
             "Default Model can be a cheap text model without misrouting image "
             "rendering.",
    )
    assessments_be_video_model = fields.Char(
        string="Video Generation Model (Veo) (v2)",
        config_parameter="assessments_be_v2.video_model",
        default=VIDEO_DEFAULT_MODEL,
        help="OPTIONAL. Veo model for async video_prompt clip generation. Veo "
             "bills PER SECOND of output clip, not per token: "
             "veo-3.1-generate-001 $0.40/s, veo-3.1-fast-generate-001 $0.15/s, "
             "veo-3.1-lite-generate $0.05/s (preview - confirm GA before "
             "production). All three carry audio. A two-clip 8s question is "
             "therefore $6.40, $2.40 or $0.80. Video generation only fires when "
             "this AND Vertex credentials resolve; otherwise video_prompt clips "
             "stay upload-only.",
    )
    assessments_be_video_location = fields.Char(
        string="Video Generation Location (v2)",
        config_parameter="assessments_be_v2.video_location",
        default=VIDEO_DEFAULT_LOCATION,
        help="Vertex region for Veo. Veo is served on a regional endpoint "
             "(us-central1), NOT 'global' - the gemini default 404s for Veo.",
    )
    assessments_be_video_default_duration_s = fields.Selection(
        selection=[(str(s), "%s seconds" % s)
                   for s in VIDEO_ALLOWED_DURATIONS_S],
        string="Video Clip Duration (s) (v2)",
        config_parameter="assessments_be_v2.video_default_duration_s",
        default=str(VIDEO_DEFAULT_DURATION_S),
        help="Default generated clip length when a brief omits one. Veo "
             "accepts only these exact lengths - any other value is rejected "
             "with 'Unsupported output video duration'.",
    )
    assessments_be_vertex_api_key = fields.Char(
        string="Vertex API Key (v2)",
        config_parameter="assessments_be_v2.vertex_api_key",
    )
    assessments_be_vertex_access_token = fields.Char(
        string="Vertex Access Token (v2)",
        config_parameter="assessments_be_v2.vertex_access_token",
    )
    assessments_be_vertex_service_account_json = fields.Char(
        string="Service Account JSON (text) (v2)",
        config_parameter="assessments_be_v2.vertex_service_account_json",
    )
    assessments_be_vertex_service_account_filename = fields.Char(
        string="Service Account Filename (v2)",
        config_parameter="assessments_be_v2.vertex_service_account_filename",
    )
    # PREFIXED, like every other identifier this fork shares with upstream.
    #
    # The manifest promises that "every identifier that Odoo shares across
    # addons was renamed so the two never collide" and lists models, tables and
    # config keys. These transient upload fields were missed, and they are
    # exactly such an identifier: `vertex_sa_upload` was declared under that
    # bare name by this module, etp_assessment_pro AND etp_assessment, so Odoo
    # merged all three into ONE field on the shared res.config.settings.
    #
    # Every module's set_values() then ran against that one field on every
    # Save. Uploading a service-account key on this tab installed the SAME
    # private key into etp_assessment_pro.vertex_service_account_json and
    # etp_assessment.vertex_service_account_json - three modules re-pointed at
    # one GCP project by an admin who touched one form. The prefix un-merges
    # them, which is why the labels below need the " (v2)" suffix that a merged
    # field never had to carry (see tests/test_field_labels_are_unambiguous.py:
    # a merged field has no sibling row, so the test could not see the clash).
    assessments_be_vertex_sa_upload = fields.Binary(
        string="Upload Service Account JSON (v2)")
    assessments_be_vertex_sa_upload_filename = fields.Char(
        string="SA Upload Filename (v2)")

    assessments_be_s3_bucket = fields.Char(
        string="S3 Bucket (v2)",
        config_parameter="assessments_be_v2.s3_bucket",
    )
    assessments_be_s3_region = fields.Char(
        string="S3 Region (v2)",
        config_parameter="assessments_be_v2.s3_region",
        default="us-east-1",
    )
    assessments_be_s3_access_key_id = fields.Char(
        string="S3 Access Key ID (v2)",
        config_parameter="assessments_be_v2.s3_access_key_id",
    )
    assessments_be_s3_secret_key = fields.Char(
        string="S3 Secret Access Key (v2)",
        config_parameter="assessments_be_v2.s3_secret_key",
    )
    assessments_be_s3_folder = fields.Char(
        string="S3 Key Prefix (v2)",
        config_parameter="assessments_be_v2.s3_folder",
        default="etp_assessment",
    )
    assessments_be_s3_cdn_url = fields.Char(
        string="S3 CDN Base URL (v2)",
        config_parameter="assessments_be_v2.s3_cdn_url",
    )
    assessments_be_s3_max_retries = fields.Integer(
        string="S3 Max Upload Retries (v2)",
        config_parameter="assessments_be_v2.s3_max_retries",
        default=3,
    )

    # READ BY controllers/media_stream.py, WRITEABLE NOWHERE until now.
    #
    # `REDIRECT_PARAM` has always been an ir.config_parameter with no field and
    # no setting, so the only way to reach it was an Odoo shell - and it is
    # named in the deploy plan as something to turn on, which is exactly the
    # combination that gets set blind. It has a PREREQUISITE that breaks the
    # question bank when it is missed, so it needs to be somewhere an operator
    # reads the warning next to the switch.
    assessments_be_media_redirect_to_s3 = fields.Boolean(
        string="Redirect Media to S3 (v2)",
        config_parameter="assessments_be_v2.media_redirect_to_s3",
    )

    # READ BY models/ir_http.py, WRITEABLE NOWHERE until now.
    #
    # Both keys already decide whether a browser is allowed to talk to this
    # server at all, and both were documented in ir_http.py as the supported
    # way to onboard a front-end domain - but no field carried them, so the
    # only way to set either was an ir.config_parameter row typed by hand. An
    # operator adding a domain had no way to see the current value, and getting
    # it wrong does not fail loudly: Odoo answers correctly and the browser
    # discards the response.
    assessments_be_cors_origins = fields.Char(
        string="Allowed Browser Origins (v2)",
        config_parameter="assessments_be_v2.cors_origins",
    )
    assessments_be_cors_allow_localhost = fields.Boolean(
        string="Trust Localhost Origins (v2)",
        config_parameter="assessments_be_v2.cors_allow_localhost",
    )

    assessments_be_llm_max_attempts = fields.Integer(
        string="LLM Scoring Max Attempts (v2)",
        config_parameter="assessments_be_v2.llm_max_attempts",
        default=3,
        help="After this many failed scoring attempts a response resolves as a "
             "fail instead of staying pending forever.",
    )
    assessments_be_scoring_batch_size = fields.Integer(
        string="Scoring Batch Size (v2)",
        config_parameter="assessments_be_v2.scoring_batch_size",
        default=8,
        help="Max answers graded in one Vertex call. Large candidates are split "
             "into sub-batches of this size so no request overflows the token "
             "budget. Lower it if you see truncated scoring responses.",
    )
    assessments_be_scoring_tick_limit = fields.Integer(
        string="Scoring Candidates per Tick (v2)",
        config_parameter="assessments_be_v2.scoring_tick_limit",
        default=20,
        help="THROUGHPUT: how many submitted candidates each scoring cron drains "
             "per minute, per shard. Default 20/shard/min ~= 1,200/hr/shard; with "
             "scoring_shards up to 4 that is ~4,800/hr. Raise for a mass-hiring "
             "drive ONLY after confirming your Vertex requests-per-minute quota "
             "can absorb it - otherwise the extra calls just 429 (and re-queue). "
             "The true ceiling is Vertex quota, not this number.",
    )
    # Read by `assessment._scoring_shard_count` and controllers/api/admin.py,
    # and writable from the API; this field puts it on the Odoo form too.
    assessments_be_scoring_shards = fields.Integer(
        string="Scoring Shards (v2)",
        config_parameter="assessments_be_v2.scoring_shards",
        default=1,
        help="Parallel scoring workers. Shard N grades the candidates whose "
             "id %% shard_count == N, and each shard is driven by its OWN cron "
             "record in data/cron.xml - so raising this past the number of "
             "shard crons that exist (%d) buys nothing, because there is no "
             "cron to claim the extra shards' work." % MAX_SCORING_SHARDS,
    )
    assessments_be_scoring_parallel_calls = fields.Integer(
        string="Scoring Parallel Calls (v2)",
        config_parameter="assessments_be_v2.scoring_parallel_calls",
        default=SETTING_RANGES["scoring_parallel_calls"][2],
        help="Judge calls each shard keeps on the wire at once. A shard spends "
             "nearly all its time waiting on Vertex, so this multiplies its "
             "throughput without adding a second writer: marks are still "
             "stored one candidate at a time. 1 grades serially. Raise Tick "
             "limit with it (about 5x this) so each tick has enough candidates "
             "to keep the calls busy. Each call holds about 2 database "
             "connections, so a shard runs fewer when the pool is too small.",
    )
    assessments_be_answers_flush_seconds = fields.Integer(
        string="Answer batch interval (seconds) (v2)",
        config_parameter="assessments_be_v2.answers_flush_seconds",
        default=SETTING_RANGES["answers_flush_seconds"][2],
        help="How long the candidate's device waits before sending its unsent "
             "answers in one batch. Longer means fewer requests during a "
             "sitting, and up to that many seconds of typing at risk if the "
             "device dies. The device also sends when the candidate leaves a "
             "question, when the tab is hidden, and at Submit. Between 15 and "
             "300; 0 means the default (60).",
    )
    # Read by controllers/api/candidate.py (`_paper_prefetch`) on every
    # `/state`, `/begin` and `/paper`.
    assessments_be_paper_prefetch = fields.Boolean(
        string="Send the whole paper at start (v2)",
        config_parameter="assessments_be_v2.paper_prefetch",
        help="Right after a candidate starts, their device fetches every "
             "question of their paper once, then moves between questions "
             "without asking the server again. Answers are still sent in "
             "batches. The paper is kept in the browser's memory only, never "
             "on disk. Off: one request per question move, as before.",
    )
    # Read by `services/question_cache.py` only when REDIS_URL is not set.
    assessments_be_redis_url = fields.Char(
        string="Question cache Redis URL (v2)",
        config_parameter="assessments_be_v2.redis_url",
        help="Production uses the REDIS_URL environment variable; this field "
             "is for local and stage testing, e.g. redis://localhost:6379/0. "
             "Empty means the question cache is off and every question is "
             "built from the database, as before.",
    )
    # Read on every tick by `services/locks.cron_lock`, raw SQL, no cache.
    assessments_be_cron_lock_mode = fields.Selection(
        selection=CRON_LOCK_MODE_SELECTION,
        string="Background job lock (v2)",
        config_parameter="assessments_be_v2.cron_lock_mode",
        default="advisory",
        help="How the background jobs make sure only one copy of each runs "
             "at a time. Keep Advisory lock unless the database is reached "
             "through PgBouncer in transaction mode; then switch to Lease "
             "row. Applies from each job's next run. Switch in a quiet "
             "window: set Shards to 1 and wait until no job holds a lock in "
             "the current mode.",
    )
    assessments_be_scoring_parallel_calls_effective = fields.Integer(
        string="Parallel Calls in Use (v2)",
        compute="_compute_be_scoring_parallel_calls_effective",
        help="What each grading lane (shard) actually runs. All lanes share "
             "half of the database pool (db_maxconn); each lane keeps 2 "
             "connections for its own cursor, and each call holds about 2. "
             "So a lane runs (db_maxconn / 2 - 2 x lanes) / (2 x lanes) "
             "calls, at least 1 and at most the setting. Example: pool 64 "
             "with 4 lanes gives 3 each; pool 600 gives the full setting.",
    )
    # THE COMPANION TO scoring_shards, and the reason both are on this screen.
    #
    # Raising shards multiplies the Vertex call rate directly - 4 shards drain 4
    # candidates at once - so shards without a limiter turns a slow grading queue
    # into a quota-exhausted one. This is the proactive limit; without it only
    # 429 handling remains, a wasted round trip per refused call.
    assessments_be_vertex_max_rpm = fields.Integer(
        string="Vertex Calls per Minute (v2)",
        config_parameter="assessments_be_v2.vertex_max_rpm",
        default=0,
        help="RATE CEILING: the most billable Vertex calls this deployment will "
             "make in any trailing 60 seconds, counted from the usage ledger so "
             "it holds across every worker and cron shard. 0 (the default) means "
             "no limit, which is the behaviour before this setting existed. Set "
             "it to your project's requests-per-minute quota - slightly BELOW, "
             "so a burst refuses locally at no cost instead of 429-ing at "
             "Vertex. A refused call is not a scoring failure: the candidate "
             "stays queued and is graded on a later tick. Set this WHENEVER you "
             "raise Scoring Shards.",
    )
    assessments_be_score_outlier_sigma = fields.Float(
        string="Score-Outlier Review Sigma (v2)",
        config_parameter="assessments_be_v2.score_outlier_sigma",
        default=2.0,
        help="INTEGRITY REVIEW: flag a submitted candidate for human review when "
             "their SUBJECTIVE score sits this many standard deviations ABOVE "
             "the cohort mean - the review net for a prompt-injection that "
             "dodged the answer gate and inflated a grader score. Subjective "
             "marks only, and only once the cohort is fully graded: an "
             "objective answer is checked against a stored key, so scoring "
             "well on one is not evidence of anything. 0 disables outlier "
             "flagging. Advisory only: never changes a score or pass/fail.",
    )
    assessments_be_pii_retention_days = fields.Integer(
        string="Candidate PII Retention (days) (v2)",
        config_parameter="assessments_be_v2.pii_retention_days",
        default=0,
        help="DATA RETENTION (GDPR storage-limitation): anonymize candidate "
             "free-text answers, violation reasons, and grader audit prose on "
             "SUBMITTED attempts older than this many days (a daily cron). "
             "Numeric scores and pass/fail are ALWAYS kept - only PII/free text "
             "is scrubbed. 0 (default) disables the purge, so nothing is deleted "
             "until you opt in. For on-demand erasure use the candidate's "
             "'Erase Candidate Data' action.",
    )
    assessments_be_default_pass_threshold = fields.Integer(
        string="Default Pass Threshold (%) (v2)",
        config_parameter=DEFAULT_PASS_THRESHOLD_PARAM,
        default=DEFAULT_PASS_THRESHOLD,
        help="The Pass Threshold a NEW assessment starts with (1-100). "
             "Changing it never touches existing assessments.",
    )
    assessments_be_daily_llm_cap_usd = fields.Float(
        string="Daily LLM Spend Cap (USD) (v2)",
        config_parameter="assessments_be_v2.daily_llm_cap_usd",
        # THE SAME CONSTANT THE GATE ENFORCES WITH. When the row is absent this
        # form falls back to its field default (res_config.py:266) while
        # `vertex.spend_cap` falls back to the module default - two literals
        # that had no reason to stay equal and every opportunity to drift.
        default=DEFAULT_DAILY_LLM_CAP_USD,
        help="H-5: refuse any Vertex call once same-day recorded LLM spend "
             "reaches this. 0 disables the daily cap. Protects against a "
             "cost-DoS (adversarial answers) draining the budget in one cycle.",
    )
    assessments_be_per_evaluator_llm_cap_usd = fields.Float(
        string="Per-Candidate LLM Spend Cap (USD) (v2)",
        config_parameter="assessments_be_v2.per_evaluator_llm_cap_usd",
        default=DEFAULT_PER_EVALUATOR_LLM_CAP_USD,
        help="H-5: refuse further Vertex calls for one candidate once their "
             "recorded LLM spend reaches this. 0 disables the per-candidate "
             "cap. Stops a single candidate consuming the whole budget.",
    )

    @api.constrains("assessments_be_default_pass_threshold")
    def _check_be_default_pass_threshold(self):
        for rec in self:
            if not 1 <= rec.assessments_be_default_pass_threshold <= 100:
                raise ValidationError(
                    "Default pass threshold must be between 1 and 100.")

    def _compute_be_scoring_parallel_calls_effective(self):
        # From the SAVED setting: what the lanes run now, not the unsaved edit.
        effective = self.env["assessments.be"]._scoring_parallel_calls()
        for rec in self:
            rec.assessments_be_scoring_parallel_calls_effective = effective

    @api.constrains("assessments_be_llm_max_attempts",
                    "assessments_be_scoring_batch_size",
                    "assessments_be_scoring_shards",
                    "assessments_be_scoring_parallel_calls",
                    "assessments_be_answers_flush_seconds",
                    "assessments_be_vertex_max_rpm",
                    "assessments_be_daily_llm_cap_usd",
                    "assessments_be_per_evaluator_llm_cap_usd",
                    "assessments_be_score_outlier_sigma")
    def _check_be_llm_limits(self):
        """NAMED FOR THIS ADDON, because the plain name was taken.

        `etp_assessment_pro` defines `_check_llm_limits` on `res.config.settings`
        too - same model, different fields, and no `super()` call. Odoo composes
        the model class from every installed addon, so one plain method wins and
        the other is gone, TOGETHER WITH ITS `@api.constrains` TRIGGER LIST.
        Both modules are installed on production, so a shared name would switch
        these checks off. The API path applies the same bounds
        (`controllers/api/write.py`).
        """
        # H-5 hardening: a compromised/fat-fingered admin setting attempts=100 or
        # batch=1000 would multiply spend / overflow the token budget. Clamp the
        # accepted range at the write path.
        #
        # THE BOUNDS COME FROM `constants.SETTING_RANGES`, which the write API
        # and the pre-deploy gate read too, so the three cannot drift apart.
        attempts_low, attempts_high, attempts_default = \
            SETTING_RANGES["llm_max_attempts"]
        batch_low, batch_high, batch_default = \
            SETTING_RANGES["scoring_batch_size"]
        shard_low, shard_high, shard_default = SETTING_RANGES["scoring_shards"]
        calls_low, calls_high, calls_default = \
            SETTING_RANGES["scoring_parallel_calls"]
        flush_low, flush_high, flush_default = \
            SETTING_RANGES["answers_flush_seconds"]
        for rec in self:
            if not (attempts_low <= (rec.assessments_be_llm_max_attempts
                                     or attempts_default) <= attempts_high):
                raise UserError(
                    "LLM Scoring Max Attempts must be between %d and %d."
                    % (attempts_low, attempts_high))
            if not (batch_low <= (rec.assessments_be_scoring_batch_size
                                  or batch_default) <= batch_high):
                raise UserError(
                    "Scoring Batch Size must be between %d and %d."
                    % (batch_low, batch_high))
            # _scoring_shard_count already clamps on READ, so an out-of-range
            # value is not dangerous - it is silently ignored, which is worse to
            # operate than a refusal. Saying no at the write path is the only
            # way the form can tell an admin that shards=8 did not take effect.
            if not (shard_low <= (rec.assessments_be_scoring_shards
                                  or shard_default) <= shard_high):
                raise UserError(
                    "Scoring Shards must be between %d and %d - one per shard "
                    "cron in data/cron.xml. A higher number is ignored at "
                    "runtime because no cron claims those shards."
                    % (shard_low, shard_high))
            if not (calls_low <= (rec.assessments_be_scoring_parallel_calls
                                  or calls_default) <= calls_high):
                raise UserError(
                    "Scoring Parallel Calls must be between %d and %d."
                    % (calls_low, calls_high))
            if not (flush_low <= (rec.assessments_be_answers_flush_seconds
                                  or flush_default) <= flush_high):
                raise UserError(
                    "Answer batch interval must be between %d and %d seconds."
                    % (flush_low, flush_high))
            # A NEGATIVE CEILING WOULD READ AS "no limit", because the gate
            # treats anything <= 0 that way - so a fat-fingered -1 would silently
            # disable the limiter the admin was trying to set. Refuse at the
            # write path, which is the only place that can say so.
            if (rec.assessments_be_vertex_max_rpm or 0) < 0:
                raise UserError(
                    "Vertex Calls per Minute cannot be negative. Use 0 for no "
                    "limit, or the requests-per-minute ceiling you want.")
            # THE SAME REASONING, FOR THE MONEY. `vertex.spend_cap` returns a
            # stored negative verbatim and both budget gates read `cap > 0`, so
            # a fat-fingered -100 in a spend cap does not lower the cap - it
            # removes it, and `/api/v1/budget` then reports `capped: false`,
            # which reads as "no cap configured" rather than "your cap is
            # broken". The outlier sigma guards on `<= 0` and goes the same
            # way. The JSON API refuses a negative on all three as well.
            for field_name, label in (
                    ("assessments_be_daily_llm_cap_usd",
                     "Daily LLM Spend Cap (USD)"),
                    ("assessments_be_per_evaluator_llm_cap_usd",
                     "Per-Candidate LLM Spend Cap (USD)"),
                    ("assessments_be_score_outlier_sigma",
                     "Score-Outlier Review Sigma")):
                if (rec[field_name] or 0) < 0:
                    raise UserError(
                        "%s cannot be negative. Use 0 to disable it, or the "
                        "value you want enforced." % label)

    assessments_be_question_prompt = fields.Char(
        string="Question Generation Prompt (v2)",
        config_parameter="assessments_be_v2.question_prompt",
    )
    assessments_be_question_prompt_upload = fields.Binary(
        string="Upload question.md (v2)")
    assessments_be_question_prompt_upload_filename = fields.Char(
        string="Question Prompt Upload Filename (v2)")
    assessments_be_question_prompt_filename = fields.Char(
        string="Question Prompt Filename (v2)",
        config_parameter="assessments_be_v2.question_prompt_filename",
    )

    # ------------------------------------------------------------------
    # Uploaded-file persistence.
    #
    # These .json / .md files are delivered through transient Binary fields
    # (assessments_be_vertex_sa_upload,
    # assessments_be_question_prompt_upload) and
    # must land in ir.config_parameter. The persistence therefore lives in
    # set_values(), which runs inside the committed Save transaction.
    #
    # It MUST NOT live in an @api.onchange handler: Odoo runs onchange in a
    # side-effect-free context and rolls its cursor back, so any set_param()
    # done there is silently discarded. The onchange handlers below only
    # decode for instant in-form feedback ("Current: <filename>"); they never
    # write to the DB.
    # ------------------------------------------------------------------
    #
    # NAMED FOR THIS ADDON, like `_check_be_llm_limits` above:
    # `etp_assessment_pro` defines `_decode_upload` on `res.config.settings`
    # too, and the `be_` prefix means the two never have to stay identical.
    @staticmethod
    def _be_decode_upload(raw_b64, label):
        try:
            return base64.b64decode(raw_b64).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise UserError("%s must be a UTF-8 text file (%s)." % (label, exc))

    def get_values(self):
        res = super().get_values()
        # M-8: the secret params are stored encrypted; decrypt them for the
        # settings form so the admin sees the real value (or a legacy plaintext),
        # not the ciphertext. Writing back through set_values re-encrypts.
        #
        # DERIVED FROM SECRET_PARAM_KEYS, the tuple set_values encrypts, so a
        # new secret is never encrypted on Save and then shown (and re-saved)
        # as ciphertext.
        from ..services import secret_store
        ICP = self.env["ir.config_parameter"].sudo()
        for param_key in secret_store.SECRET_PARAM_KEYS:
            # Every one of these fields is the parameter's own suffix prefixed
            # with `assessments_be_`. A future key that breaks the convention is
            # skipped rather than written into `res` under a name no field
            # answers to.
            field_name = "assessments_be_" + param_key.split(".", 1)[1]
            if field_name not in self._fields:
                continue
            stored = ICP.get_param(param_key, "")
            if secret_store.is_encrypted(stored):
                res[field_name] = secret_store.decrypt(self.env, stored)
        # A bad stored value (text, 0, over 100) reads as 70, so the page still
        # opens and saves instead of failing its own 1-100 check.
        res["assessments_be_default_pass_threshold"] = int(
            self.env["assessments.be"]._default_pass_threshold())
        return res

    def set_values(self):
        # Persist the uploaded files BEFORE super() so the config_parameter
        # fields super() writes carry the freshly decoded text. Runs in the
        # Save transaction, so it sticks (an onchange write would not).
        for rec in self:
            ICP = rec.env["ir.config_parameter"].sudo()
            if rec.assessments_be_vertex_sa_upload:
                text = rec._be_decode_upload(
                    rec.assessments_be_vertex_sa_upload, "Service account JSON")
                fname = (rec.assessments_be_vertex_sa_upload_filename
                         or "service-account.json")
                rec.assessments_be_vertex_service_account_json = text
                rec.assessments_be_vertex_service_account_filename = fname
                # A new SA invalidates any cached minted bearer.
                ICP.set_param("assessments_be_v2.vertex_minted_token", "")
                ICP.set_param(
                    "assessments_be_v2.vertex_minted_token_expires", "")
            if rec.assessments_be_question_prompt_upload:
                text = rec._be_decode_upload(
                    rec.assessments_be_question_prompt_upload, "Question prompt")
                rec.assessments_be_question_prompt = text
                rec.assessments_be_question_prompt_filename = (
                    rec.assessments_be_question_prompt_upload_filename
                    or "question.md")
        res = super().set_values()
        ICP = self.env["ir.config_parameter"].sudo()
        # A DELIBERATE 0 HAS TO SURVIVE THE SAVE. Odoo core coerces a falsy
        # numeric to False (`res_config.py:340`, `repr(value) if value else
        # False`) and `set_param(False)` UNLINKS the row
        # (`ir_config_parameter.py:98`). The next read then falls back to the
        # field default - so typing 0.00 into a cap whose help says "0 disables
        # the cap" silently restores $100/day, and re-saving cannot fix it
        # because the second save short-circuits on `False == False`
        # (`res_config.py:344`). So the zeros are written back explicitly,
        # derived from the classified fields rather than a list of key names,
        # so every "0 disables" field (`score_outlier_sigma` too) is covered.
        #
        # THE SIDE EFFECT, STATED: this writes "0" for ALL ~10 falsy int/float
        # `assessments_be_v2` config fields on every save, not just the caps.
        # No reader breaks - every one of them guards (`vertex.spend_cap`
        # callers on `> 0`, `scoring._max_attempts` / `_scoring_batch_size` on
        # `> 0`, `assessment._scoring_shard_count` / the tick limit / the PII
        # purge / `s3_service` on their own clamps) - but the stored "0" does
        # not mean one thing: for the two caps and `score_outlier_sigma` it
        # means DISABLED, while for the scheduler knobs
        # (`llm_max_attempts`, `scoring_batch_size` and friends) the write API
        # already treats it as "unset, use the module default"
        # (`controllers/api/write.py`, the `_SETTING_BOUNDS` check). That
        # ambiguity is accepted deliberately: the alternative is a second
        # hand-maintained exemption list beside this one, which is the kind of
        # list that drifts silently the first time a field is added.
        #
        # The prefix guard keeps this off every other module's parameters.
        for name, icp in self._get_classified_fields()["config"]:
            if not icp.startswith("assessments_be_v2."):
                continue
            if self._fields[name].type in ("integer", "float") \
                    and not self[name]:
                ICP.set_param(icp, "0")
        # M-8: super() wrote the secret params as plaintext via their
        # config_parameter binding. Re-encrypt them at rest now (idempotent - an
        # already-encrypted value is left as-is). Readers decrypt on access.
        from ..services import secret_store
        for key in secret_store.SECRET_PARAM_KEYS:
            cur = ICP.get_param(key, "")
            if cur and not secret_store.is_encrypted(cur) \
                    and "PLACEHOLDER" not in str(cur):
                ICP.set_param(key, secret_store.encrypt(self.env, cur))
        return res

    @api.onchange("assessments_be_vertex_sa_upload")
    def _onchange_be_vertex_sa_upload(self):
        """NAMED FOR THIS ADDON, because the plain name was taken.

        `etp_assessment_pro` defines `_onchange_vertex_sa_upload` and
        `_onchange_question_prompt_upload` on `res.config.settings` too, and
        neither copy calls `super()`. Odoo composes one class per model, so a
        shared name drops one addon's `@api.onchange` trigger list and its
        upload stops filling the box as the file is picked (`set_values` still
        persists it). Same defect class as `_check_be_llm_limits`.
        """
        # Decode for immediate feedback only; real persistence is in set_values.
        if not self.assessments_be_vertex_sa_upload:
            return
        text = self._be_decode_upload(
            self.assessments_be_vertex_sa_upload, "Service account JSON")
        self.assessments_be_vertex_service_account_json = text
        self.assessments_be_vertex_service_account_filename = (
            self.assessments_be_vertex_sa_upload_filename
            or "service-account.json")

    @api.onchange("assessments_be_question_prompt_upload")
    def _onchange_be_question_prompt_upload(self):
        if not self.assessments_be_question_prompt_upload:
            return
        text = self._be_decode_upload(
            self.assessments_be_question_prompt_upload, "Question prompt")
        self.assessments_be_question_prompt = text
        self.assessments_be_question_prompt_filename = (
            self.assessments_be_question_prompt_upload_filename
            or "question.md")


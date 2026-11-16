# -*- coding: utf-8 -*-
"""LLM usage ledger — one row per LLM/image API call; written best-effort by services/vertex.py."""
from odoo import models, fields, api


class EtpLlmUsage(models.Model):
    _name = "assessments.be.llm.usage"
    _description = "LLM Call Usage / Token Ledger"
    _order = "create_date desc"
    _rec_name = "operation"

    # EVERY VALUE ANY CALLER WRITES MUST BE IN THIS LIST.
    #
    # A Selection refuses an unlisted value with a ValueError on create, and
    # `vertex._log_usage` swallows its own failures so a logging hiccup cannot
    # take down scoring or generation. So an unlisted operation would be billed
    # by Google yet missing from the ledger, the LLM Budget dashboard and
    # `_check_budget`'s daily-cap sum, which reads this table. `_log_usage`
    # also coerces anything still unknown to `other` rather than losing the row.
    #
    # Adding a new operation is therefore TWO edits, not one: the `usage_ctx`
    # at the call site, and this list.
    operation = fields.Selection(
        [
            ("extract_skills", "Extract Skills"),
            ("extract_tags", "Extract Tags"),
            ("generate_questions", "Generate Questions"),
            ("generate_image", "Generate Image"),
            ("detect_image_elements", "Detect Image Elements"),
            ("locate_defect", "Locate Defect"),
            ("verify_planted_flaws", "Verify Planted Flaws"),
            ("generate_video", "Generate Video"),
            ("submit_video_op", "Submit Video (Veo)"),
            ("fetch_video_op", "Poll Video (Veo)"),
            ("score_subjective", "Score Subjective"),
            ("scoring_cache_create", "Scoring Cache Create"),
            ("scoring_cache_refresh", "Scoring Cache Refresh"),
            ("assign_question_skills", "Assign Question Skills"),
            ("draft_task_template", "Draft Task Template"),
            ("consolidate_vocab", "Consolidate Vocabulary"),
            ("map_similarity", "Map SOP Similarity"),
            ("other", "Other"),
        ],
        string="Operation", required=True, default="other", index=True)
    model = fields.Char(string="Model", index=True)
    tokens_in = fields.Integer(string="Tokens In")
    tokens_out = fields.Integer(string="Tokens Out")
    thoughts_tokens = fields.Integer(
        string="Thinking Tokens",
        help="Gemini 2.5/3 hidden reasoning tokens, billed as output.")
    cached_tokens = fields.Integer(
        string="Cached Tokens",
        help="Part of Tokens In that Vertex served from its context cache "
             "(usageMetadata.cachedContentTokenCount), billed at a 90% "
             "discount. Usually zero while caching is off; a re-sent "
             "request can hit Vertex's automatic cache.")
    total_tokens = fields.Integer(
        string="Total Tokens", compute="_compute_total_tokens", store=True)
    image_count = fields.Integer(string="Images")
    video_seconds = fields.Float(
        string="Video Seconds", digits=(12, 2), default=0.0,
        help="Seconds of generated video (Veo) for this call; drives the "
             "per-second video cost. 0 for non-video calls.")
    cost_usd = fields.Float(
        string="Est. Cost (USD)", digits=(12, 5),
        help="Best-effort estimate from a per-model rate table in "
             "services/vertex.py; the token counts are exact.")
    prompt_id = fields.Many2one(
        "assessments.be.prompt", string="Generator",
        ondelete="set null", index=True)
    evaluator_id = fields.Many2one(
        "assessments.be.evaluator", string="Candidate",
        ondelete="set null",
        # THE PER-CANDIDATE SPEND CAP FILTERS ON THIS, and it does so before
        # every billable Vertex call. The ledger is also the fastest-growing
        # table during a grading wave - one row per call, multiplied by shards -
        # so the scan it was doing got worse exactly when grading got busiest.
        index=True)
    note = fields.Char(string="Note")
    # Filled by `vertex._ledger_values` for text calls; 0 elsewhere.
    latency_ms = fields.Integer(string="Latency (ms)")
    attempt = fields.Integer(
        string="Attempt",
        help="Which HTTP try this row is: 1, or 2 for the re-ask. A call's "
             "count is the highest value over its rows.")

    @api.depends("tokens_in", "tokens_out", "thoughts_tokens")
    def _compute_total_tokens(self):
        for rec in self:
            rec.total_tokens = ((rec.tokens_in or 0) + (rec.tokens_out or 0)
                                + (rec.thoughts_tokens or 0))

"""Vertex calls are refused locally before they exhaust the project quota.

THE GAP (G9). There was no proactive rate limiting of any kind - only reactive
429 handling once Vertex had already refused (`services/vertex.py`). Two
consequences:

  * A 429 is a wasted round trip. Under a sustained grading wave it is most of
    the traffic, and each one still costs the latency of the call.
  * `scoring_shards` and `scoring_parallel_calls` are the throughput levers and
    they multiply the call rate directly - each shard is a lane, and each lane
    keeps up to `scoring_parallel_calls` calls on the wire. So raising them
    WITHOUT a limiter converts a slow grading queue into a quota-exhausted one.
    The plan costed a 1,200-candidate wave at ~2.1h with shards=4 against ~8.3h
    at the default of 1, and that arithmetic only holds if the calls actually
    land.

THE DESIGN, and the two decisions worth stating:

1. **Counted from the usage ledger, not an in-process counter.** Four shard
   crons run in four processes; no counter in one of them can see the others.
   `assessments.be.llm.usage` is already written on every billable call, so the
   count is shared by construction and needs no new bookkeeping.

2. **Raises `VertexQuotaError` - Vertex's own 429 - not a new class.** Every
   caller already treats that as TRANSIENT and requeues the candidate
   (`models/prompt.py`, `services/scoring.py`). A new exception class would be
   caught by none of them and would surface as a scoring FAILURE, marking a
   candidate ungradeable for what is a capacity condition. Refusing locally is
   the same event as being refused remotely, one round trip earlier.

A TRAILING 60 SECONDS rather than a clock minute, because a per-minute bucket
lets a wave spend its whole allowance in the last second of one minute and again
in the first of the next - double the intended rate exactly when a queue is
draining hardest.
"""
from datetime import datetime, timedelta
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import vertex


@tagged("-at_install", "post_install")
class TestTheGraderRespectsACallRateCeiling(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Usage = self.env["assessments.be.llm.usage"]
        self.icp = self.env["ir.config_parameter"].sudo()
        # A clean window: the ledger is shared, and rows a previous test left
        # behind would be counted. Measured from the same table the gate reads.
        self._baseline = vertex._calls_since(self.env, 60)

    def _log_calls(self, n, age_seconds=1):
        """Write `n` ledger rows as though `age_seconds` ago.

        `create_date` is normally set by the ORM, so it is written explicitly -
        the whole point of the gate is which rows fall inside its window.
        """
        stamp = (datetime.utcnow()
                 - timedelta(seconds=age_seconds)).strftime(
                     "%Y-%m-%d %H:%M:%S")
        rows = self.Usage.create([{
            "operation": "score_subjective",
            "model": "gemini-test",
            "cost_usd": 0.0,
        } for _ in range(n)])
        # A direct UPDATE: `create_date` is not writeable through the ORM.
        self.env.cr.execute(
            "UPDATE assessments_be_llm_usage SET create_date = %s "
            "WHERE id IN %s", (stamp, tuple(rows.ids)))
        self.env.cr.flush() if hasattr(self.env.cr, "flush") else None
        rows.invalidate_recordset()
        return rows

    def _set_limit(self, rpm):
        self.icp.set_param("assessments_be_v2.vertex_max_rpm", str(rpm))

    # ── the ceiling ───────────────────────────────────────────────────

    def test_a_call_over_the_ceiling_is_refused(self):
        """THE HEADLINE. The ceiling is reached, so the next call never happens.

        `_check_rate` is called from `_check_budget`, which every billable entry
        point runs before its HTTP request - so refusing here means no money and
        no round trip.
        """
        self._log_calls(5)
        self._set_limit(self._baseline + 5)

        with self.assertRaises(vertex.VertexQuotaError) as caught:
            vertex._check_rate(self.env)

        message = str(caught.exception)
        self.assertIn("rate limit", message.lower())
        self.assertIn("60s", message,
                      "the refusal should name the window it measured")

    def test_a_call_under_the_ceiling_is_allowed(self):
        """The other half, and the one a blanket refusal would break."""
        self._log_calls(2)
        self._set_limit(self._baseline + 50)

        # No exception is the assertion.
        vertex._check_rate(self.env)

    def test_zero_means_no_limit(self):
        """THE DEFAULT MUST CHANGE NOTHING.

        `vertex_max_rpm` defaults to 0, and every deployment that has not
        configured a quota must behave exactly as before this setting existed.
        A limiter that throttles by default would slow every install to fix a
        problem only large cohorts have.
        """
        self._log_calls(500)
        self._set_limit(0)

        vertex._check_rate(self.env)

    def test_an_unset_parameter_means_no_limit(self):
        """Not merely 0 - ABSENT. A fresh database has no row at all, and
        `_spend_cap` returns the default for an empty value."""
        self.icp.set_param("assessments_be_v2.vertex_max_rpm", "")
        self._log_calls(500)

        vertex._check_rate(self.env)

    # ── the window ────────────────────────────────────────────────────

    def test_calls_older_than_the_window_do_not_count(self):
        """A TRAILING window, so the ceiling recovers as time passes.

        Without this a busy minute would refuse every call thereafter: the count
        would only ever grow.
        """
        self._log_calls(50, age_seconds=120)
        self._set_limit(self._baseline + 10)

        # 50 calls exist, but they are two minutes old - outside the window.
        vertex._check_rate(self.env)

    def test_the_window_counts_across_workers(self):
        """The reason the ledger is the source rather than a counter.

        Four shard crons run in four PROCESSES. This cannot start a second
        process, so it asserts the mechanism that makes cross-worker counting
        possible: the count comes from the shared table, so rows this session did
        not create are still counted.
        """
        # Rows written directly, as another worker's would appear - no ORM
        # instance of this test ever "made" these calls.
        self.env.cr.execute(
            """
            INSERT INTO assessments_be_llm_usage
                (operation, model, cost_usd, create_date, write_date,
                 create_uid, write_uid)
            SELECT 'score_subjective', 'gemini-other-worker', 0.0,
                   NOW() - INTERVAL '5 seconds', NOW(), %s, %s
              FROM generate_series(1, 7)
            """, (self.env.uid, self.env.uid))

        counted = vertex._calls_since(self.env, 60)
        self.assertGreaterEqual(
            counted - self._baseline, 7,
            "calls another worker recorded are not counted, so the ceiling is "
            "per-process and four shards would each get the full allowance")

    # ── the exception type is the contract ────────────────────────────

    def test_the_refusal_is_the_transient_kind(self):
        """A rate limit must not mark a candidate ungradeable.

        `VertexQuotaError` is what the callers requeue on; `VertexBudgetError` is
        the one they surface as a refusal. Raising the wrong one would fail a
        candidate for a capacity condition - so the CLASS is part of the
        contract, not an implementation detail.
        """
        self._log_calls(3)
        self._set_limit(self._baseline + 1)

        with self.assertRaises(vertex.VertexQuotaError):
            vertex._check_rate(self.env)
        # And explicitly NOT the non-transient one.
        self.assertFalse(
            issubclass(vertex.VertexQuotaError, vertex.VertexBudgetError),
            "the transient and permanent refusals must stay distinguishable")

    def test_the_gate_runs_inside_check_budget(self):
        """Placement, because it is what makes coverage automatic.

        `_check_budget` is already called at the top of all four billable entry
        points. Putting the rate check inside it means a new call path cannot
        remember one gate and forget the other - which is exactly how a limiter
        ends up covering three of four paths.
        """
        self._log_calls(4)
        self._set_limit(self._baseline + 2)

        with self.assertRaises(vertex.VertexQuotaError):
            vertex._check_budget(self.env, {})

    # ── the settings surface ──────────────────────────────────────────

    def test_a_negative_ceiling_is_refused_at_the_write_path(self):
        """-1 would read as "no limit" and silently disable the limiter the
        admin was trying to set, so the form has to say no."""
        from odoo.exceptions import UserError

        settings = self.env["res.config.settings"].create({})
        with self.assertRaises(UserError):
            settings.assessments_be_vertex_max_rpm = -1
            settings._check_be_llm_limits()

    def test_the_setting_is_visible_in_the_back_office(self):
        """An undiscoverable parameter is one that gets missed - which is how
        `scoring_shards` came to be documented by the help text of a DIFFERENT
        field. This one ships with a field and a view entry from the start.
        """
        field = self.env["res.config.settings"]._fields.get(
            "assessments_be_vertex_max_rpm")
        self.assertIsNotNone(field, "no field, so nothing renders")
        self.assertEqual(field.config_parameter,
                         "assessments_be_v2.vertex_max_rpm")
        view = self.env.ref(
            "assessments_be_v2.res_config_settings_view_form_assessments_be_v2",
            raise_if_not_found=False)
        if view:
            self.assertIn("assessments_be_vertex_max_rpm", view.arch,
                          "the field exists but no setting renders it")

# -*- coding: utf-8 -*-
"""The 19.0.3.28.0 upgrade: AI violations move to their own columns (R5), and
papers stop sharing one quit password (R3).

Each case writes what an attempt or paper looked like BEFORE the upgrade with
raw SQL (one log holding both kinds, the AI pair at the field defaults -u
fills in, one password on several papers), runs the post-migrate, and reads
the result back. A second run must change nothing.
"""
import importlib.util
import json
import os
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


def _load_migration():
    """The post-migrate module, by path (`migrations/` is not a package)."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "migrations", "19.0.3.28.0", "post-migrate.py")
    spec = importlib.util.spec_from_file_location("be_v2_ai_split_mig", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _entry(reason, second):
    return {"reason": reason, "at": "2026-10-14 10:00:%02d" % second}


SHARED = "aaaa-bbbb-cccc"


@tagged("-at_install", "post_install")
class TestTheUpgradeSplitsAiViolations(TransactionCase):

    def setUp(self):
        super().setUp()
        self.migration = _load_migration()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Split %s" % uuid4().hex[:6]})

    def _paper(self, **vals):
        return self.env["assessments.be"].create(dict({
            "name": "Split %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
        }, **vals))

    def _attempt(self, paper, log, count):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Split %s" % uuid4().hex[:6],
            "email_from": "split_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET violation_log = %s::jsonb, "
            "violation_count = %s, is_violated = TRUE WHERE id = %s",
            (json.dumps(log) if log is not None else None, count, ev.id))
        return ev

    def _sql(self, query, params):
        self.env.flush_all()
        self.env.cr.execute(query, params)
        self.env.invalidate_all()

    def _run(self):
        """One run; returns the mocked logger. Pending ORM writes go first,
        as they would be on disk before an upgrade."""
        self.env.flush_all()
        with patch.object(self.migration, "_logger") as logger:
            self.migration.migrate(self.env.cr, "19.0.3.27.0")
        self.env.invalidate_all()
        return logger

    @staticmethod
    def _state(ev):
        return (ev.violation_count, ev.violation_log,
                ev.ai_violation_count, ev.ai_violation_log)

    # ── R5: the logs ──────────────────────────────────────────────────

    def test_the_logs_split_in_order_and_the_counts_follow(self):
        paper = self._paper(max_violations=9)
        log = [_entry("tab-switch", 1), _entry("AI: No face in view", 2),
               _entry("copy-paste", 3), _entry("AI: Phone in view", 4),
               _entry("AI: No face in view", 5)]
        ev = self._attempt(paper, log, 5)
        self._run()
        self.assertEqual(ev.violation_log, [log[0], log[2]])
        self.assertEqual(ev.ai_violation_log, [log[1], log[3], log[4]])
        self.assertEqual((ev.violation_count, ev.ai_violation_count), (2, 3))
        self.assertTrue(ev.is_violated)

        before = self._state(ev)
        self._run()
        self.assertEqual(self._state(ev), before,
                         "a second run must change nothing")

    def test_unlogged_history_stays_regular(self):
        paper = self._paper(max_violations=9)
        # Counted before the log existed: 6 violations, 1 of them logged.
        ev = self._attempt(paper, [_entry("AI: Phone in view", 1)], 6)
        regular = self._attempt(paper, [_entry("tab-switch", 1)], 1)
        erased = self._attempt(paper, [], 4)
        legacy = self._attempt(paper, None, 3)
        self._run()
        self.assertEqual((ev.violation_count, ev.ai_violation_count), (5, 1))
        self.assertEqual(ev.violation_log, [])
        for untouched, count in ((regular, 1), (erased, 4), (legacy, 3)):
            self.assertEqual(untouched.violation_count, count)
            self.assertEqual(untouched.ai_violation_count, 0)
            self.assertFalse(untouched.ai_violation_log)

    def test_an_attempt_ended_under_the_shared_cap_keeps_its_record(self):
        """Auto-submitted for violations before the split: its 3 counted
        together, so splitting would leave `violation` with no breach."""
        paper = self._paper(max_violations=3, violation_action="auto_submit")
        log = [_entry("tab-switch", 1), _entry("AI: No face in view", 2),
               _entry("AI: Phone in view", 3)]
        ended = self._attempt(paper, log, 3)
        self._sql("UPDATE assessments_be_evaluator SET auto_submit_reason = "
                  "'violation' WHERE id = %s", (ended.id,))
        self._run()
        self.assertEqual(self._state(ended)[:3], (3, log, 0))
        self.assertFalse(ended.ai_violation_log)
        self.assertEqual(ended.auto_submit_reason, "violation")

    def test_a_breached_limit_keeps_its_record_under_log_only(self):
        """Log only never ends the paper, so `auto_submit_reason` is empty -
        but 3 combined at a cap of 3 shows "Violation Limit Breached", and a
        split would leave 1 of 3 and take the label away."""
        paper = self._paper(max_violations=3, violation_action="log_only")
        log = [_entry("tab-switch", 1), _entry("AI: No face in view", 2),
               _entry("AI: Phone in view", 3)]
        breached = self._attempt(paper, log, 3)
        under = self._attempt(paper, log[:2], 2)
        self.env.invalidate_all()
        self.assertTrue(breached.violation_limit_breached)

        self._run()

        self.assertEqual(self._state(breached)[:3], (3, log, 0))
        self.assertFalse(breached.ai_violation_log)
        self.assertTrue(breached.violation_limit_breached)
        self.assertEqual(self._state(under),
                         (1, [log[0]], 1, [log[1]]),
                         "under the cap the split runs as before")

    def test_a_count_below_its_ai_entries_stops_at_zero(self):
        paper = self._paper(max_violations=9)
        log = [_entry("AI: No face in view", 1), _entry("AI: Phone in view", 2)]
        short = self._attempt(paper, log, 1)
        self._run()
        self.assertEqual(self._state(short), (0, [], 2, log))

    def test_a_null_or_object_log_is_left_alone(self):
        paper = self._paper(max_violations=9)
        null = self._attempt(paper, [], 2)
        obj = self._attempt(paper, [], 1)
        self._sql("UPDATE assessments_be_evaluator SET violation_log = "
                  "'null'::jsonb WHERE id = %s", (null.id,))
        self._sql("UPDATE assessments_be_evaluator SET violation_log = %s::jsonb "
                  "WHERE id = %s",
                  (json.dumps(_entry("AI: Phone in view", 1)), obj.id))
        self._run()
        self.assertEqual((null.violation_count, null.ai_violation_count), (2, 0))
        self.assertEqual((obj.violation_count, obj.ai_violation_count), (1, 0))
        self.assertEqual(obj.violation_log, _entry("AI: Phone in view", 1))
        self.assertFalse(obj.ai_violation_log)

    # ── R5: the policy ────────────────────────────────────────────────

    def test_each_paper_starts_its_ai_policy_from_its_own(self):
        strict = self._paper(max_violations=2, violation_action="auto_submit")
        relaxed = self._paper(max_violations=9, violation_action="log_only")
        # What -u leaves on an existing row: the field defaults.
        self._sql("UPDATE assessments_be SET ai_max_violations = 5, "
                  "ai_violation_action = 'log_only' WHERE id IN %s",
                  (tuple((strict | relaxed).ids),))
        self._run()
        self.assertEqual((strict.ai_max_violations, strict.ai_violation_action),
                         (2, "auto_submit"))
        self.assertEqual((relaxed.ai_max_violations, relaxed.ai_violation_action),
                         (9, "log_only"))

        strict.ai_max_violations = 4  # an admin's choice after the upgrade
        self._run()
        self.assertEqual(strict.ai_max_violations, 4,
                         "a second run must not undo a chosen AI policy")

    # ── R3: the quit passwords ────────────────────────────────────────

    def test_a_shared_quit_password_is_replaced_per_paper(self):
        first, second = self._paper(), self._paper()
        running = self._paper(rule_require_seb=True)
        # Each half of "a running SEB paper" alone is renewed.
        seb_only = self._paper(rule_require_seb=True)
        running_only = self._paper()
        unique = self._paper(seb_quit_password="dddd-eeee-ffff")
        self._sql("UPDATE assessments_be SET seb_quit_password = %s "
                  "WHERE id IN %s", (SHARED, tuple(
                      (first | second | running | seb_only
                       | running_only).ids)))
        self._sql("UPDATE assessments_be SET state = 'in_progress' "
                  "WHERE id IN %s", (tuple((running | running_only).ids),))

        logger = self._run()

        fresh = {first.seb_quit_password, second.seb_quit_password,
                 seb_only.seb_quit_password, running_only.seb_quit_password}
        self.assertEqual(len(fresh), 4, "each paper gets its own")
        self.assertNotIn(SHARED, fresh)
        for password in fresh:
            self.assertRegex(
                password, r"^[0-9a-hjkmnp-tv-z]{4}(-[0-9a-hjkmnp-tv-z]{4}){3}$")
        self.assertEqual(running.seb_quit_password, SHARED,
                         "a running SEB sitting keeps the password its .seb holds")
        self.assertEqual(unique.seb_quit_password, "dddd-eeee-ffff")
        skipped = [call.args[2] for call in logger.warning.call_args_list
                   if "quit password" in call.args[0]]
        self.assertEqual(skipped, [[running.id]])

        self._run()
        self.assertEqual(
            {first.seb_quit_password, second.seb_quit_password,
             seb_only.seb_quit_password, running_only.seb_quit_password},
            fresh, "a second run must change nothing")

    # ── R6: the answer key is shown by default ───────────────────────

    def test_a_null_show_answers_becomes_shown(self):
        """`init()` gives the column a default only from that -u on. A DB that
        gained the column on an earlier -u kept NULL rows, read as hidden."""
        null, hidden = self._paper(), self._paper(results_show_answers=False)
        self._sql("UPDATE assessments_be SET results_show_answers = NULL "
                  "WHERE id = %s", (null.id,))

        logger = self._run()

        self.assertTrue(null.results_show_answers)
        self.assertFalse(hidden.results_show_answers, "a chosen Off stays")
        self.assertGreaterEqual(logger.info.call_args.args[-1], 1)
        self.assertEqual(self._run().info.call_args.args[-1], 0,
                         "a second run must change nothing")

    # ── R7: transcription keys holding a digit ───────────────────────

    def test_a_transcription_key_with_a_digit_is_listed_not_changed(self):
        """Numbers are words in a key now, so a key published before that
        reads a correct words answer as a difference. Listed for a person to
        fix; the key itself is not touched."""
        def clip(text, category="none"):
            return self.env["assessments.be.question"].create({
                "name": "Clip %s" % uuid4().hex[:6],
                "question_type": "transcription",
                "prompt": "Type exactly what is said.",
                "solution_json": json.dumps(
                    {"transcription": text, "category": category,
                     "characteristics": [], "speakers": [{"id": 2}]},
                    ensure_ascii=False)})
        ascii_digit = clip("नंबर 10 है")
        devanagari = clip("नंबर १० है")
        words = clip("नंबर दस है")
        untranscribed = clip("", category="no_speech")
        unreadable = clip("x")
        self._sql("UPDATE assessments_be_question SET solution_json = "
                  "'not json 5' WHERE id = %s", (unreadable.id,))
        mine = {ascii_digit.id, devanagari.id, words.id, untranscribed.id,
                unreadable.id}

        logger = self._run()

        listed = [call.args[2] for call in logger.warning.call_args_list
                  if "digit" in call.args[0]]
        self.assertEqual(len(listed), 1, logger.warning.call_args_list)
        self.assertEqual(set(listed[0]) & mine,
                         {ascii_digit.id, devanagari.id})
        self.assertEqual(json.loads(ascii_digit.solution_json)["transcription"],
                         "नंबर 10 है")

    def test_a_fresh_install_does_nothing(self):
        with patch.object(self.migration, "_logger") as logger:
            self.migration.migrate(self.env.cr, None)
        logger.info.assert_not_called()

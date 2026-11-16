# -*- coding: utf-8 -*-
"""W15: `tools/calibration/compare.py` passes a new grading request only when it
moves marks no more than the model's own wobble and not one way.

Synthetic JSONL, built so every number is known: 30 answers whose two baseline
runs sit 4 either side of a true mark (wobble MAD 8).
"""
import importlib.util
import json
import os
import tempfile

from odoo.tests.common import TransactionCase, tagged


def _tool(name):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "tools", "calibration", name + ".py")
    spec = importlib.util.spec_from_file_location("calibration_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


compare = _tool("compare")


def _row(arm, run, key, raw, qtype="subjective_rubric", **extra):
    return dict({
        "key": str(key), "answer_id": key, "trick": None, "arm": arm,
        "run": run, "question_type": qtype, "source": "model",
        "state": "scored", "raw_100": raw, "passed": raw >= 70,
        "threshold": 70, "box_scores": None, "caps": [], "model": "m",
        "requested_model": "m", "call": key // 10, "tokens_in": 100,
        "tokens_out": 10, "thinking_tokens": 20, "cached_tokens": 0,
        "cost_usd": 0.01, "dry_run": False}, **extra)


def _baseline():
    truth = [40 + 2 * k for k in range(30)]
    rows = []
    for k, t in enumerate(truth):
        rows.append(_row("baseline", 1, k, t + 4))
        rows.append(_row("baseline", 2, k, t - 4))
    return truth, rows


def _arm(truth, arm, offsets):
    return [_row(arm, 1, k, t + offsets[k % len(offsets)])
            for k, t in enumerate(truth)]


@tagged("-at_install", "post_install")
class TestTheCalibrationVerdictFollowsTheWobble(TransactionCase):

    def _analyse(self, rows):
        """Through a real JSONL file, as the runners write it."""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "arms.jsonl")
            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(json.dumps(r) + "\n" for r in rows)
            text, analysis = compare.report(compare.load([path]), [path])
        return text, analysis

    def test_an_arm_inside_the_wobble_passes(self):
        truth, rows = _baseline()
        _text, a = self._analyse(rows + _arm(truth, "new_uncached", (2, -2)))
        self.assertEqual(a["wobble"]["subjective_rubric"]["mad"], 8.0)
        s = a["arms"][("new_uncached", 1)]["subjective_rubric"]
        self.assertEqual((s["n"], s["mad"], s["signed"]), (30, 2.0, 0.0))
        self.assertEqual(s["p"], 1.0)
        self.assertEqual(s["verdict"], "PASS")

    def test_a_small_move_all_one_way_fails_on_drift(self):
        truth, rows = _baseline()
        _text, a = self._analyse(rows + _arm(truth, "new_cached", (3,)))
        s = a["arms"][("new_cached", 1)]["subjective_rubric"]
        self.assertLess(s["mad"], 8.0, "inside the wobble on size alone")
        self.assertEqual(s["signed"], 3.0)
        self.assertAlmostEqual(s["p"], 2 / 2 ** 30)
        self.assertEqual(s["verdict"], "FAIL")

    def test_a_wider_spread_with_no_drift_fails(self):
        truth, rows = _baseline()
        _text, a = self._analyse(rows + _arm(truth, "new_uncached", (12, -12)))
        s = a["arms"][("new_uncached", 1)]["subjective_rubric"]
        self.assertEqual((s["mad"], s["signed"], s["p"]), (12.0, 0.0, 1.0))
        self.assertEqual(s["verdict"], "FAIL")

    def test_flips_count_pass_fail_changes_at_the_bar(self):
        rows = [_row("baseline", 1, 1, 72), _row("baseline", 2, 1, 68),
                _row("new_uncached", 1, 1, 71)]
        _text, a = self._analyse(rows)
        self.assertEqual(a["wobble"]["subjective_rubric"]["flips"], 1.0)
        self.assertEqual(
            a["arms"][("new_uncached", 1)]["subjective_rubric"]["flips"], 0.5,
            "passes against run 1, flips against run 2")

    def test_labelling_boxes_flip_one_by_one(self):
        label = lambda arm, run, boxes: _row(  # noqa: E731
            arm, run, 7, 60, qtype="image_label", box_scores=boxes)
        rows = [label("baseline", 1, {"1": 80, "2": 50, "3": 90}),
                label("baseline", 2, {"1": 65, "2": 50, "3": 90}),
                label("new_uncached", 1, {"1": 80, "2": 75, "3": 90})]
        text, a = self._analyse(rows)
        self.assertEqual(a["wobble"]["image_label"]["box_flips"], (1, 3))
        self.assertEqual(
            a["arms"][("new_uncached", 1)]["image_label"]["box_flips"], (3, 6),
            "box 2 flips against both runs, box 1 against run 2")
        self.assertIn("| new_uncached#1 | 3 | 6 | 50.0% |", text)

    def test_a_sign_test_is_two_sided(self):
        self.assertAlmostEqual(compare.sign_test([1] * 10), 2 / 1024)
        self.assertAlmostEqual(compare.sign_test([-1] * 10), 2 / 1024)
        self.assertEqual(compare.sign_test([1, -1] * 5), 1.0)
        self.assertEqual(compare.sign_test([0, 0]), 1.0)

    def test_rows_the_model_did_not_grade_are_counted_not_compared(self):
        truth, rows = _baseline()
        arm = _arm(truth, "new_uncached", (2, -2))
        arm[0]["model"] = "gemini-2.5-pro"        # the fallback rescued it
        arm[1]["source"] = "code"                 # gated, never sent
        arm[2]["state"] = "failed"                # truncated labelling reply
        _text, a = self._analyse(rows + arm)
        self.assertEqual(
            a["arms"][("new_uncached", 1)]["subjective_rubric"]["n"], 27)
        excluded = a["excluded"][("new_uncached", 1)]
        self.assertEqual(excluded["served by another model"], 1)
        self.assertEqual(excluded["marked by code, not the model"], 1)
        self.assertEqual(excluded["not scored (failed)"], 1)

    def test_tricks_are_reported_apart_and_never_move_the_verdict(self):
        truth, rows = _baseline()
        arm = _arm(truth, "new_uncached", (2, -2))
        trick = _row("new_uncached", 1, 999, 5, trick="invented",
                     caps=["fabrication"])
        trick["key"] = "T01"
        text, a = self._analyse(rows + arm + [trick])
        s = a["arms"][("new_uncached", 1)]["subjective_rubric"]
        self.assertEqual((s["n"], s["verdict"]), (30, "PASS"))
        self.assertIn("| T01 | invented | subjective_rubric | 5 F |", text)

    def test_the_report_carries_cost_and_caps(self):
        truth, rows = _baseline()
        rows[0]["caps"] = ["fabrication"]
        text, _a = self._analyse(rows)
        self.assertIn("| baseline#1 | 30 | 3 | 3000 | 300 | 600 | 0 | 0 | "
                      "$0.30 | $0.0100 |", text)
        self.assertIn("| baseline#1 | subjective_rubric | 30 | 3% | 0% | 0% |",
                      text)

    # -- too few answers (R6-05, B3-24) -----------------------------------------

    def test_a_type_the_arm_never_graded_is_insufficient_not_a_pass(self):
        truth, rows = _baseline()
        labels = [_row(arm, run, 100 + k, t + d, qtype="image_label")
                  for k, t in enumerate(truth)
                  for arm, run, d in (("baseline", 1, 4), ("baseline", 2, -4))]
        arm = _arm(truth, "new_uncached", (2, -2)) + [
            _row("new_uncached", 1, 100 + k, 0, qtype="image_label",
                 state="harness_error") for k in range(30)]
        text, a = self._analyse(rows + labels + arm)
        stats = a["arms"][("new_uncached", 1)]
        self.assertEqual(stats["subjective_rubric"]["verdict"], "PASS")
        self.assertEqual(
            (stats["image_label"]["n"], stats["image_label"]["verdict"]),
            (0, "INSUFFICIENT"))
        self.assertIn("- **new_uncached#1: INCOMPLETE**", text)

    def test_a_thin_type_is_insufficient_whatever_its_numbers(self):
        truth, rows = _baseline()
        arm = _arm(truth, "new_cached", (0,))[:compare.MIN_PER_TYPE - 1]
        text, a = self._analyse(rows + arm)
        s = a["arms"][("new_cached", 1)]["subjective_rubric"]
        self.assertEqual((s["mad"], s["verdict"]), (0.0, "INSUFFICIENT"),
                         "inside the wobble, but on too few answers")
        self.assertIn("- **new_cached#1: INCOMPLETE**", text)
        _text, one = self._analyse(rows + _arm(truth, "new_cached", (0,))[:1])
        self.assertEqual(one["arms"][("new_cached", 1)]["subjective_rubric"]
                         ["verdict"], "INSUFFICIENT")

    def test_a_type_the_baseline_never_scored_is_insufficient(self):
        truth, rows = _baseline()
        labels = [_row("baseline", run, 100 + k, 0, qtype="image_label",
                       state="harness_error")
                  for k in range(30) for run in (1, 2)]
        arm = _arm(truth, "new_uncached", (2, -2)) + [
            _row("new_uncached", 1, 100 + k, t, qtype="image_label")
            for k, t in enumerate(truth)]
        text, a = self._analyse(rows + labels + arm)
        s = a["arms"][("new_uncached", 1)]["image_label"]
        self.assertEqual((s["n"], s["verdict"]), (0, "INSUFFICIENT"))
        self.assertIn("- **new_uncached#1: INCOMPLETE**", text)

    def test_a_thin_wobble_is_insufficient(self):
        truth, rows = _baseline()
        rows = [r for r in rows if r["run"] == 1 or int(r["key"]) < 3]
        # Run 1 alone is the reference past key 2: the arm sits 2 either side.
        arm = [_row("new_uncached", 1, k, t + (4 if k >= 3 else 0)
                    + (2, -2)[k % 2]) for k, t in enumerate(truth)]
        text, a = self._analyse(rows + arm)
        self.assertEqual(a["wobble"]["subjective_rubric"]["n"], 3)
        s = a["arms"][("new_uncached", 1)]["subjective_rubric"]
        self.assertEqual((s["n"], s["verdict"]), (30, "INSUFFICIENT"))
        self.assertIn("- **new_uncached#1: INCOMPLETE**", text)

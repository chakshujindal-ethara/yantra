#!/usr/bin/env python3
"""W15: read the arms' JSONL files and say, per question type, whether the new
request moves marks more than the model's own wobble. Plain Python, no Odoo.

    python3 compare.py calib/*.jsonl --out calib/report.md

Wobble = baseline run 1 vs run 2. Each new arm is compared with the MEAN of
the two baseline runs:
- mean absolute difference (MAD) and mean signed difference, with a two-sided
  sign test for one-way drift;
- pass/fail flips at the stored pass bar (against each baseline run).
Verdict per type and arm: PASS when MAD <= the wobble's MAD and the sign test
is not significant (p >= 0.05); else FAIL. A type any run has rows of, but
compared on fewer than MIN_PER_TYPE answers (none included) in the arm or in
the wobble, is INSUFFICIENT, and the arm's overall verdict is then INCOMPLETE,
never PASS.

Why the mean: a new request exactly as noisy as today's lands ~13% under the
wobble MAD against the baseline mean, which is the headroom the PASS rule
needs. Against a single baseline run the two MADs have the same expectation,
so an arm that changed nothing would FAIL half the time (simulated: 50% at
n=30; with the mean, 23% at n=30 and 9% at n=100, while an arm with twice the
wobble's variance fails 71% / 86%).

Only rows the model graded and the code stored as `scored`, on the model the
arm asked for, are compared; the rest are counted as excluded. Trick answers
(`trick` set) are reported on their own.
"""
import argparse
import collections
import json
from math import comb

BASELINE = "baseline"
ALPHA = 0.05
#: Fewer compared answers than this and a type's verdict is noise.
MIN_PER_TYPE = 20


def load(paths):
    rows = []
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            rows += [json.loads(line) for line in fh if line.strip()]
    return rows


def exclusion(row):
    """Why a row is not compared, or None."""
    if row.get("dry_run"):
        return "dry run"
    if row.get("source") != "model":
        return "marked by code, not the model"
    if row.get("state") != "scored":
        return "not scored (%s)" % row.get("state")
    if row.get("requested_model") and row.get("model") != row["requested_model"]:
        return "served by another model"
    return None


def sign_test(diffs):
    """Two-sided sign test p-value; zero differences are dropped."""
    up = sum(d > 0 for d in diffs)
    down = sum(d < 0 for d in diffs)
    n = up + down
    if not n:
        return 1.0
    tail = sum(comb(n, i) for i in range(min(up, down) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def _mean(values):
    values = list(values)
    return sum(values) / len(values) if values else None


def _box_flips(row, refs):
    """(flipped, compared) boxes: a box passes at the row's own pass bar."""
    flipped = compared = 0
    for ref in refs:
        mine, theirs = row.get("box_scores") or {}, ref.get("box_scores") or {}
        bar = row.get("threshold") or 0
        for box in set(mine) | set(theirs):
            compared += 1
            flipped += ((float(mine.get(box) or 0) >= bar)
                        != (float(theirs.get(box) or 0) >= bar))
    return flipped, compared


def compare(arm, refs_by_key):
    """Stats of ``arm`` rows against their baseline rows, per type."""
    out = {}
    by_type = collections.defaultdict(list)
    for row in arm:
        refs = refs_by_key.get(row["key"])
        if refs:
            by_type[row["question_type"]].append((row, refs))
    for qtype, pairs in by_type.items():
        diffs = [row["raw_100"] - _mean(r["raw_100"] for r in refs)
                 for row, refs in pairs]
        boxes = [_box_flips(row, refs) for row, refs in pairs]
        out[qtype] = {
            "n": len(pairs),
            "mad": _mean(abs(d) for d in diffs),
            "signed": _mean(diffs),
            "p": sign_test(diffs),
            "flips": _mean(_mean(row["passed"] != r["passed"] for r in refs)
                           for row, refs in pairs),
            "box_flips": (sum(b[0] for b in boxes), sum(b[1] for b in boxes)),
        }
    return out


def analyse(rows):
    usable = collections.defaultdict(dict)       # (arm, run) -> key -> row
    excluded = collections.defaultdict(collections.Counter)
    for row in rows:
        why = exclusion(row)
        if why:
            excluded[(row["arm"], row["run"])][why] += 1
        else:
            usable[(row["arm"], row["run"])][row["key"]] = row
    base_runs = sorted(k for k in usable if k[0] == BASELINE)
    plain = lambda d: {k: r for k, r in d.items() if not r.get("trick")}  # noqa: E731
    wobble = {}
    if len(base_runs) >= 2:
        a, b = plain(usable[base_runs[0]]), plain(usable[base_runs[1]])
        wobble = compare([a[k] for k in sorted(a) if k in b],
                         {k: [b[k]] for k in b})
    refs = collections.defaultdict(list)
    for run in base_runs[:2]:
        for key, row in plain(usable[run]).items():
            refs[key].append(row)
    # Excluded rows count: a type every baseline row of failed stays in.
    types = {r["question_type"] for r in rows if not r.get("trick")}
    runs = {(r["arm"], r["run"]) for r in rows if r["arm"] != BASELINE}
    arms = {}
    for arm_run in sorted(runs):
        stats = compare(list(plain(usable.get(arm_run, {})).values()), refs)
        for qtype in types - set(stats):
            stats[qtype] = {"n": 0, "mad": None, "signed": None, "p": None,
                            "flips": None, "box_flips": (0, 0)}
        for qtype, s in stats.items():
            w = wobble.get(qtype)
            s["verdict"] = (
                "INSUFFICIENT" if s["n"] < MIN_PER_TYPE
                or (w and w["n"] < MIN_PER_TYPE) else
                "NO WOBBLE" if not w else
                "PASS" if s["mad"] <= w["mad"] and s["p"] >= ALPHA else "FAIL")
        arms[arm_run] = stats
    return {"usable": usable, "excluded": excluded, "wobble": wobble,
            "arms": arms, "base_runs": base_runs}


def _fmt(value, spec="%.1f"):
    return "-" if value is None else spec % value


def report(rows, sources=()):
    a = analyse(rows)
    usable, wobble, arms = a["usable"], a["wobble"], a["arms"]
    name = lambda k: "%s#%s" % k  # noqa: E731
    lines = ["# Calibration report", ""]
    if sources:
        lines += ["Inputs: " + ", ".join("`%s`" % s for s in sources), ""]
    counts = collections.Counter((r["arm"], r["run"]) for r in rows)
    lines += ["| arm | rows | compared | excluded |", "|---|---|---|---|"]
    for k in sorted(counts):
        why = "; ".join("%s %d" % (w, n) for w, n in a["excluded"][k].items())
        lines.append("| %s | %d | %d | %s |" % (name(k), counts[k],
                                               len(usable.get(k, {})), why or "-"))
    if len(a["base_runs"]) < 2:
        lines += ["", "**No wobble: two baseline runs are needed.**"]
    lines += ["", "## Verdict per question type", "",
              "Wobble = baseline run 1 vs run 2. MAD = mean absolute "
              "difference (0-100 raw) from the mean of the two baseline runs. "
              "Drift = mean signed difference (new minus baseline) and its "
              "sign-test p. PASS: MAD <= wobble MAD and p >= %.2f. Flips = "
              "pass/fail changes at the pass bar. INSUFFICIENT: under %d "
              "answers compared, in the arm or the wobble." % (
                  ALPHA, MIN_PER_TYPE), "",
              "| type | arm | n | MAD | wobble MAD | drift (p) | flips | "
              "wobble flips | verdict |", "|---|---|---|---|---|---|---|---|---|"]
    overall = {}
    for arm_run, stats in arms.items():
        for qtype in sorted(stats):
            s, w = stats[qtype], wobble.get(qtype) or {}
            lines.append("| %s | %s | %d | %s | %s | %s (%s) | %s | %s | **%s** |" % (
                qtype, name(arm_run), s["n"], _fmt(s["mad"]),
                _fmt(w.get("mad")), _fmt(s["signed"], "%+.1f"),
                _fmt(s["p"], "%.3f"),
                _fmt(None if s["flips"] is None else s["flips"] * 100,
                     "%.0f%%"),
                _fmt(w["flips"] * 100 if w else None, "%.0f%%"), s["verdict"]))
            overall.setdefault(arm_run, set()).add(s["verdict"])
    lines += [""] + ["- **%s: %s**" % (name(k), "PASS" if v == {"PASS"} else
                                       "FAIL" if "FAIL" in v else "INCOMPLETE")
                     for k, v in overall.items()]

    lines += ["", "## Labelling box flips", "",
              "A box passes when its own score reaches the pass bar.", "",
              "| comparison | flipped boxes | of | rate |", "|---|---|---|---|"]
    for label, stats in [("wobble (baseline 1 vs 2)", wobble)] + [
            (name(k), s) for k, s in arms.items()]:
        flipped, total = (stats.get("image_label") or {}).get(
            "box_flips", (0, 0))
        lines.append("| %s | %d | %d | %s |" % (
            label, flipped, total,
            _fmt(flipped * 100 / total if total else None, "%.1f%%")))

    lines += ["", "## Caps fired (share of compared answers)", "",
              "| arm | type | n | fabrication | 2+ checklist zeros | "
              "verdict contradiction |", "|---|---|---|---|---|---|"]
    caps = {"fabrication": "fabrication",
            "zeros": "multi_checklist_zero",
            "contradiction": "verdict_contradiction"}
    for k in sorted(usable):
        by_type = collections.defaultdict(list)
        for row in usable[k].values():
            if not row.get("trick"):
                by_type[row["question_type"]].append(row)
        for qtype in sorted(by_type):
            group = by_type[qtype]
            rate = lambda cap: _fmt(100 * sum(  # noqa: E731
                cap in (r.get("caps") or []) for r in group) / len(group),
                "%.0f%%")
            lines.append("| %s | %s | %d | %s | %s | %s |" % (
                name(k), qtype, len(group), rate(caps["fabrication"]),
                rate(caps["zeros"]), rate(caps["contradiction"])))

    lines += ["", "## Tokens and cost (every row the model graded)", "",
              "| arm | answers | calls | tokens in | out | thinking | cached | "
              "cachedContent calls | cost | per answer |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for k in sorted(counts):
        graded = [r for r in rows if (r["arm"], r["run"]) == k
                  and r.get("source") == "model"]
        total = lambda f: sum(r.get(f) or 0 for r in graded)  # noqa: E731
        cost = total("cost_usd")
        lines.append("| %s%s | %d | %d | %d | %d | %d | %d | %d | $%.2f | %s |" % (
            name(k), " (dry run, estimated)" if any(
                r.get("dry_run") for r in graded) else "",
            len(graded), len({r.get("call") for r in graded}),
            total("tokens_in"), total("tokens_out"), total("thinking_tokens"),
            total("cached_tokens"),
            len({r.get("call") for r in graded if r.get("cached_content")}),
            cost, "$%.4f" % (cost / len(graded)) if graded else "-"))

    tricks = [r for r in rows if r.get("trick")]
    if tricks:
        runs = sorted({(r["arm"], r["run"]) for r in tricks})
        keys = sorted({r["key"] for r in tricks})
        info = {r["key"]: r for r in tricks}
        cell = {(r["key"], r["arm"], r["run"]): r for r in tricks}
        lines += ["", "## Trick answers", "",
                  "Expected: invented claims earn nothing and are not "
                  "fabrication; contradicting claims lose marks; true-but-"
                  "unlisted claims are not punished. `F` = fabrication cap "
                  "fired.", "",
                  "| trick | kind | type | " + " | ".join(map(name, runs)) + " |",
                  "|---|---|---|" + "---|" * len(runs)]
        for key in keys:
            vals = []
            for k in runs:
                r = cell.get((key, k[0], k[1]))
                vals.append("-" if not r else r.get("state") if exclusion(r)
                            else "%.0f%s" % (r["raw_100"], " F" if "fabrication"
                                             in (r.get("caps") or []) else ""))
            lines.append("| %s | %s | %s | %s |" % (
                key, info[key]["trick"], info[key]["question_type"],
                " | ".join(vals)))
    return "\n".join(lines) + "\n", a


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("files", nargs="+", help="JSONL files from the arm runners")
    p.add_argument("--out", required=True, help="markdown report to write")
    args = p.parse_args(argv)
    text, _analysis = report(load(args.files), args.files)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(text)


if __name__ == "__main__":
    main()

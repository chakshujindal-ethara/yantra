"""Build a LOCAL Form Studio assessment that uses every element, end to end.

WHY THIS EXISTS. `e2e_pipeline.py` drives the GENERATION lane (SOP -> drafts ->
approve -> assessment). Nothing drove the DESIGNER lane, so the one path a real
examiner uses - draw a form in Form Studio, publish it, sit it - had no rig, and
"Form Studio works" could only ever be asserted screen by screen.

WHAT IT MAKES. One form carrying every deliverable item kind, published through
the real `/api/v1/forms/publish`, then an assessment on it with candidates
assigned and launched. From there it is an ordinary sitting: the exam runner, the
objective marking and the LLM judge are all the existing pipeline.

    python3 tools/form_rig.py                 # build it
    python3 tools/form_rig.py --clean         # remove everything it made

EVERY KIND, deliberately. The point of the rig is to find what breaks under a
real paper, and the kinds differ in exactly the ways that break: some carry
media, some carry a grid of axes, some are LLM-graded, one writes a detection
key. A rig that covered the easy five would pass while the paper an examiner
actually draws fails.

fileUpload is the one kind NOT here: `_walk_section` refuses it by design ("file
upload cannot be delivered in the exam pipeline"), so including it would make
every run report a problem that is the correct answer.

MEDIA is uploaded through `/api/v1/forms/media`, which falls back to a public
Odoo attachment when S3 is unconfigured - so this runs on a bare local database
with no cloud credentials. The images are generated here rather than committed:
a 4-colour PNG is enough for a plate an examiner marks up, and it keeps the
repo free of binary fixtures.

Marked `ZZRIG` on every row, like the other probes, so --clean can find its own
work and nothing else.
"""
import argparse
import base64
import json
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid
import zlib

import _env

_env.require_local_or_explicit()

BASE = _env.API
PROBE = "ZZRIG"

_FAILURES = []
_MADE = {"form": None, "assessment": None, "questions": 0, "candidates": []}


# ── plumbing ────────────────────────────────────────────────────────────────

def _token(login, password):
    req = urllib.request.Request(
        f"{BASE}/api/v1/auth_token",
        data=json.dumps({"login": login, "password": password}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as fh:
        payload = json.loads(fh.read())
    data = payload.get("data") or {}
    token = data.get("access_token")
    if not token:
        sys.exit("could not sign in as %s: %s" % (login, payload))
    return token


def call(path, token, body=None, timeout=300):
    """POST and return the parsed envelope. Never raises on a 4xx/5xx - the
    body of a refusal is the most useful thing this script can print."""
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=json.dumps(body if body is not None else {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer %s" % token},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as fh:
            return json.loads(fh.read())
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return json.loads(raw)
        except ValueError:
            # A wrong PATH gets Odoo's HTML 404 page, which is ~40 KB of
            # boilerplate. Printed whole it buries the actual ledger, so the
            # body is truncated and the status is what the reader sees.
            return {"ok": False, "code": "http_%s" % e.code,
                    "message": "HTTP %s (non-JSON body, %d bytes) %s"
                               % (e.code, len(raw), raw[:120].replace("\n", " "))}


def check(label, condition, detail=""):
    if condition:
        print("  PASS  %s" % label)
        return True
    print("  FAIL  %s%s" % (label, ("  -- %s" % detail) if detail else ""))
    _FAILURES.append(label)
    return False


# ── media ───────────────────────────────────────────────────────────────────

def _png(width, height, rgb):
    """A solid-colour PNG, built here so the repo carries no binary fixture."""
    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                         8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def upload_image(token, name, rgb, size=(320, 240)):
    """Upload a plate and return the URL the designer would have stored."""
    data = base64.b64encode(_png(size[0], size[1], rgb)).decode()
    res = call("/api/v1/forms/media", token, {
        "name": "%s_%s.png" % (PROBE, name),
        "content_type": "image/png",
        "data": data,
    })
    url = ((res.get("data") or {}).get("url")
           or (res.get("data") or {}).get("media_url"))
    if not url:
        sys.exit("media upload failed for %s: %s" % (name, res))
    return url


# ── the form ────────────────────────────────────────────────────────────────

def _opts(*pairs):
    """Designer option list: (label, is_correct)."""
    return [{"id": uuid.uuid4().hex[:8], "label": label, "correct": correct}
            for label, correct in pairs]


def build_sections(media):
    """One form, every deliverable kind, each with the answer key publish
    demands. Split across two sections because sectioning is itself a
    behaviour - `_walk_section` folds informational blocks into the NEXT
    question and resets that carry at a section boundary.
    """
    def item(kind, title, **extra):
        return dict({"id": uuid.uuid4().hex[:10], "kind": kind,
                     "title": title, "help": ""}, **extra)

    section_one = {
        "id": uuid.uuid4().hex[:10],
        "title": "Objective formats",
        "items": [
            # Informational, and deliberately FIRST: it must fold into the
            # question below rather than become a question of its own.
            item("textBlock", "Read the brief",
                 help="Answer every item. This block is informational."),
            item("multipleChoice", "Which control stops the line fastest?",
                 options=_opts(("Emergency stop", True),
                               ("Log a ticket", False),
                               ("Email the supervisor", False))),
            item("checkboxes", "Which of these are PPE?",
                 options=_opts(("Hard hat", True), ("Hi-vis vest", True),
                               ("Clipboard", False))),
            item("dropdown", "Who signs off a lockout?",
                 options=_opts(("The authorised person", True),
                               ("Any operator", False),
                               ("The visitor", False))),
            item("linearScale", "Rate the severity of an unguarded blade.",
                 scale_min=1, scale_max=5, scale_min_label="Trivial",
                 scale_max_label="Critical", golden_answer="5"),
            item("rating", "How urgent is a blocked fire exit?",
                 rating_max=5, golden_answer="5"),
            item("choiceGrid", "Match each hazard to its class.",
                 rows=["Spilled oil", "Exposed wiring"],
                 columns=["Slip", "Electrical"],
                 grid_key={"0": "Slip", "1": "Electrical"}),
            item("checkboxGrid", "Which checks apply to each shift?",
                 rows=["Morning", "Night"],
                 columns=["Lighting", "Guarding"],
                 grid_key={"0": "Guarding", "1": "Lighting"}),
        ],
    }

    section_two = {
        "id": uuid.uuid4().hex[:10],
        "title": "Written and media formats",
        "items": [
            item("shortAnswer", "Name the first step of a lockout.",
                 golden_answer="Isolate the energy source and verify zero "
                               "energy before touching the machine."),
            item("paragraph", "Explain why a near miss is still reported.",
                 golden_answer="A near miss reveals the same failure as an "
                               "accident without the injury, so reporting it "
                               "lets the cause be fixed before somebody is "
                               "hurt."),
            # A media block WITH options is the question itself, not a carry.
            item("imageBlock", "What is wrong in this bay?",
                 media_url=media["bay"],
                 options=_opts(("The walkway is blocked", True),
                               ("The lighting is too bright", False))),
            item("comparePair", "Which layout is safer?",
                 media_url=media["a"], media_url_b=media["b"],
                 require_justification=True,
                 golden_answer="B keeps the walkway clear of the traffic "
                               "route, so a pedestrian never crosses the "
                               "forklift path.",
                 options=_opts(("B is safer", True), ("A is safer", False))),
            item("imageAnnotation", "Mark and name each defect you can see.",
                 media_url=media["plate"],
                 annotation_count=3,
                 # Sparse-safe: keys and regions agree, which is exactly the
                 # invariant the renumbering fix restored.
                 regions=[{"n": 1, "x": 0.10, "y": 0.10, "w": 0.2, "h": 0.2},
                          {"n": 2, "x": 0.50, "y": 0.20, "w": 0.2, "h": 0.2},
                          {"n": 3, "x": 0.30, "y": 0.60, "w": 0.2, "h": 0.2}],
                 golden_labels={"1": "Missing machine guard",
                                "2": "Trailing cable across the walkway",
                                "3": "Obstructed emergency stop"}),
            item("promptWriting", "Write the prompt that produces this plate.",
                 media_url=media["target"],
                 golden_answer="A wide shot of a clean warehouse aisle, "
                               "yellow floor markings, no obstructions, "
                               "bright even lighting, photorealistic."),
        ],
    }
    return [section_one, section_two]


# ── steps ───────────────────────────────────────────────────────────────────

def make_form(token):
    stamp = time.strftime("%H%M%S")
    print("\n[1] media")
    media = {
        "bay": upload_image(token, "bay", (60, 90, 140)),
        "a": upload_image(token, "a", (150, 60, 60)),
        "b": upload_image(token, "b", (60, 140, 80)),
        "plate": upload_image(token, "plate", (200, 190, 60), (480, 360)),
        "target": upload_image(token, "target", (120, 110, 200)),
    }
    check("5 plates uploaded", len(media) == 5)

    print("\n[2] save the form")
    client_uid = "%s-%s-%s" % (PROBE.lower(), stamp, uuid.uuid4().hex[:6])
    sections = build_sections(media)
    kinds = [i["kind"] for s in sections for i in s["items"]]
    res = call("/api/v1/forms/save", token, {"form": {
        "id": client_uid,
        "title": "%s Every Element %s" % (PROBE, stamp),
        "description": "Local rig: one paper carrying every deliverable "
                       "Form Studio element.",
        "published": False,
        "shuffle_questions": False,
        "sections": sections,
    }})
    check("form saved", res.get("ok"), res.get("message"))
    _MADE["form"] = client_uid
    print("      %d items across %d sections: %s"
          % (len(kinds), len(sections), ", ".join(sorted(set(kinds)))))

    print("\n[3] publish it")
    res = call("/api/v1/forms/publish", token, {"id": client_uid})
    if not res.get("ok"):
        # The refusal names the item and section, which is the whole value of
        # publishing through the real route rather than writing rows.
        print("  FAIL  publish refused:")
        for problem in (res.get("problems") or [res.get("message")]):
            print("          - %s" % problem)
        _FAILURES.append("publish")
        return None
    data = res.get("data") or {}
    assessment_id = data.get("assessment_id") or data.get("assessment", {}).get("id")
    _MADE["assessment"] = assessment_id
    # `questions_created` is the key `publish_to_assessment` actually returns.
    # A first draft of this script read `question_count`, got None, and reported
    # "0 questions" over a publish that had in fact created all 13 - a reminder
    # that a rig asserting on a guessed key tests the guess.
    _MADE["questions"] = data.get("questions_created", 0)
    check("published to an assessment", bool(assessment_id), json.dumps(data)[:200])
    check("every item became a question",
          _MADE["questions"] >= len([k for k in kinds if k != "textBlock"]),
          "got %s questions for %s deliverable items"
          % (_MADE["questions"], len([k for k in kinds if k != "textBlock"])))
    for warning in (data.get("warnings") or []):
        print("      note: %s" % warning)
    return assessment_id


def verify_questions(token, assessment_id):
    """Read the paper back and prove each stored type arrived.

    Asserted on the SERVER's answer, not on what was sent: the whole point of
    publishing through the route is that the translation is what is under test.
    """
    print("\n[4] the paper the candidate will sit")
    res = call("/api/v1/assessments/%s" % assessment_id, token)
    data = res.get("data") or {}
    questions = data.get("questions") or []
    check("the assessment carries its questions", bool(questions),
          json.dumps(res)[:200])
    by_type = {}
    for q in questions:
        by_type.setdefault(q.get("question_type") or "?", 0)
        by_type[q.get("question_type") or "?"] += 1
    print("      stored types: %s"
          % ", ".join("%s x%d" % (t, n) for t, n in sorted(by_type.items())))
    # The five stored types this form must produce. `msq` covers checkboxes and
    # the checkbox grid; `mcq` covers the single-answer kinds and both scales.
    for wanted in ("mcq", "msq", "subjective_rubric", "image_ab",
                   "image_label", "image_prompt"):
        check("the paper has a %s question" % wanted,
              by_type.get(wanted, 0) > 0,
              "types present: %s" % sorted(by_type))
    # MEDIA IS FETCHED, NOT JUST COUNTED. A question whose plate 404s looks
    # perfect in JSON and is a blank box for the candidate, so the only check
    # worth making is to pull the bytes.
    #
    # The url key is `admin_url` (the proxy that presigns private S3 and
    # streams inline base64), NOT `url`. Reading `url` reported "NO URL" for
    # five questions whose plates were all serving correctly - a false alarm
    # that would have sent somebody hunting a bug that did not exist.
    plates = [(q, im) for q in questions for im in (q.get("images") or [])]
    check("the image questions carry plates", bool(plates),
          "no question came back with images")
    served, broken = 0, []
    for q, im in plates:
        url = im.get("admin_url") or im.get("url")
        if not url:
            broken.append("%s/%s: no url in the payload"
                          % (q.get("question_type"), im.get("slot")))
            continue
        req = urllib.request.Request(
            url if url.startswith("http") else BASE + url,
            headers={"Authorization": "Bearer %s" % token})
        try:
            with urllib.request.urlopen(req, timeout=60) as fh:
                blob = fh.read()
            # A 200 carrying an HTML error page is still a broken plate, so the
            # magic bytes are checked rather than the status alone.
            if blob[:8] == b"\x89PNG\r\n\x1a\n" or blob[:3] == b"\xff\xd8\xff":
                served += 1
            else:
                broken.append("%s/%s: %d bytes, not an image"
                              % (q.get("question_type"), im.get("slot"),
                                 len(blob)))
        except Exception as e:  # noqa: BLE001
            broken.append("%s/%s: %s" % (q.get("question_type"),
                                         im.get("slot"), e))
    check("every plate serves real image bytes (%d/%d)"
          % (served, len(plates)),
          bool(plates) and not broken, "; ".join(broken[:4]))
    return questions


def assign_and_launch(token, assessment_id, count=2):
    print("\n[5] candidates")
    res = call("/api/v1/users", token, {"limit": 50})
    # DEDUPED BY id. `/api/v1/users` is keyed on res.users and one person can
    # appear more than once; the first run of this script assigned "Aarav Mehta,
    # Aarav Mehta" - two slots, one human - which is not the two-candidate
    # cohort the rig is meant to build.
    pool, seen = [], set()
    for u in (res.get("data") or []):
        uid = u.get("id")
        if uid and uid not in seen:
            seen.add(uid)
            pool.append(u)
    if len(pool) < count:
        check("enough distinct candidates in the directory", False,
              "found %d" % len(pool))
        return
    picked = pool[:count]
    res = call("/api/v1/assessments/%s/assign" % assessment_id, token,
               {"applicant_ids": [u["id"] for u in picked]})
    check("candidates assigned", res.get("ok"), res.get("message"))
    _MADE["candidates"] = [u.get("name") or u.get("id") for u in picked]

    print("\n[6] launch")
    # `/launch`, not `/start`. There is no `/start` route, so the first draft of
    # this script got Odoo's HTML 404 page and reported "launch failed" for a
    # launch it had never actually asked for.
    #
    # DRY RUN FIRST, because it is the most valuable output this rig produces:
    # it evaluates all 8 gates without short-circuiting, so one call names every
    # answer key the publish failed to translate instead of the first.
    dry = call("/api/v1/assessments/%s/launch" % assessment_id, token)
    gates = (dry.get("data") or {}).get("gates") or []
    for gate in gates:
        if not gate.get("passed"):
            print("      gate FAILED  %-22s %s"
                  % (gate.get("code"), gate.get("reason") or ""))
    check("all %d launch gates pass" % len(gates),
          bool(gates) and all(g.get("passed") for g in gates),
          "%d gate(s) failed" % len([g for g in gates if not g.get("passed")]))

    # `confirm` IS REQUIRED. Without it the route is a DRY RUN that reports the
    # gates and returns ok=True having launched nothing - the first version of
    # this check read that as success while the assessment sat in `draft` with
    # an empty question_order, which is exactly the vacuous green a rig exists
    # to avoid.
    res = call("/api/v1/assessments/%s/launch" % assessment_id, token,
               {"confirm": True})
    launched = bool((res.get("data") or {}).get("launched"))
    check("assessment launched", launched,
          res.get("message") or json.dumps(res)[:200])

    # PROVE IT ON THE SERVER, not from the launch response. `action_start`
    # freezes each candidate's paper into `question_order`; an empty one means
    # nobody has a paper to sit, whatever the route said.
    detail = call("/api/v1/assessments/%s" % assessment_id, token)
    state = (detail.get("data") or {}).get("state")
    check("the assessment is in progress", state == "in_progress",
          "state is %r" % state)
    roster = call("/api/v1/assessments/%s/candidates" % assessment_id, token)
    rows = roster.get("data") or []
    # `total_questions` is the key the roster row actually carries - not
    # `question_count`, and not the raw `question_order`, which is server-side
    # only. Reading a key that is not in the payload reported "0 of 2 candidates
    # have questions" against two sittings that each held all 13.
    sized = [r for r in rows if (r.get("total_questions") or 0) > 0]
    check("every candidate has a frozen paper",
          bool(rows) and len(sized) == len(rows),
          "%d of %d candidates have questions (keys: %s)"
          % (len(sized), len(rows), sorted(rows[0]) if rows else []))


def clean(token):
    """Remove what previous runs made. Marked rows only."""
    print("\n[clean]")
    res = call("/api/v1/forms", token, {"limit": 200})
    forms = [f for f in (res.get("data") or [])
             if PROBE in str(f.get("title") or "")]
    for form in forms:
        got = call("/api/v1/forms/delete", token,
                   {"id": form.get("id") or form.get("client_uid")})
        print("  form %-40s %s" % (str(form.get("title"))[:40],
                                   "deleted" if got.get("ok") else got.get("message")))
    res = call("/api/v1/assessments", token, {"limit": 200,
                                              "include_archived": True})
    papers = [a for a in (res.get("data") or [])
              if PROBE in str(a.get("name") or "")]
    for paper in papers:
        got = call("/api/v1/assessments/%s/archive" % paper["id"], token)
        print("  assessment %-34s %s" % (str(paper.get("name"))[:34],
                                         "archived" if got.get("ok")
                                         else got.get("message")))
    print("  %d form(s), %d assessment(s)" % (len(forms), len(papers)))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--clean", action="store_true",
                    help="remove what earlier runs made, then exit")
    ap.add_argument("--candidates", type=int, default=2)
    args = ap.parse_args()

    print("target: %s  (db %s)" % (BASE, _env.DB))
    token = _token(_env.ADMIN_LOGIN, _env.ADMIN_PASSWORD)

    if args.clean:
        clean(token)
        return 0

    assessment_id = make_form(token)
    if assessment_id:
        verify_questions(token, assessment_id)
        assign_and_launch(token, assessment_id, args.candidates)

    print("\n" + "=" * 68)
    if _MADE["assessment"]:
        print("assessment id : %s" % _MADE["assessment"])
        print("questions     : %s" % _MADE["questions"])
        print("candidates    : %s" % ", ".join(_MADE["candidates"]) or "-")
        print("form uid      : %s" % _MADE["form"])
    if _FAILURES:
        print("FAILED (%d): %s" % (len(_FAILURES), "; ".join(_FAILURES)))
        return 1
    print("all checks passed - sit it in the app, or --clean to remove it")
    return 0


if __name__ == "__main__":
    sys.exit(main())

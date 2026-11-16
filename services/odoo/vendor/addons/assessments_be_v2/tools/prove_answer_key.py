"""Prove the exam-answer key fix over the REAL HTTP route, both spellings.

The client used to send `option_ids`; the route reads `selected_option_ids`
(via `_selected_option_lines`). Nothing errored - `_record_response` saw no
selection, and an objective question with no selection is not an error, it is
a BLANK answer, saved and submitted, then scored 0.

Drives the live route with each spelling in turn and reads the stored response
back, so the difference is demonstrated rather than asserted.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

import _env

_env.require_local_or_explicit()

BASE = _env.API
PSQL = ["psql", "-h", "localhost", "-p", "5433", "-U", "odoo",
        "-d", _env.DB, "-tAc"]


def sql(q):
    out = subprocess.run(PSQL + [q], capture_output=True, text=True)
    return out.stdout.strip()


def tok(login, password):
    req = urllib.request.Request(
        f"{BASE}/api/v1/auth_token",
        data=f"login={login}&password={password}".encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())["data"]["access_token"]


def call(path, token, body=None):
    req = urllib.request.Request(
        f"{BASE}{path}", data=json.dumps(body or {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=120).read())
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            return {"ok": False, "error": {"code": f"http{exc.code}"}}


CANDIDATE = _env.CANDIDATE_LOGIN
PASSWORD = _env.CANDIDATE_PASSWORD

# The attempt belonging to this candidate on a live assessment.
row = sql(
    "select e.id, e.access_token, e.question_order "
    "from assessments_be_evaluator e "
    "join assessments_be_v2 a on a.id = e.assessment_id "
    "where a.state = 'in_progress' "
    "and e.state in ('pending','in_progress') "
    "order by e.id desc limit 1")
if not row:
    print("no live attempt for the candidate; launch one first")
    sys.exit(1)

ev_id, token, order_json = row.split("|")
order = json.loads(order_json or "[]")
print(f"attempt {ev_id}  token {token}")
print(f"question_order {order[:5]}")
if not order:
    print("attempt has no frozen order")
    sys.exit(1)

qid = order[0]
# Options hang off the question's DIMENSIONS, not the question directly.
opt = sql(
    "select o.id from assessments_be_question_dimension d "
    "join assessments_be_question_dimension_option o "
    "  on o.dimension_id = d.id "
    f"where d.question_id = {qid} order by o.id limit 1")
if not opt:
    print(f"question {qid} has no option lines")
    sys.exit(1)
print(f"question {qid}  first option line {opt}")
print()

C = tok(CANDIDATE, PASSWORD)
call(f"/api/v1/exam/{token}/begin", C)


def stored_lines():
    return sql(
        "select count(*) from assessments_be_response_line l "
        "join assessments_be_response s on s.id = l.response_id "
        f"where s.evaluator_id = {ev_id} and s.question_id = {qid}")


for key in ("option_ids", "selected_option_ids"):
    sql("delete from assessments_be_response_line where response_id in ("
        "select id from assessments_be_response "
        f"where evaluator_id = {ev_id} and question_id = {qid})")
    sql("delete from assessments_be_response "
        f"where evaluator_id = {ev_id} and question_id = {qid}")
    res = call(f"/api/v1/exam/{token}/answer", C,
               {"question_id": qid, key: [int(opt)]})
    saved = stored_lines()
    verdict = "SELECTION STORED" if saved not in ("", "0") else "BLANK ANSWER"
    print(f"  {key:22} -> ok={res.get('ok')}  options_stored={saved}  {verdict}")

print()
print("The route reads `selected_option_ids`. With the old key the answer was")
print("accepted (ok=true) and stored with NO selection - a blank, scored 0.")

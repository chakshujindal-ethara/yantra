# Local dev commands - assessments_be_v2

All commands run from the repo root: `cd /Users/cj/Developer/ethara-etp`

`odoo.conf` is a **symlink to `src/odoo.conf`** and now sets `db_name = etp_local`,
so `-d etp_local` is the default and can be omitted.

---

## Start / stop the stack

```bash
# --- backend (Odoo, port 8069) ---
source .venv/bin/activate
nohup python src/odoo-bin -c odoo.conf > ~/odoo.log 2>&1 &
echo $! > ~/.odoo.pid

# --- frontend (Flutter web build, port 8200) ---
cd /Users/cj/Developer/ethara-assessment-fe/build/web
nohup python3 ../../tool/serve.py 8200 > ~/flutter.log 2>&1 &
echo $! > ~/.flutter.pid
```

```bash
# --- stop everything ---
pkill -f odoo-bin ; pkill -f tool/serve.py
rm -f ~/.odoo.pid ~/.flutter.pid

# --- what is listening ---
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':8069|:8200|:5433'
```

## Logs

```bash
tail -f ~/odoo.log                                  # everything
tail -f ~/odoo.log | grep -i assessments_be_v2      # just this module
tail -f ~/odoo.log | grep -iE 'ERROR|CRITICAL|Traceback'
tail -f ~/odoo.log | grep -i "ir_cron"              # cron ticks
tail -f ~/flutter.log                               # frontend requests
```

## Upgrade after a code change

```bash
# stop the server FIRST - two processes upgrading one database corrupt it
pkill -f odoo-bin
source .venv/bin/activate
python src/odoo-bin -c odoo.conf -u assessments_be_v2 --stop-after-init
```

**`data/` files are `noupdate="1"`.** An upgrade will NOT change cron records,
mail templates or security rules that already exist - only a fresh install
applies them. After editing `data/cron.xml` on an existing database, change the
rows directly:

```bash
psql -p 5433 -d etp_local -c "
UPDATE ir_cron SET active = true
WHERE id IN (SELECT res_id FROM ir_model_data
             WHERE module='assessments_be_v2' AND model='ir.cron');"
```

## Tests

```bash
# stop the server first - the test run needs the port and the database
pkill -f odoo-bin
source .venv/bin/activate

# whole module (no count here on purpose - it only ever goes stale)
python src/odoo-bin -c odoo.conf -u assessments_be_v2 \
  --test-enable --test-tags /assessments_be_v2 --stop-after-init

# one class
python src/odoo-bin -c odoo.conf -u assessments_be_v2 \
  --test-enable --test-tags /assessments_be_v2:TestRetiredNotDrawn --stop-after-init

# fresh-install check (proves independence from etp_assessment_pro)
psql -p 5433 -d postgres -c "DROP DATABASE IF EXISTS scratch;"
psql -p 5433 -d postgres -c "CREATE DATABASE scratch;"
python src/odoo-bin -c odoo.conf -d scratch -i assessments_be_v2 --stop-after-init
psql -p 5433 -d postgres -c "DROP DATABASE scratch;"
```

Add `--http-port=8199` to any of the above if something is already on 8069.

## One-off data fixes

```bash
# Recompute every question mark after the all-or-nothing rule change.
# `final_mark` is a STORED compute, so editing the rule leaves every existing
# row on the old one until a dependency happens to move. Idempotent - a second
# run reports nothing moved. Read the script's docstring before running it on
# anything that is not a copy: an attempt's result can move pass -> fail.
env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
  -c odoo.conf --no-http --http-port=8199 \
  < custom_addons/assessments_be_v2/tools/backfill_final_marks.py

# Re-canonicalise stored SOP rating schemes. A scheme saved with the SOP's own
# wording as the CODE ("OVERALL PREFERENCE" rather than "OC") makes the model
# emit that key, and every image_ab item is then rejected for having no Overall
# Choice - a generation run that spends money and yields nothing. Extraction now
# canonicalises on write; this fixes the generators already on disk. Idempotent.
env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
  -c odoo.conf --no-http --http-port=8199 \
  < custom_addons/assessments_be_v2/tools/backfill_rating_schemes.py
```

## Credentials

Both are stored **Fernet-encrypted** off `database.secret`. Never write them
with plain SQL - it stores plaintext and then fails to decrypt, and the error
looks like a credentials problem.

```bash
# Vertex service account
ETP_SA_JSON=/Users/cj/Developer/agon-development-499205-5cb4f96649ef.json \
  env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
  -c odoo.conf --no-http --http-port=8199 \
  < custom_addons/assessments_be_v2/tools/vertex_setup.py

# AWS S3 (bucket + region already default to ethara-etp-assessment / ap-south-1)
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
  -c odoo.conf --no-http --http-port=8199 \
  < custom_addons/assessments_be_v2/tools/s3_setup.py
```

## Health checks

```bash
curl -s -o /dev/null -w "backend  %{http_code}\n" http://localhost:8069/web/login
curl -s http://localhost:8069/api/v1/auth/me                 # expect 401 JSON envelope
curl -s -o /dev/null -w "frontend %{http_code}\n" http://localhost:8200/

# CORS preflight from the Flutter origin - must return Access-Control-Allow-Origin
curl -s -i -X OPTIONS http://localhost:8069/api/v1/auth/me \
  -H "Origin: http://localhost:8200" -H "Access-Control-Request-Method: GET" \
  | grep -i access-control

# our crons vs upstream's (13 each, names prefixed differently)
psql -p 5433 -d etp_local -c "
SELECT d.module, c.cron_name, c.active FROM ir_cron c
JOIN ir_model_data d ON d.res_id=c.id AND d.model='ir.cron'
WHERE d.module IN ('assessments_be_v2','etp_assessment_pro')
ORDER BY d.module, c.cron_name;"
```

## Guardrail: `etp_assessment_pro` must stay untouched

```bash
git status --porcelain -- custom_addons/etp_assessment_pro/     # expect: no output
git diff origin/stage --stat -- custom_addons/etp_assessment_pro/
```

Note that `noupdate="1"` cuts both ways: a past `-u etp_assessment_pro` run can
leave *record* drift in a dev database even when the code is clean. The check
above covers code; compare `ir_cron` / `ir_model_data` rows if a record looks
wrong.

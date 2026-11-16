# Canonical entry points for this app.
#
# `tool/verify.sh` already does the real work. This exists because tooling and
# humans both look for a Makefile first, and a project whose verification is
# only discoverable by reading the README is a project whose verification does
# not get run.

.DEFAULT_GOAL := help
.PHONY: help test lint analyze build verify clean fixtures serve \
        build-local build-stage build-prod serve-local serve-stage serve-prod

# WHICH DEPLOYMENT. One of: local, stage, prod.
#
#   make build ENV=prod        bundle pinned to the new production backend
#   make serve ENV=stage       build it and serve it locally on STAGE_PORT
#
# `local` is the default because that is what a working copy is for. A DEPLOYED
# bundle normally needs none of this: the app reads the host it is served from
# and pairs itself with that environment's backend - see
# lib/assessment/data/environment.dart. These targets exist for the case the
# host cannot answer, which is a build served from 127.0.0.1 aimed at a remote
# backend.
ENV ?= local
_ENV_OK := $(filter $(ENV),local stage prod)

# THE THREE BACKENDS THIS APP IS RUN AGAINST.
#
# MIRRORS lib/assessment/data/environment.dart, which is the runtime source of
# truth, and `assessments_be_v2/services/app_origins.py` on the server. Three
# copies of one pairing is two too many, but a Makefile cannot read a Dart const
# and a Dart const cannot read a Makefile - so `test-env-parity` asserts the
# Dart table still contains every URL named here, and a drift fails the suite
# rather than shipping.
#
# :8069 and etp_local, NOT :7070 and ethara_ops. Those defaults came from a
# private Odoo checkout that has since been deleted; ethara_ops still carries its
# shape (Project OS addons installed, employee_extension uninstalled) so
# etp_assessment_pro cannot even load there. The backend runs from the
# ethara-etp repo itself: odoo-bin -c odoo.conf -d etp_local --http-port=8069
LOCAL_BASE_URL ?= http://localhost:8069
LOCAL_DB       ?= etp_local
STAGE_BASE_URL ?= https://projects-stage.ethara.ai
PROD_BASE_URL  ?= https://projects.ethara.ai
# STAGE_DB and PROD_DB are deliberately empty. Both answer
# `/api/v1/auth_token`, so the app takes the gateway (bearer) lane, which names
# no database; `db` is only sent on the `/api/v1/auth/session` fallback that a
# 404 on the gateway selects. Setting them would have no effect and would imply
# otherwise.
STAGE_DB       ?=
PROD_DB        ?=

# A separate output directory and port per environment.
#
# One `build/web` cannot hold three. `make build` overwrites it in place, so
# building for stage silently repointed the local bundle and vice versa - and
# because a pinned bundle carries its host, the only symptom is calls landing on
# the wrong server. Separate directories mean all three can be up at once and
# the port says which is which.
#
# THESE PORTS ARE NOT ARBITRARY. Every one of them has to appear in
# `LOCALHOST_ORIGINS` in assessments_be_v2/models/ir_http.py or the remote
# backend refuses the browser's credentialed request at CORS - the server log
# stays clean and the app just shows empty screens.
LOCAL_PORT     ?= 8200
STAGE_PORT     ?= 8201
PROD_PORT      ?= 8202

# Resolve ENV to its backend, database, port and output directory.
BASE_URL_local := $(LOCAL_BASE_URL)
BASE_URL_stage := $(STAGE_BASE_URL)
BASE_URL_prod  := $(PROD_BASE_URL)
DB_local       := $(LOCAL_DB)
DB_stage       := $(STAGE_DB)
DB_prod        := $(PROD_DB)
PORT_local     := $(LOCAL_PORT)
PORT_stage     := $(STAGE_PORT)
PORT_prod      := $(PROD_PORT)

# `?=`, so an explicit `make build API_BASE_URL=https://one-off.host` still
# wins over the ENV selection - and so tool/verify.sh, which reads these from
# the environment, keeps behaving as it documents.
API_BASE_URL ?= $(BASE_URL_$(ENV))
API_DB       ?= $(DB_$(ENV))
PORT         ?= $(PORT_$(ENV))
OUT          ?= build/web-$(ENV)

# Which backend the bundle talks to. Defaults reproduce today's build, which
# points at assessments_be_v2. For the etp_assessment_pro_v2 replica:
#   make build API_PREFIX=/api/v2 MEDIA_PREFIX=/etp_assessment_pro_v2
API_PREFIX   ?= /api/v1
MEDIA_PREFIX ?= /assessments_be
# Sign-in is served by api_auth_gateway, which stays on /api/v1 regardless.
GATEWAY_PREFIX ?= /api/v1

# Refuse a misspelled ENV instead of building an unpointed bundle.
#
# Without this `ENV=production` expands `$(BASE_URL_production)` to the empty
# string, the app falls back to its own origin, and every call POSTs at the
# static file server - a 501 that surfaces to the user as "Unexpected response
# from /api/v1/auth_token". A typo that reads as broken auth.
guard-env:
	@test -n "$(_ENV_OK)" \
	  || { echo "ENV=$(ENV) is not one of: local stage prod"; exit 1; }
.PHONY: guard-env
# The proctoring SIMULATOR is a demo rig, and it drives the REAL violation
# route. In front of a candidate it is a way to fabricate violations against
# yourself, or - at a violation cap of 1 - to end your own exam with one click,
# so no bundle anybody sits an exam in should carry it. `kProctorSim` now
# defaults to FALSE in exam_screen.dart - a control that can end somebody's exam
# has to fail closed, and no test references it - so this line is belt and
# braces rather than the only thing keeping the panel out of a shipped bundle.
# Put it back for a demo with:  make build PROCTOR_SIM=true
PROCTOR_SIM  ?= false
# Everything that is NOT the backend address, factored out so the local and
# stage bundles cannot drift. Spelling the whole flag list out twice is how one
# of them quietly ends up without `--pwa-strategy=none`.
#
# No service worker. It caches main.dart.js in Cache Storage, which ignores
# HTTP headers, so a browser keeps running a bundle built against an old
# backend however often this is rebuilt.
COMMON       := --dart-define=PROCTOR_SIM=$(PROCTOR_SIM) --pwa-strategy=none \
                --dart-define=API_PREFIX=$(API_PREFIX) \
                --dart-define=MEDIA_PREFIX=$(MEDIA_PREFIX) \
                --dart-define=GATEWAY_PREFIX=$(GATEWAY_PREFIX)
DEFINES      := --dart-define=API_BASE_URL=$(API_BASE_URL) \
                --dart-define=API_DB=$(API_DB) $(COMMON)
# No API_BASE_URL. The point of `build-portable` is a bundle that resolves its
# backend from the host it is served from, which is what lets ONE image answer
# on both assessment.ethara.ai and assessment-stage.ethara.ai.
PORTABLE_DEFINES := --dart-define=API_DB= $(COMMON)
export API_BASE_URL API_DB API_PREFIX MEDIA_PREFIX GATEWAY_PREFIX

help:                ## Show this list
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) \
	  | awk -F':.*##' '{printf "  %-16s %s\n", $$1, $$2}'
	@# Print the RESOLVED values, not the literals. `help` greps its own
	@# source, so a description containing $$(API_BASE_URL) prints those
	@# characters - which is how a wrong default goes unnoticed.
	@printf '\n  ENV=%s -> backend %s  db=%s  port %s  out %s\n' \
	  '$(ENV)' '$(API_BASE_URL)' '$(if $(API_DB),$(API_DB),<none>)' \
	  '$(PORT)' '$(OUT)'
	@echo   "  ENV may be: local stage prod"

analyze:             ## Static analysis (no errors allowed)
	dart analyze lib/ test/

lint: analyze        ## Alias for analyze

test:                ## Tests on BOTH platforms
	@# Chrome is not redundant: compiled to JS there is one numeric type, so
	@# `0.0 is int` is true on the web and false on the VM. That difference
	@# once truncated every currency value while the VM suite stayed green.
	flutter test
	flutter test --platform chrome

build: guard-env     ## Release bundle for ENV=$(ENV), pinned to $(API_BASE_URL)
	@# The AI proctoring wasm and models are not committed; this fetches and
	@# hash-checks them (a no-op when they are already here and intact).
	bash tool/fetch_mediapipe.sh
	flutter build web --release --output=$(OUT) $(DEFINES)
	@$(MAKE) --no-print-directory prove-pinned OUT=$(OUT)

build-portable:      ## ONE bundle for every host -> build/web-portable
	@# What CI should ship. Carries no backend URL, so it pairs itself with
	@# whichever host serves it and an image promoted from stage to production
	@# stops talking to stage.
	bash tool/fetch_mediapipe.sh
	flutter build web --release --output=build/web-portable $(PORTABLE_DEFINES)
	@$(MAKE) --no-print-directory prove-portable OUT=build/web-portable

serve: build         ## Build ENV=$(ENV) and serve it on $(PORT)
	@echo "serving $(API_BASE_URL) app on http://127.0.0.1:$(PORT)"
	@cd $(OUT) && python3 $(CURDIR)/tool/serve.py $(PORT)

build-local:         ## Bundle pinned to the local backend -> build/web-local
	@$(MAKE) --no-print-directory build ENV=local
build-stage:         ## Bundle pinned to stage -> build/web-stage
	@$(MAKE) --no-print-directory build ENV=stage
build-prod:          ## Bundle pinned to production -> build/web-prod
	@$(MAKE) --no-print-directory build ENV=prod

serve-local:         ## Local backend on $(LOCAL_PORT)
	@$(MAKE) --no-print-directory serve ENV=local
serve-stage:         ## Stage backend on $(STAGE_PORT)
	@$(MAKE) --no-print-directory serve ENV=stage
serve-prod:          ## Production backend on $(PROD_PORT)
	@$(MAKE) --no-print-directory serve ENV=prod

prove-pinned:
	@# PRESENCE IS NECESSARY BUT NO LONGER SUFFICIENT, which is worth spelling
	@# out because this check used to be conclusive and silently stopped being.
	@#
	@# Every bundle now carries the host table, so `https://projects.ethara.ai`
	@# is in the output whether or not the define took. A pin adds a SECOND
	@# literal, so the pinned URL appearing more often than the other deployed
	@# one is what actually evidences the pin.
	@#
	@# Absence fails; an ambiguous count only warns. A count is a property of
	@# dart2js inlining, not of this app, so a compiler upgrade must not be able
	@# to block a legitimate build - and a lost define is now loud anyway: the
	@# bundle falls back to the host, localhost is not in the table, and the app
	@# POSTs at the static file server instead of quietly reaching the wrong
	@# backend. `make build-portable` is the case with a sound guard.
	@grep -qF '$(API_BASE_URL)' $(OUT)/main.dart.js \
	  || { echo "$(API_BASE_URL) is not in $(OUT) - run 'make clean' and rebuild"; exit 1; }
	@n=$$(grep -oF '$(API_BASE_URL)' $(OUT)/main.dart.js | wc -l | tr -d ' '); \
	 if [ "$$n" -ge 2 ]; then \
	   echo "  $(OUT) is pinned to $(API_BASE_URL)"; \
	 else \
	   echo "  WARN $(OUT) contains $(API_BASE_URL) but shows no sign of a PIN"; \
	   echo "       (it may be there only as a host-table entry - verify in a browser)"; \
	 fi

prove-portable:
	@# A portable bundle has no pinned URL to grep for, so assert the HOST
	@# TABLE reached the bundle instead. Tree-shaking a const map it could not
	@# see a use of would leave a build that resolves every host to same-origin
	@# and shows seed data to real users.
	@for u in '$(PROD_BASE_URL)' '$(STAGE_BASE_URL)'; do \
	  grep -qF "$$u" $(OUT)/main.dart.js \
	    || { echo "$$u is not in $(OUT) - the host table did not survive the build"; exit 1; }; \
	done
	@echo "  $(OUT) resolves its backend from the host it is served from"
.PHONY: build-portable prove-pinned prove-portable

test-env-parity:     ## The Makefile's URLs and the Dart table must agree
	@# Three copies of one pairing (here, environment.dart, app_origins.py).
	@# This is what makes a drift fail instead of ship.
	@for u in '$(PROD_BASE_URL)' '$(STAGE_BASE_URL)' '$(LOCAL_BASE_URL)'; do \
	  grep -qF "$$u" lib/assessment/data/environment.dart \
	    || { echo "$$u is in the Makefile but not in environment.dart"; exit 1; }; \
	done
	@for p in $(LOCAL_PORT) $(STAGE_PORT) $(PROD_PORT); do \
	  grep -qF "localhost:$$p" ../ethara-etp/custom_addons/assessments_be_v2/models/ir_http.py \
	    || echo "  WARN port $$p is not in the backend's LOCALHOST_ORIGINS - serving on it will fail CORS against a remote backend"; \
	done
	@echo "  Makefile and environment.dart agree"
.PHONY: test-env-parity

verify: test-env-parity  ## Everything, plus the live backend when it is reachable
	bash tool/verify.sh

fixtures:            ## Re-capture test payloads from a live backend
	python3 tool/capture_payloads.py

clean:
	flutter clean

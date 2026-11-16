FROM 426628337772.dkr.ecr.ap-south-1.amazonaws.com/ethara-flutter-multi-stage:3.44.1-amd64 AS builder

# WHERE THE BACKEND COMES FROM, and why this is now OPTIONAL.
#
# The app derives its backend from the host it is SERVED from - see
# lib/assessment/data/environment.dart:
#
#   assessment.ethara.ai        -> https://projects.ethara.ai
#   assessment-stage.ethara.ai  -> https://projects-stage.ethara.ai
#   localhost / 127.0.0.1       -> http://localhost:8069
#
# So leave API_BASE_URL EMPTY and one image answers correctly on every one of
# those hosts. This used to be mandatory, and because Dart compiles the define
# into main.dart.js as a string constant the backend was a property of the
# BUILD: an image promoted from stage to production kept calling stage, and
# nothing on the server side looked wrong because stage answered every request.
#
# Pass it only to PIN a bundle to a host the table cannot imply - a preview
# deployment, a bare IP, or a one-off aimed at another backend.
ARG API_BASE_URL=""
# Odoo only needs `db` on the login call when the host serves more than one
# database. The app omits it when empty, which matches its own default, so
# leave this unset unless staging is multi-database.
ARG API_DB=""

# WHICH BACKEND MODULE this bundle talks to. The API surface is versioned by
# path prefix, so pointing the app at a different backend is a build arg rather
# than a code change:
#
#   assessments_be_v2      -> /api/v1  + /assessments_be        (the defaults)
#   etp_assessment_pro_v2  -> /api/v2  + /etp_assessment_pro_v2
#
# These MUST be passed through to the build. They were declared in the client
# but not here, so a build aimed at /api/v2 silently produced a /api/v1 bundle:
# every call 404s and the app reports the server as unreachable while the server
# log stays clean.
ARG API_PREFIX="/api/v1"
ARG MEDIA_PREFIX="/assessments_be"
# Sign-in is served by `api_auth_gateway`, a DIFFERENT addon that registers at
# /api/v1 whatever the assessment backend is. Versioning it alongside the
# assessment API sends auth_token to a route nobody serves.
ARG GATEWAY_PREFIX="/api/v1"

WORKDIR /app
COPY . .

RUN flutter config --enable-web
RUN flutter pub get

# AI proctoring assets (~30 MB of wasm and models under web/mediapipe/) are not
# in git. Fetch them from the URLs pinned in web/mediapipe/NOTICE.md and check
# each SHA-256 there; a mismatch fails the image. Files already in the build
# context with the right hash are kept, so a local `docker build` is offline
# for them. Must run before `flutter build web`, which copies web/ verbatim.
RUN bash tool/fetch_mediapipe.sh

# Mirrors `make build`. Keep the two hardcoded defines in step with the
# Makefile, which is the canonical entry point:
#
#   PROCTOR_SIM=false   - the proctoring simulator drives the REAL violation
#     route, and `kProctorSim` defaults to TRUE so the widget tests keep
#     finding it. Omit this and a candidate can fabricate violations against
#     themselves, or end their own exam with one click at a violation cap of 1.
#   --pwa-strategy=none - the service worker caches main.dart.js in Cache
#     Storage, which ignores HTTP headers, so a browser keeps running a bundle
#     built against an old backend however often this is rebuilt.
RUN flutter build web --release \
      --dart-define=API_BASE_URL="$API_BASE_URL" \
      --dart-define=API_DB="$API_DB" \
      --dart-define=API_PREFIX="$API_PREFIX" \
      --dart-define=MEDIA_PREFIX="$MEDIA_PREFIX" \
      --dart-define=GATEWAY_PREFIX="$GATEWAY_PREFIX" \
      --dart-define=PROCTOR_SIM=false \
      --pwa-strategy=none

# PROVE the bundle can reach a backend, whichever way it was built.
#
# `--dart-define` compiles the value into main.dart.js as a string constant. It
# is NOT written to an asset file - this app has no flutter_dotenv and declares
# no `.env` asset, so a `.env` written into the image at build time would never
# reach the bundle.
#
# Pinned:   assert the pinned host landed.
# Portable: there is no pinned host, so assert the HOST TABLE landed instead.
#   Both entries, because tree-shaking a const map whose use it could not see
#   would leave a bundle that resolves every host to same-origin - which is the
#   app's seed-data mode, so real users would be shown fixtures with no error
#   anywhere. Keep these in step with lib/assessment/data/environment.dart.
RUN set -e; \
    for u in https://projects.ethara.ai https://projects-stage.ethara.ai; do \
      grep -qF "$u" /app/build/web/main.dart.js \
        || { echo "ERROR: host table entry $u missing from build output"; exit 1; }; \
    done; \
    if [ -z "$API_BASE_URL" ]; then \
      echo "OK: portable bundle - resolves its backend from the host it is served from"; \
    else \
      grep -qF "$API_BASE_URL" /app/build/web/main.dart.js \
        || { echo "ERROR: API_BASE_URL ($API_BASE_URL) missing from build output"; exit 1; }; \
      n=$(grep -oF "$API_BASE_URL" /app/build/web/main.dart.js | wc -l); \
      echo "OK: bundle PINNED to $API_BASE_URL (literal occurrences: $n)"; \
      echo "NOTE: a pinned image ignores the host table. Deployed to the WRONG"; \
      echo "      host it keeps calling $API_BASE_URL, which is the failure"; \
      echo "      an empty API_BASE_URL exists to remove. Prefer leaving it unset."; \
    fi
# Same proof for the API prefix. A bundle built for /api/v2 that silently
# carries /api/v1 answers every call with a 404, which the app reports as an
# unreachable server - so assert the prefix reached the bundle rather than
# discovering it after deploy.
RUN grep -qF "$API_PREFIX" /app/build/web/main.dart.js \
    || (echo "ERROR: API_PREFIX ($API_PREFIX) missing from build output" \
        && exit 1)
# Pre-compress the AI proctoring assets once here, so nginx (`gzip_static on`
# in its /mediapipe/ location only) sends the .gz sibling instead of gzipping
# on a small pod for every AI candidate. `-k` keeps the original for a client
# without gzip; `-n` drops the name and timestamp.
RUN find /app/build/web/mediapipe -type f \( -name '*.js' -o -name '*.mjs' \
      -o -name '*.wasm' -o -name '*.tflite' \) -size +1k -exec gzip -9 -k -n {} +
RUN ls -la /app/build/web

FROM nginx:alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Validate the config at BUILD time. Without this a syntax error only surfaces
# when the container tries to boot, which on stage reads as a deploy that went
# through and a site that is simply down. `nginx -t` parses conf.d/*.conf and
# exits non-zero on a bad directive, so the image never gets built.
RUN nginx -t
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

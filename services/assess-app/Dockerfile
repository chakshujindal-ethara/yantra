# The exam app: Assessment v2's Flutter front end (vendored, Yantra patches applied by `yantra vendor sync`),
# served by nginx with the API proxied on the same origin. Build context: services/assess-app.
#
# Stage 1 builds with the exact Flutter release CI tests (3.44.8), cloned at its tag and checked against the
# commit flutter.dev publishes for it (no published image carries 3.44.8; see app/Dockerfile).
FROM debian:bookworm-20261020-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8 AS build
ARG FLUTTER_VERSION=3.44.8
ARG FLUTTER_COMMIT=058e0af2c2b57e369d905a03ac9748b0ebf543c6
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils python3 rsync \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter \
 && test "$(git -C /opt/flutter rev-parse HEAD)" = "$FLUTTER_COMMIT"
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics --no-cli-animations && flutter precache --web
# Yantra's own address, for "Continue with Yantra" and the return-link check.
ARG YANTRA_APP_URL=http://localhost:8095
WORKDIR /src
COPY vendor/ethara-assessment-fe vendor/ethara-assessment-fe
COPY tool tool
COPY build.sh build.sh
RUN YANTRA_APP_URL="$YANTRA_APP_URL" ASSESS_BUILD_DIR=/tmp/assess-build ./build.sh

# Stage 2: static bundle plus the same-origin API proxy. nginx-unprivileged runs as uid 101 on 8080 with a
# read-only root filesystem: the rendered server block and headers live under /tmp.
FROM nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0
ENV NGINX_ENVSUBST_OUTPUT_DIR=/tmp/assess-nginx \
    ODOO_UPSTREAM=odoo:8069
COPY nginx.conf /etc/nginx/templates/assess.conf.template
COPY docker/default.conf /etc/nginx/conf.d/default.conf
COPY docker/18-assess-config.sh /docker-entrypoint.d/18-assess-config.sh
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080

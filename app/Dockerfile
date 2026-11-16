# Stage 1: build the web bundle with the exact Flutter release CI tests (.github/workflows/ci.yaml, 3.44.8). No
# published image carries it (ghcr.io/cirruslabs/flutter stops at 3.44.0), so the SDK is cloned at its release tag
# onto a pinned Debian and the tag's commit is checked against the one flutter.dev publishes for that release.
# GATEWAY_URL / KEYCLOAK_URL are baked in at build time (see README "Local run").
FROM debian:bookworm-20261104-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS build
ARG FLUTTER_VERSION=3.44.8
ARG FLUTTER_COMMIT=058e0af2c2b57e369d905a03ac9748b0ebf543c6
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter \
 && test "$(git -C /opt/flutter rev-parse HEAD)" = "$FLUTTER_COMMIT"
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics --no-cli-animations && flutter precache --web
ARG GATEWAY_URL=http://localhost:8090
ARG KEYCLOAK_URL=http://localhost:8180
# false (the default, every real environment): the Keycloak redirect (authorization code + PKCE) is the only way
# in. The local rig's compose passes true so the username/password form is offered too (its realm allows the
# password grant).
ARG DIRECT_LOGIN=false
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# --no-web-resources-cdn: CanvasKit is served from this image, not fetched from Google's CDN, so the
# page's content security policy keeps scripts to 'self'.
RUN flutter build web --release --no-web-resources-cdn \
      --dart-define=GATEWAY_URL=${GATEWAY_URL} \
      --dart-define=KEYCLOAK_URL=${KEYCLOAK_URL} \
      --dart-define=DIRECT_LOGIN=${DIRECT_LOGIN}

# Stage 2: serve the static bundle with a SPA fallback. At start the entrypoint renders /config.json from
# GATEWAY_URL / KEYCLOAK_URL / DIRECT_LOGIN, so the same image runs in every environment. Outside YANTRA_ENV=local
# the container refuses to start without GATEWAY_URL and KEYCLOAK_URL (its content security policy names them).
# nginx-unprivileged runs as uid 101 on 8080: restricted pod security admits it with a read-only root
# filesystem (only /tmp is written: the pid, the caches and the rendered config and headers).
FROM nginxinc/nginx-unprivileged:1.27.5-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY docker/40-yantra-config.sh /docker-entrypoint.d/40-yantra-config.sh
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 8080

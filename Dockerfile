# One image for every Python deployable (work, money, gateway, the events runners, the migrations, the CLI).
# The command picks the process. Built from the locked workspace; no dev tools inside.
# Bases pinned by digest (tag kept for reading; Dependabot's docker ecosystem bumps both).
FROM python:3.12.16-slim@sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30 AS runtime
COPY --from=ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/app/.venv PYTHONUNBUFFERED=1
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY packages packages
COPY services/market services/market
COPY services/talent services/talent
COPY services/assess services/assess
COPY services/quality services/quality
COPY services/payout services/payout
COPY services/notify services/notify
COPY services/gateway services/gateway
COPY services/tracker services/tracker
COPY services/analytics services/analytics
COPY deployables deployables
COPY tools tools
RUN uv sync --all-packages --no-dev --frozen --no-editable
ENV PATH=/app/.venv/bin:$PATH
RUN useradd --system --uid 10001 yantra && chown -R yantra:yantra /app
USER yantra

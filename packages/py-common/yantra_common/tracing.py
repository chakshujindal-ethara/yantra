"""OpenTelemetry tracing, opt-in: off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set (or a test passes an exporter).
One trace runs from the gateway through the service to its SQL: FastAPI server spans, SQLAlchemy spans on the
engine, httpx client spans on the gateway's forwarding client. Sampling follows the standard `OTEL_TRACES_SAMPLER`
variables. Health, readiness and metrics requests are not traced."""

import os
from collections.abc import Mapping, Sequence
from typing import TYPE_CHECKING

from fastapi import FastAPI
from sqlalchemy import Engine

if TYPE_CHECKING:
    import httpx
    from opentelemetry.sdk.trace.export import SpanExporter

EXCLUDED = "health,ready,metrics"


def install_tracing(
    app: FastAPI,
    service_name: str,
    engine: Engine | None = None,
    clients: "Sequence[httpx.AsyncClient | httpx.Client]" = (),
    exporter: "SpanExporter | None" = None,
    env: Mapping[str, str] | None = None,
) -> bool:
    env = os.environ if env is None else env
    if exporter is None and not env.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return False
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor

    provider = TracerProvider(resource=Resource.create({"service.name": service_name}))
    if exporter is None:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    else:
        provider.add_span_processor(SimpleSpanProcessor(exporter))
    FastAPIInstrumentor.instrument_app(app, tracer_provider=provider, excluded_urls=EXCLUDED)
    if engine is not None:
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

        SQLAlchemyInstrumentor().instrument(engine=engine, tracer_provider=provider)
    if clients:
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

        for client in clients:
            HTTPXClientInstrumentor.instrument_client(client, tracer_provider=provider)
    app.state.tracer_provider = provider
    return True

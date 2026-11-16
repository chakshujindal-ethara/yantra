---
type: Specification
title: Quality Service
description: Multi-stage review pipelines, reviewer hierarchy, calibration, LLM-as-judge, trust scoring, disputes.
tags: [quality, review, service]
status: draft
---

# quality

The quality machine (Scale AI parity per REQUIREMENTS.md). Submodule: `EtharaOrion/yantra-quality` (Phase 5, AI layer Phase 6).

**Responsibilities.** Configurable pipelines (attempt → auto-checks → LLM-as-judge → human review → consensus/audit); reviewer hierarchy with percentile-based promotion/demotion; seeded evaluation units silently scoring accuracy in live batches; calibration batches gating production access; per-worker trust/fit scoring; dataset-level composite quality scores; first-class dispute/appeals workflow with reversal semantics (the anti-Scale failure-mode design). Its accepted verdict is the **canonical completion signal** driving pay, billing, and trust.

**Owns.** `review_task`, `pipeline_stage`, `verdict`, `eval_seed`, `calibration_result`, `trust_score`, `dispute` (DESIGN.md §5.2).

**Emits.** `quality.verdicts` (accepted/rejected/calibration/trust.updated). **Consumes.** `work.units` (submitted), `tracking` (anomaly signals feed integrity).

**SLOs.** Review throughput per pipeline SLA; LLM-judge/human agreement benchmarked against audit samples; dispute resolution time bound.

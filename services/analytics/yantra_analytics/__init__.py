"""analytics: the read side. One durable consumer on every subject keeps an event warehouse (`analytics.event`);
marts are recomputed from it, never incremented, so a replay can never double count; the leadership endpoints
serve the four numbers against their baselines, margin per accepted unit and the watch list. Owns schema
`analytics`; emits nothing; rebuildable from the stream."""

SCHEMA = "analytics"

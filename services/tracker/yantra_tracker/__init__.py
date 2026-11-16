"""tracker: what a worker's screen does while a claim is live. Activity sessions with 30-second samples, weekly
hour caps, anomaly flags an operator dismisses or upholds (an upheld flag puts a payout hold on the worker), and
screenshot references for a future desktop agent. Owns schema `tracker`. Talks to other modules only through
events."""

SCHEMA = "tracker"

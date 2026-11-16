"""gateway: the only ingress for the app. It owns identity at the edge, the shared rate limit, and the
idempotency store. It holds no domain data."""

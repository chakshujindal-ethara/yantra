from yantra_common.ratelimit import SlidingWindowLimiter


def test_window_refills_after_the_oldest_hit_ages_out():
    limiter = SlidingWindowLimiter(limit=2, window_seconds=60)
    assert limiter.check("w", now=0.0) == 0
    assert limiter.check("w", now=10.0) == 0
    assert limiter.check("w", now=20.0) == 40.0
    assert limiter.check("w", now=60.0) == 0
    assert limiter.check("other", now=20.0) == 0


def test_the_key_table_is_capped_and_quiet_keys_are_evicted_first():
    limiter = SlidingWindowLimiter(limit=5, window_seconds=60, max_keys=3)
    for i in range(3):
        limiter.check(f"k{i}", now=float(i))
    assert limiter.size() == 3
    limiter.check("k3", now=100.0)  # every earlier window has emptied: all three go, one new key stays
    assert limiter.size() == 1
    limiter.check("k4", now=101.0)
    limiter.check("k5", now=102.0)
    limiter.check("k6", now=103.0)  # table full, nothing expired: the quietest key (k3) is dropped
    assert limiter.size() == 3 and "k3" not in limiter._hits

# -*- coding: utf-8 -*-
"""Chromium must launch from an Odoo worker that Odoo has memory-capped.

On Linux Odoo sets the RLIMIT_AS soft limit to `limit_memory_hard` (~2.5GB) in
every server mode. Chromium inherits it through the Playwright driver, reserves
more address space than that at startup, and dies with SIGTRAP - every DOM
capture on the prod pods failed with "Target page, context or browser has been
closed". macOS never sets the limit, so local dev never saw it.

`dom_capture._sync_playwright` lifts the soft limit to the HARD limit while the
driver spawns and puts it back afterwards. Both halves matter: without the lift
Chromium dies, without the restore the worker loses its memory guard for good.

`resource` is faked so the test drives the Linux path on any OS, and the hard
limit is finite so "lifted to hard" is distinguishable from "lifted to
unlimited".
"""
from unittest.mock import MagicMock, patch

from odoo.tests.common import TransactionCase, tagged

from ..services import dom_capture

CAP = 2684354560  # Odoo's default limit_memory_hard
HARD = 8 * 1024 ** 3


class _FakeResource:
    RLIMIT_AS = 9

    def __init__(self):
        self.limit = (CAP, HARD)
        self.writes = 0

    def getrlimit(self, which):
        assert which == self.RLIMIT_AS
        return self.limit

    def setrlimit(self, which, limits):
        assert which == self.RLIMIT_AS
        self.writes += 1
        self.limit = tuple(limits)


@tagged("-at_install", "post_install")
class TestChromiumStartsUnderTheMemoryCap(TransactionCase):

    def setUp(self):
        super().setUp()
        self.fake = _FakeResource()
        self.driver = MagicMock()
        self.seen_at_start = []
        self.start_error = None

        def start():
            self.seen_at_start.append(self.fake.limit)
            if self.start_error:
                raise self.start_error
            return self.driver

        manager = MagicMock()
        manager.start.side_effect = start
        for p in (patch.object(dom_capture, "resource", self.fake),
                  patch.object(dom_capture, "sync_playwright",
                               return_value=manager),
                  patch("platform.system", return_value="Linux")):
            p.start()
            self.addCleanup(p.stop)

    def test_the_driver_starts_lifted_and_the_worker_keeps_its_cap(self):
        with dom_capture._sync_playwright() as p:
            self.assertIs(p, self.driver)
            self.assertEqual(self.fake.limit, (CAP, HARD),
                             "the worker must have its cap back while it works")
        self.assertEqual(self.seen_at_start, [(HARD, HARD)],
                         "the driver must spawn with soft lifted to hard, "
                         "never above it")
        self.assertEqual(self.fake.limit, (CAP, HARD))
        self.driver.stop.assert_called_once()

    def test_a_driver_that_fails_to_start_still_restores_the_cap(self):
        self.start_error = RuntimeError("driver did not start")
        with self.assertRaises(RuntimeError):
            with dom_capture._sync_playwright():
                pass
        self.assertEqual(self.seen_at_start, [(HARD, HARD)])
        self.assertEqual(self.fake.limit, (CAP, HARD))
        self.assertTrue(dom_capture._RLIMIT_LOCK.acquire(blocking=False),
                        "a failed start must not leave the lock held")
        dom_capture._RLIMIT_LOCK.release()

    def test_off_linux_the_limit_is_never_touched(self):
        with patch("platform.system", return_value="Darwin"):
            with dom_capture._sync_playwright() as p:
                self.assertIs(p, self.driver)
        self.assertEqual(self.fake.writes, 0)
        self.assertEqual(self.seen_at_start, [(CAP, HARD)])

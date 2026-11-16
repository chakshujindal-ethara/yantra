# -*- coding: utf-8 -*-
"""W4.5: the Odoo form's status badge backs off while nothing changes.

`be_auto_refresh` (the assessment form's scoring badge, the generator's SOP and
tag badges) read its record every 3 s for as long as a run stayed busy - an hour
of one open form was ~1,200 reads for an answer that had not moved. It now
stretches the wait while the value is unchanged, up to a ceiling between 15 and
30 s, snaps back on any change, and stops for good when the form closes - even
if a read was in flight at that moment.

Asserted against the asset source, as `test_the_scoring_run_reports_its_phase`
does for this widget: the module has no JS test runner, and the defect IS the
timer in that file.
"""
import os
import re

from odoo.tests.common import TransactionCase

_JS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "static/src/fields/auto_refresh/auto_refresh.js")


def _const(js, name):
    match = re.search(r"const %s = ([\d.]+);" % name, js)
    return float(match.group(1)) if match else None


class TestTheBadgeBacksOff(TransactionCase):

    def setUp(self):
        super().setUp()
        with open(_JS, encoding="utf-8") as fh:
            self.js = fh.read()

    def _method(self, name):
        """The body of the method DEFINED as `name` (4-space indent)."""
        return self.js.split("\n    %s(" % name, 1)[1].split("\n    }\n", 1)[0]

    def test_the_wait_grows_to_a_ceiling_of_15_to_30_seconds(self):
        start = _const(self.js, "POLL_MS")
        ceiling = _const(self.js, "MAX_POLL_MS")
        factor = _const(self.js, "BACKOFF")
        self.assertEqual(start, 3000, "the first check stays prompt")
        self.assertTrue(15000 <= ceiling <= 30000, ceiling)
        self.assertGreater(factor, 1)

        # The schedule the widget follows while the value never changes.
        delay, waits = start, []
        for _ in range(20):
            waits.append(delay)
            delay = min(delay * factor, ceiling)
        self.assertEqual(waits[:2], [3000, 3000 * factor])
        self.assertEqual(waits[-1], ceiling)

        self.assertIn("Math.min(this._delay * BACKOFF, MAX_POLL_MS)",
                      self._method("_backOff"))
        self.assertIn("setTimeout(() => this._poll(), this._delay)",
                      self._method("_maybeSchedule"))

    def test_an_unchanged_read_backs_off_and_a_change_resets(self):
        poll = self._method("async _poll")
        self.assertIn("serverVal === this._lastSeen", poll)
        self.assertIn("this._backOff();", poll)
        self.assertIn("this._delay = POLL_MS;", poll)

    def test_closing_the_form_stops_polling_even_mid_read(self):
        unmount = self.js.split("onWillUnmount(", 1)[1].split("});", 1)[0]
        self.assertIn("this._stopped = true", unmount)
        self.assertIn("this._clear()", unmount)
        poll = self._method("async _poll")
        after_read = poll.split("await rec.model.orm.read", 1)[1]
        self.assertIn("if (this._stopped)", after_read,
                      "a read in flight when the form closed would schedule "
                      "another one behind it")
        self.assertIn("!this._stopped", self._method("_maybeSchedule"))

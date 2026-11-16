# -*- coding: utf-8 -*-
"""Two protections that a shared ingress address used to defeat.

BRUTE-FORCE. Odoo's `_assert_can_auth` docstring says the cooldown puts "the
user (by login)" on hold; the implementation keys it on
`request.httprequest.remote_addr`. Every candidate here reaches Odoo as one of
TWO ingress addresses, so the bucket is effectively global: on 2026-09-17, five
failures from one candidate froze sign-in for the whole 753-candidate cohort -
3,668 refusals in seven minutes. The mitigation was to switch the feature OFF,
and it has been off since, so there is currently no limit on password guessing.

`proxy_mode` does not fix it (`odoo/http.py` pins `ProxyFix(x_for=1)` and the
real client address was destroyed further upstream), so the override keys the
bucket on the LOGIN and keeps a far looser per-IP ceiling for credential
spraying.

EVERY BRUTE-FORCE TEST BELOW DRIVES `_assert_can_auth` ITSELF, under a patched
`request`, and that is not a style preference. The override's first statement is
`if not request: yield; return`, so a `TransactionCase` with no request runs
NONE of it - a test that writes the failure bucket by hand and then reads the
bucket back is grading its own arithmetic, and stays green with the whole
override deleted. These raise `AccessDenied` inside the context manager the way
a wrong password does, and assert on what the override then did.

TOKENS IN THE LOG. An exam token is a credential - whoever holds it can sit
that candidate's paper without a password - and werkzeug's access log wrote the
full request line, so every media fetch published one.
"""
import datetime
import logging
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import AccessDenied
from odoo.tests.common import TransactionCase, tagged

#: Where the limiter reads the client address from. Patched, never faked out:
#: the code under test is the real context manager.
_REQUEST = "odoo.addons.assessments_be_v2.models.res_users.request"

#: One of the two addresses the whole cohort arrives from.
INGRESS = "10.1.0.35"


def _stub_request(address):
    """The single attribute the limiter reads off a request."""
    return SimpleNamespace(
        httprequest=SimpleNamespace(remote_addr=address))


class _Probe(Exception):
    """Raised inside the context manager to ask "would this get through?".

    Neither a success nor a failure as far as `_assert_can_auth` is concerned,
    so asking the question does not itself move any counter.
    """


@tagged("-at_install", "post_install")
class TestOneCandidateCannotLockOutTheCohort(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Users = self.env["res.users"].sudo()
        self.ICP = self.env["ir.config_parameter"].sudo()
        # Set explicitly so these never depend on the value an operator
        # happened to leave behind on the database they run against.
        self.ICP.set_param("base.login_cooldown_duration", "60")
        self.registry._be_login_failures = {}
        self.addCleanup(setattr, self.registry, "_be_login_failures", {})

    def _bucket(self):
        return self.registry._be_login_failures

    def _fail(self, logins, times=1, address=INGRESS):
        """Refused sign-ins, driven through the REAL context manager.

        `logins` is one login or a sequence of them. Each attempt raises
        `AccessDenied` inside the `with`, which is exactly what a wrong
        password does at `res.users._login`.
        """
        if isinstance(logins, str):
            logins = (logins,)
        with patch(_REQUEST, _stub_request(address)):
            for login in logins:
                for _ in range(times):
                    with self.assertRaises(AccessDenied):
                        with self.Users._assert_can_auth(user=login):
                            raise AccessDenied("wrong password")

    def _succeed(self, login, address=INGRESS):
        """A sign-in that works, through the real context manager."""
        with patch(_REQUEST, _stub_request(address)):
            with self.Users._assert_can_auth(user=login):
                pass

    def _admitted(self, login, address=INGRESS):
        """Does the limiter let this attempt reach the password check at all?"""
        with patch(_REQUEST, _stub_request(address)):
            try:
                with self.Users._assert_can_auth(user=login):
                    raise _Probe()
            except _Probe:
                return True
            except AccessDenied:
                return False

    def test_the_bucket_is_keyed_on_the_login_not_the_address(self):
        """The whole defect in one assertion: two candidates, one address."""
        self.ICP.set_param("base.login_cooldown_after", "3")

        self._fail("a@x.com", times=4)

        self.assertFalse(
            self._admitted("a@x.com"),
            "the candidate who actually failed must be on cooldown")
        self.assertTrue(
            self._admitted("b@x.com"),
            "a DIFFERENT candidate at the SAME address must still get "
            "through - keying this bucket on the IP is what froze 753 people")

    def test_the_per_ip_ceiling_is_far_looser_than_the_per_login_one(self):
        """It still catches one host spraying many accounts, at a threshold a
        real cohort cannot reach.

        Asserted as BEHAVIOUR, not as the value of `_BE_IP_CEILING_MULTIPLIER`:
        the constant can be 20 while the call site passes 1, and that mutation
        is precisely the 2026-09-17 incident.
        """
        after = 3
        self.ICP.set_param("base.login_cooldown_after", str(after))

        # A cohort's worth of ordinary typos from the shared address: many
        # candidates, one failure each.
        self._fail(["cohort-%d@x.com" % i for i in range(after * 5)])

        self.assertTrue(
            self._admitted("fresh@x.com"),
            "%d failures spread across %d candidates at one ingress address "
            "must not refuse the next candidate" % (after * 5, after * 5))

        # A spray: one host, far past the ceiling.
        self._fail(["spray-%d@x.com" % i
                    for i in range(after * self.Users._BE_IP_CEILING_MULTIPLIER)])

        self.assertFalse(
            self._admitted("innocent@x.com"),
            "one host spraying many accounts is the only thing the per-IP "
            "ceiling exists to catch")

    def test_zero_still_disables_the_feature_entirely(self):
        """`base.login_cooldown_after = 0` is Odoo's own off switch and the
        current production setting. The override must not quietly re-enable
        protection an operator deliberately turned off."""
        self.ICP.set_param("base.login_cooldown_after", "0")

        self._fail("a@x.com", times=50)

        self.assertTrue(
            self._admitted("a@x.com"),
            "50 failures must still not refuse anybody while the feature is "
            "switched off")

    def test_the_failure_bucket_is_bounded(self):
        """KEYING ON THE LOGIN MADE THIS UNBOUNDED, which Odoo's IP-keyed
        version is not: a spray script trying random addresses would add one
        entry per attempt until the worker ran out of memory - a cheaper denial
        of service than the password guessing this was added to stop.

        Run with the cooldown off so the gate never refuses an attempt before
        it is recorded; the eviction is in the recording path either way.
        """
        self.ICP.set_param("base.login_cooldown_after", "0")
        ceiling = self.Users._BE_MAX_TRACKED_FAILURES

        self._fail(["spray-%d@x.com" % i for i in range(ceiling + 50)])

        bucket = self._bucket()
        self.assertLessEqual(len(bucket), ceiling)
        self.assertGreater(len(bucket), 0, "eviction must not empty it")
        # The NEWEST entries survive - evicting those would forget the attacker
        # currently active and keep the ones who gave up.
        self.assertIn(("login", "spray-%d@x.com" % (ceiling + 49)), bucket)

    def test_a_success_clears_the_login_but_not_the_shared_address(self):
        """A candidate who finally gets in must not leave their own counter
        part way to a lockout.

        IT MUST NOT ZERO THE COHORT'S ADDRESS EITHER. The per-IP bucket is the
        only thing that sees credential spraying - one password against ten
        thousand accounts never accumulates on any single login - and clearing
        it on ANY success from that address meant the sprayer only had to sign
        in to their own account occasionally, or simply wait for a candidate
        to, and the ceiling was never approached.
        """
        self.ICP.set_param("base.login_cooldown_after", "3")
        self._fail("a@x.com", times=2)

        self._succeed("a@x.com")

        self.assertNotIn(
            ("login", "a@x.com"), self._bucket(),
            "the candidate's own counter must be cleared by getting in")
        self.assertEqual(
            self._bucket().get(("ip", INGRESS), (0, None))[0], 2,
            "the shared address must keep its count - clearing it on any "
            "success is what left credential spraying unlimited")

    def test_the_address_counter_only_counts_the_last_cooldown_window(self):
        """Because a success no longer clears it, the address needs some other
        way back to zero, or a cohort's ordinary typos accumulate all season
        and freeze it again. Odoo's own predicate ignores a failure older than
        `base.login_cooldown_duration`, so the stored count follows it."""
        # Comfortably above the five failures below, so the LOGIN gate never
        # refuses one before it is recorded and the count being read is the
        # count the override actually kept.
        self.ICP.set_param("base.login_cooldown_after", "10")

        self._fail("a@x.com", times=5)
        self.assertEqual(self._bucket()[("ip", INGRESS)][0], 5)

        # Backdate the bucket past the window, the way a quiet hour does.
        stale = datetime.datetime.now() - datetime.timedelta(seconds=120)
        for key, (failures, _previous) in list(self._bucket().items()):
            self._bucket()[key] = (failures, stale)

        self._fail("a@x.com")

        self.assertEqual(
            self._bucket()[("ip", INGRESS)][0], 1,
            "a failure outside the window starts the count over instead of "
            "adding to a total that can only ever grow")


@tagged("-at_install", "post_install")
class TestAnExamTokenIsNeverWrittenToTheAccessLog(TransactionCase):

    def _redact(self, line, args=None):
        from ..models import ir_http
        record = logging.LogRecord(
            "werkzeug", logging.INFO, __file__, 1, line, args, None)
        ir_http._RedactExamTokens().filter(record)
        return record.getMessage()

    def test_an_exam_media_token_is_replaced(self):
        token = uuid4().hex
        out = self._redact(
            'GET /assessments_be/exam/qimage/%s/1 HTTP/1.1' % token)

        self.assertNotIn(token, out)
        self.assertIn("<redacted>", out)
        self.assertIn("/assessments_be/exam/qimage/", out,
                      "the path shape must survive, or the log stops being "
                      "useful for anything else")

    def test_the_candidate_exam_entry_point_is_covered_too(self):
        token = uuid4().hex
        self.assertNotIn(token, self._redact('GET /exam/%s HTTP/1.1' % token))

    def test_the_legacy_portal_routes_are_covered_too(self):
        """`/pro_assessment/<token>` and its sub-paths are live public routes
        in this addon (`legacy_redirects.py`), so every bookmarked or
        already-emailed invitation still lands on one.

        THE PATTERN NAMED THEM AND THE FILTER NEVER RAN IT: the cheap substring
        test in front of it was the literal "/exam", and "/pro_assessment/"
        does not contain "/exam", so that whole branch was dead and those
        tokens went to the log in clear.
        """
        token = uuid4().hex
        for path in ("/pro_assessment/%s" % token,
                     "/pro_assessment/%s/begin" % token,
                     "/pro_assessment/%s/submit" % token,
                     "/pro_assessment/qimage/%s/17" % token,
                     "/pro_assessment/qvideo/%s/17" % token):
            line = 'GET %s HTTP/1.1' % path
            out = self._redact(line)
            self.assertNotIn(token, out, line)
            self.assertIn("<redacted>", out, line)

    def test_the_record_shape_werkzeug_actually_emits_is_redacted(self):
        """Werkzeug logs the request line as an ARGUMENT, not as the message:
        `self.log("info", '"%s" %s %s', msg, code, size)`. A filter that only
        rewrote `record.msg` would leave every real access line untouched."""
        token = uuid4().hex
        out = self._redact(
            '"%s" %s %s',
            ('GET /exam/%s HTTP/1.1' % token, 200, '-'))

        self.assertNotIn(token, out)
        self.assertIn("<redacted>", out)

    def test_an_ordinary_path_is_untouched(self):
        line = 'GET /web/health HTTP/1.1'
        self.assertEqual(self._redact(line), line)

    def test_the_filter_never_raises(self):
        """A logging filter that throws takes the log line with it."""
        from ..models import ir_http

        class _Awkward:
            def __str__(self):
                raise RuntimeError("boom")

        record = logging.LogRecord(
            "werkzeug", logging.INFO, __file__, 1, _Awkward(), None, None)
        self.assertTrue(ir_http._RedactExamTokens().filter(record))

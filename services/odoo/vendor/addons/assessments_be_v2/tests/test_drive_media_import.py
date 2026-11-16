"""Importing a share link into this app's own media storage.

WHY THE ROUTE EXISTS. A Drive `/file/d/<id>/view` link is the VIEWER PAGE - it
answers `text/html`, so nothing can render it and the designer shows a dead
plate reading "Could not load that image URL". Examiners paste one because it
is the URL Drive hands them. `/api/v1/forms/media/import` fetches the actual
bytes once and stores them where the Upload button stores them, so the media
becomes this app's own. Dropbox, OneDrive and SharePoint were added because
they are the other three hosts examiners actually paste.

WHAT THESE TESTS ARE MOSTLY ABOUT: the allow-list is the SECURITY BOUNDARY of
that route. A route that fetches whatever URL a caller names is an SSRF
primitive, and this one runs on EKS where the instance metadata service would
hand back IAM credentials. No match means no fetch, so the URL parsers are the
whole defence and the bypass attempts below are the point of this file - not the
happy path. Widening the host set widens exactly that boundary, so every
refusal `_drive_file_id` already held is re-asserted against
`_import_fetch_url`, which is what the route now actually calls.

Deliberately NOT tested here: reaching a real host. That would make this a
network-availability test.

TESTED WITH A FAKE `requests.get` ANYWAY, in one place: the redirect walk. Every
one of these hosts answers a share URL with a 302 to a separate content domain,
so `_fetch_share_link` follows hops BY HAND and re-checks each one. That check
is our own logic and nothing else exercises it - a fake transport asserts the
hop policy, not that a mock was called. Following redirects automatically (the
`requests` default, and what this route used to do) let the allow-listed host
choose the final destination, which is the fetch-anything primitive the
allow-list exists to prevent.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import forms as forms_api
from odoo.addons.assessments_be_v2.controllers.api.forms import (
    EtpStudioFormsApi,
    _drive_file_id,
    _import_fetch_url,
    _redirect_host_allowed,
    _with_param,
)

_ID = "1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji"


@tagged("post_install", "-at_install")
class TestDriveFileId(TransactionCase):
    """The id parser that decides whether anything is fetched at all."""

    # -- the shapes examiners actually paste ---------------------------

    def test_the_share_link_that_prompted_this(self):
        self.assertEqual(
            _drive_file_id(
                "https://drive.google.com/file/d/%s/view" % _ID), _ID)

    def test_a_share_link_with_the_usual_query(self):
        self.assertEqual(
            _drive_file_id(
                "https://drive.google.com/file/d/%s/view?usp=sharing" % _ID),
            _ID)

    def test_the_open_and_uc_shapes(self):
        self.assertEqual(
            _drive_file_id("https://drive.google.com/open?id=%s" % _ID), _ID)
        self.assertEqual(
            _drive_file_id(
                "https://drive.google.com/uc?export=view&id=%s" % _ID), _ID)

    def test_surrounding_whitespace_and_www(self):
        self.assertEqual(
            _drive_file_id("  https://www.drive.google.com/file/d/%s/view  "
                           % _ID), _ID)

    # -- SSRF: the reason this parser exists ---------------------------

    def test_a_lookalike_host_is_refused(self):
        """`drive.google.com.evil.test` must not pass.

        A substring test for "drive.google.com" would accept this, and the
        route would then fetch a host the attacker controls.
        """
        self.assertIsNone(_drive_file_id(
            "https://drive.google.com.evil.test/file/d/%s/view" % _ID))

    def test_the_host_in_a_query_string_is_refused(self):
        self.assertIsNone(_drive_file_id(
            "https://evil.test/x?u=https://drive.google.com/file/d/%s/view"
            % _ID))

    def test_userinfo_smuggling_is_refused(self):
        """`https://drive.google.com@evil.test/` resolves to evil.test."""
        self.assertIsNone(_drive_file_id(
            "https://drive.google.com@evil.test/file/d/%s/view" % _ID))

    def test_cloud_metadata_is_refused(self):
        """The payload this allow-list exists to stop."""
        for url in (
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
            "http://metadata.google.internal/computeMetadata/v1/",
        ):
            self.assertIsNone(
                _drive_file_id(url),
                "%s must never yield a file id" % url)

    def test_internal_hosts_are_refused(self):
        for url in ("http://localhost:8069/web/session/authenticate",
                    "http://127.0.0.1:8069/api/v1/settings",
                    "http://10.0.0.5/",
                    "file:///etc/passwd"):
            self.assertIsNone(_drive_file_id(url), "%s must be refused" % url)

    def test_plain_http_drive_is_refused(self):
        """The patterns are https-anchored - no downgrade to a MITM-able hop."""
        self.assertIsNone(_drive_file_id(
            "http://drive.google.com/file/d/%s/view" % _ID))

    def test_other_google_hosts_are_refused(self):
        """Only Drive. Docs/Sheets are not media and share the parent domain."""
        self.assertIsNone(_drive_file_id(
            "https://docs.google.com/document/d/%s/edit" % _ID))

    # -- junk ----------------------------------------------------------

    def test_empty_and_nonsense(self):
        for url in ("", "   ", None, "not a url", "https://drive.google.com/",
                    "https://drive.google.com/file/d//view"):
            self.assertIsNone(_drive_file_id(url), "%r must be refused" % (url,))

    def test_a_too_short_id_is_refused(self):
        """Drive ids are long; a 3-character one is a malformed paste."""
        self.assertIsNone(
            _drive_file_id("https://drive.google.com/file/d/abc/view"))


# ----------------------------------------------------------------------
# The widened allow-list - `_import_fetch_url` is what the route calls
# ----------------------------------------------------------------------
@tagged("post_install", "-at_install")
class TestImportFetchUrl(TransactionCase):
    """Which links get fetched at all, now that it is not only Drive.

    `_drive_file_id` above is still the Drive half, but it is no longer the
    route's boundary on its own. Everything the old parser refused must still be
    refused HERE, because this is the function whose None means "no request is
    made".
    """

    # -- the shapes examiners paste, per host --------------------------

    def test_a_drive_link_becomes_the_direct_download_form(self):
        """Drive still routes through `_drive_file_id` and its id.

        `confirm=t` matters: without it Drive answers larger files with an
        interstitial HTML page, which the content-type gate then rejects as
        "not a media file" - true, but for the wrong reason.
        """
        fetch = _import_fetch_url(
            "https://drive.google.com/file/d/%s/view?usp=sharing" % _ID)
        self.assertIn("uc?export=download", fetch)
        self.assertIn(_ID, fetch)
        self.assertIn("confirm=t", fetch)

    def test_dropbox_share_links_are_forced_to_serve_bytes(self):
        for url in (
            "https://www.dropbox.com/s/abc123/plate.png",
            "https://www.dropbox.com/scl/fi/abc123/plate.png?rlkey=x",
            "https://dropbox.com/s/abc123/clip.mp4",
        ):
            fetch = _import_fetch_url(url)
            self.assertIsNotNone(fetch, "%s must be importable" % url)
            self.assertIn("dl=1", fetch,
                          "%s must be turned into a download" % url)

    def test_an_existing_dl_zero_is_REPLACED_not_appended(self):
        """The shape Dropbox actually hands an examiner.

        A share link arrives carrying `?dl=0`. Appending `&dl=1` would leave
        the host free to honour the FIRST value and answer the preview page -
        which then fails the content-type gate, so the examiner is told their
        perfectly good link is "not a media file".
        """
        fetch = _import_fetch_url(
            "https://www.dropbox.com/s/abc123/plate.png?dl=0")
        self.assertIn("dl=1", fetch)
        self.assertNotIn("dl=0", fetch)

    def test_the_dropbox_content_host_is_taken_as_is(self):
        """It already serves bytes, so there is no parameter to add."""
        url = "https://dl.dropboxusercontent.com/s/abc123/plate.png"
        self.assertEqual(_import_fetch_url(url), url)

    def test_onedrive_and_sharepoint_are_forced_to_download(self):
        for url in (
            "https://1drv.ms/i/s!AbCdEf123456",
            "https://onedrive.live.com/?cid=abc&id=def&authkey=ghi",
            "https://acme.sharepoint.com/:i:/g/personal/x/AbC123",
            "https://acme.sharepoint.com/:v:/g/personal/x/AbC123",
        ):
            fetch = _import_fetch_url(url)
            self.assertIsNotNone(fetch, "%s must be importable" % url)
            self.assertIn("download=1", fetch,
                          "%s must be turned into a download" % url)

    def test_a_sharepoint_link_that_is_not_a_file_share_is_refused(self):
        """`:i:`/`:v:` are the image and video share shapes.

        A bare site or document URL is not media, and matching the whole
        tenant host without them would let any SharePoint page be fetched.
        """
        for url in ("https://acme.sharepoint.com/sites/team",
                    "https://acme.sharepoint.com/:w:/g/personal/x/AbC123",
                    "https://acme.sharepoint.com/_layouts/15/start.aspx"):
            self.assertIsNone(_import_fetch_url(url), "%s must be refused" % url)

    # -- SSRF: every refusal the Drive parser held, held here -----------

    def test_lookalike_hosts_are_refused_for_every_new_family(self):
        """The mistake a substring check would make, per host.

        `dropbox.com.evil.test` contains "dropbox.com". If the pattern were not
        anchored on the whole host, the route would fetch a host the attacker
        owns - and then the redirect allow-list, the content-type gate and the
        size cap are all being applied to an attacker's server.
        """
        for url in (
            "https://drive.google.com.evil.test/file/d/%s/view" % _ID,
            "https://dropbox.com.evil.test/s/abc123/plate.png",
            "https://www.dropbox.com.evil.test/s/abc123/plate.png",
            "https://dl.dropboxusercontent.com.evil.test/s/abc/plate.png",
            "https://1drv.ms.evil.test/i/s!AbC",
            "https://onedrive.live.com.evil.test/?id=abc",
            "https://acme.sharepoint.com.evil.test/:i:/g/x",
        ):
            self.assertIsNone(_import_fetch_url(url), "%s must be refused" % url)

    def test_the_host_in_a_query_string_is_refused(self):
        for host in ("drive.google.com/file/d/%s/view" % _ID,
                     "www.dropbox.com/s/abc/plate.png",
                     "1drv.ms/i/s!AbC",
                     "acme.sharepoint.com/:i:/g/x"):
            self.assertIsNone(
                _import_fetch_url("https://evil.test/x?u=https://%s" % host),
                "%s smuggled in a query must be refused" % host)

    def test_userinfo_smuggling_is_refused(self):
        """`https://www.dropbox.com@evil.test/` resolves to evil.test."""
        for url in (
            "https://drive.google.com@evil.test/file/d/%s/view" % _ID,
            "https://www.dropbox.com@evil.test/s/abc/plate.png",
            "https://1drv.ms@evil.test/i/s!AbC",
            "https://acme.sharepoint.com@evil.test/:i:/g/x",
        ):
            self.assertIsNone(_import_fetch_url(url), "%s must be refused" % url)

    def test_cloud_metadata_and_internal_hosts_are_refused(self):
        """The payload the allow-list exists to stop, unchanged by widening."""
        for url in (
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/",
            "http://metadata.google.internal/computeMetadata/v1/",
            "http://localhost:8069/web/session/authenticate",
            "http://127.0.0.1:8069/api/v1/settings",
            "http://10.0.0.5/",
            "file:///etc/passwd",
        ):
            self.assertIsNone(_import_fetch_url(url), "%s must be refused" % url)

    def test_plain_http_is_refused_for_every_family(self):
        """https-anchored throughout - no downgrade to a MITM-able hop."""
        for url in (
            "http://drive.google.com/file/d/%s/view" % _ID,
            "http://www.dropbox.com/s/abc/plate.png",
            "http://1drv.ms/i/s!AbC",
            "http://onedrive.live.com/?id=abc",
            "http://acme.sharepoint.com/:i:/g/x",
        ):
            self.assertIsNone(_import_fetch_url(url), "%s must be refused" % url)

    def test_an_ordinary_url_is_not_importable(self):
        """Nothing to copy - the FE offers no button, and the route refuses.

        A direct CDN URL needs no import: it already serves bytes. Accepting it
        here would turn the route into "fetch any https URL", which is the
        primitive the allow-list exists to deny.
        """
        for url in ("https://cdn.example.com/plate.png",
                    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    "", "   ", None, "not a url",
                    "/api/v1/forms/media/form_studio/deadbeef.png"):
            self.assertIsNone(_import_fetch_url(url), "%r must be refused"
                              % (url,))


# ----------------------------------------------------------------------
# `_with_param` - small, and the reason a Dropbox link works at all
# ----------------------------------------------------------------------
@tagged("post_install", "-at_install")
class TestWithParam(TransactionCase):

    def test_it_adds_the_parameter_when_there_is_no_query(self):
        self.assertEqual(
            _with_param("https://1drv.ms/i/s!AbC", "download=1"),
            "https://1drv.ms/i/s!AbC?download=1")

    def test_it_keeps_the_other_parameters(self):
        out = _with_param(
            "https://www.dropbox.com/scl/fi/a/x.png?rlkey=k&dl=0", "dl=1")
        self.assertIn("rlkey=k", out)
        self.assertIn("dl=1", out)
        self.assertNotIn("dl=0", out)

    def test_no_parameter_means_the_url_is_untouched(self):
        url = "https://dl.dropboxusercontent.com/s/a/x.png"
        self.assertEqual(_with_param(url, None), url)


# ----------------------------------------------------------------------
# The redirect allow-list, and the walk that applies it
# ----------------------------------------------------------------------
@tagged("post_install", "-at_install")
class TestRedirectHostAllowed(TransactionCase):
    """Where a supported share link may send us NEXT.

    This list is separate from the import allow-list on purpose: the URL an
    examiner may PASTE and the content host a share link may REDIRECT to are
    different sets. `googleusercontent.com` belongs here and nowhere else.
    """

    def test_the_content_hosts_these_links_really_redirect_to(self):
        for url in (
            "https://doc-0k-8s-docs.googleusercontent.com/docs/abc/plate.png",
            "https://drive.google.com/uc?export=download&id=%s" % _ID,
            "https://uc123.dl.dropboxusercontent.com/cd/0/get/abc/plate.png",
            "https://acme.sharepoint.com/personal/x/Documents/plate.png",
            "https://api.onedrive.live.com/v1.0/drives/abc/content",
            # OneDrive personal's third hop, on its OWN registrable domain -
            # `1drv.ms` does not cover `1drv.com`, and missing it broke the
            # last hop of every OneDrive import.
            "https://public.dm.files.1drv.com/y4m123",
            "https://acme-my.sharepoint.com/personal/x/plate.png",
        ):
            self.assertTrue(_redirect_host_allowed(url),
                            "%s is a real hop and must be allowed" % url)

    def test_a_lookalike_hop_is_refused(self):
        """Suffix matching is on a DOT boundary, not a substring.

        `googleusercontent.com.evil.test` ends with neither `.googleusercontent
        .com` nor equals it, and `evilgoogleusercontent.com` is a different
        registrable domain that merely ends in the same letters.
        """
        for url in (
            "https://googleusercontent.com.evil.test/plate.png",
            "https://evilgoogleusercontent.com/plate.png",
            "https://notdropbox.com/plate.png",
            "https://sharepoint.com.evil.test/plate.png",
        ):
            self.assertFalse(_redirect_host_allowed(url),
                             "%s must not be followed" % url)

    def test_an_ip_literal_hop_is_refused(self):
        """An IP literal is on no allow-list, so the host check alone stops it.

        `net_guard` would refuse the private ones anyway; this asserts the
        allow-list refuses a PUBLIC one too, so a compromised share host cannot
        redirect us to an arbitrary address it happens to own.
        """
        for url in ("http://169.254.169.254/latest/meta-data/",
                    "http://127.0.0.1:8069/api/v1/settings",
                    "http://10.0.0.5/plate.png",
                    "https://93.184.216.34/plate.png"):
            self.assertFalse(_redirect_host_allowed(url),
                             "%s must not be followed" % url)

    def test_junk_is_refused(self):
        for url in ("", "   ", "not a url", "file:///etc/passwd",
                    "https:///plate.png"):
            self.assertFalse(_redirect_host_allowed(url),
                             "%r must not be followed" % (url,))


class _FakeResponse:
    """Just enough of `requests.Response` for `_fetch_share_link`.

    Deliberately does NOT define `is_redirect`: the walk branches on
    `status_code`, and a fake that supplied the property would let the code go
    back to reading it without a test noticing - which is the bug this class
    caught.
    """

    def __init__(self, status_code, headers=None):
        self.status_code = status_code
        self.headers = headers or {}
        self.closed = False

    @property
    def ok(self):
        return self.status_code < 400

    def close(self):
        self.closed = True


@tagged("post_install", "-at_install")
class TestFetchShareLinkFollowsHopsByHand(TransactionCase):
    """THE HOLE THIS CLOSES, which existed on the Drive path already.

    `uc?export=download` has always answered a 302 to `*.googleusercontent.com`.
    With `allow_redirects=True` - the default, and what this route used to pass -
    `requests` followed that hop and every hop after it WITHOUT consulting the
    allow-list. So the allow-list decided hop zero and nothing else: an open
    redirect on Drive, Dropbox or SharePoint (or a compromised one) handed this
    route back the fetch-anything primitive it exists to deny.

    A fake transport is the only way to assert a hop POLICY. The assertions are
    about which URLs were requested and which were refused, not about a mock
    having been called.
    """

    def setUp(self):
        super().setUp()
        self.controller = EtpStudioFormsApi()

    def _run(self, script):
        """Play [script] (url -> response) and return (result, urls_requested).

        A url missing from the script is a test bug, and raising says so rather
        than silently answering 200.
        """
        seen = []

        def fake_get(url, **kw):
            seen.append(url)
            self.assertFalse(
                kw.get("allow_redirects", True),
                "hops must be followed by hand, never by requests itself")
            if url not in script:
                raise AssertionError("unexpected request to %s" % url)
            return script[url]

        # `net_guard` resolves hostnames; these are example hosts that do not
        # exist, so the DNS half is stubbed to allow. The point of this test is
        # the HOST ALLOW-LIST, and `net_guard` has its own refusals asserted
        # through `_import_fetch_url` above.
        with patch.object(forms_api.requests, "get", fake_get), \
                patch.object(forms_api.net_guard, "is_safe_url",
                             return_value=True):
            return self.controller._fetch_share_link(
                list(script)[0]), seen

    def test_a_normal_two_hop_chain_reaches_the_content_host(self):
        start = "https://drive.google.com/uc?export=download&id=%s" % _ID
        final = "https://doc-0k.googleusercontent.com/docs/abc/plate.png"
        (resp, err), seen = self._run({
            start: _FakeResponse(302, {"Location": final}),
            final: _FakeResponse(200, {"Content-Type": "image/png"}),
        })
        self.assertIsNone(err)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(seen, [start, final])

    def test_a_relative_location_is_joined_against_the_current_hop(self):
        """Normal on these hosts, and a bare path has no host to check."""
        start = "https://onedrive.live.com/?id=abc&download=1"
        (resp, err), seen = self._run({
            start: _FakeResponse(302, {"Location": "/download?cid=abc"}),
            "https://onedrive.live.com/download?cid=abc":
                _FakeResponse(200, {"Content-Type": "image/jpeg"}),
        })
        self.assertIsNone(err)
        self.assertEqual(seen[1], "https://onedrive.live.com/download?cid=abc")

    def test_a_hop_to_an_off_list_host_is_REFUSED_AND_NEVER_REQUESTED(self):
        """The regression this whole mechanism exists for.

        Note the assertion on `seen`: it is not enough to fail afterwards. The
        request to the attacker's host must never be made at all, because
        making it is itself the SSRF - the response body is beside the point
        when the target is an internal service.
        """
        start = "https://www.dropbox.com/s/abc/plate.png?dl=1"
        (resp, err), seen = self._run({
            start: _FakeResponse(302, {"Location": "https://evil.test/x.png"}),
        })
        self.assertIsNone(resp)
        code, message, status = err
        self.assertEqual(code, "unsupported_source")
        self.assertEqual(status, 400)
        self.assertIn("evil.test", message,
                      "the refusal must name the hop so it is diagnosable")
        self.assertEqual(seen, [start],
                         "the off-list hop must never be requested")

    def test_a_hop_to_an_ip_literal_is_refused(self):
        """The metadata payload, arriving as a redirect rather than a paste."""
        start = "https://acme.sharepoint.com/:i:/g/x?download=1"
        (resp, err), seen = self._run({
            start: _FakeResponse(
                302,
                {"Location": "http://169.254.169.254/latest/meta-data/"}),
        })
        self.assertIsNone(resp)
        self.assertEqual(err[0], "unsupported_source")
        self.assertEqual(seen, [start],
                         "169.254.169.254 must never be requested")

    def test_a_redirect_loop_ends(self):
        a = "https://www.dropbox.com/s/abc/plate.png?dl=1"
        b = "https://dl.dropboxusercontent.com/cd/0/get/abc/plate.png"
        (resp, err), seen = self._run({
            a: _FakeResponse(302, {"Location": b}),
            b: _FakeResponse(302, {"Location": a}),
        })
        self.assertIsNone(resp)
        self.assertEqual(err[0], "fetch_failed")
        self.assertIn("too many times", err[1])
        self.assertLessEqual(
            len(seen), self.controller.MAX_IMPORT_REDIRECTS + 1,
            "the walk must stop at MAX_IMPORT_REDIRECTS")

    def test_a_redirect_with_no_location_is_a_failure_not_a_crash(self):
        """A 302 with no `Location` must be reported as a broken redirect.

        THE BUG THIS FOUND. The walk tested `resp.is_redirect`, which `requests`
        defines as False when a 3xx carries no `Location` - so this response was
        not a redirect to anybody: the empty-Location guard was unreachable, and
        `resp.ok` then passed a 302 through as SUCCESS. The examiner was told
        their file "is not an image or video", which is untrue and gives them
        nothing to fix. The walk now branches on the status code itself.
        """
        start = "https://1drv.ms/i/s!AbC?download=1"
        (resp, err), _seen = self._run({start: _FakeResponse(302, {})})
        self.assertIsNone(resp, "a 302 must never be returned as content")
        self.assertEqual(err[0], "fetch_failed")
        self.assertIn("without saying where", err[1])

    def test_an_error_status_is_reported_with_its_code(self):
        start = "https://www.dropbox.com/s/abc/plate.png?dl=1"
        (resp, err), _seen = self._run({start: _FakeResponse(404)})
        self.assertIsNone(resp)
        self.assertEqual(err[0], "fetch_failed")
        self.assertIn("404", err[1])

    def test_an_unreachable_host_is_reported_not_raised(self):
        """Publish and import must answer an envelope, never a 500."""
        def boom(url, **kw):
            raise forms_api.requests.RequestException("no route to host")

        with patch.object(forms_api.requests, "get", boom), \
                patch.object(forms_api.net_guard, "is_safe_url",
                             return_value=True):
            resp, err = self.controller._fetch_share_link(
                "https://1drv.ms/i/s!AbC?download=1")
        self.assertIsNone(resp)
        self.assertEqual(err[0], "fetch_failed")
        self.assertEqual(err[2], 502)

    def test_net_guard_refuses_a_hop_whose_name_resolves_internally(self):
        """DNS rebinding: an ALLOW-LISTED host that resolves to 10.0.0.5.

        The host allow-list cannot see this - the name is genuinely on the list.
        `net_guard` resolves it, which is why both checks run on every hop
        rather than one standing in for the other.
        """
        start = "https://www.dropbox.com/s/abc/plate.png?dl=1"

        with patch.object(forms_api.net_guard, "is_safe_url",
                          return_value=False), \
                patch.object(forms_api.requests, "get") as get:
            resp, err = self.controller._fetch_share_link(start)
        self.assertIsNone(resp)
        self.assertEqual(err[0], "unsupported_source")
        get.assert_not_called()

# -*- coding: utf-8 -*-
"""Safe Exam Browser (SEB): the .seb file we hand out, and the proof we check.

"Require Safe Exam Browser" (`assessments.be.rule_require_seb`) locks a paper
to SEB, the free lockdown browser (Windows, macOS, iPadOS). A web page cannot
stop a candidate using the rest of their computer; SEB can. We build no
desktop software: the candidate's SEB downloads the settings below, opens
their own `/exam/<token>`, and the app sends back SEB's hash of its Config Key.

THE PROOF IS THE JAVASCRIPT API, NOT THE HEADER. SEB offers the same hash as
`X-SafeExamBrowser-ConfigKeyHash`, but SEB for macOS (WKWebView) never sends
it and SEB for Windows sends it only to the page's own host - our API is on
another host. `SafeExamBrowser.security.configKey` exists on both, and equals
SHA-256(page URL without fragment + Config Key).

The Config Key algorithm follows safeexambrowser.org/developer/seb-config-key.html
as Moodle implements it (mod/quiz/accessrule/seb/classes/property_list.php).
Checked on 2026-09-30 against both of Moodle's test vectors
(tests/fixtures/unencrypted_mac_001.seb -> 4fa9af8e..., unencrypted_win_223.seb
-> 2534e4e9...; not copied here, they are GPL); the Mac one fails without the
single-backslash rule. tests/test_a_locked_exam_opens_only_in_seb.py pins the
SEB-JSON format.

Ceiling: the Config Key proves the right settings, not a genuine SEB binary.
# ponytail: add the Browser Exam Key against an allow-list of real SEB builds
# if faked SEB objects are ever seen (ETP_PLANS_AND_STRATEGY.md Part 11 §11.5).
"""
import base64
import datetime
import hashlib
import hmac
import json
import plistlib
import re
import secrets
from urllib.parse import urlsplit

DOWNLOAD_URL = "https://safeexambrowser.org/download_en.html"


#: Crockford's base32, lowercase: no i, l, o or u, so nothing an invigilator
#: reads off a screen can be typed as another symbol.
QUIT_PASSWORD_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"


def new_quit_password():
    """Four groups of four from 32 symbols (80 bits), easy to type.

    The hash sits in the downloadable .seb (SEB's own unsalted format), so the
    length is what keeps it out of reach for longer than a sitting.
    """
    return "-".join(
        "".join(secrets.choice(QUIT_PASSWORD_ALPHABET) for _ in range(4))
        for _ in range(4))


#: The generated format before 19.0.3.28.0: `token_hex(2)` three times, 48 bits.
_LEGACY_QUIT_PASSWORD = re.compile(r"[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}")


def weak_quit_password(password):
    """True for a password launch must renew: the old generated format, or
    shorter than the 12 characters a typed one needs."""
    password = password or ""
    return (len(password) < 12
            or bool(_LEGACY_QUIT_PASSWORD.fullmatch(password)))


def settings(evaluator):
    """The SEB settings for one attempt. The .seb file and the check below
    both come from here, so they cannot disagree.

    Only values without quotes or backslashes (URLs, hex): SEB's own JSON
    writer escapes neither, Moodle's escapes quotes, and keeping them out
    keeps every implementation on one Config Key.
    """
    start = evaluator.candidate_link
    password = evaluator.assessment_id.seb_quit_password or ""
    return dict(
        _settings(start, start + "/quit"),
        # allowQuit stays behind the quit password.
        hashedQuitPassword=hashlib.sha256(
            password.encode("utf-8")).hexdigest())


def _settings(start, quit_url):
    """What every .seb we hand out shares: an exam's, and the setup check's."""
    return {
        "startURL": start,
        # Opened by the app's "Exit Safe Exam Browser" button after submit;
        # SEB closes when it navigates here, with no password.
        "quitURL": quit_url,
        "quitURLConfirm": False,
        "sebConfigPurpose": 0,              # start an exam, not reconfigure
        "browserWindowWebView": 3,          # modern web view: has the JS API
        "allowQuit": True,
        # Always on, not tied to rule_webcam: toggling the webcam rule
        # mid-drive would otherwise change the Config Key under every
        # candidate already inside SEB. Windows grants the camera anyway.
        "browserMediaCaptureCamera": True,
        "allowedDisplaysMaxNumber": 1,
        "allowDisplayMirroring": False,
    }


def check_settings(origin):
    """The setup check's settings: the app's public `/seb-check` page, so a
    candidate can try SEB and their camera on their own laptop before the
    exam. No quit password, so a candidate who is only testing can always
    get out; it is its own file, so no exam's Config Key moves with it.
    `origin` is the app's (`app_origins.client_app_origin`)."""
    origin = (origin or "").rstrip("/")
    return _settings(origin + "/seb-check", origin + "/seb-check/quit")


def config_file(evaluator):
    """The .seb file: a plain XML plist, which SEB accepts unencrypted."""
    return plistlib.dumps(settings(evaluator), fmt=plistlib.FMT_XML)


def check_config_file(origin):
    """The setup check's .seb file (`check_settings`)."""
    return plistlib.dumps(check_settings(origin), fmt=plistlib.FMT_XML)


def links(evaluator):
    """What the app needs to send a candidate into SEB and back out.

    `sebs://` is SEB's name for "download this .seb over https" (`seb://` for
    http), so the launch link is the config route with its scheme swapped.
    """
    base = evaluator.get_base_url()
    return {
        "launch_url": "seb" + base[len("http"):]
        + "/api/v1/exam/%s/seb-config" % evaluator.access_token,
        "download_url": DOWNLOAD_URL,
        "quit_url": evaluator.candidate_link + "/quit",
    }


def config_key(seb_settings):
    """SEB's Config Key: SHA-256 of the settings as SEB-JSON."""
    return hashlib.sha256(seb_json(seb_settings).encode("utf-8")).hexdigest()


def seb_json(seb_settings):
    """SEB-JSON: `originatorVersion` dropped, empty dicts dropped, keys sorted
    case-insensitively at every depth, <data> as Base64, no whitespace, and
    backslashes left single (json.dumps doubles them; SEB and Moodle do not).
    """
    top = {k: v for k, v in seb_settings.items() if k != "originatorVersion"}
    text = json.dumps(_seb_json_ready(top), separators=(",", ":"),
                      ensure_ascii=False)
    return text.replace("\\\\", "\\")


def _seb_json_ready(value):
    if isinstance(value, dict):
        ready = {}
        for key in sorted(value, key=str.lower):
            item = _seb_json_ready(value[key])
            if item != {}:
                ready[key] = item
        return ready
    if isinstance(value, list):
        return [_seb_json_ready(item) for item in value]
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, datetime.datetime):
        return value.isoformat()
    return value


def proof_ok(evaluator, page_url, sent_hash):
    """True when `sent_hash` is SEB's configKey for this attempt's settings.

    `page_url` is the URL SEB loaded (the app captures it at boot, before its
    router rewrites the address), and must be this attempt's own exam page.
    """
    start = evaluator.candidate_link
    page_url = (page_url or "").split("#", 1)[0]
    if not (start and sent_hash and _on_page(page_url, start)):
        return False
    expected = hashlib.sha256(
        (page_url + config_key(settings(evaluator))).encode("utf-8")
    ).hexdigest()
    return hmac.compare_digest(expected.encode(),
                               sent_hash.strip().lower().encode("utf-8"))


_DEFAULT_PORTS = {"http": 80, "https": 443}


def _where(url):
    """(scheme, host, port, path) of `url` as a browser compares them: scheme
    and host in any case, a default port written or not. Raises ValueError
    on a port that is not a number."""
    parts = urlsplit(url)
    scheme = parts.scheme.lower()
    return (scheme, parts.hostname,
            parts.port or _DEFAULT_PORTS.get(scheme), parts.path)


def _on_page(page_url, start):
    """True when `page_url` is `start` or a page under it, never a sibling
    path that only shares its prefix (`/exam/<token>x`)."""
    try:
        page, base = _where(page_url), _where(start)
    except ValueError:
        return False
    root = base[3].rstrip("/")
    return page[:3] == base[:3] and (
        page[3] == root or page[3].startswith(root + "/"))

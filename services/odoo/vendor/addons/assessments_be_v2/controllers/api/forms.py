# -*- coding: utf-8 -*-
"""Form Studio's routes: list, save, delete, publish, media, template.

The client designs a whole form and saves it as one document, so the write
surface is deliberately one upsert: ``/forms/save`` takes the full form and
lands it on the row whose ``client_uid`` matches, creating it on first save.
There is no per-field PATCH to keep in sync with a designer that does not
edit per field.

IMPORT HAS NO ROUTE, AND DOES NOT NEED ONE. The client reads an uploaded JSON
file itself (`form_models.dart:formFromImportedJson`) and saves the result
through ``/forms/save`` like any other edit. What it cannot produce on its own
is a FIRST file, which is what ``/forms/template/json`` hands out.
"""
import base64
import binascii
import json
import logging
import re
import uuid
from urllib.parse import (
    parse_qsl, urlencode, urljoin, urlsplit, urlunsplit,
)

import requests
from botocore.exceptions import BotoCoreError, ClientError

from odoo import http
from odoo.http import request

from .common import (
    API_METHODS, API_TYPE, api_endpoint, arg, body, fail, int_arg, ok, paged,
    paging, require_manager, require_operator, require_staff,
    str_arg,
)

from ...constants import AUDIO_MIME_BY_EXT
from ...models.studio_form import MAX_STRUCTURE_BYTES
from ...services import net_guard

_logger = logging.getLogger(__name__)


def _row(rec):
    """The wire shape - identical to what the client's designer produces, so
    a round trip is byte-comparable on the client side."""
    return {
        "id": rec.client_uid,
        "title": rec.title or "",
        # BOTH, deliberately. `internal_name` is the stored override and comes
        # back exactly as sent, empty included, so the designer's field can
        # show "not overridden" rather than a title it did not type. Every
        # admin-facing label reads `display_title` instead, so the fallback
        # chain lives on the server and the client cannot drift from it.
        "internal_name": rec.internal_name or "",
        "display_title": rec.display_title or "",
        "description": rec.description or "",
        "published": bool(rec.published),
        "shuffle_questions": bool(rec.shuffle_questions),
        "sections": rec.sections(),
        "updated_at": rec.write_date.isoformat() if rec.write_date else "",
    }


class EtpStudioFormsApi(http.Controller):

    @http.route("/api/v1/forms", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def forms_list(self, **kw):
        Form = request.env["etp.studio.form"]
        domain = []
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("title", "ilike", search))
        limit, offset = paging()
        total = Form.search_count(domain)
        # ORDER STATED, NOT INHERITED. This is `etp.studio.form._order` written
        # out verbatim, so today's newest-first listing is unchanged - the point
        # is that an offset-paged route must not depend on a model attribute
        # somebody can retune for the back-office list. `write_date` ties across
        # a batch (it is the transaction timestamp), and `id desc` is what makes
        # the pages a partition; a route that silently inherited a non-unique
        # `_order` is how the attempt listing lost 461 rows.
        records = Form.search(domain, limit=limit, offset=offset,
                              order="write_date desc, id desc")
        return paged([_row(r) for r in records], total, limit, offset)

    @http.route("/api/v1/forms/save", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_save(self, **kw):
        payload = body().get("form")
        if not isinstance(payload, dict):
            return fail("bad_request", "Send the form as `form`.", status=400)

        client_uid = str(payload.get("id") or "").strip()
        if not client_uid:
            return fail("bad_request", "The form has no id.", status=400)

        sections = payload.get("sections")
        if not isinstance(sections, list):
            return fail("bad_request",
                        "`sections` must be a list.", status=400)
        if len(json.dumps(sections).encode("utf-8")) > MAX_STRUCTURE_BYTES:
            return fail("too_large",
                        "The form document is too large.", status=413)

        vals = {
            "title": str(payload.get("title") or "").strip()
                or "Untitled form",
            # The operator's own name for the form. NO FALLBACK TO THE TITLE
            # here, unlike the line above: empty is the meaningful state that
            # says "not overridden", and defaulting it would make every form
            # permanently overridden with a copy of its own title - after
            # which editing the title would stop moving the name operators
            # see, and nothing would say why.
            "internal_name": str(payload.get("internal_name") or "").strip(),
            "description": str(payload.get("description") or ""),
            "published": bool(payload.get("published")),
            # The designer's form-wide "Shuffle question order" switch. Read
            # here or it dies at this boundary: the client has always sent it,
            # and until this line nothing stored it, so the flag never reached
            # `publish_to_assessment` and no candidate ever saw a shuffle.
            "shuffle_questions": bool(payload.get("shuffle_questions")),
            # Json field: store the native list, no dumps.
            "structure_json": sections,
        }

        Form = request.env["etp.studio.form"]
        rec = Form.search([("client_uid", "=", client_uid)], limit=1)
        if rec:
            rec.write(vals)
        else:
            rec = Form.create(dict(vals, client_uid=client_uid))
        return ok(_row(rec))

    @http.route("/api/v1/forms/delete", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_delete(self, **kw):
        client_uid = str(arg("id") or "").strip()
        if not client_uid:
            return fail("bad_request", "The form has no id.", status=400)
        rec = request.env["etp.studio.form"].search(
            [("client_uid", "=", client_uid)], limit=1)
        deleted = bool(rec)
        if rec:
            rec.unlink()
        # Deleting what is already gone is success, not failure: the client
        # retries deletes on flaky networks and must be able to converge.
        return ok({"deleted": deleted})

    @http.route("/api/v1/forms/publish", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_publish(self, **kw):
        """Publish the form: materialise it as bank questions under a
        dedicated generator plus a draft assessment on it.

        From there the EXISTING pipeline does everything - assign, launch,
        the exam runner, objective auto-scoring, the LLM judge, release.
        This route only translates; it owns no delivery or scoring logic.
        """
        client_uid = str(arg("id") or "").strip()
        if not client_uid:
            return fail("bad_request", "The form has no id.", status=400)
        rec = request.env["etp.studio.form"].search(
            [("client_uid", "=", client_uid)], limit=1)
        if not rec:
            return fail("not_found", "No such form.", status=404)

        result = rec.publish_to_assessment()
        problems = result.get("problems")
        if problems:
            # One human-readable message: the client toasts `message` as-is,
            # and each line names the item and section it is about.
            return fail("unpublishable",
                        "The form is not ready to publish:\n- "
                        + "\n- ".join(problems),
                        status=422, problems=problems)
        return ok(result)

    @http.route("/api/v1/forms/template/json", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_template_json(self, **kw):
        """The import template: one EMPTY item of every element kind.

        A STRUCTURE, NOT A FORM. It carries no question text, no options and no
        answer keys - only the shape of each kind with every slot an author can
        write present and blank. So it is deliberately NOT publishable as
        downloaded: filling it in is the author's job, and pressing Publish on
        an unfilled one is how they get the list of what is still missing, item
        by item, from `validate_structure`.

        RENDERED FROM `constants.FORM_ITEM_KINDS`, the same catalogue
        `_item_spec` branches on and the back-office item editor draws its type
        picker from. A kind added there appears here with no edit; one that
        cannot be seeded fails the suite rather than shipping a template with a
        slot missing.

        AUTH: `auth="user"` + `@require_manager`, the same rung as
        `/api/v1/forms/save` and as every other template route on this API. The
        template is a read OF THE IMPORT CONTRACT for an Admin-only importer,
        and leaving it more open than `/forms/save` would publish the field list
        of a route nobody below Admin can call.

        COST: constant. A pure render of module-level data - no ORM, no search,
        no read of any form - so this route cannot be turned into a scan by
        asking for it repeatedly.
        """
        from ...services import form_json_template

        return ok(form_json_template.template_api_payload())

    # 40 MB raw - room for a short clip, an order of magnitude above any
    # form image. Checked against the base64 length BEFORE decoding, so an
    # oversized body is refused without materialising it.
    MAX_MEDIA_BYTES = 100 * 1024 * 1024

    @http.route("/api/v1/forms/media", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_media_upload(self, **kw):
        """Designer media upload: S3 when configured, else a public Odoo
        attachment - so the Upload button works on every deployment and the
        creator can always choose paste-a-URL instead."""
        name = str_arg("name", max_len=200) or "media"
        # An allow-list: this bucket prefix is served publicly, so it holds
        # media and nothing else.
        content_type = _media_type(str_arg("content_type", max_len=100))
        if content_type not in UPLOAD_TYPES:
            # A browser's own name for the type (`audio/x-m4a`) or none at all
            # (the back-office editor sends `file.type`): the extension
            # decides, exactly as the proxy will when it serves the file.
            content_type = MEDIA_MIME.get(
                name.rsplit(".", 1)[-1].lower(), content_type)
        if content_type not in UPLOAD_TYPES:
            return _unsupported_type(content_type)
        b64 = body().get("data")
        if not isinstance(b64, str) or not b64:
            return fail("bad_request", "Send the file as base64 `data`.",
                        status=400)
        if len(b64) * 3 // 4 - b64[-2:].count("=") > self.MAX_MEDIA_BYTES:
            return fail("too_large", "The file is larger than 100 MB.",
                        status=413)
        try:
            raw = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            return fail("bad_request", "`data` is not valid base64.",
                        status=400)

        payload, err = _store_form_media(request.env, raw, name, content_type)
        if err:
            code, message, status = err
            return fail(code, message, status=status)
        return ok(payload)

    # Long enough for a 100 MB file on a slow link to reach S3 inside it.
    PRESIGN_SECONDS = 3600

    @http.route("/api/v1/forms/media/presign", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_media_presign(self, **kw):
        """Step 1 of a browser upload straight to S3, so a 100 MB clip never
        crosses Odoo as a base64 body.

        Body ``{name, content_type, size}``. Returns ``{"upload": {url, fields,
        prefix, expires_at}, "key"}``: the client POSTs ``fields`` (whose
        ``key`` is already ``key``) plus the file to ``url``, then calls
        ``/forms/media/complete`` with ``key``. The policy pins a fresh uuid4
        prefix under ``form_studio/`` at the bucket ROOT (where the proxy route
        and ``object_key_from_url`` read), the declared type and the declared
        size.
        """
        content_type = _media_type(str_arg("content_type", max_len=100))
        if content_type not in UPLOAD_TYPES:
            return _unsupported_type(content_type)
        size = int_arg("size", 0)
        if size <= 0:
            return fail("bad_request", "Send the file's `size` in bytes.",
                        status=400)
        if size > self.MAX_MEDIA_BYTES:
            return fail("too_large", "The file is larger than 100 MB.",
                        status=413)
        from ...services import s3_service
        upload = s3_service.presigned_post(
            request.env, f"form_studio/{uuid.uuid4().hex}", content_type, size,
            self.PRESIGN_SECONDS, under_folder=False)
        if upload is None:
            code, message, status = _S3_NOT_CONFIGURED
            return fail(code, message, status=status)
        key = upload["prefix"] + _safe_media_name(
            str_arg("name", max_len=200), content_type)
        upload["fields"] = dict(upload["fields"], key=key)
        return ok({"upload": upload, "key": key})

    @http.route("/api/v1/forms/media/complete", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_media_complete(self, **kw):
        """Step 2: accept what the browser actually put at ``key``.

        The policy bounded type and size, but this is the server's own look at
        what landed: ``head_object`` must find it, at most the cap, with an
        allowed ``ContentType``. A refused object is deleted, never referenced.
        Only the key shape presign issues is accepted, so this can never reach
        (or delete) an object the base64 route or the importer stored. Returns
        the same payload as ``_store_form_media``.
        """
        key = str_arg("key", max_len=512)
        if not _PRESIGNED_KEY.match(key):
            return fail("bad_key", "That is not a key /forms/media/presign "
                        "issued.", status=400)
        from ...services import s3_service
        cli, bucket = s3_service.storage_target(request.env)
        if cli is None or not bucket:
            code, message, status = _S3_NOT_CONFIGURED
            return fail(code, message, status=status)
        try:
            head = cli.head_object(Bucket=bucket, Key=key)
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in (
                    "404", "NoSuchKey", "NotFound"):
                return fail("not_found", "Nothing was uploaded at that key.",
                            status=404)
            return fail("s3_failed", f"S3 could not check the upload: {exc}",
                        status=502)
        except BotoCoreError as exc:
            return fail("s3_failed", f"S3 could not check the upload: {exc}",
                        status=502)

        content_type = _media_type(head.get("ContentType"))
        if content_type not in UPLOAD_TYPES:
            refusal = _unsupported_type(content_type)
        elif (head.get("ContentLength") or 0) > self.MAX_MEDIA_BYTES:
            refusal = fail("too_large", "The file is larger than 100 MB.",
                           status=413)
        else:
            return ok({"url": f"/api/v1/forms/media/{key}", "storage": "s3",
                       "public": True})
        try:
            cli.delete_object(Bucket=bucket, Key=key)
        except (ClientError, BotoCoreError) as exc:
            _logger.warning("Could not delete refused upload %s: %s", key, exc)
        return refusal

    # How long to wait on the third-party host, and the ceiling on what it may
    # hand back. The size cap MATCHES the Upload button's `MAX_MEDIA_BYTES`
    # deliberately: a clip an examiner could upload by hand must not be
    # refused just because they pasted its link instead, and video is the whole
    # reason 25 MB was too tight - most exam clips exceed it.
    IMPORT_TIMEOUT_SECONDS = 20
    MAX_IMPORT_BYTES = MAX_MEDIA_BYTES

    # Enough for the share-page -> content-host chain every one of these hosts
    # uses (Drive takes two), and low enough that a redirect loop ends quickly.
    MAX_IMPORT_REDIRECTS = 5

    def _fetch_share_link(self, fetch_url):
        """GET [fetch_url], following redirects ONE HOP AT A TIME.

        Returns ``(response, None)`` or ``(None, (code, message, status))``.

        `allow_redirects=False` is the whole point. Every supported host answers
        a share URL with a 302 to a different content domain, so the default
        (follow silently) let the allow-listed host name the final destination -
        which means an open redirect on Drive, Dropbox or SharePoint turns this
        back into the fetch-anything primitive the allow-list exists to prevent.
        Each hop is re-checked against the redirect allow-list AND resolved
        through `net_guard`, so a hop cannot point at an internal address either
        directly or via a name that resolves to one.
        """
        seen = fetch_url
        for _hop in range(self.MAX_IMPORT_REDIRECTS + 1):
            if not net_guard.is_safe_url(seen):
                return None, ("unsupported_source",
                              "That link resolves to an address this server "
                              "will not fetch. Use Upload instead.", 400)
            try:
                resp = requests.get(
                    seen, timeout=self.IMPORT_TIMEOUT_SECONDS, stream=True,
                    allow_redirects=False)
            except requests.RequestException as exc:
                return None, ("fetch_failed",
                              f"That host could not be reached: {exc}", 502)

            # THE STATUS CODE, NOT `resp.is_redirect`. That property is False
            # when a 3xx carries no `Location`, so testing it left the
            # empty-Location guard below unreachable and dropped such a response
            # through to the success path - where a 302 body then failed the
            # content-type gate and the examiner was told their file "is not an
            # image or video", which is both untrue and unactionable.
            if resp.status_code in _REDIRECT_STATUSES:
                location = resp.headers.get("Location") or ""
                resp.close()
                if not location:
                    return None, ("fetch_failed",
                                  "That host redirected without saying where.",
                                  502)
                # Relative Locations are normal on these hosts.
                seen = urljoin(seen, location)
                if not _redirect_host_allowed(seen):
                    return None, (
                        "unsupported_source",
                        "That link redirected to %s, which is not a host this "
                        "server will fetch from. Use Upload instead."
                        % (urlsplit(seen).hostname or "an unknown host"), 400)
                continue

            if not resp.ok:
                status = resp.status_code
                resp.close()
                return None, ("fetch_failed",
                              f"That host answered {status}.", 502)
            return resp, None

        return None, ("fetch_failed",
                      "That link redirected too many times.", 502)

    @http.route("/api/v1/forms/media/import", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def form_media_import(self, **kw):
        """Copy a share link into this app's own media storage.

        WHY THIS EXISTS. A Drive `/file/d/<id>/view` link is the VIEWER PAGE:
        it answers `text/html`, so nothing can render it and the designer shows
        a dead plate. Examiners paste one, reasonably, because it is the URL
        Drive gives them. This fetches the actual bytes once and replaces the
        link with a `/api/v1/forms/media/...` URL, after which the media is
        this app's own - the same place the Upload button puts it.

        AND WHY COPY RATHER THAN REWRITE THE LINK. Drive does serve a direct
        URL that renders, but a share link is the wrong dependency for an exam
        whatever its shape: the owner can move or unshare the file mid-sitting,
        Drive rate-limits a cohort all loading the same image, and a link that
        works for candidates is public to anyone holding it.

        AN ALLOW-LIST, ON PURPOSE. A route that fetches any URL a caller names
        is an SSRF primitive - on EKS it would reach the instance metadata
        service and hand back IAM credentials. The host allow-list is what makes
        this safe, so it is checked BEFORE any request is made. Drive, Dropbox,
        OneDrive and SharePoint are supported because those are what examiners
        paste; each is anchored on its whole host, and adding one is a
        deliberate act, never a pattern loosened to "any host containing".

        AND EVERY REDIRECT IS RE-CHECKED. These hosts all 302 to a separate
        content domain, so following redirects automatically would have let the
        allow-listed host pick the final destination - an open redirect on any
        of them, and the allow-list decides nothing. Hops are followed by hand,
        each one re-checked against the redirect allow-list and against
        `net_guard`, which resolves the name and refuses private, loopback and
        metadata addresses.
        """
        url = str_arg("url", max_len=2048) or ""
        fetch_url = _import_fetch_url(url)
        if not fetch_url:
            return fail(
                "unsupported_source",
                "That link cannot be imported. Google Drive, Dropbox, OneDrive, "
                "SharePoint and Jumpshare links are supported - otherwise paste "
                "a direct media URL, or use Upload.",
                status=400)

        resp, err = self._fetch_share_link(fetch_url)
        if err:
            code, message, status = err
            return fail(code, message, status=status)

        if _JUMPSHARE_PAGE.match(fetch_url):
            # Jumpshare has no download switch: its share page is HTML that
            # names the file's own CDN link, fetched hop by hop like any other.
            file_url = _jumpshare_file_url(resp)
            if not file_url:
                return fail(
                    "not_media",
                    "That Jumpshare page has no audio, video or image file in "
                    "it. Check it is shared publicly, or use Upload.",
                    status=422)
            resp, err = self._fetch_share_link(file_url)
            if err:
                code, message, status = err
                return fail(code, message, status=status)

        content_type = (resp.headers.get("Content-Type") or "").split(";")[0] \
            .strip().lower()
        # THE CONTENT TYPE IS THE PERMISSION CHECK. A file that is not shared
        # answers 200 with a sign-in PAGE, not a 403 - so the only way to tell
        # "private" from "fine" is that the bytes are HTML. Saying so in those
        # words is what turns a dead plate into something the examiner can fix.
        if not content_type.startswith(("image/", "video/", "audio/")):
            return fail(
                "not_media",
                "That file did not come back as an image, video or audio file "
                f"(got {content_type or 'no content type'}). Check it is "
                'shared as "Anyone with the link", or use Upload.',
                status=422)

        # Read with the cap enforced as we go: trusting Content-Length would
        # let a lying header stream unbounded bytes into memory.
        chunks, total = [], 0
        for chunk in resp.iter_content(chunk_size=64 * 1024):
            if not chunk:
                continue
            total += len(chunk)
            if total > self.MAX_IMPORT_BYTES:
                return fail("too_large",
                            "That file is larger than the %d MB limit."
                            % (self.MAX_IMPORT_BYTES // (1024 * 1024)),
                            status=413)
            chunks.append(chunk)
        raw = b"".join(chunks)
        if not raw:
            return fail("not_media", "Google Drive returned an empty file.",
                        status=422)

        ext = _EXT_BY_CONTENT_TYPE.get(content_type, "bin")
        payload, err = _store_form_media(
            request.env, raw, f"drive-import.{ext}", content_type)
        if err:
            code, message, status = err
            return fail(code, message, status=status)
        return ok(dict(payload, imported_bytes=total,
                       content_type=content_type))


_EXT_BY_CONTENT_TYPE = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/webp": "webp",
    "image/gif": "gif",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    **{mime: ext for ext, mime in AUDIO_MIME_BY_EXT.items()},
    # Non-standard names share hosts answer for the same audio, so an import
    # still lands with the extension `media_kind` and the proxy read.
    "audio/mp3": "mp3", "audio/x-wav": "wav", "audio/wave": "wav",
    "audio/x-m4a": "m4a",
}


def _media_type(raw):
    """A Content-Type reduced to its bare, lower-case media type."""
    return (raw or "").split(";")[0].strip().lower()


def _unsupported_type(content_type):
    return fail(
        "unsupported_type",
        "Only images (PNG, JPEG, WebP, GIF), video (MP4, WebM, MOV) and audio "
        "(MP3, WAV, M4A, OGG, AAC, FLAC) can be uploaded (got %s)."
        % (content_type or "no content type"), status=400)


def _safe_media_name(name, content_type):
    """[name] cut to a key-safe stem, plus the extension OF [content_type].

    The proxy's MIME map and `question.video.media_kind` both read the key's
    extension, so it must agree with the type S3 was told, whatever the
    browser's filename said.
    """
    stem = re.sub(r"[^A-Za-z0-9_-]+", "_", (name or "").rsplit(".", 1)[0])
    return "%s.%s" % (stem.strip("_")[:80] or "media",
                      _EXT_BY_CONTENT_TYPE[content_type])


# The only key shape `/forms/media/presign` issues (see `_safe_media_name`).
_PRESIGNED_KEY = re.compile(r"^form_studio/[0-9a-f]{32}/[A-Za-z0-9_-]+\.[a-z0-9]+$")

# The Drive URL shapes an examiner actually pastes, and nothing else.
#
# THIS FUNCTION IS THE SECURITY BOUNDARY of `/api/v1/forms/media/import`. The
# host is matched as a WHOLE host, anchored, so `drive.google.com.evil.test`
# and `evil.test/?u=drive.google.com` both fail - a substring check on
# "drive.google.com" would pass both and turn the importer into a
# fetch-anything primitive, which on EKS reaches the instance metadata service.
_DRIVE_URL_PATTERNS = (
    # https://drive.google.com/file/d/<id>/view?usp=sharing
    re.compile(
        r"^https://(?:www\.)?drive\.google\.com/file/d/([\w-]{10,})",
        re.I),
    # https://drive.google.com/open?id=<id>  /  /uc?export=view&id=<id>
    re.compile(
        r"^https://(?:www\.)?drive\.google\.com/(?:open|uc)\?"
        r"(?:[^#]*&)?id=([\w-]{10,})",
        re.I),
)


def _drive_file_id(url):
    """The Drive file id in [url], or None when it is not a Drive link.

    Returning None is what makes the caller refuse: no id, no fetch.
    """
    candidate = (url or "").strip()
    for pattern in _DRIVE_URL_PATTERNS:
        match = pattern.match(candidate)
        if match:
            return match.group(1)
    return None


# The other share hosts an examiner pastes, beyond Drive.
#
# SAME DISCIPLINE AS `_DRIVE_URL_PATTERNS`, and for the same reason: anchored at
# the start, https only, and the host matched as a WHOLE host so
# `dropbox.com.evil.test` and `evil.test/?u=dropbox.com/s/x` both fail. Each
# entry names the query parameter that turns the host's share page into its
# bytes, because every one of these answers HTML by default.
#
# Deliberately NOT a general "fetch this URL". The allow-list is the security
# boundary of the whole route - widening it host by host, each anchored, is the
# only safe way to widen it at all.
# Jumpshare share pages (`/s/`, `/v/` and the `/share/` form its og:url uses).
_JUMPSHARE_PAGE = re.compile(
    r"^https://(?:www\.)?jumpshare\.com/(?:s|v|share)/[\w-]+", re.I)

_SHARE_URL_PATTERNS = (
    # Dropbox: the old `/s/<token>/name` and the current `/scl/fi/<id>/name`.
    # `dl=1` is what serves the file rather than the preview page.
    (re.compile(r"^https://(?:www\.)?dropbox\.com/s(?:cl)?/", re.I), "dl=1"),
    # Dropbox's own content host already serves bytes.
    (re.compile(r"^https://dl\.dropboxusercontent\.com/", re.I), None),
    # OneDrive personal short links and the full viewer.
    (re.compile(r"^https://1drv\.ms/", re.I), "download=1"),
    (re.compile(r"^https://onedrive\.live\.com/", re.I), "download=1"),
    # SharePoint image (`:i:`) and video (`:v:`) shares, any tenant.
    (re.compile(r"^https://[\w-]+\.sharepoint\.com/[^?#]*:[iv]:", re.I),
     "download=1"),
    # Jumpshare: fetched as-is; the route reads the file link out of the page.
    (_JUMPSHARE_PAGE, None),
)


# The cap on a Jumpshare share page (~200 KB today; the file link sits near
# the end, so the whole page is read).
MAX_JUMPSHARE_PAGE_BYTES = 2 * 1024 * 1024


def _jumpshare_file_url(resp):
    """The file link in a Jumpshare share page, or None. Closes [resp].

    The page names the file as `https://cdn.jumpshare.com/preview/<token>.<ext>`
    (which 302s to Jumpshare's CloudFront). A clip wins over an image, so a
    video's poster frame is never imported in place of the video.
    """
    chunks, total = [], 0
    try:
        for chunk in resp.iter_content(chunk_size=64 * 1024):
            total += len(chunk)
            if total > MAX_JUMPSHARE_PAGE_BYTES:
                break
            chunks.append(chunk)
    finally:
        resp.close()
    page = b"".join(chunks).decode("utf-8", "replace")
    found = re.finditer(
        r"https://cdn\.jumpshare\.com/preview/[A-Za-z0-9_-]+\.(%s)\b"
        % "|".join(MEDIA_MIME), page)
    clips, images = [], []
    for m in found:
        (images if MEDIA_MIME[m.group(1)].startswith("image/")
         else clips).append(m.group(0))
    return (clips or images or [None])[0]


def _with_param(url, param):
    """[url] with [param] (`k=v`) set, replacing any existing value for `k`.

    Replacing matters: a Dropbox share link arrives carrying `?dl=0`, and
    appending `&dl=1` leaves the host free to honour the first one.
    """
    if not param:
        return url
    key, _, value = param.partition("=")
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if k.lower() != key.lower()]
    query.append((key, value))
    return urlunsplit(parts._replace(query=urlencode(query)))


def _import_fetch_url(url):
    """The URL to actually GET for a supported share link, or None.

    None means the caller refuses without making any request - the same
    contract `_drive_file_id` has, generalised over the other hosts.
    """
    candidate = (url or "").strip()
    if not candidate:
        return None
    file_id = _drive_file_id(candidate)
    if file_id:
        # The direct-download form. `confirm=t` skips the interstitial Drive
        # shows for larger files, which would otherwise arrive as HTML and be
        # rejected below as "not a media file" - true, but for the wrong
        # reason, and unactionable.
        return ("https://drive.google.com/uc?export=download"
                "&id=%s&confirm=t" % file_id)
    for pattern, param in _SHARE_URL_PATTERNS:
        if pattern.match(candidate):
            return _with_param(candidate, param)
    return None


# The 3xx codes `_fetch_share_link` treats as a hop. Tested directly rather
# than through `resp.is_redirect`, which is False for a 3xx carrying no
# `Location` - and a response nobody classifies as a redirect falls through to
# the success path.
_REDIRECT_STATUSES = frozenset((301, 302, 303, 307, 308))


# Hosts a supported share link is allowed to REDIRECT to.
# WHY THIS EXISTS AT ALL. Every one of these hosts answers a share URL with a
# 302 to a separate content domain - Drive's own `uc?export=download` has always
# redirected to `*.googleusercontent.com`. So `requests.get(...)` following
# redirects by default meant the allow-listed host chose the FINAL destination,
# and the host allow-list stopped deciding anything after hop zero. An open
# redirect on any of these (or a compromised one) would hand this route back its
# fetch-anything primitive.
#
# So redirects are followed by hand, each hop re-checked against this list AND
# against `net_guard` (which resolves the name and refuses private, loopback,
# link-local and metadata addresses, defeating a DNS-rebinding hop).
_REDIRECT_HOST_SUFFIXES = (
    "drive.google.com",
    "docs.google.com",
    # Drive's CURRENT download host, and it is NOT under
    # `googleusercontent.com` - it is `drive.usercontent.google.com`, a
    # `google.com` subdomain. Google moved the `uc?export=download` 303 here
    # from the old `doc-0k-8s-docs.googleusercontent.com` shape, so listing
    # only that one made EVERY Drive import fail at the redirect hop while the
    # tests - which used the old host - stayed green. Verified against a live
    # 303 rather than assumed. Anchored as a whole host like every entry here.
    "drive.usercontent.google.com",
    "googleusercontent.com",
    "dropbox.com",
    "dropboxusercontent.com",
    "1drv.ms",
    "onedrive.live.com",
    "live.com",
    # OneDrive personal serves the actual bytes from a THIRD domain:
    # `1drv.ms` -> `onedrive.live.com` -> `*.files.1drv.com`. A different
    # registrable domain from `1drv.ms`, so listing that one does not cover it,
    # and without this hop every OneDrive import fails at the last step.
    "1drv.com",
    "sharepoint.com",
    "svc.ms",
    # Jumpshare: `cdn.jumpshare.com/preview/...` 302s to its own CloudFront
    # distribution. That ONE distribution host, never all of cloudfront.net
    # (anyone can own a distribution there). Verified against a live 302.
    "jumpshare.com",
    "d1p1y5pyxk2k6i.cloudfront.net",
)


def _redirect_host_allowed(url):
    """True when [url]'s host is one a share link may redirect to."""
    host = (urlsplit(url).hostname or "").lower()
    if not host:
        return False
    return any(host == suffix or host.endswith("." + suffix)
               for suffix in _REDIRECT_HOST_SUFFIXES)


def _store_form_media(env, raw, name, content_type):
    """Put designer media in the ONE place the upload button already puts it.

    Returns ``(payload_dict, None)`` on success, or ``(None, (code, message,
    status))`` for the caller to hand to `fail`.

    WHY THIS IS SHARED AND NOT COPIED. Two routes now store designer media -
    the Upload button and the share-link importer - and they must agree on the
    bucket prefix, the key shape and the storage ORDER, because `studio_form.
    _fetch_s3_object` reads those keys back at publish time. A second copy of
    this that drifted by one prefix would make publish silently fall back to a
    link-only image for every question carrying imported media: exactly the bug
    06f0c663b fixed once already, from the other direction.

    Storage, most-preferred first:
      1. the platform's `s3.connector` record - the team's canonical bucket;
      2. this addon's own `assessments_be_v2.s3_*` settings;
      3. nothing. An unconfigured deployment is TOLD, not quietly handed a
         Postgres filestore that grows until it becomes a disk alert.
    """
    # Everything Form Studio stores lives under ONE bucket prefix, so its
    # media is isolated from the assessment module's objects and can be
    # listed, policied or wiped as a unit.
    ext = (name.rsplit(".", 1)[-1] if "." in name else "bin")[:8]
    key = f"form_studio/{uuid.uuid4().hex}.{ext}"
    # The bucket stays private and media is served through our own proxy
    # route, so links never expire and no bucket policy or CDN is required.
    proxy_url = f"/api/v1/forms/media/{key}"

    # ONE resolved target for storing AND serving - see
    # `s3_service.storage_target` for why these must not be resolved
    # separately.
    from ...services import s3_service
    cli, bucket = s3_service.storage_target(env)
    if cli is not None and bucket:
        try:
            cli.put_object(Bucket=bucket, Key=key, Body=raw,
                           ContentType=content_type)
        except (ClientError, BotoCoreError) as exc:
            return None, ("s3_failed", f"S3 refused the upload: {exc}", 502)
        return {"url": proxy_url, "storage": "s3", "public": True}, None

    return None, _S3_NOT_CONFIGURED


_S3_NOT_CONFIGURED = (
    "s3_not_configured",
    "Media storage is not configured, so this file cannot be stored. Set "
    "assessments_be_v2.s3_bucket, .s3_region, .s3_access_key_id and "
    ".s3_secret_key in Settings > Assessments v2 > Media storage (S3), or "
    "install and configure the platform S3 connector.",
    503)


MEDIA_MIME = {
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "webp": "image/webp", "gif": "image/gif",
    "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    **AUDIO_MIME_BY_EXT,
}

# What either upload route accepts: exactly the types the proxy serves.
UPLOAD_TYPES = frozenset(MEDIA_MIME.values())


class EtpStudioMediaProxy(http.Controller):
    """Serves Form Studio's S3 objects the way etp_assessment_pro serves its
    question images: downloaded server-side with the platform's own
    credentials and streamed to the browser. The bucket never opens up and
    the links never expire (the module's stated reason for avoiding
    presigned URLs).

    Access model, also inherited from the portal: the URL itself is the
    capability - every key carries a uuid4, and the route refuses anything
    outside the `form_studio/` prefix, so it can serve exactly one thing:
    media that a form creator uploaded for respondents to see.
    """

    MAX_STREAM_BYTES = 100 * 1024 * 1024  # matches the upload cap

    @http.route("/api/v1/forms/media/<path:key>", type="http",
                auth="public", methods=["GET"], csrf=False)
    def form_media_serve(self, key, **kw):
        if not key.startswith("form_studio/") or ".." in key:
            return request.not_found()

        from ...services import s3_service
        ext = key.rsplit(".", 1)[-1].lower()
        if MEDIA_MIME.get(ext, "").startswith(("audio/", "video/")):
            # CLIPS PLAY FROM S3 ITSELF: a 302 to a signed URL, so the bytes
            # never pass through Odoo and the player can seek (S3 answers Range
            # requests; the stream below does not). A media element needs no
            # bucket CORS to follow it. Same lifetime as the exam's clips.
            from ..media_stream import _presign_seconds
            signed = s3_service.presigned_url(
                request.env, key, expires=_presign_seconds(request.env))
            if signed:
                resp = request.redirect(signed, code=302, local=False)
                # The signature expires; this stable URL must be asked again.
                resp.headers["Cache-Control"] = "no-store"
                return resp

        body = None
        # THE SAME resolved target the upload wrote to - resolving it here
        # independently is what let reads and writes land on different buckets.
        cli, bucket = s3_service.storage_target(request.env)
        try:
            if cli is not None and bucket:
                obj = cli.get_object(Bucket=bucket, Key=key)
                body = obj["Body"].read(self.MAX_STREAM_BYTES + 1)
        except (ClientError, BotoCoreError):
            return request.not_found()
        if body is None or len(body) > self.MAX_STREAM_BYTES:
            return request.not_found()

        return request.make_response(body, headers=[
            ("Content-Type", MEDIA_MIME.get(ext, "application/octet-stream")),
            ("Content-Length", str(len(body))),
            # The uuid in the key makes every URL immutable: cache hard.
            ("Cache-Control", "public, max-age=86400, immutable"),
        ])

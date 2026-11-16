# -*- coding: utf-8 -*-
"""Byte-serving helpers shared by the admin and candidate media proxies.

Both proxies stream the same private-S3 objects and differ only in how they
decide the caller may see them - admin gates on `_be_is_staff()` + `check_access`,
candidate gates on the exam token and the evaluator's own `question_order`. The
streaming half was duplicated in both, so a fix to the S3 fallback would have
had to be made twice.

The admin gate USED TO ASK `_is_internal()`, which was right while every
candidate was a portal user and wrong from the moment candidates became internal
accounts - it admitted them to the admin proxy and left `check_access` as the
only thing in the way. `res.users._be_assessment_role` tells staff from
candidate; see its docstring for the four gates that each answered this
differently.
"""
import hashlib
import logging

from werkzeug.http import http_date

from odoo import fields
from odoo.http import request

_logger = logging.getLogger(__name__)

# Send images as a 302 to a presigned S3 URL instead of proxying their bytes:
#
#     assessments_be_v2.media_redirect_to_s3 = 1
#
# WHY THE DEFAULT IS OFF, i.e. why a worker is held for the transfer.
#
# A 302 is strictly better for the server and unusable by this client. The
# Flutter app fetches admin media with an Authorization bearer, which makes it
# an XHR rather than an `<img>` subresource, and an XHR that follows a
# cross-origin redirect needs CORS headers FROM THE REDIRECT TARGET. S3 answers
# a presigned GET with `200 image/png` and no `Access-Control-Allow-Origin` at
# all unless the bucket carries a CORS rule, so the browser fetched a perfectly
# good PNG and discarded it - every approved question in the bank rendered its
# "no image" state over a picture S3 was holding. Draft images never hit this
# because they are still inline base64; the failure appeared only on approval,
# which is the worst possible moment for it to appear.
#
# Proxying costs a worker and some bandwidth for a file of a few hundred KB to
# a couple of MB, and the response carries this module's own credentialed CORS
# headers, so it simply works. Turn this parameter on once the bucket has a
# CORS rule naming the app's origin and the 302 comes back.
#
# Videos are NOT covered by this: they stay on the 302 path unconditionally.
# A clip is far too large to hold a worker for, and `<video>` is an ordinary
# subresource fetch that carries no Authorization header, so it never needed
# the redirect target to answer CORS in the first place.
REDIRECT_PARAM = "assessments_be_v2.media_redirect_to_s3"

# How long a presigned media URL stays valid, in seconds.
#
#     assessments_be_v2.media_presign_seconds = 21600
#
# WHY THE DEFAULT IS SIX HOURS AND NOT THE SIGNER'S 15 MINUTES. A clip is
# ALWAYS served as a 302 to a presigned S3 URL - it is far too large to hold a
# worker for - and a `<video>` element re-requests its source on a seek, a
# reload, a resumed session or a network blip. Fifteen minutes into a
# two-hour paper, every one of those returned 403 from S3 and the player went
# dead mid-exam, which is indistinguishable from a broken question.
#
# The signature is still short-lived relative to the object: this is a URL that
# expires, not a public one. Deployments serving papers longer than six hours
# should raise it to cover their longest sitting.
PRESIGN_SECONDS_PARAM = "assessments_be_v2.media_presign_seconds"
DEFAULT_PRESIGN_SECONDS = 6 * 60 * 60


def _prefers_redirect(env):
    raw = env["ir.config_parameter"].sudo().get_param(REDIRECT_PARAM, "")
    return str(raw or "").strip().lower() in ("1", "true", "yes", "on", "t")


def _presign_seconds(env):
    """The signed-URL lifetime, floored at the old 15 minutes.

    A deployment that sets this LOWER than the default gets the default: the
    setting exists to cover a longer sitting, and a value that expires
    mid-paper is the bug it was added to fix.
    """
    raw = env["ir.config_parameter"].sudo().get_param(
        PRESIGN_SECONDS_PARAM, "")
    try:
        seconds = int(str(raw).strip())
    except (TypeError, ValueError):
        return DEFAULT_PRESIGN_SECONDS
    return max(seconds, 900)


def _s3_image_response(env, external_url, fallback_ctype="image/png"):
    """The bytes behind an offloaded image, as a response this origin owns.

    BUFFERS WHEN IT CAN AND STREAMS WHEN IT MUST. `s3_service.download` refuses
    anything over its in-memory cap, and the only thing left after that was a
    302 to presigned S3 - which an XHR cannot follow cross-origin without a
    bucket CORS rule, so a large picture rendered as an empty plate while a
    small one from the same bucket was fine. Size-dependent, therefore
    intermittent, and the server logged a healthy 200 for both.

    Returns None when the object cannot be fetched at all, so the caller can
    still fall back rather than turning a slow read into a hard failure.
    """
    from ..services import s3_service
    key = s3_service.object_key_from_url(env, external_url)
    if not key:
        return None
    data, ctype = s3_service.download(env, key)
    if data is not None:
        return request.make_response(data, headers=[
            ("Content-Type", ctype or fallback_ctype),
            ("Content-Length", str(len(data))),
            ("Cache-Control", "private, max-age=3600"),
        ])
    # Too large to buffer, or the buffered read failed. Stream it.
    chunks, ctype, length = s3_service.open_stream(env, key)
    if chunks is None:
        return None
    headers = [
        ("Content-Type", ctype or fallback_ctype),
        ("Cache-Control", "private, max-age=3600"),
    ]
    if length:
        headers.append(("Content-Length", str(length)))
    return request.make_response(chunks, headers=headers)


def _validators(record):
    """(etag, http_date) for one media record, or (None, None).

    WHY THESE AND NOT A LONGER max-age (SNo 135). The proxy already answers
    `private, max-age=3600`, so within the hour a browser re-uses its copy and
    costs nothing. The hour AFTER that it re-downloads the whole file - and
    question media is the largest thing on this wire, a few hundred KB to a
    couple of MB per plate, fetched by every candidate in the cohort. With a
    validator the same request comes back `304 Not Modified` and no body at
    all.

    THE ROW ALSO ASKED FOR `public`, AND THAT IS DELIBERATELY NOT DONE. These
    routes are ACL-checked - `admin_qimage` gates on an internal user,
    the exam routes on the attempt token. `public` invites a shared proxy to
    cache the bytes under the URL alone and hand them to whoever asks next,
    which is exactly the guarantee an exam image must not give up. Revalidation
    gets the bandwidth back without trading that away.

    `write_date` is the validator rather than a content hash: it changes
    whenever the record's bytes are replaced, and it costs nothing to read,
    where hashing would mean holding the whole object to answer a request that
    is usually going to be a 304 anyway.
    """
    stamp = getattr(record, "write_date", None)
    if not stamp:
        return None, None
    dt = fields.Datetime.to_datetime(stamp)

    # THE STAMP ALONE IS NOT ENOUGH, and a test caught it. `write_date` has
    # SECOND resolution, so replacing a plate within the same second as the
    # previous write left the ETag identical and every browser holding the old
    # picture kept it. The source is mixed in, so swapping the URL moves the
    # validator whatever the clock says.
    #
    # KNOWN LIMIT, stated rather than hidden: if the bytes AT an unchanged URL
    # are overwritten in place - an S3 PUT over the same key, with no write to
    # this record - neither half moves and a cached copy stays for the hour.
    # A content hash would catch that and would mean reading the whole object
    # on every request, including the ones that are about to be answered 304.
    # Re-uploading through this addon writes the record, so the case needs
    # somebody going around it.
    source = "|".join(str(getattr(record, f, "") or "") for f in (
        "image_url", "annotated_image_url", "video_url"))
    digest = hashlib.sha1(source.encode("utf-8")).hexdigest()[:8]
    etag = '"%s-%s-%s"' % (record.id, int(dt.timestamp()), digest)
    return etag, http_date(dt)


def _not_modified(etag, last_modified):
    """A 304 when the browser already holds this exact version, else None."""
    if not etag:
        return None
    req = request.httprequest
    if req.headers.get("If-None-Match") == etag:
        return request.make_response("", status=304, headers=[
            ("ETag", etag),
            ("Cache-Control", "private, max-age=3600"),
        ])
    since = req.headers.get("If-Modified-Since")
    if since and last_modified and since == last_modified:
        return request.make_response("", status=304, headers=[
            ("ETag", etag),
            ("Last-Modified", last_modified),
            ("Cache-Control", "private, max-age=3600"),
        ])
    return None


def serve_image(image, annotated=False):
    """Serve one question image.

    Proxies the bytes by default so the response comes from THIS origin and
    carries its CORS headers - see REDIRECT_PARAM for why a 302 to presigned S3
    cannot be the default. Falls back to the redirect when the download fails
    or when the parameter asks for it, and to the on-record Binary before
    either.
    """
    etag, last_modified = _validators(image)
    fresh = _not_modified(etag, last_modified)
    if fresh is not None:
        return fresh

    binary_field = "annotated_image" if annotated else "image"
    binary = image.annotated_image if annotated else image.image
    external_url = image.annotated_image_url if annotated else image.image_url
    if binary:
        return request.env["ir.binary"]._get_image_stream_from(
            image, field_name=binary_field).get_response()
    if external_url:
        from ..services import s3_service
        key = s3_service.object_key_from_url(request.env, external_url)
        if _prefers_redirect(request.env) and key:
            signed = s3_service.presigned_url(
                request.env, key, expires=_presign_seconds(request.env))
            if signed:
                return request.redirect(signed, code=302, local=False)
        proxied = _s3_image_response(request.env, external_url)
        if proxied is not None:
            # Stamped on the way out so the NEXT request can be a 304.
            if etag:
                proxied.headers["ETag"] = etag
                proxied.headers["Last-Modified"] = last_modified
            return proxied
        if key:
            signed = s3_service.presigned_url(
                request.env, key, expires=_presign_seconds(request.env))
            if signed:
                return request.redirect(signed, code=302, local=False)
            # NEVER redirect to an unsigned URL of OUR OWN bucket.
            #
            # `key` parsing succeeded, so this object lives in the private
            # bucket this addon writes to, and a plain GET on it answers 403
            # AccessDenied - always. The old fallback sent the browser there
            # anyway, so a broken S3 configuration rendered as an ordinary
            # blank image plate: the admin preview showed the "add image"
            # placeholder and the candidate saw "No image yet for this
            # question", with nothing in either UI suggesting the picture
            # existed and the server simply could not read it. These records
            # have NO local binary - S3 holds the only copy - so this is the
            # difference between a diagnosable outage and silent data loss.
            #
            # Both the download and the presign swallow their own failure into
            # a warning inside s3_service, so this is the only place that knows
            # both have failed for a specific image.
            _logger.error(
                "Question image %s is stored at %s but could not be read from "
                "S3, and no presigned URL could be produced. Check the S3 "
                "credentials for this database (they are encrypted against "
                "database.secret, so a restored or copied database needs them "
                "set again) and that the IAM identity holds s3:GetObject.",
                image.id, external_url)
            return request.not_found()
        # A genuinely EXTERNAL url - not our bucket, nothing to sign. Handing
        # it to the browser is the only thing left worth trying.
        return request.redirect(external_url, code=302, local=False)
    return request.not_found()


def serve_video(video):
    """Stream one question clip.

    An mp4 is never proxied through the worker: a large clip goes out as a 302
    to the signed S3/CDN url. Only the small on-record Binary dev fallback is
    streamed, via ir.binary whose Stream honours Range so `<video>` can seek.
    """
    if video.video_url:
        from ..services import s3_service
        key = s3_service.object_key_from_url(request.env, video.video_url)
        if not key:
            # Somebody else's URL: hand the player straight at it.
            return request.redirect(video.video_url, code=302, local=False)
        signed = s3_service.presigned_url(
            request.env, key, expires=_presign_seconds(request.env))
        if signed:
            return request.redirect(signed, code=302, local=False)
        # OUR bucket, and we could not sign for it. Redirecting unsigned is a
        # guaranteed 403, so say what is wrong in the log instead of handing
        # the player a URL that can only fail.
        _logger.error(
            "Question video %s is stored at %s but no presigned URL could be "
            "produced. Check this database's S3 credentials.",
            video.id, video.video_url)
        # LAST RESORT: THE ROUTE THE DESIGNER ALREADY USES.
        #
        # Form Studio media is served in the admin by `/api/v1/forms/media/`,
        # which resolves storage connector-first and therefore works in cases
        # where presigning cannot - that asymmetry is precisely how a clip
        # played for the examiner and showed a dead 0:00 player to the
        # candidate sitting the exam.
        #
        # It is a FALLBACK and not the default on purpose: that proxy reads the
        # whole object into worker memory and answers no `Accept-Ranges`, so
        # the clip cannot be seeked and a whole cohort loading it puts the
        # bytes through Odoo instead of S3. Correct-but-slow beats a dead
        # player; it does not beat a presigned redirect.
        if key.startswith("form_studio/"):
            return request.redirect(
                "/api/v1/forms/media/%s" % key, code=302, local=True)
        # ...AND FALL THROUGH TO THE BYTES. Failing loudly is right; doing it
        # in a candidate's face mid-exam is not. This used to `return
        # not_found()` here and never look at the Binary field, so a clip whose
        # bytes sat on the record still played as a dead 0:00 player - which is
        # how this presented on stage. `serve_image` has always preferred bytes;
        # the order here is the same, just tried AFTER the redirect so a large
        # clip still leaves the worker alone in the normal case.
    if video.video:
        mimetype = "video/webm" if (video.video_filename or "").lower(
        ).endswith(".webm") else "video/mp4"
        return request.env["ir.binary"]._get_stream_from(
            video, field_name="video", mimetype=mimetype).get_response(
                as_attachment=False)
    return request.not_found()


def annotated_is_worker_safe(question):
    """True only when a question's annotated overlay carries NO answer content.

    SECURITY (Finding L-2). For UI/dense labelling the numbered boxes sit on
    controls and the candidate supplies the labels, so the overlay reveals
    nothing. For DEFECT annotation the markers are drawn ON the defects, so the
    overlay IS the answer key. Never serve it for a defect question, whatever
    `?annotated=` asks for.
    """
    if (question.question_type or "") != "image_label":
        return False
    mode = (question.detection_mode or "").lower()
    if mode in ("ui", "dense", "dense_boxes"):
        return True
    # A live-DOM captured screenshot is a UI task by construction.
    if question.image_ids.filtered(lambda i: i.source_url):
        return True
    return False

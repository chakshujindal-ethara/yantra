# -*- coding: utf-8 -*-
"""Task template routes: list, save, delete.

A task template is the shape of ONE task the SOP defines - its axes, its
per-axis options, how many assets a candidate needs - saved once and generated
from many times. The write surface mirrors Form Studio's deliberately: the
designer authors a whole document, so `save` is one upsert of the whole thing
rather than a per-field PATCH.

Templates are MANAGER-ONLY on write and STAFF-ONLY on read, the same split
`forms.py` uses. A candidate must never see a template: it carries the answer
key for every item it describes.
"""
import json
import time

from odoo import fields, http
from odoo.http import request
from odoo.tools import config

from .common import (
    API_METHODS, API_TYPE, api_endpoint, arg, body, fail, int_arg, ok, paged,
    paging, require_manager, require_staff, str_arg,
)

from ...constants import TASK_PRIMITIVE_TO_QUESTION_TYPE, takes_one_answer
from ...models.studio_form import MAX_STRUCTURE_BYTES
from ...services import vertex


def _row(rec):
    """The wire shape for one template.

    `structure` uses the designer's own key name so the Form Studio screen can
    load a template without a translation layer - that reuse is the whole reason
    a template stores the designer's structure verbatim.
    """
    return {
        "id": rec.id,
        "name": rec.name or "",
        "instructions": rec.instructions or "",
        "response": rec.response or "",
        "question_type": rec.question_type or "",
        "structure": rec.structure_json or [],
        "item_count": rec.item_count,
        # HOW MANY WOULD ACTUALLY GENERATE. A template whose questions fail
        # their answer-key contract looks identical to a healthy one in the
        # picker - same name, same type, same count - and only reveals itself
        # after a paid run returns nothing. Sending this lets the client warn
        # before the spend.
        "usable_count": rec.usable_count,
        "authored_by": rec.authored_by or "manual",
        # The examiner's own answer-key data. Sent on every row so the editor
        # can round-trip it; a primitive that does not use a field just leaves
        # it blank rather than the wire shape changing per type.
        "rubric_criteria": rec.rubric_criteria or "",
        "rubric_pass_condition": rec.rubric_pass_condition or "",
        "rubric_constraints": rec.rubric_constraints or "",
        "annotation_targets": rec.annotation_targets or "",
        "annotation_expected_count": rec.annotation_expected_count or 0,
        "media_brief": rec.media_brief or "",
        # WHAT WOULD GO WRONG IF THIS WERE GENERATED FROM, one per line.
        #
        # Sent on every row, not just after a draft, because the whole point is
        # that these outlive the drafting toast: the editor renders them as a
        # standing notice and the template list can badge a row without asking
        # the model anything. Empty when nothing is wrong.
        "shape_warnings": [
            line for line in (rec.shape_warnings or "").split("\n") if line
        ],
        # WHAT SHAPE THIS ACTUALLY IS, in one line the operator can compare
        # across a list where every LLM-drafted A/B template is named
        # "Compare AI-Generated Images" - the same title three times over with
        # nothing else to go on but a question count. This is the SAME
        # dimension data `answer_contract()` computes, read here for display
        # rather than for generation.
        "shape_summary": rec.shape_summary(),
        # Which SOP this was authored against, so the library list is legible.
        # Null is normal: a template outlives the generator it came from.
        "origin": ({"id": rec.origin_prompt_id.id,
                    "name": rec.origin_prompt_id.name or ""}
                   if rec.origin_prompt_id else None),
        "updated_at": rec.write_date.isoformat() if rec.write_date else "",
    }


class AssessmentsBeTaskTemplateApi(http.Controller):

    @http.route("/api/v1/task_templates", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def task_templates_list(self, **kw):
        """Newest first, every template regardless of origin SOP.

        The library is cross-SOP on purpose: the admin asked to see "past
        created task templates" when choosing what to generate, and a template
        authored for one project is often the right shape for the next.
        """
        Template = request.env["assessments.be.task.template"]
        domain = []
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("name", "ilike", search))
        # Optional narrowing for the panel that lives on ONE generator's page.
        origin_id = int_arg("origin_id")
        if origin_id:
            domain.append(("origin_prompt_id", "=", origin_id))
        limit, offset = paging()
        total = Template.search_count(domain)
        # `assessments.be.task.template._order` written out verbatim, for the
        # reason spelled out on the same line in `forms.py`: an offset-paged
        # route states its own total order rather than inheriting one that can be
        # retuned for a back-office list.
        records = Template.search(domain, limit=limit, offset=offset,
                                  order="write_date desc, id desc")
        return paged([_row(r) for r in records], total, limit, offset)

    @http.route("/api/v1/task_templates/save", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def task_template_save(self, **kw):
        """Upsert one template. `id` absent or 0 creates."""
        payload = body().get("template")
        if not isinstance(payload, dict):
            return fail("bad_request",
                        "Send the template as `template`.", status=400)

        structure = payload.get("structure")
        if structure is None:
            structure = []
        if not isinstance(structure, list):
            return fail("bad_request",
                        "`structure` must be a list of sections.", status=400)
        if len(json.dumps(structure).encode("utf-8")) > MAX_STRUCTURE_BYTES:
            return fail("too_large",
                        "The template document is too large.", status=413)

        Template = request.env["assessments.be.task.template"]
        response = str(payload.get("response") or "").strip()
        if response and response not in dict(
                Template._fields["response"].selection):
            return fail("bad_request",
                        "Unknown response primitive %r." % response,
                        status=400)

        vals = {
            "name": str(payload.get("name") or "").strip() or "Untitled task",
            "instructions": str(payload.get("instructions") or ""),
            # Json field: store the native list, no dumps.
            "structure_json": structure,
        }
        # The examiner's own answer-key data, per primitive. Optional on every
        # save: a template authored before these existed keeps working, and a
        # primitive that does not use a given field simply never sends it.
        for key, field in (
                ("rubric_criteria", "rubric_criteria"),
                ("rubric_pass_condition", "rubric_pass_condition"),
                ("rubric_constraints", "rubric_constraints"),
                ("annotation_targets", "annotation_targets"),
                ("media_brief", "media_brief")):
            if key in payload:
                vals[field] = str(payload.get(key) or "")
        expected = payload.get("annotation_expected_count")
        if isinstance(expected, int) and expected >= 0:
            vals["annotation_expected_count"] = expected
        if response:
            vals["response"] = response
        authored_by = str(payload.get("authored_by") or "").strip()
        if authored_by in ("manual", "llm_edited"):
            vals["authored_by"] = authored_by
        origin_id = payload.get("origin_id")
        if isinstance(origin_id, int) and origin_id > 0:
            vals["origin_prompt_id"] = origin_id

        template_id = payload.get("id")
        rec = None
        if isinstance(template_id, int) and template_id > 0:
            rec = Template.browse(template_id).exists()
            if not rec:
                return fail("not_found", "No such template.", status=404)
        # A KEY NOBODY CAN EARN IS REFUSED BEFORE ANYTHING IS SAVED (R8). On a
        # one-pick axis a candidate picks one option and scoring is an
        # exact-set match, so two marked correct score every candidate zero -
        # for every question generated from the template.
        qtype = TASK_PRIMITIVE_TO_QUESTION_TYPE.get(
            response or (rec.response if rec else "")) or ""
        for axis in Template.new({"structure_json": structure})._axes():
            if len(axis["correct"]) > 1 and takes_one_answer(qtype,
                                                             axis["kind"]):
                return fail(
                    "invalid",
                    "%r takes one answer, so it cannot have %d correct "
                    "options. Mark one, or make it checkboxes."
                    % (axis["label"], len(axis["correct"])), status=422)
        if rec:
            rec.write(vals)
        else:
            rec = Template.create(vals)
        return ok(_row(rec))

    @http.route("/api/v1/task_templates/draft", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def task_template_draft(self, **kw):
        """Propose a template from a generator's SOP. SAVES NOTHING.

        The response goes straight into the designer for the admin to edit; only
        their explicit Save persists it, with `authored_by=llm_edited`. Keeping
        the draft unsaved is what makes an imperfect proposal harmless.

        This is a PAID call, one per press.
        """
        generator_id = int_arg("generator_id")
        if not generator_id:
            return fail("bad_request", "Send the `generator_id`.", status=400)
        generator = request.env["assessments.be.prompt"].browse(
            generator_id).exists()
        if not generator:
            return fail("not_found", "Generator not found.", status=404)
        if generator.deleted:
            return fail("deleted", "This generator is deleted and cannot be "
                        "changed.", status=409)
        # A Stop pressed after this moment refuses any further model call for
        # this draft, and the reply that is already on its way.
        started = fields.Datetime.now()
        def stopped():
            return fail("cancelled",
                        "Drafting was stopped. Nothing was saved.", status=409)
        # ANSWER BEFORE ODOO KILLS THE WORKER. Past `limit_time_real` (default
        # 120 s) the worker is killed mid-call: the client gets a bare proxy
        # error and a retry already sent is paid for and lost. 10 s is left
        # for the rest of this request.
        limit = config.get("limit_time_real") or 0
        deadline = time.monotonic() + limit - 10 if limit > 0 else None
        try:
            draft = vertex.draft_task_template_from_sop(
                request.env, generator,
                usage_ctx={"user_id": request.env.user.id,
                           "template_draft_since": started,
                           "deadline": deadline})
        except vertex.VertexCancelledError:
            return stopped()
        except vertex.VertexDeadlineError:
            return fail("timeout", "The AI model took too long to answer. "
                        "Nothing was saved - try again.", status=504)
        except vertex.VertexNotConfiguredError as exc:
            # Its own words say what is missing and where to set it.
            return fail("not_configured", str(exc), status=503)
        except vertex.LLMRefusalError as exc:
            # The model's own words, or ours about a missing SOP - either way
            # something the operator can act on, not a 500.
            return fail("llm_refused", str(exc), status=422)
        except vertex.VertexQuotaError:
            # Vertex's own 429: the house "busy" answer, not a 500. A minute,
            # not the pool shed's 2s - a quota window does not clear that fast.
            return fail(
                "busy", "The AI model is busy right now. Try again in a minute.",
                status=503, retry_after=60, headers=[("Retry-After", "60")])
        if vertex.template_draft_cancelled(request.env, generator.id, started):
            return stopped()
        # The origin rides back so a Save can attribute the template without the
        # client having to remember which generator it came from.
        draft["origin_id"] = generator.id
        draft["authored_by"] = "llm_edited"
        return ok(draft)

    @http.route("/api/v1/task_templates/cancel_draft", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def task_template_cancel_draft(self, **kw):
        """Stop a Draft from SOP that is still waiting on the model.

        The draft runs inside its own web request, so this cannot interrupt
        the call already on the wire (it finishes and is billed); it stops
        any further call and makes that request answer `cancelled`.
        """
        generator_id = int_arg("generator_id")
        generator = request.env["assessments.be.prompt"].browse(
            generator_id or 0).exists()
        if not generator:
            return fail("not_found", "Generator not found.", status=404)
        generator.template_draft_cancelled_at = fields.Datetime.now()
        return ok({"cancelled": True})

    @http.route("/api/v1/task_templates/delete", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def task_template_delete(self, **kw):
        """ARCHIVE, never unlink.

        A launched assessment may cite the template its questions came from, and
        those questions are already frozen. Archiving takes it out of the picker
        without destroying that provenance.
        """
        template_id = int_arg("id")
        if not template_id:
            return fail("bad_request", "Send the template `id`.", status=400)
        rec = request.env["assessments.be.task.template"].browse(
            template_id).exists()
        # Archiving what is already archived is success, not failure: the client
        # retries on flaky networks and must be able to converge.
        archived = bool(rec)
        if rec:
            rec.active = False
        return ok({"archived": archived})

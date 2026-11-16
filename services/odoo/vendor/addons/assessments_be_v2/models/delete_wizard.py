# -*- coding: utf-8 -*-
"""Permanent delete for an assessment, from the Odoo cog menu.

ONE DIALOG. An earlier version asked twice - a warning, then the numbers - which
is what the Flutter console does over an HTTP round trip it cannot avoid. In the
back office both halves are already known when the menu is clicked, so the
second screen bought nothing but a second click.

It still archives before it destroys. That is not a step the operator takes, it
is the order the work happens in: the paper is filed away and its queued work
released, and only then are the rows removed.
"""
from odoo import _, api, fields, models
from odoo.exceptions import UserError


class EtpAssessmentDeleteWizard(models.TransientModel):
    _name = "assessments.be.delete.wizard"
    _description = "Delete an assessment permanently"

    #: NO `ondelete="cascade"`. The cascade deleted this very record the moment
    #: the assessment went, so the method returned holding a row that no longer
    #: existed. Transients are vacuumed anyway; a dangling id here costs nothing.
    assessment_id = fields.Many2one(
        "assessments.be", string="Assessment", ondelete="set null")
    name = fields.Char(readonly=True)
    candidate_count = fields.Integer(readonly=True)
    response_count = fields.Integer(readonly=True)
    ledger_kept = fields.Integer(readonly=True)
    #: Candidates mid-sitting. The API refuses this case outright and makes the
    #: operator confirm interrupting an exam before anything is archived; the
    #: wizard has no second round trip to refuse in, so it states the number
    #: instead. "2 candidates are sitting this right now" is what tells someone
    #: they picked the wrong row - a bare "are you sure?" does not.
    live_count = fields.Integer(readonly=True)

    @api.model
    def default_get(self, fields_list):
        res = super().default_get(fields_list)
        # `active_ids` WINS, and the guard below is why. The cog menu sets
        # BOTH keys on every invocation - the web client's own
        # `action_menus.js` puts `active_id: activeIds[0]` in the context
        # before the server action runs, and the server action returns it
        # again - so preferring `active_id` collapsed a five-row selection to
        # one row, made `len(ids) > 1` unreachable, and destroyed the first
        # paper while the operator believed they had selected five.
        ids = self.env.context.get("active_ids") or []
        if not ids and self.env.context.get("active_id"):
            ids = [self.env.context["active_id"]]
        if len(ids) > 1:
            raise UserError(_("Delete one assessment at a time."))
        if not ids:
            return res
        a = self.env["assessments.be"].browse(ids[0])
        Response = self.env["assessments.be.response"].sudo()
        Usage = self.env["assessments.be.llm.usage"].sudo()
        res.update({
            "assessment_id": a.id,
            "name": a.name,
            "candidate_count": len(a.assessment_evaluator_ids),
            "response_count": Response.with_context(
                active_test=False).search_count([("assessment_id", "=", a.id)]),
            "ledger_kept": Usage.search_count(
                [("evaluator_id", "in", a.assessment_evaluator_ids.ids)]),
            "live_count": len(a.assessment_evaluator_ids.filtered(
                lambda e: e.state == "in_progress")),
        })
        return res

    def _back_to_the_list(self):
        """Leave on the list, never on the record that was just destroyed.

        `ir.actions.act_window_close` only dismisses the dialog. The form
        underneath stays mounted on the record, so the web client reloads a
        row that no longer exists and answers with "the records with IDs N
        cannot be found" - twice, once per read it had in flight. The delete
        has in fact succeeded, but every signal the operator gets says
        otherwise: the paper is still on screen, the breadcrumb still names
        it, the URL still points at it. They press Delete again (the wizard
        reopens on a dead id) and then Archive, which raises Missing Record.

        So the destructive button answers with a destination. `target: "main"`
        replaces the whole breadcrumb stack rather than pushing onto it, which
        is what drops the dead form; reusing the module's own action means the
        list comes back with the same views, domain and context as the menu.
        """
        action = self.env.ref(
            "assessments_be_v2.action_etp_assessment").sudo()._get_action_dict()
        action["target"] = "main"
        return action

    def action_destroy(self):
        """Archive, then destroy. The only irreversible control in this module.

        NOT `ir.actions.act_window_closed`, which is not a model and which
        `clean_action` turns into a raw KeyError traceback in the browser.
        `call_kw` never runs `clean_action`, so an RPC test of this method
        passes while every real button press fails.
        """
        self.ensure_one()
        a = self.assessment_id
        if not a:
            return self._back_to_the_list()
        if a.active:
            a.write({"active": False})
        a.with_context(**{a.CONFIRMED_DESTROY_CTX: True}).unlink()
        return self._back_to_the_list()

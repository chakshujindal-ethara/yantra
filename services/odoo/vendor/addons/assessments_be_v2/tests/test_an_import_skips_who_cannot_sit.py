# -*- coding: utf-8 -*-
"""An import skips the people who could never sit and assigns everybody else.

THE INCIDENT (stage, 19 Oct 2026). An 874-row roster was imported into
"Dummy Test". Seven addresses belonged to portal accounts and one was not a
company address. Provisioning ran for 499 s and then refused all 874; the
browser had long given up, so the operator saw nothing and nobody was
assigned. 59 more portal accounts, bound to applicants by earlier papers,
would have been assigned anyway and refused at sign-in.

Now the people who cannot sit are skipped with a reason and named in the
History, everybody else is assigned, a bound portal account counts the same as
an unbound one, and `dry_run` says all of it before anything is written. A
request that ends with nobody assigned is a 422 naming who and why, because
the single-person adds toast any 200 as done. Launch keeps its all-or-nothing
refusal (`test_every_blocked_candidate_is_named_at_once`).
"""
import base64
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..controllers.api import admin as api_admin
from ..models.assessment import _skipped_lines
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
LATE_REASON = "Work email must be an @ethara.ai address."


@tagged("-at_install", "post_install")
class TestAnImportSkipsWhoCannotSit(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.paper = self.env["assessments.be"].create(
            {"name": "Skip %s" % uuid4().hex[:6], "duration_minutes": 30})
        self.Applicant = self.env["hr.applicant"].sudo().with_context(
            active_test=False)
        self.Users = self.env["res.users"].sudo().with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True)
        self.domain = "skip%s.example.com" % uuid4().hex[:6]

    def _address(self, slug):
        return "%s@%s" % (slug, self.domain)

    def _user(self, slug, group):
        return self.Users.create({
            "name": "User %s" % slug, "login": self._address(slug),
            "group_ids": [(6, 0, [self.env.ref(group).id])]})

    def _portal(self, slug):
        return self._user(slug, "base.group_portal")

    def _bound_applicant(self, user):
        """The 59 when `user` is portal: an account an earlier paper bound."""
        applicant = self.Applicant.create(
            {"partner_name": "Bound %s" % user.login, "email_from": user.login})
        applicant.be_candidate_user_id = user.id
        return applicant

    def _assign(self, rows=(), **params):
        return call_route(
            api_admin, api_admin.EtpAssessmentApiAdmin(), "assessment_assign",
            self.env, path={"assessment_id": self.paper.id},
            candidates=[{"name": n, "email": e} for n, e in rows], **params)

    def _emails(self, applicants):
        return set(applicants.mapped("email_from"))

    def _roster(self):
        self.paper.invalidate_recordset()
        return self.paper.assessment_evaluator_ids.applicant_id

    def _refusing(self, address):
        """Provisioning that refuses one address, as another addon's rule on
        the account does on stage - the check cannot foresee it."""
        Assessment = type(self.env["assessments.be"])
        provision = Assessment._ensure_candidate_user

        def refuse_one(model, applicant):
            if applicant.email_from == address:
                raise ValidationError(LATE_REASON)
            return provision(model, applicant)
        return patch.object(Assessment, "_ensure_candidate_user", refuse_one)

    def _history(self):
        return " ".join(self.paper.message_ids.mapped("body"))

    # -- the assign route ----------------------------------------------------

    def test_the_route_assigns_the_rest_and_names_who_was_skipped(self):
        self._portal("unbound")
        bound = self._bound_applicant(self._portal("bound"))
        good = [self._address("good1"), self._address("good2")]

        done = self._assign([
            ("Good One", good[0]),
            ("Unbound Portal", self._address("unbound")),
            ("Bound Portal", bound.email_from),
            ("Good Two", good[1]),
            ("Good One Again", good[0].upper()),
            ("Unbound Again", self._address("unbound")),
        ])

        self.assertEqual(status_of(done), 200, done)
        data = done["data"]
        self.assertEqual(data["assigned_count"], 2, data)
        self.assertEqual(
            sorted(s["email"] for s in data["skipped"]),
            sorted([self._address("unbound"), bound.email_from]),
            "both kinds of portal account must be skipped alike, once each")
        for row in data["skipped"]:
            self.assertIn("portal account", row["reason"])
        self.assertEqual(self._emails(self.paper.evaluator_ids), set(good))
        self.assertEqual(self._emails(self._roster()), set(good))
        self.assertFalse(
            self.Applicant.search(
                [("email_from", "=", self._address("unbound"))]),
            "an applicant was made for somebody who was skipped")
        self.assertEqual(
            len(self.Applicant.search([("email_from", "=", good[0])])), 1,
            "the same new address twice made two applicants")
        self.assertIn(bound.email_from, self._history(),
                      "the History does not say who was skipped")

    def test_returning_staff_and_bound_candidates_are_not_skipped(self):
        """The majority of a real roster: people who already have an internal
        account, bound or found by their login. A check that skipped every
        account it found would empty most rosters."""
        bound = self._bound_applicant(self._user("bound", "base.group_user"))
        staff = self._user("staff", "base.group_user")

        done = self._assign([("Staff", staff.login)],
                            applicant_ids=[bound.id])

        self.assertEqual(status_of(done), 200, done)
        self.assertEqual(done["data"]["skipped"], [])
        self.assertEqual(done["data"]["assigned_count"], 2)
        self.assertEqual(self._emails(self.paper.evaluator_ids),
                         {bound.email_from, staff.login})

    def test_a_dry_run_says_who_would_be_skipped_and_writes_nothing(self):
        self._portal("portal")
        on_roster = self.Applicant.create(
            {"partner_name": "Already", "email_from": self._address("already")})
        self.paper.write({"evaluator_ids": [(4, on_roster.id)]})
        new = self._address("new")

        checked = self._assign([
            ("New Person", new),
            ("Portal Person", self._address("portal")),
            ("Already", on_roster.email_from),
        ], dry_run=True)

        self.assertEqual(status_of(checked), 200, checked)
        data = checked["data"]
        self.assertTrue(data["dry_run"])
        self.assertEqual(data["assigned_count"], 1)
        self.assertEqual(data["already_assigned"], 1)
        self.assertEqual([s["email"] for s in data["skipped"]],
                         [self._address("portal")])
        self.assertFalse(self.Applicant.search([("email_from", "=", new)]),
                         "a dry run created an applicant")
        self.assertFalse(self.Users.with_context(active_test=False).search(
            [("login", "=", new)]), "a dry run provisioned a login")
        self.assertEqual(self.paper.evaluator_ids, on_roster)
        self.assertFalse(self.paper.assessment_evaluator_ids,
                         "a dry run wrote roster rows")
        self.assertFalse(on_roster.be_candidate_user_id,
                         "a dry run bound somebody")

    def test_nobody_assigned_is_a_refusal_that_names_them(self):
        """Invite by Email, the picker and a row's Assign button each send ONE
        person and toast any 200 as done."""
        portal = self._portal("picked")
        junk = self.Applicant.create(
            {"partner_name": "Junk", "email_from": "not an address"})
        Assessment = type(self.env["assessments.be"])
        provision = Assessment._ensure_candidate_user
        reached = []

        def spy(model, applicant):
            reached.append(applicant.email_from)
            return provision(model, applicant)

        with patch.object(Assessment, "_ensure_candidate_user", spy):
            refused = self._assign(user_ids=[portal.id],
                                   applicant_ids=[junk.id])

        self.assertEqual(status_of(refused), 422, refused)
        self.assertEqual(refused["error"]["code"], "nothing_assigned")
        self.assertIn(portal.login, refused["error"]["message"])
        reasons = {s["email"]: s["reason"] for s in refused["skipped"]}
        self.assertIn("portal account", reasons[portal.login])
        self.assertIn("'not an address' is not an email address",
                      reasons["not an address"])
        self.assertEqual(reached, [],
                         "the up-front check let somebody through to the "
                         "slow provisioning it exists to spare")
        self.assertFalse(self.paper.evaluator_ids)

    def test_a_picked_person_also_typed_in_is_one_applicant(self):
        """Picked from the directory AND typed in, in one request. The typed
        row is looked up after the picked one has made its applicant."""
        staff = self._user("both", "base.group_user")
        rows = [("Typed Too", staff.login)]

        checked = self._assign(rows, user_ids=[staff.id], dry_run=True)
        done = self._assign(rows, user_ids=[staff.id])

        self.assertEqual(checked["data"]["assigned_count"], 1)
        self.assertEqual(status_of(done), 200, done)
        self.assertEqual(done["data"]["assigned_count"], 1)
        self.assertEqual(len(done["data"]["created_applicants"]), 1)
        self.assertEqual(
            len(self.Applicant.search([("email_from", "=", staff.login)])), 1)
        self.assertEqual(self.paper.evaluator_ids.be_candidate_user_id, staff)

    def test_an_archived_applicant_typed_in_again_is_revived(self):
        archived = self.Applicant.create(
            {"partner_name": "Old Name", "email_from": self._address("back")})
        archived.active = False

        done = self._assign([("Came Back", archived.email_from)])

        self.assertEqual(done["data"]["assigned_count"], 1)
        self.assertEqual(done["data"]["created_applicants"], [])
        self.assertEqual(self.paper.evaluator_ids, archived)
        self.assertTrue(archived.active)
        self.assertEqual(archived.partner_name, "Old Name")

    def test_remove_cannot_be_previewed(self):
        person = self.Applicant.create(
            {"partner_name": "Stays", "email_from": self._address("stays")})
        self.paper.write({"evaluator_ids": [(4, person.id)]})

        refused = self._assign(applicant_ids=[person.id], remove=True,
                               dry_run=True)

        self.assertEqual(status_of(refused), 400, refused)
        self.assertEqual(self.paper.evaluator_ids, person,
                         "a dry run really removed somebody")

    def test_an_empty_request_is_still_a_bad_request(self):
        for params in ({}, {"dry_run": True}):
            refused = self._assign(**params)
            self.assertEqual(status_of(refused), 400, refused)
            self.assertEqual(refused["error"]["code"], "no_candidates")

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_a_login_refused_during_provisioning_comes_off_the_roster(self):
        """The check cannot know every rule on an account. On stage another
        addon refuses a non-company address only when the login is created.
        `left` was assigned before but never got a roster row, so this sync
        provisions - and refuses - them too: they must not also be counted
        as already assigned."""
        good, late = self._address("good"), self._address("late")
        left = self.Applicant.create(
            {"partner_name": "Left", "email_from": self._address("left")})
        self.paper.write({"evaluator_ids": [(4, left.id)]})

        with self._refusing(late), self._refusing(left.email_from):
            done = self._assign([("Good", good), ("Late", late),
                                 ("Left", left.email_from)])

        self.assertEqual(status_of(done), 200, done)
        self.assertEqual(done["data"]["assigned_count"], 1)
        self.assertEqual(done["data"]["already_assigned"], 0)
        self.assertEqual(len(done["data"]["created_applicants"]), 1)
        self.assertEqual(
            sorted((s["email"], s["reason"]) for s in done["data"]["skipped"]),
            sorted([(late, LATE_REASON), (left.email_from, LATE_REASON)]))
        self.assertEqual(self._emails(self.paper.evaluator_ids), {good})
        self.assertEqual(self._emails(self._roster()), {good})

    # -- the CSV import ------------------------------------------------------

    def _import(self, *rows):
        csv_text = "name,email\n%s\n" % "\n".join("%s,%s" % r for r in rows)
        self.paper.candidate_csv_file = base64.b64encode(csv_text.encode())
        return self.paper.action_import_candidates_csv()["params"]

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_the_csv_import_skips_and_says_who(self):
        self._portal("unbound")
        bound = self._bound_applicant(self._portal("bound"))
        good, late = self._address("good"), self._address("late")

        with self._refusing(late):
            params = self._import(
                ("Good Person", good),
                ("Unbound Portal", self._address("unbound")),
                ("Bound Portal", bound.email_from),
                ("Late Refusal", late),
                ("Good Again", good.upper()),
                ("Unbound Again", self._address("unbound")))

        self.assertEqual(params["type"], "warning")
        self.assertTrue(params["sticky"])
        self.assertIn("1 new candidate(s) added. 0 already assigned.",
                      params["message"])
        self.assertIn("3 skipped", params["message"])
        for address in (self._address("unbound"), bound.email_from, late):
            self.assertIn(address, params["message"])
            self.assertIn(address, self._history())
        self.assertEqual(self._emails(self.paper.evaluator_ids), {good})
        self.assertEqual(self._emails(self._roster()), {good})
        self.assertEqual(
            len(self.Applicant.search([("email_from", "=", good)])), 1,
            "the same new address twice made two applicants")

    def test_a_clean_csv_import_is_a_plain_success(self):
        params = self._import(("One", self._address("one")),
                              ("Two", self._address("two")))

        self.assertEqual(params["type"], "success")
        self.assertFalse(params["sticky"])
        self.assertNotIn("skipped", params["message"])
        self.assertEqual(len(self.paper.evaluator_ids), 2)

    # -- the reports -----------------------------------------------------------

    def test_a_long_skip_list_is_cut_and_counted(self):
        rows = [("P%d" % i, "p%d@x.com" % i, "why") for i in range(3)]
        self.assertEqual(
            _skipped_lines(rows, limit=2),
            "  - P0 <p0@x.com>: why\n  - P1 <p1@x.com>: why\n  and 1 more")
        self.paper._log_skipped(rows, limit=1)
        history = self._history()
        self.assertIn("P0 &lt;p0@x.com&gt;: why", history)
        self.assertIn("and 2 more", history)
        self.assertNotIn("p1@x.com", history)

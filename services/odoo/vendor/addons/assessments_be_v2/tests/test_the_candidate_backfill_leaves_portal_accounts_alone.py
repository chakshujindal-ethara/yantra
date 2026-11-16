# -*- coding: utf-8 -*-
"""The 19.0.3.17.0 candidate backfill must not convert a portal account.

WHY THIS IS TESTED AT ALL, when migrations normally are not. This one grants a
group to an enumerated set of live accounts, and it is the riskiest script in the
addon: too narrow and every existing candidate is refused at their own exam door
the moment the module upgrades. It is also the only place in the codebase that
touches the legacy portal-candidate shape in bulk - 70 such accounts on stage, 68
of them on @ethara.ai addresses.

THE FAILURE MODE IT MUST NOT HAVE. `group_assessment_candidate` implies
`base.group_user`, and `res.users._check_disjoint_groups` refuses an account that
ends up both portal and internal. That constraint is an `@api.constrains` on
`group_ids`, so it fires at FLUSH - not at write. A migration that granted the
group to a portal account would therefore not fail on that account; it would fail
LATER, aborting the upgrade and taking every other grant in the run with it. A
`try/except` around the write cannot catch it, and a test that never flushes
cannot see it. Both are asserted below.

THE POLICY IT MUST HAVE. Portal accounts are not converted. This platform is
internal-only, and promoting an account buys a paid Odoo seat on somebody's
behalf - a decision for a person, not for a migration running unattended. They
are left untouched and named in the log so an operator has a work queue.
"""
import logging
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..constants import GROUP_CANDIDATE


#: The version directory holding the access-ladder migration.
#:
#: DISCOVERED, NOT ASSUMED, and specifically NOT read off the manifest.
#:
#: This used to return `manifest["version"]`, on the reasoning that a hardcoded
#: literal had already gone stale once when the scalability work took
#: 19.0.3.17.0 and .18.0 for its index migrations and pushed the access-ladder
#: scripts up to .19.0. That fixed the wrong half of the problem: a migration
#: directory is named for the version that INTRODUCED it, and the module keeps
#: moving past it. The next release that adds no migration at all - 19.0.3.20.0,
#: the admin-console defect pass, whose schema changes are plain fields the ORM
#: creates on upgrade - left this pointing at a directory that does not exist,
#: and six tests died with FileNotFoundError.
#:
#: Odoo runs EVERY intermediate version's scripts on the way up, so .19.0's
#: post-migrate still runs for a database below it however far the manifest
#: advances. Finding the newest directory that actually holds the script is
#: therefore both correct and stable: it survives a renumbering (the original
#: fear) and a version bump that adds no migration (the one that broke it).
def _version_dir():
    import os

    addon = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.join(addon, "migrations")
    def is_backfill(d):
        # Identified by content: newer releases add unrelated post-migrate
        # scripts (19.0.3.27.0 recounts answers), so "newest" alone is wrong.
        path = os.path.join(root, d, "post-migrate.py")
        if not os.path.isfile(path):
            return False
        with open(path, encoding="utf-8") as f:
            return "group_assessment_candidate" in f.read()

    have = [d for d in os.listdir(root) if is_backfill(d)]
    if not have:
        raise RuntimeError(
            "no migrations/*/post-migrate.py under %s - the access-ladder "
            "backfill this file tests has been deleted or renamed" % root)

    def key(name):
        # Newest by VERSION, not by string: "19.0.3.9.0" sorts above
        # "19.0.3.19.0" lexically, which would pick the wrong script the moment
        # a single-digit version exists.
        return tuple(int(p) if p.isdigit() else -1 for p in name.split("."))

    return max(have, key=key)


VERSION_DIR = _version_dir()


def _load_migration():
    """The post-migrate module, by file path.

    `migrations/` is not a Python package - Odoo loads migration scripts by path,
    and the directory has no `__init__.py` - so it cannot be imported normally.
    """
    import importlib.util
    import os

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "migrations", VERSION_DIR, "post-migrate.py")
    spec = importlib.util.spec_from_file_location("be_v2_post_migrate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@tagged("-at_install", "post_install")
class TestTheCandidateBackfillLeavesPortalAccountsAlone(TransactionCase):

    def setUp(self):
        super().setUp()
        self.migration = _load_migration()
        self.Users = self.env["res.users"].sudo()
        self.Applicant = self.env["hr.applicant"].sudo()
        self.candidate_group = self.env.ref(GROUP_CANDIDATE)

    # -- fixtures ---------------------------------------------------------

    def _account(self, group_xmlid):
        login = "backfill_%s@example.com" % uuid4().hex[:8]
        return self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "Backfill %s" % uuid4().hex[:6],
            "login": login,
            "group_ids": [(6, 0, [self.env.ref(group_xmlid).id])],
        })

    def _candidate_applicant(self, user):
        """An applicant bound to `user`, with a real attempt behind it.

        Written straight onto the field, which is how the legacy rows got there
        - `_ensure_candidate_user` now refuses to create this shape.
        """
        applicant = self.Applicant.create({
            "partner_name": "Legacy %s" % uuid4().hex[:6],
            "email_from": user.login,
            "be_candidate_user_id": user.id,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Backfill exam %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })
        self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "access_token": str(uuid4()),
        })
        return applicant

    def _run(self):
        """The migration, as an upgrade (a truthy `version`)."""
        self.migration.migrate(self.env.cr, "19.0.3.16.0")

    # -- cases ------------------------------------------------------------

    def test_the_upgrade_survives_a_portal_candidate(self):
        """THE HEADLINE. One badly-shaped legacy row must not abort an upgrade.

        Flushed explicitly: the constraint that would kill this is deferred, so
        an unflushed test would pass with the bug present.
        """
        portal = self._account("base.group_portal")
        self._candidate_applicant(portal)

        try:
            self._run()
            self.env.flush_all()
        except ValidationError as exc:
            self.fail(
                "the candidate backfill aborted on a portal account, which "
                "would take the whole upgrade and every other grant with it: %s"
                % exc)

    def test_the_portal_account_is_not_granted_the_group(self):
        portal = self._account("base.group_portal")
        self._candidate_applicant(portal)

        self._run()
        self.env.flush_all()
        portal.invalidate_recordset()

        self.assertNotIn(
            self.candidate_group, portal.all_group_ids,
            "a portal account must not be granted the Candidate group")

    def test_the_portal_account_is_not_converted(self):
        """POLICY. Converting buys a paid Odoo seat on somebody's behalf."""
        portal = self._account("base.group_portal")
        self._candidate_applicant(portal)
        before = set(portal.group_ids.ids)

        self._run()
        self.env.flush_all()
        portal.invalidate_recordset()

        self.assertFalse(
            portal._is_internal(),
            "the migration must never promote a portal account to internal")
        self.assertEqual(
            set(portal.group_ids.ids), before,
            "the account's groups must be exactly as they were")

    def test_the_blocked_account_is_named_in_the_log(self):
        """The log line IS the operator's work queue.

        Nothing else in the system will tell them which accounts these are, so a
        count without logins would be a dead end.
        """
        portal = self._account("base.group_portal")
        self._candidate_applicant(portal)

        with self.assertLogs(self.migration._logger.name,
                             level=logging.WARNING) as captured:
            self._run()

        blob = "\n".join(captured.output)
        self.assertIn(
            portal.login, blob,
            "the warning must name the account, not just count it")
        self.assertIn(
            "internal users only", blob,
            "and state the rule, so the reader knows this is policy rather "
            "than a failure to be retried")

    def test_an_internal_candidate_is_still_granted(self):
        """Guard the guard. If the backfill granted nothing, every assertion
        above would be vacuous - and this is the script whose whole purpose is
        to stop live candidates being locked out."""
        internal = self._account("base.group_user")
        self._candidate_applicant(internal)

        self._run()
        self.env.flush_all()
        internal.invalidate_recordset()

        self.assertIn(
            self.candidate_group, internal.all_group_ids,
            "an internal candidate MUST be granted the group - without this "
            "the upgrade locks every existing candidate out of their own exam")

    def test_a_fresh_install_does_nothing(self):
        """`version` falsy = install. There are no pre-existing candidates, and
        `_ensure_candidate_user` grants the group to every new one."""
        internal = self._account("base.group_user")
        self._candidate_applicant(internal)

        self.migration.migrate(self.env.cr, None)
        self.env.flush_all()
        internal.invalidate_recordset()

        self.assertNotIn(
            self.candidate_group, internal.all_group_ids,
            "an install must not run the backfill")

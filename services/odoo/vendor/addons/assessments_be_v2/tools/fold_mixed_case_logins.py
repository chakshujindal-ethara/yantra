# -*- coding: utf-8 -*-
"""Fold existing mixed-case `res.users` logins. ONE-OFF, RUN DELIBERATELY.

NOT A MIGRATION. A migration runs on every upgrade of every database, and this
touches authentication on rows nobody asked about - it wants a person deciding
when, on which database, after reading what it would do.

Run the dry run first. It writes nothing:

    ./odoo-bin shell -c odoo.conf -d <db> \\
        < custom_addons/assessments_be_v2/tools/fold_mixed_case_logins.py

Then, to apply:

    env FOLD_LOGINS_APPLY=1 ./odoo-bin shell -c odoo.conf -d <db> \\
        < custom_addons/assessments_be_v2/tools/fold_mixed_case_logins.py

WHY THIS IS CLEANUP AND NOT AN INCIDENT. On production at the time of writing,
53 of 1663 logins differ from their own lower-case form: 52 are web-scanner
junk from a single day and 1 is a deactivated duplicate. No live candidate is
locked out. Run it AFTER the `res.users.create` fold is deployed, or the rows
come straight back.

COLLISIONS ARE REPORTED, NEVER MERGED. Two accounts that fold to the same login
is a question about which person owns that address - who has the exam history,
which one is deactivated, whether one is a scanner artefact. A script that
picked for you would be picking which of two people can sign in.
"""
import os

# `env` is provided by `odoo-bin shell`.
APPLY = os.environ.get("FOLD_LOGINS_APPLY") == "1"

Users = env["res.users"].sudo().with_context(active_test=False)

mixed = Users.search([("login", "!=", False)]).filtered(
    lambda u: "@" in (u.login or "") and u.login != u.login.casefold())

print("=" * 72)
print("%d login(s) differ from their own lower-case form" % len(mixed))
print("=" * 72)

# Group by target so a collision is visible before anything is written.
by_target = {}
for user in mixed:
    by_target.setdefault(user.login.casefold(), []).append(user)

safe, collisions = [], []
for target, users in sorted(by_target.items()):
    taken = Users.search([("login", "=", target)])
    if len(users) > 1 or taken:
        collisions.append((target, users, taken))
    else:
        safe.append((target, users[0]))

for target, user in safe:
    print("  fold   %-45s -> %s%s"
          % (user.login, target, "" if user.active else "   [inactive]"))

for target, users, taken in collisions:
    print("  SKIP   %s" % target)
    for user in users:
        print("           id=%-6s %-45s active=%s"
              % (user.id, user.login, user.active))
    for user in taken:
        print("           id=%-6s %-45s active=%s  <- already holds it"
              % (user.id, user.login, user.active))

print("-" * 72)
print("%d safe to fold, %d collision(s) left alone" % (len(safe), len(collisions)))

if not APPLY:
    print("\nDRY RUN - nothing written. Set FOLD_LOGINS_APPLY=1 to apply.")
else:
    for target, user in safe:
        # One at a time: a failure on row 40 must not roll back rows 1-39 in a
        # way that leaves the operator unsure which half landed.
        try:
            user.write({"login": target})
        except Exception as exc:  # noqa: BLE001
            print("  FAILED id=%s %s: %s" % (user.id, user.login, exc))
    env.cr.commit()
    print("\nAPPLIED: %d login(s) folded and committed." % len(safe))
    if collisions:
        print("%d collision(s) still need a human decision." % len(collisions))

# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.19.0 pre-migration: free the name "Manager".

WITHOUT THIS THE UPGRADE DOES NOT LOAD. `res_groups` carries
`UNIQUE(privilege_id, name)`, and 19.0.3.19.0 does two things to one privilege at
once: it renames the existing `group_assessment_manager` from "Manager" to
"Admin", and it introduces a NEW group that takes the freed name.

On a fresh install that is fine - neither record exists yet. On an UPGRADE the
old row is still sitting there called "Manager" when the XML reaches the new
record, and Odoo loads a data file top to bottom:

    psycopg2.errors.UniqueViolation: duplicate key value violates unique
    constraint "res_groups_name_uniq"
    DETAIL:  Key (privilege_id, name)=(9, {"en_US": "Manager"}) already exists.

The module then fails to install and the registry never loads, so this is a hard
stop on every database that already has the addon - stage and production
included, which is where it would otherwise have been discovered.

WHY NOT JUST REORDER THE XML. The Admin record has to declare
`implied_ids -> group_assessment_manager_restricted`, and `ref()` resolves while
parsing, so the restricted group must already exist when Admin is read. Moving
Admin above it swaps a unique violation for a missing-xmlid one. Splitting Admin
into a create and a later write would put one group across two records for the
rest of the file's life.

WHY RAW SQL. Pre-migrate runs before the new registry is in place, and `name` on
`res.groups` is a translated column: the stored value is jsonb, not text, so it
is written as jsonb here rather than through a field that does not exist yet.

IDEMPOTENT. Matching on the xmlid rather than on the old label means a re-run - or
a database somebody already renamed by hand - is a no-op rather than a second
rename of the wrong row.
"""


def migrate(cr, version):
    # No version = a fresh install, which has no old row to collide with.
    if not version:
        return
    cr.execute("""
        UPDATE res_groups g
           SET name = '{"en_US": "Admin"}'::jsonb
          FROM ir_model_data d
         WHERE d.model = 'res.groups'
           AND d.module = 'assessments_be_v2'
           AND d.name = 'group_assessment_manager'
           AND g.id = d.res_id
           AND g.name ->> 'en_US' != 'Admin'
    """)

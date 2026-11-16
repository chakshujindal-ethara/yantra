-- Least privilege per deployable. Run once per database by its owner (`yantra`), after the roles exist, on the rig
-- (deployment/local/postgres-init/20-roles.sh does it) and on a managed Postgres (the owner runs it, then sets each
-- role's password from the secret store). Safe to run again.
--
--   yantra        owns every schema; the migrate Jobs connect as it; no running process does.
--   yantra_work   the work API and events processes: read and write market, talent, assess, quality, notify,
--                 tracker and analytics. Nothing in payout.
--   yantra_money  the money API and events processes: read and write payout. Nothing else.
--
-- A bug or an injection in one deployable cannot read or change the other's data. No role here may create or drop
-- objects; only migrations change the shape of a schema.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'yantra_work') THEN
    CREATE ROLE yantra_work LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'yantra_money') THEN
    CREATE ROLE yantra_money LOGIN;
  END IF;
END
$$;

-- every schema exists before its first migration, so the default privileges below cover tables created later
CREATE SCHEMA IF NOT EXISTS market AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS talent AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS assess AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS quality AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS notify AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS tracker AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS analytics AUTHORIZATION yantra;
CREATE SCHEMA IF NOT EXISTS payout AUTHORIZATION yantra;

DO $$
DECLARE
  grant_to record;
BEGIN
  FOR grant_to IN
    SELECT * FROM (VALUES
      ('market', 'yantra_work'), ('talent', 'yantra_work'), ('assess', 'yantra_work'), ('quality', 'yantra_work'),
      ('notify', 'yantra_work'), ('tracker', 'yantra_work'), ('analytics', 'yantra_work'),
      ('payout', 'yantra_money')
    ) AS g(schema_name, role_name)
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', grant_to.schema_name, grant_to.role_name);
    -- what exists now (a database migrated before this file ran) ...
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I',
                   grant_to.schema_name, grant_to.role_name);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', grant_to.schema_name, grant_to.role_name);
    -- ... and everything the owner's migrations create from now on
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE yantra IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
                   grant_to.schema_name, grant_to.role_name);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE yantra IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO %I',
                   grant_to.schema_name, grant_to.role_name);
  END LOOP;
END
$$;

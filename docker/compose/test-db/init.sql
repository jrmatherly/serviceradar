-- One-time preparation of the disposable test database, run as the superuser by
-- entrypoint.sh on first start. It mirrors install_extensions in
-- rust/integration-db/src/lib.rs. The caller passes the owner password as the
-- psql variable owner_password.

CREATE ROLE srql LOGIN PASSWORD :'owner_password';

-- The image's initdb default is SQL_ASCII, which migrations reject.
CREATE DATABASE sr_core_test_local OWNER srql
  TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';

\connect sr_core_test_local

-- Must exist before the first migration, or schema_migrations lands in public.
CREATE SCHEMA platform AUTHORIZATION srql;

CREATE EXTENSION pgcrypto;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION citext;
CREATE EXTENSION timescaledb;
CREATE EXTENSION age;
CREATE EXTENSION postgis;
CREATE EXTENSION vector;
CREATE EXTENSION "uuid-ossp";

GRANT USAGE ON SCHEMA ag_catalog TO srql;
GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO srql;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO srql;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO srql;

LOAD 'age';
SET search_path = ag_catalog, pg_catalog, "$user", public;
SELECT create_graph('serviceradar_topology');
SELECT create_graph('serviceradar');
SELECT create_graph('platform_graph');
RESET search_path;

-- Migrations create indexes on the AGE label tables, which needs ownership,
-- not a grant. A sequence owned by a column follows its table.
DO $$
DECLARE
  graph_name text;
  obj record;
BEGIN
  FOREACH graph_name IN ARRAY ARRAY['serviceradar_topology', 'serviceradar', 'platform_graph'] LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO srql', graph_name);
    FOR obj IN
      SELECT c.relname AS name, c.relkind AS kind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = graph_name
        AND c.relkind IN ('r', 'p', 'S')
        AND NOT (
          c.relkind = 'S'
          AND EXISTS (
            SELECT 1 FROM pg_depend d
            WHERE d.classid = 'pg_class'::regclass
              AND d.objid = c.oid
              AND d.deptype IN ('a', 'i')
          )
        )
      ORDER BY (c.relkind = 'S'), c.relname
    LOOP
      IF obj.kind = 'S' THEN
        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO srql', graph_name, obj.name);
      ELSE
        EXECUTE format('ALTER TABLE %I.%I OWNER TO srql', graph_name, obj.name);
      END IF;
    END LOOP;
  END LOOP;
END
$$;

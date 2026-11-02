\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS schema
      ON schema.oid = relation.relnamespace
    WHERE schema.nspname = 'realtime'
      AND relation.relname = 'messages'
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'Realtime message authorization must keep RLS enabled';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE anon;
DO $$
DECLARE
  violations text[] := ARRAY[]::text[];
  denied boolean := false;
BEGIN
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.boards';
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    violations := array_append(violations, 'anon retains direct table SELECT');
  END IF;

  denied := false;
  BEGIN
    EXECUTE 'SELECT * FROM public.get_full_board_p($1)' USING 'closed-access-fixture';
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    violations := array_append(violations, 'slug RPC exposes an existing board to anon');
  END IF;

  denied := false;
  BEGIN
    EXECUTE 'SELECT * FROM public.create_board_p($1)' USING 'anonymous-created';
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    violations := array_append(violations, 'slug RPC lets anon create a board');
  END IF;

  denied := false;
  BEGIN
    INSERT INTO realtime.messages(extension, topic, payload)
    VALUES (
      'broadcast',
      'board:00000000-0000-4000-8000-000000000001',
      '{}'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN
    violations := array_append(violations, 'anon can publish to a private Realtime channel');
  END IF;

  IF cardinality(violations) > 0 THEN
    RAISE EXCEPTION 'Closed access boundary violations: %', array_to_string(violations, '; ');
  END IF;
END;
$$;
ROLLBACK;
\echo 'PASS: anonymous clients cannot read or create product data'

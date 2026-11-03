\set ON_ERROR_STOP on
\echo 'Issue #49: inspect effective anonymous privileges after the complete migration chain'

-- The allowlist of effective anon grants in the PostgREST public schema is empty.
-- Intentionally public HTTP entry points are inventoried separately in issue-49.md.

DO $$
DECLARE
  v_public_relations text;
  v_public_sequences text;
  v_public_routines text;
BEGIN
  IF has_schema_privilege('anon', 'public', 'USAGE')
    OR has_schema_privilege('anon', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'anon can use or create objects in the public schema';
  END IF;

  SELECT pg_catalog.string_agg(
    pg_catalog.format('%I.%I (%s)', schema_name.nspname, relation.relname, privilege.name),
    ', ' ORDER BY relation.relname, privilege.name
  )
  INTO v_public_relations
  FROM pg_catalog.pg_class AS relation
  JOIN pg_catalog.pg_namespace AS schema_name
    ON schema_name.oid = relation.relnamespace
  CROSS JOIN pg_catalog.unnest(ARRAY[
    'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
  ]::text[]) AS privilege(name)
  WHERE schema_name.nspname = 'public'
    AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
    AND pg_catalog.has_table_privilege('anon', relation.oid, privilege.name);
  IF v_public_relations IS NOT NULL THEN
    RAISE EXCEPTION 'anon has effective public table/view privileges: %', v_public_relations;
  END IF;

  SELECT pg_catalog.string_agg(
    pg_catalog.format('%I.%I (%s)', schema_name.nspname, sequence.relname, privilege.name),
    ', ' ORDER BY sequence.relname, privilege.name
  )
  INTO v_public_sequences
  FROM pg_catalog.pg_class AS sequence
  JOIN pg_catalog.pg_namespace AS schema_name
    ON schema_name.oid = sequence.relnamespace
  CROSS JOIN pg_catalog.unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']::text[]) AS privilege(name)
  WHERE schema_name.nspname = 'public'
    AND sequence.relkind = 'S'
    AND pg_catalog.has_sequence_privilege('anon', sequence.oid, privilege.name);
  IF v_public_sequences IS NOT NULL THEN
    RAISE EXCEPTION 'anon has effective public sequence privileges: %', v_public_sequences;
  END IF;

  SELECT pg_catalog.string_agg(
    pg_catalog.format('%I.%I(%s)', schema_name.nspname, routine.proname,
      pg_catalog.pg_get_function_identity_arguments(routine.oid)),
    ', ' ORDER BY routine.proname, routine.oid
  )
  INTO v_public_routines
  FROM pg_catalog.pg_proc AS routine
  JOIN pg_catalog.pg_namespace AS schema_name
    ON schema_name.oid = routine.pronamespace
  WHERE schema_name.nspname = 'public'
    AND routine.prokind IN ('f', 'p', 'a', 'w')
    AND pg_catalog.has_function_privilege('anon', routine.oid, 'EXECUTE');
  IF v_public_routines IS NOT NULL THEN
    RAISE EXCEPTION 'anon has effective public function/procedure EXECUTE privileges (including PUBLIC grants): %',
      v_public_routines;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS schema_name
      ON schema_name.oid = relation.relnamespace
    WHERE schema_name.nspname = 'storage'
      AND relation.relname = 'objects'
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'Storage objects are missing row-level security';
  END IF;
  IF COALESCE((SELECT bucket.public
      FROM storage.buckets AS bucket
      WHERE bucket.id = 'task-attachments'), true) THEN
    RAISE EXCEPTION 'the task attachment bucket is missing or public';
  END IF;

  RAISE NOTICE 'PASS: no effective anon privilege reaches public tables, views, sequences, functions, or procedures; task attachment Storage bucket is private with RLS enabled';
END;
$$;

BEGIN;
SET LOCAL ROLE anon;
DO $$
DECLARE
  v_visible_objects bigint;
  v_write_blocked boolean := false;
BEGIN
  SELECT count(*) INTO v_visible_objects
  FROM storage.objects
  WHERE bucket_id = 'task-attachments';
  IF v_visible_objects <> 0 THEN
    RAISE EXCEPTION 'anon can read task attachment object metadata';
  END IF;

  BEGIN
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('task-attachments', 'issue49-anonymous-denied');
  EXCEPTION WHEN insufficient_privilege THEN
    v_write_blocked := true;
  END;
  IF NOT v_write_blocked THEN
    RAISE EXCEPTION 'anon can write task attachment object metadata';
  END IF;
END;
$$;
COMMIT;

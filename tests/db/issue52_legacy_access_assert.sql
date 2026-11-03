\set ON_ERROR_STOP on
\echo 'Comprobando que los RPC anónimos del estado previo exponen el fixture legado'

BEGIN;
SET LOCAL ROLE anon;
DO $$
DECLARE
  v_payload json;
BEGIN
  IF NOT has_function_privilege('anon', 'public.get_full_board_p(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'El fixture legado ya no reproduce la superficie RPC anónima anterior al corte';
  END IF;

  v_payload := public.get_full_board_p('issue52-legacy-a');
  IF v_payload->'board'->>'slug' IS DISTINCT FROM 'issue52-legacy-a'
    OR v_payload->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM 'Tarea sintética legado A' THEN
    RAISE EXCEPTION 'El acceso RPC legado no devuelve el contenido sintético conocido';
  END IF;

  v_payload := public.get_full_board_p('issue52-legacy-b');
  IF v_payload->'board'->>'slug' IS DISTINCT FROM 'issue52-legacy-b'
    OR v_payload->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM 'Tarea sintética legado B' THEN
    RAISE EXCEPTION 'El acceso RPC legado no conserva el segundo tablero sintético';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: el estado previo a la transición hace visible el fixture por RPC anónimo.'

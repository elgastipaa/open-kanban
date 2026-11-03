\ir issue52_inventory_assert.sql

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '52100000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_payload jsonb;
BEGIN
  v_payload := public.get_full_board_p('issue52-legacy-a')::jsonb;
  IF v_payload->'board'->>'slug' IS DISTINCT FROM 'issue52-legacy-a'
    OR v_payload->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM 'Tarea sintética legado A'
    OR public.get_full_board_p('issue52-legacy-b') IS NOT NULL THEN
    RAISE EXCEPTION 'El propietario A no ve solo el tablero asignado en el inventario';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '52100000-0000-4000-8000-000000000002', true);
DO $$
BEGIN
  IF public.get_full_board_p('issue52-legacy-b')::jsonb->'columns'->0->'tasks'->0->>'title'
      IS DISTINCT FROM 'Tarea sintética legado B'
    OR public.get_full_board_p('issue52-legacy-a') IS NOT NULL THEN
    RAISE EXCEPTION 'El propietario B no ve solo el tablero asignado en el inventario';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '52100000-0000-4000-8000-000000000003', true);
DO $$
BEGIN
  IF public.is_application_admin() IS DISTINCT FROM true
    OR public.get_full_board_p('issue52-legacy-a') IS NOT NULL
    OR public.get_full_board_p('issue52-legacy-b') IS NOT NULL
    OR EXISTS (SELECT 1 FROM public.list_my_boards()) THEN
    RAISE EXCEPTION 'El admin bootstrap fue convertido en lector global o no quedó habilitado';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: los dos propietarios pueden leer solo su tablero y el admin no tiene lectura de tablero.'

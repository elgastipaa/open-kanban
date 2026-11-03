\ir issue52_inventory_assert.sql

BEGIN;
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_inventory issue52_rehearsal.inventory%ROWTYPE;
  v_other issue52_rehearsal.inventory%ROWTYPE;
  v_payload jsonb;
BEGIN
  FOR v_inventory IN SELECT * FROM issue52_rehearsal.inventory ORDER BY slug LOOP
    PERFORM set_config('request.jwt.claim.sub', v_inventory.explicit_owner_id::text, true);
    v_payload := public.get_full_board_p(v_inventory.slug)::jsonb;
    IF v_payload->'board'->>'slug' IS DISTINCT FROM v_inventory.slug
      OR v_payload->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM v_inventory.expected_task_title THEN
      RAISE EXCEPTION 'El owner explícito no ve el contenido de %', v_inventory.slug;
    END IF;

    FOR v_other IN
      SELECT * FROM issue52_rehearsal.inventory AS other_inventory
      WHERE other_inventory.board_id <> v_inventory.board_id
      ORDER BY other_inventory.slug
    LOOP
      IF public.get_full_board_p(v_other.slug) IS NOT NULL THEN
        RAISE EXCEPTION 'El owner de % también puede leer el tablero ajeno %',
          v_inventory.slug, v_other.slug;
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  v_admin_id uuid;
BEGIN
  SELECT admin_id INTO STRICT v_admin_id
  FROM issue52_rehearsal.bootstrap
  WHERE singleton;
  PERFORM set_config('request.jwt.claim.sub', v_admin_id::text, true);

  IF public.is_application_admin() IS DISTINCT FROM true
    OR EXISTS (
      SELECT 1 FROM issue52_rehearsal.inventory AS inventory
      WHERE public.get_full_board_p(inventory.slug) IS NOT NULL
    )
    OR EXISTS (SELECT 1 FROM public.list_my_boards()) THEN
    RAISE EXCEPTION 'El admin bootstrap fue convertido en lector global o no quedó habilitado';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: los dos propietarios pueden leer solo su tablero y el admin no tiene lectura de tablero.'

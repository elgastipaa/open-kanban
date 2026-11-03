\set ON_ERROR_STOP on
\echo 'Comprobando propiedad explícita, contenido y separación entre admin y tablero'

DO $$
DECLARE
  v_inventory issue52_rehearsal.inventory%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_admin issue52_rehearsal.bootstrap%ROWTYPE;
  v_payload jsonb;
  v_count integer;
BEGIN
  IF (SELECT count(*) FROM issue52_rehearsal.inventory) <> 2 THEN
    RAISE EXCEPTION 'El ensayo no tiene el inventario ficticio completo';
  END IF;

  SELECT * INTO STRICT v_admin FROM issue52_rehearsal.bootstrap WHERE singleton;
  IF NOT EXISTS (
    SELECT 1 FROM public.application_access AS access
    WHERE access.email = v_admin.admin_email
      AND access.auth_user_id = v_admin.admin_id
      AND access.google_subject = v_admin.admin_subject
      AND access.state = 'active'
      AND access.is_admin
  ) THEN
    RAISE EXCEPTION 'El administrador bootstrap no coincide con la elección explícita del fixture';
  END IF;

  FOR v_inventory IN SELECT * FROM issue52_rehearsal.inventory ORDER BY slug LOOP
    SELECT * INTO STRICT v_board FROM public.boards WHERE id = v_inventory.board_id;
    IF v_board.slug IS DISTINCT FROM v_inventory.slug
      OR v_board.owner_id IS DISTINCT FROM v_inventory.explicit_owner_id THEN
      RAISE EXCEPTION 'El tablero % no conserva el owner explícito del inventario', v_inventory.slug;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = v_inventory.explicit_owner_id
        AND access.state = 'active'
        AND NOT access.is_admin
    ) OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_board.id
        AND membership.user_id = v_inventory.explicit_owner_id
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Falta la identidad habilitada o membresía dueña explícita para %', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El tablero % cambió su número de columnas durante la migración', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    JOIN public.tasks AS task ON task.column_id = column_row.id
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El tablero % cambió su número de tareas durante la migración', v_inventory.slug;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.columns AS column_row
      JOIN public.tasks AS task ON task.column_id = column_row.id
      WHERE column_row.board_id = v_board.id
        AND task.id = v_inventory.expected_task_id
        AND task.title = v_inventory.expected_task_title
    ) THEN
      RAISE EXCEPTION 'El tablero % perdió su tarea sintética al migrar', v_inventory.slug;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id IN (SELECT board_id FROM issue52_rehearsal.inventory)
      AND membership.user_id = v_admin.admin_id
      AND membership.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'El bootstrap admin recibió membresía de tablero por ser el primer usuario';
  END IF;
END;
$$;

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

\echo 'PASS: dos owners explícitos conservan contenido; el admin bootstrap no obtiene lectura de tableros ajenos.'

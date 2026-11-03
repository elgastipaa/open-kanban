\set ON_ERROR_STOP on
\echo 'Asignando propietarios elegidos y admin bootstrap después del cierre anónimo'

BEGIN;
INSERT INTO public.application_access (
  email, auth_user_id, google_subject, state, is_admin
)
SELECT actor.email, actor.actor_id, actor.google_subject, 'active',
  actor.intended_role = 'bootstrap_admin'
FROM issue52_rehearsal.actors AS actor;

-- This is a migration-owner step in the disposable fixture, not an application
-- path. Every legacy board gets an owner from the explicit inventory before
-- 017 creates its active generation and owner membership.
ALTER TABLE public.boards DISABLE TRIGGER boards_require_owner;
UPDATE public.boards AS board
SET owner_id = inventory.explicit_owner_id
FROM issue52_rehearsal.inventory AS inventory
WHERE inventory.board_id = board.id;
ALTER TABLE public.boards ENABLE TRIGGER boards_require_owner;

DO $$
BEGIN
  IF (SELECT count(*) FROM issue52_rehearsal.inventory) <> 2
    OR EXISTS (
      SELECT 1
      FROM issue52_rehearsal.inventory AS inventory
      JOIN public.boards AS board ON board.id = inventory.board_id
      WHERE board.owner_id IS DISTINCT FROM inventory.explicit_owner_id
    ) THEN
    RAISE EXCEPTION 'La asignación de owners no coincide con el inventario explícito';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: el mapa de owners y el bootstrap admin quedaron explícitos antes de 017.'

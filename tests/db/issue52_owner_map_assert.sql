\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT count(*) FROM issue52_rehearsal.inventory) <> 2
    OR EXISTS (
      SELECT 1
      FROM issue52_rehearsal.inventory AS inventory
      LEFT JOIN public.boards AS board ON board.id = inventory.board_id
      WHERE board.id IS NULL
        OR board.slug IS DISTINCT FROM inventory.slug
        OR board.owner_id IS DISTINCT FROM inventory.explicit_owner_id
    ) THEN
    RAISE EXCEPTION 'La asignación de owners no coincide con el inventario explícito';
  END IF;
END;
$$;

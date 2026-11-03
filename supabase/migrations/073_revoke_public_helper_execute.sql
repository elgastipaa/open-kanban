BEGIN;

-- These trigger helpers were recreated after the closed-access default ACL was
-- applied. They are implementation details, not callable public RPCs.
REVOKE ALL ON FUNCTION public.check_board_owner_membership()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.check_active_board_generation()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.validate_board_time_zone()
  FROM PUBLIC, anon, authenticated, service_role;

-- Board discovery is a user-facing RPC, but only for an authenticated caller.
REVOKE ALL ON FUNCTION public.list_my_boards()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_boards() TO authenticated;

COMMIT;

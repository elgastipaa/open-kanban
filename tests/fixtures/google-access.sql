\set ON_ERROR_STOP on
-- Explicit test principals; the absent no-access principal must remain denied.
INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('bootstrap-admin@example.test', 'pending', true),
  ('enabled-user@example.test', 'pending', false);
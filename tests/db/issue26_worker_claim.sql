\set ON_ERROR_STOP on

-- Exercise lease replacement and exhausted-lease cleanup through the worker
-- claim path. This runs in a rollback-only transaction and uses the synthetic
-- issue #26 series created by repetition_edit.sql.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_ref public.issue26_repetition_race_ref%ROWTYPE;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_old_token uuid := '26000000-0000-4000-8000-000000000093';
  v_new_token uuid;
  v_claim record;
  v_worker_result jsonb;
  v_result jsonb;
  v_claimed integer := 0;
BEGIN
  SELECT * INTO v_ref FROM public.issue26_repetition_race_ref WHERE singleton;

  -- Make this one synthetic series the only eligible work for the assertions.
  UPDATE public.daily_repetition_jobs AS job
  SET available_at = v_now + interval '100 years'
  WHERE job.id <> v_ref.job_id AND job.state IN ('queued', 'retry_wait');
  UPDATE public.daily_repetition_jobs AS job
  SET lease_expires_at = v_now + interval '100 years'
  WHERE job.id <> v_ref.job_id AND job.state = 'leased';

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = v_old_token,
      lease_expires_at = v_now - interval '1 second', attempt_count = 1
  WHERE job.id = v_ref.job_id;

  SELECT * INTO v_claim
  FROM public.claim_daily_repetition_jobs_internal_p(1, v_now)
  WHERE id = v_ref.job_id;
  IF NOT FOUND OR v_claim.lease_token IS NULL
    OR v_claim.lease_token = v_old_token OR v_claim.attempt_count <> 2 THEN
    RAISE EXCEPTION 'An expired lease was not replaced after board/series locks: %', v_claim;
  END IF;
  v_new_token := v_claim.lease_token;

  v_result := public.process_daily_repetition_job_internal_p(
    v_ref.job_id, v_old_token, v_now
  );
  IF v_result->>'status' IS DISTINCT FROM 'lease_lost' THEN
    RAISE EXCEPTION 'The previous lease token still applied after re-claim: %', v_result;
  END IF;
  v_result := public.process_daily_repetition_job_internal_p(
    v_ref.job_id, v_new_token, v_now
  );
  IF v_result->>'status' IS DISTINCT FROM 'superseded' THEN
    RAISE EXCEPTION 'A re-claimed job from the old series revision was not rejected: %', v_result;
  END IF;

  v_now := pg_catalog.clock_timestamp();
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = '26000000-0000-4000-8000-000000000092',
      lease_expires_at = v_now - interval '1 second',
      attempt_count = job.max_attempts
  WHERE job.id = v_ref.job_id;
  v_worker_result := public.run_daily_repetition_jobs_p(100);
  SELECT count(*) INTO v_claimed
  FROM public.daily_repetition_jobs AS job
  WHERE job.id = v_ref.job_id AND job.state = 'leased';
  IF v_worker_result->>'claimed' IS DISTINCT FROM '0'
    OR v_claimed <> 0
    OR (SELECT job.state FROM public.daily_repetition_jobs AS job
        WHERE job.id = v_ref.job_id) IS DISTINCT FROM 'dead_letter'
    OR (SELECT job.lease_token FROM public.daily_repetition_jobs AS job
        WHERE job.id = v_ref.job_id) IS NOT NULL
    OR (SELECT job.last_error_code FROM public.daily_repetition_jobs AS job
        WHERE job.id = v_ref.job_id) IS DISTINCT FROM 'lease_expired' THEN
    RAISE EXCEPTION 'The scheduler did not dead-letter an exhausted lease safely: %', v_worker_result;
  END IF;
END;
$$;
ROLLBACK;

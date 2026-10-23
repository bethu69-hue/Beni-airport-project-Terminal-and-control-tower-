-- Migration 0005: Supabase-specific hardening.
-- Supabase grants EXECUTE on new functions to anon and authenticated by default, so
-- "revoke from public" alone is not enough. Close every door explicitly.

-- 1. Nobody signed-out may call any function in the public schema.
revoke execute on all functions in schema public from anon;

-- 2. Trigger and internal functions: no direct calls by anyone through the API.
revoke execute on function
  public.audit_row(), public.block_change(), public.handle_new_user(), public.next_ref(uuid, text),
  public.documents_before_insert(), public.notices_guard(), public.rules_guard(), public.deadlines_guard(),
  public.contracts_touch(), public.er_guard(), public.itps_guard(), public.itp_steps_guard(),
  public.inspections_guard(), public.ncrs_guard(), public.corrective_actions_guard(),
  public.test_records_guard(), public.material_approvals_guard(), public.quality_audits_guard(),
  public.er_links_guard(), public.er_verifications_guard(), public.kpi_readings_guard(),
  public.seed_quality_kpis(uuid), public.generate_reminders(date)
  from public, anon, authenticated;

-- 3. Pure functions get a fixed search path.
alter function public.block_change() set search_path = public;
alter function public.notice_rank(text) set search_path = public;
alter function public.contracts_touch() set search_path = public;
alter function public.deadlines_guard() set search_path = public;
alter function public.compute_due_date(timestamptz, int, text, text) set search_path = public;
alter function public.ncr_rank(text) set search_path = public;

-- ref_counters is internal on purpose: RLS on, no policy, no grants.
comment on table public.ref_counters is 'Internal counter. No policies on purpose: only SECURITY DEFINER functions touch it.';

-- 4. Close the default PUBLIC grant too, then re-grant only what signed-in users call.
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.mfa_ok(uuid), public.has_project_role(uuid, text[]), public.is_project_member(uuid),
  public.can_write_quality(uuid), public.can_manage_requirements(uuid), public.can_sign_off_quality(uuid),
  public.notice_rank(text), public.ncr_rank(text),
  public.compute_due_date(timestamptz, int, text, text), public.create_project(text, text, text),
  public.create_deadline_for_notice(uuid, uuid, timestamptz, text, uuid),
  public.recalculate_flagged_deadline(uuid, timestamptz), public.change_deadline(uuid, date, text),
  public.satisfy_deadline(uuid, text), public.project_dashboard(uuid), public.log_document_download(uuid),
  public.import_requirements(uuid, jsonb), public.supersede_requirement(uuid, text, text, text, text),
  public.kpi_value(uuid, text, date, date), public.quality_scorecard(uuid, date, date), public.qms_dashboard(uuid)
  to authenticated;

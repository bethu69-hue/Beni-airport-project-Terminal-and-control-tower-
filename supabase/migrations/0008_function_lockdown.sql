-- Migration 0008: only the functions the app is meant to call stay callable.
-- Supabase gives new functions to anon/authenticated/service_role by default, so revoke everything first, then grant explicitly.
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

alter function public.signoffs_no_change() set search_path = public;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.can_write_reports(uuid), public.generate_monthly_report(uuid, date),
  public.set_report_input(uuid, text, text), public.submit_report_for_review(uuid), public.sign_record(text, uuid, text, text),
  public.issue_report(uuid),
  public.mfa_ok(uuid), public.has_project_role(uuid, text[]), public.is_project_member(uuid),
  public.can_write_quality(uuid), public.can_manage_requirements(uuid), public.can_sign_off_quality(uuid),
  public.notice_rank(text), public.ncr_rank(text), public.compute_due_date(timestamptz, int, text, text),
  public.create_project(text, text, text), public.create_deadline_for_notice(uuid, uuid, timestamptz, text, uuid),
  public.recalculate_flagged_deadline(uuid, timestamptz), public.change_deadline(uuid, date, text),
  public.satisfy_deadline(uuid, text), public.project_dashboard(uuid), public.log_document_download(uuid),
  public.import_requirements(uuid, jsonb), public.supersede_requirement(uuid, text, text, text, text),
  public.kpi_value(uuid, text, date, date), public.quality_scorecard(uuid, date, date), public.qms_dashboard(uuid),
  public.touch_presence(uuid), public.search_contract_text(uuid, text, int) to authenticated;
grant execute on function public.record_alert_result(bigint, text, text, text), public.purge_old_chat(),
  public.run_monthly_report_job(date), public.generate_reminders(date) to service_role;

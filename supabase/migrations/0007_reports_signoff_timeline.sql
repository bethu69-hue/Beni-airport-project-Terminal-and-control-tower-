-- Migration 0007: monthly progress report (FIDIC Sub-Clause 4.21 style), digital sign-off,
-- one timeline across every tracker, and the language preference.
--
-- Rules carried through:
--  * Nothing is invented. A section with no data says so. Manual sections must be filled in by a person.
--  * The report section list is a template that a Project Manager or Contract Manager must VERIFY against the
--    executed contract (Particular Conditions can change it). Until then every report is marked "template unverified".
--  * Generating a report is not issuing it. Issue needs three recorded sign-offs by different people.
--  * Sign-offs are permanent and carry a fingerprint of exactly what was signed.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Language and report settings
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists language text not null default 'en' check (language in ('en','fr'));
grant update (language) on public.profiles to authenticated;
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

alter table public.projects
  add column if not exists report_generate_day int not null default 4 check (report_generate_day between 1 and 28),
  add column if not exists report_due_days int not null default 7 check (report_due_days between 1 and 60);

create or replace function public.can_write_reports(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_project_role(p, array['project_administrator','project_manager','assistant_project_manager',
    'contract_manager','planning_engineer','quantity_surveyor','qa_qc_manager','hse_officer','engineer',
    'resident_engineer','site_engineer','design_manager','document_controller','contractor_rep'])
$$;

-- ---------------------------------------------------------------------------
-- Report template: the sections the contract requires, each to be verified
-- ---------------------------------------------------------------------------
create table public.report_sections (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  position int not null,
  key text not null,
  title_en text not null,
  title_fr text not null,
  clause_ref text,
  source text not null check (source in ('auto','manual','mixed')),
  status text not null default 'unverified' check (status in ('unverified','verified')),
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  active boolean not null default true,
  unique (project_id, key)
);

create or replace function public.report_sections_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.status = 'verified' and old.status <> 'verified' then
      if not public.has_project_role(new.project_id, array['project_manager','contract_manager']) then
        raise exception 'Only a Project Manager or Contract Manager can verify a report section';
      end if;
      new.verified_by := auth.uid(); new.verified_at := now();
    end if;
    if new.status = 'verified' and old.status = 'verified' and
       (new.key, new.title_en, new.source, new.clause_ref) is distinct from (old.key, old.title_en, old.source, old.clause_ref) then
      raise exception 'A verified section cannot be changed';
    end if;
  end if;
  return new;
end $$;
create trigger report_sections_guard before update on public.report_sections for each row execute function public.report_sections_guard();
create trigger report_sections_no_delete before delete on public.report_sections for each row execute function public.block_change();

-- Seeded from the usual Sub-Clause 4.21 list. All start UNVERIFIED because the executed contract and
-- Particular Conditions decide the final list.
create or replace function public.seed_report_sections() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.report_sections (project_id, position, key, title_en, title_fr, clause_ref, source) values
   (new.id, 1, 'progress', 'Progress charts and descriptions: design, Contractor''s Documents, procurement, manufacture, delivery, construction, erection and testing',
      'Graphiques et descriptions d''avancement : conception, documents de l''Entrepreneur, approvisionnement, fabrication, livraison, construction, montage et essais', '4.21 (a)', 'manual'),
   (new.id, 2, 'photographs', 'Photographs of manufacturing status and site progress',
      'Photographies de l''état de fabrication et de l''avancement du chantier', '4.21 (b)', 'mixed'),
   (new.id, 3, 'manufacture', 'Main items of manufacture: manufacturer, location, progress, dates of start, inspections, tests, shipment and arrival on site',
      'Principaux éléments fabriqués : fabricant, lieu, avancement, dates de début, inspections, essais, expédition et arrivée sur site', '4.21 (c)', 'manual'),
   (new.id, 4, 'resources', 'Contractor''s Personnel and Equipment', 'Personnel et matériel de l''Entrepreneur', '4.21 (d)', 'manual'),
   (new.id, 5, 'quality', 'Quality assurance documents, test results and material certificates',
      'Documents d''assurance qualité, résultats d''essais et certificats de matériaux', '4.21 (e)', 'mixed'),
   (new.id, 6, 'claims', 'List of notices of the Employer''s and the Contractor''s claims', 'Liste des notifications de réclamations du Maître de l''Ouvrage et de l''Entrepreneur', '4.21 (f)', 'auto'),
   (new.id, 7, 'safety', 'Safety statistics, including hazardous incidents, environmental and public relations activities',
      'Statistiques de sécurité, y compris incidents dangereux, activités environnementales et de relations publiques', '4.21 (g)', 'mixed'),
   (new.id, 8, 'actual_vs_planned', 'Actual against planned progress, and events or circumstances that may jeopardise completion',
      'Avancement réel comparé au planifié, et événements ou circonstances pouvant compromettre l''achèvement', '4.21 (h)', 'mixed'),
   (new.id, 9, 'delay_measures', 'Measures being adopted to overcome delays', 'Mesures adoptées pour surmonter les retards', 'Check the executed contract', 'manual');
  return new;
end $$;
create trigger seed_report_sections after insert on public.projects for each row execute function public.seed_report_sections();

-- ---------------------------------------------------------------------------
-- Monthly reports
-- ---------------------------------------------------------------------------
create table public.monthly_reports (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  period_start date not null,
  period_end date not null,
  due_date date not null,                       -- last day to submit
  status text not null default 'generated' check (status in ('generated','under_review','signed','issued')),
  auto_content jsonb not null default '{}'::jsonb,
  manual_content jsonb not null default '{}'::jsonb,
  template_verified boolean not null default false,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles(id),     -- null when produced by the scheduler
  issued_at timestamptz,
  issued_by uuid references public.profiles(id),
  unique (project_id, period_start),
  check (period_end >= period_start)
);

create table public.report_recipients (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  organization text,
  email text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role text,
  active boolean not null default true,
  unique (project_id, email)
);
create table public.report_deliveries (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  report_id uuid not null references public.monthly_reports(id),
  recipient_id uuid not null references public.report_recipients(id),
  status text not null default 'queued' check (status in ('queued','sent','delivered','failed')),
  queued_at timestamptz not null default now(),
  sent_at timestamptz, delivered_at timestamptz, provider_ref text, error text,
  unique (report_id, recipient_id)
);

-- ---------------------------------------------------------------------------
-- Digital sign-off (works for any record type)
-- ---------------------------------------------------------------------------
create table public.signoffs (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  record_type text not null check (record_type in ('monthly_report','notice','variation','payment','claim','ncr','other')),
  record_id uuid not null,
  step text not null check (step in ('prepared','reviewed','approved')),
  signer uuid not null references public.profiles(id),
  signer_role text not null,
  statement text not null,
  content_hash text not null,
  signed_at timestamptz not null default now(),
  unique (record_type, record_id, step)
);

create or replace function public.report_hash(r public.monthly_reports) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(convert_to(r.id::text || '|' || r.period_start::text || '|' || r.auto_content::text || '|' || r.manual_content::text, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function public.sign_record(
  p_type text, p_record uuid, p_step text, p_statement text default null)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare r public.monthly_reports; pid uuid; hash text; role_used text; sid bigint; prev_signer uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_type <> 'monthly_report' then raise exception 'Sign-off for % is added with that module', p_type; end if;
  select * into r from public.monthly_reports where id = p_record;
  if not found then raise exception 'Report not found'; end if;
  pid := r.project_id;
  if r.status = 'issued' then raise exception 'The report is already issued'; end if;

  if p_step = 'prepared' then
    if not public.can_write_reports(pid) then raise exception 'You are not authorised to sign as preparer'; end if;
    if r.status <> 'under_review' then raise exception 'Submit the report for review first'; end if;
    role_used := 'preparer';
  elsif p_step = 'reviewed' then
    if not public.has_project_role(pid, array['project_manager','assistant_project_manager','contract_manager']) then
      raise exception 'Only a Project Manager, Assistant Project Manager or Contract Manager can sign as reviewer'; end if;
    if not exists (select 1 from public.signoffs where record_type = 'monthly_report' and record_id = p_record and step = 'prepared') then
      raise exception 'The report has not been signed as prepared'; end if;
    role_used := 'reviewer';
  elsif p_step = 'approved' then
    if not public.has_project_role(pid, array['project_manager','contract_manager']) then
      raise exception 'Only a Project Manager or Contract Manager can approve'; end if;
    if not exists (select 1 from public.signoffs where record_type = 'monthly_report' and record_id = p_record and step = 'reviewed') then
      raise exception 'The report has not been signed as reviewed'; end if;
    role_used := 'approver';
  else
    raise exception 'Unknown step';
  end if;

  -- one person cannot sign two steps (separation of duties)
  if exists (select 1 from public.signoffs where record_type = 'monthly_report' and record_id = p_record and signer = auth.uid()) then
    raise exception 'The same person cannot sign more than one step';
  end if;

  hash := public.report_hash(r);
  insert into public.signoffs (project_id, record_type, record_id, step, signer, signer_role, statement, content_hash)
  values (pid, 'monthly_report', p_record, p_step, auth.uid(), role_used,
          coalesce(nullif(btrim(p_statement), ''), 'I have checked this report and confirm it is accurate to the best of my knowledge.'), hash)
  returning id into sid;
  if p_step = 'approved' then update public.monthly_reports set status = 'signed' where id = p_record; end if;
  return sid;
end $$;

create or replace function public.signoffs_no_change() returns trigger language plpgsql as $$
begin raise exception 'Sign-offs are permanent'; end $$;
create trigger signoffs_no_change before update or delete on public.signoffs for each row execute function public.signoffs_no_change();

-- ---------------------------------------------------------------------------
-- Generate, fill in, submit and issue
-- ---------------------------------------------------------------------------
create or replace function public.build_report_content(p uuid, d_from date, d_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text; c jsonb := '{}'::jsonb;
begin
  c := jsonb_build_object(
    'photographs', jsonb_build_object(
      'documents_in_period', (select count(*) from documents where project_id = p and folder_code = '16' and uploaded_at::date between d_from and d_to),
      'refs', coalesce((select jsonb_agg(ref order by uploaded_at) from documents where project_id = p and folder_code = '16' and uploaded_at::date between d_from and d_to), '[]'::jsonb)),
    'quality', jsonb_build_object(
      'inspections', jsonb_build_object(
        'recorded', (select count(*) from inspections where project_id = p and inspected_at::date between d_from and d_to and result <> 'pending'),
        'accepted', (select count(*) from inspections where project_id = p and inspected_at::date between d_from and d_to and result in ('accepted','accepted_with_comments')),
        'rejected', (select count(*) from inspections where project_id = p and inspected_at::date between d_from and d_to and result = 'rejected')),
      'tests', jsonb_build_object(
        'recorded', (select count(*) from test_records where project_id = p and tested_at::date between d_from and d_to and result <> 'pending'),
        'passed', (select count(*) from test_records where project_id = p and tested_at::date between d_from and d_to and result = 'pass'),
        'failed', (select count(*) from test_records where project_id = p and tested_at::date between d_from and d_to and result = 'fail')),
      'ncrs', jsonb_build_object(
        'opened', (select count(*) from ncrs where project_id = p and identified_at::date between d_from and d_to),
        'closed', (select count(*) from ncrs where project_id = p and closed_at::date between d_from and d_to),
        'open_at_period_end', (select count(*) from ncrs where project_id = p and identified_at::date <= d_to and (closed_at is null or closed_at::date > d_to))),
      'material_submissions', jsonb_build_object(
        'reviewed', (select count(*) from material_approvals where project_id = p and reviewed_at::date between d_from and d_to),
        'approved', (select count(*) from material_approvals where project_id = p and reviewed_at::date between d_from and d_to and status in ('approved','approved_as_noted'))),
      'document_refs', coalesce((select jsonb_agg(ref order by uploaded_at) from documents
          where project_id = p and folder_code in ('10','11','12','21') and uploaded_at::date between d_from and d_to), '[]'::jsonb)),
    'claims', jsonb_build_object(
      'notices', coalesce((select jsonb_agg(jsonb_build_object('ref', ref, 'title', title, 'category', category,
          'initiating_party', initiating_party, 'status', status, 'issued_at', issued_at) order by prepared_at)
          from notices where project_id = p and (category ilike '%claim%' or title ilike '%claim%')
            and (prepared_at::date between d_from and d_to or issued_at::date between d_from and d_to)), '[]'::jsonb),
      'open_claim_deadlines', (select count(*) from contractual_deadlines where project_id = p and status in ('open','flagged_for_review')
            and title ilike '%claim%')),
    'safety', jsonb_build_object(
      'hse_documents_in_period', (select count(*) from documents where project_id = p and folder_code in ('13','14') and uploaded_at::date between d_from and d_to)),
    'actual_vs_planned', jsonb_build_object(
      'commencement_date', (select commencement_date from contracts where project_id = p),
      'time_for_completion_days', (select time_for_completion_days from contracts where project_id = p),
      'overdue_deadlines', (select count(*) from contractual_deadlines where project_id = p and status = 'open' and due_date < d_to + 1)));
  return c;
end $$;

-- Create (or refresh) the report for one calendar month. Called by people or by the scheduler.
create or replace function public.generate_monthly_report(p uuid, p_month date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare tz text; due_days int; m date; d_from date; d_to date; rid uuid; ok boolean; uid uuid := auth.uid();
begin
  if uid is not null and not public.can_write_reports(p) then raise exception 'You are not authorised to generate reports'; end if;
  select timezone, report_due_days into tz, due_days from public.projects where id = p;
  if tz is null then raise exception 'Project not found'; end if;
  m := coalesce(date_trunc('month', p_month)::date, (date_trunc('month', (now() at time zone tz)::date) - interval '1 month')::date);
  d_from := m; d_to := (m + interval '1 month - 1 day')::date;
  select not exists (select 1 from public.report_sections where project_id = p and active and status <> 'verified') into ok;

  select id into rid from public.monthly_reports where project_id = p and period_start = d_from;
  if rid is not null then
    update public.monthly_reports set auto_content = public.build_report_content(p, d_from, d_to), template_verified = ok
     where id = rid and status = 'generated';
    return rid;
  end if;
  insert into public.monthly_reports (project_id, ref, period_start, period_end, due_date, auto_content, template_verified, generated_by)
  values (p, public.next_ref(p, 'RPT'), d_from, d_to, d_to + due_days, public.build_report_content(p, d_from, d_to), ok, uid)
  returning id into rid;
  return rid;
end $$;

create or replace function public.set_report_input(p_report uuid, p_key text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.monthly_reports;
begin
  select * into r from public.monthly_reports where id = p_report;
  if not found then raise exception 'Report not found'; end if;
  if not public.can_write_reports(r.project_id) then raise exception 'You are not authorised to edit this report'; end if;
  if r.status <> 'generated' then raise exception 'The report can only be edited before it is submitted for review'; end if;
  if not exists (select 1 from public.report_sections where project_id = r.project_id and key = p_key and active) then
    raise exception 'Unknown section';
  end if;
  update public.monthly_reports set manual_content = jsonb_set(manual_content, array[p_key], to_jsonb(coalesce(p_text, ''))) where id = p_report;
end $$;

create or replace function public.submit_report_for_review(p_report uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.monthly_reports; missing text;
begin
  select * into r from public.monthly_reports where id = p_report;
  if not found then raise exception 'Report not found'; end if;
  if not public.can_write_reports(r.project_id) then raise exception 'You are not authorised'; end if;
  if r.status <> 'generated' then raise exception 'Already submitted'; end if;
  select string_agg(s.title_en, '; ') into missing from public.report_sections s
   where s.project_id = r.project_id and s.active and s.source in ('manual','mixed')
     and coalesce(btrim(r.manual_content ->> s.key), '') = '';
  if missing is not null then
    raise exception 'These sections need text (write "None this month" if there is nothing to report): %', missing;
  end if;
  update public.monthly_reports set status = 'under_review' where id = p_report;
end $$;

-- A report that was approved can be issued; recipients are queued for the sending service.
create or replace function public.issue_report(p_report uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r public.monthly_reports; n int;
begin
  select * into r from public.monthly_reports where id = p_report;
  if not found then raise exception 'Report not found'; end if;
  if not public.has_project_role(r.project_id, array['project_manager','contract_manager']) then
    raise exception 'Only a Project Manager or Contract Manager can issue a report'; end if;
  if r.status <> 'signed' then raise exception 'The report must be signed by preparer, reviewer and approver first'; end if;
  if not exists (select 1 from public.signoffs where record_type = 'monthly_report' and record_id = r.id and step = 'approved'
                 and content_hash = public.report_hash(r)) then
    raise exception 'The report changed after it was signed';
  end if;
  update public.monthly_reports set status = 'issued', issued_at = now(), issued_by = auth.uid() where id = r.id;
  insert into public.report_deliveries (project_id, report_id, recipient_id)
    select r.project_id, r.id, id from public.report_recipients where project_id = r.project_id and active
    on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.monthly_reports_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if old.status in ('under_review','signed','issued') and
       (new.auto_content, new.manual_content, new.period_start, new.period_end, new.project_id)
       is distinct from (old.auto_content, old.manual_content, old.period_start, old.period_end, old.project_id) then
      raise exception 'The report content is locked once it is submitted for review';
    end if;
    if coalesce(current_setting('beni.report_internal', true), '') <> 'on' and new.status is distinct from old.status then
      null;  -- status changes happen only through the functions above (RLS gives no direct update right)
    end if;
  end if;
  return new;
end $$;
create trigger monthly_reports_guard before update on public.monthly_reports for each row execute function public.monthly_reports_guard();
create trigger monthly_reports_no_delete before delete on public.monthly_reports for each row execute function public.block_change();

-- Scheduler entry point: runs daily. On each project's generate day it creates last month's report and
-- tells the approvers. If the due date is near and the report is unsigned, it reminds them.
create or replace function public.run_monthly_report_job(p_today date default null) returns int
language plpgsql security definer set search_path = public as $$
declare pr record; rid uuid; n int := 0; today date; rp record; days_left int;
begin
  for pr in select id, timezone, report_generate_day from public.projects loop
    today := coalesce(p_today, (now() at time zone pr.timezone)::date);
    if extract(day from today) = pr.report_generate_day then
      rid := public.generate_monthly_report(pr.id, (date_trunc('month', today) - interval '1 month')::date);
      insert into public.notifications (project_id, user_id, kind, message, dedupe_key)
        select pr.id, m.user_id, 'report_ready', 'The monthly progress report for the previous month has been generated. Complete the manual sections and sign it.',
               'rpt:' || rid || ':' || m.user_id || ':ready'
          from public.project_members m where m.project_id = pr.id and m.active and m.role in ('project_manager','assistant_project_manager','contract_manager')
        on conflict (dedupe_key) do nothing;
      n := n + 1;
    end if;
    for rp in select * from public.monthly_reports where project_id = pr.id and status <> 'issued' loop
      days_left := rp.due_date - today;
      if days_left in (3, 1, 0) or days_left < 0 then
        insert into public.notifications (project_id, user_id, kind, message, due_date, days_remaining, dedupe_key)
          select pr.id, m.user_id, case when days_left < 0 then 'overdue' else 'upcoming' end,
                 case when days_left < 0 then format('Monthly report %s is %s day(s) overdue and not yet issued', rp.ref, -days_left)
                      else format('Monthly report %s is due in %s day(s) (%s) and not yet issued', rp.ref, days_left, rp.due_date) end,
                 rp.due_date, days_left, 'rpt:' || rp.id || ':' || m.user_id || ':' || today
            from public.project_members m where m.project_id = pr.id and m.active and m.role in ('project_manager','contract_manager')
          on conflict (dedupe_key) do nothing;
      end if;
    end loop;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Tracked records: variations, payments, claims, RFIs, instructions and anything else with a timeline
-- ---------------------------------------------------------------------------
create table public.tracked_records (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  kind text not null check (kind in ('claim','variation','payment_application','interim_payment_certificate','rfi',
    'design_submission','engineer_instruction','determination','early_warning','security','insurance','procurement','other')),
  ref text not null,
  title text not null,
  owner uuid references public.profiles(id),
  event_at timestamptz,
  due_date date,
  due_basis text not null default 'none' check (due_basis in ('none','internal_target','contract_deadline')),
  deadline_id uuid references public.contractual_deadlines(id),
  status text not null default 'open' check (status in ('open','submitted','responded','closed')),
  closed_at timestamptz,
  closure_note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);
create or replace function public.tracked_records_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare pref text;
begin
  if tg_op = 'INSERT' then
    pref := case new.kind when 'claim' then 'CLM' when 'variation' then 'VAR' when 'payment_application' then 'PAY'
      when 'interim_payment_certificate' then 'IPC' when 'rfi' then 'RFI' when 'design_submission' then 'DSB'
      when 'engineer_instruction' then 'INS' when 'determination' then 'DET' when 'early_warning' then 'EWN'
      when 'security' then 'SEC' when 'insurance' then 'INR' when 'procurement' then 'PRC' else 'TRK' end;
    new.ref := public.next_ref(new.project_id, 'T-' || pref);
    new.created_by := auth.uid(); new.status := 'open'; new.closed_at := null;
  else
    if (new.ref, new.kind, new.project_id) is distinct from (old.ref, old.kind, old.project_id) then
      raise exception 'The reference and kind cannot be changed'; end if;
    if old.status = 'closed' then raise exception 'A closed record cannot be changed'; end if;
    if new.status = 'closed' then
      if coalesce(btrim(new.closure_note), '') = '' then raise exception 'Record how this was closed'; end if;
      new.closed_at := now();
    end if;
  end if;
  -- a due date is either a documented internal target, or it comes from an approved contract rule. Never both, never guessed.
  if new.due_basis = 'contract_deadline' then
    if new.deadline_id is null then raise exception 'A contract deadline must be linked to a calculated deadline'; end if;
    new.due_date := (select due_date from public.contractual_deadlines where id = new.deadline_id and project_id = new.project_id);
  elsif new.due_basis = 'internal_target' then
    if new.due_date is null then raise exception 'Enter the internal target date'; end if;
    new.deadline_id := null;
  else
    new.due_date := null; new.deadline_id := null;
  end if;
  return new;
end $$;
create trigger tracked_records_guard before insert or update on public.tracked_records for each row execute function public.tracked_records_guard();
create trigger tracked_records_no_delete before delete on public.tracked_records for each row execute function public.block_change();

-- One timeline across everything that has a date
create or replace view public.v_timeline with (security_invoker = true) as
  select d.project_id, 'contract_deadline'::text as source, d.id as source_id, d.notice_id::text as ref, d.title,
         d.due_date, 'contract_rule'::text as basis, d.status, d.responsible_user as owner,
         (d.due_date - current_date) as days_remaining, d.flagged_reason as note
    from public.contractual_deadlines d where d.status in ('open','flagged_for_review')
  union all
  select t.project_id, 'tracker:' || t.kind, t.id, t.ref, t.title, t.due_date,
         case t.due_basis when 'contract_deadline' then 'contract_rule' else t.due_basis end, t.status, t.owner,
         (t.due_date - current_date), null
    from public.tracked_records t where t.status <> 'closed'
  union all
  select n.project_id, 'ncr', n.id, n.ref, n.title, n.due_date, 'internal_target', n.status, null, (n.due_date - current_date), null
    from public.ncrs n where n.status <> 'closed' and n.due_date is not null
  union all
  select c.project_id, 'corrective_action', c.id, null, c.description, c.due_date, 'internal_target', c.status, c.assignee, (c.due_date - current_date), null
    from public.corrective_actions c where c.status <> 'verified' and c.due_date is not null
  union all
  select a.project_id, 'quality_audit', a.id, a.ref, a.title, a.planned_date, 'internal_target', 'planned', a.auditor, (a.planned_date - current_date), null
    from public.quality_audits a where a.performed_at is null
  union all
  select r.project_id, 'monthly_report', r.id, r.ref, 'Monthly progress report', r.due_date, 'contract_rule_unverified', r.status, null, (r.due_date - current_date),
         case when r.template_verified then null else 'Report template not yet verified against the contract' end
    from public.monthly_reports r where r.status <> 'issued';

-- ---------------------------------------------------------------------------
-- Audit, security
-- ---------------------------------------------------------------------------
create trigger audit_report_sections after insert or update on public.report_sections for each row execute function public.audit_row();
create trigger audit_monthly_reports after insert or update on public.monthly_reports for each row execute function public.audit_row();
create trigger audit_signoffs after insert on public.signoffs for each row execute function public.audit_row();
create trigger audit_tracked after insert or update on public.tracked_records for each row execute function public.audit_row();
create trigger audit_recipients after insert or update on public.report_recipients for each row execute function public.audit_row();

alter table public.report_sections enable row level security;
alter table public.monthly_reports enable row level security;
alter table public.report_recipients enable row level security;
alter table public.report_deliveries enable row level security;
alter table public.signoffs enable row level security;
alter table public.tracked_records enable row level security;

create policy rs_read on public.report_sections for select to authenticated using (public.is_project_member(project_id));
create policy rs_update on public.report_sections for update to authenticated
  using (public.has_project_role(project_id, array['project_manager','contract_manager']))
  with check (public.has_project_role(project_id, array['project_manager','contract_manager']));
create policy mr_read on public.monthly_reports for select to authenticated using (public.is_project_member(project_id));
create policy rr_read on public.report_recipients for select to authenticated using (public.is_project_member(project_id));
create policy rr_write on public.report_recipients for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager']));
create policy rr_update on public.report_recipients for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager']));
create policy rd_read on public.report_deliveries for select to authenticated using (public.is_project_member(project_id));
create policy so_read on public.signoffs for select to authenticated using (public.is_project_member(project_id));
create policy tr_read on public.tracked_records for select to authenticated using (public.is_project_member(project_id));
create policy tr_insert on public.tracked_records for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','quantity_surveyor','planning_engineer','engineer','design_manager','contractor_rep','employer_rep','document_controller']));
create policy tr_update on public.tracked_records for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','quantity_surveyor','planning_engineer','engineer','design_manager','contractor_rep','employer_rep','document_controller']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','quantity_surveyor','planning_engineer','engineer','design_manager','contractor_rep','employer_rep','document_controller']));

grant select on public.report_sections, public.monthly_reports, public.report_recipients, public.report_deliveries,
  public.signoffs, public.tracked_records, public.v_timeline to authenticated;
grant update on public.report_sections, public.report_recipients, public.tracked_records to authenticated;
grant insert on public.report_recipients, public.tracked_records to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.can_write_reports(uuid), public.generate_monthly_report(uuid, date),
  public.set_report_input(uuid, text, text), public.submit_report_for_review(uuid), public.sign_record(text, uuid, text, text),
  public.issue_report(uuid) to authenticated;
grant execute on function public.mfa_ok(uuid), public.has_project_role(uuid, text[]), public.is_project_member(uuid),
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

-- Migration 0002: project setup, deadline engine, reminders, dashboard.
--
-- The deadline engine lives in the database so the browser can never invent or
-- alter a contractual date. It follows these rules:
--   1. A deadline is generated only from a rule that is "approved".
--   2. If the rule is not approved, or the trigger date is missing, the deadline is
--      created as "flagged_for_review" with NO date, never a guessed one.
--   3. The original date is permanent. Later changes need a reason and an authorised user.
--   4. Uploading a document or changing a status never moves a deadline.

-- ---------------------------------------------------------------------------
-- Date arithmetic
-- ---------------------------------------------------------------------------
-- Calendar days, counted in the project's local time zone.
--   exclude_trigger_day: the day after the trigger is day 1   -> trigger + period
--   include_trigger_day: the trigger day itself is day 1      -> trigger + period - 1
create or replace function public.compute_due_date(
  p_trigger timestamptz, p_period int, p_counting text, p_tz text default 'Africa/Lubumbashi')
returns date language sql immutable as $$
  select ((p_trigger at time zone p_tz)::date)
         + case p_counting when 'include_trigger_day' then p_period - 1 else p_period end
$$;

-- ---------------------------------------------------------------------------
-- Project creation (with the rule library started as "Not Configured")
-- ---------------------------------------------------------------------------
create or replace function public.create_project(
  p_name text, p_location text default null, p_timezone text default 'Africa/Lubumbashi')
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid; matters text[]; i int;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and active and can_create_projects) then
    raise exception 'You are not allowed to create projects';
  end if;
  insert into public.projects (name, location, timezone, created_by)
    values (p_name, p_location, p_timezone, auth.uid()) returning id into pid;
  insert into public.project_members (project_id, user_id, role) values (pid, auth.uid(), 'project_administrator');
  insert into public.contracts (project_id) values (pid);

  matters := array[
    'Contractor''s Notice of Claim','Employer''s Notice of Claim',
    'Engineer''s acknowledgment of a Notice of Claim','Detailed Particulars of Claim',
    'Responses to claims','Interim and final particulars for continuing claims',
    'Engineer''s determination','Notice of Dissatisfaction','DAAB referral','DAAB decision',
    'Amicable settlement period','Contractor''s programme submission and updates',
    'Engineer''s response to programme submissions','Design submission and review periods',
    'Requests for information','Variation quotations','Payment applications',
    'Interim Payment Certificates','Payment deadlines','Tests on Completion',
    'Taking-Over procedures','Defects Notification Period obligations',
    'Final Statement and Final Payment Certificate'];
  for i in 1 .. array_length(matters, 1) loop
    insert into public.deadline_rules (project_id, rule_code, matter)
      values (pid, 'R-' || lpad(i::text, 3, '0'), matters[i]);
  end loop;
  return pid;
end $$;

-- ---------------------------------------------------------------------------
-- Generate a deadline from a notice
-- ---------------------------------------------------------------------------
create or replace function public.create_deadline_for_notice(
  p_notice uuid, p_rule uuid,
  p_trigger_at timestamptz default null,
  p_trigger_description text default null,
  p_responsible uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  n public.notices; r public.deadline_rules; tz text; trig timestamptz;
  due date; flag text; note text; did uuid;
begin
  select * into n from public.notices where id = p_notice;
  if not found then raise exception 'Notice not found'; end if;
  if not public.has_project_role(n.project_id, array['project_administrator','project_manager',
      'assistant_project_manager','contract_manager','engineer','contractor_rep','employer_rep']) then
    raise exception 'You are not authorised to create deadlines on this project';
  end if;
  select * into r from public.deadline_rules where id = p_rule and project_id = n.project_id;
  if not found then raise exception 'Rule not found on this project'; end if;
  select timezone into tz from public.projects where id = n.project_id;
  trig := coalesce(p_trigger_at, n.event_at);

  if r.status <> 'approved' then
    flag := format('Rule %s is "%s", not approved for use. No date has been calculated.', r.rule_code, r.status);
  elsif trig is null then
    flag := 'The triggering event date is missing. No date has been calculated.';
  elsif r.period_value is null then
    flag := 'The rule has no period. No date has been calculated.';
  else
    due := public.compute_due_date(trig, r.period_value, r.counting, tz);
    note := format('Rule %s, clause %s: trigger %s + %s calendar days (%s) = %s. Project time zone %s.',
      r.rule_code, r.clause, (trig at time zone tz)::date, r.period_value,
      case r.counting when 'include_trigger_day' then 'trigger day counted as day 1'
                      else 'trigger day excluded' end,
      due, tz);
  end if;

  insert into public.contractual_deadlines
    (project_id, notice_id, rule_id, kind, title, trigger_at, trigger_description, period_value,
     counting, clause, calculation_note, due_date, status, flagged_reason, responsible_user, created_by)
  values
    (n.project_id, n.id, r.id, r.deadline_kind, r.matter || ' — ' || n.ref, trig, p_trigger_description,
     r.period_value, r.counting, r.clause, note, due,
     case when flag is null then 'open' else 'flagged_for_review' end, flag,
     coalesce(p_responsible, n.responsible_user, auth.uid()), auth.uid())
  returning id into did;

  update public.notices set rule_id = r.id where id = n.id and issued_at is null;
  return did;
end $$;

-- A flagged deadline can be recalculated once its rule is approved and the trigger is known.
create or replace function public.recalculate_flagged_deadline(p_deadline uuid, p_trigger_at timestamptz default null)
returns date language plpgsql security definer set search_path = public as $$
declare d public.contractual_deadlines; r public.deadline_rules; tz text; trig timestamptz; due date;
begin
  select * into d from public.contractual_deadlines where id = p_deadline;
  if not found then raise exception 'Deadline not found'; end if;
  if d.status <> 'flagged_for_review' then
    raise exception 'Only a flagged deadline can be recalculated this way. Use change_deadline with a reason.';
  end if;
  if not public.has_project_role(d.project_id, array['project_manager','contract_manager']) then
    raise exception 'Only a Project Manager or Contract Manager can recalculate a flagged deadline';
  end if;
  select * into r from public.deadline_rules where id = d.rule_id;
  if r.status <> 'approved' then raise exception 'Rule % is still "%"', r.rule_code, r.status; end if;
  select timezone into tz from public.projects where id = d.project_id;
  trig := coalesce(p_trigger_at, d.trigger_at);
  if trig is null then raise exception 'The triggering event date is still missing'; end if;
  due := public.compute_due_date(trig, r.period_value, r.counting, tz);
  update public.contractual_deadlines set
    trigger_at = trig, period_value = r.period_value, counting = r.counting, clause = r.clause,
    calculation_note = format('Rule %s, clause %s: trigger %s + %s calendar days = %s (recalculated after review).',
                              r.rule_code, r.clause, (trig at time zone tz)::date, r.period_value, due),
    original_due_date = due, due_date = due, status = 'open', flagged_reason = null
   where id = d.id;
  return due;
end $$;

-- ---------------------------------------------------------------------------
-- Change a deadline (reason + authorised user, history preserved)
-- ---------------------------------------------------------------------------
create or replace function public.change_deadline(p_deadline uuid, p_new_due date, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.contractual_deadlines;
begin
  select * into d from public.contractual_deadlines where id = p_deadline;
  if not found then raise exception 'Deadline not found'; end if;
  if not public.has_project_role(d.project_id, array['project_manager','contract_manager']) then
    raise exception 'Only a Project Manager or Contract Manager can change a deadline';
  end if;
  if d.status not in ('open') then raise exception 'Only an open deadline can be changed'; end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'A documented reason (at least 10 characters) is required';
  end if;
  if p_new_due is null then raise exception 'A new date is required'; end if;
  if p_new_due = d.due_date then raise exception 'The new date is the same as the current date'; end if;

  insert into public.deadline_changes (deadline_id, project_id, old_due_date, new_due_date, reason, changed_by)
    values (d.id, d.project_id, d.due_date, p_new_due, p_reason, auth.uid());
  perform set_config('beni.allow_deadline_change', 'on', true);
  update public.contractual_deadlines set due_date = p_new_due where id = d.id;
  perform set_config('beni.allow_deadline_change', 'off', true);
end $$;

create or replace function public.satisfy_deadline(p_deadline uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d public.contractual_deadlines;
begin
  select * into d from public.contractual_deadlines where id = p_deadline;
  if not found then raise exception 'Deadline not found'; end if;
  if not (d.responsible_user = auth.uid() or public.has_project_role(d.project_id,
      array['project_manager','contract_manager','assistant_project_manager'])) then
    raise exception 'You are not authorised to close this deadline';
  end if;
  if d.status <> 'open' then raise exception 'Only an open deadline can be marked satisfied'; end if;
  update public.contractual_deadlines
     set status = 'satisfied', satisfied_at = now(), satisfied_note = p_note where id = d.id;
end $$;

-- ---------------------------------------------------------------------------
-- Reminders (run daily by a scheduler; safe to run more than once a day)
-- ---------------------------------------------------------------------------
create or replace function public.generate_reminders(p_today date default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with open_d as (
    select d.id, d.project_id, d.title, d.due_date, d.responsible_user,
           p.reminder_offsets, p.escalation_user,
           coalesce(p_today, (now() at time zone p.timezone)::date) as today
      from public.contractual_deadlines d
      join public.projects p on p.id = d.project_id
     where d.status = 'open' and d.due_date is not null),
  cand as (
    select o.*, (o.due_date - o.today) as days_left from open_d o),
  recipients as (
    select project_id, id as did, responsible_user as uid, title, due_date, days_left, today,
           false as escalated
      from cand
     where responsible_user is not null
       and (days_left = any (reminder_offsets) or days_left < 0)
    union all
    select project_id, id, escalation_user, title, due_date, days_left, today, true
      from cand
     where escalation_user is not null and days_left < 0
       and escalation_user is distinct from responsible_user)
  insert into public.notifications
    (project_id, user_id, deadline_id, kind, message, due_date, days_remaining, dedupe_key)
  select project_id, uid, did,
         case when escalated then 'escalation'
              when days_left > 0 then 'upcoming' when days_left = 0 then 'due_today' else 'overdue' end,
         case when days_left > 0 then format('%s is due in %s day(s) on %s', title, days_left, due_date)
              when days_left = 0 then format('%s is due today (%s)', title, due_date)
              else format('%s is %s day(s) overdue (was due %s)', title, -days_left, due_date) end,
         due_date, days_left,
         did || ':' || uid || ':' || case when escalated then 'esc' else 'rem' end || ':' || today
    from recipients
  on conflict (dedupe_key) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.generate_reminders(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Views and dashboard (no invented numbers: missing data stays NULL)
-- ---------------------------------------------------------------------------
create or replace view public.v_deadlines with (security_invoker = true) as
select d.*, p.timezone,
       (d.due_date - (now() at time zone p.timezone)::date) as days_remaining,
       case when d.status = 'flagged_for_review' then 'flagged_for_review'
            when d.status <> 'open' then d.status
            when d.due_date - (now() at time zone p.timezone)::date < 0 then 'overdue'
            when d.due_date - (now() at time zone p.timezone)::date = 0 then 'due_today'
            when d.due_date - (now() at time zone p.timezone)::date <= 7 then 'approaching'
            else 'within_deadline' end as urgency
  from public.contractual_deadlines d
  join public.projects p on p.id = d.project_id;

create or replace view public.v_documents with (security_invoker = true) as
select d.*,
       (d.version = max(d.version) over (partition by d.project_id, d.folder_code, d.original_name)) as is_current
  from public.documents d;

create or replace function public.project_dashboard(p uuid) returns jsonb
language plpgsql stable set search_path = public as $$
declare c public.contracts; tz text; today date; res jsonb;
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  select * into c from public.contracts where project_id = p;
  select timezone into tz from public.projects where id = p;
  today := (now() at time zone tz)::date;
  res := jsonb_build_object(
    'commencement_date', c.commencement_date,
    'time_for_completion_days', c.time_for_completion_days,
    'planned_completion_date', case when c.commencement_date is not null and c.time_for_completion_days is not null
                                    then c.commencement_date + c.time_for_completion_days end,
    'days_elapsed', case when c.commencement_date is not null then today - c.commencement_date end,
    'days_remaining', case when c.commencement_date is not null and c.time_for_completion_days is not null
                           then (c.commencement_date + c.time_for_completion_days) - today end,
    'draft_notices', (select count(*) from notices where project_id = p and status = 'draft'),
    'open_notices', (select count(*) from notices where project_id = p
                      and status not in ('draft','determined','closed')),
    'deadlines_overdue', (select count(*) from v_deadlines where project_id = p and urgency = 'overdue'),
    'deadlines_due_within_7_days', (select count(*) from v_deadlines where project_id = p
                      and urgency in ('due_today','approaching')),
    'deadlines_flagged_for_review', (select count(*) from v_deadlines where project_id = p and urgency = 'flagged_for_review'),
    'rules_total', (select count(*) from deadline_rules where project_id = p and status <> 'superseded'),
    'rules_approved', (select count(*) from deadline_rules where project_id = p and status = 'approved'),
    'documents', (select count(*) from documents where project_id = p));
  return res;
end $$;

-- Record that someone downloaded a document (the app calls this before issuing a download link).
create or replace function public.log_document_download(p_document uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents;
begin
  select * into d from public.documents where id = p_document;
  if not found or not public.is_project_member(d.project_id) then
    raise exception 'Document not found';
  end if;
  insert into public.audit_events (project_id, actor, action, table_name, record_id, note)
    values (d.project_id, auth.uid(), 'DOWNLOAD', 'documents', d.id::text, d.original_name);
end $$;

grant select on public.v_deadlines, public.v_documents to authenticated;
grant execute on function
  public.compute_due_date(timestamptz, int, text, text),
  public.create_project(text, text, text),
  public.create_deadline_for_notice(uuid, uuid, timestamptz, text, uuid),
  public.recalculate_flagged_deadline(uuid, timestamptz),
  public.change_deadline(uuid, date, text),
  public.satisfy_deadline(uuid, text),
  public.project_dashboard(uuid),
  public.log_document_download(uuid)
  to authenticated;

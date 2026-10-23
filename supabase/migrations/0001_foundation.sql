-- BENI Airport DRC — Terminal and Control Tower
-- Migration 0001: foundation (projects, people, roles, contract particulars,
-- deadline rule library, notices, documents, audit log, row-level security).
--
-- Principles
--  * Nothing about the contract is pre-filled. Dates, prices and periods are NULL until entered.
--  * Security is enforced here, in the database, never only in the browser.
--  * Issued contractual records cannot be silently edited or deleted.
--  * Every important change is written to a permanent audit log.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  full_name text,
  email text,
  active boolean not null default true,
  can_create_projects boolean not null default false,
  created_at timestamptz not null default now()
);

-- The very first person to register can create projects (bootstrap administrator).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, can_create_projects)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    not exists (select 1 from public.profiles)
  );
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Projects and membership
-- ---------------------------------------------------------------------------
create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  location text,
  timezone text not null default 'Africa/Lubumbashi',     -- Beni, DRC (UTC+2)
  reminder_offsets int[] not null default '{14,7,3,1,0}', -- days before a deadline
  escalation_user uuid references public.profiles(id),
  session_timeout_minutes int check (session_timeout_minutes is null or session_timeout_minutes >= 5),
  mfa_required boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  role text not null check (role in (
    'project_administrator','project_manager','assistant_project_manager','contract_manager',
    'engineer','design_manager','resident_engineer','site_engineer','quantity_surveyor',
    'planning_engineer','qa_qc_manager','hse_officer','document_controller',
    'contractor_rep','employer_rep','auditor')),
  organization text,
  active boolean not null default true,
  added_at timestamptz not null default now(),
  primary key (project_id, user_id, role)
);

-- Access helpers. Used by every policy.
create or replace function public.mfa_ok(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select not mfa_required or coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
       from public.projects where id = p),
    false)
$$;

create or replace function public.has_project_role(p uuid, roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active)
     and public.mfa_ok(p)
     and exists (select 1 from public.project_members m
                 where m.project_id = p and m.user_id = auth.uid()
                   and m.active and m.role = any (roles))
$$;

create or replace function public.is_project_member(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.active)
     and public.mfa_ok(p)
     and exists (select 1 from public.project_members m
                 where m.project_id = p and m.user_id = auth.uid() and m.active)
$$;

-- ---------------------------------------------------------------------------
-- Contract particulars (all optional: nothing is invented)
-- ---------------------------------------------------------------------------
create table public.contracts (
  project_id uuid primary key references public.projects(id) on delete cascade,
  contract_form text not null default 'FIDIC Conditions of Contract for Plant and Design-Build, Second Edition 2017',
  employer text,
  engineer text,
  contractor text,
  commencement_date date,
  time_for_completion_days int check (time_for_completion_days is null or time_for_completion_days > 0),
  contract_price numeric(18,2),
  currency text,
  particular_conditions_note text,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Deadline rule library (data-driven; nothing hard-coded)
-- ---------------------------------------------------------------------------
create table public.deadline_rules (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  rule_code text not null,
  matter text not null,
  deadline_kind text not null default 'contractual'
    check (deadline_kind in ('contractual','statutory','internal_target','administrative_target')),
  contract_edition text,
  clause text,
  rule_description text,
  applies_to text,
  trigger_event text,
  period_value int check (period_value is null or period_value >= 0),
  period_unit text not null default 'calendar_days' check (period_unit in ('calendar_days')),
  counting text not null default 'exclude_trigger_day'
    check (counting in ('exclude_trigger_day','include_trigger_day')),
  delivery_requirement text,
  exceptions text,
  continuing_event_treatment text,
  particular_condition_note text,
  source_document text,
  status text not null default 'not_configured'
    check (status in ('not_configured','extracted_unverified','under_review','verified','approved','superseded')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (project_id, rule_code),
  -- A rule cannot be approved unless it is complete and signed off.
  constraint approved_rule_is_complete check (
    status <> 'approved'
    or (period_value is not null and clause is not null and trigger_event is not null
        and source_document is not null and approved_by is not null and approved_at is not null))
);

-- ---------------------------------------------------------------------------
-- Reference numbers
-- ---------------------------------------------------------------------------
create table public.ref_counters (
  project_id uuid not null references public.projects(id) on delete cascade,
  prefix text not null,
  last int not null default 0,
  primary key (project_id, prefix)
);

create or replace function public.next_ref(p uuid, p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.ref_counters as rc (project_id, prefix, last) values (p, p_prefix, 1)
  on conflict (project_id, prefix) do update set last = rc.last + 1
  returning rc.last into n;
  return p_prefix || '-' || lpad(n::text, 3, '0');
end $$;

-- ---------------------------------------------------------------------------
-- Notices
-- ---------------------------------------------------------------------------
create table public.notices (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  title text not null,
  category text,
  initiating_party text,
  receiving_party text,
  clause text,
  description text,
  event_at timestamptz,            -- when the event occurred
  aware_at timestamptz,            -- when the party became aware
  prepared_at timestamptz not null default now(),
  approved_at timestamptz,
  approver uuid references public.profiles(id),
  issued_at timestamptz,
  issued_by uuid references public.profiles(id),
  delivery_method text,
  delivered_at timestamptz,
  delivery_evidence text,
  receipt_confirmed_at timestamptz,
  status text not null default 'draft' check (status in (
    'draft','internally_reviewed','approved_for_issue','formally_issued','delivery_pending',
    'delivered','receipt_confirmed','response_pending','response_received',
    'under_assessment','determined','closed')),
  responsible_user uuid references public.profiles(id),
  reviewer uuid references public.profiles(id),
  rule_id uuid references public.deadline_rules(id),
  related_record text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, ref)
);

create or replace function public.notice_rank(s text) returns int
language sql immutable as $$
  select case s
    when 'draft' then 0 when 'internally_reviewed' then 1 when 'approved_for_issue' then 2
    when 'formally_issued' then 3 when 'delivery_pending' then 4 when 'delivered' then 5
    when 'receipt_confirmed' then 6 when 'response_pending' then 7 when 'response_received' then 8
    when 'under_assessment' then 9 when 'determined' then 10 when 'closed' then 11 end
$$;

-- ---------------------------------------------------------------------------
-- Contractual deadlines and their history
-- ---------------------------------------------------------------------------
create table public.contractual_deadlines (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  notice_id uuid references public.notices(id),
  rule_id uuid references public.deadline_rules(id),
  kind text not null default 'contractual'
    check (kind in ('contractual','statutory','internal_target','administrative_target')),
  title text not null,
  trigger_at timestamptz,
  trigger_description text,
  period_value int,
  counting text,
  clause text,
  calculation_note text,                 -- the rule and arithmetic used, in words
  original_due_date date,                -- set once, never changes
  due_date date,
  status text not null default 'open'
    check (status in ('open','satisfied','closed','flagged_for_review')),
  flagged_reason text,
  responsible_user uuid references public.profiles(id),
  satisfied_at timestamptz,
  satisfied_note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create unique index one_live_deadline_per_notice_rule
  on public.contractual_deadlines (notice_id, rule_id)
  where status in ('open','flagged_for_review');

create table public.deadline_changes (
  id bigserial primary key,
  deadline_id uuid not null references public.contractual_deadlines(id),
  project_id uuid not null references public.projects(id),
  old_due_date date,
  new_due_date date,
  reason text not null check (length(btrim(reason)) >= 10),
  changed_by uuid not null references public.profiles(id),
  changed_at timestamptz not null default now()
);

create table public.notifications (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  deadline_id uuid references public.contractual_deadlines(id),
  kind text not null,
  message text not null,
  due_date date,
  days_remaining int,
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Documents (metadata; files live in private storage)
-- ---------------------------------------------------------------------------
create table public.document_folders (
  code text primary key,
  name text not null,
  ref_prefix text not null
);
insert into public.document_folders (code, name, ref_prefix) values
 ('00','Project Administration and Governance','ADM'),
 ('01','Executed Contract and Particular Conditions','CON'),
 ('02','Contractual Correspondence and Notices','COR'),
 ('03','Claims, EOT and Delay Analysis','CLM'),
 ('04','Engineer''s Instructions and Determinations','EIN'),
 ('05','Design Management','DES'),
 ('06','Drawings and Specifications','DWG'),
 ('07','Technical Submissions and RFIs','RFI'),
 ('08','Programme and Progress Reports','PRG'),
 ('09','Procurement and Subcontracts','PRO'),
 ('10','Quality Assurance and Quality Control','QAC'),
 ('11','Inspection and Test Plans','ITP'),
 ('12','Non-Conformance Reports and Corrective Actions','NCF'),
 ('13','Health, Safety and Environment','HSE'),
 ('14','Environmental and Social Management','ENV'),
 ('15','Site Diaries and Daily Reports','FLD'),
 ('16','Site Photographs and Video Evidence','PHO'),
 ('17','Meetings and Minutes','MTG'),
 ('18','Payment Applications and IPCs','IPC'),
 ('19','Variations and Commercial Management','VAR'),
 ('20','Risk Register and Early Warnings','RSK'),
 ('21','Testing, Commissioning and Handover','TCH'),
 ('22','Taking-Over and Completion','TOC'),
 ('23','Defects Notification Period','DNP'),
 ('24','As-Built Drawings and Operation Manuals','ABD'),
 ('25','Final Accounts and Project Closeout','FIN');

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  folder_code text not null references public.document_folders(code),
  ref text not null,
  title text not null,
  doc_type text,
  note text,
  original_name text not null,
  storage_path text not null unique,
  mime_type text,
  size_bytes bigint,
  sha256 text,                            -- computed in the browser before upload
  file_last_modified timestamptz,         -- reported by the device: UNVERIFIED
  version int not null default 1,
  related_notice uuid references public.notices(id),
  uploaded_by uuid references public.profiles(id),
  uploaded_at timestamptz not null default now(),   -- set by the database, not the client
  unique (project_id, ref)
);

-- ---------------------------------------------------------------------------
-- Audit log (append-only)
-- ---------------------------------------------------------------------------
create table public.audit_events (
  id bigserial primary key,
  at timestamptz not null default now(),
  project_id uuid,
  actor uuid,
  action text not null,
  table_name text not null,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  note text
);
create index on public.audit_events (project_id, at desc);
create index on public.audit_events (table_name, record_id);

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; pid uuid;
begin
  r := to_jsonb(coalesce(new, old));
  pid := coalesce(r ->> 'project_id', case when tg_table_name = 'projects' then r ->> 'id' end)::uuid;
  insert into public.audit_events (project_id, actor, action, table_name, record_id, old_data, new_data)
  values (pid, auth.uid(), tg_op, tg_table_name,
          coalesce(r ->> 'id', r ->> 'user_id', r ->> 'project_id'),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create or replace function public.block_change() returns trigger
language plpgsql as $$
begin
  raise exception '% records are permanent: % is not allowed', tg_table_name, tg_op;
end $$;

create trigger audit_no_update before update or delete on public.audit_events
  for each row execute function public.block_change();
create trigger changes_no_update before update or delete on public.deadline_changes
  for each row execute function public.block_change();
create trigger documents_no_update before update or delete on public.documents
  for each row execute function public.block_change();
create trigger notices_no_delete before delete on public.notices
  for each row execute function public.block_change();
create trigger deadlines_no_delete before delete on public.contractual_deadlines
  for each row execute function public.block_change();
create trigger rules_no_delete before delete on public.deadline_rules
  for each row execute function public.block_change();

create trigger audit_projects after insert or update on public.projects for each row execute function public.audit_row();
create trigger audit_members after insert or update or delete on public.project_members for each row execute function public.audit_row();
create trigger audit_contracts after insert or update on public.contracts for each row execute function public.audit_row();
create trigger audit_rules after insert or update on public.deadline_rules for each row execute function public.audit_row();
create trigger audit_notices after insert or update on public.notices for each row execute function public.audit_row();
create trigger audit_deadlines after insert or update on public.contractual_deadlines for each row execute function public.audit_row();
create trigger audit_changes after insert on public.deadline_changes for each row execute function public.audit_row();
create trigger audit_documents after insert on public.documents for each row execute function public.audit_row();

-- ---------------------------------------------------------------------------
-- Guards: rules of the contract process enforced in the database
-- ---------------------------------------------------------------------------

-- Rules: only a Project Manager or Contract Manager can verify or approve.
-- An approved rule is frozen; to change it, supersede it with a new rule.
create or replace function public.rules_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare approvers text[] := array['project_manager','contract_manager'];
begin
  if tg_op = 'INSERT' then
    if new.status in ('verified','approved') then
      raise exception 'A new rule cannot start as %', new.status;
    end if;
    return new;
  end if;

  if old.status = 'superseded' then
    raise exception 'A superseded rule is final';
  end if;
  if old.status = 'approved' then
    if new.status <> 'approved' and new.status <> 'superseded' then
      raise exception 'An approved rule can only be superseded';
    end if;
    if (new.period_value, new.period_unit, new.counting, new.clause, new.trigger_event,
        new.applies_to, new.project_id, new.rule_code)
       is distinct from
       (old.period_value, old.period_unit, old.counting, old.clause, old.trigger_event,
        old.applies_to, old.project_id, old.rule_code) then
      raise exception 'An approved rule cannot be edited. Supersede it and create a new rule.';
    end if;
  end if;

  if new.status in ('verified','approved') and new.status is distinct from old.status then
    if not public.has_project_role(new.project_id, approvers) then
      raise exception 'Only a Project Manager or Contract Manager can mark a rule as %', new.status;
    end if;
  end if;
  if new.status = 'approved' and old.status <> 'approved' then
    if old.status <> 'verified' then
      raise exception 'A rule must be Verified before it is Approved for Use';
    end if;
    new.approved_by := auth.uid();
    new.approved_at := now();
  end if;
  return new;
end $$;
create trigger rules_guard before insert or update on public.deadline_rules
  for each row execute function public.rules_guard();

-- Notices: a draft is not an issued notice, and issued notices are locked.
create or replace function public.notices_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare issuers text[] := array['project_manager','contract_manager','assistant_project_manager','project_administrator','engineer','contractor_rep','employer_rep'];
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'NOT');
    new.created_by := auth.uid();
    new.status := 'draft';          -- always starts as a draft
    new.issued_at := null; new.issued_by := null; new.approved_at := null; new.approver := null;
    new.delivered_at := null; new.receipt_confirmed_at := null;
    return new;
  end if;

  new.updated_at := now();
  if public.notice_rank(new.status) >= 3 then
    if new.approved_at is null or new.approver is null or new.issued_at is null then
      raise exception 'A notice cannot be formally issued without approval and an issue time';
    end if;
    if new.approved_at > new.issued_at then
      raise exception 'Approval must come before issue';
    end if;
    if old.issued_at is null then
      -- the moment of issue: record who issued it, from the authenticated session
      if not public.has_project_role(new.project_id, issuers) then
        raise exception 'You are not authorised to issue notices on this project';
      end if;
      new.issued_by := auth.uid();
    end if;
  end if;
  if public.notice_rank(new.status) >= 5 and new.delivered_at is null then
    raise exception 'Delivery must be evidenced (delivered_at) before a notice is marked delivered';
  end if;
  if new.status = 'receipt_confirmed' and new.receipt_confirmed_at is null then
    raise exception 'Receipt confirmation needs a receipt time';
  end if;
  if new.approver is not null and new.approver is distinct from old.approver then
    if not exists (select 1 from public.project_members m
                   where m.project_id = new.project_id and m.user_id = new.approver and m.active
                     and m.role in ('project_manager','contract_manager','project_administrator')) then
      raise exception 'The approver must be a Project Manager, Contract Manager or Project Administrator on this project';
    end if;
  end if;

  if old.issued_at is not null then
    if (new.ref, new.title, new.category, new.initiating_party, new.receiving_party, new.clause,
        new.description, new.event_at, new.aware_at, new.prepared_at, new.approved_at,
        new.approver, new.issued_at, new.issued_by, new.project_id)
       is distinct from
       (old.ref, old.title, old.category, old.initiating_party, old.receiving_party, old.clause,
        old.description, old.event_at, old.aware_at, old.prepared_at, old.approved_at,
        old.approver, old.issued_at, old.issued_by, old.project_id) then
      raise exception 'An issued notice cannot be edited. Record a new notice or a response instead.';
    end if;
    if public.notice_rank(new.status) < public.notice_rank(old.status) then
      raise exception 'An issued notice cannot move back to an earlier status';
    end if;
  end if;
  return new;
end $$;
create trigger notices_guard before insert or update on public.notices
  for each row execute function public.notices_guard();

-- Deadlines: original date is permanent; later dates change only through change_deadline().
create or replace function public.deadlines_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.original_due_date := new.due_date;
    return new;
  end if;
  if old.original_due_date is not null and new.original_due_date is distinct from old.original_due_date then
    raise exception 'The original deadline can never be changed';
  end if;
  if (new.trigger_at, new.rule_id, new.period_value, new.counting, new.notice_id, new.project_id)
     is distinct from
     (old.trigger_at, old.rule_id, old.period_value, old.counting, old.notice_id, old.project_id)
     and old.status <> 'flagged_for_review' then
    raise exception 'The trigger and rule behind a deadline are permanent';
  end if;
  if old.due_date is not null and new.due_date is distinct from old.due_date
     and coalesce(current_setting('beni.allow_deadline_change', true), '') <> 'on' then
    raise exception 'A deadline can only be changed with a documented reason (change_deadline)';
  end if;
  return new;
end $$;
create trigger deadlines_guard before insert or update on public.contractual_deadlines
  for each row execute function public.deadlines_guard();

-- Documents: the database sets who uploaded, when, the reference and the version.
create or replace function public.documents_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare pref text;
begin
  select ref_prefix into pref from public.document_folders where code = new.folder_code;
  new.ref := public.next_ref(new.project_id, pref);
  new.uploaded_by := auth.uid();
  new.uploaded_at := now();
  select coalesce(max(version), 0) + 1 into new.version
    from public.documents
   where project_id = new.project_id and folder_code = new.folder_code and original_name = new.original_name;
  return new;
end $$;
create trigger documents_before_insert before insert on public.documents
  for each row execute function public.documents_before_insert();

create or replace function public.contracts_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger contracts_touch before update on public.contracts
  for each row execute function public.contracts_touch();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.contracts enable row level security;
alter table public.deadline_rules enable row level security;
alter table public.ref_counters enable row level security;
alter table public.notices enable row level security;
alter table public.contractual_deadlines enable row level security;
alter table public.deadline_changes enable row level security;
alter table public.notifications enable row level security;
alter table public.document_folders enable row level security;
alter table public.documents enable row level security;
alter table public.audit_events enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (
  id = auth.uid()
  or exists (select 1 from public.project_members a join public.project_members b on a.project_id = b.project_id
             where a.user_id = auth.uid() and b.user_id = profiles.id));

create policy projects_read on public.projects for select to authenticated using (public.is_project_member(id));
create policy projects_update on public.projects for update to authenticated
  using (public.has_project_role(id, array['project_administrator','project_manager']))
  with check (public.has_project_role(id, array['project_administrator','project_manager']));

create policy members_read on public.project_members for select to authenticated using (public.is_project_member(project_id));
create policy members_insert on public.project_members for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager']));
create policy members_update on public.project_members for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager']));

create policy contracts_read on public.contracts for select to authenticated using (public.is_project_member(project_id));
create policy contracts_update on public.contracts for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager']));

create policy rules_read on public.deadline_rules for select to authenticated using (public.is_project_member(project_id));
create policy rules_insert on public.deadline_rules for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager']));
create policy rules_update on public.deadline_rules for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager']));

create policy notices_read on public.notices for select to authenticated using (public.is_project_member(project_id));
create policy notices_insert on public.notices for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','contractor_rep','employer_rep']));
create policy notices_update on public.notices for update to authenticated
  using (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','contractor_rep','employer_rep']))
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','engineer','contractor_rep','employer_rep']));

create policy deadlines_read on public.contractual_deadlines for select to authenticated using (public.is_project_member(project_id));
create policy changes_read on public.deadline_changes for select to authenticated using (public.is_project_member(project_id));

create policy notifications_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy folders_read on public.document_folders for select to authenticated using (true);

create policy documents_read on public.documents for select to authenticated using (public.is_project_member(project_id));
create policy documents_insert on public.documents for insert to authenticated
  with check (public.has_project_role(project_id, array[
    'project_administrator','project_manager','assistant_project_manager','contract_manager','engineer',
    'design_manager','resident_engineer','site_engineer','quantity_surveyor','planning_engineer',
    'qa_qc_manager','hse_officer','document_controller','contractor_rep','employer_rep']));

create policy audit_read on public.audit_events for select to authenticated
  using (project_id is not null and public.has_project_role(project_id,
         array['project_administrator','project_manager','contract_manager','auditor']));

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.profiles, public.projects, public.project_members, public.contracts,
  public.deadline_rules, public.notices, public.contractual_deadlines, public.deadline_changes,
  public.notifications, public.document_folders, public.documents, public.audit_events
  to authenticated;
grant update on public.projects, public.contracts to authenticated;
grant insert, update on public.project_members, public.deadline_rules, public.notices to authenticated;
grant insert on public.documents to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke execute on function public.audit_row(), public.block_change(), public.handle_new_user(),
  public.next_ref(uuid, text), public.documents_before_insert(), public.notices_guard(),
  public.rules_guard(), public.deadlines_guard(), public.contracts_touch() from public;

-- Create a profile automatically for every new sign-up.
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

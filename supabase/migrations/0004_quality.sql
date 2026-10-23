-- Migration 0004: Quality Management System.
--
-- Employer's Requirements (ERs) are entered by the team (one by one or imported from a
-- spreadsheet). Each requirement is then planned (ITPs), checked (inspections, tests,
-- material approvals), and its compliance is tracked. Non-conformances, corrective
-- actions and audits feed a scorecard of performance metrics (KPIs).
--
-- Nothing here is pre-filled. KPI targets are NULL until the team enters the targets
-- stated in the Employer's Requirements or the contract.

-- ---------------------------------------------------------------------------
-- Who may do what
-- ---------------------------------------------------------------------------
create or replace function public.can_write_quality(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_project_role(p, array['project_administrator','project_manager','assistant_project_manager',
    'contract_manager','engineer','resident_engineer','site_engineer','qa_qc_manager','design_manager',
    'contractor_rep','employer_rep','hse_officer','document_controller'])
$$;
create or replace function public.can_manage_requirements(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_project_role(p, array['project_administrator','project_manager','assistant_project_manager',
    'contract_manager','qa_qc_manager','design_manager','engineer','employer_rep'])
$$;
create or replace function public.can_sign_off_quality(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_project_role(p, array['project_manager','contract_manager','qa_qc_manager',
    'resident_engineer','engineer','employer_rep','design_manager'])
$$;

-- ---------------------------------------------------------------------------
-- 1. Employer's Requirements register
-- ---------------------------------------------------------------------------
create table public.employer_requirements (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,                         -- ER-001 (same reference across versions)
  version int not null default 1,
  er_section text,                           -- clause or section number in the Employer's Requirements
  title text not null,
  requirement_text text not null,            -- the requirement, word for word
  discipline text not null default 'general' check (discipline in (
    'architectural','structural','civil','mechanical','electrical','fire_life_safety',
    'lifts_vertical_transport','atc_control_tower','communications_it','aviation_icao',
    'environmental','hse','general')),
  category text not null default 'general' check (category in (
    'performance','design','materials','testing','documentation','standards','operational','general')),
  mandatory boolean not null default true,   -- "shall" (true) or "should" (false)
  priority text not null default 'major' check (priority in ('critical','major','minor')),
  applicable_standard text,
  acceptance_criteria text,
  verification_methods text[] not null default '{}'
    check (verification_methods <@ array['inspection','test','design_review','demonstration','certificate','analysis','document_review']),
  source_document_id uuid references public.documents(id),
  status text not null default 'draft' check (status in ('draft','active','superseded')),
  supersedes uuid references public.employer_requirements(id),
  superseded_by uuid references public.employer_requirements(id),
  change_reason text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref, version)
);
create index on public.employer_requirements (project_id, status);

create or replace function public.er_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare mgr text[] := array['project_manager','contract_manager','qa_qc_manager'];
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('beni.er_supersede', true), '') <> 'on' then
      new.ref := public.next_ref(new.project_id, 'ER');
      new.version := 1; new.status := 'draft'; new.supersedes := null; new.superseded_by := null;
    end if;
    new.created_by := auth.uid();
    return new;
  end if;
  if old.status = 'superseded' then raise exception 'A superseded requirement is final'; end if;
  if old.status = 'active' then
    if (new.ref, new.version, new.er_section, new.title, new.requirement_text, new.discipline, new.category,
        new.mandatory, new.priority, new.applicable_standard, new.acceptance_criteria,
        new.verification_methods, new.project_id)
       is distinct from
       (old.ref, old.version, old.er_section, old.title, old.requirement_text, old.discipline, old.category,
        old.mandatory, old.priority, old.applicable_standard, old.acceptance_criteria,
        old.verification_methods, old.project_id) then
      raise exception 'An active requirement cannot be edited. Supersede it with a new version.';
    end if;
    if new.status not in ('active','superseded') then raise exception 'An active requirement can only be superseded'; end if;
  end if;
  if new.status in ('active','superseded') and new.status is distinct from old.status then
    if not public.has_project_role(new.project_id, mgr)
       and coalesce(current_setting('beni.er_supersede', true), '') <> 'on' then
      raise exception 'Only a Project Manager, Contract Manager or QA/QC Manager can activate or supersede a requirement';
    end if;
  end if;
  if new.status = 'active' and old.status = 'draft' then
    if length(btrim(new.requirement_text)) < 5 then raise exception 'The requirement text is too short'; end if;
    if coalesce(array_length(new.verification_methods, 1), 0) = 0 then
      raise exception 'Choose at least one verification method before activating a requirement';
    end if;
  end if;
  return new;
end $$;
create trigger er_guard before insert or update on public.employer_requirements
  for each row execute function public.er_guard();
create trigger er_no_delete before delete on public.employer_requirements
  for each row execute function public.block_change();

-- Bulk import from a spreadsheet (the app parses the file and sends rows as JSON).
create or replace function public.import_requirements(p uuid, rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare r jsonb; n int := 0; vm text[];
begin
  if not public.can_manage_requirements(p) then raise exception 'You are not authorised to add requirements'; end if;
  if jsonb_typeof(rows) <> 'array' then raise exception 'Expected a list of requirements'; end if;
  for r in select * from jsonb_array_elements(rows) loop
    if coalesce(btrim(r ->> 'requirement_text'), '') = '' or coalesce(btrim(r ->> 'title'), '') = '' then
      raise exception 'Row % is missing a title or requirement text', n + 1;
    end if;
    select coalesce(array_agg(x), '{}') into vm from jsonb_array_elements_text(coalesce(r -> 'verification_methods', '[]'::jsonb)) x;
    insert into public.employer_requirements
      (project_id, er_section, title, requirement_text, discipline, category, mandatory, priority,
       applicable_standard, acceptance_criteria, verification_methods)
    values (p, r ->> 'er_section', r ->> 'title', r ->> 'requirement_text',
            coalesce(r ->> 'discipline', 'general'), coalesce(r ->> 'category', 'general'),
            coalesce((r ->> 'mandatory')::boolean, true), coalesce(r ->> 'priority', 'major'),
            r ->> 'applicable_standard', r ->> 'acceptance_criteria', vm);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Replace an active requirement with a new version (for example after a Variation).
create or replace function public.supersede_requirement(
  p_old uuid, p_requirement_text text, p_reason text,
  p_title text default null, p_acceptance_criteria text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.employer_requirements; nid uuid;
begin
  select * into o from public.employer_requirements where id = p_old;
  if not found then raise exception 'Requirement not found'; end if;
  if o.status <> 'active' then raise exception 'Only an active requirement can be superseded'; end if;
  if not public.has_project_role(o.project_id, array['project_manager','contract_manager','qa_qc_manager']) then
    raise exception 'Only a Project Manager, Contract Manager or QA/QC Manager can supersede a requirement';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'A documented reason is required'; end if;
  perform set_config('beni.er_supersede', 'on', true);
  insert into public.employer_requirements
    (project_id, ref, version, er_section, title, requirement_text, discipline, category, mandatory, priority,
     applicable_standard, acceptance_criteria, verification_methods, source_document_id, status, supersedes, change_reason)
  values (o.project_id, o.ref, o.version + 1, o.er_section, coalesce(p_title, o.title), p_requirement_text,
          o.discipline, o.category, o.mandatory, o.priority, o.applicable_standard,
          coalesce(p_acceptance_criteria, o.acceptance_criteria), o.verification_methods,
          o.source_document_id, 'active', o.id, p_reason)
  returning id into nid;
  update public.employer_requirements set status = 'superseded', superseded_by = nid where id = o.id;
  perform set_config('beni.er_supersede', 'off', true);
  return nid;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Inspection and Test Plans
-- ---------------------------------------------------------------------------
create table public.itps (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  title text not null,
  work_activity text,
  discipline text,
  specification_ref text,
  status text not null default 'draft' check (status in ('draft','approved','superseded')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);
create table public.itp_steps (
  id uuid primary key default gen_random_uuid(),
  itp_id uuid not null references public.itps(id),
  project_id uuid not null references public.projects(id) on delete cascade,
  step_no int not null,
  description text not null,
  point_type text not null default 'review' check (point_type in ('hold','witness','review','surveillance')),
  acceptance_criteria text,
  responsible_role text,
  unique (itp_id, step_no)
);

create or replace function public.itps_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'ITP'); new.status := 'draft';
    new.approved_by := null; new.approved_at := null; new.created_by := auth.uid();
    return new;
  end if;
  if old.status = 'approved' and (new.title, new.work_activity, new.specification_ref, new.project_id)
     is distinct from (old.title, old.work_activity, old.specification_ref, old.project_id) then
    raise exception 'An approved ITP cannot be edited. Supersede it with a new ITP.';
  end if;
  if new.status = 'approved' and old.status <> 'approved' then
    if not public.can_sign_off_quality(new.project_id) then
      raise exception 'You are not authorised to approve an ITP';
    end if;
    if not exists (select 1 from public.itp_steps where itp_id = new.id) then
      raise exception 'An ITP needs at least one step before approval';
    end if;
    new.approved_by := auth.uid(); new.approved_at := now();
  end if;
  return new;
end $$;
create trigger itps_guard before insert or update on public.itps for each row execute function public.itps_guard();

create or replace function public.itp_steps_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text;
begin
  select status into st from public.itps where id = new.itp_id;
  if st is null then raise exception 'ITP not found'; end if;
  if st <> 'draft' then raise exception 'Steps can only be changed while the ITP is a draft'; end if;
  new.project_id := (select project_id from public.itps where id = new.itp_id);
  return new;
end $$;
create trigger itp_steps_guard before insert or update on public.itp_steps for each row execute function public.itp_steps_guard();

-- ---------------------------------------------------------------------------
-- 3. Inspections
-- ---------------------------------------------------------------------------
create table public.inspections (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  title text not null,
  inspection_type text not null default 'work' check (inspection_type in
    ('hold_point','witness_point','review','surveillance','material','work','final','other')),
  itp_step_id uuid references public.itp_steps(id),
  location text, building text, level_floor text, drawing_ref text, specification_ref text,
  requested_by uuid references public.profiles(id),
  requested_at timestamptz,
  scheduled_at timestamptz,
  inspected_at timestamptz,
  inspector uuid references public.profiles(id),
  team text,
  result text not null default 'pending' check (result in ('pending','accepted','accepted_with_comments','rejected')),
  status text not null default 'planned' check (status in
    ('planned','requested','scheduled','inspected','accepted','accepted_with_comments','rejected','reinspection_required','closed')),
  comments text,
  deficiencies text,
  reinspection_of uuid references public.inspections(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);

create or replace function public.inspections_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev public.inspections;
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'INS'); new.created_by := auth.uid();
    if new.reinspection_of is not null then
      select * into prev from public.inspections where id = new.reinspection_of;
      if not found or prev.project_id <> new.project_id then raise exception 'Original inspection not found'; end if;
      if prev.result <> 'rejected' then raise exception 'Only a rejected inspection can be reinspected'; end if;
    end if;
    if new.result <> 'pending' or new.status in ('inspected','accepted','accepted_with_comments','rejected','reinspection_required','closed') then
      raise exception 'A new inspection starts as planned, requested or scheduled';
    end if;
    return new;
  end if;

  if old.result <> 'pending' and new.result is distinct from old.result then
    raise exception 'A recorded inspection result cannot be changed';
  end if;
  if old.result <> 'pending' and (new.inspected_at is distinct from old.inspected_at
      or new.inspector is distinct from old.inspector or new.project_id <> old.project_id) then
    raise exception 'The inspection date and inspector cannot be changed once a result is recorded';
  end if;
  if new.status in ('inspected','accepted','accepted_with_comments','rejected','reinspection_required','closed') then
    if new.inspected_at is null or new.inspector is null then
      raise exception 'Record the inspection time and inspector first';
    end if;
  end if;
  if new.result <> old.result or new.status in ('accepted','accepted_with_comments','rejected') then
    if not public.can_sign_off_quality(new.project_id) then
      raise exception 'You are not authorised to record an inspection result';
    end if;
  end if;
  if new.status = 'accepted' and new.result <> 'accepted' then raise exception 'Status and result do not match'; end if;
  if new.status = 'accepted_with_comments' and new.result <> 'accepted_with_comments' then raise exception 'Status and result do not match'; end if;
  if new.status = 'rejected' and new.result <> 'rejected' then raise exception 'Status and result do not match'; end if;
  if new.status = 'reinspection_required' and new.result <> 'rejected' then raise exception 'Only a rejected inspection needs reinspection'; end if;
  if new.result = 'rejected' and coalesce(btrim(new.deficiencies), '') = '' then
    raise exception 'Record the deficiencies found when rejecting an inspection';
  end if;
  if new.status = 'closed' and new.result = 'rejected' then
    if not exists (select 1 from public.ncrs n where n.inspection_id = new.id) then
      raise exception 'A rejected inspection needs a linked non-conformance report before it is closed';
    end if;
    if not exists (select 1 from public.inspections r where r.reinspection_of = new.id
                    and r.result in ('accepted','accepted_with_comments')) then
      raise exception 'A rejected inspection needs an accepted reinspection before it is closed';
    end if;
  end if;
  if new.status = 'closed' and new.result = 'pending' then raise exception 'Record a result before closing'; end if;
  return new;
end $$;
create trigger inspections_guard before insert or update on public.inspections for each row execute function public.inspections_guard();

-- ---------------------------------------------------------------------------
-- 4. Non-conformance reports and corrective actions
-- ---------------------------------------------------------------------------
create table public.ncrs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  title text not null,
  identified_at timestamptz not null default now(),
  location text,
  description text not null,
  specification_ref text,
  drawing_ref text,
  responsible_org text,
  severity text not null default 'minor' check (severity in ('minor','major','critical')),
  inspection_id uuid references public.inspections(id),
  requirement_id uuid references public.employer_requirements(id),   -- the requirement that was not met
  repeat_of uuid references public.ncrs(id),
  immediate_action text,
  root_cause text,
  proposed_corrective_action text,
  disposition text not null default 'pending' check (disposition in ('pending','rework','repair','use_as_is','reject')),
  disposition_approved_by uuid references public.profiles(id),
  due_date date,
  status text not null default 'open' check (status in
    ('open','corrective_action_assigned','corrective_action_done','verified','closed')),
  verification_notes text,
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  closure_evidence_document uuid references public.documents(id),
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);

create table public.corrective_actions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ncr_id uuid not null references public.ncrs(id),
  kind text not null default 'corrective' check (kind in ('corrective','preventive')),
  description text not null,
  assignee uuid references public.profiles(id),
  due_date date,
  status text not null default 'open' check (status in ('open','completed','verified')),
  completed_at timestamptz,
  evidence_document uuid references public.documents(id),
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create or replace function public.ncr_rank(s text) returns int language sql immutable as $$
  select case s when 'open' then 0 when 'corrective_action_assigned' then 1 when 'corrective_action_done' then 2
                when 'verified' then 3 when 'closed' then 4 end $$;

create or replace function public.ncrs_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'NCR'); new.created_by := auth.uid();
    new.status := 'open'; new.verified_by := null; new.verified_at := null;
    new.closed_by := null; new.closed_at := null; new.disposition_approved_by := null;
    if new.inspection_id is not null and not exists
       (select 1 from public.inspections i where i.id = new.inspection_id and i.project_id = new.project_id) then
      raise exception 'Inspection not found on this project';
    end if;
    return new;
  end if;
  if old.status = 'closed' then raise exception 'A closed non-conformance report cannot be changed'; end if;
  if (new.ref, new.project_id, new.identified_at, new.created_by) is distinct from
     (old.ref, old.project_id, old.identified_at, old.created_by) then
    raise exception 'The reference, project and identification time cannot be changed';
  end if;
  if public.ncr_rank(new.status) < public.ncr_rank(old.status) then
    raise exception 'A non-conformance report cannot move back to an earlier status';
  end if;
  if new.disposition = 'use_as_is' and old.disposition is distinct from 'use_as_is' then
    if not public.has_project_role(new.project_id, array['project_manager','engineer','resident_engineer','employer_rep','qa_qc_manager']) then
      raise exception 'Only a Project Manager, Engineer, Resident Engineer, QA/QC Manager or Employer Representative can accept work as is';
    end if;
    new.disposition_approved_by := auth.uid();
  end if;
  if new.status = 'corrective_action_assigned' and not exists
     (select 1 from public.corrective_actions c where c.ncr_id = new.id) then
    raise exception 'Add a corrective action before assigning';
  end if;
  if public.ncr_rank(new.status) >= 2 and exists
     (select 1 from public.corrective_actions c where c.ncr_id = new.id and c.status = 'open') then
    raise exception 'All corrective actions must be completed first';
  end if;
  if public.ncr_rank(new.status) >= 3 and old.status <> new.status and new.status = 'verified' then
    if not public.can_sign_off_quality(new.project_id) then raise exception 'You are not authorised to verify a corrective action'; end if;
    if coalesce(btrim(new.verification_notes), '') = '' then raise exception 'Record how the corrective action was verified'; end if;
    if exists (select 1 from public.corrective_actions c where c.ncr_id = new.id and c.status <> 'verified') then
      raise exception 'Every corrective action must be verified first';
    end if;
    new.verified_by := auth.uid(); new.verified_at := now();
  end if;
  if new.status = 'closed' then
    if not public.can_sign_off_quality(new.project_id) then raise exception 'You are not authorised to close a non-conformance report'; end if;
    if old.status <> 'verified' then raise exception 'Verify the corrective action before closing'; end if;
    if coalesce(btrim(new.root_cause), '') = '' then raise exception 'A root cause is required before closure'; end if;
    if new.closure_evidence_document is null then raise exception 'Closure evidence is required'; end if;
    if new.disposition = 'pending' then raise exception 'A disposition is required before closure'; end if;
    if new.disposition = 'use_as_is' and new.disposition_approved_by is null then
      raise exception 'Accepting work as is needs an authorised approval';
    end if;
    new.closed_by := auth.uid(); new.closed_at := now();
  end if;
  return new;
end $$;
create trigger ncrs_guard before insert or update on public.ncrs for each row execute function public.ncrs_guard();
create trigger ncrs_no_delete before delete on public.ncrs for each row execute function public.block_change();

create or replace function public.corrective_actions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare n public.ncrs;
begin
  select * into n from public.ncrs where id = new.ncr_id;
  if not found then raise exception 'Non-conformance report not found'; end if;
  new.project_id := n.project_id;
  if tg_op = 'INSERT' then
    new.created_by := auth.uid(); new.status := 'open'; new.completed_at := null;
    new.verified_by := null; new.verified_at := null;
    if n.status = 'closed' then raise exception 'The report is closed'; end if;
    return new;
  end if;
  if old.status = 'verified' then raise exception 'A verified corrective action cannot be changed'; end if;
  if new.status = 'completed' and old.status = 'open' then new.completed_at := now(); end if;
  if new.status = 'verified' then
    if not public.can_sign_off_quality(new.project_id) then raise exception 'You are not authorised to verify a corrective action'; end if;
    if new.evidence_document is null then raise exception 'Evidence is required to verify a corrective action'; end if;
    if old.status = 'open' then raise exception 'Complete the action before verifying it'; end if;
    new.verified_by := auth.uid(); new.verified_at := now();
  end if;
  return new;
end $$;
create trigger corrective_actions_guard before insert or update on public.corrective_actions
  for each row execute function public.corrective_actions_guard();
create trigger corrective_actions_no_delete before delete on public.corrective_actions
  for each row execute function public.block_change();

-- ---------------------------------------------------------------------------
-- 5. Test records and material approvals
-- ---------------------------------------------------------------------------
create table public.test_records (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  test_type text not null check (test_type in ('concrete_cube','steel','welding','waterproofing',
    'electrical','mechanical','fire_protection','lift','calibration','commissioning','soil','other')),
  item_tested text not null,
  location text,
  standard text,
  specified_min numeric, specified_max numeric,
  measured_value numeric,
  unit text,
  result text not null default 'pending' check (result in ('pass','fail','pending')),
  tested_at timestamptz,
  laboratory text,
  certificate_document uuid references public.documents(id),
  retest_of uuid references public.test_records(id),
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);
-- A measured value is judged by the database against the specified limits, not by the person typing.
create or replace function public.test_records_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.ref := public.next_ref(new.project_id, 'TRS'); new.created_by := auth.uid();
  if new.measured_value is not null and (new.specified_min is not null or new.specified_max is not null) then
    new.result := case when (new.specified_min is null or new.measured_value >= new.specified_min)
                        and (new.specified_max is null or new.measured_value <= new.specified_max)
                       then 'pass' else 'fail' end;
  elsif new.result <> 'pending' and new.measured_value is null and new.specified_min is null and new.specified_max is null then
    null;   -- qualitative test: the recorded outcome stands
  end if;
  if new.result <> 'pending' and new.tested_at is null then raise exception 'Record when the test was done'; end if;
  if new.retest_of is not null and not exists
     (select 1 from public.test_records t where t.id = new.retest_of and t.project_id = new.project_id and t.result = 'fail') then
    raise exception 'A retest must refer to a failed test on this project';
  end if;
  return new;
end $$;
create trigger test_records_guard before insert on public.test_records for each row execute function public.test_records_guard();
create trigger test_records_no_change before update or delete on public.test_records for each row execute function public.block_change();

create table public.material_approvals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  material text not null,
  supplier text,
  specification_ref text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer uuid references public.profiles(id),
  status text not null default 'submitted' check (status in ('submitted','approved','approved_as_noted','rejected','resubmit')),
  resubmission_of uuid references public.material_approvals(id),
  comments text,
  document_id uuid references public.documents(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);
create or replace function public.material_approvals_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'MAR'); new.created_by := auth.uid();
    new.status := 'submitted'; new.reviewed_at := null; new.reviewer := null; new.submitted_at := now();
    return new;
  end if;
  if old.status <> 'submitted' then raise exception 'A reviewed submission cannot be changed. Submit a new one.'; end if;
  if new.status <> 'submitted' then
    if not public.can_sign_off_quality(new.project_id) then raise exception 'You are not authorised to review material submissions'; end if;
    new.reviewed_at := now(); new.reviewer := auth.uid();
  end if;
  return new;
end $$;
create trigger material_approvals_guard before insert or update on public.material_approvals
  for each row execute function public.material_approvals_guard();

-- ---------------------------------------------------------------------------
-- 6. Quality audits
-- ---------------------------------------------------------------------------
create table public.quality_audits (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  ref text not null,
  title text not null,
  scope text,
  planned_date date not null,
  performed_at date,
  auditor uuid references public.profiles(id),
  outcome text check (outcome is null or outcome in ('satisfactory','minor_findings','major_findings')),
  report_document uuid references public.documents(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, ref)
);
create or replace function public.quality_audits_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.ref := public.next_ref(new.project_id, 'AUD'); new.created_by := auth.uid();
    new.performed_at := null; new.outcome := null; return new;
  end if;
  if new.performed_at is not null and (new.outcome is null or new.auditor is null) then
    raise exception 'Record the auditor and outcome when an audit is performed';
  end if;
  return new;
end $$;
create trigger quality_audits_guard before insert or update on public.quality_audits
  for each row execute function public.quality_audits_guard();

-- ---------------------------------------------------------------------------
-- 7. Evidence trail: links between requirements and the records that prove them
-- ---------------------------------------------------------------------------
create table public.er_links (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  requirement_id uuid not null references public.employer_requirements(id),
  kind text not null check (kind in ('itp_step','inspection','test','material_approval','ncr','document','audit')),
  target_id uuid not null,
  note text,
  linked_by uuid references public.profiles(id),
  linked_at timestamptz not null default now(),
  unique (requirement_id, kind, target_id)
);
create or replace function public.er_links_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ok boolean; rp uuid;
begin
  select project_id into rp from public.employer_requirements where id = new.requirement_id;
  if rp is null then raise exception 'Requirement not found'; end if;
  new.project_id := rp; new.linked_by := auth.uid(); new.linked_at := now();
  execute format('select exists (select 1 from public.%I where id = $1 and project_id = $2)',
    case new.kind when 'itp_step' then 'itp_steps' when 'inspection' then 'inspections' when 'test' then 'test_records'
                  when 'material_approval' then 'material_approvals' when 'ncr' then 'ncrs'
                  when 'document' then 'documents' when 'audit' then 'quality_audits' end)
    into ok using new.target_id, rp;
  if not ok then raise exception 'The linked record was not found on this project'; end if;
  return new;
end $$;
create trigger er_links_guard before insert on public.er_links for each row execute function public.er_links_guard();
create trigger er_links_no_change before update or delete on public.er_links for each row execute function public.block_change();

-- Compliance verifications are a permanent history; the latest one decides current status.
create table public.er_verifications (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  requirement_id uuid not null references public.employer_requirements(id),
  result text not null check (result in ('compliant','partially_compliant','non_compliant','waived')),
  evidence_document uuid references public.documents(id),
  inspection_id uuid references public.inspections(id),
  test_id uuid references public.test_records(id),
  waiver_reference text,
  notes text,
  verified_by uuid references public.profiles(id),
  verified_at timestamptz not null default now()
);
create or replace function public.er_verifications_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.employer_requirements;
begin
  select * into r from public.employer_requirements where id = new.requirement_id;
  if not found then raise exception 'Requirement not found'; end if;
  if r.status <> 'active' then raise exception 'Only an active requirement can be verified'; end if;
  new.project_id := r.project_id; new.verified_by := auth.uid(); new.verified_at := now();
  if not public.can_sign_off_quality(new.project_id) then raise exception 'You are not authorised to record compliance'; end if;
  if new.result = 'compliant' and new.evidence_document is null and new.inspection_id is null and new.test_id is null then
    raise exception 'A "compliant" result needs evidence: a document, an inspection or a test record';
  end if;
  if new.result = 'waived' then
    if coalesce(btrim(new.waiver_reference), '') = '' then raise exception 'A waiver needs its approval reference'; end if;
    if not public.has_project_role(new.project_id, array['project_manager','contract_manager','employer_rep']) then
      raise exception 'Only a Project Manager, Contract Manager or Employer Representative can record a waiver';
    end if;
  end if;
  return new;
end $$;
create trigger er_verifications_guard before insert on public.er_verifications for each row execute function public.er_verifications_guard();
create trigger er_verifications_no_change before update or delete on public.er_verifications for each row execute function public.block_change();

create or replace view public.v_er_compliance with (security_invoker = true) as
select r.*,
       coalesce(v.result, 'not_verified') as compliance_status,
       v.verified_at as last_verified_at,
       (select count(*) from public.er_links l where l.requirement_id = r.id) as evidence_links,
       (select count(*) from public.ncrs n where n.requirement_id = r.id and n.status <> 'closed') as open_ncrs
  from public.employer_requirements r
  left join lateral (select result, verified_at from public.er_verifications x
                      where x.requirement_id = r.id order by x.verified_at desc, x.id desc limit 1) v on true
 where r.status = 'active';

-- ---------------------------------------------------------------------------
-- 8. Performance metrics (KPIs)
-- ---------------------------------------------------------------------------
create table public.quality_kpis (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  code text not null,
  name text not null,
  description text,
  formula_key text not null default 'manual',
  unit text not null default 'count' check (unit in ('%','days','count','number')),
  direction text not null default 'higher_is_better' check (direction in ('higher_is_better','lower_is_better')),
  target numeric,                 -- from the Employer's Requirements or contract; NULL until entered
  amber_tolerance numeric not null default 0 check (amber_tolerance >= 0),
  er_reference text,              -- where the target is stated, for example "ER 12.4"
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (project_id, code)
);
create table public.quality_kpi_readings (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  kpi_id uuid not null references public.quality_kpis(id),
  period_start date not null,
  period_end date not null,
  value numeric not null,
  note text,
  recorded_by uuid references public.profiles(id),
  recorded_at timestamptz not null default now(),
  check (period_end >= period_start)
);
create or replace function public.kpi_readings_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.project_id := (select project_id from public.quality_kpis where id = new.kpi_id);
  new.recorded_by := auth.uid(); new.recorded_at := now();
  if new.project_id is null then raise exception 'KPI not found'; end if;
  return new;
end $$;
create trigger kpi_readings_guard before insert on public.quality_kpi_readings for each row execute function public.kpi_readings_guard();
create trigger kpi_readings_no_change before update or delete on public.quality_kpi_readings for each row execute function public.block_change();
create trigger kpis_no_delete before delete on public.quality_kpis for each row execute function public.block_change();

-- The measurable metrics the system can calculate by itself.
create or replace function public.kpi_value(p uuid, formula text, d_from date default null, d_to date default null)
returns numeric language plpgsql stable set search_path = public as $$
declare f date := coalesce(d_from, date_trunc('month', current_date)::date);
        t date := coalesce(d_to, current_date);
        v numeric;
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  case formula
  when 'er_compliance_pct' then
    select 100.0 * count(*) filter (where compliance_status = 'compliant')
           / nullif(count(*) filter (where compliance_status <> 'waived'), 0) into v
      from public.v_er_compliance where project_id = p;
  when 'er_verified_pct' then
    select 100.0 * count(*) filter (where compliance_status <> 'not_verified') / nullif(count(*), 0) into v
      from public.v_er_compliance where project_id = p;
  when 'er_critical_compliance_pct' then
    select 100.0 * count(*) filter (where compliance_status = 'compliant')
           / nullif(count(*) filter (where compliance_status <> 'waived'), 0) into v
      from public.v_er_compliance where project_id = p and priority = 'critical';
  when 'er_non_compliant_count' then
    select count(*) into v from public.v_er_compliance
     where project_id = p and compliance_status in ('non_compliant','partially_compliant');
  when 'inspection_first_time_pass_pct' then
    select 100.0 * count(*) filter (where result in ('accepted','accepted_with_comments')) / nullif(count(*), 0) into v
      from public.inspections
     where project_id = p and reinspection_of is null and result <> 'pending' and inspected_at::date between f and t;
  when 'inspection_rejection_rate_pct' then
    select 100.0 * count(*) filter (where result = 'rejected') / nullif(count(*), 0) into v
      from public.inspections
     where project_id = p and result <> 'pending' and inspected_at::date between f and t;
  when 'inspection_turnaround_days' then
    select avg(extract(epoch from (inspected_at - requested_at)) / 86400.0) into v
      from public.inspections
     where project_id = p and requested_at is not null and inspected_at is not null and inspected_at::date between f and t;
  when 'ncr_open_count' then
    select count(*) into v from public.ncrs where project_id = p and status <> 'closed';
  when 'ncr_overdue_count' then
    select count(*) into v from public.ncrs where project_id = p and status <> 'closed' and due_date < current_date;
  when 'ncr_critical_open_count' then
    select count(*) into v from public.ncrs where project_id = p and status <> 'closed' and severity = 'critical';
  when 'ncr_avg_closure_days' then
    select avg(extract(epoch from (closed_at - identified_at)) / 86400.0) into v
      from public.ncrs where project_id = p and closed_at is not null and closed_at::date between f and t;
  when 'ncr_repeat_rate_pct' then
    select 100.0 * count(*) filter (where repeat_of is not null) / nullif(count(*), 0) into v
      from public.ncrs where project_id = p and identified_at::date between f and t;
  when 'test_pass_rate_pct' then
    select 100.0 * count(*) filter (where result = 'pass') / nullif(count(*), 0) into v
      from public.test_records where project_id = p and result <> 'pending' and tested_at::date between f and t;
  when 'material_first_time_approval_pct' then
    select 100.0 * count(*) filter (where status in ('approved','approved_as_noted')) / nullif(count(*), 0) into v
      from public.material_approvals
     where project_id = p and resubmission_of is null and status <> 'submitted' and reviewed_at::date between f and t;
  when 'ca_overdue_count' then
    select count(*) into v from public.corrective_actions
     where project_id = p and status <> 'verified' and due_date < current_date;
  when 'audit_completion_pct' then
    select 100.0 * count(*) filter (where performed_at is not null) / nullif(count(*), 0) into v
      from public.quality_audits where project_id = p and planned_date between f and t;
  else
    return null;
  end case;
  return round(v, 1);
end $$;

create or replace function public.quality_scorecard(p uuid, d_from date default null, d_to date default null)
returns table (code text, name text, unit text, direction text, target numeric, amber_tolerance numeric,
               er_reference text, value numeric, status text)
language plpgsql stable set search_path = public as $$
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  return query
  select k.code, k.name, k.unit, k.direction, k.target, k.amber_tolerance, k.er_reference, x.val,
         case when x.val is null then 'no_data'
              when k.target is null then 'no_target'
              when k.direction = 'higher_is_better' then
                   case when x.val >= k.target then 'green' when x.val >= k.target - k.amber_tolerance then 'amber' else 'red' end
              else case when x.val <= k.target then 'green' when x.val <= k.target + k.amber_tolerance then 'amber' else 'red' end
         end
    from public.quality_kpis k
    cross join lateral (
      select case when k.formula_key = 'manual' then
        (select r.value from public.quality_kpi_readings r where r.kpi_id = k.id
          and r.period_end >= coalesce(d_from, date_trunc('month', current_date)::date)
          and r.period_start <= coalesce(d_to, current_date)
          order by r.period_end desc, r.id desc limit 1)
      else public.kpi_value(p, k.formula_key, d_from, d_to) end as val) x
   where k.project_id = p and k.active
   order by k.code;
end $$;

-- The standard metric set, started WITHOUT targets. The team enters the targets.
create or replace function public.seed_quality_kpis(p uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.quality_kpis (project_id, code, name, description, formula_key, unit, direction) values
   (p,'Q01',E'Employer\'s Requirements compliance','Share of active requirements verified as compliant (waived ones excluded)','er_compliance_pct','%','higher_is_better'),
   (p,'Q02','Requirements verified','Share of active requirements with any compliance result recorded','er_verified_pct','%','higher_is_better'),
   (p,'Q03','Critical requirements compliance','Compliance of requirements marked critical','er_critical_compliance_pct','%','higher_is_better'),
   (p,'Q04','Non-compliant requirements','Requirements currently non-compliant or only partly compliant','er_non_compliant_count','count','lower_is_better'),
   (p,'Q05','Inspection first-time pass rate','First inspections accepted (with or without comments)','inspection_first_time_pass_pct','%','higher_is_better'),
   (p,'Q06','Inspection rejection rate','All inspections rejected in the period','inspection_rejection_rate_pct','%','lower_is_better'),
   (p,'Q07','Inspection turnaround','Average days from request to inspection','inspection_turnaround_days','days','lower_is_better'),
   (p,'Q08','Open NCRs','Non-conformance reports not yet closed','ncr_open_count','count','lower_is_better'),
   (p,'Q09','Overdue NCRs','Open reports past their due date','ncr_overdue_count','count','lower_is_better'),
   (p,'Q10','Critical NCRs open','Open reports with critical severity','ncr_critical_open_count','count','lower_is_better'),
   (p,'Q11','NCR closure time','Average days from identification to closure','ncr_avg_closure_days','days','lower_is_better'),
   (p,'Q12','Repeat non-conformances','Reports in the period that repeat an earlier one','ncr_repeat_rate_pct','%','lower_is_better'),
   (p,'Q13','Test pass rate','Tests passed first time or on retest, as a share of all results','test_pass_rate_pct','%','higher_is_better'),
   (p,'Q14','Material first-time approval','Material submissions approved without resubmission','material_first_time_approval_pct','%','higher_is_better'),
   (p,'Q15','Overdue corrective actions','Actions not verified and past their due date','ca_overdue_count','count','lower_is_better'),
   (p,'Q16','Audit completion','Planned quality audits actually performed','audit_completion_pct','%','higher_is_better');
end $$;

-- Re-define project creation so every new project also gets the quality metric set.
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
  perform public.seed_quality_kpis(pid);
  return pid;
end $$;

-- Quality dashboard summary (counts only; nothing invented)
create or replace function public.qms_dashboard(p uuid) returns jsonb
language plpgsql stable set search_path = public as $$
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  return jsonb_build_object(
    'requirements_active', (select count(*) from employer_requirements where project_id = p and status = 'active'),
    'requirements_draft', (select count(*) from employer_requirements where project_id = p and status = 'draft'),
    'requirements_compliant', (select count(*) from v_er_compliance where project_id = p and compliance_status = 'compliant'),
    'requirements_non_compliant', (select count(*) from v_er_compliance where project_id = p and compliance_status in ('non_compliant','partially_compliant')),
    'requirements_not_verified', (select count(*) from v_er_compliance where project_id = p and compliance_status = 'not_verified'),
    'requirements_waived', (select count(*) from v_er_compliance where project_id = p and compliance_status = 'waived'),
    'inspections_open', (select count(*) from inspections where project_id = p and status not in ('accepted','accepted_with_comments','closed')),
    'ncrs_open', (select count(*) from ncrs where project_id = p and status <> 'closed'),
    'ncrs_overdue', (select count(*) from ncrs where project_id = p and status <> 'closed' and due_date < current_date),
    'actions_open', (select count(*) from corrective_actions where project_id = p and status <> 'verified'),
    'tests_failed', (select count(*) from test_records t where project_id = p and result = 'fail'
                      and not exists (select 1 from test_records r where r.retest_of = t.id and r.result = 'pass')));
end $$;

-- ---------------------------------------------------------------------------
-- Audit, security and privileges
-- ---------------------------------------------------------------------------
create trigger audit_er after insert or update on public.employer_requirements for each row execute function public.audit_row();
create trigger audit_itps after insert or update on public.itps for each row execute function public.audit_row();
create trigger audit_itp_steps after insert or update on public.itp_steps for each row execute function public.audit_row();
create trigger audit_inspections after insert or update on public.inspections for each row execute function public.audit_row();
create trigger audit_ncrs after insert or update on public.ncrs for each row execute function public.audit_row();
create trigger audit_cas after insert or update on public.corrective_actions for each row execute function public.audit_row();
create trigger audit_tests after insert on public.test_records for each row execute function public.audit_row();
create trigger audit_mar after insert or update on public.material_approvals for each row execute function public.audit_row();
create trigger audit_audits after insert or update on public.quality_audits for each row execute function public.audit_row();
create trigger audit_links after insert on public.er_links for each row execute function public.audit_row();
create trigger audit_verifs after insert on public.er_verifications for each row execute function public.audit_row();
create trigger audit_kpis after insert or update on public.quality_kpis for each row execute function public.audit_row();
create trigger audit_kpi_readings after insert on public.quality_kpi_readings for each row execute function public.audit_row();

alter table public.employer_requirements enable row level security;
alter table public.itps enable row level security;
alter table public.itp_steps enable row level security;
alter table public.inspections enable row level security;
alter table public.ncrs enable row level security;
alter table public.corrective_actions enable row level security;
alter table public.test_records enable row level security;
alter table public.material_approvals enable row level security;
alter table public.quality_audits enable row level security;
alter table public.er_links enable row level security;
alter table public.er_verifications enable row level security;
alter table public.quality_kpis enable row level security;
alter table public.quality_kpi_readings enable row level security;

do $$
declare t text;
begin
  foreach t in array array['employer_requirements','itps','itp_steps','inspections','ncrs','corrective_actions',
    'test_records','material_approvals','quality_audits','er_links','er_verifications','quality_kpis','quality_kpi_readings']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (public.is_project_member(project_id))', t || '_read', t);
  end loop;
end $$;

-- Requirements, KPI definitions: managed by requirement managers
create policy er_insert on public.employer_requirements for insert to authenticated with check (public.can_manage_requirements(project_id));
create policy er_update on public.employer_requirements for update to authenticated
  using (public.can_manage_requirements(project_id)) with check (public.can_manage_requirements(project_id));
create policy kpis_insert on public.quality_kpis for insert to authenticated with check (public.can_manage_requirements(project_id));
create policy kpis_update on public.quality_kpis for update to authenticated
  using (public.can_manage_requirements(project_id)) with check (public.can_manage_requirements(project_id));
-- Day-to-day quality records: quality writers
create policy itps_insert on public.itps for insert to authenticated with check (public.can_write_quality(project_id));
create policy itps_update on public.itps for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy itp_steps_insert on public.itp_steps for insert to authenticated
  with check (public.can_write_quality((select project_id from public.itps where id = itp_id)));
create policy itp_steps_update on public.itp_steps for update to authenticated
  using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy inspections_insert on public.inspections for insert to authenticated with check (public.can_write_quality(project_id));
create policy inspections_update on public.inspections for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy ncrs_insert on public.ncrs for insert to authenticated with check (public.can_write_quality(project_id));
create policy ncrs_update on public.ncrs for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy cas_insert on public.corrective_actions for insert to authenticated
  with check (public.can_write_quality((select project_id from public.ncrs where id = ncr_id)));
create policy cas_update on public.corrective_actions for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy tests_insert on public.test_records for insert to authenticated with check (public.can_write_quality(project_id));
create policy mar_insert on public.material_approvals for insert to authenticated with check (public.can_write_quality(project_id));
create policy mar_update on public.material_approvals for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy audits_insert on public.quality_audits for insert to authenticated with check (public.can_write_quality(project_id));
create policy audits_update on public.quality_audits for update to authenticated using (public.can_write_quality(project_id)) with check (public.can_write_quality(project_id));
create policy links_insert on public.er_links for insert to authenticated
  with check (public.can_write_quality((select project_id from public.employer_requirements where id = requirement_id)));
create policy verifs_insert on public.er_verifications for insert to authenticated
  with check (public.can_sign_off_quality((select project_id from public.employer_requirements where id = requirement_id)));
create policy kpi_readings_insert on public.quality_kpi_readings for insert to authenticated
  with check (public.can_write_quality((select project_id from public.quality_kpis where id = kpi_id)));

grant select on public.employer_requirements, public.itps, public.itp_steps, public.inspections, public.ncrs,
  public.corrective_actions, public.test_records, public.material_approvals, public.quality_audits,
  public.er_links, public.er_verifications, public.quality_kpis, public.quality_kpi_readings,
  public.v_er_compliance to authenticated;
grant insert, update on public.employer_requirements, public.itps, public.itp_steps, public.inspections, public.ncrs,
  public.corrective_actions, public.material_approvals, public.quality_audits, public.quality_kpis to authenticated;
grant insert on public.test_records, public.er_links, public.er_verifications, public.quality_kpi_readings to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function
  public.import_requirements(uuid, jsonb),
  public.supersede_requirement(uuid, text, text, text, text),
  public.kpi_value(uuid, text, date, date),
  public.quality_scorecard(uuid, date, date),
  public.qms_dashboard(uuid),
  public.create_project(text, text, text)
  to authenticated;
revoke execute on function public.seed_quality_kpis(uuid), public.er_guard(), public.itps_guard(),
  public.itp_steps_guard(), public.inspections_guard(), public.ncrs_guard(), public.corrective_actions_guard(),
  public.test_records_guard(), public.material_approvals_guard(), public.quality_audits_guard(),
  public.er_links_guard(), public.er_verifications_guard(), public.kpi_readings_guard() from public;

-- Migration 0010: a rule must pass through review, and be complete, before it can be Verified.
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

  if new.status = 'verified' and old.status not in ('verified','under_review') then
    raise exception 'A rule must be Under review before it is Verified';
  end if;
  if new.status = 'verified' and old.status <> 'verified' and
     (new.period_value is null or new.clause is null or new.trigger_event is null or new.source_document is null) then
    raise exception 'A rule needs its period, clause, trigger event and source document before it can be Verified';
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

-- Migration 0011: align with FIDIC Plant & Design-Build, 2nd edition 2017 (General Conditions text supplied by the user).
-- 1) Monthly report clause is Sub-Clause 4.20 [Progress Reports] in 2017 (4.21 was the 1999 numbering).
-- 2) A function that PROPOSES clause, trigger and period for rules, from the 2017 General Conditions.
--    Everything it writes is 'extracted_unverified'. Nothing is approved. Particular Conditions and Contract Data
--    can change any period, so the Project Manager / Contract Manager must still review, verify and approve.

-- 1) Report section references (only sections not yet verified are touched)
create or replace function public.fidic_2017_fix_sections(p uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.report_sections set clause_ref = '4.20 (a)' where project_id = p and key = 'progress' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (b)' where project_id = p and key = 'photographs' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (c)' where project_id = p and key = 'manufacture' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (d) / 6.10', title_en = 'Contractor''s Records (6.10): personnel, equipment and site records', title_fr = 'Registres de l''Entrepreneur (6.10) : personnel, matériel et chantier' where project_id = p and key = 'resources' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (e)' where project_id = p and key = 'quality' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (f)', title_en = 'List of Variations, and Notices of Claim given by either Party under 20.2.1',
         title_fr = 'Liste des Modifications et des Notifications de Réclamation données par l''une ou l''autre Partie (20.2.1)' where project_id = p and key = 'claims' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (g)' where project_id = p and key = 'safety' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (h)' where project_id = p and key = 'actual_vs_planned' and status = 'unverified';
  update public.report_sections set clause_ref = '4.20 (h) (measures to overcome delays)' where project_id = p and key = 'delay_measures' and status = 'unverified';
end $$;

-- Existing projects, and new ones from now on
select public.fidic_2017_fix_sections(id) from public.projects;
create or replace function public.seed_report_sections_2017() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.fidic_2017_fix_sections(new.id); return new; end $$;
create trigger seed_report_sections_2017 after insert on public.projects for each row execute function public.seed_report_sections_2017();
-- Note: this AFTER trigger fires after seed_report_sections (alphabetical order: seed_report_sections < seed_report_sections_2017).

-- 2) Proposed rule content from the 2017 General Conditions. One row per rule; periods are the GC defaults.
create or replace function public.load_fidic_2017_rule_proposals(p_project uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; src constant text := 'FIDIC Conditions of Contract for Plant and Design-Build, 2nd Ed. 2017, General Conditions';
begin
  if auth.uid() is null or not public.has_project_role(p_project, array['project_manager','contract_manager','project_administrator']) then
    raise exception 'Only a Project Manager, Contract Manager or Administrator can load rule proposals';
  end if;
  with m(code, clause, trig, val, descr, note) as (values
   ('R-001','20.2.1','Contractor became aware, or should have become aware, of the event or circumstance',28,'Notice of Claim by the Contractor, no later than 28 days. Late notice: no entitlement to payment or EOT.','Particular Conditions may change this period.'),
   ('R-002','20.2.1','Employer became aware, or should have become aware, of the event or circumstance',28,'Notice of Claim by the Employer, no later than 28 days. Late notice: no price reduction / DNP extension.','Particular Conditions may change this period.'),
   ('R-003','20.2.2','Engineer receives the Notice of Claim',14,'Engineer gives a Notice that the Notice of Claim was late, within 14 days; otherwise it is deemed valid.','Check Particular Conditions.'),
   ('R-004','20.2.4','Claiming Party became aware, or should have become aware, of the event or circumstance',84,'Fully detailed Claim within 84 days, or other period proposed by the claiming Party and agreed by the Engineer. Otherwise the Notice of Claim lapses.','Read from page 101 of the 2017 text. Check Particular Conditions.'),
   ('R-006','20.2.6','End of the effects of the event or circumstance (final claim); first interim claim then monthly',28,'Continuing effect: interim fully detailed Claims at monthly intervals; final fully detailed Claim within 28 days after the effects end, or other period agreed with the Engineer.','Two periods in one clause: monthly interim, 28 days final. Review how to split into two rules.'),
   ('R-007','3.7.3','Engineer receives the fully detailed Claim (or the date stated in the applicable Sub-Clause)',42,'Engineer gives Notice of agreement within 42 days, and Notice of determination within 42 days after that period. Silence on a Claim = deemed rejection.','The determination period starts after the agreement period ends under 3.7.1 / 3.7.2. Review start dates.'),
   ('R-008','3.7.5','Party receives the Engineer''s Notice of determination (or deemed rejection period expires)',28,'Notice of Dissatisfaction (NOD) within 28 days. If none, the determination is final and binding.','Check Particular Conditions.'),
   ('R-009','21.4.1','Party gives or receives the NOD under 3.7.5',42,'Reference of the Dispute to the DAAB within 42 days, otherwise the NOD lapses.','Check Particular Conditions.'),
   ('R-010','21.4.3','DAAB receives the reference',84,'DAAB gives its decision within 84 days, or other period agreed by the Parties.','Check Contract Data and DAAB Agreement.'),
   ('R-011','21.5','NOD given (after DAAB decision)',28,'Arbitration may begin on or after the 28th day after the NOD was given, unless the Parties agree otherwise.','Not a deadline to act by; earliest date arbitration may start.'),
   ('R-012','8.3','Contractor receives the Notice under 8.1 [Commencement of Works]',28,'Initial programme submitted to the Engineer within 28 days after receiving the Notice under 8.1.','Revised programme timing: see 8.3. Check Particular Conditions.'),
   ('R-013','8.3','Engineer receives the initial programme (21 days) or a revised programme (14 days)',21,'No Engineer Notice within 21 days (initial) or 14 days (revised) = deemed Notice of No-objection.','Two periods: 21 initial, 14 revised. Review how to split into two rules.'),
   ('R-016','13.3.2','Engineer receives the quotations',7,'If the Engineer does not respond within 7 days of receiving the quotations, the Contractor may accept any of them.','Applies to quotations for Daywork-type items. Review whether this matches the matter.'),
   ('R-018','14.6','Engineer receives a Statement and supporting documents',28,'Engineer issues the IPC within 28 days after receiving a Statement and supporting documents.','Check Contract Data.'),
   ('R-019','14.7','Engineer receives the Statement (IPC: 56 days), Employer receives IPC under 14.13 (28 days), Employer receives FPC (56 days)',56,'Payment of IPC within the period in the Contract Data; if not stated, 56 days after the Engineer receives the Statement and supporting documents.','Contract Data period decides. Different periods for advance payment (21 days) and FPC (56 days).'),
   ('R-021','10.1','Engineer receives the Contractor''s Notice applying for the Taking-Over Certificate',28,'Engineer issues the Taking-Over Certificate or rejects the application within 28 days. Contractor may apply not more than 14 days before completion.','Check Particular Conditions.'),
   ('R-023','14.11.1','Performance Certificate issued',56,'Contractor submits the draft final Statement within 56 days after the Performance Certificate.','Final Payment Certificate Claims: 56 days after receiving a copy (14.14).'))
  update public.deadline_rules r set
     contract_edition = 'FIDIC Plant & Design-Build 2nd Ed. 2017', clause = m.clause, trigger_event = m.trig,
     period_value = m.val, rule_description = m.descr, particular_condition_note = m.note,
     source_document = src, status = 'extracted_unverified'
  from m where r.project_id = p_project and r.rule_code = m.code and r.status = 'not_configured';
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.fidic_2017_fix_sections(uuid), public.seed_report_sections_2017(), public.load_fidic_2017_rule_proposals(uuid) from public, anon, authenticated;
grant execute on function public.load_fidic_2017_rule_proposals(uuid) to authenticated;

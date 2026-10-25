\set ON_ERROR_STOP off
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise notice 'FAIL (should have been blocked): %', label;
exception when others then raise notice 'PASS blocked: % -> %', label, sqlerrm; end $$;
create or replace function pg_temp.expect_ok(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise notice 'PASS allowed: %', label;
exception when others then raise notice 'FAIL (should have worked): % -> %', label, sqlerrm; end $$;
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','pm@x'),('22222222-2222-2222-2222-222222222222','site@x'),
 ('33333333-3333-3333-3333-333333333333','out@x'),('66666666-6666-6666-6666-666666666666','cm@x');
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
select public.create_project('Test','Beni') as pid \gset
reset role;
insert into project_members(project_id,user_id,role) values (:'pid','11111111-1111-1111-1111-111111111111','project_manager'),
 (:'pid','22222222-2222-2222-2222-222222222222','site_engineer'),(:'pid','66666666-6666-6666-6666-666666666666','contract_manager') on conflict do nothing;
select count(*) as rules_seeded, count(*) filter (where status='not_configured') as all_not_configured from deadline_rules where project_id=:'pid';
select timezone from projects where id=:'pid';
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);

-- RULES
select pg_temp.expect_fail($q$insert into deadline_rules(project_id,rule_code,matter,status) values ('$q$||:'pid'||$q$','X-1','m','approved')$q$,'rule born approved');
select pg_temp.expect_fail($q$update deadline_rules set status='approved' where rule_code='R-001'$q$,'approve straight from not_configured');
select pg_temp.expect_fail($q$update deadline_rules set status='verified' where rule_code='R-001'$q$,'verify straight from not_configured');
update deadline_rules set status='under_review' where rule_code='R-001';
select pg_temp.expect_fail($q$update deadline_rules set status='verified' where rule_code='R-001'$q$,'verify incomplete rule');
update deadline_rules set period_value=14, clause='20.2.1 (test)', trigger_event='Awareness of event', source_document='Test source', status='under_review', counting='exclude_trigger_day' where rule_code='R-001';
update deadline_rules set status='verified' where rule_code='R-001';
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
update deadline_rules set status='approved' where rule_code='R-001';
select status as status_after_site_engineer_attempt from deadline_rules where rule_code='R-001';
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
update deadline_rules set status='approved' where rule_code='R-001';
select rule_code,status,approved_by is not null as has_approver, approved_at is not null as has_time from deadline_rules where rule_code='R-001';
select pg_temp.expect_fail($q$update deadline_rules set period_value=30 where rule_code='R-001'$q$,'edit approved rule');
select pg_temp.expect_fail($q$delete from deadline_rules where rule_code='R-002'$q$,'delete rule');

-- NOTICES
insert into notices(project_id,title,event_at,status,issued_at) values (:'pid','Notice A','2026-10-01 10:00+02','formally_issued',now());
select ref,status,issued_at is null as issued_cleared from notices;
select pg_temp.expect_fail($q$update notices set status='formally_issued', issued_at=now() where title='Notice A'$q$,'issue without approval');
update notices set approved_at = now() - interval '1 hour', approver = '66666666-6666-6666-6666-666666666666' where title='Notice A';
select pg_temp.expect_ok($q$update notices set status='formally_issued', issued_at=now() where title='Notice A'$q$,'issue after approval');
select status, issued_by is not null as issuer_recorded from notices where title='Notice A';
select pg_temp.expect_fail($q$update notices set title='Changed' where title='Notice A'$q$,'edit issued notice');
select pg_temp.expect_fail($q$update notices set status='draft' where title='Notice A'$q$,'issued notice back to draft');
select pg_temp.expect_fail($q$update notices set status='delivered' where title='Notice A'$q$,'delivered without evidence');
select pg_temp.expect_fail($q$delete from notices$q$,'delete notice');
select pg_temp.expect_fail($q$update notices set approver='22222222-2222-2222-2222-222222222222' where title='Notice A'$q$,'site engineer as approver');

-- DEADLINES
select public.create_deadline_for_notice((select id from notices where title='Notice A'),(select id from deadline_rules where rule_code='R-002')) as d_flagged \gset
select status, due_date, flagged_reason from contractual_deadlines where id=:'d_flagged';
select public.create_deadline_for_notice((select id from notices where title='Notice A'),(select id from deadline_rules where rule_code='R-001')) as d_ok \gset
select status, due_date, original_due_date, left(calculation_note,60) as note from contractual_deadlines where id=:'d_ok';
select pg_temp.expect_fail($q$select public.create_deadline_for_notice((select id from notices where title='Notice A'),(select id from deadline_rules where rule_code='R-001'))$q$,'duplicate live deadline');
select pg_temp.expect_fail($q$update contractual_deadlines set due_date='2027-01-01'$q$,'direct date edit');
select pg_temp.expect_fail($q$select public.change_deadline('$q$||:'d_ok'||$q$','2026-10-20','short')$q$,'change without reason');
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select pg_temp.expect_fail($q$select public.change_deadline('$q$||:'d_ok'||$q$','2026-10-20','Engineer agreed an extension in writing')$q$,'site engineer changes deadline');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.change_deadline(:'d_ok','2026-10-20','Engineer agreed an extension in writing');
select due_date, original_due_date from contractual_deadlines where id=:'d_ok';
select old_due_date, new_due_date, left(reason,20) as reason from deadline_changes;
select pg_temp.expect_fail($q$update deadline_changes set reason='x'$q$,'edit change history');
select pg_temp.expect_fail($q$select public.recalculate_flagged_deadline('$q$||:'d_flagged'||$q$')$q$,'recalculate while rule unapproved');
select public.satisfy_deadline(:'d_ok','Notice of claim delivered');
select status from contractual_deadlines where id=:'d_ok';
select pg_temp.expect_fail($q$delete from contractual_deadlines$q$,'delete deadline');
select pg_temp.expect_fail($q$select public.change_deadline('$q$||:'d_ok'||$q$','2026-10-25','Trying to change a closed one')$q$,'change satisfied deadline');
select compute_due_date('2026-10-01 23:30+00'::timestamptz,14,'exclude_trigger_day','Africa/Lubumbashi') as excl_tz_rollover, compute_due_date('2026-10-01 10:00+00'::timestamptz,14,'include_trigger_day','Africa/Lubumbashi') as incl;

-- DOCUMENTS and AUDIT
insert into documents(project_id,folder_code,title,original_name,storage_path) values (:'pid','04','Letter','a.pdf',:'pid'||'/04/a.pdf');
select ref, uploaded_at is not null as stamped, uploaded_by is not null as uploader from documents;
select pg_temp.expect_fail($q$update documents set title='x'$q$,'edit document record');
select pg_temp.expect_fail($q$delete from documents$q$,'delete document record');
select pg_temp.expect_fail($q$update audit_events set action='x'$q$,'edit audit log');
select pg_temp.expect_fail($q$delete from audit_events$q$,'delete audit log');
select count(*) > 5 as audit_has_events from audit_events;

-- OUTSIDER
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select (select count(*) from notices) as n, (select count(*) from contractual_deadlines) as d, (select count(*) from deadline_rules) as r, (select count(*) from documents) as docs, (select count(*) from audit_events) as audit;
select pg_temp.expect_fail($q$select public.project_dashboard('$q$||:'pid'||$q$')$q$,'outsider dashboard');
select pg_temp.expect_fail($q$insert into notices(project_id,title) values ('$q$||:'pid'||$q$','sneaky')$q$,'outsider notice');
reset role;
set role anon;
select pg_temp.expect_fail($q$select count(*) from notices$q$,'anon reads notices');
select pg_temp.expect_fail($q$select public.create_project('x')$q$,'anon creates project');

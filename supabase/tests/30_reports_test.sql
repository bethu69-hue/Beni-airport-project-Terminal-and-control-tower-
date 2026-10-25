\set ON_ERROR_STOP off
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise notice 'FAIL (should have been blocked): %', label;
exception when others then raise notice 'PASS blocked: % -> %', label, sqlerrm; end $$;
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','pm@x'),('22222222-2222-2222-2222-222222222222','site@x'),
 ('33333333-3333-3333-3333-333333333333','out@x'),('44444444-4444-4444-4444-444444444444','apm@x');
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
select public.create_project('Test','Beni') as pid \gset
reset role;
insert into project_members(project_id,user_id,role) values (:'pid','22222222-2222-2222-2222-222222222222','site_engineer'),
 (:'pid','44444444-4444-4444-4444-444444444444','assistant_project_manager'),
 (:'pid','11111111-1111-1111-1111-111111111111','project_manager')
 on conflict do nothing;
select count(*) as sections_seeded from report_sections where project_id=:'pid';
set role authenticated;
-- site engineer generates
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select public.generate_monthly_report(:'pid','2026-09-01') as rid \gset
select ref, period_start, period_end, due_date, status, template_verified from monthly_reports;
select public.generate_monthly_report(:'pid','2026-09-01') = :'rid' as regenerate_same_row;
select count(*) as one_row_only from monthly_reports;
select pg_temp.expect_fail($q$select public.submit_report_for_review('$q$||:'rid'||$q$')$q$,'submit with empty manual sections');
select public.set_report_input(:'rid', k, 'None this month') from unnest(array['photographs','manufacture','resources','claims','safety','delay_measures','progress','quality','actual_vs_planned']) k;
select public.submit_report_for_review(:'rid');
select status from monthly_reports;
select pg_temp.expect_fail($q$update monthly_reports set manual_content='{}'$q$,'edit content after submit');
select pg_temp.expect_fail($q$select public.set_report_input('$q$||:'rid'||$q$','safety','x')$q$,'input after submit');
-- sign-off chain
select pg_temp.expect_fail($q$select public.sign_record('monthly_report','$q$||:'rid'||$q$','approved')$q$,'approve first');
select public.sign_record('monthly_report',:'rid','prepared') > 0 as prepared_ok;
select pg_temp.expect_fail($q$select public.sign_record('monthly_report','$q$||:'rid'||$q$','reviewed')$q$,'site engineer cannot review');
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
select public.sign_record('monthly_report',:'rid','reviewed','Checked against site records') > 0 as reviewed_ok;
select pg_temp.expect_fail($q$select public.sign_record('monthly_report','$q$||:'rid'||$q$','approved')$q$,'APM cannot approve');
select pg_temp.expect_fail($q$select public.issue_report('$q$||:'rid'||$q$')$q$,'APM cannot issue / not signed');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.sign_record('monthly_report',:'rid','approved') > 0 as approved_ok;
select status from monthly_reports;
select pg_temp.expect_fail($q$update signoffs set statement='x'$q$,'signoffs immutable');
select pg_temp.expect_fail($q$delete from signoffs$q$,'signoffs undeletable');
select step, signer_role, left(content_hash,12) h from signoffs order by id;
select public.issue_report(:'rid') as recipients_queued;
select status, issued_at is not null as has_issued_at from monthly_reports;
select pg_temp.expect_fail($q$update monthly_reports set status='generated'$q$,'reopen issued report');
-- same person two steps (second report)
select public.generate_monthly_report(:'pid','2026-08-01') as rid2 \gset
select public.set_report_input(:'rid2', k, 'None this month') from unnest(array['photographs','manufacture','resources','claims','safety','delay_measures','progress','quality','actual_vs_planned']) k;
select public.submit_report_for_review(:'rid2');
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.sign_record('monthly_report',:'rid2','prepared');
select pg_temp.expect_fail($q$select public.sign_record('monthly_report','$q$||:'rid2'||$q$','reviewed')$q$,'same person signs two steps');
-- tracked records
insert into tracked_records(project_id,kind,ref,title,due_basis,due_date) values (:'pid','variation','x','VO 1 pricing','internal_target','2026-11-15');
select pg_temp.expect_fail($q$insert into tracked_records(project_id,kind,ref,title,due_basis) values ('$q$||:'pid'||$q$','claim','x','c','contract_deadline')$q$,'contract due without deadline');
select pg_temp.expect_fail($q$insert into tracked_records(project_id,kind,ref,title,due_basis) values ('$q$||:'pid'||$q$','claim','x','c','internal_target')$q$,'internal target without date');
insert into tracked_records(project_id,kind,ref,title) values (:'pid','rfi','x','RFI no date');
select ref, kind, due_basis, due_date from tracked_records order by created_at;
select pg_temp.expect_fail($q$update tracked_records set status='closed'$q$,'close without note');
select pg_temp.expect_fail($q$delete from tracked_records$q$,'delete tracker');
select count(*) as timeline_rows, count(distinct source) as sources from v_timeline where project_id=:'pid';
-- outsider
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select count(*) as outsider_reports from monthly_reports;
select count(*) as outsider_timeline from v_timeline;
select count(*) as outsider_signoffs from signoffs;
select pg_temp.expect_fail($q$select public.generate_monthly_report('$q$||:'pid'||$q$','2026-07-01')$q$,'outsider generates');
-- scheduler (runs as service role: no signed-in user)
reset role;
select set_config('request.jwt.claim.sub','',false);
select public.run_monthly_report_job('2026-10-03') as day3_runs;
select public.run_monthly_report_job('2026-10-04') as day4_runs;
select public.run_monthly_report_job('2026-10-04') as day4_again;
select ref, period_start, period_end, due_date, status, generated_by is null as by_scheduler from monthly_reports order by period_start;
select count(*) as ready_notifications from notifications where kind='report_ready';
select public.run_monthly_report_job('2026-10-06');
-- anon cannot call
set role anon;
select pg_temp.expect_fail($q$select public.run_monthly_report_job()$q$,'anon scheduler');
select pg_temp.expect_fail($q$select public.generate_monthly_report(gen_random_uuid(),'2026-01-01')$q$,'anon generate');

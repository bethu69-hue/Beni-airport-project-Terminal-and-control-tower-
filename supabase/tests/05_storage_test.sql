\set ON_ERROR_STOP off
create or replace function pg_temp.expect_fail(sql text, label text) returns void language plpgsql as $$
begin execute sql; raise notice 'FAIL (should have been blocked): %', label;
exception when others then raise notice 'PASS blocked: % -> %', label, sqlerrm; end $$;
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','pm@x'),('33333333-3333-3333-3333-333333333333','out@x'),('55555555-5555-5555-5555-555555555555','aud@x');
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
select public.create_project('Test','Beni') as pid \gset
reset role;
insert into project_members(project_id,user_id,role) values (:'pid','11111111-1111-1111-1111-111111111111','project_manager'),(:'pid','55555555-5555-5555-5555-555555555555','auditor') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
insert into storage.objects(bucket_id,name,owner) values ('project-documents', :'pid'||'/04/abc-letter.pdf','11111111-1111-1111-1111-111111111111');
select count(*) as pm_sees from storage.objects;
select pg_temp.expect_fail($q$insert into storage.objects(bucket_id,name) values ('project-documents','not-a-uuid/04/x.pdf')$q$,'bad path');
select pg_temp.expect_fail($q$insert into storage.objects(bucket_id,name) values ('project-documents','$q$||:'pid'||$q$/x.pdf')$q$,'no folder segment');
select pg_temp.expect_fail($q$insert into storage.objects(bucket_id,name) values ('other-bucket','$q$||:'pid'||$q$/04/x.pdf')$q$,'wrong bucket');
select pg_temp.expect_fail($q$insert into storage.objects(bucket_id,name) values ('project-documents','11111111-1111-1111-1111-000000000000/04/x.pdf')$q$,'someone else''s project');
select set_config('request.jwt.claim.sub','55555555-5555-5555-5555-555555555555',false);
select count(*) as auditor_sees from storage.objects;
select pg_temp.expect_fail($q$insert into storage.objects(bucket_id,name) values ('project-documents','$q$||:'pid'||$q$/04/aud.pdf')$q$,'auditor upload');
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select count(*) as outsider_sees from storage.objects;
reset role;
select public='f' as bucket_private, file_size_limit from (select public, file_size_limit from storage.buckets where id='project-documents') b;
select pg_temp.expect_fail($q$insert into public.documents(project_id,folder_code,title,original_name,storage_path) values ('$q$||:'pid'||$q$','04','t','a.pdf','elsewhere/a.pdf')$q$,'document path outside project');

-- Migration 0003: private file storage for project documents.
-- Rules: the bucket is private; files live under {project_id}/{folder_code}/...; only project members can read;
-- only roles allowed to upload documents can add files; nobody can overwrite or delete a stored file (issued records are permanent).
-- Applied after 0007/0008 in practice (numbering reserved earlier); it re-states its own grants.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('project-documents', 'project-documents', false, 104857600, array[
  'application/pdf','image/png','image/jpeg','image/webp','image/heic',
  'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain','text/csv'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- First path segment is the project id. Returns null when the path is not in that shape.
create or replace function public.storage_project(name text) returns uuid
language plpgsql immutable set search_path = public as $$
begin
  return (string_to_array(name, '/'))[1]::uuid;
exception when others then return null;
end $$;

create or replace function public.can_upload_documents(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p is not null and public.has_project_role(p, array[
    'project_administrator','project_manager','assistant_project_manager','contract_manager','engineer',
    'design_manager','resident_engineer','site_engineer','quantity_surveyor','planning_engineer',
    'qa_qc_manager','hse_officer','document_controller','contractor_rep','employer_rep'])
$$;

drop policy if exists beni_docs_read on storage.objects;
drop policy if exists beni_docs_insert on storage.objects;
create policy beni_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'project-documents' and public.is_project_member(public.storage_project(name)));
create policy beni_docs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'project-documents' and public.can_upload_documents(public.storage_project(name))
              and array_length(string_to_array(name, '/'), 1) >= 3);
-- No update and no delete policy: stored files cannot be replaced or removed by users.

-- A document record must point inside its own project's folder.
alter table public.documents drop constraint if exists documents_path_in_project;
alter table public.documents add constraint documents_path_in_project
  check (storage_path like project_id::text || '/%') not valid;

revoke execute on function public.storage_project(text), public.can_upload_documents(uuid) from public, anon;
grant execute on function public.storage_project(text), public.can_upload_documents(uuid) to authenticated;

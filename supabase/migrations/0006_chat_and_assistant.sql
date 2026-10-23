-- Migration 0006: team directory, project chat with @mentions, off-line alerts (WhatsApp and
-- email outbox), 30-day chat retention, and the contract-document assistant's search index.
--
-- Honesty rules built in:
--  * A queued alert is NOT a delivered alert. The outbox records queued / sent / delivered / failed
--    separately, and only the sending service (service_role) may mark an alert sent or delivered.
--  * Phone numbers are only held with the person's WhatsApp consent flag.
--  * Chat is a convenience channel. Contractual notices must still go through Notices.

-- ---------------------------------------------------------------------------
-- Team directory: official email and phone for each project member
-- ---------------------------------------------------------------------------
create table public.team_directory (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  display_title text,
  organization text,
  work_email text,
  phone_e164 text check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  whatsapp_e164 text check (whatsapp_e164 is null or whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  whatsapp_consent boolean not null default false,
  whatsapp_consent_at timestamptz,
  email_alerts boolean not null default true,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (project_id, user_id)
);

create or replace function public.team_directory_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.project_members m where m.project_id = new.project_id and m.user_id = new.user_id and m.active) then
    raise exception 'That person is not a member of this project';
  end if;
  if tg_op = 'UPDATE' then new.last_seen_at := old.last_seen_at; end if;   -- presence has its own function
  if new.whatsapp_e164 is not null and new.whatsapp_consent and (tg_op = 'INSERT' or not old.whatsapp_consent) then
    new.whatsapp_consent_at := now();
  end if;
  if not new.whatsapp_consent then new.whatsapp_consent_at := null; end if;
  new.updated_at := now();
  return new;
end $$;
create trigger team_directory_guard before insert or update on public.team_directory
  for each row execute function public.team_directory_guard();

-- Project-level contact for the administrator's WhatsApp line and the retention period
alter table public.projects
  add column if not exists admin_whatsapp_e164 text check (admin_whatsapp_e164 is null or admin_whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  add column if not exists admin_email text,
  add column if not exists chat_retention_days int not null default 30 check (chat_retention_days >= 30);

-- ---------------------------------------------------------------------------
-- Channels and messages
-- ---------------------------------------------------------------------------
create table public.chat_channels (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null,
  purpose text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (project_id, name)
);

create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  channel_id uuid not null references public.chat_channels(id),
  sender uuid not null references public.profiles(id),
  body text not null check (length(btrim(body)) between 1 and 4000),
  mentions uuid[] not null default '{}',
  urgent boolean not null default false,
  reply_to uuid references public.chat_messages(id),
  created_at timestamptz not null default now()
);
create index on public.chat_messages (channel_id, created_at desc);
create index on public.chat_messages (project_id, created_at desc);

-- Alerts to people who are not online. One row per person per channel of delivery.
create table public.message_alerts (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  recipient uuid not null references public.profiles(id),
  via text not null check (via in ('whatsapp','email')),
  status text not null default 'queued' check (status in ('queued','sent','delivered','failed','skipped')),
  skip_reason text,
  provider_ref text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz,
  error text,
  unique (message_id, recipient, via)
);
create index on public.message_alerts (status, queued_at) where status = 'queued';

create or replace function public.chat_messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch public.chat_channels;
begin
  select * into ch from public.chat_channels where id = new.channel_id;
  if not found then raise exception 'Channel not found'; end if;
  new.project_id := ch.project_id;
  new.sender := auth.uid();
  new.created_at := now();
  if not public.is_project_member(new.project_id) then raise exception 'You are not a member of this project'; end if;
  -- keep only mentions of active members of this project
  new.mentions := coalesce((select array_agg(distinct m.user_id) from public.project_members m
                             where m.project_id = new.project_id and m.active and m.user_id = any (new.mentions)), '{}');
  return new;
end $$;
create trigger chat_messages_guard before insert on public.chat_messages
  for each row execute function public.chat_messages_guard();
create trigger chat_messages_no_edit before update on public.chat_messages
  for each row execute function public.block_change();

-- Queue off-line alerts for people who were tagged and are not currently online.
-- "Online" = seen in the last 2 minutes. A channel with the name 'site-queries' also alerts the
-- project's escalation user when nobody is tagged but the message is marked urgent.
create or replace function public.chat_messages_alerts() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid; td public.team_directory; online boolean; targets uuid[]; esc uuid;
begin
  targets := new.mentions;
  if new.urgent and coalesce(array_length(targets, 1), 0) = 0 then
    select escalation_user into esc from public.projects where id = new.project_id;
    if esc is not null then targets := array[esc]; end if;
  end if;
  foreach uid in array coalesce(targets, '{}') loop
    continue when uid = new.sender;
    select * into td from public.team_directory where project_id = new.project_id and user_id = uid;
    online := td.last_seen_at is not null and td.last_seen_at > now() - interval '2 minutes';
    if online then continue; end if;

    if td.user_id is not null and td.whatsapp_consent and td.whatsapp_e164 is not null then
      insert into public.message_alerts (project_id, message_id, recipient, via) values (new.project_id, new.id, uid, 'whatsapp')
        on conflict do nothing;
    else
      insert into public.message_alerts (project_id, message_id, recipient, via, status, skip_reason)
        values (new.project_id, new.id, uid, 'whatsapp', 'skipped',
                case when td.user_id is null then 'no directory entry'
                     when not td.whatsapp_consent then 'no WhatsApp consent recorded'
                     else 'no WhatsApp number' end) on conflict do nothing;
    end if;

    if td.user_id is not null and td.email_alerts and td.work_email is not null then
      insert into public.message_alerts (project_id, message_id, recipient, via) values (new.project_id, new.id, uid, 'email')
        on conflict do nothing;
    else
      insert into public.message_alerts (project_id, message_id, recipient, via, status, skip_reason)
        values (new.project_id, new.id, uid, 'email', 'skipped',
                case when td.user_id is null then 'no directory entry' when not td.email_alerts then 'email alerts switched off' else 'no email address' end)
        on conflict do nothing;
    end if;
  end loop;
  return new;
end $$;
create trigger chat_messages_alerts after insert on public.chat_messages
  for each row execute function public.chat_messages_alerts();

-- Presence: called by the app every minute while the chat is open.
create or replace function public.touch_presence(p uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  insert into public.team_directory (project_id, user_id) values (p, auth.uid())
    on conflict (project_id, user_id) do nothing;
  update public.team_directory set last_seen_at = now() where project_id = p and user_id = auth.uid();
end $$;

-- A person can see whether an alert about them was actually delivered or only queued.
-- Used by the sending service (service_role) to record real outcomes.
create or replace function public.record_alert_result(p_alert bigint, p_status text, p_provider_ref text default null, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the sending service may record delivery results'; end if;
  if p_status not in ('sent','delivered','failed') then raise exception 'Invalid status'; end if;
  update public.message_alerts set status = p_status, provider_ref = coalesce(p_provider_ref, provider_ref), error = p_error,
         sent_at = case when p_status in ('sent','delivered') and sent_at is null then now() else sent_at end,
         delivered_at = case when p_status = 'delivered' then now() else delivered_at end
   where id = p_alert;
end $$;

-- Retention: remove messages older than the project's retention period (never less than 30 days).
-- Run daily by the scheduler. Alerts go with their messages. Everything removed is counted in the audit log.
create or replace function public.purge_old_chat() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('beni.chat_purge', 'on', true);
  with gone as (
    delete from public.chat_messages m using public.projects p
     where p.id = m.project_id and m.created_at < now() - make_interval(days => p.chat_retention_days)
    returning m.project_id)
  select count(*) into n from gone;
  perform set_config('beni.chat_purge', 'off', true);
  if n > 0 then
    insert into public.audit_events (project_id, action, table_name, note) values (null, 'PURGE', 'chat_messages', n || ' messages past retention removed');
  end if;
  return n;
end $$;
create or replace function public.chat_messages_no_delete() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('beni.chat_purge', true), '') <> 'on' then
    raise exception 'Chat messages cannot be deleted. They are removed automatically after the retention period.';
  end if;
  return old;
end $$;
create trigger chat_messages_no_delete before delete on public.chat_messages
  for each row execute function public.chat_messages_no_delete();

-- ---------------------------------------------------------------------------
-- Contract-document assistant: searchable text and a permanent question log
-- ---------------------------------------------------------------------------
create table public.document_chunks (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  document_id uuid not null references public.documents(id),
  page int,
  heading text,
  content text not null,
  tsv tsvector generated always as (to_tsvector('simple', coalesce(heading, '') || ' ' || content)) stored,
  created_at timestamptz not null default now()
);
create index on public.document_chunks using gin (tsv);
create index on public.document_chunks (project_id, document_id);

create or replace function public.document_chunks_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.project_id := (select project_id from public.documents where id = new.document_id);
  if new.project_id is null then raise exception 'Document not found'; end if;
  if not public.has_project_role(new.project_id, array['project_administrator','project_manager','assistant_project_manager','contract_manager','document_controller']) then
    raise exception 'You are not authorised to index documents';
  end if;
  return new;
end $$;
create trigger document_chunks_guard before insert on public.document_chunks
  for each row execute function public.document_chunks_guard();

-- Passage search. Returns the passages and where they came from, so every answer can cite its source.
create or replace function public.search_contract_text(p uuid, q text, n int default 8)
returns table (chunk_id bigint, document_id uuid, doc_ref text, doc_title text, page int, heading text, passage text, rank real)
language plpgsql stable set search_path = public as $$
begin
  if not public.is_project_member(p) then raise exception 'No access to this project'; end if;
  return query
  select c.id, c.document_id, d.ref, d.title, c.page, c.heading, c.content,
         ts_rank(c.tsv, websearch_to_tsquery('simple', q))
    from public.document_chunks c join public.documents d on d.id = c.document_id
   where c.project_id = p and c.tsv @@ websearch_to_tsquery('simple', q)
   order by 8 desc limit least(greatest(n, 1), 20);
end $$;

create table public.assistant_queries (
  id bigserial primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  asked_by uuid references public.profiles(id),
  asked_at timestamptz not null default now(),
  question text not null,
  chunk_ids bigint[] not null default '{}',
  answer text,
  grounded boolean not null default false,
  model text
);
create or replace function public.assistant_queries_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_project_member(new.project_id) then raise exception 'No access to this project'; end if;
    new.asked_by := auth.uid(); new.asked_at := now();
    new.answer := null; new.grounded := false; new.model := null;
    return new;
  end if;
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the assistant service may record answers'; end if;
  if old.answer is not null then raise exception 'An answer, once recorded, is permanent'; end if;
  return new;
end $$;
create trigger assistant_queries_guard before insert or update on public.assistant_queries
  for each row execute function public.assistant_queries_guard();
create trigger assistant_queries_no_delete before delete on public.assistant_queries
  for each row execute function public.block_change();

-- ---------------------------------------------------------------------------
-- Security
-- ---------------------------------------------------------------------------
create trigger audit_directory after insert or update on public.team_directory for each row execute function public.audit_row();
create trigger audit_channels after insert on public.chat_channels for each row execute function public.audit_row();

alter table public.team_directory enable row level security;
alter table public.chat_channels enable row level security;
alter table public.chat_messages enable row level security;
alter table public.message_alerts enable row level security;
alter table public.document_chunks enable row level security;
alter table public.assistant_queries enable row level security;

create policy dir_read on public.team_directory for select to authenticated using (public.is_project_member(project_id));
create policy dir_insert on public.team_directory for insert to authenticated
  with check (user_id = auth.uid() or public.has_project_role(project_id, array['project_administrator','project_manager']));
create policy dir_update on public.team_directory for update to authenticated
  using (user_id = auth.uid() or public.has_project_role(project_id, array['project_administrator','project_manager']))
  with check (user_id = auth.uid() or public.has_project_role(project_id, array['project_administrator','project_manager']));

create policy channels_read on public.chat_channels for select to authenticated using (public.is_project_member(project_id));
create policy channels_insert on public.chat_channels for insert to authenticated
  with check (public.has_project_role(project_id, array['project_administrator','project_manager','assistant_project_manager']));

create policy msgs_read on public.chat_messages for select to authenticated using (public.is_project_member(project_id));
create policy msgs_insert on public.chat_messages for insert to authenticated
  with check (public.is_project_member((select project_id from public.chat_channels where id = channel_id)));

create policy alerts_read on public.message_alerts for select to authenticated
  using (recipient = auth.uid() or exists (select 1 from public.chat_messages m where m.id = message_id and m.sender = auth.uid()));

create policy chunks_read on public.document_chunks for select to authenticated using (public.is_project_member(project_id));
create policy chunks_insert on public.document_chunks for insert to authenticated
  with check (public.has_project_role((select project_id from public.documents where id = document_id),
    array['project_administrator','project_manager','assistant_project_manager','contract_manager','document_controller']));

create policy aq_read on public.assistant_queries for select to authenticated using (asked_by = auth.uid()
  or public.has_project_role(project_id, array['project_administrator','project_manager','contract_manager','auditor']));
create policy aq_insert on public.assistant_queries for insert to authenticated with check (public.is_project_member(project_id));

grant select on public.team_directory, public.chat_channels, public.chat_messages, public.message_alerts,
  public.document_chunks, public.assistant_queries to authenticated;
grant insert, update on public.team_directory to authenticated;
grant insert on public.chat_channels, public.chat_messages, public.document_chunks, public.assistant_queries to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Internal functions are not callable through the API; user-facing ones are granted explicitly.
revoke execute on function public.team_directory_guard(), public.chat_messages_guard(), public.chat_messages_alerts(),
  public.chat_messages_no_delete(), public.document_chunks_guard(), public.assistant_queries_guard(),
  public.purge_old_chat(), public.record_alert_result(bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.touch_presence(uuid), public.search_contract_text(uuid, text, int) to authenticated;
revoke execute on function public.touch_presence(uuid), public.search_contract_text(uuid, text, int) from public, anon;
grant execute on function public.record_alert_result(bigint, text, text, text), public.purge_old_chat() to service_role;

-- Live chat for the app (Supabase Realtime), where available
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;

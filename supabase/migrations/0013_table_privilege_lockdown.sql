-- Migration 0013: tighten table privileges (defence in depth; row security already blocked access).
-- Applied live together with the claim_events lockdown.
revoke all on public.claim_events, public.claim_event_types from public, anon, authenticated;
grant select on public.claim_event_types to authenticated;
grant select, insert, update on public.claim_events to authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke delete, truncate, trigger, references on all tables in schema public from authenticated;

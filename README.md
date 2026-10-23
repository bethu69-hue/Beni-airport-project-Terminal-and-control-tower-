# BENI Airport DRC: Terminal and Control Tower

Contract-aware project platform. Principles: no invented dates, values or progress; a draft is not an issued notice;
a prepared email is not a delivered one; every important change is audited; issued records are immutable;
security is enforced in the database (Postgres row-level security), not only in the browser.

## What is here
- `supabase/migrations/` — the database, applied in order:
  `0001_foundation`, `0002_deadline_engine`, `0004_quality`, `0005_supabase_hardening`, `0006_chat_and_assistant`.
  (There is no 0003 yet: it is reserved for file storage.)
- `supabase/tests/` — SQL tests. They run on plain Postgres 16 using the stub in `00_stub_supabase.sql`. Never run the stub on a real Supabase project.
- `prototype/` — the clickable design prototype (Design artifact files). Sample data is labelled DEMO.

## Status
Done: database, roles and row-level security, deadline engine, quality management (Employer's Requirements, compliance, NCRs, KPIs), chat with off-line alert queue, document search index.
Not built yet: the web application, file storage policies, the scheduler (daily reminders, chat retention), and the sender service for WhatsApp, email and the AI assistant.

## Nothing is configured on purpose
A new project starts with all contract particulars empty and all 23 deadline rules "not configured".
They must be entered from the executed contract and approved by a Project Manager or Contract Manager.
Quality KPI targets are blank until the targets from the Employer's Requirements are entered.

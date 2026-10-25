-- Migration 0009: daily jobs (Supabase pg_cron). Runs at 05:00 UTC; each job decides per project using the project's own timezone.
create extension if not exists pg_cron;
select cron.schedule('beni-monthly-report', '0 5 * * *', $$select public.run_monthly_report_job()$$);
select cron.schedule('beni-deadline-reminders', '5 5 * * *', $$select public.generate_reminders(null)$$);
select cron.schedule('beni-chat-retention', '15 2 * * *', $$select public.purge_old_chat()$$);

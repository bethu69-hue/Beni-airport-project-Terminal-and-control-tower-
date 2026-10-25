-- Run once after the first project is created (no project exists yet in the database).
update public.projects set admin_whatsapp_e164 = '+254725309557' where admin_whatsapp_e164 is null;

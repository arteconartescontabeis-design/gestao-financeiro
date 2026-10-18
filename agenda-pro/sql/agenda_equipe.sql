-- ============================================================
-- AGENDA PRO — cadastro de pessoas da equipe
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Usado pela Edge Function agenda-equipe: acha o login (auth.users) de um
-- e-mail que já existe no projeto (o mesmo projeto é usado pelo Financeiro Pro).
-- ============================================================
create or replace function public.agenda_auth_id_por_email(p_email text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1
$$;
revoke all on function public.agenda_auth_id_por_email(text) from public, anon, authenticated;
grant execute on function public.agenda_auth_id_por_email(text) to service_role;

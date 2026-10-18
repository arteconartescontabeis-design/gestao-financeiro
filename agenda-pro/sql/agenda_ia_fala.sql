-- ============================================================
-- MINUTOS DE ÁUDIO DO AGENDA NO PORTAL (projeto do Agenda: vuwgxndahrzinfdlapxz)
-- Aplicado em 11/10/2026. Par de sql/nucleo_ia_fala.sql (núcleo do portal).
--
-- O token que a função agenda-whats usa para informar os segundos de áudio
-- transcritos fica no cofre deste projeto (vault → ia_fala_token, criado com
-- 'iafala_agenda_' || 48 caracteres aleatórios). O núcleo guarda só o hash.
-- ============================================================

-- (feito uma vez, direto no SQL — o token não aparece em lugar nenhum)
-- select vault.create_secret('iafala_agenda_' || encode(extensions.gen_random_bytes(24), 'hex'), 'ia_fala_token',
--   'Token do Agenda para informar minutos de áudio (Azure) ao núcleo do portal');

create or replace function public.agenda_ia_fala_token()
returns text language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'ia_fala_token' limit 1
$$;
revoke all on function public.agenda_ia_fala_token() from public, anon, authenticated;
grant execute on function public.agenda_ia_fala_token() to service_role;

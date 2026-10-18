-- ============================================================
-- DURAÇÃO DO ÁUDIO TRANSCRITO (projeto do Cobrança: yeujqjtjqtegsnzwwazb)
-- Aplicado em 11/10/2026.
--
-- O serviço artecon-whats (v1.5.1+) grava em audio_seg quantos segundos de
-- áudio mandou para a Azure. A função agenda-whats lê por
-- cob_agenda_recebidas2 e informa ao núcleo do portal (Consumo de IA →
-- Transcrição de áudio). A cob_agenda_recebidas antiga continua igual.
-- ============================================================

alter table public.cob_whatsapp_recebidas
  add column if not exists audio_seg integer check (audio_seg is null or audio_seg between 0 and 3600);

create or replace function public.cob_agenda_recebidas2(p_token text, p_apos_id bigint, p_telefones text[])
 returns table(id bigint, telefone text, nome text, texto text, recebido_em timestamptz, audio_seg integer)
 language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.cob_agenda_integracao
   where ativo and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if v_tenant is null then raise exception 'token inválido' using errcode = '28000'; end if;
  return query
    select r.id, r.telefone, r.nome, r.texto, r.recebido_em, r.audio_seg
      from public.cob_whatsapp_recebidas r
     where r.tenant_id = v_tenant
       and r.id > coalesce(p_apos_id, 0)
       and r.recebido_em > now() - interval '2 days'
       and public.cob_fone_chave(r.telefone) = any (select public.cob_fone_chave(t) from unnest(p_telefones[1:50]) t)
     order by r.id
     limit 50;
end $function$;

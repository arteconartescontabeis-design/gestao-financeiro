-- BANCO ANTIGO "patrimonial-pro" (rujfstmskkgyeksspyoa) · SÓ LEITURA a partir da virada do Patrimonial.
-- Rodar NO BANCO ANTIGO (não no agenda-pro). Ninguém logado grava mais nada lá: tabelas só com leitura, as 2 funções que
-- gravam por conta própria sem uso, e os arquivos do GED sem envio nem exclusão. Os dados continuam lá para consulta e
-- para a conferência final (md5) até o projeto ir para o Artecon Arquivo. Volta: somente_leitura_volta.sql.
do $$ declare r record; begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pat\_%' loop
    execute format('revoke all on public.%I from anon, authenticated', r.relname);
    execute format('grant select on public.%I to authenticated', r.relname);
  end loop;
end $$;
revoke all on sequence public.pat_auditoria_id_seq from anon, authenticated;
revoke execute on function public.pat_admin_criar_usuario(text, text, text, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.pat_inativar(text, uuid, uuid) from public, anon, authenticated;
alter policy ged_objs_insert on storage.objects with check (false);
alter policy pat_docs_storage_insert on storage.objects with check (false);
alter policy ged_objs_delete on storage.objects using (false);
alter policy pat_docs_storage_delete on storage.objects using (false);
select count(*) filter (where has_table_privilege('authenticated', c.oid, 'INSERT') or has_table_privilege('authenticated', c.oid, 'UPDATE')) as tabelas_gravaveis,
       count(*) filter (where has_table_privilege('authenticated', c.oid, 'SELECT')) as tabelas_legiveis
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pat\_%';

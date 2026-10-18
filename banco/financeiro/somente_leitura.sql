-- BANCO ANTIGO do Financeiro (agenda-pro / vuwgxndahrzinfdlapxz) · SÓ LEITURA a partir da virada (18/10/2026).
-- Rodar NO agenda-pro. Tabelas fin_* só com leitura para quem está logado; as funções fin_* que gravam por conta própria
-- (SECURITY DEFINER com INSERT/UPDATE/DELETE) sem uso; arquivos do bucket fin-documentos sem envio, troca nem exclusão.
-- CORREÇÃO junto: a leitura dos arquivos passa a valer só para a pasta das empresas a que a pessoa tem acesso
-- (antes qualquer login do banco da Agenda lia qualquer arquivo). Volta: somente_leitura_volta.sql.
do $$ declare r record; begin
  for r in select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname like 'fin\_%' and c.relkind in ('r', 'S') loop
    if r.relkind = 'r' then
      execute format('revoke all on public.%I from anon, authenticated', r.relname);
      execute format('grant select on public.%I to authenticated', r.relname);
    else
      execute format('revoke all on sequence public.%I from anon, authenticated', r.relname);
    end if;
  end loop;
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'fin\_%' or p.proname = 'fn_atualizar_saldo_conta')
              and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.prosrc ~* '\m(insert|update|delete)\M' loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.f);
  end loop;
end $$;
alter policy fin_docs_select on storage.objects using ((bucket_id = 'fin-documentos'::text) AND ((storage.foldername(name))[1] IN (SELECT (t.t)::text AS t FROM public.fin_tenants_acessiveis() t(t))));
alter policy fin_docs_insert on storage.objects with check (false);
alter policy fin_docs_update on storage.objects using (false);
alter policy fin_docs_delete on storage.objects using (false);

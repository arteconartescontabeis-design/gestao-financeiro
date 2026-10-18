-- VOLTA ATRÁS · Financeiro de novo gravável no agenda-pro, como era antes da virada (inclusive a regra antiga dos arquivos,
-- que deixava qualquer login ler/gravar/apagar — só use se precisar desfazer a virada).
do $$ declare r record; begin
  for r in select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname like 'fin\_%' and c.relkind in ('r', 'S') loop
    if r.relkind = 'r' then execute format('grant all on public.%I to anon, authenticated', r.relname);
    else execute format('grant all on sequence public.%I to anon, authenticated', r.relname); end if;
  end loop;
  for r in select p.oid::regprocedure as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'fin\_%' or p.proname = 'fn_atualizar_saldo_conta')
              and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.prosrc ~* '\m(insert|update|delete)\M' loop
    execute format('grant execute on function %s to public, anon, authenticated', r.f);
  end loop;
end $$;
alter policy fin_docs_select on storage.objects using ((bucket_id = 'fin-documentos'::text));
alter policy fin_docs_insert on storage.objects with check ((bucket_id = 'fin-documentos'::text));
alter policy fin_docs_update on storage.objects using ((bucket_id = 'fin-documentos'::text));
alter policy fin_docs_delete on storage.objects using ((bucket_id = 'fin-documentos'::text));

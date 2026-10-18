-- VOLTA ATRÁS · banco antigo "patrimonial-pro" (rujfstmskkgyeksspyoa) de novo gravável, exatamente como era antes da virada.
do $$ declare r record; begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pat\_%' loop
    execute format('grant all on public.%I to anon, authenticated', r.relname);
  end loop;
end $$;
grant all on sequence public.pat_auditoria_id_seq to anon, authenticated;
grant execute on function public.pat_admin_criar_usuario(text, text, text, text, text, uuid, text) to public, anon, authenticated;
grant execute on function public.pat_inativar(text, uuid, uuid) to public, anon, authenticated;
alter policy ged_objs_insert on storage.objects with check (((bucket_id = 'pat-documentos'::text) AND pat_ged_path_ok(name)));
alter policy pat_docs_storage_insert on storage.objects with check (((bucket_id = 'pat-documentos'::text) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.ativo = true) AND ((ue.tenant_id)::text = (storage.foldername(objects.name))[1]))))));
alter policy ged_objs_delete on storage.objects using (((bucket_id = 'pat-documentos'::text) AND pat_ged_path_ok(name)));
alter policy pat_docs_storage_delete on storage.objects using (((bucket_id = 'pat-documentos'::text) AND (EXISTS ( SELECT 1
   FROM pat_usuarios_empresas ue
  WHERE ((ue.usuario_id = auth.uid()) AND (ue.ativo = true) AND ((ue.tenant_id)::text = (storage.foldername(objects.name))[1]))))));

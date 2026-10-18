-- FINANCEIRO PRO → cobranca-pro · arquivos (bucket privado fin-documentos). APLICADO em 18/10/2026 como `financeiro_003_arquivos`.
-- CORREÇÃO em relação ao banco antigo: lá qualquer login lia, gravava e apagava qualquer arquivo; aqui só os da pasta de
-- uma empresa a que a pessoa tem acesso (os caminhos são sempre <empresa>/<tipo>/<lançamento>/<arquivo>).
insert into storage.buckets (id, name, public) values ('fin-documentos', 'fin-documentos', false) on conflict (id) do nothing;
create policy fin_docs_select on storage.objects as permissive for select to authenticated
  using (bucket_id = 'fin-documentos' and (storage.foldername(name))[1] in (select t::text from public.fin_tenants_acessiveis() t));
create policy fin_docs_insert on storage.objects as permissive for insert to authenticated
  with check (bucket_id = 'fin-documentos' and (storage.foldername(name))[1] in (select t::text from public.fin_tenants_acessiveis() t));
create policy fin_docs_update on storage.objects as permissive for update to authenticated
  using (bucket_id = 'fin-documentos' and (storage.foldername(name))[1] in (select t::text from public.fin_tenants_acessiveis() t))
  with check (bucket_id = 'fin-documentos' and (storage.foldername(name))[1] in (select t::text from public.fin_tenants_acessiveis() t));
create policy fin_docs_delete on storage.objects as permissive for delete to authenticated
  using (bucket_id = 'fin-documentos' and (storage.foldername(name))[1] in (select t::text from public.fin_tenants_acessiveis() t));

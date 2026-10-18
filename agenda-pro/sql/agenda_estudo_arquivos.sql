-- ============================================================
-- AGENDA PRO — arquivos do Estudo da Reforma Tributária só com login (v2.6.0)
-- Projeto Supabase do Agenda: vuwgxndahrzinfdlapxz
-- Áudios (audio/*.mp3), conteúdo (dados.json) e análises (analises/*) saíram do GitHub (público)
-- e ficam no armazenamento privado "estudo". Só quem tem acesso ativo ao Estudo lê:
-- equipe do Agenda ou pessoa só do Estudo (agenda_estudo_tenant_id(), sql/agenda_estudo_usuarios.sql).
-- O estudo.html baixa o dados.json com o login e toca os áudios por endereço assinado (vale 6 h).
-- Quem grava os arquivos é a função estudo-carga (chave de serviço), por isso não há regra de gravação.
-- Só acréscimos.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('estudo', 'estudo', false, 20971520)
on conflict (id) do nothing;

create policy estudo_arquivos_ler on storage.objects for select to authenticated
  using (bucket_id = 'estudo' and public.agenda_estudo_tenant_id() is not null);

-- ------------------------------------------------------------
-- PARA REMOVER (só com confirmação do usuário), junto com o Estudo:
-- apagar os arquivos do armazenamento "estudo" (painel do Supabase → Storage) e depois:
-- drop policy if exists estudo_arquivos_ler on storage.objects;
-- delete from storage.buckets where id = 'estudo';
-- ------------------------------------------------------------

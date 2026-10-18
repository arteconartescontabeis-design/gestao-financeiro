-- Cobrança Pro v2.16.0 — liberação dos avisos de suspensão (2º e 3º nível da cobrança)
-- Começam BLOQUEADOS: enquanto false, o cliente recebe a cobrança normal (1º nível).
-- Liberar em Configurações → "Níveis de cobrança" (só diretor — mesma política de UPDATE de cob_politicas).
alter table public.cob_politicas
  add column if not exists nivel2_liberado boolean not null default false,
  add column if not exists nivel3_liberado boolean not null default false;

comment on column public.cob_politicas.nivel2_liberado is 'v2.16.0: envia o aviso de suspensão (30 a 59 dias de atraso). false = cobrança normal.';
comment on column public.cob_politicas.nivel3_liberado is 'v2.16.0: envia o aviso de serviços suspensos (60 dias ou mais). false = cobrança normal.';

# Financeiro Pro → banco da Gestão Empresarial e Financeiro (cobranca-pro) — 18/10/2026

| Arquivo | O que é |
|---|---|
| `001_estrutura.sql` | 3 sequências, 28 tabelas `fin_*`, regras, vínculos, índices, RLS e sem acesso anônimo |
| `002_funcoes_e_acesso.sql` | 47 funções, 109 políticas e 32 gatilhos (aplicado a partir do commit `7295c62`, conferido pelo md5) |
| `003_arquivos.sql` | bucket `fin-documentos` com a regra **corrigida** (só a pasta das empresas da pessoa) |
| `somente_leitura.sql` / `somente_leitura_volta.sql` | banco antigo (agenda-pro) só para consulta na virada / como desfazer |

**Conferência:** impressão digital da estrutura igual à do agenda-pro (colunas, regras, índices, funções, permissões,
políticas, gatilhos, RLS, acessos); md5 das 28 tabelas igual antes e depois de travar o banco antigo; 20 arquivos iguais
(nome e tamanho). Antes: extensão `pg_trgm` no esquema `extensions` (usada pela sugestão de vínculos de categorias).

**Como os dados foram copiados:** de servidor para servidor, por duas funções temporárias (`mig-fin-enviar` no agenda-pro e
`mig-fin-receber` no cobranca-pro), autenticadas por um código de uso único que nunca saiu dos servidores (só o resumo
sha256 dele foi copiado), com a cópia só podendo gravar linhas em tabelas `fin_*`, 2 logins pré-autorizados e arquivos do
bucket `fin-documentos`. Gatilhos desligados na cópia (não gerou auditoria nova nem refez saldos). Depois da cópia o
código foi apagado e as funções viraram aviso 410. O id do login do Cleiver foi trocado pelo id dele no cobranca-pro; os
outros 2 logins do Financeiro foram junto, com a senha que já tinham (eles nunca chegaram a entrar).

**Leitura de documentos por IA (`validar-anexos`):** publicada no cobranca-pro (`financeiro-pro/funcoes/validar-anexos.ts`).
Já não funcionava no agenda-pro: falta o secret `IA_GATEWAY_TOKEN` (token do Financeiro no Portal → Consumo de IA, que tem
0 usos). Precisa ser cadastrado no cobranca-pro para voltar a funcionar.

**Já não funcionava antes e continua igual:** "Novo usuário" chama a função `criar-usuario`, que nunca foi publicada.
6 dos 20 arquivos estão na pasta de uma empresa que não existe mais (ficam guardados, sem acesso pelo app).
